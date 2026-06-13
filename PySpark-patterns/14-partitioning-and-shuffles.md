<!-- PySpark-patterns: Partitioning and Shuffles -->

# Partitioning and Shuffles

## What Triggers a Shuffle

A shuffle redistributes data across the cluster so that rows with the same key
end up on the same partition. It writes intermediate data to disk (shuffle files)
and reads it back — this is the most expensive operation in Spark.

**Operations that trigger a shuffle (wide transformations):**

| Operation | Why it Shuffles |
|-----------|----------------|
| `groupBy().agg()` | All rows with same group key must be on same partition |
| `join()` (SortMergeJoin) | Matching keys from both tables must co-locate |
| `orderBy()` / `sort()` | Global sort requires full data redistribution |
| `distinct()` | Must compare rows globally |
| `repartition(n)` | Explicit redistribution |
| `cogroup()` | RDD-level operation |

**No shuffle:** `filter`, `select`, `withColumn`, `union`, `coalesce` (mostly)

---

## repartition() vs coalesce()

### repartition(n) — Full Shuffle

```python
df.repartition(100)               # shuffle to exactly 100 partitions, even distribution
df.repartition(100, "date")       # shuffle by column — rows with same date colocate
df.repartition("date", "region")  # shuffle by multiple columns
```

- Triggers a full shuffle
- Produces evenly distributed partitions
- Use BEFORE wide operations to control parallelism
- Use when current partitions are heavily skewed

### coalesce(n) — No Shuffle (Usually)

```python
df.coalesce(10)   # merge partitions down to 10 without a full shuffle
```

- Does NOT trigger a full shuffle
- Just merges adjacent partitions
- Only works for reducing partition count (not increasing)
- Produces skewed partitions if reducing heavily (e.g., 200 -> 10)

```python
# Typical use: reduce partition count before writing small output
df.filter(F.col("status") == "error") \
  .coalesce(1) \
  .write.mode("overwrite").csv("/output/errors/")
```

**Risk with coalesce:** merging 200 partitions into 10 puts 20 partitions on each
resulting partition. If data was already skewed, it stays skewed.

---

## spark.sql.shuffle.partitions

```python
spark.conf.set("spark.sql.shuffle.partitions", "200")  # default
```

Controls the number of partitions created AFTER every shuffle.

**Too many (e.g., 2000 for 1 GB data):**
- 2000 tiny partitions
- Task scheduling overhead dominates
- Many tiny files written on output

**Too few (e.g., 10 for 1 TB data):**
- Each partition handles 100 GB
- OOM or heavy disk spill
- Job is slow

**With AQE enabled (Spark 3.2+ default):**
`shuffle.partitions` becomes a target maximum. AQE coalesces small partitions
automatically, so you can set it higher (e.g., 1000) and let AQE tune down.

---

## Partition on Write: partitionBy()

```python
# Write data partitioned by columns — creates directory structure
df.write \
  .mode("overwrite") \
  .partitionBy("year", "month") \
  .parquet("/data/sales/")

# Creates:
# /data/sales/year=2024/month=01/part-00000.parquet
# /data/sales/year=2024/month=02/part-00000.parquet
# ...
```

### How Predicate Pushdown Works with Partitioned Data

```python
# Reads ONLY the 2024/01 directory — skips all other data on disk
spark.read.parquet("/data/sales/") \
    .filter((F.col("year") == 2024) & (F.col("month") == 1))
```

This is called **partition pruning** — the most powerful filter optimization.
Verify it worked with `.explain()` — look for `PartitionFilters` in the plan.

**Partition on write is NOT the same as `repartition()` in memory.**
`partitionBy` determines the directory layout on disk, not the in-memory partitions.

---

## Optimal Partition Size

Target 100–200 MB of uncompressed data per partition:
- Too small (< 10 MB): too many tasks, scheduling overhead
- Too large (> 1 GB): OOM risk, spill to disk

```python
# Estimate partition size
total_gb = 500
target_partition_mb = 128
n_partitions = int((total_gb * 1024) / target_partition_mb)  # ~4000 partitions
spark.conf.set("spark.sql.shuffle.partitions", str(n_partitions))
```

---

## How Skew Breaks Performance

Skew occurs when one partition key has far more rows than others.

```python
# Check partition sizes in memory
df.rdd.mapPartitions(lambda x: [sum(1 for _ in x)]).collect()
# Shows row count per partition — look for extreme outliers
```

**Symptoms in Spark UI:**
- Stage has 200 tasks, 199 complete in 10s, 1 takes 30 minutes
- Task Duration histogram shows one outlier bar far to the right
- One task's "Shuffle Read Size" is 10x the median

**Causes:**
- Joining on a column where one value dominates (e.g., `country = "US"`)
- GroupBy on a low-cardinality column
- Data not evenly distributed after repartition by a skewed column

**Fixes:** See `15-broadcast-and-skew-joins.md` for salting patterns.
See `21-aqe-and-performance.md` for AQE automatic skew handling.

---

## Number of Output Files on Write

Each in-memory partition becomes one output file (unless explicitly coalesced).

```python
# 200 shuffle partitions -> 200 output files per partition directory
df.write.partitionBy("date").parquet("/output/")
# If 365 date values and 200 shuffle partitions: 365 * 200 = 73,000 files

# Fix: repartition within each partition value before writing
df.repartition(10, "date") \
  .write.partitionBy("date").parquet("/output/")
# 365 * 10 = 3,650 files — more manageable
```

**Too many small files** degrades read performance significantly (each file requires
a separate filesystem operation to open).

For Delta Lake, use `OPTIMIZE` to compact small files after writes.
