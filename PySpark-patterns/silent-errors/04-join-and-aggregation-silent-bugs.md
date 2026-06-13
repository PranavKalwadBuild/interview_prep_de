<!-- Part of PySpark-patterns: Silent Errors — Join and Aggregation Silent Bugs -->

# Silent Errors — Join and Aggregation Silent Bugs

Joins and aggregations are the two most analytically significant operations in PySpark. They are
also the two most fertile ground for silent wrong results: fan-out row multiplication inflates
sums, cross joins from missing conditions explode cardinality, and approximate functions return
estimates presented as exact values — all without raising an exception.

---

### 1. Fan-Out Join Silently Multiplies Rows Before Aggregation

**What it looks like:**
```python
# orders has one row per order; order_items has multiple rows per order
orders = spark.read.parquet("s3://bucket/orders/")
items = spark.read.parquet("s3://bucket/order_items/")

result = orders.join(items, "order_id").groupBy("customer_id").agg(F.sum("order_total"))
```

**What actually happens:**
`orders.order_total` is repeated for every matching row in `order_items`. A 3-item order has
`order_total` repeated 3 times before the `groupBy`. The `SUM(order_total)` is 3× the true total
for that order. No error. The result looks plausible — just inflated by the average items-per-order.

**Why it's insidious:**
The join succeeds. The aggregation succeeds. The result is a credible-looking number — off by a
factor of 2-5× depending on average order size. This is one of the most common data errors in
production analytics pipelines, consistently reported as revenue overstatement in post-mortems.

**Minimal repro:**
```python
orders = spark.createDataFrame([(1, 100.0), (2, 200.0)], ["order_id", "total"])
items = spark.createDataFrame([(1, "A"), (1, "B"), (2, "C")], ["order_id", "item"])

# Wrong: inflated
wrong = orders.join(items, "order_id").agg(F.sum("total")).collect()[0][0]
print(f"Wrong total: {wrong}")   # 400.0 (100+100+200), not 300.0

# Correct: aggregate before join
correct = orders.agg(F.sum("total")).collect()[0][0]
print(f"Correct total: {correct}")   # 300.0
```

**How to catch it:**
```python
# Row count check before and after join
pre_join_count = orders.count()
post_join_count = orders.join(items, "order_id").count()
expansion_factor = post_join_count / pre_join_count
assert expansion_factor <= 1.0, f"Join expanded rows by {expansion_factor:.1f}x — fan-out detected"
```

**Real-world trigger:**
A revenue dashboard joins `transactions` to `transaction_events` (audit log). Revenue is summed
post-join. Events average 3 per transaction; revenue is overstated by 3×. The discrepancy
surfaces during a SOX audit, months after deployment.

---

### 2. Cross Join From Missing Join Condition When Already Enabled in Cluster Config

**What it looks like:**
```python
df1 = spark.read.parquet("s3://bucket/customers/")
df2 = spark.read.parquet("s3://bucket/campaigns/")
result = df1.join(df2)   # missing condition — Cartesian product
```

**What actually happens:**
Without a join condition, Spark produces a Cartesian product. If `spark.sql.crossJoin.enabled`
is `True` (often set globally in shared clusters for BI tools), Spark silently executes the
cross join. 1M customers × 50 campaigns = 50M rows. Downstream aggregations on `result` are
computed on a 50M-row DataFrame, not 1M.

**Why it's insidious:**
On small development data (1K rows each), the cross join produces 1M rows slowly but not
impossibly. Engineers tune Spark settings (`spark.sql.crossJoin.enabled = True`) to unblock
themselves in dev — it carries forward to production. The first production run on real data
generates 50M+ rows, produces wrong aggregates, and may OOM silently before any error is raised.

**How to catch it:**
```python
# Validate join condition is present before executing
def safe_join(df1, df2, condition, join_type="inner"):
    if condition is None:
        raise ValueError("Cross join attempted — pass an explicit condition")
    return df1.join(df2, condition, join_type)
```

