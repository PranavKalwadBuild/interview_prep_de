<!-- PySpark-patterns: Jobs, Stages, and Tasks Deep Dive -->

# Jobs, Stages, and Tasks — The Spark Execution Model

## The Three-Level Hierarchy

```
SparkContext / SparkSession
  └── Job  (1 per action: count, write, collect, show)
        └── Stage  (1 per shuffle boundary)
              └── Task  (1 per partition per stage)
```

Understanding this hierarchy is the foundation for reading the Spark UI, reasoning about failure recovery, and tuning parallelism.

---

## Part 1 — Jobs

### What Is a Job?

A **Job** is the top-level execution unit. It is created exactly once per **action**. Every action call triggers Spark to:

1. Take the accumulated logical plan (the DAG of transformations)
2. Submit it to `DAGScheduler` via `SparkContext.runJob()`
3. Assign a unique, auto-incrementing **Job ID** (starts at 0)
4. Create all the stages required to satisfy the action
5. Execute those stages in dependency order

### Actions That Each Trigger a New Job

| Action | Notes |
|--------|-------|
| `df.count()` | Full scan of all partitions; result returned to driver |
| `df.collect()` | Pulls all partition data to driver memory |
| `df.show(n)` | Internally issues collect on a limited result |
| `df.write.save()` | Writes all partitions to storage; one job regardless of file count |
| `df.take(n)` / `df.first()` | Tries to satisfy N rows with minimal task launches; may not scan all partitions |
| `df.foreach()` | Runs function side-effectively on each partition |
| `df.toPandas()` | Collects everything to driver as Pandas DataFrame |

**A single notebook cell can trigger multiple jobs** if it contains multiple actions:

```python
# This fires TWO jobs
total = df.count()       # Job 0
sample = df.show(10)     # Job 1
```

### Hidden Job Triggers

```python
# 1. Schema inference — fires an implicit job to sample the data
df = spark.read.option("inferSchema", "true").json("/data/")
# Fix: provide explicit schema to avoid the extra job

# 2. spark.read.format().load() with CSV sometimes fires a job for header detection
# Fix: set header option explicitly and provide schema

# 3. cache() does NOT trigger a job (it's lazy)
df.cache()        # no job yet
df.show()         # NOW it fires a job that also populates the cache
```

### The count()-in-a-Loop Antipattern

```python
# BAD: N separate jobs, each a full scan
for date in date_list:
    n = df.filter(F.col("dt") == date).count()   # 1 job per date

# GOOD: one job, all counts at once
counts = df.groupBy("dt").count().collect()      # 1 job total
```

In the Spark UI (Jobs tab), the bad pattern shows as many jobs with identical descriptions and the same source line number. The good pattern shows a single job.

### Job ID Lifecycle

The `DAGScheduler` maintains an atomic counter `nextJobId`. On `SparkContext.runJob()`:

1. `nextJobId.getAndIncrement()` assigns the Job ID
2. `SparkListenerJobStart` event posted — UI becomes aware
3. `handleJobSubmitted()` creates the terminal `ResultStage` and walks backward through the lineage to discover all `ShuffleMapStage`s
4. On completion (success or failure): `SparkListenerJobEnd` posted

**Driver-only concept:** The Job ID is not surfaced to executors. Inside a running task, only `TaskContext.get().stageId()` and `TaskContext.get().attemptNumber()` are accessible.

**Zero-partition short-circuit:** If the DataFrame has zero partitions (e.g., filtered to empty), Spark posts `JobStart` and `JobEnd(Succeeded)` immediately with no tasks scheduled.

---

## Part 2 — Stages

### What Is a Stage?

A **Stage** is a maximal set of tasks that can execute without any cross-node data exchange (shuffle). Stage boundaries are created by **wide (shuffle) transformations**.

**Narrow transformation** — each output partition depends on exactly ONE input partition. Pipelined within a stage:
- `filter`, `select`, `withColumn`, `map`, `flatMap`, `union`, `mapPartitions`

**Wide transformation** — each output partition depends on MULTIPLE input partitions. Creates a shuffle = creates a stage boundary:
- `groupBy`, `join` (SortMerge), `repartition`, `distinct`, `orderBy`, `cogroup`

