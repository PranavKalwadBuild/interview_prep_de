<!-- PySpark-patterns: Spark UI Debugging Deep Dive -->

# Spark UI Debugging — Every Tab, Every Metric

## Access

| Where | URL / How |
|-------|-----------|
| Live application | `http://<driver-host>:4040` (4041, 4042... if multiple apps on same machine) |
| Databricks | Cluster page → Spark UI link; persists after cluster termination |
| Completed applications | History Server at `http://<history-server>:18080` |

**Enable history logging** (required for post-mortem debugging):
```python
spark.conf.set("spark.eventLog.enabled", "true")
spark.conf.set("spark.eventLog.dir", "s3://my-bucket/spark-events/")  # or hdfs://...
# Start history server: $SPARK_HOME/sbin/start-history-server.sh
```

**Debugging pattern:** Jobs → Stages → Stage Detail → cross-reference with Executors.

---

## 1. Jobs Tab

### What Each Column Tells You

| Column | What to Check |
|--------|--------------|
| **Job ID** | Auto-incrementing. Primary key for cross-referencing with logs. |
| **Description** | Action name + source file + line number (e.g., `count at pipeline.py:47`). Click to open Job Detail. This is how you map a slow job back to the line that triggered it. |
| **Submitted** | Absolute timestamp. Correlate with external system logs. |
| **Duration** | Wall-clock time. Sort descending to find the slowest job. |
| **Stages: N/M** | N succeeded out of M total. If N < M, at least one stage failed or is running. |
| **Tasks: N/M** | Aggregate across all stages. High failure ratio even if job succeeded = thrashing (tasks failing and retrying). |

### What to Look For

**Too many jobs with the same description:** Classic `count()` in a loop. The description text and source line number will be identical across dozens of jobs. Fix: replace the loop with a single grouped aggregation.

```python
# BAD — produces N jobs in the UI
for date in dates:
    n = df.filter(F.col("dt") == date).count()  # 1 job per date

# GOOD — 1 job, same description once in the UI
df.groupBy("dt").count().show()
```

**Long gap between jobs (Event Timeline view):** Gap indicates driver-side Python computation between Spark actions, or a very slow action (e.g., `toPandas()` on large data). The Event Timeline at the top of the Jobs tab shows job overlaps as a Gantt chart — look for large gray gaps.

**Failed jobs (red row):** Click description → Job Detail → look for the red stage → click that stage's description for the failure reason.

**Unexpected extra job at the start:** Usually caused by schema inference:
```python
# fires an implicit job to sample files for schema inference
df = spark.read.option("inferSchema", "true").json("/data/")

# fix: provide explicit schema
schema = StructType([StructField("id", LongType()), ...])
df = spark.read.schema(schema).json("/data/")
```

---

## 2. Stages Tab

### What Each Column Tells You

| Column | What to Check |
|--------|--------------|
| **Stage ID** | Auto-incrementing across the app lifetime. |
| **Description** | Operation + source location that produced the stage boundary (e.g., `hashaggregate at GroupBy.py:34`). |
| **Duration** | Sort descending to find the bottleneck stage. |
| **Input** | Bytes read from HDFS/S3/local per stage. High mid-pipeline = predicate pushdown not working. |
| **Output** | Bytes written to external storage. Usually only the final write stage is non-zero. |
| **Shuffle Read** | Bytes received over network from upstream shuffle. High = expensive shuffle; consider broadcast join. |
| **Shuffle Write** | Bytes written to local disk for downstream shuffle. `ShuffleWrite(stage N)` ≈ `ShuffleRead(stage N+1)`. |
| **Tasks** | Total tasks for this stage. For shuffle stages this is `spark.sql.shuffle.partitions`. |

### Identifying the Bottleneck Stage

Sort by Duration descending. The top row is your target. Then cross-check:

