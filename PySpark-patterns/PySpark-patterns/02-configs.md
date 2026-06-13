# PySpark Configs — Scenario Reference

> Rule: set configs at SparkSession level for the job. Config priority:
> SparkSession.conf.set > spark-submit flags > spark-defaults.conf > hardcoded defaults
> Verify in Spark UI → Environment tab — the final resolved value is truth.

---

## AQE (Adaptive Query Execution) — Highest Leverage

Enable this first. AQE measures actual runtime statistics and re-optimizes mid-execution.

```python
spark.conf.set("spark.sql.adaptive.enabled", "true")                              # default true in 3.2+
spark.conf.set("spark.sql.adaptive.coalescePartitions.enabled", "true")           # merge small shuffle partitions
spark.conf.set("spark.sql.adaptive.coalescePartitions.parallelismFirst", "false") # respect size target, not max tasks
spark.conf.set("spark.sql.adaptive.advisoryPartitionSizeInBytes", "128m")         # target partition size after coalescing
spark.conf.set("spark.sql.adaptive.coalescePartitions.minPartitionSize", "32m")   # floor — never smaller than this
spark.conf.set("spark.sql.adaptive.localShuffleReader.enabled", "true")           # avoid network for local shuffle blocks
```

**Why `parallelismFirst=false`**: Default `true` maximizes task count (one task per original partition), ignoring `advisoryPartitionSizeInBytes`. Setting `false` lets AQE actually coalesce to target size.

**Why set `minPartitionSize=32m`**: Without this, AQE can coalesce to tiny 1 MB partitions, creating thousands of tasks with high scheduler overhead.

---

## Shuffle Tuning

```python
spark.conf.set("spark.sql.shuffle.partitions", "2000")
# Default is 200 — almost always wrong.
# With AQE: start high (2000+), AQE coalesces down to target size.
# Without AQE: target = shuffle_data_MB / 128. Never < total cluster cores.

spark.conf.set("spark.shuffle.file.buffer", "1m")           # default 32k — reduces disk I/O on shuffle write
spark.conf.set("spark.shuffle.compress", "true")            # compress shuffle blocks (default true)
spark.conf.set("spark.shuffle.spill.compress", "true")      # compress spilled data (default true)
```

**Sizing formula (without AQE)**:
```
target_partitions = max(
    shuffle_stage_output_bytes / (128 * 1024 * 1024),  # 128 MB per partition
    total_cluster_cores * 2                             # at least 2 tasks per core
)
```

**With AQE** (recommended): set `spark.sql.shuffle.partitions=2000`, set `advisoryPartitionSizeInBytes=128m`, let AQE coalesce.

---

## Join Strategy Configs

```python
# Auto-broadcast threshold
spark.conf.set("spark.sql.autoBroadcastJoinThreshold", str(50 * 1024 * 1024))   # 50 MB (default 10 MB)
# Raise carefully — driver must hold the broadcast table in memory

spark.conf.set("spark.sql.broadcastTimeout", "600")        # seconds; raise if broadcast times out for ~200 MB tables

spark.conf.set("spark.sql.join.preferSortMergeJoin", "true")  # default true — SMJ is always the safe fallback

# AQE-specific: allow AQE to convert SMJ → SHJ when post-shuffle partitions are small
spark.conf.set("spark.sql.adaptive.maxShuffledHashJoinLocalMapThreshold", "64m")
# 0 by default (disabled). SHJ has no spill — don't enable if partitions can exceed executor memory.
```

**Join hint priority** (code wins over configs):
```python
from pyspark.sql.functions import broadcast

# Explicit broadcast hint — highest priority
result = large_df.join(broadcast(small_df), "key")

# SQL hints
spark.sql("SELECT /*+ BROADCAST(dim) */ * FROM fact JOIN dim ON fact.id = dim.id")
spark.sql("SELECT /*+ MERGE(t1) */    * FROM t1 JOIN t2 ON t1.id = t2.id")   # force SMJ
spark.sql("SELECT /*+ SHUFFLE_HASH(t1) */ * FROM t1 JOIN t2 ON t1.id = t2.id") # force SHJ
```

