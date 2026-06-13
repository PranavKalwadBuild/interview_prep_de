# Spark UI Debugging Guide

> Ground truth for what actually ran. `explain()` shows intent; Spark UI shows reality.
> Access: http://driver-host:4040 (running job) | Databricks: cluster → Spark UI tab

---

## Navigation Map

```
Spark UI
├── Jobs          — all jobs, status, stage counts
├── Stages        — all stages, shuffle metrics, spill detection
│   └── Stage Detail → Tasks, Event Timeline, Summary Metrics
├── Storage       — cached datasets, eviction status
├── Environment   — final resolved configs (ground truth)
├── Executors     — per-executor utilization, GC, OOM diagnosis
└── SQL/DataFrame — executed queries, actual post-AQE plans, per-node metrics
```

**Fastest diagnosis path**:
```
Slow job? → SQL/DataFrame tab (find expensive query)
         → Stages tab (find expensive stage)
         → Stage Detail (check Summary Metrics for skew/spill)
         → Tasks tab (sort by Duration desc — find the stragglers)
         → Executors tab (GC? Dead executors?)
```

---

## Jobs Tab

**What it shows**: All Spark jobs. Each action (`.count()`, `.write()`, `.show()`) triggers one or more jobs.

**Columns**:
- Job ID, description (DataFrame operation or SQL query text)
- Status: Running / Succeeded / Failed / Skipped
- Stages (completed/total), Tasks (completed/total), Duration

**What to look for**:

| Signal | Meaning | Next step |
|--------|---------|-----------|
| Failed job | Exception in a stage | Click → see which stage failed |
| Skipped stages | Results reused from cache | Expected if caching correctly |
| One job 10× longer than others | The actual bottleneck | Drill into its stages |
| Many short jobs | Overhead-dominated pipeline | Check for small file reads, unnecessary actions |

**Skipped stages**: When Spark's lineage DAG shows a stage whose output was cached, it skips recomputation. Seeing skipped stages means caching is working correctly.

---

## Stages Tab

**What it shows**: All stages across all jobs. Each stage = one set of tasks between shuffle boundaries.

**Key columns**:

| Column | Problem Threshold | What it Means |
|--------|-------------------|---------------|
| Duration | — | Wall-clock time for stage completion |
| Input | — | Data read from external storage (S3, HDFS) |
| Shuffle Read | — | Data read from previous stage shuffle output |
| Shuffle Write | — | Data written to shuffle for next stage |
| **Shuffle Spill (Memory)** | **Any non-zero** | In-memory size of data that spilled |
| **Shuffle Spill (Disk)** | **Any non-zero** | Serialized bytes written to disk — memory exhausted |
| Failed Tasks | Any non-zero | Tasks that errored and may have retried |

**Detecting skew in Stages tab**:

The summary metrics table (in Stage Detail) shows min/25th/median/75th/max per metric. Skew pattern:
- `Max Duration` > 3–5× `75th percentile Duration`
- `Max Shuffle Read` > 3× `Median Shuffle Read`
- Databricks built-in rule: task data read > 3× average AND > 10 MB = data skew
- Time skew: task time > 3× average AND > 30 seconds = compute skew (not data)

**Spill diagnosis**:
```
Shuffle Spill (Memory): 50 GB   ← in-memory deserialized size of spilled data
Shuffle Spill (Disk):    5 GB   ← serialized bytes on disk (compression ratio ~10:1 typical)
```
Any disk spill = execution memory exhausted during that stage.

---

## Stage Detail View

Click any stage → opens the Stage Detail page.

### Event Timeline

Visual timeline showing which tasks ran on which executors, with color-coded phases:
- **Scheduler delay** (orange): time between task scheduling and starting — high if cluster is overloaded
- **Task deserialization** (yellow): time to deserialize the task and its dependencies
- **Executor computing time** (teal): actual computation
- **Result serialization** (red): serializing task result back to driver
- **GC** (dark red): garbage collection during the task