- **High Shuffle Read, low Input:** Dominated by cross-network data movement. Can this join be broadcast? Is there data skew in the shuffle output?
- **High Input, moderate Shuffle Read:** Scan-bound. Did predicate pushdown work? Use `explain(mode="formatted")` to check `PushedFilters`.
- **Shuffle Write >> Shuffle Read of the next stage:** The stage is producing more output than expected. Look for an accidental Cartesian product (missing join condition) or a `groupBy` that explodes cardinality.

### Skipped Stages

Grayed-out rows labeled "(skipped)" in the DAG Visualization = stage output reused from cache or a prior job's shuffle. This is good. If a stage you expected to be skipped is running, check the Storage tab: the cache may have been evicted due to memory pressure.

### Stage Failure and Retry

Red row = stage failed. Look at the Stage Detail → Tasks table → Error column for the failure reason. Patterns:
- All failures on the same executor → node-level problem (OOM, disk, network)
- Failures spread across executors → data-level problem (bad record, serialization error, schema mismatch)
- Attempt numbers climbing to 3–4 → about to hit `spark.task.maxFailures`; root cause must be fixed

---

## 3. Stage Detail Page (The Most Important Page)

Accessed by clicking a stage description. This is where you spend most debugging time.

### Summary Metrics Table

Shows each task metric at 5 percentiles: Min, 25th, Median, 75th, Max. Reading the spread tells you whether the stage is balanced or skewed.

**Healthy distribution:** Min ≈ 25th ≈ Median ≈ 75th ≈ Max. All tasks doing roughly equal work.

**Skew signals:**
- Max > 1.5× 75th percentile → mild skew, monitor
- Max > 3× 75th percentile → moderate skew, investigate
- Max > 10× Median → **severe skew**; the cluster sits idle while one task runs

### Key Metrics in the Summary Table

| Metric | Healthy | Red Flag |
|--------|---------|---------|
| **Duration** | Max ≈ 75th percentile | Max >> 75th → skew or straggler |
| **Scheduler Delay** | < 100ms | Seconds → driver bottleneck or undersized cluster |
| **Task Deserialization Time** | Milliseconds | Seconds → task closure is too large; broadcasting large Python objects unintentionally |
| **GC Time** | < 5% of Duration | > 10% of Duration → **red row** in UI → memory pressure |
| **Result Serialization Time** | Milliseconds | Seconds → tasks returning too much data to driver (reduce `collect()` size) |
| **Input Size** | Roughly equal across tasks | Max >> Median → data source is unevenly partitioned |
| **Shuffle Read Size** | Roughly equal | Max >> Median → shuffle output is skewed (check join key cardinality) |
| **Shuffle Read Blocked Time** | < 100ms | Seconds → network congestion or slow executor holding up shuffle fetch |
| **Spill (Memory)** | 0 | Any non-zero → task exceeded execution memory |
| **Spill (Disk)** | 0 | Any non-zero → data written to disk; 10–100× slower than memory |
| **Peak Execution Memory** | Baseline | Sudden spike → large data structure in task (collect_list, cross join) |

### Enable Additional Metrics

In Stage Detail, click "Show Additional Metrics" to reveal: Input Size/Records, Shuffle Read/Write Size/Records, Shuffle Read Blocked Time, Spill (Memory), Spill (Disk), Peak Execution Memory.

### Diagnosing Data Skew from Stage Detail

```
Summary Metrics:
  Duration:     Min=1.2s  25th=2.1s  Median=2.3s  75th=2.5s  Max=4m 12s
  Shuffle Read: Min=45MB  25th=62MB  Median=65MB  75th=68MB  Max=8.2GB
```

Max Duration is 100× the Median. Max Shuffle Read is 126× the Median. This partition received 8.2 GB while others got ~65 MB — one join key has an enormous number of rows.

**Fix options:**
1. AQE skew join (automatic, requires `spark.sql.adaptive.skewJoin.enabled=true`)
2. Broadcast the smaller side if possible
3. Manual salting — add a random suffix to the skew key before join, strip after aggregation
4. Pre-aggregate the skewed key to reduce cardinality before joining

### Diagnosing Shuffle Spill from Stage Detail

