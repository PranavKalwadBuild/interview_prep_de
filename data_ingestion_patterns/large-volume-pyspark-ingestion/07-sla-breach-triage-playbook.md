# Scenario 07 — SLA Breach Triage Playbook

## The Problem Statement
> It's 2:15 AM. Job started at midnight. SLA is 3 AM. Spark UI shows 60% of tasks complete, but the remaining 40% are in a single skewed stage that started 90 minutes ago and shows no progress. What do you do?

---

## Triage Mindset

```
You have 45 minutes to fix or fail gracefully.

Three possible outcomes:
1. Fix and finish within SLA  ← ideal
2. Finish late but correctly  ← acceptable (communicate early)
3. Kill, fix root cause, re-run tomorrow  ← last resort, must communicate NOW

Decision rule:
  If estimated remaining time > time to SLA: kill and escalate immediately.
  Slow + silent = worst outcome.
```

---

## Step 1 — Diagnose in 5 Minutes (Spark UI)

```
Spark UI → Jobs → click failing job → Stages

For each stage, check:
┌──────────────────────┬─────────────────────────────────────────────────────┐
│ What to look at      │ What it means                                       │
├──────────────────────┼─────────────────────────────────────────────────────┤
│ Tasks: 99 succeeded, │ Skew: one task has 100× more data than others       │
│ 1 running (90 min)   │                                                     │
├──────────────────────┼─────────────────────────────────────────────────────┤
│ Shuffle Spill (Disk) │ Partitions too large → executor writing to disk     │
│ > 100 GB             │ → fix: increase shuffle.partitions                  │
├──────────────────────┼─────────────────────────────────────────────────────┤
│ GC Time > 20% of     │ Too many cores per executor, or too many small      │
│ task time            │ objects → fix: reduce cores/executor                │
├──────────────────────┼─────────────────────────────────────────────────────┤
│ Input: 50 GB for     │ Small files OR skewed partition → fix openCostIn    │
│ one task             │ Bytes or enable AQE skew                            │
├──────────────────────┼─────────────────────────────────────────────────────┤
│ 0 active tasks       │ Scheduler delay: cluster out of resources, or       │
│ despite pending      │ executor heartbeat lost → check executor logs       │
└──────────────────────┴─────────────────────────────────────────────────────┘
```

---

## Step 2 — Identify the Stage Type

```
Read stage (no shuffle):
  Bottleneck is S3 throughput or file enumeration (small files)
  Fix: cannot speed up a running stage — kill and add openCostInBytes fix

Shuffle stage (exchange / sort):
  Bottleneck is partition size (shuffle.partitions too low) or skew
  Fix: if AQE is on, check if skewJoin kicked in (Spark UI → stage details)
       If not: kill, increase shuffle.partitions, restart

Write stage (final output):
  Bottleneck is DW sink throughput, S3 PUT rate, or output file count
  Fix: reduce output parallelism if DW is throttling
       Increase if S3 PUT rate is fine but file count is low
```

---

## Step 3 — Estimate Remaining Time

```python
# Mental math:
# Tasks completed: 60% of 40,000 = 24,000 tasks done
# Tasks remaining: 16,000 tasks
# Currently running: 1 task (the skewed one)
# Time elapsed on that task: 90 minutes
# Estimate: task won't finish for another 90+ minutes

# Will it finish by 3 AM?
# Current time: 2:15 AM
# Time to SLA: 45 minutes
# Skewed task estimate: 90+ more minutes → MISS

# Decision: kill now, fix, re-run tomorrow with fix
#           OR kill the skewed task (let Spark retry) and hope retry is faster
```

---

## Emergency Fixes You Can Apply to a RUNNING Job

### Fix A — Kill the Straggler Task (Force Retry)

```
Spark UI → Stage → find the running task → "Kill" button
Spark will retry the task on a different executor.
Only helps if: the task was OOM/stuck due to executor state, not data skew.
Does NOT help if: same data = same skew = same outcome.
```

### Fix B — Dynamic Resource Allocation (Add Executors Mid-Run)

```python
# If cluster supports it, add executors dynamically
# Spark does not expose this via SparkSession API directly
# Must be done at cluster manager level (YARN / Kubernetes)

# For YARN (command line — not in Spark code):
# yarn application -updatePriority <app_id> VERY_HIGH  (gets more containers)

# For Kubernetes:
# kubectl scale deployment spark-executor --replicas=500

# Spark config to enable dynamic allocation (set at job start, not mid-run):
spark.conf.set("spark.dynamicAllocation.enabled", "true")
spark.conf.set("spark.dynamicAllocation.minExecutors", "10")
spark.conf.set("spark.dynamicAllocation.maxExecutors", "500")
spark.conf.set("spark.dynamicAllocation.executorIdleTimeout", "60s")
```

### Fix C — Speculative Execution (Auto-Duplicate Slow Tasks)

