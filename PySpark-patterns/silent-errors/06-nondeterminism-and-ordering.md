<!-- Part of PySpark-patterns: Silent Errors — Nondeterminism and Ordering -->

# Silent Errors — Nondeterminism and Ordering

Spark is a distributed system. Row order is not guaranteed. Partition assignment is not
deterministic across runs unless explicitly fixed. Any code that assumes ordering is preserved
through a shuffle — or that `show()` returns the same rows twice — will silently produce
different results on different runs. These bugs are particularly dangerous for ML pipelines
and reconciliation jobs where reproducibility is assumed.

---

### 1. `df.show()` / `df.first()` / `df.head()` Are Not Stable Across Runs

**What it looks like:**
```python
first_row = df.first()
assert first_row["status"] == "active"   # validation in a pipeline
```

**What actually happens:**
`first()` returns the first row from the first partition. Partition layout depends on the
shuffle, which depends on data size, cluster topology, and task scheduling. With different
cluster load or after a Spark version upgrade, the "first" partition contains different rows.
The assertion silently passes or fails based on which row happens to be partition-0-row-0.

**Why it's insidious:**
On a development dataset with a single partition and a deterministic sort, `first()` is stable.
In production with distributed data, it's non-deterministic. Validation logic written against
`first()` / `head()` passes in CI and fails randomly in production.

**Minimal repro:**
```python
df = spark.range(1000).withColumn("r", F.rand())
print(df.first())   # different each run — no exception, just different data
```

**How to catch it:**
Never use `first()` or `head()` for validation. Use deterministic queries:
```python
# Correct: query a specific known row
result = df.filter(F.col("user_id") == "known_test_id").first()
# Or sort before head
result = df.orderBy("user_id").first()
```

**Real-world trigger:**
A smoke test that validates the pipeline produced output by asserting `df.first()["date"]` equals
today's date. On days with data from multiple dates in the first partition, the assertion fails
non-deterministically, causing the on-call engineer to investigate a non-bug.

---

### 2. Sort Within Partition Is Not Preserved After Shuffle

**What it looks like:**
```python
# Write sorted data for efficient downstream range queries
df.sortWithinPartitions("timestamp").write.parquet("s3://bucket/events/")

# Read back
df_read = spark.read.parquet("s3://bucket/events/")
df_read.show()   # assumed to be sorted
```

**What actually happens:**
`sortWithinPartitions()` sorts rows within each partition before writing. Each Parquet file is
internally sorted. However, when reading back, Spark does not guarantee that files are read in
any particular order, and the rows from multiple files are merged in undefined sequence. The
sort is preserved within each file on disk but is lost when the files are read and combined
across partitions.

**Why it's insidious:**
A local `show()` on a single-partition dataset shows sorted output. In production with multiple
files, the read produces interleaved unsorted rows. Downstream code that assumes sorted order
(e.g., window functions relying on physical row order rather than ORDER BY) silently produces
wrong results.

**How to catch it:**
```python
# If sort is required on read, apply it explicitly
df_sorted = spark.read.parquet("s3://bucket/events/").orderBy("timestamp")
# Note: orderBy triggers a full shuffle — verify it's necessary
```

**Real-world trigger:**
A streaming session stitching algorithm that reads Parquet files and expects events to be in
timestamp order for sequential processing. The sort is lost on read; session boundaries are
computed on scrambled event sequences, producing wrong session lengths.

---

### 3. `repartition(N)` Uses Round-Robin Distribution — Non-Deterministic

**What it looks like:**
```python
df_repartitioned = df.repartition(100)
# Assume rows are evenly and deterministically distributed
df_repartitioned.write.parquet("s3://bucket/output/")
```

**What actually happens:**
`repartition(N)` without a column uses a round-robin distribution that is randomized by Spark's
internal hash. Running the same `repartition(100)` on the same DataFrame twice produces
different partition assignments. Two writes of the same logical DataFrame may have identical
data but completely different partition layouts.

**Why it's insidious:**
For pure writes, this doesn't matter. But if code depends on partition layout (e.g., reading
partition 5 to get a specific subset, or joining two repartitioned DataFrames assuming aligned
partitions), the non-determinism produces silently wrong results.

