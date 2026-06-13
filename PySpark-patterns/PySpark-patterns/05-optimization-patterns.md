# PySpark Optimization Patterns

> Everything not covered in explain plans, configs, or Spark UI.
> Core question per pattern: How does this break? How does this scale?

---

## Partitioning: repartition vs coalesce

| | `repartition(n)` | `coalesce(n)` |
|--|------------------|---------------|
| Direction | Increase OR decrease | Decrease only |
| Shuffle | Full shuffle | No shuffle (narrow dependency) |
| Distribution | Even (hash or round-robin) | Uneven — merges local partitions |
| Use case | Before joins/aggregations, fixing skew | Reduce output files before write |
| Under the hood | `coalesce(n, shuffle=True)` | Merges partitions on same executor |

**Breaking scenario with `coalesce`**: You have 1000 partitions spread unevenly (skew). `coalesce(10)` merges 100 partitions per executor. If 200 of those 1000 partitions are fat, they could all land on the same 2 executors → OOM.

**Scaling rule**: Use `repartition()` whenever even distribution matters. Use `coalesce()` only as the last step before a write when you just need fewer output files.

```python
# Before write — reduce file count without caring about evenness
df.coalesce(100).write.format("delta").save("path")

# Before join — ensure balanced data
df.repartition(200, "join_key") \
  .join(other_df, "join_key")

# Repartition by partition key for balanced writes
df.repartition(200, "date_col") \
  .write.partitionBy("date_col") \
  .format("delta").save("path")
```

---

## `partitionBy` for Writes

Organizes data into subdirectories by column value. Enables partition pruning on reads.

```python
df.write.partitionBy("year", "month").format("delta").save("s3://bucket/table/")
# Output: s3://bucket/table/year=2024/month=01/part-00000.parquet
#                          year=2024/month=02/part-00000.parquet
```

**Query benefit**:
```python
# Reads ONLY year=2024/month=01/ — skips all other partitions
spark.read.format("delta").load("s3://bucket/table/") \
  .filter("year = 2024 AND month = 1")
```

**How it breaks**:
- High-cardinality column (e.g., `user_id` with 100M unique values) → 100M subdirectories → metadata explosion → driver OOM listing files
- Too many partitions × too many Spark tasks = millions of tiny output files (small files problem)
- Partition column with skewed distribution → one partition has 90% of the data → reads are still slow

**Scaling rules**:
- `partitionBy` columns should have **low cardinality** (dates, region, status)
- Target: each partition directory has **~128 MB – 1 GB** of data total
- Max practical partitions: ~10,000 (beyond that, metadata operations slow down)
- Combine with `optimizeWrite` (Databricks) to avoid small files within each partition

---

## Bucketing for Repeat Joins

Pre-shuffles and pre-sorts data at write time. Joins between two tables bucketed on the same key with the same bucket count require **zero shuffle**.

```python
# Write bucketed (once, expensive — rewrites the data)
df_orders.write \
    .bucketBy(200, "customer_id") \
    .sortBy("customer_id") \
    .format("parquet") \
    .saveAsTable("bucketed_orders")   # must be a managed table

df_customers.write \
    .bucketBy(200, "customer_id") \
    .sortBy("customer_id") \
    .format("parquet") \
    .saveAsTable("bucketed_customers")

# Join (no Exchange node in explain plan — zero shuffle)
result = spark.table("bucketed_orders") \
              .join(spark.table("bucketed_customers"), "customer_id")
```

**Verify it worked** — no `Exchange` between scan and join:
```python
result.explain(mode="simple")
# Should show: SortMergeJoin directly above FileScan, no Exchange
```

**How it breaks**:
- Bucket count is fixed at write time. Change it → full rewrite. Choose bucket count ≈ `data_size_GB / 0.128` (targeting ~128 MB per bucket).
- If one table uses 200 buckets and the other uses 100 → bucketing incompatible → shuffle happens anyway
- Bucketing only works for Hive-style managed tables via `saveAsTable`, not `save()` to a path