**Healthy timeline**: Narrow scheduler delay, narrow GC, wide teal (computing time).
**Unhealthy patterns**:
- Lots of orange: Cluster resource contention
- Lots of dark red: GC pressure — increase executor memory or reduce cores per executor
- Uneven task lengths: Data skew — one task runs 10× longer than others

### Summary Metrics Table

Shows distribution (min/25th/median/75th/max) for each metric across all tasks:

| Metric | What It Tells You |
|--------|------------------|
| Task Duration | Spread shows skew — large max/median ratio = skew |
| GC Time | > 10% of Duration = memory pressure |
| Result Size | Large results risk driver OOM |
| Shuffle Read Size | Uneven distribution = skew in previous stage |
| Shuffle Write Size | Uneven = skew going into next stage |
| Shuffle Read Blocked Time | High = I/O bottleneck reading remote shuffle blocks |
| Peak Execution Memory | How much execution memory each task consumed |
| Input Size / Records | Highly variable = partitioned data has skew |

---

## Tasks Tab (Stage Detail → Task List)

Most granular view. Sort by **Duration descending** immediately.

**Important columns**:

| Column | What to Watch |
|--------|---------------|
| Status | FAILED or KILLED (check stderr logs) |
| Locality | PROCESS_LOCAL > NODE_LOCAL > RACK_LOCAL > ANY — ANY means remote shuffle read |
| Duration | Sort desc — top tasks are the stragglers |
| GC Time | > 30% of Duration = GC is killing this executor |
| Input Size | Outlier = data skew in source partitioning |
| Shuffle Read Size | Outlier = skew from previous stage |
| Shuffle Write Size | Outlier = this task produces fat shuffle blocks |
| Shuffle Spill (Disk) | Any non-zero = this task spilled |
| Peak Execution Memory | How much memory this task used at peak |

**Scenario: Data skew diagnosis**:
```
Sort tasks by: Shuffle Read Size DESC
→ Task 47:  Shuffle Read = 12 GB  ← this is the skewed task
→ Task 0-46: Shuffle Read = ~200 MB each

Fix: AQE skew join (lower threshold), or manual salting
```

**Scenario: Spill diagnosis**:
```
Sort tasks by: Shuffle Spill (Disk) DESC
→ Most tasks: Disk = 0
→ Task 12: Disk = 8 GB, Memory = 80 GB

Fix: more shuffle partitions, more executor memory, broadcast join
```

**Scenario: GC pressure**:
```
Task Duration: 5 min
GC Time:       3 min  ← 60% of time in GC

Fix: reduce executor.cores (fewer concurrent tasks per JVM),
     increase executor.memory, switch to G1GC
```

---

## Storage Tab

**What it shows**: All currently cached/persisted RDDs and DataFrames.

**Columns**:

| Column | Problem Threshold | Meaning |
|--------|-------------------|---------|
| Storage Level | — | MEMORY_AND_DISK, MEMORY_ONLY, etc. |
| Cached Partitions | < Total | Not fully materialized |
| **Fraction Cached** | **< 100%** | Eviction occurred — cache benefit is partial |
| Size in Memory | — | JVM heap consumed by this cache |
| **Size on Disk** | **Any > 0** | Memory spilled to disk for cache — reads now 10–100× slower |

**Problem patterns**:
- **Fraction Cached < 100%**: Partitions evicted due to memory pressure. Either unpersist to reclaim memory for execution, or increase executor memory.
- **Disk > 0 with MEMORY_AND_DISK**: Memory wasn't enough; disk reads degrade performance substantially.
- **Storage consumes >80% of unified memory**: Execution (shuffles, joins) is being squeezed → spill in subsequent stages. Unpersist datasets you no longer need.

**Click any cached dataset name**: Opens per-executor breakdown. Uneven distribution (one executor holds 80%) indicates data skew in the partitioning of the underlying data.

---

## Environment Tab

**What it shows**: Final resolved values of all Spark configs, JVM system properties, environment variables.

**Primary use**: Verify your configs actually took effect.

