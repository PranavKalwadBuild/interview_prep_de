<!-- PySpark-patterns: Lazy Evaluation and DAG -->

# Lazy Evaluation and DAG

## How It Works

Spark uses lazy evaluation: transformations build a logical plan (DAG) but do not execute.
Execution only happens when an action is called.

### Transformations (lazy — build the DAG)

```python
df2 = df.filter(F.col("status") == "active")   # no execution
df3 = df2.select("id", "name")                  # no execution
df4 = df3.join(other_df, on="id")               # no execution
df5 = df4.groupBy("region").agg(F.sum("amount")) # no execution
```

Each call returns a new DataFrame with an updated logical plan. No data moves.

### Actions (trigger execution — run the DAG)

```python
df5.show()          # triggers full execution
df5.collect()       # triggers full execution, pulls to driver
df5.count()         # triggers full execution
df5.write.save()    # triggers full execution
df5.first()         # triggers partial execution (stops early)
df5.take(10)        # triggers partial execution
```

When an action is called, Spark:
1. Takes the logical plan
2. Optimizes it (Catalyst optimizer)
3. Generates a physical plan
4. Schedules jobs -> stages -> tasks
5. Executes across the cluster

---

## Why df.cache() Alone Does Nothing

```python
df = spark.read.parquet("/path/to/data")
df = df.filter(F.col("year") == 2024)
df.cache()           # marks df for caching — does NOT read data yet

df.show()            # FIRST action: reads data AND caches it
df.count()           # SECOND action: reads from cache (fast)
```

`cache()` is a transformation. The cache is populated on the first action that touches the DataFrame.

If you do:
```python
df.cache()
df2 = df.filter(...)  # creates new df, cache never materialized
```
The cache is never used.

---

## The .count() in a Loop Trap

Each `.count()` is a separate Spark job (a full DAG execution).

```python
# BAD: N separate jobs, each reading the full dataset
for date in date_list:
    subset = df.filter(F.col("date") == date)
    n = subset.count()   # triggers a job for EACH date
    print(f"{date}: {n}")
```

```python
# GOOD: one job, all counts at once
counts = df.groupBy("date").count().collect()
for row in counts:
    print(f"{row['date']}: {row['count']}")
```

The second pattern is one Spark job regardless of how many dates exist.

Another common trap:
```python
# BAD: two separate full scans
print(df.count())
print(df.filter(F.col("status") == "active").count())

# GOOD: one pass with conditional aggregation
from pyspark.sql import functions as F
result = df.agg(
    F.count("*").alias("total"),
    F.sum(F.when(F.col("status") == "active", 1).otherwise(0)).alias("active")
).collect()[0]
print(result["total"], result["active"])
```

---

## DAG Structure: Jobs, Stages, Tasks

```
Action (e.g., write)
  -> Job  (one per action)
      -> ShuffleMapStage 1 (narrow transforms: filter, select → pipelined)
          -> Task per partition  (one task = one input partition)
      -> Shuffle boundary (wide transform: groupBy, join → stage boundary)
      -> ResultStage / ShuffleMapStage 2 (post-shuffle)
          -> Task per shuffle partition  (count = spark.sql.shuffle.partitions)
```

**Narrow transformation** — each output partition depends on exactly ONE input partition. No shuffle needed; pipelined in one stage:
- `filter`, `select`, `withColumn`, `map`, `flatMap`, `union`, `mapPartitions`

**Wide transformation** — output partition depends on MULTIPLE input partitions. Triggers a shuffle — ends the current stage and starts a new one:
- `groupBy`, `join` (sort-merge), `repartition`, `distinct`, `orderBy`, `cogroup`

> For the full deep dive on Jobs, Stages, Tasks (lifecycle, ShuffleMapStage vs ResultStage, input partitions vs shuffle partitions, speculative execution, failure modes): see [27-jobs-stages-tasks.md](27-jobs-stages-tasks.md)

---

## How to Read the Spark UI DAG

1. Open Spark UI at `http://driver-host:4040`
2. **Jobs tab** → click a job → see stage dependency graph
3. **Stages tab** → click a stage → **Stage Detail** (the most important page for debugging)
4. **SQL tab** → interactive physical plan DAG with row counts on edges

Key things to look for:

| Element | What to Check |
|---------|---------------|
| Stage duration (Stages tab) | Is one stage taking 10x longer than others? That's the bottleneck. |
| Max vs Median task duration (Stage Detail) | Max >> Median = data skew |
| Spill (Memory / Disk) (Stage Detail) | Non-zero = task out of memory → increase shuffle.partitions or executor memory |
| GC Time (Stage Detail) | > 10% of Duration = memory pressure (row highlighted red) |
| Shuffle Read/Write (Stages tab) | Large shuffle = expensive; can this join be broadcast? |
| Fraction Cached (Storage tab) | < 100% = cache evicted due to memory pressure |
| Failed Tasks (Executors tab) | Climbing on one executor = node-level problem; check stderr logs |

> For the full deep dive on every Spark UI tab, all metrics, and diagnostic workflows (slow query, OOM, huge shuffle, many failed tasks): see [28-spark-ui-debugging.md](28-spark-ui-debugging.md)

---

## explain() — Reading the Physical Plan

```python
df.explain()                    # default: physical plan only
df.explain(mode="extended")     # parsed → analyzed → optimized → physical (all 4 stages)
df.explain(mode="formatted")    # physical plan + per-node detail blocks (best for debugging)
df.explain(mode="cost")         # optimized logical plan with CBO statistics
df.explain(mode="codegen")      # physical plan + generated Java code (WholeStageCodegen)
```

Key operators to recognize:

```
FileScan parquet           -- reading data; check PartitionFilters and PushedFilters
Filter above FileScan      -- predicate NOT pushed down (bad; full scan then filter)
Filter inside FileScan     -- predicate pushed to source (good; columnar batch filter)
BroadcastHashJoin          -- broadcast join; one Exchange total (fast)
SortMergeJoin              -- shuffle join; two Exchange nodes (expensive)
BroadcastNestedLoopJoin    -- range/non-equality join; O(N×M); dangerous on large tables
HashAggregate (×2)         -- two-phase agg: partial (map-side) + final (reduce-side)
Exchange hashpartitioning  -- shuffle stage boundary; every Exchange = a stage boundary
BroadcastExchange          -- small table collected and broadcast (not a disk shuffle)
AdaptiveSparkPlan          -- AQE wrapper; isFinalPlan=false before execution
CustomShuffleReader        -- AQE coalesced shuffle partitions post-execution
*(n) prefix                -- operator is in WholeStageCodegen stage n (fused into one Java loop)
```

> For the full deep dive on all 5 explain modes, every operator in detail, how to read AQE plans, codegen, CBO statistics, and common misreadings: see [26-explain-deep-dive.md](26-explain-deep-dive.md)

---

## Common Lazy Evaluation Bugs

### Bug: schema inference triggers an action

```python
df = spark.read.json("/path/to/data")
# Spark reads a sample of the data to infer the schema
# This is an implicit action — not free
```

Fix: provide an explicit schema.

### Bug: printing inside a transformation

```python
# This does NOT print during execution — it's a transformation
df2 = df.withColumn("debug", F.lit(print("hello")))
# print() runs at plan-build time, not at execution time
```

### Bug: assuming variable assignment = execution

```python
result = df.groupBy("region").agg(F.sum("revenue"))
# result is a DataFrame with a plan — nothing has run yet
# The groupBy+agg job runs when you call result.show(), .collect(), .write(), etc.
```
