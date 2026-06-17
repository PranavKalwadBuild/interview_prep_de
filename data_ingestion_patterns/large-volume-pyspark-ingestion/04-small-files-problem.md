# Scenario 04 — The Small Files Problem

## The Problem Statement
> Same 10 TB, but instead of 100 large files you have 5 million files averaging 2 MB each. The Spark job takes 45 minutes just to start and then crawls. Why?

---

## Why Small Files Destroy Performance

```
Problem 1 — S3 LIST overhead:
  S3 LIST returns max 1,000 keys per API call
  5,000,000 files / 1,000 = 5,000 LIST calls
  Each LIST call ≈ 10–100ms
  5,000 × 50ms = 250 seconds = 4 minutes just to enumerate files
  (Driver does this single-threaded before any executor starts)

Problem 2 — Task explosion:
  Spark default: spark.sql.files.maxPartitionBytes = 128 MB
  spark.sql.files.openCostInBytes = 4 MB  ← inflates each file size for bin-packing
  
  Without openCostInBytes inflation: 5M files × 2 MB = 10 TB / 128 MB = 78,125 tasks
  With openCostInBytes=4MB:  each 2 MB file treated as (2+4)=6 MB for bin-packing
  Bin-packing result: fewer files grouped per partition = ~1.2M tasks (each 2 files avg)
  
  1.2 million tasks × 2 sec task overhead = 2.4 million seconds of overhead
  Even at 2,000 concurrent tasks: 1.2M / 2,000 = 600 waves × 2 sec = 20 minutes wasted

Problem 3 — JVM overhead per task:
  Each Spark task has ~50–200ms startup cost (JVM, object allocation)
  1.2M tasks × 100ms = 120,000 sec of pure overhead at single-task throughput

Problem 4 — Driver OOM:
  Driver tracks every task in DAG. 5M files → 5M+ tasks in one stage → driver heap exhausted
```

---

## Clarifying Questions

| Question | Why It Matters |
|----------|---------------|
| Why are there 5M small files? (streaming writes? bad partition config?) | Root cause changes fix |
| Are files in S3 directories by date/hour/region? | Nested directories = recursive LIST, worse |
| Can files be compacted before Spark reads? | Yes → cheapest fix |
| Is this the source schema or produced by a prior Spark job? | Prior Spark job = fix write config |
| Same-day files or accumulated over months? | Months → compaction job is ongoing need |

---

## Detection

```python
# Check partition count after read
df = spark.read.parquet(INPUT_PATH)
print(f"Partition count: {df.rdd.getNumPartitions()}")
# If >> 100,000 for 10 TB → small files problem confirmed

# Check file count
import subprocess
result = subprocess.run(
    ["aws", "s3", "ls", "--recursive", INPUT_PATH],
    capture_output=True, text=True
)
file_count = len(result.stdout.strip().split('\n'))
avg_size_mb = 10_000_000 / file_count
print(f"Files: {file_count}, Avg size: {avg_size_mb:.1f} MB")
```

---

## Fix 1 — Tune openCostInBytes to Force Bin-Packing

```python
# openCostInBytes inflates each file's apparent size during bin-packing
# Higher value = more files packed per partition = fewer tasks
# Default: 4 MB. For 2 MB avg files, set to 128 MB to force ~64 files/partition.

spark.conf.set("spark.sql.files.openCostInBytes", str(128 * 1024 * 1024))  # 128 MB
spark.conf.set("spark.sql.files.maxPartitionBytes", str(256 * 1024 * 1024))  # 256 MB

# Result: Spark now bins ~64 files (64 × 2 MB = 128 MB data) per partition
# 5M files → ~78,000 partitions (from 1.2M without this fix)
```

**Tradeoff:** Larger inflation = fewer tasks = less parallelism. Balance against data size.

---

## Fix 2 — Repartition After Read (Quick Fix, Not Root Cause)

```python
df = spark.read.parquet(INPUT_PATH)
# df has 1M+ partitions here

# Force repartition to sensible count
TARGET_PARTITIONS = (10_000 * 1024) // 256  # 10 TB / 256 MB = ~40,000
df = df.repartition(TARGET_PARTITIONS)

# Now pipeline runs with 40K partitions instead of 1M+
# Cost: one full shuffle to redistribute data
```

---

## Fix 3 — Compaction Job (Root Cause Fix)

Run a periodic compaction job to merge small files before the main ingestion pipeline reads them.

```python
# Compaction: read small files, write back as large files
# Run this as a separate scheduled job (e.g., nightly before ingestion starts)

def compact_partition(partition_path: str, target_size_mb: int = 256):
    df = spark.read.parquet(partition_path)
    
    # Count current files and total bytes
    total_bytes = df.rdd.mapPartitions(
        lambda it: [sum(1 for _ in it)]  # approximate
    ).sum()
    
    target_partitions = max(1, (total_bytes // (target_size_mb * 1024 * 1024)) + 1)
    
    TEMP_PATH = partition_path.rstrip("/") + "_compact_tmp/"
    
    df.coalesce(target_partitions) \
      .write \
      .mode("overwrite") \
      .parquet(TEMP_PATH)
    
    # Validate and swap (see Scenario 03 for atomic swap pattern)
    return TEMP_PATH

# Run compaction on each partition directory in parallel using Spark itself
partition_dirs = [
    "s3a://bucket/landing/date=2024-01-10/",
    "s3a://bucket/landing/date=2024-01-11/",
    # ...
]

# Use ThreadPoolExecutor for parallel compaction across partitions
from concurrent.futures import ThreadPoolExecutor
with ThreadPoolExecutor(max_workers=10) as executor:
    futures = [executor.submit(compact_partition, d) for d in partition_dirs]
    results = [f.result() for f in futures]
```