```python
df2 = df.filter(F.col("year") == 2024)   # narrow — same stage as what comes next
df3 = df2.select("id", "amount")          # narrow — same stage
df4 = df3.groupBy("id").agg(F.sum("amount"))  # wide — NEW STAGE BOUNDARY
df4.write.parquet("/output")              # action → DAGScheduler sees groupBy → 2 stages
```

### ResultStage vs. ShuffleMapStage

Spark defines exactly two stage types:

**`ShuffleMapStage`** (intermediate):
- Appears everywhere in the DAG *except* the terminal stage
- Each task writes **shuffle output files** (FileSegments) to local executor disk
- Output tracked by `MapOutputTrackerMaster` on the driver
- Stage "completes" when ALL partitions have registered a `MapStatus` (location + size of each shuffle block)
- Can be **shared across multiple jobs** that share the same shuffle dependency — Spark reuses the files, so the stage is skipped in the second job

**`ResultStage`** (terminal):
- Exactly **one** per job — always the last stage
- Tasks either return results to driver (`collect`, `count`) or write to external storage (`write`)
- Tasks are instances of `ResultTask`

### How DAGScheduler Creates Stages

`handleJobSubmitted()` starts at the final RDD and performs a **reverse traversal** of the lineage DAG:

1. Walk backward through RDD dependencies
2. Wherever a `ShuffleDependency` is found → create a new `ShuffleMapStage` for the parent computation
3. All RDDs connected by `NarrowDependency` → pipelined into the same stage
4. Stages are submitted in **topological order** (parents before children)

Stage IDs are assigned by incrementing `nextStageId` — globally unique within a SparkContext lifetime.

### Stage Attempt Numbers

Each stage has a **Stage ID** (unique) and an **Attempt Number** (starts at 0, increments on re-execution).

A stage is **re-attempted** when:

1. **FetchFailedException**: A downstream task cannot read shuffle output from an upstream `ShuffleMapStage` (executor hosting the shuffle files died). DAGScheduler invalidates the lost `MapStatus`es and reschedules the upstream stage with `Attempt N+1`.

2. **ExecutorLost**: When an executor dies, all shuffle outputs it held are lost. Affected `ShuffleMapStage`s are resubmitted.

In the Spark UI, re-attempted stages show as e.g. "Stage 2, Attempt 1" — separate rows in the Stages table.

### Stage Success Criteria

A stage is **complete** when DAGScheduler receives a successful `CompletionEvent` for every partition:
- `ShuffleMapStage`: all `MapStatus`es registered in `MapOutputTrackerMaster`
- `ResultStage`: all tasks returned their result or wrote their output

Only then does DAGScheduler call `submitWaitingChildStages()` to unlock and submit dependent stages.

### Stage Skipping

When a `ShuffleMapStage`'s output is still on disk (from a prior job), subsequent jobs that share the same shuffle dependency **skip the stage**:

```
Spark UI: Stage appears grayed out with "(skipped)" label
Stages list: Appears under "Skipped Stages" section
```

Similarly, if a cached DataFrame is used as input to a stage, that stage is skipped.

**Skipped = good.** It means Spark found the data already computed.

### How Many Stages per Query?

Each wide transformation adds a stage boundary — one boundary = one additional stage on each side:

| Operation | Stages Added |
|-----------|-------------|
| 1 `groupBy` | 2 (partial agg + shuffle + final agg; the boundary is between them) |
| 1 SortMergeJoin | ~2 (shuffle both sides; both sides may be in separate stages) |
| 1 BroadcastHashJoin | ~1 (no shuffle on small side; only large side has a stage) |
| `repartition(N)` | 1 additional stage boundary |
| `distinct()` | 1–2 (internally a groupBy) |

For a query with **3 SortMergeJoins + 2 groupBys**:
```
Initial scan stage: 1
3 SMJ × ~2 stages: ~6
2 groupBy × ~2 stages: ~4
Final result stage: 1
Rough total: ~10–12 stages
```

Always verify in the Spark UI DAG Visualization — stage boxes connected by arrows, shuffle boundaries as the arrows between boxes.

---

## Part 3 — Tasks

### What Is a Task?

A **Task** is the smallest execution unit. One task is created per partition per stage. Tasks within a stage execute the same function on different data partitions, ideally in parallel across the cluster.