**Scaling**: Best for tables joined repeatedly on the same key in production pipelines. One-time write cost pays for every subsequent join.

---

## Z-Ordering (Databricks Delta)

Co-locates related data in the same files using a space-filling curve. Delta stores min/max stats per column per file in the transaction log — queries skip entire files that can't match the filter.

```sql
OPTIMIZE events_table ZORDER BY (user_id, event_type);
```

**How data skipping works**:
```
File 1: user_id min=1,      max=50000   → filter user_id=99999 → SKIP
File 2: user_id min=50001,  max=100000  → filter user_id=99999 → READ
```

**Effective when**:
- High-cardinality columns with point lookups (`WHERE user_id = 12345`)
- Columns used in most ad hoc queries
- 2–3 columns max (effectiveness drops beyond that — Z-curve degrades in high dimensions)

**How it breaks**:
- Rewrites **all files** in the table every time `OPTIMIZE ... ZORDER BY` runs — very expensive for large tables
- No benefit for range scans unless the range is selective
- Requires `ANALYZE TABLE` to collect column stats before file skipping can trigger
- New data written after the last `OPTIMIZE` run is not Z-ordered — re-run periodically

**Liquid Clustering** (Databricks Runtime 15.2+) — replaces Z-ORDER:
```sql
-- Create table with liquid clustering
CREATE TABLE events (id BIGINT, user_id BIGINT, event_type STRING)
  CLUSTER BY (user_id, event_type);

-- Incremental OPTIMIZE — only re-clusters new/modified data
OPTIMIZE events;

-- Change clustering columns without rewriting table
ALTER TABLE events CLUSTER BY (user_id);
```

Liquid Clustering is incremental — `OPTIMIZE` only processes unclustered ZCubes. Recommended for all new tables.

---

## Bloom Filters (Delta)

Complement to Z-order for equality filters. Builds a probabilistic index per column per file. Very effective for UUID/string equality lookups where Z-order range skipping is weak.

```sql
ALTER TABLE events SET TBLPROPERTIES (
  'delta.bloomFilter.user_id.enabled' = 'true',
  'delta.bloomFilter.user_id.fpp' = '0.1',           -- false positive probability
  'delta.bloomFilter.user_id.numItems' = '10000000'  -- expected unique values
);
```

Lower `fpp` = more accurate = larger bloom filter on disk. `0.1` is a good starting point.

---

## Caching Strategy

### When to cache

- DataFrame reused in **multiple actions** (not just multiple transformations — Spark is lazy, no work is duplicated until an action triggers execution)
- Result of expensive computation (multi-join + aggregation) feeding several downstream queries
- Iterative algorithms (ML loops)
- Interactive analysis: same filtered subset queried repeatedly

### When NOT to cache

- Single-use DataFrames (scan once, write once)
- DataFrames that exceed 30–40% of total storage memory (evicts execution memory → causes spill)
- Easy-to-recompute DataFrames (simple scan + filter)
- Before a filter that removes most rows — cache the **filtered** result instead

### Storage level selection

```python
from pyspark import StorageLevel

df.cache()                                         # MEMORY_AND_DISK — default, balanced
df.persist(StorageLevel.MEMORY_ONLY)               # fastest access, no spill fallback
df.persist(StorageLevel.MEMORY_ONLY_SER)           # serialized — 2-3× smaller, CPU cost
df.persist(StorageLevel.MEMORY_AND_DISK_SER)       # serialized + disk fallback
df.persist(StorageLevel.DISK_ONLY)                 # rarely explicit — let Spark spill
df.persist(StorageLevel.MEMORY_AND_DISK_2)         # replicated to 2 executors — fault tolerant

# Force materialization (caching is lazy — nothing cached until an action runs)
df.cache()
df.count()    # triggers materialization

# Release when done
df.unpersist()
```

| Level | Use When |
|-------|----------|
| `MEMORY_AND_DISK` | Default. Data may not all fit in memory. |
| `MEMORY_ONLY` | Data fits comfortably, fast recompute OK if evicted. |
| `MEMORY_ONLY_SER` | Memory constrained; data has large JVM object graphs. |
| `MEMORY_AND_DISK_SER` | Large data, constrained memory, recomputation expensive. |
| `*_2` suffix | Node failures likely; recomputation extremely costly. |

