# Scenario 05 — OOM Crashes and Shuffle Tuning

## The Problem Statement
> The 10 TB job runs fine for 40 minutes, then executors start dying with `java.lang.OutOfMemoryError: Java heap space` or `Container killed by YARN due to memory`. The job retries, uses more memory, eventually fails completely.

---

## Clarifying Questions

| Question | Why It Matters |
|----------|---------------|
| Where in the stage graph does OOM happen? (read / shuffle / write?) | Each has different fix |
| Is it GC overhead limit exceeded or heap OOM? | GC = many small objects. Heap = single large allocation |
| How many shuffle.partitions is set? (likely 200) | Default 200 → ~50 GB per partition on 10 TB = guaranteed OOM |
| Any UDFs (especially Python UDFs)? | Python UDFs copy data out of JVM → 2× memory |
| Any collect(), toPandas(), or broadcast of large DataFrames? | These pull data to driver |
| Executor memory and cores config? | Too many cores / too little memory per core = OOM |

---

## Understanding Spark Memory Model

```
Per-executor memory allocation:
┌──────────────────────────────────────────────────────┐
│  Total JVM Heap  (spark.executor.memory = 16 GB)     │
│  ├── Reserved    300 MB   (system overhead)          │
│  ├── User memory 40% × (16 GB - 300 MB) = 6.3 GB    │ ← your code, UDFs, closures
│  └── Spark memory 60% × (16 GB - 300 MB) = 9.5 GB   │
│       ├── Storage memory  50% = 4.75 GB              │ ← caching (.cache(), broadcast)
│       └── Execution memory 50% = 4.75 GB             │ ← shuffle, sort, aggregation
│                                                       │
│  Off-heap (spark.executor.memoryOverhead = 2 GB)      │ ← JVM overhead, Python process
└──────────────────────────────────────────────────────┘

Note: Storage and Execution share the 9.5 GB pool dynamically (unified memory model).
      When execution needs more, it borrows from storage (may evict cached data).
      When storage needs more, it can borrow unused execution memory.
```

---

## Root Cause 1 — shuffle.partitions Too Low (Most Common)

```
Default: spark.sql.shuffle.partitions = 200
10 TB of data / 200 partitions = 51.2 GB per shuffle partition
One task must hold 51.2 GB decompressed in execution memory → OOM guaranteed

Critical rule: AQE can ONLY coalesce partitions DOWN from shuffle.partitions ceiling.
               AQE CANNOT split or increase beyond the initial value.
               Set shuffle.partitions HIGH enough BEFORE AQE runs.

Fix:
  Target shuffle partition size = 128 MB–256 MB
  For 10 TB data going through a shuffle:
    shuffle.partitions = (10 TB × 1024 MB/GB × 1024 MB/TB) / 128 MB
                       = 10,485,760 / 128
                       = ~82,000   ← set to 100,000 (round up)
  
  AQE will then coalesce 100K down to a reasonable number at runtime.
```

```python
# WRONG — crashes on 10 TB shuffle
spark.conf.set("spark.sql.shuffle.partitions", "200")

# RIGHT — set high, let AQE coalesce down
spark.conf.set("spark.sql.shuffle.partitions", "100000")
spark.conf.set("spark.sql.adaptive.enabled", "true")
spark.conf.set("spark.sql.adaptive.coalescePartitions.enabled", "true")
spark.conf.set("spark.sql.adaptive.advisoryPartitionSizeInBytes", "128m")
```

---

## Root Cause 2 — Too Many Cores Per Executor (GC Pressure)

```
Executor: 32 cores, 64 GB memory → 2 GB per core
Each core runs one task → 32 concurrent tasks
Each task needs ~1–3 GB for its partition in memory
32 tasks × 2 GB = 64 GB → EXACTLY at limit, no GC headroom → GC thrash → OOM

Rule of thumb: 4–5 cores per executor, 4 GB memory per core
  4 cores × 4 GB = 16 GB per executor → comfortable
  Too few (1 core): high executor overhead, no HDFS read parallelism
  Too many (10+):   JVM GC pressure, HDFS connection thrash
```

