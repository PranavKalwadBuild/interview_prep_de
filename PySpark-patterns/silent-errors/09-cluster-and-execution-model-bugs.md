<!-- Part of PySpark-patterns: Silent Errors — Cluster and Execution Model Bugs -->

# Silent Errors — Cluster and Execution Model Bugs

The Spark execution model — driver/executor separation, task retry, speculative execution,
broadcast variables, and garbage collection — creates a class of bugs that are invisible in
local mode and only manifest under real cluster conditions. These bugs are the hardest to
reproduce, the most expensive to diagnose in production, and the most likely to produce
silent data corruption rather than loud failures.

---

### 1. Driver OOM From `collect()` on Unintentionally Large DataFrame

**What it looks like:**
```python
# Filter was supposed to return ~100K rows for reporting
df_report = (events
    .filter(F.col("event_type") == "purchase")
    .filter(F.col("region") == "EMEA")
)
result = df_report.collect()   # expected: small, actual: 50M rows
```

**What actually happens:**
If the filter predicates are silently wrong (e.g., `region` column has different capitalization —
"emea" not "EMEA"; or the filter was accidentally dropped in a refactor), `df_report` is the
full events table. `collect()` pulls all 50M rows to the driver. The driver JVM gradually
exhausts heap memory. Before OOM, partial results are returned to calling code; if any
subsequent processing has already started on the partial buffer, some rows have been processed
and some haven't. The job eventually fails with `OutOfMemoryError` — but only after some rows
were processed without error.

**Why it's insidious:**
The partial processing before OOM is the silent part. Any counters, state, or writes that
occurred on the partial `result` list before OOM reflect an incomplete dataset — and they may
have already been committed to a downstream system.

**How to catch it:**
```python
# Guard collect() with a row count check
count_before_collect = df_report.count()
assert count_before_collect < 1_000_000, \
    f"collect() on {count_before_collect:,} rows will likely OOM the driver — use write() instead"
result = df_report.collect()
```

**Real-world trigger:**
A finance report pipeline `collect()`s transaction records for a monthly email report. In
December, transaction volume is 5× higher than the filter predicate anticipated. The driver
OOMs after processing 70% of rows; the email report is sent with partial data by the calling
code before the OOM propagates up the stack.

---

### 2. Stale Broadcast Variable — Captured State at Broadcast Time

**What it looks like:**
```python
# Load reference data from a database
reference_data = load_from_db("SELECT * FROM product_catalog")
reference_bc = sc.broadcast(reference_data)

@F.udf(returnType=StringType())
def lookup_category(product_id):
    return reference_bc.value.get(product_id, "unknown")

df.withColumn("category", lookup_category(F.col("product_id"))).write.parquet(...)
```

**What actually happens:**
`sc.broadcast(reference_data)` serializes `reference_data` at the time of the broadcast call.
If `reference_data` is a Python dict loaded from a database, it captures the state of the
catalog at job submission time. If the product catalog is updated between job submissions (new
products, removed products, category changes), the broadcast variable is stale for the duration
of the job. New products added to the catalog return "unknown"; products with changed categories
return the old category.

**Why it's insidious:**
The job succeeds. The broadcast lookup works for the majority of products (those that existed
and unchanged at broadcast time). The stale entries are a small minority — exactly the new
and recently-changed products that are most important for accurate categorization.

**How to catch it:**
```python
# Reload broadcast variable at job start, not at module import time
def run_job():
    # Always refresh at the start of each job run
    reference_data = load_from_db("SELECT * FROM product_catalog")
    reference_bc = sc.broadcast(reference_data)
    
    df.withColumn("category", lookup_udf(F.col("product_id"))).write.parquet(...)
    
    reference_bc.unpersist()   # cleanup after job
```

**Real-world trigger:**
A product recommendation pipeline broadcasts a product→category mapping loaded at service
startup. The service runs for weeks between restarts. Products added after startup are classified
as "unknown" silently. The recommendation engine never learns preferences for new product
categories because they all map to "unknown."

---

### 3. `spark.default.parallelism` vs `spark.sql.shuffle.partitions` — Silently Different Parallelism

**What it looks like:**
```python
spark.conf.set("spark.default.parallelism", "400")
# Expected: all parallel operations now use 400 partitions
df.groupBy("user_id").agg(F.sum("revenue"))   # this join uses 200 (default), not 400!
```

**What actually happens:**
`spark.default.parallelism` controls RDD operations and the number of partitions for
`sc.parallelize()`. It does NOT affect DataFrame/SQL operations.
`spark.sql.shuffle.partitions` controls DataFrame joins and aggregations (default: 200).
Setting one silently does not affect the other. A pipeline that appears to be tuned for 400
parallelism runs all DataFrame shuffles at 200 partitions — silently under-parallelized or
over-partitioned depending on the workload.