```
Summary Metrics:
  Spill (Memory): Min=0  25th=0  Median=4.2GB  75th=6.1GB  Max=12.8GB
  Spill (Disk):   Min=0  25th=0  Median=410MB  75th=590MB  Max=1.2GB
```

`Spill (Memory) / Spill (Disk)` ≈ 10:1 = 10:1 compression ratio (good, data compresses well).
When this ratio approaches 1:1, the spilled data is incompressible (random strings, pre-compressed bytes) — disk I/O penalty is the full uncompressed size.

**Fix options:**
- Increase `spark.sql.shuffle.partitions` → smaller partitions → each task fits in memory
- Increase `spark.executor.memory`
- Fix upstream skew that sent too much data to one partition
- Pre-aggregate before the shuffle to reduce data volume

### Diagnosing GC Pressure from Stage Detail

```
Summary Metrics:
  Duration: Median=45s  Max=3m 20s
  GC Time:  Median=12s  Max=2m 8s       ← 63% of Max Duration is GC!
```

GC Time > 10% of Duration = executor heap too small for this workload. The UI highlights the row in **red** automatically.

**GC death spiral (extreme case):** GC duration exceeds `spark.executor.heartbeatInterval` (default 10s). Driver declares executor dead, reschedules its tasks. New tasks inherit the same heap pressure → same GC → same timeout → cascade of executor deaths.

**Fix options:**
```python
# 1. More executor memory
spark.conf.set("spark.executor.memory", "16g")   # up from 8g

# 2. Fewer concurrent tasks per executor (less heap pressure per task)
spark.conf.set("spark.executor.cores", "2")       # down from 4

# 3. G1GC instead of default GC (better for large heaps)
spark.conf.set("spark.executor.extraJavaOptions",
               "-XX:+UseG1GC -XX:+G1SummarizeRStrings")

# 4. More memory for execution (less for storage)
spark.conf.set("spark.memory.storageFraction", "0.3")   # down from 0.5
```

### Event Timeline View

Each task is a horizontal bar, color-coded by phase:
- **Green:** Compute time
- **Blue:** Shuffle write
- **Orange:** Shuffle read
- **Yellow:** Deserialization
- **Red:** GC time
- **Gray:** Scheduler delay (queued before execution)

**What to look for:**
- **Long bar at the end, all others done:** Visual signature of skew — one task runs while the cluster sits idle
- **All bars heavy in orange (shuffle read):** Network-bound; high Shuffle Read Blocked Time
- **All bars heavy in red (GC):** Memory pressure across all executors
- **Short bars with long gray prefix:** Too many tasks for available cores — task dispatch queue building up

### Tasks Table

Below the summary, the Tasks table shows every individual task. Click column headers to sort. Useful columns:

| Column | Use |
|--------|-----|
| **Duration** | Sort descending to find the slowest task. Click the task ID for full details. |
| **Attempt** | Attempt 0 = first try. Attempt 1+ = retry. High attempt counts = thrashing. |
| **Locality** | PROCESS_LOCAL is best. ANY = worst locality, data shipped across cluster. |
| **Input Size** | Per-task data read from storage. Uneven = source partitioning problem. |
| **Shuffle Read Size** | Per-task shuffle data received. Uneven = downstream skew. |
| **Spill (Memory)** | Non-zero = this task spilled to disk. |
| **GC Time** | Per-task GC. Isolated high GC = one partition OOM-ing; uniform high GC = global memory pressure. |
| **Errors** | Click the error icon for the full stack trace of a failed task. |

---

## 4. SQL Tab (DataFrames and Spark SQL)

### Overview

Lists all DataFrame/SQL queries executed by this application. Each row shows: description, submission time, duration, jobs generated.

Click a query → **Query Detail page**: the physical plan as an interactive DAG visualization.

### Query Plan Visualization

Operators are drawn as nodes; data flows **bottom to top**. Edges carry row counts and data sizes.

**Node colors:**
- **Blue:** Standard Spark SQL operators
- **Orange/peach (Databricks + Photon):** Photon-accelerated operators (C++ engine)

**Node metrics shown inline:**
- Output rows
- Data size
- Time in this operator
- Spill size (if any)