```python
# Sweet spot configuration (not a hard formula — validate with profiling)
spark.conf.set("spark.executor.cores", "4")
spark.conf.set("spark.executor.memory", "16g")
spark.conf.set("spark.executor.memoryOverhead", "4g")   # extra for Python, native memory
# → 4 GB per core, overhead covers Python UDFs + native allocations
```

---

## Root Cause 3 — Shuffle Spill and Spill-to-Disk OOM

```
When execution memory fills:
  1. Spark spills intermediate data to disk (spark.local.dir)
  2. Spill is expensive: serialize → compress → write to disk → read back → deserialize
  3. If local disk fills OR spill rate exceeds I/O bandwidth → job stalls or OOM

Signs of spill in Spark UI:
  "Shuffle Spill (Memory)" — how much was in memory before spill
  "Shuffle Spill (Disk)"   — how much written to disk
  Ratio > 10:1 → severe spill problem
```

```python
# Fix: increase shuffle partition count (reduces per-partition size)
spark.conf.set("spark.sql.shuffle.partitions", "100000")

# Fix: configure spill-friendly settings
spark.conf.set("spark.shuffle.spill.compress", "true")
spark.conf.set("spark.io.compression.codec", "lz4")        # fast compression for spill

# Fix: use local SSD for shuffle temp storage (set at cluster launch, not in code)
# spark.local.dir = /local/ssd1,/local/ssd2   (multiple disks = parallel spill I/O)

# Fix: increase execution memory fraction if you have headroom
spark.conf.set("spark.memory.fraction", "0.8")             # default 0.6
spark.conf.set("spark.memory.storageFraction", "0.3")      # within fraction, 30% for storage
```

---

## Root Cause 4 — Driver OOM

```
Symptoms: "GC overhead limit exceeded" on driver, not executor
Causes:
  - collect() or toPandas() pulling large DataFrame to driver
  - broadcast() of a large DataFrame (> 1 GB)
  - DAG with millions of tasks (small files — see Scenario 04)
  - accumulate too many partition stats in driver memory
```

```python
# WRONG: never collect large DataFrames
rows = df.collect()               # pulls 10 TB to driver → OOM
pdf = df.toPandas()               # same problem

# RIGHT: keep data distributed
df.write.parquet(OUTPUT_PATH)    # let executors write

# WRONG: broadcasting a large table
df.join(broadcast(large_df), ...)  # large_df > 1 GB → driver OOM

# RIGHT: don't broadcast; let sort-merge join handle it, or increase driver memory
spark.conf.set("spark.driver.memory", "16g")
spark.conf.set("spark.driver.memoryOverhead", "4g")
spark.conf.set("spark.sql.autoBroadcastJoinThreshold", "50m")  # limit broadcast size
```

---

## Root Cause 5 — Python UDF Memory Doubling

```
PySpark UDFs run in a separate Python process per executor.
Data path: JVM → serialize → Python process → deserialize → run UDF → serialize → JVM

Memory impact:
  Each executor runs a Python worker process
  Python worker holds a copy of the data being processed
  Effective memory per task doubles: 1 GB partition → 2 GB needed per task

Fix 1: Replace Python UDF with built-in Spark SQL functions (zero overhead)
Fix 2: Use Pandas UDF (vectorized — 10–100x faster, still has some overhead)
Fix 3: Accept higher memory and lower core count per executor
```

```python
# BAD: Python UDF — row-by-row, full data copy
from pyspark.sql.functions import udf
from pyspark.sql.types import StringType

@udf(returnType=StringType())
def normalize_name(name):
    return name.strip().lower() if name else None

df = df.withColumn("name", normalize_name(col("name")))

# BETTER: built-in functions (JVM only, no Python process)
from pyspark.sql.functions import lower, trim
df = df.withColumn("name", lower(trim(col("name"))))

# ACCEPTABLE: Pandas UDF (vectorized — batch processing)
from pyspark.sql.functions import pandas_udf
import pandas as pd

@pandas_udf(StringType())
def normalize_name_vectorized(series: pd.Series) -> pd.Series:
    return series.str.strip().str.lower()

df = df.withColumn("name", normalize_name_vectorized(col("name")))
```