```
# Check these specifically:
spark.sql.adaptive.enabled              → true
spark.sql.shuffle.partitions            → 2000 (not the default 200)
spark.sql.autoBroadcastJoinThreshold    → 52428800 (50 MB you set)
spark.databricks.delta.optimizeWrite.enabled → true
```

If a config you set is showing the default value here: precedence issue — check how/where you set it. Session-level `spark.conf.set()` should always win.

---

## SQL/DataFrame Tab

**The most important tab for query optimization.**

Shows all executed SQL/DataFrame queries. For each:
- Submitted time, duration, status (Running/Completed/Failed)
- Associated Spark jobs
- Physical plan DAG (expandable, with per-node metrics)

### Per-Node Metrics in the Plan DAG

Click any node in the plan visualization to see:

| Metric | What It Tells You |
|--------|------------------|
| `number of output rows` | Rows produced by this operator |
| `number of files read` | For Scan nodes |
| `size of files read` | For Scan nodes |
| `number of partitions read` | **Key DPP indicator** — should be << total partitions |
| `shuffle bytes written total` | For Exchange nodes — high = lots of data shuffled |
| `peak memory` | Per-operator memory at peak |
| `spill size` | Bytes spilled for this operator |
| `time in aggregation build` | For HashAggregate — high = large aggregation state |

### What to Look For

**Verify predicate pushdown worked**:
- Find the Scan node in the plan
- Check `number of partitions read` — if it equals total table partitions, DPP or partition pruning didn't fire

**Find the bottleneck operator**:
- The operator with the highest duration or shuffle bytes is the bottleneck
- Expand the exchange node — if shuffle bytes >> scan bytes, data is exploding (explode(), cross joins, etc.)

**Verify AQE join conversion**:
- Initial plan (from `explain()`) shows `SortMergeJoin`
- SQL tab shows `BroadcastHashJoin` after AQE conversion
- Look for `AdaptiveSparkPlan` at the root node; "Show Details" shows initial vs final plan

**Wrong row estimates**:
- Exchange node shows 10B rows going into a join
- But join output is 1K rows
- Optimizer's cardinality estimate was wrong → suboptimal plan was chosen

---

## Executors Tab

**What it shows**: Per-executor resource usage and task statistics.

**Key columns**:

| Column | Problem Threshold | Meaning |
|--------|-------------------|---------|
| State | Dead | Executor was killed |
| **GC Time** | **> 10% of Task Time** | GC pressure — shown with red background |
| Failed Tasks | Any > 0 | Tasks that errored on this executor |
| Disk Used | Any > 0 | Cached or spilled data on disk |
| Shuffle Read | Varies wildly | If one executor reads 10× others → skew in previous stage |

**OOM diagnosis flow**:
```
1. Executors tab → find Dead executors
   → Container OOM → increase spark.executor.memoryOverhead (not heap memory)
      Common cause: Python UDFs, Arrow ops, large broadcast tables

2. Executors tab → find high Failed Tasks + no Dead executor
   → Task-level OOM (java.lang.OutOfMemoryError in task logs)
   → Fix: increase spark.executor.memory, reduce spark.executor.cores

3. Executors tab → GC Time > 10% of Task Time
   → Fix: reduce spark.executor.cores (fewer tasks share heap)
          switch GC to G1GC: spark.executor.extraJavaOptions=-XX:+UseG1GC
          reduce cached data (Storage tab → Fraction Cached check)
```

**Skew diagnosis via Executors**:
- One executor has 3× more Shuffle Read bytes than others → that executor has the hot key
- One executor Active Tasks is always > 0 while others are idle → stragglers

---

## Scenario Playbooks

### Playbook: Slow Stage

**Symptoms**: One stage takes 10× longer than expected.

**Steps**:
1. Stages tab → click the slow stage
2. Event Timeline → any executors idle while others run? → uneven parallelism
3. Summary Metrics → Max Duration >> Median? → Data skew
4. Summary Metrics → All tasks slow equally? → Under-parallelism or slow I/O
5. Tasks tab → sort by Duration desc → inspect the slowest task
   - High Shuffle Read? → Skew in previous stage
   - High Input? → Skew in partitioning of source data
   - High GC Time? → Memory pressure on this executor

