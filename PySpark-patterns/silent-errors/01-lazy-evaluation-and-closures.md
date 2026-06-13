<!-- Part of PySpark-patterns: Silent Errors — Lazy Evaluation and Closures -->

# Silent Errors — Lazy Evaluation and Closures

Lazy evaluation is Spark's defining feature and its most dangerous footgun. Transformations build
a DAG; actions execute it. The gap between definition and execution is where closure bugs, mutable
state, and accumulator traps live — none raise exceptions.

---

### 1. Mutable Python Variable Captured by Reference in Closure

**What it looks like:**
```python
multiplier = 1.0
df_result = df.withColumn("adjusted", F.col("value") * multiplier)
multiplier = 2.0           # mutated AFTER the transformation is defined
df_result.show()           # executes here — but which multiplier?
```

**What actually happens:**
Python closures capture variables by reference, not by value. When Spark serializes the UDF or
expression at action time, it sees `multiplier = 2.0`. Every row is multiplied by 2.0, not 1.0.
No warning is raised.

**Why it's insidious:**
The code reads as if 1.0 is the intended multiplier. The mutation is often several lines away —
or in a loop body. The DAG is evaluated at `.show()`, not at `.withColumn()`, so the variable's
value at definition time is irrelevant.

**Minimal repro:**
```python
multiplier = 10
transform = lambda x: x * multiplier
rdd = sc.parallelize([1, 2, 3])
mapped = rdd.map(transform)
multiplier = 999          # mutate after map() is defined
print(mapped.collect())   # [999, 1998, 2997] — NOT [10, 20, 30]
```

**How to catch it:**
Capture the value at definition time with a default argument:
`lambda x, m=multiplier: x * m`
Or freeze with `multiplier = float(multiplier)` before the transformation.
In code review, flag any variable mutation between transformation definition and action.

**Real-world trigger:**
A loop that builds a different DataFrame per market segment, reusing a `filter_val` variable.
All DataFrames silently use the last iteration's filter value.

---

### 2. `foreach` / `foreachPartition` Side Effects with Task Retries

**What it looks like:**
```python
def write_to_api(partition):
    for row in partition:
        requests.post("https://api.example.com/ingest", json=row.asDict())

df.foreachPartition(write_to_api)
```

**What actually happens:**
Spark retries failed tasks up to `spark.task.maxFailures` times (default 4). If a partition task
fails mid-way through (network blip, executor OOM eviction) and retries, the API call for already-
processed rows fires again. The API receives duplicate events with no deduplication guarantee.
Spark reports the job as succeeded.

**Why it's insidious:**
The job succeeds. The Spark UI shows no failures (the retry succeeded). The API has no way to
distinguish a retry from a new event unless the caller implements idempotency keys. The downstream
table has doubled rows weeks later when an analyst reconciles.

**Minimal repro:**
```python
# Simulate with a counter in an external store
import redis
r = redis.Redis()

def increment_counter(partition):
    for row in partition:
        r.incr(f"count:{row['id']}")  # increments on retry too

df.foreachPartition(increment_counter)
# Counter shows 2x the actual row count if any task retried
```

**How to catch it:**
Use idempotency keys: `requests.post(..., headers={"Idempotency-Key": str(row["event_id"])})`.
For DB writes, use MERGE/upsert rather than INSERT.
For Delta Lake sinks, use `txnVersion` + `txnAppId` options.

**Real-world trigger:**
A CDC pipeline that calls a REST API to invalidate a cache entry. On retry, the same cache key
is invalidated twice, briefly serving stale data to downstream consumers.

---

### 3. Accumulator Read Before Action Gives Zero

**What it looks like:**
```python
error_count = sc.accumulator(0)

def validate(row):
    if row["amount"] < 0:
        error_count.add(1)
    return row

df.rdd.map(validate)           # transformation, not an action
print(f"Errors: {error_count.value}")  # prints 0 — always
```

**What actually happens:**
The `map()` is a transformation — it builds a DAG node but executes nothing. The accumulator
is never incremented. Reading it before triggering an action always returns the initial value (0).
No warning is raised.

**Why it's insidious:**
If the intent is an early-exit validation gate (`if error_count > 0: raise`), the gate silently
passes no matter how many invalid rows exist. The pipeline continues with corrupt data.

**Minimal repro:**
```python
acc = sc.accumulator(0)
rdd = sc.parallelize([1, -2, 3, -4])
rdd.map(lambda x: acc.add(1) or x)
print(acc.value)   # 0, not 4
rdd.count()        # action triggers execution
print(acc.value)   # 4
```

**How to catch it:**
Always read accumulators after an action:
```python
df.rdd.map(validate).count()   # or .cache() + .count()
print(error_count.value)        # now valid
```

**Real-world trigger:**
A data quality check in a streaming micro-batch that gates downstream writes on an error count.
The gate always passes; bad records flow through silently.

