<!-- PySpark-patterns: AQE and Performance -->

# AQE and Performance

## What is AQE?

Adaptive Query Execution (AQE) re-optimizes the query plan at runtime using actual
shuffle statistics (row counts, data sizes) instead of compile-time estimates.

Enabled by default since Spark 3.2.

```python
spark.conf.get("spark.sql.adaptive.enabled")  # "true" by default in Spark 3.2+

# Enable explicitly (pre-Spark 3.2 or if someone disabled it)
spark.conf.set("spark.sql.adaptive.enabled", "true")
```

---

## AQE Feature 1 — Post-Shuffle Partition Coalescing

After a shuffle, AQE automatically merges small partitions into larger ones.

**Without AQE:**
- You set `shuffle.partitions=200`, run a groupBy on 100 MB of data
- Result: 200 partitions averaging 0.5 MB each
- 200 tasks for tiny work — scheduling overhead dominates

**With AQE:**
- Spark runs the shuffle with 200 partitions
- AQE sees the actual sizes: most are < 1 MB
- AQE merges adjacent small partitions until they reach `advisoryPartitionSizeInBytes`
- Result might be 5 meaningful partitions instead of 200 tiny ones

```python
# Target size for coalesced partitions
spark.conf.set("spark.sql.adaptive.advisoryPartitionSizeInBytes", "128m")  # default

# Minimum partition size (below this, AQE will merge)
spark.conf.set("spark.sql.adaptive.coalescePartitions.minPartitionSize", "1m")  # default

# Disable partition coalescing (keep all shuffle partitions as-is)
spark.conf.set("spark.sql.adaptive.coalescePartitions.enabled", "false")
```

**Practical implication:** with AQE, you can set `shuffle.partitions` higher (e.g., 1000)
without worrying about creating too many tiny partitions for small data.
AQE coalesces them. Set it high enough for your largest datasets.

---

## AQE Feature 2 — Dynamic Join Strategy Switching

At compile time, Spark estimates table sizes to decide join type (SortMergeJoin vs BroadcastHashJoin).
Estimates can be wrong (stale statistics, computed from complex aggregations).

**With AQE:** after a shuffle, Spark knows the actual size.
If a table turned out to be smaller than `autoBroadcastJoinThreshold`, AQE converts
the SortMergeJoin to a BroadcastHashJoin mid-query.

```python
# Threshold for AQE to convert SMJ -> BHJ (same as auto-broadcast threshold)
spark.conf.get("spark.sql.autoBroadcastJoinThreshold")  # default 10MB

# AQE non-empty partition threshold (don't broadcast nearly-empty tables as SMJ)
spark.conf.set("spark.sql.adaptive.nonEmptyPartitionRatioForBroadcastJoin", "0.2")
```

This is especially useful after a `filter` reduces a large table to a small one
before a join — compile-time stats don't know how many rows the filter will remove.

---

## AQE Feature 3 — Skew Join Optimization

AQE auto-detects skewed partitions in a join and splits them.

```python
spark.conf.set("spark.sql.adaptive.skewJoin.enabled", "true")  # default true
spark.conf.set("spark.sql.adaptive.skewJoin.skewedPartitionFactor", "5")       # default
spark.conf.set("spark.sql.adaptive.skewJoin.skewedPartitionThresholdInBytes", "256m")  # default
```

A partition is "skewed" if it is:
- More than `skewedPartitionFactor` (5x) times the median partition size, AND
- Larger than `skewedPartitionThresholdInBytes` (256 MB)

AQE splits the skewed partition into multiple smaller ones and replicates the
corresponding partition from the other table to match.

**Limitation:** only works for SortMergeJoin (not BroadcastHashJoin).

---

## Verifying AQE Is Working

In **Spark UI -> SQL tab**:
- Click a query
- Look for node labels containing "AQE" in the plan visualization
- Look for `AdaptiveSparkPlan` node wrapping the plan
- After execution, the plan shows actual stats

```python
# Check if a specific query used AQE
df.explain(mode="formatted")
# Look for "AdaptiveSparkPlan" in the output
```

---

## When AQE Does NOT Help

1. **First shuffle in the query:** AQE needs shuffle statistics to act.
   The very first shuffle has no runtime stats yet — it uses compile-time estimates.

2. **Data source statistics not available:** AQE relies on statistics for pre-shuffle
   optimizations. If the source has no stats (uncataloged files, no ANALYZE), AQE
   can't help for the initial plan.

3. **Broadcast join decisions:** AQE can convert SMJ -> BHJ, but cannot convert
   BHJ -> SMJ (it can't un-broadcast).

4. **Streaming queries:** AQE is not applied to Structured Streaming.

5. **Python UDFs:** UDFs break column statistics propagation.

---

## Manual Tuning When AQE Is Insufficient

```python
# Explicit repartition before skewed groupBy
df.repartition(200, F.col("customer_id")) \
  .groupBy("customer_id") \
  .agg(F.sum("amount"))

# Explicit broadcast hint when auto-broadcast misses
result = large_df.join(F.broadcast(medium_df), on="id")

# Increase shuffle.partitions for very large joins
spark.conf.set("spark.sql.shuffle.partitions", "2000")
# AQE will coalesce down if many are small

# Salting for extreme skew — see 15-broadcast-and-skew-joins.md
```

---

## AQE Config Quick Reference

```python
# Core switch
spark.conf.set("spark.sql.adaptive.enabled", "true")

# Partition coalescing
spark.conf.set("spark.sql.adaptive.coalescePartitions.enabled", "true")
spark.conf.set("spark.sql.adaptive.advisoryPartitionSizeInBytes", "128m")

# Skew join
spark.conf.set("spark.sql.adaptive.skewJoin.enabled", "true")
spark.conf.set("spark.sql.adaptive.skewJoin.skewedPartitionFactor", "5")
spark.conf.set("spark.sql.adaptive.skewJoin.skewedPartitionThresholdInBytes", "256m")

# Dynamic broadcast conversion
spark.conf.set("spark.sql.autoBroadcastJoinThreshold", str(10 * 1024 * 1024))  # 10MB

# Local shuffle reader (avoid re-shuffle when possible)
spark.conf.set("spark.sql.adaptive.localShuffleReader.enabled", "true")
```