```
Stage with 500 input partitions → 500 tasks
Post-shuffle stage with shuffle.partitions=200 → 200 tasks
```

### Task Types

**`ShuffleMapTask`:**
- Computes a partition of a `ShuffleMapStage`
- Writes output to local disk as shuffle files (one FileSegment per reducer partition)
- Returns a `MapStatus` (BlockManagerId + sizes of each shuffle block) to the driver
- M map tasks × R reducer partitions = M × R total shuffle files

**`ResultTask`:**
- Computes a partition of a `ResultStage`
- Either returns data to the driver (for `collect`, `count`) or writes to external storage
- No shuffle output written

### Task Serialization

Before running on an executor, task code must be serialized and shipped from the driver. Spark broadcasts the serialized "task binary" to executors (using a `BroadcastVariable` internally). Each executor deserializes it at the start of `runTask()`.

```python
# Default serializer: Java serialization (slow)
# Better: Kryo (faster, smaller binary)
spark.conf.set("spark.serializer", "org.apache.spark.serializer.KryoSerializer")
```

All objects captured in closures must implement `Serializable`. A `NotSerializableException` during deserialization fails the task immediately — check for captured Python objects, database connections, or non-serializable classes.

Deserialization time is visible in the Spark UI Stage Detail as "Task Deserialization Time." Spikes here mean the task closure is too large (e.g., accidentally broadcasting a large Python object).

### Task Locality Levels

TaskScheduler tries to assign tasks to executors where their input data lives. Locality levels from best to worst:

| Level | Data Location | Network Cost |
|-------|-------------|--------------|
| `PROCESS_LOCAL` | Same JVM (executor) | None — in-memory |
| `NODE_LOCAL` | Same physical node, different JVM | IPC only |
| `NO_PREF` | No locality preference (e.g., generated data) | Neutral |
| `RACK_LOCAL` | Same rack, different node | Intra-rack network |
| `ANY` | Anywhere in cluster | Full network hop |

Before degrading to a worse locality level, Spark waits `spark.locality.wait` (default **3 seconds** per level). This avoids shipping tasks to far executors, but can add latency in micro-batch streaming. Reduce for streaming workloads:

```python
spark.conf.set("spark.locality.wait", "1s")   # faster dispatch for streaming
```

### Task Attempt Numbers

- Each task starts at attempt 0
- On failure and retry: attempt 1, 2, etc.
- `TaskContext.get().attemptNumber()` returns the retry count (0 = first try)
- `TaskContext.get().taskAttemptId()` returns the globally unique attempt ID (monotonically increasing)

Speculative duplicate tasks are killed when the original or another duplicate succeeds first — killed speculative tasks do NOT count as task failures.

### Task Failure and Retry

`spark.task.maxFailures` (default **4**): Max failures per partition before the stage is aborted.

```python
spark.conf.set("spark.task.maxFailures", "4")   # default

# In local mode (local[N]): always 1, cannot be changed
# If you see a stage failing after 4 attempts, the root cause must be fixed
```

Important: `maxFailures` counts failures for a **specific partition** (across all stage re-attempts), not globally. If 3 different tasks each fail once, no stage failure is triggered — only if the same partition fails 4 times.

**Shuffle retry config (for FetchFailedException):**
```python
spark.conf.set("spark.shuffle.io.maxRetries", "3")    # default
spark.conf.set("spark.shuffle.io.retryWait", "5s")    # default
```

---

## Part 4 — Input Partitions vs. Shuffle Partitions

These are two completely different concepts that are frequently confused.

### Input Partitions (Read-Side)

Created when Spark reads file-based sources. Controlled by:

```python
spark.conf.set("spark.sql.files.maxPartitionBytes", str(128 * 1024 * 1024))  # 128 MB default
spark.conf.set("spark.sql.files.openCostInBytes", str(4 * 1024 * 1024))      # 4 MB default
```

**Formula:** Spark packs files into partitions, targeting `maxPartitionBytes` per partition. Multiple small files can be packed into one partition (using `openCostInBytes` to account for file-open overhead). A large file is split at block boundaries (always respecting row group boundaries for Parquet).

```
31 × 330 MB Parquet files → each file spans ~3 HDFS blocks → 93 input partitions
54 × 40 MB files → multiple files packed per partition → ~18 input partitions
```