**Edges:** Row counts and byte sizes between operators. A sudden explosion in rows between two operators = accidental Cartesian product or many-to-many join. A sudden collapse = highly selective filter or aggregation.

### WholeStageCodegen Blocks

Operators in a dashed box labeled `WholeStageCodegen (N)` are fused into one generated Java function. This is good — fewer virtual dispatch calls, better CPU cache utilization. The `(N)` is the codegen stage ID.

**Code gen breaks at:** `Exchange`, `WindowExec`, Python UDFs, certain complex aggregations. Each break is visible as a separate box in the DAG. Fewer, larger codegen blocks = more efficient query.

### Exchange Nodes in the SQL Tab

Each `Exchange` node = one shuffle = one stage boundary. The metrics on an Exchange node show:
- Rows and bytes flowing through
- Post-execution: actual vs. estimated rows (estimation error visible here)

If actual rows >> estimated rows on an Exchange, statistics are stale → AQE may have compensated, or the downstream plan was suboptimal.

### AQE in the SQL Tab

With AQE on (default since Spark 3.2):

- `AQEShuffleRead` nodes: Post-shuffle partition coalescing happened. Where you had 200 shuffle partitions, AQE merged them to fewer because data was small.
- `BroadcastHashJoin` replacing what would have been `SortMergeJoin`: AQE detected mid-execution that one side was below the broadcast threshold.
- The plan **changes after stages complete** — the SQL tab shows the evolving plan.

Click **"Details"** at the bottom of the Query Detail page for text representations of: logical plan, initial physical plan, and final physical plan. Compare initial vs. final to see exactly what AQE changed.

---

## 5. Storage Tab

### What It Shows

Lists all currently **materialized** cached DataFrames and RDDs. A cache entry only appears after the cache is populated — `.cache()` is lazy; data is written to cache on the first action that touches it.

### Key Columns

| Column | What to Check |
|--------|--------------|
| **Storage Level** | `MEMORY_AND_DISK` = default for `.cache()`. `MEMORY_ONLY` = no spill to disk. `MEMORY_ONLY_SER` = serialized bytes (smaller footprint, slower reads). |
| **Cached Partitions** | Number of partitions currently in cache. |
| **Fraction Cached** | `Cached / Total`. < 100% = some partitions missing from cache. |
| **Size in Memory** | Bytes across all executors in heap (or off-heap). |
| **Size on Disk** | Non-zero for `MEMORY_AND_DISK` when partitions overflowed to executor local disk. |

### Diagnosing Incomplete Caches

**Fraction Cached < 100%:** Two causes:
1. DataFrame was never fully materialized (no action forced all partitions through the cache): `df.cache(); df.count()` — the `count()` is required to populate the cache.
2. Memory pressure evicted partitions. Spark uses LRU: when execution memory (shuffles, aggregations) needs space, it evicts the least-recently-used cached partitions.

Check total storage memory across executors in the Executors tab. If "Storage Memory Used ≈ Total Storage Memory," the cache is under pressure.

**Size on Disk > 0 with `MEMORY_AND_DISK`:** Partitions spilled to local disk. On next access, Spark reads from disk (10–100× slower than memory). Fix: increase executor memory, or switch to `MEMORY_ONLY_SER` to reduce memory footprint.

```python
from pyspark import StorageLevel

# Default (MEMORY_AND_DISK)
df.cache()

# Smaller memory footprint (serialized)
df.persist(StorageLevel.MEMORY_AND_DISK_SER)

# Off-heap (requires spark.memory.offHeap.enabled=true)
df.persist(StorageLevel.OFF_HEAP)

# Always unpersist when done to free memory
df.unpersist()
```

**Click the RDD name** → per-executor breakdown showing which partitions are on which executor. Skewed caching (one executor holds 70%) = data was not evenly distributed before caching, or that executor had less eviction pressure.

---

## 6. Executors Tab

### What Each Column Tells You