**Why it's insidious:**
Performance tuning documentation often shows `spark.default.parallelism` as the knob to turn.
Engineers set it and observe no change in DataFrame query performance. The correct knob
(`spark.sql.shuffle.partitions`) is different. The misconfiguration is invisible until someone
inspects the Spark UI's shuffle partition counts.

**How to catch it:**
```python
# Always set both when mixing RDD and DataFrame operations
spark.conf.set("spark.default.parallelism", "400")
spark.conf.set("spark.sql.shuffle.partitions", "400")

# Or enable AQE to set shuffle partitions dynamically:
spark.conf.set("spark.sql.adaptive.enabled", "true")
spark.conf.set("spark.sql.adaptive.coalescePartitions.enabled", "true")
```

**Real-world trigger:**
A migration from RDD-based pipeline to DataFrame-based pipeline. The original pipeline tuned
`spark.default.parallelism = 800` for the large cluster. The new DataFrame pipeline runs all
joins at the default 200 shuffle partitions — 4× under-partitioned for the cluster size. Memory
spill and job slowdowns are attributed to "larger data" rather than misconfiguration.

---

### 4. GC Pause Causes Heartbeat Timeout → Executor Declared Dead → Duplicate Task Writes

**What it looks like:**
```python
# Executor under GC pressure (large heap, many small objects)
df.write.format("jdbc") \
    .option("url", jdbc_url) \
    .option("dbtable", "target_table") \
    .mode("append") \
    .save()
```

**What actually happens:**
During a full GC pause, an executor stops all threads — including the heartbeat sender. If the
pause exceeds `spark.network.timeout` (default 120 seconds), the driver marks the executor as
dead and reschedules its tasks on other executors. But the original executor resumes after GC,
finishes its task, and writes its JDBC rows. The rescheduled task on the new executor also
writes. The target table receives duplicate rows from both executors. Spark reports the job as
successful. No error is raised.

**Why it's insidious:**
The duplicate write is silent. Both writes committed independently. The Spark event log shows
the original task as "killed" and the new task as "succeeded" — but the "killed" task actually
wrote before it was killed. Without checking the JDBC row count, the duplication is invisible.

**How to catch it:**
```python
# Option 1: Use idempotent writes (MERGE instead of append)
# Option 2: Tune GC to reduce pause frequency
# In spark-submit or cluster config:
# --conf "spark.executor.extraJavaOptions=-XX:+UseG1GC -XX:InitiatingHeapOccupancyPercent=35"

# Option 3: Increase network timeout to accommodate GC pauses
spark.conf.set("spark.network.timeout", "600s")
spark.conf.set("spark.executor.heartbeatInterval", "60s")

# Option 4: Post-write deduplication
spark.sql("DELETE FROM target_table WHERE id IN (SELECT id FROM target_table GROUP BY id HAVING COUNT(*) > 1)")
```

**Real-world trigger:**
A nightly batch pipeline writes 50M rows to a data warehouse via JDBC. The cluster uses large
32GB executor heaps with default G1GC settings. Full GC pauses of 150 seconds occur on 2-3
executors per job. Those executors are declared dead; their tasks are retried; both writes
commit. The data warehouse has 0.5% duplicate rows every morning. The ETL team adds a
"deduplication step" without understanding the root cause.

---

### 5. Task Retry on Side-Effectful Sink Writes Data Multiple Times

**What it looks like:**
```python
def write_to_kafka(partition):
    producer = KafkaProducer(bootstrap_servers="...")
    for row in partition:
        producer.send("events", value=row.asDict())
    producer.flush()

df.foreachPartition(write_to_kafka)
```

**What actually happens:**
Spark retries failed tasks up to `spark.task.maxFailures` times (default 4). If a task fails
mid-write (e.g., producer timeout after 50% of rows are sent), the retry sends those 50% of
rows again, plus the remaining 50%. Kafka receives 150% of the partition's rows. No error
is raised to the Spark driver. The Kafka topic has duplicate events.

**Why it's insidious:**
This is fundamentally different from the speculation bug (pattern 4 in file 06): retries are
triggered by failures, not slowness. Failed tasks are correctly reported as retried in the
Spark UI — but the side effects of the partial first attempt are not undone.

**How to catch it:**
```python
# Use idempotent Kafka producer with transactional guarantees
def write_to_kafka_idempotent(partition):
    producer = KafkaProducer(
        bootstrap_servers="...",
        enable_idempotence=True,         # prevents duplicates within a session
        transactional_id="spark-task-" + str(partition_id)   # exactly-once semantics
    )
    producer.init_transactions()
    producer.begin_transaction()
    for row in partition:
        producer.send("events", key=row["id"].encode(), value=row.asDict())
    producer.commit_transaction()
```

