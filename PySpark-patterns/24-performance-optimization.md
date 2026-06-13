<!-- PySpark-patterns: Performance Optimization -->

# Performance Optimization

## The Performance Checklist (In Order of Impact)

### 1. Push Filters Early (Before Joins and Aggregations)

```python
# BAD: join all data, then filter
df1.join(df2, "id").filter(F.col("year") == 2024)

# GOOD: filter before join — fewer rows to shuffle
df1.filter(F.col("year") == 2024).join(df2.filter(F.col("year") == 2024), "id")
```

For Parquet/Delta: filters on partition columns applied before read → partition pruning.
For Delta with Z-order: filters on Z-ordered columns skip row groups.

### 2. Select Only Needed Columns (Projection Pruning)

```python
# BAD: carry all 200 columns through the pipeline
df.join(other, "id").groupBy("region").agg(F.sum("amount"))

# GOOD: select needed columns early
df.select("id", "region", "amount") \
  .join(other.select("id", "category"), "id") \
  .groupBy("region") \
  .agg(F.sum("amount"))
```

### 3. Use Broadcast Joins for Small Tables

```python
result = large_df.join(F.broadcast(dim_df), "id")
```

Eliminates the shuffle of `large_df`. See `15-broadcast-and-skew-joins.md`.

### 4. Avoid Python UDFs — Use Built-in Functions

```python
# BAD: Python UDF with serialization overhead
@F.udf("string")
def normalize(x):
    return x.strip().lower() if x else None

# GOOD: built-in functions stay in JVM
F.lower(F.trim(F.col("x")))
```

### 5. Use .select() Not Chained .withColumn()

```python
# BAD: 50 projection nodes in the plan
df = df.withColumn("a", ...).withColumn("b", ...) # ... 48 more

# GOOD: one projection
df = df.select(expr_a, expr_b, ...)
```

### 6. Tune shuffle.partitions (Or Rely on AQE)

```python
# With AQE (default Spark 3.2+): set high, AQE coalesces down
spark.conf.set("spark.sql.shuffle.partitions", "1000")

# Without AQE: size to ~128MB per partition
# e.g., 500GB / 128MB = ~4000 partitions
spark.conf.set("spark.sql.shuffle.partitions", "4000")
```

### 7. Cache DataFrames Used Multiple Times

```python
base = expensive_df.cache()
base.count()  # materialize

agg1 = base.groupBy("region").agg(F.sum("revenue"))
agg2 = base.groupBy("product").agg(F.avg("margin"))
```

### 8. Use Delta with Z-ordering for Skewed Access Patterns

```python
spark.sql("OPTIMIZE dim_customer ZORDER BY (customer_id, region)")
# Queries filtering on customer_id or region read fewer row groups
```

---

## explain() — Reading the Physical Plan

```python
df.explain()                    # physical plan only (quick sanity check)
df.explain(mode="extended")     # all 4 plan stages: parsed → analyzed → optimized → physical
df.explain(mode="formatted")    # physical plan + per-node detail blocks — BEST for debugging
df.explain(mode="cost")         # optimized logical plan with CBO statistics (diagnose wrong join choice)
df.explain(mode="codegen")      # physical plan + generated Java code (verify WholeStageCodegen)
```

### Key Operators to Spot

| Operator | Meaning | Signal |
|----------|---------|--------|
| `FileScan` with non-empty `PartitionFilters` | Partition pruning active | Good |
| `FileScan` with non-empty `PushedFilters` | Filter pushed inside Parquet reader | Good |
| `Filter` ABOVE `FileScan` (standalone node) | Predicate NOT pushed down — full scan then filter | Bad — fix the predicate |
| `FileScan` `ReadSchema` narrow | Column pruning worked | Good |
| `BroadcastHashJoin BuildRight/BuildLeft` | Small table broadcast; one `Exchange` total | Good |
| `SortMergeJoin` | Two `Exchange` nodes; both sides shuffled | Expensive; check if one side can be broadcast |
| `BroadcastNestedLoopJoin` | No equality condition; O(N×M) | Critical on large data — rewrite to BHJ |
| `Exchange hashpartitioning(key, N)` | Shuffle = stage boundary; N = shuffle partitions | Count these; each = a shuffle |
| `HashAggregate` (pair around Exchange) | Two-phase agg: partial + final | Normal; check for `Batches > 1` = spill |
| `AdaptiveSparkPlan isFinalPlan=false` | AQE initial plan (before execution) | Don't trust before running |
| `AdaptiveSparkPlan isFinalPlan=true` | AQE final plan (after execution) | Shows actual optimization decisions |
| `*(n)` prefix | Operator in WholeStageCodegen stage n (fused Java loop) | Good; operators without = codegen break |