---

### 4. Accumulator Double-Counted on Re-Execution

**What it looks like:**
```python
acc = sc.accumulator(0)
rdd = sc.parallelize(range(100))
processed = rdd.map(lambda x: (acc.add(1), x)[1])  # NOT cached
processed.count()   # action 1: acc = 100
processed.count()   # action 2: acc = 200 — lineage re-executed!
```

**What actually happens:**
Without caching, every action on `processed` re-executes the full lineage from `rdd`. The
accumulator is incremented once per action. After two actions it reads 200, not 100.

**Why it's insidious:**
The first count gives a correct-looking result. The second count inflates the accumulator. Any
logic that reads the accumulator after multiple actions over the same non-cached RDD is wrong.

**How to catch it:**
Cache the RDD/DataFrame before the first action if accumulators are involved:
```python
processed = rdd.map(lambda x: (acc.add(1), x)[1]).cache()
processed.count()
print(acc.value)   # 100, stable
```

**Real-world trigger:**
A pipeline that calls `.count()` to log row counts and then `.write()` to persist — both on the
same non-cached DataFrame. Accumulators used for metrics show 2× the expected value.

---

### 5. Chained `withColumn` on the Same Column Name Creates Duplicate Columns

**What it looks like:**
```python
df = (df
      .withColumn("status", F.lit("pending"))
      .withColumn("status", F.when(F.col("amount") > 0, "active").otherwise("pending"))
      .withColumn("status", F.upper(F.col("status")))
)
df.select("status").show()
```

**What actually happens:**
Each `withColumn("status", ...)` appends a new column named "status" to the internal schema
rather than replacing in place. The schema now has three columns all named "status". Spark's
column resolution picks the *last* one by default — which looks correct for simple selects.
But in a `join`, `groupBy`, or after passing the DataFrame to another function, the reference
`F.col("status")` is **ambiguous** and may silently resolve to any of the three.

**Why it's insidious:**
`df.printSchema()` looks normal (it shows one "status"). `df.select("status")` works. The
ambiguity only surfaces during complex operations, often with a cryptic `AnalysisException:
Reference 'status' is ambiguous` — far from where the duplicate was introduced.

**Minimal repro:**
```python
df = spark.createDataFrame([(1,)], ["id"])
df2 = df.withColumn("x", F.lit(1)).withColumn("x", F.lit(2))
df3 = df2.join(df2.alias("b"), "id")
df3.select("x").show()  # AnalysisException: Reference 'x' is ambiguous
```

**How to catch it:**
```python
def check_no_duplicate_columns(df):
    cols = [c.lower() for c in df.columns]
    dupes = [c for c in cols if cols.count(c) > 1]
    assert not dupes, f"Duplicate columns: {set(dupes)}"
```

**Real-world trigger:**
A modular pipeline where each stage calls `withColumn` on a shared column name. The final
DataFrame has 6 copies of "updated_at" and groupBy silently aggregates on the wrong one.

---

### 6. `count()` in a Loop Silently Re-Evaluates from Source

**What it looks like:**
```python
for threshold in [100, 500, 1000]:
    filtered = df.filter(F.col("amount") > threshold)
    n = filtered.count()   # re-reads source CSV every iteration
    print(f"threshold={threshold}: {n} rows")
```

**What actually happens:**
If `df` is not cached, every `.count()` call re-executes the full lineage from the source (e.g.,
reading a CSV from S3). In a loop of 10 thresholds this means 10 full source scans. If the
source is a live table that changes between iterations, the counts are computed on different
snapshots — silently inconsistent results.

**Why it's insidious:**
Each individual count looks correct for the data it sees. The inconsistency is only visible
when counts are compared — and even then, a slowly-growing table makes the discrepancy small
and plausible-looking.

**How to catch it:**
Cache before the loop:
```python
df.cache()
df.count()   # materialize the cache
for threshold in [...]:
    ...
```

**Real-world trigger:**
A dashboard job that computes revenue by decile with 10 `.count()` calls on a non-cached
DataFrame reading from a Kafka-backed Delta table. The table receives writes mid-job;
each decile is computed on a different data snapshot.

---

### 7. UDF References Module-Level Mutable Object Serialized Once

**What it looks like:**
```python
# config loaded from a file at import time
config = load_config("/etc/pipeline/config.json")   # {"threshold": 100}

@F.udf(returnType=DoubleType())
def apply_threshold(value):
    return float(value) if float(value) > config["threshold"] else 0.0

# Later, config is hot-reloaded on driver:
config["threshold"] = 500  # driver update
df.withColumn("result", apply_threshold(F.col("amount"))).write.parquet(...)
```