**Real-world trigger:**
An event-driven architecture where PySpark publishes processed events to Kafka. A cluster
network partition causes 3% of tasks to fail and retry. Those tasks publish their events twice.
The downstream stream processing system counts each event twice, inflating session counts and
revenue metrics by 3%.

---

### 6. Executor OOM From Implicitly Broadcast Table Exceeding Memory

**What it looks like:**
```python
# AQE decides to broadcast a "small" table based on pre-filter statistics
spark.conf.set("spark.sql.adaptive.enabled", "true")
spark.conf.set("spark.sql.autoBroadcastJoinThreshold", "100mb")

large_fact.join(dimension_table, "product_id")
```

**What actually happens:**
The planner estimates `dimension_table` at 80MB (below the 100MB threshold). AQE broadcasts it.
But the estimate was computed before a JOIN of `dimension_table` with another large table (the
actual `dimension_table` passed to the join). The post-join dimension_table is 800MB. The 800MB
object is broadcast to every executor. With 20 executors each using 800MB for the broadcast
table, the total cluster memory allocated to the broadcast is 16GB — exceeding executor heap
size and triggering OOM on each executor silently.

**Why it's insidious:**
The plan looks like an optimization (broadcast join). The executors OOM with `java.lang.OutOfMemoryError:
Java heap space` — which points to the symptom, not the cause. The Spark UI shows a successful
broadcast join; the OOM is reported as a task failure, not a planning failure.

**How to catch it:**
```python
# Check estimated broadcast size in the explain plan before running
df.explain(True)   # look for "EstimatedSizes" in the plan — > 100MB is a red flag

# Or disable auto-broadcast for joins involving complex intermediate tables
df = large_fact.join(F.broadcast(dimension_table.hint("broadcast")), "product_id")
# Explicit hint gives you control; size estimation is your responsibility
```

**Real-world trigger:**
An analytical pipeline joins a fact table to a "small" dimension table. The dimension table was
small during development (5MB). After 6 months of data growth, it's 2GB. AQE still broadcasts
it (the old statistics were cached). Executors OOM; jobs fail and retry on new executors which
also OOM. The cluster is unstable for hours.

---

### 7. `spark.sql.shuffle.partitions` Too Low Causes Shuffle Spill → Silent Perf Degradation Leading to Partial Writes

**What it looks like:**
```python
spark.conf.set("spark.sql.shuffle.partitions", "10")   # set for small dev data
# In production with 500M rows, each shuffle partition is 50M rows
df.groupBy("user_id").agg(F.collect_list("events"))   # must fit 50M rows per partition
```

**What actually happens:**
With too few shuffle partitions, each partition is very large. When a partition exceeds the
executor's memory, Spark spills to disk. Spilling is not a failure — it's a fallback. But:
1. Spill to disk is 100× slower than in-memory processing.
2. If disk also fills up, the task fails and retries on another executor.
3. If the disk-full failure happens mid-write (e.g., writing a large partition to S3), the
   write is incomplete. The retry writes from scratch. If the output path has both the partial
   first write and the complete retry, the output has duplicated rows.

**Why it's insidious:**
The job eventually succeeds (after retries). Performance degradation is attributed to "large
data." The partial+complete write duplication is only visible in row count validation.

**How to catch it:**
```python
# Rule of thumb: target 100-200MB per shuffle partition
total_data_bytes = 500_000_000 * 100  # rows * avg bytes per row
target_partition_size_bytes = 128 * 1024 * 1024  # 128MB
recommended_partitions = int(total_data_bytes / target_partition_size_bytes)
spark.conf.set("spark.sql.shuffle.partitions", str(recommended_partitions))

# Enable AQE to auto-tune:
spark.conf.set("spark.sql.adaptive.coalescePartitions.enabled", "true")
```

**Real-world trigger:**
A machine learning feature pipeline tuned in development with `shuffle.partitions=50` runs in
production on 10TB data. Each shuffle partition holds 200GB; executors spill to local disk.
The NVMe disks fill up; 12% of tasks fail and retry. The output has 12% row duplication.
The feature store's deduplication step masks the issue, but the training data is quietly 12%
larger than expected.

---

### 8. Executor Lost Mid-Job Causing Stage Re-Submission — Intermediate Write Duplication

**What it looks like:**
```python
# Multi-stage pipeline that writes intermediate results
raw_df.write.parquet("/tmp/stage1_output/")
stage1_df = spark.read.parquet("/tmp/stage1_output/")
stage1_df.groupBy("user_id").agg(...).write.parquet("/tmp/stage2_output/")
```

