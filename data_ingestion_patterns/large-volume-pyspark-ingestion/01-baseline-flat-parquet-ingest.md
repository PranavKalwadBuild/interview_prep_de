# Scenario 01 — Baseline: 10 TB Flat Parquet Ingest within 3 Hours

## The Problem Statement (Interview Version)
> You receive 10 TB of Parquet files daily in S3. Files arrive as a complete batch by midnight. You must ingest all data into a data warehouse by 3 AM. Design the ingestion pipeline.

---

## Clarifying Questions to Ask First

Before designing anything, ask these in an interview:

| Question | Why It Matters |
|----------|---------------|
| How many files? 10 large vs 10M small? | Drives S3 LIST cost and partition strategy |
| Schema: flat or nested? | Nested Parquet needs explode → 3–5x more shuffle |
| Transformations needed? | Passthrough vs heavy compute changes cluster size |
| Target DW write mode? Full replace or upsert? | Upsert = merge cost on top |
| Is schema fixed or can it evolve? | Schema evolution needs mergeSchema → slower reads |
| Downstream SLA dependencies? | Determines acceptable latency buffer |
| Idempotency required? | Re-runs must not double-count |
| Cluster budget / fixed or auto-scaling? | Caps what's achievable |

---

## The Math (Whiteboard-Ready)

### Step 1 — Partition Count

```
Data size        = 10,000 GB = 10,240,000 MB
Default partition= 128 MB  (spark.sql.files.maxPartitionBytes default — verified)
Target partition = 256 MB  (tuned for this workload; sweet spot: 128–512 MB for Parquet)
                            (128 MB → more parallelism, more tasks
                             512 MB → fewer tasks, higher per-task cost)

Required partitions at 256 MB = 10,240,000 / 256 = ~40,000 partitions
Required partitions at 128 MB = 10,240,000 / 128 = ~80,000 partitions (Spark default)
```

### Step 2 — Task Duration Check

```
Assume each task reads + transforms + writes one partition:
  Read throughput (S3 → executor):  ~500 MB/s per executor (network bound)
  Task time for 256 MB partition  = 256 MB / 500 MB/s ≈ 0.5 seconds (read only)
  With transforms + write          ≈ 2–5 seconds per task

If total parallelism = 2,000 tasks concurrent:
  Waves needed = 40,000 / 2,000 = 20 waves
  Total time   = 20 waves × 5 sec/task ≈ 100 seconds ← way under 3 hrs

Reality check: add shuffle time, DW write, overhead → aim for 2× buffer
Comfortable target: 10,000–20,000 concurrent tasks for 3hr SLA
```

### Step 3 — Cluster Sizing

```
Executor config (recommended starting point):
  Cores per executor : 4–5  (avoid 1 = no parallelism; avoid 10+ = GC pressure)
  Memory per executor: 16–32 GB
  Memory per core    : ~4 GB (safe default)

For 10,000 concurrent tasks:
  Executors needed   = 10,000 / 4 cores = 2,500 executors
  
  Too expensive → reduce target parallelism:
  500 executors × 4 cores = 2,000 cores
  40,000 tasks / 2,000 = 20 waves × 5 sec = 100 sec read time
  + 10 min shuffle + 20 min DW write = ~35 min total  ← well within 3 hr SLA

Start with 200–500 executors for a 10 TB flat ingest.
```

### Step 4 — Memory Budget

```
Per executor (32 GB total):
  Spark reserved      = 300 MB (system)
  User memory         = 40% of (32 GB - 300 MB) ≈ 12.7 GB  (your code, UDFs)
  Execution memory    = 60% of remaining ≈ 19 GB             (shuffle, aggregations)

Overhead:
  spark.executor.memoryOverhead = max(10% of executor memory, 384 MB)
  = max(3.2 GB, 384 MB) = 3.2 GB off-heap

Working partition in memory ≈ 256 MB × 3.5 (deserialized overhead) ≈ 900 MB
Concurrent partitions per executor (4 cores): 4 × 900 MB = 3.6 GB → fits in 19 GB execution memory
```

---

## Spark Configurations