| Column | What to Check |
|--------|--------------|
| **Executor ID / Address** | `host:port` of the executor JVM. Use this to find container logs in YARN/K8s. |
| **State** | Active or Dead. Dead executors stay in table for post-mortem. |
| **Storage Memory** | `used / total`. Used ≈ total = memory pressure; cached partitions being evicted. |
| **Disk Used** | Local disk for cached partitions + shuffle files. Growing = risk of disk-full failures. |
| **Active Tasks** | Currently running tasks. Should be ≤ `spark.executor.cores`. Consistently lower = underutilized. |
| **Failed Tasks** | Tasks that failed on this executor (all time). Climbing on one executor while others are zero = unhealthy node. |
| **Task Time (GC Time)** | Total task time with GC in parentheses. **Red row** if GC > 10% of task time. |
| **Shuffle Read** | Total bytes received over network. |
| **Shuffle Write** | Total bytes written to local disk for shuffle. |
| **Logs** | Links to `stderr` / `stdout` of the executor container. Fastest path to OOM stack traces. |
| **Thread Dump** | Click for live JVM thread dump. Shows what a hanging task is actually waiting on. |

### Diagnosing from the Executors Tab

**All executors have red GC highlighting:** Global memory pressure — executor heap too small. Increase `spark.executor.memory`.

**One executor failing while others succeed:** Node-level problem. Check its `stderr` log. If the address is unreachable, it's a network partition. If it shows `OutOfMemoryError`, that specific node has less available memory (competing processes, smaller instance type).

**Uneven Active Tasks:** If all cores are constantly busy on some executors but low on others, data locality is concentrating too much work on a few nodes. Or there's speculation running and duplicate tasks are filling slots on fast executors.

**Rapidly climbing Failed Tasks on one executor:** About to be blacklisted (excluded). Spark excludes an executor after `spark.excludeOnFailure.taskExcludeOnFailure.maxTaskFailures` (default 2 per stage). When excluded, all its tasks migrate — other executors' Active Tasks spike temporarily.

**Checking input balance:** Sort by Input descending. For a scan-heavy job, all executors should have similar Input values. A 10:1 ratio confirms unbalanced source data (one file much larger, or partitioned on a skewed key).

---

## 7. Environment Tab

### What It Shows

Authoritative configuration state of your running application. Five sections:

1. **Runtime Information:** Java version, Scala version, Spark version
2. **Spark Properties:** All `spark.*` settings **explicitly set** (not defaults). Absence = using default.
3. **Hadoop Properties:** HDFS/YARN settings
4. **System Properties:** JVM `-Dkey=value` arguments
5. **Classpath Entries:** Every JAR loaded, in order (diagnose `ClassNotFoundException`, version conflicts)

### Verifying Config Changes Took Effect

