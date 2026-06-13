<!-- PySpark-patterns: Duplicate Deep Dive -->

# Duplicate Deep Dive

## Three Duplicate Types

### 1. Exact Duplicates
Every column is identical. Typically from double-ingestion, retry logic, or CDC issues.

```python
# Detection
total = df.count()
unique = df.distinct().count()
print(f"Exact duplicates: {total - unique}")
```

### 2. Soft Duplicates (Same Business Key, Different Metadata)
Same `order_id`, but different `updated_at`, `status`, or `load_timestamp`.
This is the most common type in data pipelines.

```python
# Detection: find keys with multiple rows
df.groupBy("order_id") \
  .count() \
  .filter(F.col("count") > 1) \
  .orderBy(F.col("count").desc()) \
  .show()
```

### 3. Fuzzy Duplicates
Same entity, slightly different representation. Requires distance-based matching.

```python
# String similarity: Levenshtein distance
df.withColumn(
    "similarity",
    F.levenshtein(F.col("name_a"), F.col("name_b"))
)
# Or use soundex for phonetic matching
F.soundex(F.col("name"))
```

---

## Detecting Fan-Out in Joins

Fan-out happens when the right table has duplicate keys — each left row matches
multiple right rows, multiplying the row count.

```python
# Before join
left_count = orders.count()

# After join
result = orders.join(order_items, on="order_id", how="left")
after_count = result.count()

ratio = after_count / left_count
print(f"Fan-out ratio: {ratio:.2f}x")
# Ratio > 1.0 means fan-out occurred
# Ratio >> 1.0 means serious duplication in right table or wrong join key
```

### Finding the Fan-Out Source

```python
# Check if the right table has duplicate join keys
order_items.groupBy("order_id") \
           .count() \
           .filter(F.col("count") > 1) \
           .show()
```

---

## Common Sources of Duplicates in Pipelines

### 1. Explode on arrays

```python
df = spark.createDataFrame([
    (1, ["tag_a", "tag_b"]),
    (2, ["tag_c"])
], ["id", "tags"])

exploded = df.select("id", F.explode("tags").alias("tag"))
# id=1 now has 2 rows — one per tag
# Any aggregation on id will double-count id=1 if not careful
```

### 2. Joins without unique right-side key

```python
# If orders has order_status history (multiple statuses per order_id):
orders.join(status_history, on="order_id")
# Each order gets multiple rows — one per status change
```

### 3. Duplicate source records

```python
# CDC extract has the same event twice
# EL tools retry on failure and load data twice
```

### 4. UNION without DISTINCT

```python
# union() keeps all rows including duplicates
df1.union(df2)            # may create duplicates if rows overlap

# unionByName() same behavior
df1.unionByName(df2)      # same, column order doesn't matter

# To deduplicate after union:
df1.union(df2).distinct()
```

---

## Dedup Strategies

### Exact Dedup

```python
df.distinct()                              # all columns must match
df.dropDuplicates()                        # equivalent
df.dropDuplicates(["order_id"])            # dedup on subset
```

### ROW_NUMBER Dedup — Keep Latest

```python
from pyspark.sql import Window

w = Window.partitionBy("order_id").orderBy(F.col("updated_at").desc_nulls_last())

df_deduped = df \
    .withColumn("rn", F.row_number().over(w)) \
    .filter(F.col("rn") == 1) \
    .drop("rn")
```

### ROW_NUMBER Dedup — Keep Earliest

```python
w = Window.partitionBy("order_id").orderBy(F.col("created_at").asc_nulls_last())
df.withColumn("rn", F.row_number().over(w)) \
  .filter(F.col("rn") == 1).drop("rn")
```

### Aggregate Dedup (For Numeric Columns)

```python
# If you only need the latest value of each column per key:
df.groupBy("order_id").agg(
    F.max("updated_at").alias("updated_at"),
    F.last("status", ignorenulls=True).alias("status"),
    F.sum("amount").alias("total_amount")   # dangerous if amounts are duplicated
)
```

---

## How Duplicates Break Aggregations

```python
# orders table has order_id=101 duplicated 3 times with amount=500

# Wrong: counts 3 rows, not 1 order
df.groupBy("customer_id").agg(F.count("order_id").alias("order_count"))

# Wrong: sums 1500 instead of 500
df.groupBy("customer_id").agg(F.sum("amount").alias("total_spent"))

# Wrong: 3 distinct amounts? No — 1. But would be wrong if each duplicate had different amount
df.groupBy("customer_id").agg(F.countDistinct("order_id").alias("unique_orders"))
# This one is actually CORRECT — countDistinct handles dups on the key column
```

Fix: dedup on `order_id` before aggregating.

---

## How Duplicates Propagate Through a Pipeline

```python
# Stage 1: Source has duplicates
raw = spark.read.parquet("/raw/orders/")  # order_id 101 appears 3 times

# Stage 2: Filter doesn't remove duplicates (still 3 rows for id 101)
filtered = raw.filter(F.col("status") == "shipped")

# Stage 3: Join fans out further (each of the 3 rows joins to 2 line items)
joined = filtered.join(line_items, on="order_id")  # now 6 rows for id 101

# Stage 4: Aggregation is wrong
result = joined.groupBy("customer_id").agg(F.sum("amount"))
# amount for customer with order 101 is 6x what it should be
```

**Dedup as early as possible** — at the raw layer, before joins and aggregations.

---

## Duplicate Audit Pattern

```python
def check_duplicates(df, key_cols, name="DataFrame"):
    total = df.count()
    unique = df.dropDuplicates(key_cols).count()
    dupe_count = total - unique
    dupe_pct = (dupe_count / total * 100) if total > 0 else 0
    print(f"{name}: {total} rows, {unique} unique on {key_cols}, {dupe_count} duplicates ({dupe_pct:.1f}%)")
    if dupe_count > 0:
        df.groupBy(key_cols).count().filter(F.col("count") > 1).orderBy(F.col("count").desc()).show(10)

check_duplicates(orders_df, ["order_id"], "orders")
```