---

### Playbook: OOM / Executor Dead

**Symptoms**: Executor disappears from Executors tab or job fails with OOM.

**Steps**:
1. Executors tab → find Dead executor → note its host
2. Driver log (or Databricks cluster logs) → search for:
   - `Container killed by YARN` → container OOM → increase `memoryOverhead`
   - `java.lang.OutOfMemoryError: Java heap space` → JVM heap OOM → increase `executor.memory`
   - `OutOfMemoryError: GC overhead limit exceeded` → GC death spiral → same fix + reduce cores
3. If Python UDFs or Arrow: increase `memoryOverhead` first (it covers Python worker memory)
4. Storage tab → check if large caches are consuming memory

---

### Playbook: Data Skew

**Symptoms**: Stage runs for 30 minutes but 999/1000 tasks finish in 2 minutes.

**Steps**:
1. Stages tab → find the slow stage → see Max Duration >> Median Duration
2. Stage Detail → Tasks tab → sort Duration desc → one or few tasks 10–100× longer
3. Check: is it Input skew or Shuffle Read skew?
   - Shuffle Read outlier → skew from GROUP BY or JOIN key
   - Input outlier → source data partition imbalance
4. SQL tab → find the Exchange node feeding this stage → check shuffle bytes distribution
5. SQL tab → find the GROUP BY / JOIN responsible

**Fixes by type**:
- Join skew: AQE skew join (check thresholds), or manual salting
- GROUP BY skew: manual two-phase aggregation with salting
- Source partition skew: `repartition(n, col)` after read, or re-partition source data

---

### Playbook: Shuffle Spill

**Symptoms**: Stage much slower than expected; Shuffle Spill (Disk) > 0 in Stages tab.

**Steps**:
1. Stages tab → note which stages have Shuffle Spill (Disk) > 0
2. Stage Detail → Summary Metrics → check Peak Execution Memory distribution
3. Check: is spill concentrated on few tasks (skew) or spread across all tasks (global memory pressure)?
   - Concentrated: skew problem → fix the skew
   - Widespread: execution memory too small → more partitions or more executor memory
4. Can the join be converted to broadcast? If the table is borderline on size, increase `autoBroadcastJoinThreshold`

---

### Playbook: GC Pressure

**Symptoms**: Executors tab shows GC Time > 10–30% of Task Time (red background).

**Steps**:
1. Check executor configuration: are there many cores per executor? (> 5 is risky)
2. Check Storage tab: large caches consuming storage memory → evicting execution memory
3. Check for Python UDFs creating many JVM object graphs per row
4. Add G1GC: `spark.executor.extraJavaOptions=-XX:+UseG1GC -XX:InitiatingHeapOccupancyPercent=35`
5. Reduce `spark.executor.cores` to fewer concurrent tasks per JVM

---

## Quick-Reference: What Tab Answers What Question

| Question | Tab | What to Check |
|----------|-----|---------------|
| Which stage is the bottleneck? | Jobs → Stages | Duration column |
| Is there data skew? | Stage Detail → Summary Metrics | Max >> Median for Duration / Shuffle Read |
| Is there spill? | Stages | Shuffle Spill (Disk) > 0 |
| Is DPP working? | SQL/DataFrame | number of partitions read << total |
| Did AQE convert my join? | SQL/DataFrame | BroadcastHashJoin in AdaptiveSparkPlan |
| Is my cache working? | Storage | Fraction Cached = 100%, Disk = 0 |
| Why did my executor die? | Executors | State = Dead, check GC Time %, Failed Tasks |
| Are my configs applied? | Environment | Check the specific config value |
| Which tasks are stragglers? | Stage Detail → Tasks | Sort Duration desc |
| Is there GC pressure? | Executors | GC Time > 10% of Task Time (red) |
| What was the actual execution plan? | SQL/DataFrame | AdaptiveSparkPlan node |