**Decision tree**:
```
One side < autoBroadcastJoinThreshold?
  YES → BroadcastHashJoin (no shuffle, fastest)
  NO  → preferSortMergeJoin=false AND one side 3× smaller AND fits in memory?
          YES → ShuffledHashJoin (no sort, risky — no spill fallback)
          NO  → SortMergeJoin (default, robust, spills OK)

Non-equi join or cross join?
  → BroadcastNestedLoopJoin or CartesianProduct (almost always a bug at scale)
```

---

## Memory Management

```python
# spark-submit / cluster config (not runtime-settable)
# --executor-memory 16g
# --executor-cores 4
# --driver-memory 8g
# --conf spark.executor.memoryOverhead=4g   # for PySpark UDFs, Arrow, Python workers

# Runtime-settable
spark.conf.set("spark.memory.fraction", "0.6")          # 60% of heap for unified (execution + storage)
spark.conf.set("spark.memory.storageFraction", "0.5")   # 50% of unified = storage eviction floor
spark.conf.set("spark.memory.offHeap.enabled", "true")  # off-heap for Tungsten/Arrow (set before session starts)
spark.conf.set("spark.memory.offHeap.size", "4g")       # off-heap per executor
```

**Memory layout for 16 GB executor (defaults)**:
```
Total JVM heap:       16,384 MB
  Reserved:             300 MB  (hardcoded)
  Usable:            16,084 MB
    User memory (40%): 6,434 MB  — your data structures, UDF variables
    Unified (60%):     9,650 MB
      Storage (50%):   4,825 MB  — cache, broadcast
      Execution (50%): 4,825 MB  — shuffles, sort, hash tables
Total container:    ~17.6 GB   (add 10% overhead: 1.6 GB)
```

**Executor sizing rules**:
- 3–5 cores per executor is the sweet spot
- < 3 cores → overhead per executor is high
- > 5 cores → too many concurrent tasks competing for the same heap → GC pressure
- Fat executors (>32 GB heap) → long GC pause times → task timeouts

**OOM scenarios and fixes**:

| Scenario | Symptom | Fix |
|----------|---------|-----|
| Python worker OOM | Executor Dead, container killed by YARN/K8s | Increase `memoryOverhead` (not `executor.memory`) |
| JVM heap OOM | `java.lang.OutOfMemoryError: Java heap space` | Increase `executor.memory`, reduce `executor.cores` |
| Execution memory exhausted | Shuffle spill, GC pressure | Increase `memory.fraction`, more shuffle partitions |
| Storage evicts execution | Cache too large, execution spills | Reduce what you cache, or use `MEMORY_ONLY_SER` |

---

## AQE Skew Handling

```python
spark.conf.set("spark.sql.adaptive.skewJoin.enabled", "true")

# A partition is "skewed" when BOTH conditions are true:
spark.conf.set("spark.sql.adaptive.skewJoin.skewedPartitionFactor", "5.0")
# partition_size > factor × median_partition_size

spark.conf.set("spark.sql.adaptive.skewJoin.skewedPartitionThresholdInBytes", "256m")
# AND partition_size > this_threshold

# For subtler skew — lower both thresholds:
spark.conf.set("spark.sql.adaptive.skewJoin.skewedPartitionFactor", "3.0")
spark.conf.set("spark.sql.adaptive.skewJoin.skewedPartitionThresholdInBytes", "64m")

spark.conf.set("spark.sql.adaptive.forceOptimizeSkewedJoin", "false")
# Set true to force skew handling even when it adds extra shuffle cost
```

**How AQE skew join works**: Detects skewed partitions after shuffle. Splits the fat partition into sub-partitions and replicates the matching side of the join for each sub-partition. Transparent — no code change needed.

