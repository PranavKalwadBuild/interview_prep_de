# Scenario 02 — Partitioned Data with Skew

## The Problem Statement
> Same 10 TB, but data is partitioned by `country` in S3. 60% of records are from the US. One Spark task processes the entire US partition → takes 10× longer than all others → entire job waits.

---

## Why Skew Kills SLAs

```
Scenario: 40,000 partitions, 1 skewed task = 200 GB
Normal task time   = 5 sec (256 MB)
Skewed task time   = 200 GB / 256 MB × 5 sec = ~3,900 sec = 65 minutes

Even with 1,200 executors, the job cannot finish until that one task completes.
SLA breach: guaranteed.
```

---

## Clarifying Questions

| Question | Why It Matters |
|----------|---------------|
| Which columns cause skew? (date? country? user_id?) | Determines salting key |
| Is skew predictable or dynamic? | Static: hard-code salt. Dynamic: AQE handles |
| What's the skew ratio? (2:1 or 1000:1?) | Severity changes the fix |
| Are joins involved or just aggregations? | Joins need different fix than groupBy |
| Spark version? | AQE only available 3.0+; skew join fix 3.0+ |

---

## Detection: How to Spot Skew

```python
# In Spark UI: look for "Tasks" tab → sort by Duration descending
# One task 10x–1000x longer than median = skew

# In code: check partition size distribution
df.groupBy(spark_partition_id()).count().orderBy(col("count").desc()).show(20)

# Or check source column distribution
df.groupBy("country").count().orderBy(col("count").desc()).show(20)
```

---

## Fix 1 — AQE Skew Join (Spark 3.0+, Zero Code Change)

```python
spark.conf.set("spark.sql.adaptive.enabled", "true")
spark.conf.set("spark.sql.adaptive.skewJoin.enabled", "true")

# AQE detects skewed partitions at runtime and splits them automatically
# Skew threshold: partition > skewedPartitionFactor × median AND > threshold
spark.conf.set("spark.sql.adaptive.skewJoin.skewedPartitionFactor", "5")
spark.conf.set("spark.sql.adaptive.skewJoin.skewedPartitionThresholdInBytes", "256m")

# Works for: sort-merge joins, groupBy + aggregate
# Does NOT help: non-equi joins, cross joins, custom partitioners
```

**When AQE is enough:** skew ratio < 10:1, data changes day to day, don't know skew key upfront.

---

## Fix 2 — Salting (Manual, More Control)

Salting = add a random suffix to the skewed key to spread one "big" partition across N smaller ones.

```python
import math
from pyspark.sql import functions as F

SALT_FACTOR = 10  # spread skewed key into 10 sub-partitions

# Step 1: Add salt column to main (large) DataFrame
df_salted = df.withColumn(
    "salt",
    F.when(
        F.col("country") == "US",
        (F.rand() * SALT_FACTOR).cast("int")   # random 0–9
    ).otherwise(F.lit(0))                        # non-skewed keys: salt=0
).withColumn(
    "salted_key",
    F.concat(F.col("country"), F.lit("_"), F.col("salt").cast("string"))
)

# Step 2: Explode the lookup/dimension DataFrame by same salt factor
# (only needed for joins — for groupBy skip this step)
df_lookup_exploded = df_lookup.withColumn(
    "salt",
    F.explode(F.array([F.lit(i) for i in range(SALT_FACTOR)]))
).withColumn(
    "salted_key",
    F.concat(F.col("country"), F.lit("_"), F.col("salt").cast("string"))
)

# Step 3: Join on salted key
df_result = df_salted.join(df_lookup_exploded, on="salted_key", how="left")

# Step 4: Drop salt columns
df_result = df_result.drop("salt", "salted_key")
```

**Rule for SALT_FACTOR:**
```
salt_factor = ceil(skewed_partition_size / target_partition_size)
            = ceil(200 GB / 256 MB) = 800  ← extreme case, use AQE instead
            
Practical: use 8–32 for moderate skew. Above 50 → AQE is better.
```