---

## Configs Reference

```python
# ─── Memory ─────────────────────────────────────────────────────────────────
spark.conf.set("spark.executor.memory",                "16g")
spark.conf.set("spark.executor.memoryOverhead",        "4g")
spark.conf.set("spark.driver.memory",                  "16g")
spark.conf.set("spark.driver.memoryOverhead",          "4g")
spark.conf.set("spark.memory.fraction",                "0.8")    # default 0.6
spark.conf.set("spark.memory.storageFraction",         "0.3")    # default 0.5

# ─── Shuffle ─────────────────────────────────────────────────────────────────
spark.conf.set("spark.sql.shuffle.partitions",         "100000") # start HIGH, AQE coalesces
spark.conf.set("spark.shuffle.spill.compress",         "true")
spark.conf.set("spark.io.compression.codec",           "lz4")    # fastest, ~2:1 ratio
spark.conf.set("spark.shuffle.compress",               "true")

# ─── AQE ─────────────────────────────────────────────────────────────────────
spark.conf.set("spark.sql.adaptive.enabled",                                  "true")
spark.conf.set("spark.sql.adaptive.coalescePartitions.enabled",               "true")
spark.conf.set("spark.sql.adaptive.advisoryPartitionSizeInBytes",             "128m")
spark.conf.set("spark.sql.adaptive.coalescePartitions.parallelismFirst",      "false")  # respect advisory size
spark.conf.set("spark.sql.adaptive.skewJoin.enabled",                         "true")
spark.conf.set("spark.sql.adaptive.skewJoin.skewedPartitionFactor",           "5")
spark.conf.set("spark.sql.adaptive.skewJoin.skewedPartitionThresholdInBytes", "256m")

# ─── Broadcast safety ────────────────────────────────────────────────────────
spark.conf.set("spark.sql.autoBroadcastJoinThreshold",  "50m")   # keep conservative
```

---

## OOM Diagnosis Flowchart

```
Job fails with OOM/Container killed
│
├── Which component failed?
│   ├── Executor → go to shuffle.partitions check
│   └── Driver  → look for collect(), toPandas(), or huge DAG (small files)
│
├── Spark UI → Stages → look for:
│   ├── Shuffle Spill (Disk) > 0 → increase shuffle.partitions
│   ├── GC time > 10% of task time → reduce cores/executor, increase memory
│   └── One task runs 10x longer than others → skew (see Scenario 02)
│
├── shuffle.partitions = 200 (default)?
│   └── YES → set to 10,000–100,000 (most likely root cause)
│
└── Python UDFs present?
    └── YES → replace with built-in or Pandas UDF
```

---

## Follow-up Questions Interviewers Ask

**Q: shuffle.partitions is set to 200 — how bad is that for 10 TB?**
A: 10 TB / 200 = 51.2 GB per shuffle partition. One task trying to hold 51.2 GB in 16 GB executor memory → guaranteed OOM. AQE cannot fix this because it can only coalesce down from 200, not split upward.

**Q: Why does Spark default to 200 if it's so dangerous?**
A: Default was set for small workloads. 200 is fine for a 10 GB dataset. The config was never updated as Spark scaled to petabyte workloads. Always override it for production large-scale jobs.

**Q: What's the difference between GC pressure and OOM?**
A: GC pressure = JVM is spending >25% of time running garbage collection (not computing). Manifests as very slow tasks with many pauses. OOM = JVM cannot allocate even after GC runs — heap is full. GC pressure usually precedes OOM; if you see GC time > 10% in Spark UI, fix memory before it becomes OOM.

**Q: Can you increase the execution memory fraction indefinitely?**
A: No. `spark.memory.fraction` takes from User Memory (the 40% pool). If you set fraction=0.9 and storage_fraction=0.1, user memory = 10%, leaving almost nothing for code variables, UDFs, and temporary objects → paradoxically increases OOM risk for non-shuffle code paths.