**What actually happens:**
Python UDFs are serialized (pickled) when the action fires. At that moment, `config` contains
`{"threshold": 500}` — but Python's pickle captures the object *by reference from the closure*.
What executors receive depends on the Python version and pickle protocol, but in most cases the
updated value (500) is what executors use, not the original 100. Worse: if `config` is a
mutable object shared across threads on the driver, concurrent job submissions serialize
different snapshots of it.

**Why it's insidious:**
Works correctly when config is stable. Fails silently during hot-reload deployments or when
config is modified between job submission and action execution.

**How to catch it:**
Freeze config at UDF definition time:
```python
_threshold = config["threshold"]   # local copy

@F.udf(returnType=DoubleType())
def apply_threshold(value):
    return float(value) if float(value) > _threshold else 0.0
```

**Real-world trigger:**
A feature store pipeline that loads model parameters at startup and hot-reloads them via a
config refresh thread. Concurrent Spark jobs serialize different parameter snapshots, producing
different feature values for the same input data.

---

### 8. `limit()` Non-Determinism on Non-Sorted Data

**What it looks like:**
```python
sample = df.limit(1000)
result1 = sample.agg(F.mean("revenue")).collect()
result2 = sample.agg(F.sum("revenue")).collect()
```

**What actually happens:**
`limit()` on a non-sorted DataFrame is non-deterministic across different action calls. Because
Spark re-evaluates `sample` from scratch for each action (if not cached), the two actions may
see different 1000-row subsets. `result1` and `result2` are computed on different samples.

**Why it's insidious:**
`limit()` looks like it pins a dataset. It does not. It pins the *count*, not the *rows*, and
only for a single action invocation.

**Minimal repro:**
```python
df = spark.range(1_000_000).withColumn("r", F.rand())
s = df.limit(100)
# Two counts can differ if the upstream DataFrame is non-deterministic
print(s.agg(F.min("r")).collect())
print(s.agg(F.max("r")).collect())
# min and max computed on different 100-row subsets
```

**How to catch it:**
Cache `limit()` results before multiple actions:
```python
sample = df.limit(1000).cache()
sample.count()   # materialize
```

**Real-world trigger:**
An exploratory data analysis script that computes multiple statistics on `df.limit(10000)`. Each
`.agg()` call operates on a different sample, making the statistics mutually inconsistent.

---

### 9. Transformation Applied After `cache()` Is Not Part of the Cached Plan

**What it looks like:**
```python
df_cached = df.cache()
df_filtered = df_cached.filter(F.col("status") == "active")
df_cached.count()        # materializes the cache for df_cached
df_filtered.count()      # does this use the cache?
```

**What actually happens:**
`df_filtered` is a new logical plan that includes the filter on top of `df_cached`. When
`df_filtered.count()` runs, Spark uses the cached result of `df_cached` and applies the filter
on top — this is correct. However, if `df_cached` hasn't been materialized yet (the `.count()`
was skipped), `df_filtered.count()` triggers full re-execution from source *and* caches
`df_cached` as a side effect — which can change the apparent behavior of later actions.

The subtle bug: after calling `df_cached.unpersist()`, `df_filtered` reads from source again
silently. There is no error; the result may differ if the source changed.

**How to catch it:**
Use `df.explain()` to verify which plan steps use cached data (`InMemoryRelation` in the plan).
Always unpersist explicitly and verify dependent DataFrames don't silently re-read from source.

**Real-world trigger:**
A pipeline where a cached DataFrame is unpersisted mid-flow for memory management, but a
downstream transformation still holds a reference. That branch silently re-reads from the
mutable source table.

---

### 10. `randomSplit` Without Seed Produces Leaky Train/Test Splits

**What it looks like:**
```python
train, test = df.randomSplit([0.8, 0.2])   # no seed
train.write.parquet("s3://bucket/train/")
test.write.parquet("s3://bucket/test/")
```

**What actually happens:**
Without a seed, `randomSplit` uses a random seed at execution time. Each write triggers a
separate action, which means `train` and `test` are each evaluated independently. The same row
may appear in both `train` and `test` — or in neither. This is train/test leakage.

**Why it's insidious:**
The total row count of `train + test` may roughly equal `df.count()`, so a row-count check
passes. The leakage only shows when model performance is suspiciously high.

**Minimal repro:**
```python
df = spark.range(1000)
train, test = df.randomSplit([0.8, 0.2])
train_ids = set(r.id for r in train.collect())
test_ids = set(r.id for r in test.collect())
overlap = train_ids & test_ids
print(f"Overlapping rows: {len(overlap)}")  # non-zero without seed + cache
```

**How to catch it:**
```python
df_cached = df.cache()
df_cached.count()
train, test = df_cached.randomSplit([0.8, 0.2], seed=42)
```

**Real-world trigger:**
A churn prediction model trained monthly. Without a seed, the train/test split changes each
run. The model's AUC varies by ±0.05 month-over-month from split variance, not true drift.
