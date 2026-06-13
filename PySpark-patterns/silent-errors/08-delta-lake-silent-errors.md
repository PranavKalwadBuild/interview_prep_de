<!-- Part of PySpark-patterns: Silent Errors — Delta Lake Silent Errors -->

# Silent Errors — Delta Lake Silent Errors

Delta Lake adds transactional semantics on top of Parquet — but the transactions are not
immune to silent failures. Non-deterministic MERGE sources, concurrent OPTIMIZE runs, VACUUM
destroying time travel, and schema evolution silently adding NULLs to historical data are
production-grade bugs. These are the bugs that surface when you try to reproduce a quarterly
audit and discover the historical data is not what it was.

---

### 1. `MERGE INTO` With Non-Unique Source — Non-Deterministic Upsert

**What it looks like:**
```python
updates = spark.read.parquet("s3://bucket/daily_updates/")
# updates may have duplicate keys if the source has retried writes

deltaTable.alias("t").merge(
    updates.alias("u"),
    "t.user_id = u.user_id"
).whenMatchedUpdateAll().whenNotMatchedInsertAll().execute()
```

**What actually happens:**
If `updates` contains multiple rows with the same `user_id`, Delta Lake's MERGE behavior for
`WHEN MATCHED UPDATE` is undefined — which duplicate wins depends on the physical order of
rows in the `updates` DataFrame (non-deterministic). In Delta Lake < 2.2, MERGE scans the
source twice; different duplicates may win in each scan, producing inconsistent results. No error.

In Delta Lake 2.2+, sources are auto-materialized to fix the two-scan issue — but duplicate
rows in the materialized source still produce undefined UPDATE behavior.

Note: When multiple source rows match the same target row for UPDATE, Delta Lake raises
`UnsupportedOperationException: Cannot perform MERGE as multiple source rows matched...` — but
only for the UPDATE case. The INSERT case (new rows) silently inserts duplicates.

**Why it's insidious:**
ETL systems often produce retried writes. The duplicates look like valid updates to new keys
(which trigger the INSERT path). The MERGE appears to succeed; the target table has duplicated
rows for those keys.

**Minimal repro:**
```python
# source has duplicate keys for user_id=1
updates = spark.createDataFrame([(1, "alice@new.com"), (1, "alice@newest.com")], ["user_id", "email"])
# MERGE: which email survives? Non-deterministic for the matched UPDATE case.
```

**How to catch it:**
```python
# Deduplicate source before MERGE
from pyspark.sql import Window
w = Window.partitionBy("user_id").orderBy(F.col("updated_at").desc())
deduped_updates = (updates
    .withColumn("rn", F.row_number().over(w))
    .filter("rn = 1")
    .drop("rn")
)
```

**Real-world trigger:**
A CDC (Change Data Capture) pipeline replays events from Kafka. A Kafka consumer offset reset
causes some events to be reprocessed. The MERGE source has duplicate user_id events. For some
users, the older email address "wins" the MERGE; the email list is silently reverted to stale data.

---

### 2. `MERGE INTO` Source With Non-Deterministic Expressions

**What it looks like:**
```python
updates = (spark.read.table("staging")
    .filter(F.col("event_date") >= F.current_date() - 7)   # non-deterministic!
)
deltaTable.merge(updates.alias("u"), "t.id = u.id").whenMatchedUpdateAll().execute()
```

**What actually happens:**
Delta Lake MERGE internally scans the source DataFrame **twice**: once to find matching target
rows, and once to compute the update values. `F.current_date()` returns different values if the
two scans happen across a day boundary. Rows that were in the 7-day window during the first scan
may not be in the window during the second scan. Some updates are applied with stale data, and
some rows are matched but then "disappear" in the second scan.

This is documented in the Delta Lake docs as "a merge operation can produce incorrect results if
the source dataset is non-deterministic."