**How to catch it:**
Use `repartition(N, col)` with a deterministic column to get reproducible partition assignment:
```python
df.repartition(100, "user_id")   # deterministic: same user_id → same partition
```

**Real-world trigger:**
A co-partitioning strategy repartitions two DataFrames by the same N before a join, expecting
records with the same key to land on the same partition (a map-side join). Without specifying
the join key in `repartition()`, the partition layouts differ; the join falls back to a full
shuffle silently.

---

### 4. Speculative Execution Duplicates Output Rows in Non-Idempotent Sinks

**What it looks like:**
```python
spark.conf.set("spark.speculation", "true")   # enabled globally for reliability

df.write.jdbc(url, "target_table", mode="append", properties=props)
```

**What actually happens:**
`spark.speculation = true` causes Spark to launch duplicate tasks for any task that takes
longer than 75% of the median task time. Both the original and speculative task may write their
partition to the JDBC table. If both writes commit before Spark can mark one as killed, the
table receives duplicate rows. The job succeeds; the duplicate rows are permanent.

**Why it's insidious:**
SPARK-16741 (filed 2016, still relevant) documents this exact behavior. Speculation is often
enabled cluster-wide for latency improvement. Non-HDFS sinks (JDBC, Kafka, Elasticsearch,
REST APIs) don't have Spark's atomic task commit protocol and are vulnerable. The job reports
success; the data issue is discovered during reconciliation.

**Minimal scenario:**
Any `df.write.jdbc()` or `df.foreachPartition(api_call)` with `spark.speculation = true`
on a slow network or overloaded executor.

**How to catch it:**
```python
# Option 1: Disable speculation for non-idempotent sinks
spark.conf.set("spark.speculation", "false")

# Option 2: Use upsert/MERGE instead of append
# Write to staging table, then MERGE into target
spark.sql("""
    MERGE INTO target t USING staging s ON t.id = s.id
    WHEN MATCHED THEN UPDATE SET *
    WHEN NOT MATCHED THEN INSERT *
""")
```

**Real-world trigger:**
A payment processing pipeline writes transaction records to PostgreSQL with `spark.speculation
= true`. A slow network causes some tasks to be speculated. 0.1% of transactions are duplicated.
The payment system detects duplicates 3 days later during nightly reconciliation — after
customers have been double-charged.

---

### 5. `randomSplit` Without Seed — Train/Test Leakage

**What it looks like:**
```python
train, test = df.randomSplit([0.8, 0.2])   # no seed, not cached
train.write.parquet("s3://bucket/train/")
test.write.parquet("s3://bucket/test/")
```

**What actually happens:**
Each write action re-evaluates `train` and `test` from scratch. The `randomSplit` generates new
split assignments on each evaluation. A row may be in `train` during the first write and in
`test` during the second write (or in neither, if the random assignment changes between the two
evals of the combined lineage). This is train/test leakage.

**Why it's insidious:**
Total `train.count() + test.count()` approximately equals `df.count()` (so a count check
passes). Individual row membership is unstable. The leakage inflates test-set performance
metrics by up to 20% for the leaked rows.

**Minimal repro:**
```python
df = spark.range(1000)
train, test = df.randomSplit([0.8, 0.2])
train_ids_1 = {r.id for r in train.collect()}
train_ids_2 = {r.id for r in train.collect()}
print(f"Train IDs differ between evals: {train_ids_1 != train_ids_2}")  # True without cache
```

**How to catch it:**
```python
# Always seed + cache before split
df_cached = df.cache()
df_cached.count()   # materialize
train, test = df_cached.randomSplit([0.8, 0.2], seed=42)
```

**Real-world trigger:**
A fraud detection model is trained monthly. Without a seed, the train/test split changes each
month. The model's performance appears to improve by 3% — but the improvement is from test set
contamination, not model quality. The model underperforms significantly in live scoring.

---

### 6. `orderBy()` Before `groupBy()` Does Not Preserve Order Through Shuffle

**What it looks like:**
```python
# Try to get the most recent event per user
df.orderBy("event_ts").groupBy("user_id").agg(F.first("status")).show()
```

**What actually happens:**
`orderBy()` sorts the entire DataFrame. Then `groupBy()` triggers a shuffle that redistributes
rows by `user_id`. The shuffle destroys the sort order. The `first()` aggregate picks an
arbitrary row from each partition — not the most recent one. The result is wrong and changes
between runs.