```python
# Spark launches a duplicate of any task that takes 1.5× longer than median
# If the duplicate finishes first, the original is killed
# Helps for: network issues, bad executor, noisy neighbor
# Does NOT help: genuine data skew (duplicate has same data)

spark.conf.set("spark.speculation", "true")
spark.conf.set("spark.speculation.multiplier", "1.5")  # task takes 1.5× median → speculate
spark.conf.set("spark.speculation.quantile", "0.9")    # wait for 90% of tasks to finish first
```

---

## Step 4 — Decision Matrix

```
Is the remaining stage a shuffle stage with one slow task?
├── YES → Is AQE skew detection enabled?
│         ├── NO  → Kill job, enable AQE skewJoin, restart
│         └── YES → Kill the straggler task (Fix A), monitor retry
│                   If retry same → AQE not detecting: raise threshold
│                   spark.sql.adaptive.skewJoin.skewedPartitionThresholdInBytes → 64m
│
├── Is shuffle.partitions = 200 (default)?
│   └── YES → Kill job, set to 10,000+, restart. Root cause confirmed.
│
├── Is it a write stage (DW sink)?
│   └── Check DW logs for throttling / connection limit
│       Reduce numPartitions on JDBC writer, restart from staging if available
│
└── Is time to SLA < estimated remaining time?
    └── YES → Kill, communicate breach, fix root cause, schedule re-run
```

---

## Step 5 — Prevention: Config Checklist for Every Large Job

```python
# Run this before every large ingestion job
def validate_spark_config(spark, data_size_gb: int):
    issues = []
    
    shuffle_parts = int(spark.conf.get("spark.sql.shuffle.partitions", "200"))
    if shuffle_parts < data_size_gb * 4:  # rough heuristic: 4 partitions/GB
        issues.append(
            f"shuffle.partitions={shuffle_parts} too low for {data_size_gb} GB. "
            f"Recommend >= {data_size_gb * 4}"
        )
    
    aqe_enabled = spark.conf.get("spark.sql.adaptive.enabled", "false")
    if aqe_enabled != "true":
        issues.append("AQE disabled. Enable for Spark 3.0+")
    
    skew_enabled = spark.conf.get("spark.sql.adaptive.skewJoin.enabled", "false")
    if skew_enabled != "true":
        issues.append("AQE skew join disabled. Enable for skew protection.")
    
    merge_schema = spark.conf.get("spark.sql.parquet.mergeSchema", "false")
    if merge_schema == "true":
        issues.append("mergeSchema=true causes full file scan before any task. Disable unless required.")
    
    if issues:
        for issue in issues:
            print(f"[CONFIG WARNING] {issue}")
        raise ValueError("Fix config issues before running on large dataset")
    
    print("Config check passed.")
```

---

## SLA Communication Template (Non-Technical)

```
Subject: [ALERT] Daily Ingestion Job — SLA at Risk / Missed

Status: Job started at 00:00. SLA is 03:00.
Current: [X%] complete at [TIME].
Estimated completion: [TIME].
SLA status: [AT RISK | MISSED by ~N minutes].

Root cause identified: [skew / OOM / small files / config].
Fix applied / being applied: [description].
Next action: [complete by X | re-run at Y | downstream tables impacted until Z].
```

---

## Follow-up Questions Interviewers Ask

**Q: You killed the job and restarted at 2:30 AM. Can you finish by 3 AM?**
A: Depends on the fix. If root cause was shuffle.partitions=200, restart with 10,000 and the shuffle stage that took 90 minutes should take ~5 minutes. A 30-minute restart + 20-minute run = done by 3:20 AM — close miss but significantly better than waiting for the straggler. Communicate the 20-minute breach early rather than hoping.

**Q: How do you prevent this from happening tomorrow?**
A: (1) Add the config validation function to the job's startup. (2) Add a job progress metric (tasks completed/total) to monitoring — alert if < 50% progress at 75% of SLA time. (3) Profile on 10% sample before first production run on a new dataset.

**Q: What's speculative execution and when does it NOT help?**
A: Spark launches a copy of any task running 1.5× longer than the median. The faster copy wins. Helps for: slow executor (hardware), network issues, noisy neighbor. Does NOT help: data skew (the duplicate gets the same skewed data and takes just as long). Configuring speculative execution on a skewed job wastes resources — duplicate tasks fight for the same resources as the original.

**Q: How do you estimate when a stage will finish?**
A: `Spark UI → Stage → Task Summary`. Find the 75th percentile task duration. Multiply by ceil(remaining tasks / concurrent slots). Add 15% buffer. This is your estimate. For skewed stages, look at the MAX task duration, not the median.

**Q: What is dynamic resource allocation and when to use it?**
A: DRA lets the cluster manager add/remove executors based on pending tasks. Use when: workload varies within a job (large shuffle then small write), or cluster is shared and you don't want to hold resources during idle phases. Don't use when: job is a single large stage (DRA won't kick in — all tasks already queued), or latency of spinning up new executors > the benefit (cold start can take 2–5 minutes).