**Why it's insidious:**
The MERGE completes without error. The result is partially correct — rows processed consistently
between scans are right, rows that straddled the scan boundary have wrong or missing values.

**How to catch it:**
```python
# Materialize non-deterministic sources before MERGE
materialized = updates.cache()
materialized.count()   # force materialization
deltaTable.merge(materialized.alias("u"), "t.id = u.id").whenMatchedUpdateAll().execute()
# Delta Lake 2.2+ does this automatically, but explicit is safer
```

**Real-world trigger:**
A nightly SCD2 merge runs at 23:58. The first MERGE scan completes before midnight; the second
scan runs after midnight. `current_date()` returns different dates in the two scans. Rows for
"yesterday" are matched but not found in the second scan; the SCD2 close date is set to NULL
for those rows silently.

---

### 3. `VACUUM` Breaks Time Travel — Silently Incomplete Results

**What it looks like:**
```python
# Audit query using time travel
spark.sql("SELECT * FROM sales VERSION AS OF 5").show()
# Runs successfully for weeks, then silently returns wrong/incomplete data
```

**What actually happens:**
Delta Lake's time travel reads the Parquet files listed in the transaction log for version 5.
After `VACUUM` removes files older than the retention threshold (default 7 days), the Parquet
files referenced by version 5 may no longer exist. If `spark.sql.files.ignoreMissingFiles=True`
is set (common in production for fault tolerance), the time travel query silently returns a
subset of rows — only the rows whose files survived VACUUM. No error is raised.

With `ignoreMissingFiles=False`, an explicit `FileNotFoundException` is raised. But in many
production clusters, this flag is True to handle transient storage issues.

**Why it's insidious:**
The audit query worked for the first 7 days after the data was written. After VACUUM, it silently
returns incomplete results. The auditor receives a partial dataset without any indication that
it's incomplete.

**How to catch it:**
```python
# Check if time travel version is within VACUUM retention window
import datetime
retention_days = 7
vacuum_cutoff = datetime.datetime.now() - datetime.timedelta(days=retention_days)

table_history = spark.sql("DESCRIBE HISTORY delta.`/path/to/table`")
old_versions = table_history.filter(F.col("timestamp") < vacuum_cutoff)
if old_versions.count() > 0:
    print(f"WARNING: versions before {vacuum_cutoff} may be unavailable after VACUUM")
```

**Real-world trigger:**
A financial compliance system stores daily audit snapshots using Delta time travel. A VACUUM
job was added to reduce storage costs with an aggressive 3-day retention. A quarterly audit
attempts to read version 45 (from 3.5 days ago). `ignoreMissingFiles=True` returns an incomplete
dataset; the audit is signed off on partial data.

---

### 4. `mergeSchema=True` Adds NULLs to All Historical Rows

**What it looks like:**
```python
# Week 1-10: schema has [user_id, revenue]
# Week 11: schema adds new column "region"

new_batch = spark.read.parquet("s3://bucket/raw/week=11/")   # has "region" column
new_batch.write.option("mergeSchema", "true").mode("append").format("delta").save("/delta/sales")

# After merge, compute average revenue by region
spark.read.format("delta").load("/delta/sales").groupBy("region").agg(F.mean("revenue")).show()
```

**What actually happens:**
When `mergeSchema=True` adds the `region` column to the Delta table, all historical rows
(weeks 1-10) have `region = NULL`. The `GROUP BY region` groups all historical rows into the
NULL bucket. `F.mean("revenue")` for NULL region covers 10 weeks of data, while each named
region covers only week 11. The average revenue per region is computed over incomparable time
horizons. No error.

**Why it's insidious:**
Schema evolution looks like a feature, not a bug. The "NULL region" group is a silent artifact
of the schema evolution — not a true business segment.