**Why it's insidious:**
The code reads logically: "sort by time, then get first." In a single-machine SQL database,
this works because the sort is preserved. In Spark, the shuffle between `orderBy` and `groupBy`
resets row order. The pattern is a common PySpark anti-pattern that looks correct and runs without error.

**Minimal repro:**
```python
df = spark.createDataFrame([
    ("u1", "2024-01-03", "closed"),
    ("u1", "2024-01-01", "active"),
    ("u1", "2024-01-02", "pending"),
], ["user", "date", "status"])

# Wrong approach
wrong = df.orderBy("date").groupBy("user").agg(F.first("status"))
wrong.show()   # may show "active" or "pending", not "closed"

# Correct approach
from pyspark.sql import Window
w = Window.partitionBy("user").orderBy(F.col("date").desc())
correct = df.withColumn("rn", F.row_number().over(w)).filter("rn = 1").drop("rn")
correct.show()   # always "closed"
```

**How to catch it:**
Any `orderBy().groupBy().agg(F.first())` or `orderBy().groupBy().agg(F.last())` pattern in a
code review is a red flag. Replace with a window function + filter.

**Real-world trigger:**
A CRM pipeline that retrieves the "current" account status by sorting by last_modified_date and
taking `first()` after `groupBy`. The current status is correct in dev (1 partition, no shuffle).
In production (multi-partition), the status is random — some accounts show as "closed" when they
are actually "active."

---

### 7. `collect_list` Order Is Non-Deterministic Without `sort_array`

**What it looks like:**
```python
df.groupBy("session_id").agg(F.collect_list("event_type").alias("event_sequence"))
```

**What actually happens:**
`collect_list` aggregates values into an array but does not guarantee any ordering of the
collected elements. The order depends on which executor processes which partition first, which
changes with cluster load. Two runs of the same pipeline produce different event sequences for
the same session.

**Why it's insidious:**
If the event sequence is used as a feature for a sequence model (RNN, LSTM), the model is
trained on a different sequence each run. Model weights are non-reproducible; the model may
perform differently in production than in evaluation — with no data error detected.

**How to catch it:**
```python
# Ensure deterministic ordering in collected lists
from pyspark.sql.functions import sort_array, struct

df.groupBy("session_id").agg(
    F.sort_array(F.collect_list(F.struct("event_ts", "event_type"))).alias("ordered_events")
)
# Or: use array_sort with a struct that includes the sort key
```

**Real-world trigger:**
A recommendation engine trains on user click sequences. The `collect_list("clicked_item_id")`
produces different orderings on each training run. The model's recommendation quality varies by
±5% MRR between training runs on identical data.

---

### 8. `df.write` Mode `overwrite` With Dynamic Partition Overwrites Silently Drops Other Partitions

**What it looks like:**
```python
spark.conf.set("spark.sql.sources.partitionOverwriteMode", "dynamic")
df_today = spark.read.parquet("s3://bucket/raw/date=2024-01-15/")
df_today.write.mode("overwrite").partitionBy("date").parquet("s3://bucket/output/")
```

**What actually happens:**
With `partitionOverwriteMode = STATIC` (default), `mode="overwrite"` deletes the entire output
path and rewrites it. With `partitionOverwriteMode = DYNAMIC`, only the partitions present in
`df_today` are overwritten. Historical partitions are preserved.

The silent bug: if `df_today` contains data from unexpected dates (e.g., late-arriving data for
`date=2024-01-10`), those partitions are *also* overwritten — silently replacing historical data
with the late-arriving subset.

**How to catch it:**
```python
# Validate that the DataFrame only contains the expected partition values
dates_in_df = {r.date for r in df_today.select("date").distinct().collect()}
expected_dates = {"2024-01-15"}
unexpected = dates_in_df - expected_dates
assert not unexpected, f"DataFrame contains unexpected partitions: {unexpected}"
```

**Real-world trigger:**
A daily ingestion pipeline includes late-arriving records from 5 days ago in the current batch.
Dynamic partition overwrite silently overwrites the 5-day-old partition with only the late records,
dropping all the data originally written for that date. The historical partition shrinks silently.
