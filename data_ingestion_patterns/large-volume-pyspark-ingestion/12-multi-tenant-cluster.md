# 12 — Multi-Tenant Cluster Issues: Noisy Neighbors, Executor Preemption, and Spot Interruptions

---

## 1. The Problem

Your ingestion job shares a YARN cluster (or Kubernetes node pool) with other teams. A neighbor's job spikes and consumes all available executors. Your job gets preempted or starved. Alternatively, AWS Spot / GCP Preemptible instances are reclaimed by the cloud provider mid-job with 2 minutes of warning.

Result: job fails at 95% completion after 5 hours of processing. No checkpointing means the job restarts from scratch, consuming another 5 hours. In the worst case, it gets preempted again in the next run.

---

## 2. Interview Trigger Phrases

- "shared cluster"
- "YARN queue"
- "noisy neighbor"
- "executor preemption"
- "spot instance"
- "preemptible VMs"
- "job got killed"
- "resource contention"
- "fair scheduler"
- "dynamic allocation stealing executors"
- "ExecutorLostFailure"

---

## 3. Detection Signals

| Signal | Where to Look |
|--------|---------------|
| Executor count drops suddenly to near zero | Spark UI → Executors tab — look for rapid decrease |
| YARN shows queued tasks when cluster should have capacity | YARN ResourceManager UI → cluster queue utilization |
| `ExecutorLostFailure` in event log | Spark History Server → Failed Stages |
| Task retry count spikes | Spark UI → Stages → Tasks → look for retry > 0 |
| Job runtime variance: sometimes 2h, sometimes 6h | Monitor via job history — high variance = resource contention |
| Spot interruption notice | AWS: instance metadata `http://169.254.169.254/.../spot/termination-time`; GCP: metadata `maintenance-event` |
| YARN preemption log entries | YARN logs: `Container ... preempted` |

---

## 4. Root Cause

**YARN preemption:**
YARN's Capacity Scheduler and Fair Scheduler both support preemption — the ability to reclaim containers from a lower-priority queue and give them to a higher-priority or overloaded queue. Your job's executors are killed to free resources for another job that a scheduler considers higher priority.

**Spot / Preemptible instance reclamation:**
Cloud providers sell unused capacity at a discount with the caveat that they can reclaim the instance with a 2-minute notice. Spark treats a reclaimed node the same as a lost executor: all in-progress tasks on that node fail and must be retried (or the job fails if `spark.task.maxFailures` is exceeded).

**Dynamic allocation stealing:**
`spark.dynamicAllocation.enabled=true` tells Spark to release idle executors back to the cluster. Another job can immediately acquire them. When your job needs them again, they may not be available.

---

## 5. Fix Pattern

### Queue Isolation — Dedicated YARN Queue for SLA-Critical Jobs

```bash
# Submit to a dedicated queue with reserved capacity, not the default shared queue
spark-submit \
  --queue ingestion-sla-queue \   # YARN queue with capacity guarantee
  --conf spark.yarn.queue=ingestion-sla-queue \
  ...
```

Configure the YARN queue in `capacity-scheduler.xml` with a capacity floor:
```xml
<property>
  <name>yarn.scheduler.capacity.root.ingestion-sla-queue.capacity</name>
  <value>30</value>  <!-- 30% of cluster guaranteed -->
</property>
<property>
  <name>yarn.scheduler.capacity.root.ingestion-sla-queue.disable_preemption</name>
  <value>true</value>  <!-- prevent preemption FROM this queue -->
</property>
```

### Spot Instance Strategy — On-Demand Driver + Spot Workers

```bash
# Driver MUST be on on-demand — driver preemption kills the entire job
# Workers can be spot — individual task failures are recoverable

spark-submit \
  --conf spark.dynamicAllocation.enabled=true \
  --conf spark.dynamicAllocation.minExecutors=10 \    # on-demand floor, always available
  --conf spark.dynamicAllocation.maxExecutors=200 \   # burst with spot
  --conf spark.executor.instances=0 \                 # start with 0, let dynamic alloc scale
  ...

# EMR: use Instance Fleet with mixed purchasing option
# - 1 On-Demand master (driver)
# - Core group: 10 On-Demand (floor)
# - Task group: 0-190 Spot (burst)
```

### Checkpointing for Recovery — Never Restart from Scratch

```python
import os

CHECKPOINT_BASE = "s3://bucket/spark-checkpoints/job_name/"

def load_or_compute(spark, checkpoint_path: str, compute_fn):
    """Load from checkpoint if it exists; compute and save if not."""
    if spark._jvm.org.apache.hadoop.fs.FileSystem \
           .get(spark._jsc.hadoopConfiguration()) \
           .exists(spark._jvm.org.apache.hadoop.fs.Path(checkpoint_path)):
        print(f"Loading from checkpoint: {checkpoint_path}")
        return spark.read.parquet(checkpoint_path)
    else:
        df = compute_fn()
        df.write.mode("overwrite").parquet(checkpoint_path)
        print(f"Checkpoint saved: {checkpoint_path}")
        return spark.read.parquet(checkpoint_path)

# Stage 1: heavy transformation — checkpoint after completion
df_stage1 = load_or_compute(
    spark,
    CHECKPOINT_BASE + "stage1/",
    lambda: raw_df.transform(heavy_transform_1)
)

# Stage 2: join — checkpoint after completion
df_stage2 = load_or_compute(
    spark,
    CHECKPOINT_BASE + "stage2/",
    lambda: df_stage1.join(dim_df, "customer_id")
)

# Final write
df_stage2.write.mode("append").parquet(target_path)
```