**How to catch it:**
```python
# After schema evolution, check null rates per column
new_col = "region"
null_pct = spark.read.format("delta").load("/delta/sales").filter(F.col(new_col).isNull()).count() / spark.read.format("delta").load("/delta/sales").count()
print(f"NULL rate for '{new_col}': {null_pct:.1%}")
# If > 50%, historical rows don't have this column — metrics over full history are biased
```

**Real-world trigger:**
A revenue attribution team adds a "channel" column in Q3. After `mergeSchema`, all Q1-Q2 rows
have `channel = NULL`. The Q4 channel-level revenue report shows Q1-Q2 revenue attributed to
the NULL channel — not to any actual channel. Leadership sees a "NULL channel" as the top revenue
source for 6 months with no explanation.

---

### 5. `overwriteSchema=True` + `replaceWhere` Can Silently Drop Columns

**What it looks like:**
```python
# Full historical schema: [date, user_id, revenue, cost, margin]
# Current batch doesn't include "margin" column:
daily_df = spark.createDataFrame([...], schema=["date", "user_id", "revenue", "cost"])

daily_df.write.format("delta") \
    .mode("overwrite") \
    .option("overwriteSchema", "true") \
    .option("replaceWhere", "date = '2024-01-15'") \
    .save("/delta/transactions")
```

**What actually happens:**
`overwriteSchema=True` replaces the table schema with the schema of the current write. The new
schema is `[date, user_id, revenue, cost]` — without `margin`. All historical partitions that
had `margin` values now have the `margin` column dropped at the schema level. The column is gone
from the table metadata; historical `margin` data is unreadable.

**Why it's insidious:**
The write is for a single date partition. The intent is to overwrite just that date's data. But
`overwriteSchema` applies to the entire table, not just the partition being overwritten.
Historical data is intact in the Parquet files on disk but the column metadata is gone — the
data cannot be read without schema reconstruction.

**How to catch it:**
```python
# Never use overwriteSchema=True unless you explicitly intend to change the global schema
# Use replaceWhere WITHOUT overwriteSchema to overwrite a partition:
daily_df.write.format("delta") \
    .mode("overwrite") \
    .option("replaceWhere", "date = '2024-01-15'") \
    .save("/delta/transactions")
# This fails if the schema doesn't match — which is the correct behavior (prevents silent column drops)
```

**Real-world trigger:**
A pipeline that processes daily batches uses `overwriteSchema=True` to avoid schema mismatch
errors during development. The production batch from a new data source is missing the `margin`
column. The entire table loses `margin`. The finance team's margin analysis returns NULL for
all rows the next morning.

---

### 6. Delta `checkpointInterval` Too High — Streaming Replay Duplicates Data

**What it looks like:**
```python
spark.readStream.format("kafka") \
    .option("kafka.bootstrap.servers", "...") \
    .load() \
    .writeStream.format("delta") \
    .option("checkpointLocation", "/checkpoints/stream1") \
    .option("delta.checkpointInterval", "1000")  # checkpoint every 1000 commits
    .start()
```

**What actually happens:**
The Delta streaming checkpoint records the last committed Delta version. If the streaming job
fails and restarts before reaching the next checkpoint interval (e.g., at commit 500 of 1000),
it replays from the last checkpoint at commit 0. The 500 already-processed micro-batches are
reprocessed and their data is written again. If the sink is Delta with `append` mode and no
deduplication, all replayed rows are duplicated silently.

**Why it's insidious:**
The job resumes normally after restart. The checkpoint catches up. The Spark UI shows no errors.
Row counts in the Delta table are 1.5× the expected values — only detectable by comparing source
event count to sink row count.

**How to catch it:**
```python
# Use Delta's idempotent streaming write with txnVersion
(stream.writeStream.format("delta")
    .option("checkpointLocation", "/checkpoints/stream1")
    .queryName("my_stream")
    .start())
# Ensure low checkpointInterval for critical streams
# And validate row counts against the source after any restart
```