**Parquet nuance:** A Parquet row group (default 128 MB) always belongs entirely to one input partition. If row groups are larger than `maxPartitionBytes`, some partitions will be oversized. Creating more partitions than row groups produces empty partitions.

### Shuffle Partitions (Post-Shuffle)

Created after any wide transformation (groupBy, join). Controlled by:

```python
spark.conf.set("spark.sql.shuffle.partitions", "200")   # default — often wrong
```

Completely **independent** of input partition count. A 1 TB dataset split into 10,000 input partitions will produce 200 post-shuffle partitions by default — potentially 5 GB each.

**Without AQE — sizing rule:**
```
target partition size: 100 MB – 200 MB
total post-shuffle data: 500 GB
shuffle partitions needed: 500 GB / 150 MB ≈ 3,333

spark.conf.set("spark.sql.shuffle.partitions", "3000")
```

### AQE Partition Coalescing

Since Spark 3.2, AQE is on by default and **automatically coalesces small shuffle partitions**:

```python
# AQE enabled by default
spark.conf.get("spark.sql.adaptive.enabled")  # "true"

# Key settings
spark.conf.set("spark.sql.adaptive.advisoryPartitionSizeInBytes", "128m")   # target size
spark.conf.set("spark.sql.adaptive.coalescePartitions.enabled", "true")     # default
spark.conf.set("spark.sql.adaptive.coalescePartitions.minPartitionNum",      # floor
               str(spark.sparkContext.defaultParallelism))
```

**Critical constraint:** AQE can only **reduce** partition count, never increase it. If you set `shuffle.partitions=50` but need 300, AQE cannot help.

**Best practice with AQE:** Set `shuffle.partitions` **high** (e.g., 1000–2000) and let AQE coalesce down to the right number based on actual data sizes.

```python
# Without AQE
spark.conf.set("spark.sql.shuffle.partitions", "500")   # sized for your data

# With AQE (default)
spark.conf.set("spark.sql.shuffle.partitions", "2000")  # set high; AQE coalesces to ~50 if data is small
```

In the Spark UI, AQE coalescing shows as `CustomShuffleReader` in the SQL tab plan and as fewer tasks than expected in the Stages tab.

---

## Part 5 — ShuffleMapTask Lifecycle (Detailed)

Understanding the full task lifecycle explains what the Spark UI metrics measure:

1. **Receive task binary** — serialized closure broadcast from driver to executor
2. **Deserialize** — `runTask()` instantiates closure serializer; deserializes `(RDD, ShuffleDependency)`. Measured as "Task Deserialization Time" in Stage Detail.
3. **Compute** — `rdd.iterator()` applies all pipelined narrow transformations in the stage to the partition's records
4. **Partition output** — `partitioner.partition(record.key)` assigns each record to a reducer partition (0 to R-1)
5. **Write shuffle output** — `ShuffleWriter` writes to local disk. Three implementations:
   - `BypassMergeSortShuffleWriter`: one file per reducer, no sorting. Fast for small partitions.
   - `UnsafeShuffleWriter`: serialized records directly, tungsten-optimized, sorted by partition ID.
   - `SortShuffleWriter`: general case, sorts by partition key + sort key.
6. **Produce MapStatus** — `ShuffleWriter.stop(success=true)` returns `MapStatus` containing `BlockManagerId` and estimated size of each shuffle block
7. **Report to driver** — `MapStatus` sent to `MapOutputTrackerMaster`; DAGScheduler checks if all partitions of the stage are now complete

### ResultTask Shuffle Read Step

After the upstream `ShuffleMapStage` completes, `ResultTask` (or downstream `ShuffleMapTask`) reads shuffle data:

1. Consults `MapOutputTrackerWorker` for locations of needed shuffle blocks
2. `ShuffleBlockFetcherIterator` fetches blocks from remote and local `BlockManager`s concurrently
3. Spark **starts processing records before all fetches are complete** — fetch and compute overlap
4. "Shuffle Read Blocked Time" in Stage Detail = time waiting for slow fetches

---

## Part 6 — Speculative Execution

### What It Is

When some tasks in a stage run much slower than others (straggler tasks), Spark launches **duplicate copies** of those tasks on different executors. Whichever copy finishes first wins; the other is killed. The kill does NOT count as a task failure.