### Graceful Spot Interruption Handling

```python
# On EMR: install the Spot Interruption Handler daemon on each node
# It polls the instance metadata service for termination notice
# On notice: sends SIGTERM to running containers, triggers graceful drain

# Increase task retry tolerance for spot workloads
# --conf spark.task.maxFailures=8  (default is 4)

# Enable speculative execution to re-launch stragglers on healthy nodes
# --conf spark.speculation=true
# --conf spark.speculation.interval=100ms
# --conf spark.speculation.multiplier=1.5
# --conf spark.speculation.quantile=0.90
```

### Dynamic Allocation Tuning

```bash
# Release idle executors quickly (60s) to be a good neighbor
--conf spark.dynamicAllocation.executorIdleTimeout=60s

# But keep executors longer if they hold cached data (RDD cache / broadcast)
--conf spark.dynamicAllocation.cachedExecutorIdleTimeout=300s

# Request new executors fast when backlog builds up
--conf spark.dynamicAllocation.schedulerBacklogTimeout=1s
--conf spark.dynamicAllocation.sustainedSchedulerBacklogTimeout=5s
```

### Kubernetes — Pod Priority and Disruption Budgets

```yaml
# PriorityClass: ingestion-critical pods won't be evicted for lower-priority pods
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata:
  name: spark-ingestion-high
value: 1000
globalDefault: false

# Pod Disruption Budget: at least 80% of executor pods must be running
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: spark-executor-pdb
spec:
  minAvailable: "80%"
  selector:
    matchLabels:
      spark-role: executor
```

### Full spark-submit Config Delta

```bash
spark-submit \
  --conf spark.task.maxFailures=8 \                              # more retries for spot
  --conf spark.dynamicAllocation.enabled=true \
  --conf spark.dynamicAllocation.minExecutors=10 \               # on-demand floor
  --conf spark.dynamicAllocation.maxExecutors=200 \
  --conf spark.dynamicAllocation.executorIdleTimeout=60s \
  --conf spark.dynamicAllocation.cachedExecutorIdleTimeout=300s \
  --conf spark.dynamicAllocation.schedulerBacklogTimeout=1s \
  --conf spark.speculation=true \                                 # re-launch stragglers
  --conf spark.speculation.multiplier=1.5 \
  --conf spark.speculation.quantile=0.90 \
  --conf spark.yarn.queue=ingestion-sla-queue \
  your_job.py
```

---

## 6. Gotchas

- **`spark.speculation=true` causes duplicate writes on non-ACID targets.** If a speculative task and the original task both complete successfully and both write to the same output path, you get duplicates. Only safe with Delta Lake (ACID transactions) or if output is idempotent by key. Do not enable speculation with plain Parquet writes to overlapping paths.
- **Never run the driver on a spot instance.** Driver preemption terminates the entire Spark application. There is no recovery — all executor state is lost. Driver must be on-demand, always.
- **`spark.task.maxFailures` counts failures per task attempt, not per job.** Default is 4. For spot workloads, set to 8–10. But don't set it too high — real application bugs will retry indefinitely and waste hours before the job finally fails.
- **Dynamic allocation can fight against checkpointing.** If executors are released between stages and checkpoints, re-acquiring them adds latency. Set `cachedExecutorIdleTimeout` high enough to keep executors alive during checkpoint writes.
- **Monitor spot reclamation rate.** If your spot instance reclamation rate exceeds 5% per hour, the job's expected completion time becomes unbounded. Switch SLA-critical jobs to on-demand for the executor floor.
- **YARN preemption and spot interruptions look identical in Spark UI** — both appear as `ExecutorLostFailure`. Distinguish them by checking: YARN logs for preemption messages vs. AWS/GCP instance metadata for spot termination notices.
- **Checkpoint paths accumulate.** Without a cleanup job, stage checkpoint directories grow unboundedly on S3. Add a cleanup step at job end or use S3 lifecycle policies on the checkpoint prefix.

---

## 7. Interview One-Liner

> "Multi-tenant and spot preemption failures are addressed with three levers: dedicated YARN queues with capacity guarantees and preemption disabled (for isolation), a mandatory on-demand driver with spot-only workers behind a minimum on-demand floor (for cost vs. reliability balance), and stage-level checkpointing to S3 (so a preempted job resumes from the last completed stage rather than restarting from scratch)."