```python
spark = SparkSession.builder \
    .appName("10TB_flat_parquet_ingest") \
    .config("spark.executor.instances", "300") \
    .config("spark.executor.cores", "4") \
    .config("spark.executor.memory", "16g") \
    .config("spark.executor.memoryOverhead", "2g") \
    .config("spark.driver.memory", "8g") \
    .config("spark.driver.memoryOverhead", "1g") \
    # Parallelism
    .config("spark.default.parallelism", "2400")          # 2× total cores
    .config("spark.sql.shuffle.partitions", "4000")        # post-shuffle partitions
    # S3 read optimization
    .config("spark.sql.files.maxPartitionBytes", "268435456")  # 256 MB (default=128 MB)
    .config("spark.sql.files.openCostInBytes", "4194304")      # 4 MB default — inflates small files for bin-packing
    .config("spark.hadoop.fs.s3a.block.size", "268435456") # 256 MB block size
    .config("spark.hadoop.fs.s3a.readahead.range", "524288")
    .config("spark.hadoop.fs.s3a.connection.maximum", "200")
    .config("spark.hadoop.fs.s3a.threads.max", "64")
    # Parquet
    .config("spark.sql.parquet.mergeSchema", "false")      # NEVER true unless needed
    .config("spark.sql.parquet.filterPushdown", "true")
    .config("spark.sql.parquet.columnarReaderBatchSize", "4096")
    # AQE (Adaptive Query Execution) — enabled by default since Spark 3.2.0
    # CRITICAL: AQE can only coalesce shuffle.partitions DOWN — it cannot increase beyond
    # the ceiling you set. Set shuffle.partitions HIGH; AQE will merge small partitions.
    .config("spark.sql.adaptive.enabled", "true")
    .config("spark.sql.adaptive.coalescePartitions.enabled", "true")
    .config("spark.sql.adaptive.advisoryPartitionSizeInBytes", "128m")     # AQE merge target
    # parallelismFirst=true (default): AQE ignores advisory size, maximizes parallelism
    # parallelismFirst=false: AQE respects advisory size → controlled output file sizes
    .config("spark.sql.adaptive.coalescePartitions.parallelismFirst", "false")
    .config("spark.sql.adaptive.skewJoin.enabled", "true")
    .config("spark.sql.adaptive.skewJoin.skewedPartitionFactor", "5")
    .config("spark.sql.adaptive.skewJoin.skewedPartitionThresholdInBytes", "256m")
    # Write optimization
    .config("spark.sql.files.maxRecordsPerFile", "5000000") # cap records/output file
    .getOrCreate()
```

---

## Pseudo Code

```python
# --- INGEST PIPELINE ---

INPUT_PATH  = "s3a://bucket/landing/date=2024-01-15/**/*.parquet"
OUTPUT_PATH = "s3a://bucket/processed/table_name/"
TARGET_PARTITION_MB = 256
TOTAL_DATA_GB = 10_000

# 1. Calculate target partition count
target_partitions = (TOTAL_DATA_GB * 1024) // TARGET_PARTITION_MB  # ~40,000

# 2. Read — let Spark split files by block size
df = spark.read \
    .option("mergeSchema", "false") \
    .parquet(INPUT_PATH)

# 3. Repartition to match target parallelism
#    Use repartition() when increasing partitions
#    Use coalesce() only when reducing (avoids full shuffle)
#
#    Rule: if AQE enabled, let it handle coalescing — don't manual coalesce
df = df.repartition(target_partitions)

# 4. Apply transformations (keep narrow; avoid wide unless necessary)
df_transformed = (
    df
    .filter(df["status"] != "DELETED")
    .withColumn("ingestion_ts", current_timestamp())
    .withColumn("batch_date", lit("2024-01-15"))
)

# 5. Write
#    NEVER use .rdd.saveAsTextFile or collect() on 10 TB
#    Use DataFrame writer with parallelism control
df_transformed.write \
    .mode("overwrite") \
    .option("compression", "snappy") \
    .option("maxRecordsPerFile", 5_000_000) \
    .parquet(OUTPUT_PATH)

# If writing to a JDBC sink (generic DW):
# df_transformed.write \
#     .mode("overwrite") \
#     .option("numPartitions", 200) \        # parallel JDBC connections
#     .option("batchsize", 100_000) \        # rows per INSERT batch
#     .jdbc(url, table, properties)
```

---

## Follow-up Questions Interviewers Ask

**Q: Why 256 MB partition target?**
A: Parquet read is columnar + compressed. After decompression into JVM, 256 MB Parquet → ~1–3 GB in memory depending on schema. Fits comfortably in executor memory without spill. Below 64 MB = task overhead dominates. Above 512 MB = OOM risk.

**Q: Why `mergeSchema=false`?**
A: `mergeSchema=true` forces Spark to LIST all files and read all footers before any task runs. On 10 TB with thousands of files = minutes of driver-side overhead. Keep schema fixed; validate separately.

**Q: What if the DW write is the bottleneck, not the read?**
A: Tune `numPartitions` on the JDBC writer (= parallel connections). Check DW ingestion rate limit. Consider writing to an intermediate staging area (Parquet → staging table → DW bulk load) — bulk load APIs are always faster than JDBC row-by-row.

**Q: repartition vs coalesce?**
A: `repartition(N)` = full shuffle, creates N evenly sized partitions. Use when N > current partitions or when partitions are skewed. `coalesce(N)` = no shuffle, merges adjacent partitions on same executor. Use only to reduce partitions at write time. Never coalesce to a very small number mid-pipeline — creates hot partitions.

**Q: How do you ensure idempotency?**
A: Write to a temp path, validate row count / checksum, then atomic rename/move. Or use `mode("overwrite")` on a deterministic output path keyed by batch date. See Scenario 06 for full pattern.

---

## SLA Sanity Check Formula

```
Time available        = 3 hours = 10,800 seconds
Estimated task time   = 5 seconds/partition
Total partitions      = 40,000
Concurrent tasks      = executors × cores = 300 × 4 = 1,200

Waves                 = ceil(40,000 / 1,200) = 34 waves
Total compute time    = 34 × 5 = 170 seconds  (~3 minutes)
Shuffle + write       = ~20 minutes (optimistic), ~60 minutes (heavy transforms)
Overhead + retries    = ~20 minutes buffer

Total estimated       = ~80 minutes  → 53% of SLA budget used
Safety buffer         = ~100 minutes → comfortable
```

If estimate > 80% of SLA budget → double executor count or reduce partition size to 128 MB.
