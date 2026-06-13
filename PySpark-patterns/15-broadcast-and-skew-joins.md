<!-- PySpark-patterns: Broadcast and Skew Joins -->

# Broadcast and Skew Joins

## Broadcast Join Mechanics

In a broadcast join:
1. The small table is fully collected by the driver
2. The driver broadcasts (sends) a copy to every executor
3. Each executor builds a hash map from the small table in memory
4. The large table is scanned partition by partition — each partition looks up matches in the local hash map
5. No shuffle of the large table

**Result:** one broadcast network transfer instead of two full shuffles.

```
Driver
  |
  +-- collect small_df -- broadcast to all executors
                              |
                        Executor 1: hash map of small_df + scan large_df[partition 1]
                        Executor 2: hash map of small_df + scan large_df[partition 2]
                        ...
```

---

## Explicit Broadcast Hint

```python
from pyspark.sql import functions as F

# Explicitly tell Spark to broadcast the smaller table
result = large_df.join(F.broadcast(small_df), on="id", how="left")

# SQL hint equivalent
spark.sql("SELECT /*+ BROADCAST(d) */ * FROM facts f JOIN dim d ON f.id = d.id")
```

Put the broadcast hint on the SMALLER table (the one you want broadcast).
The larger table stays as-is and is scanned partition by partition.

---

## Auto-Broadcast Threshold

Spark automatically broadcasts a table if its estimated size is below the threshold:

```python
# Default: 10MB
spark.conf.get("spark.sql.autoBroadcastJoinThreshold")  # "10485760" (10MB in bytes)

# Increase threshold (careful — broadcasts land in executor memory)
spark.conf.set("spark.sql.autoBroadcastJoinThreshold", str(50 * 1024 * 1024))  # 50MB

# Disable auto-broadcast entirely
spark.conf.set("spark.sql.autoBroadcastJoinThreshold", "-1")
```

Size estimate comes from table statistics. If statistics are stale or unavailable,
auto-broadcast may not trigger even for small tables — use explicit `F.broadcast()`.

---

## When Broadcast Fails

```python
# SparkException: Cannot broadcast large object
# The small table exceeded driver/executor memory for broadcast

# Fix 1: disable broadcast for this join
spark.conf.set("spark.sql.autoBroadcastJoinThreshold", "-1")
result = large_df.join(small_df, on="id", how="left")  # falls back to SortMergeJoin

# Fix 2: reduce the broadcast table first
small_df_filtered = small_df.filter(F.col("active") == True).select("id", "name")
result = large_df.join(F.broadcast(small_df_filtered), on="id", how="left")
```

---

## Diagnosing Skew

A skewed join means one key value has far more rows than others.

**In Spark UI:**
- Go to the join Stage
- Click "Tasks" — sort by Duration descending
- If the top task is 10x+ longer than the median, you have skew

**In code:**
```python
# Find skewed keys
df.groupBy("join_key") \
  .count() \
  .orderBy(F.col("count").desc()) \
  .show(20)
```

---

## AQE Skew Join Fix (Spark 3.0+)

```python
spark.conf.set("spark.sql.adaptive.skewJoin.enabled", "true")   # default true with AQE
spark.conf.set("spark.sql.adaptive.skewJoin.skewedPartitionFactor", "5")    # default
spark.conf.set("spark.sql.adaptive.skewJoin.skewedPartitionThresholdInBytes", "256m")  # default
```

AQE detects skewed partitions after the shuffle and automatically splits them
into multiple smaller partitions that run in parallel.

**Limitation:** AQE skew detection only works for SortMergeJoin.
It does not help with broadcast join issues.

---

## Manual Salting Pattern (Works Pre-Spark 3.0 or for Extreme Skew)

The idea: dilute the skewed key by adding a random salt (0 to N-1) as a suffix.
Split the large table across N reducers. Replicate the small table N times to match.

```python
SALT_BUCKETS = 10

# Step 1: Add a random salt to the large (skewed) table
large_df = large_df.withColumn(
    "salt",
    (F.rand() * SALT_BUCKETS).cast("int")
).withColumn(
    "salted_key",
    F.concat_ws("_", F.col("join_key").cast("string"), F.col("salt").cast("string"))
)

# Step 2: Replicate the small table for each salt value
salt_df = spark.range(SALT_BUCKETS).withColumnRenamed("id", "salt")

small_df_replicated = small_df.crossJoin(salt_df).withColumn(
    "salted_key",
    F.concat_ws("_", F.col("join_key").cast("string"), F.col("salt").cast("string"))
)

# Step 3: Join on the salted key
result = large_df.join(
    small_df_replicated,
    on="salted_key",
    how="left"
).drop("salt", "salted_key")
```

**Trade-off:** the small table grows N times in memory (N=10 means 10x size).
Only use when AQE doesn't solve the skew.

---

## Choosing SALT_BUCKETS

```python
# Estimate: how many times does the skewed key appear?
max_count = df.groupBy("join_key").count().agg(F.max("count")).collect()[0][0]

# Target: each bucket should have roughly the same rows as a non-skewed key
avg_count = df.groupBy("join_key").count().agg(F.avg("count")).collect()[0][0]

SALT_BUCKETS = max(int(max_count / avg_count), 2)
SALT_BUCKETS = min(SALT_BUCKETS, 50)   # cap to avoid replication explosion
print(f"Using {SALT_BUCKETS} salt buckets")
```

---

## Partial Salting (Only Salt the Skewed Key)

When only ONE key value is skewed (e.g., "UNKNOWN" or a single customer ID),
salt only that key:

```python
# Only salt the known skewed value
SKEWED_KEY = "UNKNOWN"

large_df = large_df.withColumn(
    "salted_key",
    F.when(
        F.col("join_key") == SKEWED_KEY,
        F.concat_ws("_", F.col("join_key"), (F.rand() * SALT_BUCKETS).cast("int").cast("string"))
    ).otherwise(F.col("join_key"))
)

# Replicate only the skewed key row in the small table
normal_rows = small_df.filter(F.col("join_key") != SKEWED_KEY)
skewed_row = small_df.filter(F.col("join_key") == SKEWED_KEY)
salt_df = spark.range(SALT_BUCKETS).withColumnRenamed("id", "salt")

skewed_replicated = skewed_row.crossJoin(salt_df).withColumn(
    "salted_key",
    F.concat_ws("_", F.col("join_key"), F.col("salt").cast("string"))
).drop("salt")

normal_rows = normal_rows.withColumn("salted_key", F.col("join_key"))

small_df_final = normal_rows.union(skewed_replicated)

result = large_df.join(small_df_final, on="salted_key", how="left").drop("salted_key")
```
