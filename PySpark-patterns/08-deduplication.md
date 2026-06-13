<!-- PySpark-patterns: Deduplication -->

# Deduplication

## Three Types of Duplicates

1. **Exact duplicates** — every column is identical; same row appears multiple times
2. **Soft duplicates** — same business key, different metadata (e.g., two rows for same `order_id` with different `updated_at`)
3. **Fuzzy duplicates** — similar but not identical (e.g., "John Smith" vs "Jon Smith"); requires ML or custom logic

---

## Detecting Duplicates

```python
from pyspark.sql import functions as F

# Quick check: total rows vs distinct rows
total = df.count()
distinct = df.distinct().count()
print(f"Duplicates: {total - distinct}")

# Find which keys have duplicates
df.groupBy("order_id") \
  .count() \
  .filter(F.col("count") > 1) \
  .show()

# Count duplicate rows by key
dupes = df.groupBy("order_id").agg(F.count("*").alias("cnt"))
dupes.filter(F.col("cnt") > 1).show()
```

---

## df.distinct() — Exact Dedup

Removes rows that are completely identical across all columns.

```python
df_deduped = df.distinct()
```

Triggers a full shuffle — every row must be compared with every other row globally.
Expensive on large datasets.

Equivalent to:
```python
df.dropDuplicates()   # no arguments = distinct on all columns
```

---

## df.dropDuplicates() — Subset Dedup

Keeps the first occurrence of each unique combination of specified columns.
"First" is non-deterministic unless you sort first.

```python
# Dedup on specific columns — keep first occurrence
df.dropDuplicates(["order_id"])

# Dedup on composite key
df.dropDuplicates(["customer_id", "product_id", "order_date"])
```

**Prefer `dropDuplicates(subset)` over `distinct()`** when:
- You only care about uniqueness on a subset of columns
- You want to avoid shuffling unnecessary column data

Still triggers a shuffle, but only on the subset columns.

---

## ROW_NUMBER Dedup — Keep Latest by Timestamp

Use when you want deterministic control over which duplicate to keep.

```python
from pyspark.sql import Window

w = Window.partitionBy("order_id").orderBy(F.col("updated_at").desc())

df_deduped = df \
    .withColumn("rn", F.row_number().over(w)) \
    .filter(F.col("rn") == 1) \
    .drop("rn")
```

This is the standard "keep most recent record" pattern:
- Partitions by business key (`order_id`)
- Orders by timestamp descending (most recent = row 1)
- Keeps only row 1 per partition

**NULLs in the ORDER BY column:** NULLs sort FIRST in descending order by default.
A row with NULL `updated_at` would be selected as "most recent" — almost certainly wrong.

Fix:
```python
w = Window.partitionBy("order_id").orderBy(F.col("updated_at").desc_nulls_last())
```

---

## How Duplicates Break Aggregations

```python
# orders table has duplicated rows for order_id 101
# order_id 101 appears 3 times with amount = 500 each

df.groupBy("customer_id").agg(F.sum("amount"))
# Customer's total is 1500 instead of 500 — 3x inflation

# Fix: dedup before aggregating
df.dropDuplicates(["order_id"]) \
  .groupBy("customer_id") \
  .agg(F.sum("amount"))
```

**count(*) is always wrong if there are duplicates** — it counts every occurrence.
Use `countDistinct("order_id")` to count unique orders.

---

## How Duplicates Break Joins (Fan-Out)

If the right table has duplicate keys, a join multiplies the left table rows.

```python
# orders: 1000 rows, one per order_id
# order_items: has duplicate order_id rows (3 items per order on average)

result = orders.join(order_items, on="order_id", how="left")
# result has 3000 rows — each order row appears 3 times

# If you then sum order.amount:
result.groupBy("customer_id").agg(F.sum("amount"))
# amount is counted 3 times per order — wrong
```

**Always verify row counts after joins:**

```python
before = orders.count()
after = orders.join(order_items, on="order_id", how="left").count()
print(f"Fan-out ratio: {after / before:.2f}x")
# Expected ~1.0 for a lookup join; > 1 means fan-out
```

---

## Dedup with Null Business Keys

If the business key can be NULL, `dropDuplicates` treats all NULL keys as duplicates
of each other (only one NULL-key row is kept).

```python
# Both rows have order_id = NULL — dropDuplicates keeps only one
df = spark.createDataFrame([(None, "a"), (None, "b")], ["order_id", "val"])
df.dropDuplicates(["order_id"]).show()
# Only one row remains — which one is non-deterministic
```

If NULL keys are valid and should be kept:
```python
# Separate NULL-key rows, dedup the non-NULL rows, then union
null_rows = df.filter(F.col("order_id").isNull())
non_null = df.filter(F.col("order_id").isNotNull()).dropDuplicates(["order_id"])
result = non_null.union(null_rows)
```

---

## Scale Considerations

| Method | Shuffle? | When to Use |
|--------|---------|-------------|
| `distinct()` | Full shuffle on all columns | Small data; all columns matter |
| `dropDuplicates(subset)` | Shuffle on subset columns | Large data; only key columns matter |
| `ROW_NUMBER()` dedup | Full shuffle (window partition) | Need to control which row to keep |

For very large datasets, consider **early dedup** — deduplicate at the earliest
stage of the pipeline before any joins or aggregations to reduce data volume.

```python
# Dedup raw data immediately after read
raw = spark.read.parquet("/raw/events")
raw_deduped = raw.dropDuplicates(["event_id"])  # dedup before any processing
```