**What actually happens:**
If an executor is lost during stage 1's write, Spark re-submits the failed tasks. The retried
tasks write their partition's data to `/tmp/stage1_output/`. But if some tasks had partially
written before the executor was lost, and the file system does not support atomic commits (e.g.,
S3 without Hadoop-aware committers), the partial files from the first attempt may coexist with
the complete files from the retry. Reading `/tmp/stage1_output/` in stage 2 includes both the
partial and complete versions of the same partition's data.

**Why it's insidious:**
S3 does not have native atomic file commits. The default Spark output committer on S3 can leave
partial files. Both the partial file and the complete retry file exist in the output directory.
Subsequent reads on that directory process rows from both files — silently doubling some rows.

**How to catch it:**
```python
# Use the S3A committer for atomic writes on S3
spark.conf.set("spark.hadoop.fs.s3a.committer.name", "partitioned")
spark.conf.set("spark.sql.sources.commitProtocolClass",
    "org.apache.spark.internal.io.cloud.PathOutputCommitProtocol")

# Or: Use Delta Lake for all intermediate writes (provides atomic commits)
raw_df.write.format("delta").save("/delta/stage1_output/")
```

**Real-world trigger:**
A multi-stage ETL pipeline writes intermediate Parquet files to S3 without magic committer
configuration. An executor fails due to spot instance preemption. The retry writes complete
files; the partial files remain. The final aggregation is 3% overstated. The error is discovered
during a reconciliation audit, but the root cause (partial file coexistence) takes 2 weeks to
diagnose.

---

### 9. Python Serialization of Lambda Captures Unexpected Outer Scope

**What it looks like:**
```python
THRESHOLD = 100

def process_partition(partition_df):
    return partition_df.filter(partition_df["value"] > THRESHOLD)

df.mapInPandas(process_partition, schema=df.schema)
```

**What actually happens:**
When `process_partition` is serialized, Python's pickle captures the function's `__globals__`
reference — not just `THRESHOLD`. In some Python versions and serialization paths, the entire
module's global namespace is serialized, including all imported modules, large data structures,
and DB connections that may be in scope. If any of these are not serializable, the UDF fails.
More insidiously, if `THRESHOLD` is a mutable global that is modified between serialization and
execution (same closure mutation as pattern 1 in file 01), executors use the mutated value.

**How to catch it:**
```python
# Use explicit closure with frozen local variable
def make_processor(threshold):
    def process_partition(partition_df):
        return partition_df[partition_df["value"] > threshold]
    return process_partition

processor = make_processor(THRESHOLD)   # threshold is captured as a local, not global
df.mapInPandas(processor, schema=df.schema)
```

**Real-world trigger:**
A distributed feature engineering pipeline captures model hyperparameters as module-level
globals. During a hyperparameter sweep, multiple Spark jobs run concurrently. Each job's UDF
serializes the current global state — but due to concurrent modification, some jobs' UDFs use
hyperparameters from the wrong sweep iteration. Feature computation is silently wrong for
cross-contaminated jobs.

---

### 10. `persist()` Without `unpersist()` Causes Silent Memory Pressure OOM

**What it looks like:**
```python
for table in ["sales", "inventory", "customers", "products"]:
    df = spark.read.table(table)
    df.persist()
    # ... process df ...
    # Forgot to call df.unpersist()
```

**What actually happens:**
Each `persist()` call pins a copy of the DataFrame in executor memory (or disk, depending on
storage level). If `unpersist()` is never called, all persisted DataFrames accumulate in memory
across all executors. As the loop progresses, executor memory fills. When executor memory is
exhausted, Spark evicts cached blocks (LRU) to make room — silently. The evicted blocks are
re-computed on next access by re-reading from source.

**Why it's insidious:**
The re-computation after eviction produces correct results — but from potentially stale data if
the source changed. More critically: the memory pressure from unpersisted DataFrames causes GC
pauses, heartbeat timeouts, and the executor-declared-dead bug (pattern 4 in this file), which
then causes the task-retry duplicate write bug. The chain of silent failures is triggered by a
forgotten `unpersist()`.

**How to catch it:**
```python
# Use context manager pattern for persist/unpersist
from contextlib import contextmanager

@contextmanager
def cached_df(df):
    df.persist()
    df.count()   # materialize immediately
    try:
        yield df
    finally:
        df.unpersist()

with cached_df(spark.read.table("sales")) as df_sales:
    # process df_sales
    pass
# unpersist is guaranteed even on exception
```

**Real-world trigger:**
A daily pipeline processes 30 reference tables, caching each for fast lookups. Each persist()
pins 500MB × 30 = 15GB across the cluster. The cluster has 12GB of executor memory per node.
After processing 24 tables, the executor memory is full; LRU eviction begins. The evicted
reference tables are re-read from a slowly-loading catalog. GC pressure increases. The job
completes in 8 hours instead of 30 minutes.