**How it breaks**:
- Cache `.count()` to materialize, but then do a `.write()` — the write triggers a separate execution path that may not use the cache (depends on plan)
- Caching wide DataFrames with many columns fills storage memory fast
- Caching too early in the pipeline (before filter) wastes memory on data you'll throw away

---

## UDF Performance Hierarchy

**Fastest to slowest**:
```
1. Built-in SQL functions (pyspark.sql.functions.*)   — JVM, Catalyst-optimized, zero Python
2. Scala/Java UDFs registered via JVM                 — JVM, no serialization
3. Pandas UDFs (Arrow-vectorized)                     — batch transfer, zero-copy
4. Standard Python UDFs                               — row-by-row, pickle, IPC per row
```

### Why Python UDFs kill performance

- Catalyst treats UDF as a black box → no predicate pushdown, no constant folding
- Row-by-row serialization: Java object → pickle bytes → Python object
- IPC: JVM process ↔ Python process socket per **batch** (Spark 3.x batches internally, but still expensive)
- No whole-stage codegen through UDF boundary

### Pandas UDFs (right way to use Python)

```python
from pyspark.sql.functions import pandas_udf
import pandas as pd

@pandas_udf("double")
def normalize(s: pd.Series) -> pd.Series:
    return (s - s.mean()) / s.std()

df.withColumn("normalized", normalize("value"))

# Iterator variant — useful for expensive initialization (model loading)
from pyspark.sql.functions import pandas_udf
from typing import Iterator

@pandas_udf("double")
def batch_predict(it: Iterator[pd.Series]) -> Iterator[pd.Series]:
    model = load_model()   # loaded once per partition, not per row
    for s in it:
        yield model.predict(s)

df.withColumn("prediction", batch_predict("features"))
```

**Enable Arrow for all Python UDFs**:
```python
spark.conf.set("spark.sql.execution.arrow.pyspark.enabled", "true")
spark.conf.set("spark.sql.execution.pythonUDF.arrow.enabled", "true")  # Spark 3.4+
```

**Replace UDFs with native equivalents**:
```python
# Instead of UDF:           df.withColumn("upper", udf(lambda x: x.upper())("name"))
from pyspark.sql import functions as F
df.withColumn("upper", F.upper("name"))                   # native — 10–100× faster

# Instead of UDF:           udf(lambda x: x is None)("col")
df.withColumn("is_null", F.col("col").isNull())           # native

# Instead of UDF:           udf(lambda x: x[:3])("col")
df.withColumn("prefix", F.substring("col", 1, 3))         # native

# Instead of UDF for JSON:  udf(lambda x: json.loads(x)["field"])("col")
df.withColumn("field", F.get_json_object("col", "$.field"))  # native
```

---

## Window Function Optimization

### Rule 1: Always use `partitionBy`

Without `partitionBy`, Spark shuffles the **entire dataset to one partition**. One task processes all rows. At any scale this is OOM or hours.

```python
from pyspark.sql import Window
from pyspark.sql import functions as F

# WRONG for large data — all rows go to one task
w_bad = Window.orderBy("salary")

# CORRECT — each department is independent
w = Window.partitionBy("dept").orderBy("salary")
df.withColumn("rank", F.rank().over(w))
```

### Rule 2: Reuse window specs

Each distinct `WindowSpec` can require a separate shuffle. Reuse the same spec for multiple functions.

```python
# BAD — potentially 3 shuffles
df.withColumn("r",    F.rank().over(Window.partitionBy("dept").orderBy("salary"))) \
  .withColumn("lag1", F.lag("salary", 1).over(Window.partitionBy("dept").orderBy("salary"))) \
  .withColumn("sum",  F.sum("salary").over(Window.partitionBy("dept").orderBy("salary")))

# GOOD — one shuffle
w = Window.partitionBy("dept").orderBy("salary")
df.withColumn("r",    F.rank().over(w)) \
  .withColumn("lag1", F.lag("salary", 1).over(w)) \
  .withColumn("sum",  F.sum("salary").over(w))
```