Speculation does NOT stop the original slow task — it races alongside it.

### When It Triggers

A background thread runs every `spark.speculation.interval` (default 100ms). A task is speculated when ALL of the following are true:

1. At least `spark.speculation.quantile` (default **75%**) of the stage's tasks have **already completed**
2. The task's running time exceeds `spark.speculation.multiplier` (default **1.5×**) × median running time of completed tasks
3. The task has not yet completed

So: once 75% done, any remaining task taking >1.5× the median gets a speculative copy.

### Configuration

```python
spark.conf.set("spark.speculation", "true")                  # disabled by default
spark.conf.set("spark.speculation.interval", "100ms")        # check frequency
spark.conf.set("spark.speculation.multiplier", "1.5")        # slowness threshold
spark.conf.set("spark.speculation.quantile", "0.75")         # % complete before checking
```

### Caveats

- **Safe only for idempotent operations.** Two copies writing to a database = duplicate inserts. Two copies writing Parquet = file-level overwrite (generally safe if using unique task output paths).
- **Does NOT cure data skew.** If one partition has 100× more records, the speculative copy on a new executor runs the same 100× partition. Same data = same duration. Fix skew instead.
- **Consumes extra resources.** On a heavily loaded cluster, duplicate tasks worsen resource contention.

---

## Part 7 — Failure Mode Reference

### Task Failure

```
Task X in stage Y.Z failed N times:
Lost task X.N in stage Y.Z (TID nnn, host, executor N):
java.lang.OutOfMemoryError: Java heap space
```

- Failed N times: N is the attempt count for that specific partition
- When N reaches `spark.task.maxFailures` (default 4): stage is aborted
- Common failure types: OOM (heap too small), serialization error (non-serializable closure), disk-full, network timeout

### Stage Failure

Stage is aborted when any task for the same partition exhausts retries. DAGScheduler calls `abortStage()` → all jobs depending on this stage receive `JobFailed`.

**Special case — FetchFailedException:**
Not counted as a task failure. Instead, DAGScheduler:
1. Marks lost map outputs as unavailable
2. Reschedules the upstream ShuffleMapStage (new attempt number)
3. Pauses the failed downstream stage until upstream re-completes

This is Spark's recovery mechanism for lost executors mid-job.

### Job Failure

Driver-side `JobWaiter` receives failure → `SparkContext.runJob()` throws `SparkException: Job aborted due to stage failure`. The calling action propagates the exception to user code.

---

## Quick Reference

| Concept | Key Facts |
|---------|---------|
| **Job** | 1 per action; ID assigned atomically by `nextJobId`; visible in UI Jobs tab |
| **ShuffleMapStage** | Writes shuffle files to local disk; tracked by `MapOutputTrackerMaster` |
| **ResultStage** | Terminal stage; exactly 1 per job; returns result or writes to sink |
| **Stage attempt** | Increments on FetchFailed or ExecutorLost |
| **Skipped stage** | Gray in Spark UI; shuffle output reused from prior job or cache |
| **Task** | 1 per partition per stage; `ShuffleMapTask` or `ResultTask` |
| **Task serialization** | Closure broadcast to executor; all captures must be `Serializable` |
| **Locality wait** | 3s per level before degrading; reduce to 1s for streaming |
| **Task max failures** | Default 4; 1 in local mode |
| **Input partitions** | `spark.sql.files.maxPartitionBytes` = 128 MB default; based on file size |
| **Shuffle partitions** | `spark.sql.shuffle.partitions` = 200 default; set high when using AQE |
| **AQE coalescing** | Reduces shuffle partitions post-execution; cannot increase |
| **Speculation** | Disabled by default; not a cure for data skew |
| **groupBy stage count** | ~2 stages (map-side partial agg + shuffle + final agg) |
| **SortMergeJoin stage count** | ~2 stages per join (shuffle both sides) |
| **BroadcastHashJoin stage count** | ~1 stage (no shuffle on small side) |

*See also: [02-lazy-evaluation-and-dag.md](02-lazy-evaluation-and-dag.md) for DAG basics | [26-explain-deep-dive.md](26-explain-deep-dive.md) for reading physical plans | [28-spark-ui-debugging.md](28-spark-ui-debugging.md) for Spark UI diagnostics*