**When AQE skew join doesn't fire**: Skew below thresholds, or the skew is in a `GROUP BY`, not a join. Use manual salting (see [05-optimization-patterns.md](05-optimization-patterns.md)).

---

## Spill Prevention

```python
# Primary: ensure partitions are small enough to fit in execution memory
spark.conf.set("spark.sql.shuffle.partitions", "2000")      # more partitions = smaller each
spark.conf.set("spark.executor.memory", "16g")               # more heap = more room per partition

# Secondary: tune memory fraction for shuffle/join-heavy workloads
spark.conf.set("spark.memory.fraction", "0.75")              # give more to execution, less to user

# Tertiary: broadcast small tables to eliminate shuffles
spark.conf.set("spark.sql.autoBroadcastJoinThreshold", str(50 * 1024 * 1024))
```

**Detecting spill**: Spark UI → Stages tab → `Shuffle Spill (Disk)` column. Any non-zero = memory exhausted during that stage.

---

## Databricks-Specific Configs

```python
# Optimized Writes — shuffle data before writing to produce ~128 MB output files
# Replaces manual coalesce(n) before writes
spark.conf.set("spark.databricks.delta.optimizeWrite.enabled", "true")
spark.conf.set("spark.databricks.delta.optimizeWrite.binSize", "512m")  # target in-memory size per output file

# Auto Compaction — runs a compaction job after each write to merge small files
spark.conf.set("spark.databricks.delta.autoCompact.enabled", "true")
# Adds latency after each write job. Good for streaming / frequent appends.

# Or set as table properties (persists on the table itself):
# ALTER TABLE t SET TBLPROPERTIES ('delta.autoOptimize.optimizeWrite' = 'true')
# ALTER TABLE t SET TBLPROPERTIES ('delta.autoOptimize.autoCompact' = 'true')
```

**Databricks file size autotune targets**:
- Table < 2.56 TB → 256 MB target file size
- Table 2.56–10 TB → scales linearly 256 MB → 1 GB
- Table > 10 TB → 1 GB target file size

Override: `ALTER TABLE t SET TBLPROPERTIES ('delta.targetFileSize' = '256m')`

---

## Dynamic Partition Pruning (DPP)

```python
spark.conf.set("spark.sql.optimizer.dynamicPartitionPruning.enabled", "true")  # default true

# Only apply DPP when it can reuse an existing BroadcastExchange (less overhead)
spark.conf.set("spark.sql.optimizer.dynamicPartitionPruning.reuseBroadcastOnly", "true")  # default true
# Set false to always apply DPP even if it creates a new subquery (more aggressive)
```

**DPP requires all 3**:
1. Fact table is `partitionBy("join_key")` at write time
2. Dimension table small enough to broadcast (< `autoBroadcastJoinThreshold`) OR `broadcast()` hint
3. `dynamicPartitionPruning.enabled = true`

**Verify DPP in plan**:
```
FileScan parquet [...]
  PartitionFilters: [dynamicpruningexpression(date#3 IN dynamicpruning#5)]
```

**Why DPP fails**:
- Fact table not partitioned on the join key (most common)
- Dimension too large to broadcast → increase threshold or add hint
- Full outer join (not supported)
- Column type mismatch between fact and dimension

---

## I/O and File Sizing

```python
spark.conf.set("spark.sql.files.maxPartitionBytes", str(128 * 1024 * 1024))  # 128 MB (default)
# Each input file split targets this size. Reduce for large files with skewed records.
# Increase to reduce task count when files are perfectly sized.

spark.conf.set("spark.sql.files.openCostInBytes", str(4 * 1024 * 1024))      # 4 MB (default)
# Estimated cost to open a file. Increase for S3/GCS (high open latency) to pack
# more small files into one partition.

# Small files packing trick: inflate openCostInBytes to make Spark prefer
# packing multiple small files into one partition
spark.conf.set("spark.sql.files.openCostInBytes", str(128 * 1024 * 1024))    # 128 MB
# Now each partition will try to fill 128 MB of actual data + 128 MB "open cost" before splitting

# Parallel directory listing (improves metadata performance on large S3 prefixes)
spark.conf.set("spark.sql.sources.parallelPartitionDiscovery.threshold", "32")
spark.conf.set("spark.sql.sources.parallelPartitionDiscovery.parallelism", "10000")
```