This tab is the ground truth. If you submitted with `--conf spark.sql.shuffle.partitions=500` but the tab shows `200`, something overrode your value (a `SparkConf.set()` in code, cluster policy, or the property wasn't properly passed).

Key properties to verify:
```
spark.sql.shuffle.partitions          → should match your tuning
spark.sql.adaptive.enabled            → verify AQE on/off
spark.sql.autoBroadcastJoinThreshold  → verify broadcast threshold
spark.executor.memory                 → actual allocated memory
spark.executor.cores                  → task concurrency per executor
spark.eventLog.enabled                → confirm logging for history server
spark.serializer                      → confirm Kryo if enabled
```

---

## 8. Key Debugging Workflows

### "The Query Is Slow"

```
1. Jobs tab → sort by Duration → find the slow job → click description
2. Job Detail → Stages list → sort by Duration → find bottleneck stage
3. Stage Detail → Summary Metrics:
   - Max Duration >> 75th? → skew
   - Spill > 0? → memory too small
   - GC Time > 10%? → memory pressure
4. Stage Detail → Event Timeline:
   - One long bar after all others finish → skew confirmation
   - All bars heavy in red → GC across the board
5. SQL tab → find corresponding Exchange/Join node → check row counts on edges
```

### "Out of Memory"

```
1. Jobs tab → failed job (red) → click description
2. Job Detail → find red/failed stage
3. Executors tab → look for Dead executor → click stderr
   - "Java heap space" → increase spark.executor.memory
   - "GC overhead limit exceeded" → same cause, earlier warning
   - "Direct buffer memory" → increase spark.executor.memoryOverhead
   - "Container killed on request. Exit code 143" → YARN container limit exceeded
     → increase spark.executor.memoryOverhead or total memory
4. Storage tab → large cached DataFrame consuming storage memory?
   → unpersist it or reduce storage footprint
5. Stage Detail → large Spill values?
   → spill is a precursor to OOM; fix it before the task fails completely
```

**OOM type → fix mapping:**
```python
# Java heap space → executor heap too small
spark.conf.set("spark.executor.memory", "16g")

# Direct buffer memory → off-heap / netty buffer too small
spark.conf.set("spark.executor.memoryOverhead", "4g")

# Metaspace → JVM class metadata exhausted
spark.conf.set("spark.executor.extraJavaOptions",
               "-XX:MaxMetaspaceSize=512m")

# Driver OOM (collect() too large, broadcast too large)
spark.conf.set("spark.driver.memory", "8g")
spark.conf.set("spark.driver.maxResultSize", "4g")
```

### "Shuffle Read Is Huge"

```
1. Stages tab → identify stage(s) with largest Shuffle Read column
2. SQL tab → find corresponding Exchange node → check edge metrics
   - Rows on edge >> expected? → missing filter, Cartesian product, or many-to-many join
3. Is one side of the join small? → force broadcast join
   → large_df.join(F.broadcast(small_df), "key")
   → spark.conf.set("spark.sql.autoBroadcastJoinThreshold", str(200 * 1024 * 1024))
4. Stage Detail → Shuffle Read per task: is it skewed?
   - Max >> Median → skew in join key; enable AQE skew join or salt the key
5. Shuffle partition count:
   - Many tiny tasks (< 1MB each) → AQE coalescing not working → check AQE settings
   - Few huge tasks (> 1GB each) → need more shuffle partitions → increase shuffle.partitions
```

### "Many Failed Tasks"

```
1. Stage Detail → Tasks table → Error column
   - FetchFailedException → upstream executor died holding shuffle files
     → Executors tab → find Dead executor → check stderr → likely OOM or disk-full
   - OutOfMemoryError in task → reduce partition size or increase memory
   - NotSerializableException → captured non-serializable object in closure
     → check what your Python UDF or lambda is capturing
   - TaskKilled: another attempt succeeded → normal speculative execution, not an error
   - ClassCastException / schema mismatch → check source schema vs. expected schema
2. Same executor failing repeatedly?
   → Node-level problem (hardware, network)
   → Check cluster-level metrics (Ganglia or Databricks Cluster Metrics)
3. Attempt numbers at 3 or 4?
   → About to hit spark.task.maxFailures → job will fail on next failure
   → Fix root cause now; increasing maxFailures is only for transient infrastructure issues
```

---

## 9. Databricks-Specific Features

### Photon in the SQL Tab

Photon is Databricks' native vectorized engine (C++). In the SQL tab:
- **Orange/peach nodes** = Photon operators (`PhotonGroupingAgg`, `PhotonSortMergeJoin`, `PhotonScan`, etc.)
- **Blue nodes** = standard JVM Spark operators
- **"Task Time in Photon"** percentage at the bottom of Query Detail = fraction of CPU in Photon

If a query falls back from Photon to JVM, it's usually because: Python UDF in the plan, unsupported aggregate function, or an unsupported data type. Check the non-orange nodes to identify the fallback point.

If a job fails with Photon but succeeds without it, disable Photon for that cluster temporarily to isolate:
```python
spark.conf.set("spark.databricks.photon.enabled", "false")
```

### Cluster Metrics (Databricks Runtime 13.0+)

Accessed from: Compute → [cluster] → Metrics tab. Replaces Ganglia. Shows per-node:
- CPU utilization (all workers should be ~100% during active compute)
- Container memory (reclaimable + page cache + configured limit)
- JVM heap usage (actual + capacity + max)
- Network bytes received/transmitted
- Free filesystem space (**critical: if this hits 0, shuffle writes fail → FetchFailedException**)

**Cluster Metrics vs. Spark UI:**

| Scope | Cluster Metrics | Spark UI |
|-------|----------------|---------|
| Hardware saturation | ✓ | ✗ |
| Disk-full detection | ✓ | ✗ |
| Task-level breakdown | ✗ | ✓ |
| Skew/spill diagnosis | ✗ | ✓ |
| GC per executor | ✓ (JVM heap chart) | ✓ (GC time column) |
| Historical retention | 30 days | Per-app event log only |

Use Cluster Metrics to answer "is the hardware saturated?" Use Spark UI to answer "which specific operation is causing it and why?"

---

## 10. History Server

The Spark UI at port 4040 disappears when the application stops. The History Server replays event logs to recreate the UI for completed (or failed) applications.

**Setup:**
```
# spark-defaults.conf
spark.eventLog.enabled=true
spark.eventLog.dir=hdfs:///spark/events
spark.history.fs.logDirectory=hdfs:///spark/events
spark.history.fs.cleaner.enabled=true
spark.history.fs.cleaner.maxAge=7d

# For large applications, use rolling logs to avoid huge single files:
spark.eventLog.rolling.enabled=true
spark.eventLog.rolling.maxFileSize=128m
```

Start: `$SPARK_HOME/sbin/start-history-server.sh` → UI at `http://<host>:18080`

**What works in History Server:** All tabs (Jobs, Stages, SQL, Storage, Executors, Environment) are fully functional. The only missing feature is live thread dumps (JVMs no longer exist).

**What doesn't work:** Live updates (static replay). Thread dump button is disabled. Very large jobs with gigabytes of event logs may take time to parse.

**On Databricks:** History Server is managed automatically. Spark UI links remain accessible from the Jobs UI and Cluster UI after cluster termination. No setup needed.

---

## Quick Reference: Symptom → Location → Fix

| Symptom | Where to Look | Key Metric | Fix |
|---------|--------------|-----------|-----|
| Slow stage | Stages → Duration | Max Duration >> 75th | → Stage Detail |
| Data skew | Stage Detail → Summary Metrics | Max Input/Shuffle Read >> Median | Broadcast join, salt, AQE skew |
| Shuffle spill | Stage Detail → Spill columns | Spill (Memory) or Spill (Disk) > 0 | More partitions, more memory |
| GC pressure | Stage Detail / Executors | GC Time > 10% Duration (red) | Increase executor memory |
| Driver OOM | Jobs tab → error, Driver logs | `collect()` / broadcast too large | Add `.limit()`, increase driver memory |
| Executor OOM | Executors → stderr logs | Dead executor, OOM stack trace | Increase memory, fix skew |
| Broadcast OOM | SQL tab → BHJ node size | Unexpected large broadcast | Set `autoBroadcastJoinThreshold=-1` |
| Too many jobs | Jobs → Description | Same description + line repeated N times | Remove action from loop |
| Cache not working | Storage → Fraction Cached | < 100% | Check memory pressure; call `count()` after `cache()` |
| Config not applied | Environment → Spark Properties | Property absent or wrong | Check submission flags, SparkConf ordering |
| Huge shuffle read | SQL tab → Exchange node | Rows/bytes on edge > expected | Broadcast, increase partitions, fix Cartesian join |
| Many failed tasks | Stage Detail → Tasks → Error | FetchFailedException / OOM | Find dead executor; fix root cause |
| Slow streaming | Jobs → Event Timeline | Gaps between micro-batch jobs | Reduce locality wait, tune trigger interval |
| Completed job inaccessible | History Server (port 18080) | App in history list | Enable `spark.eventLog.enabled` |

*See also: [26-explain-deep-dive.md](26-explain-deep-dive.md) for reading query plans | [27-jobs-stages-tasks.md](27-jobs-stages-tasks.md) for execution model internals | [21-aqe-and-performance.md](21-aqe-and-performance.md) for AQE configuration*