### Rule 3: Avoid `UNBOUNDED FOLLOWING` unless necessary

```python
# Fast — only looks backward
w_running = Window.partitionBy("dept").orderBy("date") \
              .rowsBetween(Window.unboundedPreceding, Window.currentRow)

# Slow — must buffer entire partition before outputting any row
w_full = Window.partitionBy("dept").orderBy("date") \
           .rowsBetween(Window.unboundedPreceding, Window.unboundedFollowing)

# Fast bounded window — only 7 rows
w_7day = Window.partitionBy("dept").orderBy("date").rowsBetween(-6, 0)
```

### Rule 4: `rowsBetween` vs `rangeBetween`

- `rowsBetween`: physical row offset — deterministic, works with any type
- `rangeBetween`: value-range offset — requires numeric `orderBy`, natural for time-series

```python
# 7-day range (rangeBetween on epoch days)
w_range = Window.partitionBy("dept") \
            .orderBy(F.col("date").cast("long")) \
            .rangeBetween(-6, 0)
```

### Scaling concern

Window functions never use whole-stage codegen. For very high-cardinality `PARTITION BY` keys, the shuffle is unavoidable but the per-partition work is parallelized. For low-cardinality keys with large partitions, each task does more work — watch for stragglers.

---

## Skew: Manual Salting

Use when AQE skew join hasn't fired (pre-3.2, skew below thresholds, or GROUP BY skew).

### Skew in joins

```python
import pyspark.sql.functions as F

SALT_N = 50  # tune based on skew factor

# Salt the large (hot-key) side — random assignment
df_large = df_large.withColumn(
    "salted_key",
    F.concat(F.col("join_key").cast("string"), F.lit("_"),
             (F.rand() * SALT_N).cast("int"))
)

# Explode the small side to match all salt values
salt_array = F.array([F.lit(i) for i in range(SALT_N)])
df_small = df_small.withColumn("_salt", F.explode(salt_array))
df_small = df_small.withColumn(
    "salted_key",
    F.concat(F.col("join_key").cast("string"), F.lit("_"), F.col("_salt").cast("string"))
)

result = df_large.join(df_small, "salted_key").drop("salted_key", "_salt")
```

**Tradeoff**: small side grows `SALT_N`× in size. If small side is 10 GB and SALT_N=50, small side becomes 500 GB — now too big to broadcast, still needs shuffle. Tune SALT_N to be just large enough to distribute the skew.

### Skew in GROUP BY

```python
SALT_N = 20

# Phase 1: partial aggregate on salted key
df_salted = df.withColumn("_salt", (F.rand() * SALT_N).cast("int"))
partial = df_salted.groupBy("original_key", "_salt") \
                   .agg(F.sum("value").alias("partial_sum"),
                        F.count("*").alias("partial_count"))

# Phase 2: final aggregate on original key
final = partial.groupBy("original_key") \
               .agg(F.sum("partial_sum").alias("total_sum"),
                    F.sum("partial_count").alias("total_count"))
```

**How it breaks**: Only works for **decomposable aggregations** (sum, count, min, max). Does NOT work for exact distinct count, median, or other non-decomposable aggregations.

---

## Small Files Problem

### Causes
- Streaming micro-batches write files every few seconds
- Over-partitioned writes: high-cardinality `partitionBy` × many Spark tasks
- Many incremental appends without compaction

### Symptoms
- First stage shows 50,000+ tasks each reading 1 KB
- High scheduler overhead; low executor utilization
- Spark UI Stages tab: many tiny input partitions

### Solutions (Databricks)

**Option 1: Optimized Writes** (best for active pipelines)
```python
spark.conf.set("spark.databricks.delta.optimizeWrite.enabled", "true")
# Shuffles data before write → ~128 MB output files automatically
# Adds one shuffle but eliminates small file problem at source
```