---

## Fix 4 — Fix the Writer (Prevent Small Files from Being Created)

If small files are produced by a prior Spark job, fix the writer config:

```python
# BAD: default spark.sql.shuffle.partitions=200 on 10 TB produces 200 files
# of 50 GB each — then downstream jobs split them again → small files cascade

# BAD: writing without maxRecordsPerFile → huge files OR tiny files depending on data dist

# GOOD: control output file size
df.write \
    .option("maxRecordsPerFile", 5_000_000) \    # cap rows per file
    .partitionBy("event_date") \
    .parquet(OUTPUT_PATH)

# GOOD: repartition before write to control file count
df.repartition(500) \                             # 500 output files for 10 TB = 20 GB each → still large
  .write.parquet(OUTPUT_PATH)                     # adjust to target 256 MB–1 GB per file

# GOOD for streaming: trigger compaction on micro-batch completion
# (see Fix 3 above)
```

---

## Fix 5 — S3 Glob Optimization

```python
# BAD: recursive wildcard causes driver to enumerate everything
df = spark.read.parquet("s3a://bucket/landing/**/*.parquet")

# GOOD: explicit date-partitioned paths if you know the range
from datetime import date, timedelta
dates = [str(date(2024,1,15) - timedelta(days=i)) for i in range(0)]
paths = [f"s3a://bucket/landing/date={d}/" for d in dates]
df = spark.read.parquet(*paths)

# GOOD: use partition pruning with filter pushdown
df = spark.read.parquet("s3a://bucket/landing/") \
    .filter(col("date") == "2024-01-15")          # Spark pushes this down to LIST only that partition
```

---

## S3 Committer Configs (Verified Critical)

```python
# Classic FileOutputCommitter = UNSAFE on S3
# S3 rename is NOT atomic — it is copy+delete, O(data) operation
# A task failure mid-rename leaves partial data

# For open-source Spark on S3: use S3A Staging Committer
spark.conf.set("spark.hadoop.mapreduce.outputcommitter.factory.scheme.s3a",
               "org.apache.hadoop.fs.s3a.commit.S3ACommitterFactory")
spark.conf.set("spark.hadoop.fs.s3a.committer.name", "staging")
spark.conf.set("spark.hadoop.fs.s3a.committer.staging.conflict-mode", "replace")
spark.conf.set("spark.hadoop.fs.s3a.committer.staging.tmp.path", "/tmp/spark-staging")

# Connection tuning for high-file-count S3 workloads
spark.conf.set("spark.hadoop.fs.s3a.connection.maximum", "200")
spark.conf.set("spark.hadoop.fs.s3a.threads.max", "64")
spark.conf.set("spark.hadoop.fs.s3a.connection.establish.timeout", "5000")
spark.conf.set("spark.hadoop.fs.s3a.attempts.maximum", "10")
```

---

## Math: Impact Summary

```
Scenario         Files      Avg Size   Partitions     Waves @ 2K concurrent   Estimate
─────────────────────────────────────────────────────────────────────────────────────────
Baseline (10TB)  100        100 GB     ~40,000        20                      35 min
Small files      5,000,000  2 MB       ~1,200,000     600                     10+ hours ← SLA blown
After Fix 1      5,000,000  2 MB       ~78,000        39                      55 min
After Fix 2      5,000,000  2 MB       ~40,000        20 + shuffle cost       50 min
After compaction ~40,000    256 MB     ~40,000        20                      35 min ← same as baseline
```

---

## Follow-up Questions Interviewers Ask

**Q: coalesce vs repartition for compaction?**
A: `coalesce(N)` merges partitions on same executor without shuffle — faster and no network cost. Use for compaction (reducing partition count). `repartition(N)` does full shuffle — use only when increasing count or rebalancing skewed data.

**Q: What generates small files in practice?**
A: (1) Streaming writes (Spark Structured Streaming default micro-batch = many small files per trigger), (2) partitionBy on high-cardinality column (1M partition dirs × N executors = N files per dir), (3) low shuffle.partitions with small data (200 partitions × tiny records = 200 tiny files).

**Q: What's the openCostInBytes config doing exactly?**
A: Spark's file scheduler adds this value to every file's size during bin-packing. It simulates the "cost to open a new file" so the bin-packer prefers to fill existing partitions rather than starting new ones for each small file. Default 4 MB. For 2 MB avg files: set to ~64–128 MB to get 32–64 files packed per partition.

**Q: Can you fix small files without a compaction job?**
A: Partially — Fix 1 (openCostInBytes) reduces task count at read time. Fix 5 (explicit paths) reduces LIST calls. But compaction is the only fix that also reduces S3 LIST overhead for future reads. openCostInBytes only affects Spark's partitioner, not the S3 API call count.