**Real-world trigger:**
A clickstream pipeline sets `checkpointInterval=500` to reduce S3 write costs. A cluster
restart at offset 200 causes 200 micro-batches to replay. The click event table contains
duplicate clicks for the replay window. The ad attribution system double-counts clicks and
overpays publishers by the duplicate click amount.

---

### 7. Delta Concurrent Readers and OPTIMIZE: File Version Inconsistency

**What it looks like:**
```python
# Thread 1: long-running read query (30 minutes)
df_long_query = spark.read.format("delta").load("/delta/events").groupBy("user_id").agg(F.sum("amount"))

# Thread 2: concurrent OPTIMIZE
spark.sql("OPTIMIZE delta.`/delta/events`")

# Thread 1 action (30 minutes after the read was defined):
df_long_query.collect()
```

**What actually happens:**
Delta Lake's snapshot isolation means `df_long_query` is bound to a specific Delta version at
the time the read is constructed (snapshot at `spark.read.format("delta").load()`). OPTIMIZE
rewrites the Parquet files into larger ones and creates new transaction log entries. Spark caches
file lists at the snapshot time. If the cached file list includes some pre-OPTIMIZE files (now
deleted by OPTIMIZE) and some post-OPTIMIZE files (new), the read is inconsistent: some
partitions are read from pre-OPTIMIZE files, others from post-OPTIMIZE files.

In practice, Delta's snapshot isolation prevents this — but if `spark.databricks.delta.snapshotIsolation.enabled=False`
or `spark.sql.files.ignoreMissingFiles=True`, and OPTIMIZE runs concurrently, the inconsistency
can silently produce wrong row counts.

**How to catch it:**
```python
# Enable strict snapshot isolation (default on Databricks)
spark.conf.set("spark.databricks.delta.snapshotIsolation.enabled", "true")
# Avoid concurrent OPTIMIZE on tables with long-running reads
```

**Real-world trigger:**
An automated OPTIMIZE job runs every hour. A long-running analytical query starts at XX:55 and
finishes at YY:15 (across the optimize window). With snapshot isolation disabled, the query
reads from a mix of pre- and post-OPTIMIZE file sets, producing a row count 8% lower than
expected. The discrepancy is attributed to "eventual consistency" without further investigation.

---

### 8. Delta `RESTORE` to a Version After VACUUM Silently Returns Partial Data

**What it looks like:**
```python
# Attempt to roll back a bad pipeline run
spark.sql("RESTORE delta.`/delta/transactions` TO VERSION AS OF 42")
```

**What actually happens:**
If version 42's Parquet files have been removed by VACUUM, the RESTORE command fails with
`FileNotFoundException`. However, with `spark.sql.files.ignoreMissingFiles=True`, the RESTORE
silently succeeds but restores only the rows whose Parquet files still exist. The table appears
to be at version 42 in the transaction log, but contains only the rows that survived VACUUM.

**Why it's insidious:**
The RESTORE shows as successful. The table's Delta log reflects version 42. Row counts are
silently lower than version 42 originally had. A subsequent audit shows the RESTORE "worked"
but the data is incomplete.

**How to catch it:**
```python
# Before RESTORE, verify all required Parquet files exist
from delta.tables import DeltaTable
table_history = DeltaTable.forPath(spark, "/delta/transactions").history()
# Check if target version's files are available
# Or extend retention period before RESTORE:
spark.sql("ALTER TABLE delta.`/delta/transactions` SET TBLPROPERTIES ('delta.deletedFileRetentionDuration' = '30 days')")
# Then run VACUUM with the new retention before attempting RESTORE
```

**Real-world trigger:**
A data engineering team discovers a bad pipeline run corrupted 3 days of transaction data.
They attempt a RESTORE to the last clean version (4 days old). VACUUM ran with a 3-day
retention. The RESTORE succeeds on 40% of the files; the other 60% are gone. The "restored"
table has 40% of the expected row count. The partial restoration is accepted as "data partially
recovered" without realizing it's silently wrong rather than a known partial recovery.