---

## Fix 3 — Two-Phase Aggregation (groupBy skew without joins)

```python
# Problem: df.groupBy("country").agg(sum("amount")) → US bucket = 6 TB
# Fix: pre-aggregate with salt, then final aggregate

SALT_FACTOR = 20

# Phase 1: partial aggregate on salted key
df_partial = df \
    .withColumn("salt", (F.rand() * SALT_FACTOR).cast("int")) \
    .withColumn("salted_country", F.concat(F.col("country"), F.lit("_"), F.col("salt"))) \
    .groupBy("salted_country", "country") \
    .agg(F.sum("amount").alias("partial_sum"), F.count("*").alias("partial_count"))

# Phase 2: final aggregate on real key (now balanced)
df_final = df_partial \
    .groupBy("country") \
    .agg(
        F.sum("partial_sum").alias("total_amount"),
        F.sum("partial_count").alias("total_count")
    )
```

---

## Fix 4 — Broadcast Join (Eliminate Shuffle Entirely)

If the dimension/lookup table fits in memory, broadcast it. No shuffle = no skew possible.

```python
from pyspark.sql.functions import broadcast

# Rule: broadcast if table < spark.sql.autoBroadcastJoinThreshold
# Default threshold = 10 MB. Increase carefully.
spark.conf.set("spark.sql.autoBroadcastJoinThreshold", "512m")  # max ~1 GB safe

df_result = df_large.join(
    broadcast(df_small),   # forces broadcast regardless of threshold
    on="country",
    how="left"
)

# When to use: dimension tables, lookup tables, static reference data
# When NOT to use: both tables are large (OOM on driver/executor)
```

---

## Fix 5 — Repartition by Skewed Column Before Write

```python
# If skew is at write time (output partitions uneven):
df.repartition(4000, "country", "date") \
  .write \
  .partitionBy("date", "country") \
  .parquet(OUTPUT_PATH)

# AQE + coalesce will merge small partitions automatically if enabled
```

---

## Configs Summary

```python
# AQE (always on for Spark 3+)
"spark.sql.adaptive.enabled"                              → "true"
"spark.sql.adaptive.skewJoin.enabled"                     → "true"
"spark.sql.adaptive.skewJoin.skewedPartitionFactor"       → "5"
"spark.sql.adaptive.skewJoin.skewedPartitionThresholdInBytes" → "256m"
"spark.sql.adaptive.coalescePartitions.enabled"           → "true"

# Broadcast threshold
"spark.sql.autoBroadcastJoinThreshold"                    → "10m"  (raise to 256m if needed)
```

---

## Decision Tree

```
Is the skewed column a join key?
├── YES → Can the other side be broadcast?
│         ├── YES (< 1 GB) → Use broadcast join
│         └── NO (large)   → Use salting OR AQE skew join
└── NO (pure aggregation skew)
          └── Use two-phase aggregation with salting

Is Spark version >= 3.0?
├── YES → Enable AQE first; if still slow → add salting
└── NO  → Must use salting manually
```

---

## Follow-up Questions Interviewers Ask

**Q: AQE already handles skew — why know salting?**
A: AQE works only for sort-merge joins and aggregations. Non-equi joins, Python UDFs, custom partitioners, Spark < 3.0 — all need manual salting.

**Q: What's the downside of high SALT_FACTOR?**
A: Exploding the dimension table by SALT_FACTOR multiplies its size. SALT_FACTOR=100 on a 1 GB lookup = 100 GB shuffle of the lookup side. Can cause OOM. Sweet spot: 8–32.

**Q: How do you detect skew before the job fails?**
A: Profile with `df.groupBy(column).count().orderBy(desc)` on a sample first. If max/median ratio > 5x, expect skew problems at full scale.

**Q: Skew vs spill — what's the difference?**
A: Skew = uneven data distribution across tasks. Spill = single task exceeds executor memory and writes intermediate data to disk. Skew causes spill, but spill can also happen from large shuffles even without skew.