**Option 2: Auto Compaction** (for streaming/frequent appends)
```python
spark.conf.set("spark.databricks.delta.autoCompact.enabled", "true")
# Runs a compaction job after each write
# Adds latency after each micro-batch — acceptable for near-real-time, not true streaming
```

**Option 3: Scheduled OPTIMIZE** (for batch tables)
```sql
-- Run daily/weekly via a scheduled job
OPTIMIZE table_name;
OPTIMIZE table_name ZORDER BY (col1);  -- combine compaction + Z-order
```

**Option 4: Tune input-side packing** (when you can't rewrite the source)
```python
# Spark packs small files into larger partitions using this formula:
# partition_size = actual_data + openCostInBytes
# Inflate openCostInBytes to force more aggressive packing
spark.conf.set("spark.sql.files.openCostInBytes", str(128 * 1024 * 1024))  # 128 MB
spark.conf.set("spark.sql.files.maxPartitionBytes", str(256 * 1024 * 1024)) # 256 MB
```

**Option 5: Manual coalesce before write** (simple, no extra shuffle)
```python
df.coalesce(100).write.format("delta").mode("append").save("path")
```

---

## Broadcast Variables vs Broadcast Joins

### Broadcast variables — general-purpose lookup

```python
# Good for: lookup dicts, small config maps, feature encoders
lookup_dict = {"US": "United States", "GB": "Great Britain"}
bc_lookup = spark.sparkContext.broadcast(lookup_dict)

# Use inside a UDF or map
from pyspark.sql.functions import udf
from pyspark.sql.types import StringType

@udf(StringType())
def enrich_country(code):
    return bc_lookup.value.get(code, "Unknown")

df.withColumn("country_name", enrich_country("country_code"))

# Always destroy when done — otherwise stays in executor memory
bc_lookup.destroy()
```

### Broadcast joins — structured table joins

```python
from pyspark.sql.functions import broadcast

# Explicit hint — highest priority, overrides all thresholds
result = large_df.join(broadcast(small_df), "key")

# Auto-broadcast if table < autoBroadcastJoinThreshold
spark.conf.set("spark.sql.autoBroadcastJoinThreshold", str(50 * 1024 * 1024))
```

**Key difference**:
- Broadcast variable: any Python object, used in UDFs/maps
- Broadcast join: structured DataFrame, Catalyst-aware, produces `BroadcastHashJoin` in plan (no shuffle)

**How broadcast joins break**:
- Table is actually 2 GB but stats say 5 MB → driver attempts to broadcast 2 GB → driver OOM
- Table is borderline size and grows over time → previously working job starts OOMing on the driver
- Full outer join → broadcast not supported, falls back to SMJ silently

**Practical size limit**: Driver memory is the constraint. Keep broadcast tables < 200 MB for safety; up to ~2 GB if driver has 8+ GB heap.

---

## Predicate Pushdown

Filters evaluated at the storage layer — before data enters Spark memory. Most impactful optimization for I/O-bound jobs.

### How to check

```python
df.filter(col("status") == "active").explain(mode="formatted")
# Look for: PushedFilters: [EqualTo(status, active)] in FileScan node
```

### When it works vs fails

```python
# WORKS — literal filter on raw column
df.filter(col("status") == "active")

# WORKS — multiple filters on raw columns
df.filter((col("status") == "active") & (col("amount") > 100))

# FAILS — UDF on filter column
df.filter(clean_udf(col("status")) == "active")

# FAILS — transformation before filter
df.filter(upper(col("status")) == "ACTIVE")
# Fix: store data in uppercase, filter on raw column

# FAILS — filter on derived column
df.withColumn("clean_status", trim(col("status"))) \
  .filter(col("clean_status") == "active")
# Fix: df.filter(trim(col("status")) == "active")
# Some trims/casts ARE pushed down — check with explain()
```

### Partition filter vs column filter

```
PartitionFilters: [isnotnull(date#3), (date#3 = 2024-01-01)]  ← directory-level skip
PushedFilters:    [IsNotNull(status), EqualTo(status, active)] ← row-level skip within files
```

Partition filters skip entire directories. Column filters skip row groups within Parquet files. Both appear in the `FileScan` node.

---

## File Format Decisions

| Format | Columnar | Predicate Pushdown | Schema Evolution | Best For |
|--------|----------|--------------------|------------------|----------|
| **Delta Lake** | Yes (Parquet) | Yes + stats + DPP | Yes (full) | All Databricks production tables |
| **Parquet** | Yes | Yes (min/max, bloom) | Additive only | Read-heavy analytics, cross-platform |
| **ORC** | Yes | Yes (indexes, bloom) | Additive only | Hive/Presto-heavy environments |
| **Avro** | No (row) | No | Excellent | Schema-evolution-heavy streaming, Kafka |
| **JSON/CSV** | No | No | Yes | Ingestion only — never store analytics data here |

**Delta advantages for ETL/joins on Databricks**:
- ACID transactions: concurrent reads/writes safe
- Time travel: `VERSION AS OF`, `TIMESTAMP AS OF` for debugging
- Schema enforcement: bad data fails loudly
- `MERGE INTO` for upserts: single-pass CDC handling
- Delta Cache (SSDs): subsequent reads from same data 5–10× faster
- Streaming + batch unified: same table, same API

---

## Repartition Before Write

```python
# Problem: 1000 shuffle partitions → 1000 tiny output files
df.groupBy("dept").agg(F.sum("salary")).write.format("delta").save("path")
# → 1000 files × maybe 1 KB each = massive small files problem

# Fix option 1: coalesce (no shuffle, but potentially uneven)
df.groupBy("dept").agg(F.sum("salary")).coalesce(10) \
  .write.format("delta").save("path")

# Fix option 2: repartition (even distribution, one shuffle)
df.groupBy("dept").agg(F.sum("salary")).repartition(10) \
  .write.format("delta").save("path")

# Fix option 3: optimizeWrite (Databricks, handles it automatically)
spark.conf.set("spark.databricks.delta.optimizeWrite.enabled", "true")
df.groupBy("dept").agg(F.sum("salary")).write.format("delta").save("path")
```

---

## AQE: What It Fixes Automatically

With `spark.sql.adaptive.enabled=true` (default in Spark 3.2+):

| Problem | AQE Solution | Config |
|---------|-------------|--------|
| Too many small shuffle partitions | Coalesces small partitions into larger ones | `coalescePartitions.enabled` |
| SMJ on a table that's actually small | Converts SMJ → BHJ at runtime | `autoBroadcastJoinThreshold` |
| Skewed join partitions | Splits fat partitions and replicates matching side | `skewJoin.enabled` |
| Wrong partition count for next stage | Adjusts partition count based on actual data | `advisoryPartitionSizeInBytes` |

**AQE does NOT fix**:
- Missing predicate pushdown (happens before execution)
- Wrong join strategy due to missing broadcast hint on a large table
- GROUP BY skew (only join skew)
- Small files on the write side

---

## Query Anti-Patterns

### Anti-pattern 1: `count()` in a loop

```python
# NEVER — each count() is a full job
for table in tables:
    if spark.read.parquet(path).filter(col("status") == "A").count() > 0:
        process(table)

# Better — union and count once
from functools import reduce
dfs = [spark.read.parquet(p).filter(col("status") == "A").withColumn("t", lit(t))
       for t, p in tables.items()]
combined = reduce(lambda a, b: a.union(b), dfs)
counts = combined.groupBy("t").count().collect()
```

### Anti-pattern 2: `collect()` on large DataFrames

```python
# BAD — brings all data to driver
all_rows = df.collect()  # OOM if df > driver memory

# Better — use write() or limit()
df.write.format("delta").save("path")
df.limit(1000).toPandas()  # for sampling/inspection only
```

### Anti-pattern 3: Repeated reads without caching

```python
# BAD — reads S3 3 times
df = spark.read.parquet("s3://bucket/table/")
count = df.count()
summary = df.groupBy("dept").agg(F.sum("salary"))
filtered = df.filter(col("status") == "active")

# GOOD — read once, cache, reuse
df = spark.read.parquet("s3://bucket/table/").cache()
df.count()  # materialize
count = df.count()  # from cache
summary = df.groupBy("dept").agg(F.sum("salary"))  # from cache
filtered = df.filter(col("status") == "active")    # from cache
df.unpersist()
```

### Anti-pattern 4: Wide transformations before unnecessary columns

```python
# BAD — joins all columns then filters
result = df1.join(df2, "id") \
            .join(df3, "id") \
            .select("id", "name", "value")  # only 3 columns needed

# GOOD — project early to reduce shuffle data volume
df1_slim = df1.select("id", "name")
df2_slim = df2.select("id", "value")
result = df1_slim.join(df2_slim, "id")
```

### Anti-pattern 5: Python UDF where native function exists

```python
# BAD
from pyspark.sql.functions import udf
from pyspark.sql.types import StringType
extract_year = udf(lambda d: str(d)[:4], StringType())
df.withColumn("year", extract_year("date_col"))

# GOOD — 10–100× faster, Catalyst-transparent
from pyspark.sql.functions import year
df.withColumn("year", year("date_col"))
```

### Anti-pattern 6: `orderBy` inside a window with global sort

```python
# BAD — global sort before window = extra Exchange + Sort
df.orderBy("salary") \
  .withColumn("rank", F.rank().over(Window.partitionBy("dept").orderBy("salary")))

# The Window already sorts within each partition — the global orderBy is redundant
# GOOD
df.withColumn("rank", F.rank().over(Window.partitionBy("dept").orderBy("salary")))
```

---

## Execution Model: Stages, Tasks, and Data Flow

Understanding the mental model prevents misdiagnosis:

```
DataFrame API call
      ↓ (lazy — no work yet)
Catalyst optimizer → logical plan → physical plan
      ↓ (triggered by action: .count(), .write(), .show())
Spark job
  ├── Stage 1 (tasks reading from source)
  │     ├── Task 0: reads partition 0
  │     ├── Task 1: reads partition 1
  │     └── ...N tasks (one per input partition)
  │           ↓ (shuffle write)
  ├── Exchange (shuffle boundary)
  │           ↓ (shuffle read)
  ├── Stage 2 (tasks after shuffle)
  │     ├── Task 0: reads shuffle partition 0
  │     └── ...M tasks (spark.sql.shuffle.partitions or AQE-determined)
  └── ...
```

**Parallelism levers**:
- Input tasks: controlled by `maxPartitionBytes` and number of input files
- Shuffle tasks: controlled by `spark.sql.shuffle.partitions` (then AQE coalesces)
- Output files: controlled by number of tasks in last stage (or `coalesce`/`repartition`)

---

## Choosing the Right Fix

| Symptom | Likely Cause | Fix |
|---------|-------------|-----|
| One task runs 10× longer | Data skew | AQE skew join / salting |
| All tasks run slowly | Under-parallelism or slow I/O | More partitions, check source bottleneck |
| Shuffle Spill (Disk) > 0 | Execution memory exhausted | More partitions, more memory, broadcast join |
| GC Time > 20% | Too many cores per executor | Reduce `executor.cores`, increase `executor.memory` |
| Executor Dead | Container OOM | Increase `memoryOverhead` (Python/Arrow) or `executor.memory` (JVM) |
| 50,000 tiny input tasks | Small files | `openCostInBytes`, `maxPartitionBytes`, OPTIMIZE table |
| SMJ on 5 MB dimension | Broadcast threshold too low | Raise `autoBroadcastJoinThreshold` or use `broadcast()` hint |
| Filter not pushed down | UDF/transform on filter column | Filter raw column directly before any transformation |
| DPP not firing | Fact not partitioned on join key | Re-partition fact table on join key at write time |
| AQE not coalescing | `parallelismFirst=true` | Set `parallelismFirst=false`, set `minPartitionSize=32m` |
| Python UDF slow | Row-by-row serialization | Replace with native function or Pandas UDF |