---

## Codegen

```python
spark.conf.set("spark.sql.codegen.wholeStage", "true")     # default true — never disable in prod
spark.conf.set("spark.sql.codegen.maxFields", "100")       # default 100 — codegen off for schemas > 100 cols
# If your schema has 150 columns and you're seeing no * prefixes in explain:
spark.conf.set("spark.sql.codegen.maxFields", "200")       # raise to re-enable codegen (watch compile time)
```

---

## Python / Arrow

```python
spark.conf.set("spark.sql.execution.arrow.pyspark.enabled", "true")
# Arrow-based column transfer between JVM and Python. Required for Pandas UDFs.
# Also speeds up toPandas() / createDataFrame(pandas_df).

spark.conf.set("spark.sql.execution.pythonUDF.arrow.enabled", "true")
# Spark 3.4+: enable Arrow for regular scalar Python UDFs too (5–10× speedup)
```

---

## Production Config Template

```python
# Apply at session start for ETL/join-heavy workloads on Databricks

configs = {
    # AQE
    "spark.sql.adaptive.enabled": "true",
    "spark.sql.adaptive.coalescePartitions.enabled": "true",
    "spark.sql.adaptive.coalescePartitions.parallelismFirst": "false",
    "spark.sql.adaptive.advisoryPartitionSizeInBytes": "128m",
    "spark.sql.adaptive.coalescePartitions.minPartitionSize": "32m",
    "spark.sql.adaptive.skewJoin.enabled": "true",
    "spark.sql.adaptive.skewJoin.skewedPartitionFactor": "5.0",
    "spark.sql.adaptive.skewJoin.skewedPartitionThresholdInBytes": "256m",
    "spark.sql.adaptive.localShuffleReader.enabled": "true",
    # Shuffle
    "spark.sql.shuffle.partitions": "2000",
    "spark.shuffle.file.buffer": "1m",
    # Joins
    "spark.sql.autoBroadcastJoinThreshold": str(50 * 1024 * 1024),
    "spark.sql.broadcastTimeout": "600",
    # DPP
    "spark.sql.optimizer.dynamicPartitionPruning.enabled": "true",
    # I/O
    "spark.sql.files.maxPartitionBytes": str(128 * 1024 * 1024),
    # Arrow / Python
    "spark.sql.execution.arrow.pyspark.enabled": "true",
    "spark.sql.execution.pythonUDF.arrow.enabled": "true",
    # Databricks
    "spark.databricks.delta.optimizeWrite.enabled": "true",
}

for k, v in configs.items():
    spark.conf.set(k, v)
```

---

## Config Conflict Matrix

| Problem | Wrong Config | Right Config |
|---------|-------------|--------------|
| AQE coalesces to 1 MB partitions | `parallelismFirst=true` | `parallelismFirst=false` + `minPartitionSize=32m` |
| Broadcast times out on 100 MB table | `broadcastTimeout=300` | `broadcastTimeout=600` |
| SHJ fails on large partitions | `maxShuffledHashJoinLocalMapThreshold=1g` | Leave at `0` (disabled) or set conservatively |
| DPP not firing | Fact table not partitioned | Partition fact table on join key at write time |
| High GC after caching | `MEMORY_ONLY` on large data | `MEMORY_AND_DISK_SER` or don't cache |
| Python UDF performance | Default scalar UDFs | `pythonUDF.arrow.enabled=true` or use Pandas UDF |
| Small files on every write | No write optimization | `optimizeWrite.enabled=true` |
