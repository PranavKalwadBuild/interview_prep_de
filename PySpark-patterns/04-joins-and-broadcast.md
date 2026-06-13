<!-- PySpark-patterns: Joins and Broadcast -->

# Joins and Broadcast

## Join Types

```python
from pyspark.sql import functions as F

# Inner join — only matching rows
df1.join(df2, on="id", how="inner")

# Left join — all rows from df1, matched rows from df2 (NULLs for no match)
df1.join(df2, on="id", how="left")

# Right join — all rows from df2, matched rows from df1
df1.join(df2, on="id", how="right")

# Full outer join — all rows from both, NULLs where no match
df1.join(df2, on="id", how="full")        # or how="outer"

# Left semi join — only rows from df1 that HAVE a match in df2 (no df2 columns)
df1.join(df2, on="id", how="left_semi")   # equivalent to WHERE EXISTS

# Left anti join — only rows from df1 that DO NOT have a match in df2
df1.join(df2, on="id", how="left_anti")   # equivalent to WHERE NOT EXISTS

# Cross join — every row in df1 with every row in df2 (Cartesian product)
df1.crossJoin(df2)                         # explicit; requires spark.sql.crossJoin.enabled=true
df1.join(df2, how="cross")
```

## Which Table Goes Left vs Right

**Anchor (larger) table goes LEFT. Dimension (smaller) table goes RIGHT.**

This is the same anchor-left convention as SQL.

```python
# Correct: fact table left, dimension right
orders.join(customers, on="customer_id", how="left")

# For broadcast joins: the RIGHT side is what gets broadcast
orders.join(F.broadcast(customers), on="customer_id", how="left")
```

---

## Shuffle Join vs Broadcast Join

### Shuffle Join (SortMergeJoin — default for large tables)

Both tables are shuffled so matching keys land on the same partition, then merged.

- **Cost:** 2 full shuffles (one per table)
- **Memory:** proportional to one partition of each table
- **When used:** both tables are large (above broadcast threshold)

```
Table A (partitioned by key)    Table B (partitioned by key)
      |                                |
      +------------ Exchange ----------+
              (shuffle by join key)
                      |
               SortMergeJoin
```

### Broadcast Join (BroadcastHashJoin — for small tables)

The small table is collected by the driver and broadcast to every executor.
No shuffle of the large table.

- **Cost:** one broadcast of the small table
- **Memory:** small table must fit in executor memory (and driver memory)
- **When used:** one table is smaller than `spark.sql.autoBroadcastJoinThreshold` (default 10MB)

```python
# Explicit broadcast hint
result = large_df.join(F.broadcast(small_df), on="id", how="left")

# Auto-broadcast: happens automatically if small_df statistics < 10MB threshold
# Disable auto-broadcast:
spark.conf.set("spark.sql.autoBroadcastJoinThreshold", "-1")
```

---

## NULL Key Behavior

NULL keys never match in any join — same as SQL.

```python
df1 = spark.createDataFrame([(1, "a"), (None, "b")], ["id", "val1"])
df2 = spark.createDataFrame([(1, "x"), (None, "y")], ["id", "val2"])

result = df1.join(df2, on="id", how="inner")
# Result: only (1, "a", "x") — the NULL rows do NOT match each other
```

**Fix for NULL-safe join:** use `eqNullSafe()` (treats NULL == NULL as true)

```python
result = df1.join(df2, df1["id"].eqNullSafe(df2["id"]), how="inner")
# Now NULL rows match: (None, "b", "y") is included
```

Or coalesce the key before joining:
```python
df1 = df1.withColumn("id_safe", F.coalesce(F.col("id"), F.lit(-1)))
df2 = df2.withColumn("id_safe", F.coalesce(F.col("id"), F.lit(-1)))
df1.join(df2, on="id_safe")
```

---

## How Joins Break: Cartesian Explosion

If a join key is not selective (e.g., joining on `region` where both tables have 1M rows per region),
the result explodes in size.

```python
# Both tables have 1M rows per region -> result has 1M * 1M = 1 trillion rows per region
df1.join(df2, on="region")   # DANGER if region is not unique in df2
```

Always check: is the join key unique in the right table?
If not, expect fan-out — post-join row count > pre-join row count.

```python
# Check before joining
print(df2.select("id").distinct().count() == df2.count())  # True = id is unique
```

---

## Skew in Joins

A skewed join happens when one key value appears millions of times in both tables,
causing one reducer task to process the majority of the data.

**Symptom:** one task in the join stage takes 100x longer than others.

### Fix 1: AQE Skew Join (automatic, Spark 3.0+)

```python
spark.conf.set("spark.sql.adaptive.skewJoin.enabled", "true")
# AQE auto-detects skewed partitions and splits them
```

### Fix 2: Salting (manual, works pre-Spark 3.0 or for extreme skew)

The idea: add a random salt to the skewed key to split it across N reducers.
The small table must be replicated N times to match.

```python
import random

SALT_BUCKETS = 10

# Salt the large table
large_df = large_df.withColumn(
    "salt", (F.rand() * SALT_BUCKETS).cast("int")
).withColumn(
    "salted_key", F.concat_ws("_", F.col("join_key"), F.col("salt"))
)

# Replicate the small table for every salt value
salt_values = spark.range(SALT_BUCKETS).withColumnRenamed("id", "salt")
small_df_replicated = small_df.crossJoin(salt_values).withColumn(
    "salted_key", F.concat_ws("_", F.col("join_key"), F.col("salt").cast("string"))
)

# Join on salted key
result = large_df.join(small_df_replicated, on="salted_key", how="left") \
    .drop("salt", "salted_key")
```

---

## Join on Multiple Keys

```python
# List of column names (same name in both DataFrames)
df1.join(df2, on=["order_id", "date"], how="inner")

# Expression (for different column names or complex conditions)
df1.join(df2,
    on=(df1["order_id"] == df2["order_id"]) & (df1["date"] == df2["txn_date"]),
    how="left"
)
```

When joining with expressions (not string column names), both join key columns
will appear in the result. Drop duplicates:
```python
result = df1.join(df2, on=(df1["id"] == df2["id"]), how="left") \
    .drop(df2["id"])
```

---

## Non-Equi Joins (Range Joins)

```python
# Join where df1.start <= df2.date <= df1.end
result = df1.join(df2,
    on=(df2["date"] >= df1["start"]) & (df2["date"] <= df1["end"]),
    how="inner"
)
```

Non-equi joins cannot use hash join or SortMergeJoin efficiently.
Spark falls back to a nested loop (BroadcastNestedLoopJoin) if one side can be broadcast,
or a Cartesian product otherwise — extremely expensive at scale.

**Minimize range join input sizes** before performing the join.