> For the full deep dive on all 5 modes, every operator, AQE in explain, codegen, CBO, and common misreadings: **[26-explain-deep-dive.md](26-explain-deep-dive.md)**

---

## Spark UI Metrics

Access at `http://driver:4040` (or Databricks cluster UI).

### Jobs Tab
- Each action = one job. Many jobs with identical descriptions + same line number = `count()` in a loop.
- Event Timeline at top = Gantt chart showing gaps between jobs (driver-side Python overhead).

### Stages Tab — Find the Bottleneck
- Sort by Duration descending. Top row = bottleneck stage.
- High Shuffle Read with low Input → can this join be broadcast?
- Shuffle Write >> expected → look for missing join condition (Cartesian product)

### Stage Detail — The Most Important Page
Click a stage description to open Stage Detail. This has the Summary Metrics table showing each metric at Min / 25th / Median / 75th / Max across all tasks:

| Metric | Red Flag | Fix |
|--------|---------|-----|
| **Duration: Max >> 75th** | Data skew | Broadcast, salt, AQE skew join |
| **GC Time > 10% Duration** | Memory pressure (row highlighted red) | Increase executor memory |
| **Spill (Memory) or Spill (Disk) > 0** | Task OOM'd into disk | More shuffle partitions or more memory |
| **Shuffle Read Blocked Time > seconds** | Network congestion or slow executor | Check Executors tab for dead node |
| **Task Deserialization Time > seconds** | Closure too large | Avoid capturing large objects in lambdas |

Event Timeline in Stage Detail: one long bar at the end = visual confirmation of skew.

### Storage Tab
- Fraction Cached < 100% = partitions evicted (memory pressure). Call `.count()` after `.cache()` to materialize.
- Size on Disk > 0 with `MEMORY_AND_DISK` = partitions spilled to executor local disk (slower).

### SQL Tab
- Interactive physical plan DAG with row counts and bytes on edges.
- `AQEShuffleRead` nodes = AQE coalesced shuffle partitions.
- `WholeStageCodegen (N)` dashed boxes = codegen fused operators (good).
- "Details" at bottom = text plans (initial vs final) showing AQE changes.

### Executors Tab
- GC Time > 10% of Task Time → red row → memory pressure on that executor.
- Climbing Failed Tasks on one executor while others are zero → unhealthy node → check `stderr` logs.
- Thread Dump button → live JVM thread dump → diagnose hanging tasks.

> For the full deep dive on every tab, all metrics, and step-by-step workflows (slow query, OOM, huge shuffle, many failed tasks, Databricks Photon): **[28-spark-ui-debugging.md](28-spark-ui-debugging.md)**

---

## Common Anti-Patterns

### .toPandas() on Large Data

```python
# BAD: pulls entire DataFrame to driver — OOM for large data
df.toPandas()

# GOOD: aggregate first, then collect the small result
df.groupBy("region").agg(F.sum("revenue")).toPandas()
```

### .collect() Without Size Check

```python
# DANGEROUS for large DataFrames
rows = df.collect()   # if df has 100M rows, driver OOM

# SAFER: limit first
rows = df.limit(1000).collect()
```

### Python Loops Over Rows

```python
# BAD: 1M iterations in Python driver
for row in df.collect():
    process(row)

# GOOD: process in Spark using UDF, map, or built-in functions
df.withColumn("result", F.udf(process)("col"))
```

### Re-reading the Same Data Multiple Times

```python
# BAD: reads the file 3 times
a1 = df.filter(F.col("year") == 2022).count()
a2 = df.filter(F.col("year") == 2023).count()
a3 = df.filter(F.col("year") == 2024).count()

# GOOD: one pass
df.groupBy("year").count().show()
```

### Not Unpersisting Cached Data

```python
# BAD: fills memory with stale cached data across many steps
for i in range(100):
    df_step = compute_step(df_prev).cache()
    df_step.count()

# GOOD: unpersist previous step's cache before moving on
for i in range(100):
    df_step = compute_step(df_prev).cache()
    df_step.count()
    df_prev.unpersist()
    df_prev = df_step
```

### Shuffling Before Filtering

```python
# BAD: groupBy shuffles ALL data, then filter discards most
df.groupBy("region").agg(F.count("*").alias("cnt")) \
  .filter(F.col("region") == "US")

# GOOD: filter before groupBy — shuffle less data
df.filter(F.col("region") == "US") \
  .groupBy("region").agg(F.count("*").alias("cnt"))
```