**Real-world trigger:**
A personalization pipeline that joins user profiles to campaign targeting criteria. A developer
removes the condition during debugging and forgets to restore it. The cluster's crossJoin setting
is permissive; the pipeline produces a user×campaign explosion that runs out of disk on shuffle.

---

### 3. `distinct()` After `union()` Silently Drops Intentional Duplicates

**What it looks like:**
```python
# Two legitimate transactions for the same amount on the same day
tx1 = spark.createDataFrame([(1, "2024-01-01", 100.0)], ["user", "date", "amount"])
tx2 = spark.createDataFrame([(1, "2024-01-01", 100.0)], ["user", "date", "amount"])
combined = tx1.union(tx2).distinct()
```

**What actually happens:**
The two transactions are identical in all column values but are semantically distinct events
(different transaction IDs that weren't included in the union). `distinct()` merges them into
one row. The combined revenue understates by 100.0. No error.

**Why it's insidious:**
Using `.distinct()` after `.union()` is a common anti-pattern applied to "de-duplicate" the
union result. But if the two DataFrames represent different event streams that legitimately
produce identical rows, `distinct()` destroys real data.

**How to catch it:**
```python
# Check if distinct() reduces count meaningfully
pre_distinct = combined_before.count()
post_distinct = combined_before.distinct().count()
if post_distinct < pre_distinct:
    print(f"distinct() removed {pre_distinct - post_distinct} rows — verify these are true duplicates")
```

**Real-world trigger:**
An event pipeline that unions click and impression events. A user who clicks twice with the same
metadata within the same second has two identical rows. `distinct()` reduces them to one,
understating click counts and inflating CTR calculations.

---

### 4. `approx_count_distinct` With Default `rsd=0.05` Presents As Exact

**What it looks like:**
```python
df.agg(F.approx_count_distinct("user_id")).show()
# Output: 1000000
# Is this 1,000,000 exactly? No.
```

**What actually happens:**
`approx_count_distinct` uses HyperLogLog with a default relative standard deviation of 5%
(`rsd=0.05`). The returned value is an estimate with ±5% error. A true count of 1,000,000 can
be reported as anywhere from 950,000 to 1,050,000. The column alias (`approx_count_distinct(user_id)`)
contains "approx" — but in a SQL view or dashboard, this is truncated or renamed. The downstream
consumer sees "1000000" and treats it as exact.

**Why it's insidious:**
5% error on 1M distinct users = ±50,000 users. For DAU metrics, growth rates, or A/B test
sample size calculations, this is material. The function succeeds, the result looks like an
integer, and there is no flag in the output indicating it is approximate.

**How to catch it:**
```python
# Use exact countDistinct for SLO-grade metrics; document when approx is used
exact = df.agg(F.countDistinct("user_id").alias("exact_dau")).collect()[0][0]
approx = df.agg(F.approx_count_distinct("user_id", rsd=0.01).alias("approx_dau")).collect()[0][0]
print(f"Error: {abs(exact - approx) / exact:.2%}")
```

**Real-world trigger:**
An A/B test platform uses `approx_count_distinct` for experiment enrollment counts. The 5% error
creates false significance in small experiments. A 2% lift is reported as statistically
significant when the actual denominator is off by 5%.

---

### 5. `groupBy` Column Name Case Sensitivity Trap

**What it looks like:**
```python
# Schema has column named "UserID"
df = spark.createDataFrame([(1, 100), (1, 200), (2, 300)], ["UserID", "amount"])
result = df.groupBy("userid").agg(F.sum("amount"))
```

**What actually happens:**
Spark SQL column names are case-insensitive by default (`spark.sql.caseSensitive = False`).
`groupBy("userid")` resolves to `UserID` and works correctly. However, if `caseSensitive` is
enabled (common in certain Databricks configurations), `groupBy("userid")` raises an
`AnalysisException`. The insidious case is when two columns exist — `UserID` and `userid` —
because of a schema merge. `groupBy("userid")` ambiguously resolves to one of them without
clear documentation of which.

**Why it's insidious:**
Case-insensitive mode silently succeeds even when the column name in code doesn't exactly match
the schema. A column rename from `UserID` to `user_id` may be invisible in code reviews
because both names resolve to the same column in case-insensitive mode — until someone runs
in a case-sensitive environment.

**How to catch it:**
```python
# Check exact column name match
assert "user_id" in df.columns, f"Column 'user_id' not found; actual columns: {df.columns}"
```

**Real-world trigger:**
A pipeline developed on Databricks (case-insensitive) is migrated to a self-managed Spark cluster
with case-sensitivity enabled. Dozens of `groupBy("userid")` calls start failing because the
schema uses `UserID`. Some are silently wrong in mixed-schema DataFrames.

---

### 6. `agg({'col': 'sum'})` Dict Aggregation: Result Column Order Is Undefined

**What it looks like:**
```python
result = df.groupBy("category").agg({"revenue": "sum", "cost": "sum", "margin": "sum"})
total = result.rdd.map(lambda r: r[1] + r[2] + r[3]).collect()   # positional access
```

**What actually happens:**
When using a dictionary for `agg()`, Spark's internal dict ordering determines the column order
of the result. In Python 3.7+ dicts are insertion-ordered, but Spark may reorder them internally.
Positional column access (`r[1]`, `r[2]`, `r[3]`) silently reads wrong columns if the output
order differs from expectation.

**Why it's insidious:**
Works correctly in development on small data. The dict ordering may be preserved in one
execution context (local mode) but different in another (cluster mode). Positional access on
the result is always fragile.

**How to catch it:**
```python
# Always use named access, never positional
result = df.groupBy("category").agg(
    F.sum("revenue").alias("total_revenue"),
    F.sum("cost").alias("total_cost"),
)
total_revenue = result.select("total_revenue")   # named, not positional
```

**Real-world trigger:**
A Scala-to-PySpark migration. The original Scala code used positional tuple access. The migrated
Python code preserves positional indexing on dict-aggregation results. Revenue and cost columns
are transposed silently; the margin calculation is inverted.

---

### 7. NULL Keys in Joins: Matching Behavior

**What it looks like:**
```python
df1 = spark.createDataFrame([(None, "Alice"), (1, "Bob")], ["id", "name"])
df2 = spark.createDataFrame([(None, 100), (1, 200)], ["id", "value"])
df1.join(df2, "id", "inner").show()
```

**What actually happens:**
NULL does not equal NULL in SQL join semantics. `NULL = NULL` is `NULL` (not True). The inner
join on `id` excludes both rows where `id = NULL` — even though both DataFrames have a NULL
id. Only the row `id = 1` matches. The NULL rows are silently dropped from the inner join result.

**Why it's insidious:**
Engineers from a Python or R background expect `None == None` is `True`. In SQL semantics it
is not. Records with NULL keys are silently excluded from equi-joins, causing row count
discrepancies between the source and the join output.

**How to catch it:**
```python
# Detect NULL key rows before joining
null_keys_left = df1.filter(F.col("id").isNull()).count()
null_keys_right = df2.filter(F.col("id").isNull()).count()
if null_keys_left > 0 or null_keys_right > 0:
    print(f"WARNING: {null_keys_left} + {null_keys_right} NULL key rows will be excluded from inner join")
```

**Real-world trigger:**
A user attribution pipeline joins sessions to users on `user_id`. Anonymous sessions have
`user_id = NULL`. They are silently excluded from the inner join. Revenue attributed to anonymous
sessions is unaccounted for in the joined output.

---

### 8. `distinct()` vs `dropDuplicates()` Behavior With Subset

**What it looks like:**
```python
df.distinct()
# vs
df.dropDuplicates(["user_id", "event_date"])
```

**What actually happens:**
`distinct()` deduplicates on ALL columns. `dropDuplicates(subset)` deduplicates only on the
specified subset, keeping an arbitrary row (the first one encountered in the partition) for each
duplicate key. The "kept" row is non-deterministic — it depends on partition layout, which
changes with data size and shuffle configuration.

**Why it's insidious:**
After `dropDuplicates(["user_id", "event_date"])`, the columns NOT in the subset (e.g.,
`timestamp`, `revenue`) come from an arbitrary duplicate row. If one duplicate has revenue=100
and another has revenue=0, the result silently picks one — different on each run.

**How to catch it:**
```python
# Before dropDuplicates, verify the subset is truly a unique key
duplicate_count = (df
    .groupBy("user_id", "event_date")
    .count()
    .filter(F.col("count") > 1)
    .count()
)
if duplicate_count > 0:
    print(f"WARNING: {duplicate_count} duplicate keys — values in non-key columns will be arbitrary")
    # Use window function to pick the correct row instead
    w = Window.partitionBy("user_id", "event_date").orderBy(F.col("timestamp").desc())
    df_deduped = df.withColumn("rn", F.row_number().over(w)).filter(F.col("rn") == 1).drop("rn")
```

**Real-world trigger:**
A sessions table is deduplicated by `session_id` using `dropDuplicates`. Two rows for the same
session exist from a retry write. One has `duration = 0` (failed write), one has `duration = 120`.
`dropDuplicates` randomly picks one per run, causing session duration metrics to vary by ±15%
across daily runs.

---

### 9. Broadcast Join With Stale AQE Statistics Producing Wrong Join Type

**What it looks like:**
```python
# AQE dynamically upgrades to broadcast join
spark.conf.set("spark.sql.adaptive.enabled", "true")
large_df.join(small_df, "key")   # AQE decides join strategy at runtime
```

**What actually happens:**
AQE collects statistics after the shuffle to decide whether to convert a sort-merge join to a
broadcast join. If `small_df` is the result of a filter on a large table, AQE uses the
post-filter row count to decide on broadcasting. In some edge cases (stale cached statistics,
concurrent writes to the source), AQE may broadcast a table that has grown significantly since
statistics were collected. The broadcast table is the stale smaller version; the join silently
misses rows that were added to `small_df` after the statistics snapshot.

**Why it's insidious:**
The join succeeds. The plan shows a broadcast join (which looks like an optimization, not a
bug). The missing rows only surface in a row count reconciliation.

**How to catch it:**
```python
# Explicitly refresh table statistics before joins with AQE
spark.sql("ANALYZE TABLE small_table COMPUTE STATISTICS FOR ALL COLUMNS")
# Or disable AQE for joins where data freshness is critical
spark.conf.set("spark.sql.adaptive.enabled", "false")
```

**Real-world trigger:**
A real-time dashboard that joins a streaming events table to a dimension table. AQE broadcasts
the dimension table using statistics from the previous `ANALYZE TABLE` run (6 hours stale). New
dimension entries added in the last 6 hours are silently absent from the joined output.

---

### 10. `groupBy().pivot()` Silently Drops Rows for Unlisted Pivot Values

**What it looks like:**
```python
result = df.groupBy("user_id").pivot("event_type").agg(F.count("*"))
```

**What actually happens:**
Without an explicit list of pivot values, Spark runs a separate scan to collect all distinct
values of `event_type`, then pivots. If a new `event_type` value appears between the collection
scan and the aggregation scan (concurrent write), that value is silently absent from the pivot
output. Rows with the new event type are dropped, not counted under "unknown".

**Why it's insidious:**
The pivot output has the correct number of columns (for known event types). The new event type
simply doesn't appear. Any count based on the pivot output is an undercount.

**How to catch it:**
```python
# Explicitly specify pivot values to avoid the two-scan problem
known_event_types = ["click", "view", "purchase"]
result = df.groupBy("user_id").pivot("event_type", known_event_types).agg(F.count("*"))
# Then check for unclassified events separately
df.filter(~F.col("event_type").isin(known_event_types)).count()
```

**Real-world trigger:**
A funnel analysis pivot that tracks user progression through event types. A new event type
("add_to_wishlist") is added to the product during the quarter. The pivot silently excludes it;
funnel drop-off at the wishlist step is invisible in the report for weeks.
