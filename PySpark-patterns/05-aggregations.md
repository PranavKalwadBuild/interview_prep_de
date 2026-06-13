<!-- PySpark-patterns: Aggregations -->

# Aggregations

## .groupBy().agg() — The Correct Pattern

Always combine all aggregations in a single `.agg()` call.

```python
from pyspark.sql import functions as F

# GOOD: one shuffle, one HashAggregate stage
result = df.groupBy("region", "product") \
    .agg(
        F.count("*").alias("order_count"),
        F.sum("amount").alias("total_amount"),
        F.avg("amount").alias("avg_amount"),
        F.min("amount").alias("min_amount"),
        F.max("amount").alias("max_amount"),
        F.countDistinct("customer_id").alias("unique_customers")
    )
```

### Why Chaining .agg() Calls Is Wrong

```python
# BAD: two shuffles — two separate groupBy operations
result = df.groupBy("region").agg(F.sum("amount").alias("total"))
result = result.groupBy("region").agg(F.count("*").alias("cnt"))
# This also produces wrong results — second groupBy regrouping on an already-aggregated df
```

---

## count() vs countDistinct() vs approx_count_distinct()

```python
F.count("*")                           # count all rows (NULLs included)
F.count("col")                         # count non-NULL values in col
F.countDistinct("col")                 # exact distinct count — triggers a shuffle
F.approx_count_distinct("col", rsd=0.05)  # approximate, much faster at scale
```

### When to Use Approximate

`countDistinct()` requires collecting all values per group to deduplicate — expensive at scale.
`approx_count_distinct()` uses HyperLogLog++ with configurable relative standard deviation.

- `rsd=0.05` — ~5% error, fast (default)
- `rsd=0.01` — ~1% error, slower but still much faster than exact

```python
# Exact — use for small data or when precision is required (e.g., billing)
F.countDistinct("user_id")

# Approximate — use for analytics dashboards, trend analysis
F.approx_count_distinct("user_id", rsd=0.05)
```

---

## NULL Behavior in Aggregations

NULLs are ignored by all aggregation functions except `count(*)`.

```python
# Given: amounts = [100, NULL, 200, NULL, 300]
F.sum("amount")    # = 600  (NULLs skipped)
F.avg("amount")    # = 200  (600 / 3, not 600 / 5)
F.count("amount")  # = 3    (NULLs not counted)
F.count("*")       # = 5    (counts every row including NULL rows)
F.min("amount")    # = 100  (NULLs skipped)
F.max("amount")    # = 300  (NULLs skipped)
```

If ALL values in a group are NULL:
- `sum()`, `avg()`, `min()`, `max()` return NULL
- `count("col")` returns 0
- `count("*")` returns the number of rows

---

## How Duplicates Inflate Counts

```python
# If df has duplicate rows, count(*) counts duplicates
df.groupBy("customer_id").agg(F.count("*").alias("order_count"))
# If orders are duplicated, order_count is inflated

# Fix: dedup before aggregating
df.dropDuplicates(["order_id"]) \
    .groupBy("customer_id") \
    .agg(F.count("*").alias("order_count"))
```

---

## collect_list() and collect_set()

```python
F.collect_list("product")   # all values in group as an array (duplicates kept, order not guaranteed)
F.collect_set("product")    # unique values in group as an array (no duplicates, order not guaranteed)
```

**Order is not guaranteed.** If you need ordered arrays, sort first:
```python
# Sort before collecting using a window function or sort the array after
from pyspark.sql import Window

w = Window.partitionBy("customer_id").orderBy("order_date")
df.withColumn("ranked", F.collect_list("product").over(w))
# Note: this still doesn't guarantee global order within the collected array
# Better approach: sort the resulting array
df.groupBy("customer_id") \
    .agg(F.sort_array(F.collect_list("product")).alias("products"))
```

**OOM risk at scale:** if one group has millions of rows, `collect_list()` builds
a single array per group in executor memory. One large group can OOM an executor.

```python
# Safeguard: limit collection size
df.groupBy("customer_id") \
    .agg(F.slice(F.collect_list("product"), 1, 100).alias("top_100_products"))
```

---

## Pivot

`.pivot()` turns distinct values of a column into new columns.

```python
# Pivot: one row per customer, one column per product category
result = df.groupBy("customer_id") \
    .pivot("category") \
    .agg(F.sum("amount"))
```

**Performance trap:** without specifying the pivot values, Spark runs an extra job
to find all distinct values first.

```python
# GOOD: specify values explicitly — no extra job
result = df.groupBy("customer_id") \
    .pivot("category", ["electronics", "clothing", "food"]) \
    .agg(F.sum("amount"))
```

**Memory trap:** pivot creates N new columns (one per distinct value).
If the pivot column has 10,000 distinct values, you get 10,000 new columns —
this can OOM the driver and makes the schema unmanageable.

**Rule:** only pivot when the column has a small, known set of values (< 50).

---

## Global Aggregations (No groupBy)

```python
# Aggregates over the entire DataFrame
df.agg(
    F.count("*").alias("total_rows"),
    F.sum("amount").alias("grand_total"),
    F.avg("amount").alias("global_avg")
).show()
```

---

## Filtering After Aggregation (HAVING equivalent)

```python
df.groupBy("region") \
    .agg(F.sum("amount").alias("total")) \
    .filter(F.col("total") > 10000)   # equivalent to HAVING total > 10000
```

---

## Common Aggregation Functions Reference

```python
F.count("*")                     # row count
F.count("col")                   # non-null count
F.countDistinct("col")           # exact distinct count
F.approx_count_distinct("col")   # approximate distinct count
F.sum("col")                     # sum
F.avg("col")                     # mean
F.mean("col")                    # alias for avg
F.min("col")                     # minimum
F.max("col")                     # maximum
F.stddev("col")                  # sample standard deviation
F.stddev_pop("col")              # population standard deviation
F.variance("col")                # sample variance
F.var_pop("col")                 # population variance
F.first("col")                   # first value (non-deterministic)
F.last("col")                    # last value (non-deterministic)
F.first("col", ignorenulls=True) # first non-null value
F.collect_list("col")            # array of all values
F.collect_set("col")             # array of distinct values
F.percentile_approx("col", 0.5)  # median (approximate)
F.percentile_approx("col", [0.25, 0.5, 0.75])  # quartiles
F.corr("col1", "col2")           # Pearson correlation
F.covar_samp("col1", "col2")     # sample covariance
```
