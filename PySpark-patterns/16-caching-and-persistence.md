<!-- PySpark-patterns: Caching and Persistence -->

# Caching and Persistence

## How Caching Works

Caching stores the materialized result of a DataFrame (after all its transformations)
in executor memory and/or disk so it doesn't need to be recomputed on subsequent actions.

**Cache is lazy** — calling `.cache()` marks the DataFrame for caching but does NOT
execute. The cache is populated on the first action that touches the DataFrame.

```python
from pyspark.sql import functions as F

df = spark.read.parquet("/data/large_table/") \
    .filter(F.col("year") == 2024) \
    .withColumn("revenue_adj", F.col("revenue") * 1.1)

df.cache()       # marks for caching — nothing happens yet
df.count()       # FIRST action: reads data, computes transformations, stores in cache
df.show()        # SECOND action: reads from cache — fast
df.groupBy("region").agg(F.sum("revenue_adj")).show()  # also from cache
```

---

## df.cache() vs df.persist()

`df.cache()` is equivalent to `df.persist(StorageLevel.MEMORY_AND_DISK)`.

```python
from pyspark import StorageLevel

df.cache()                                    # MEMORY_AND_DISK (default)
df.persist()                                  # same as cache()
df.persist(StorageLevel.MEMORY_ONLY)          # only memory; recomputed if evicted
df.persist(StorageLevel.MEMORY_AND_DISK)      # spills to disk if memory full
df.persist(StorageLevel.DISK_ONLY)            # disk only; slower but always available
df.persist(StorageLevel.OFF_HEAP)             # off-heap memory (requires config)
df.persist(StorageLevel.MEMORY_ONLY_2)        # MEMORY_ONLY with 2x replication (fault tolerant)
```

### Storage Level Trade-offs

| Level | Speed | Memory Use | Fault Tolerant |
|-------|-------|-----------|---------------|
| MEMORY_ONLY | Fastest | High | No (recomputed on eviction) |
| MEMORY_AND_DISK | Fast | Medium | Yes (spills to disk) |
| DISK_ONLY | Slow | Low | Yes |
| OFF_HEAP | Fast | Configurable | No GC pressure |

---

## When to Cache

**Cache when:**
- The DataFrame is used 2 or more times in the same job
- The DataFrame is expensive to compute (many joins, aggregations, UDFs)
- Iterative algorithms (ML training loops) that reuse the same base data

```python
# Good use case: two aggregations over the same expensive DataFrame
base = expensive_df.cache()
base.count()   # materialize

report_1 = base.groupBy("region").agg(F.sum("revenue"))
report_2 = base.groupBy("product").agg(F.avg("margin"))
```

---

## When NOT to Cache

**Do not cache when:**
- The DataFrame is used only once
- The DataFrame is too large to fit in memory (or only marginally fits — eviction thrashing)
- You are reading from a fast source (Delta with caching layer, Alluxio)
- The computation is cheap (simple filter + select)

```python
# No benefit — each DataFrame used only once
df1 = raw.filter(F.col("year") == 2023).cache()   # wasted cache
df2 = raw.filter(F.col("year") == 2024).cache()   # wasted cache
```

---

## Releasing Cache — unpersist()

Always unpersist DataFrames when you no longer need them.
Spark's LRU eviction eventually clears them, but:
- You can't control when — you may evict other useful cached data
- In long-running jobs, memory fills up

```python
df.unpersist()               # release immediately (blocking)
df.unpersist(blocking=True)  # same — waits until cache is cleared

# Check if a DataFrame is cached
df.is_cached   # True or False
```

---

## Checkpoint vs Cache

### Cache
- Stores data in executor memory/disk
- Lineage (DAG) is preserved — Spark can recompute from source if needed
- Data is lost if executor fails and data was in MEMORY_ONLY

### Checkpoint
- Stores data to a reliable distributed filesystem (HDFS, S3, DBFS)
- **Breaks lineage** — Spark no longer knows how to recompute from source
- Used for long iterative algorithms to avoid recomputing the full lineage chain

```python
# Set checkpoint directory first
spark.sparkContext.setCheckpointDir("/checkpoints/my-job/")

df.checkpoint()         # materialize and write to checkpoint dir (blocking)
df.localCheckpoint()    # write to executor local disk (faster, less reliable)
```

**Use checkpoint when:**
- DAG has hundreds of stages (iterative ML, graph algorithms)
- The lineage is so long that recomputation from scratch would be catastrophic
- You want to cut the plan for debugging

---

## Caching Named Temp Views

When you register a cached DataFrame as a temp view, the cache is preserved
and SQL queries against that view also use the cache.

```python
df.cache()
df.createOrReplaceTempView("sales")
df.count()  # materialize cache

spark.sql("SELECT region, SUM(revenue) FROM sales GROUP BY region").show()
# Uses the cached data
```

---

## Checking Cache Usage in Spark UI

1. Open Spark UI -> **Storage** tab
2. You'll see all cached DataFrames with:
   - Memory used
   - Disk used
   - Number of partitions cached
   - Fraction cached (if partial eviction happened)

If a cache is only 80% in memory, the other 20% will be recomputed on access.

---

## Common Cache Bugs

### Bug: reassigning the variable after cache

```python
df = df.filter(F.col("year") == 2024)
df.cache()     # marks this DataFrame for caching
df = df.select("id", "name")   # creates a new DataFrame — the cached one is orphaned
df.count()     # materializes the NEW DataFrame (not cached), original cache never used
```

Fix: use a separate variable or call `cache()` on the final form:
```python
df_filtered = df.filter(F.col("year") == 2024).select("id", "name")
df_filtered.cache()
df_filtered.count()
```

### Bug: caching before a filter (caching too much)

```python
# BAD: caches all data, then filters
df.cache()
df.count()
df.filter(F.col("region") == "US").show()  # reads all 1TB from cache, then filters

# GOOD: filter first, then cache only what you need
df_us = df.filter(F.col("region") == "US").cache()
df_us.count()
df_us.show()
```
