# Edge Case 05: Duplicate Files, Replayed Batches, and Exactly-Once Ingestion

**Cluster baseline:** Driver 8c/32 GB heap + 4 GB overhead | Executor 5c/36 GB heap + 4 GB overhead  
**Throughput coefficient:** 25 MB/s per core | **Safe SLA window:** 2/3 of business SLA  
**Key configs:** `spark.sql.shuffle.partitions = total_cores × 5` | `mergeSchema=false` | AQE=true

---

## 1. The Problem

Upstream re-delivers yesterday's files at 2 AM — a standard retry after a network blip. The pipeline runs again because the scheduler sees new files in the landing zone. The DW table now has 2× the expected row count for that date. Revenue aggregates are wrong. Finance opens a P1. Rolling back a partitioned Parquet table in S3 is a multi-hour manual operation. A Delta table rollback is faster but still costs time and trust.

The underlying guarantee problem: **distributed systems can only natively provide at-least-once delivery**. Upstream re-sends = at-least-once in action. Exactly-once requires application-layer deduplication.

---

## 2. Interview Trigger Phrases

Listen for any of these in the question:

- "duplicate rows in the data warehouse"
- "pipeline ran twice / job ran twice"
- "upstream re-sent yesterday's files"
- "idempotent ingestion"
- "exactly-once semantics"
- "at-least-once vs exactly-once"
- "how do you prevent double-counting"
- "what happens if the job re-runs on the same data"
- "making the pipeline safe to retry"

---

## 3. Detection Signals

| Signal | Where to look |
|---|---|
| Row count post-load > expected (often exactly 2×) | Post-load reconciliation check |
| Duplicate primary keys in target table | `SELECT id, COUNT(*) FROM target GROUP BY id HAVING COUNT(*) > 1` |
| File manifest shows same file_path processed twice | `SELECT file_path, COUNT(*) FROM file_manifest GROUP BY file_path HAVING COUNT(*) > 1` |
| Aggregates (SUM, COUNT) are exact multiples of previous values | Data quality dashboard |
| Two job runs with overlapping `processed_at` windows | Scheduler/Airflow logs |

**Spark UI tell:** If a job processed 2× the expected bytes for a partition date but the source file count is normal, the same files ran twice. Check job history for the same partition date appearing in two separate `JobId` entries.

---

## 4. Root Cause

Distributed systems guarantee **at-least-once** delivery by design. Retries — at the network, scheduler, or application layer — are the mechanism that provides durability. The cost is that any retry can produce a duplicate.

Exactly-once is not a property of the transport layer; it is a property of the **write operation**. The question is whether writing the same data twice produces the same result (idempotent write) or a larger result (non-idempotent append).

**At-least-once → exactly-once spectrum:**

| Write pattern | Guarantee | Risk |
|---|---|---|
| `df.write.mode("append")` | At-least-once | Duplicates on retry |
| `df.write.mode("overwrite").partitionBy("date")` | Effectively-once per partition | Overwrites good data if partition column drifts |
| `MERGE/UPSERT on primary key` | Effectively-once per key | Expensive on large tables without optimization |
| Transactional MERGE (Delta Lake) | Exactly-once | Requires ACID storage layer |

---

## 5. Fix Pattern

Build exactly-once in layers. Each layer catches a different failure mode.

### Layer 1 — File-level idempotency (manifest tracking)

Track every processed file in a metadata table. Skip files already recorded. Write to the manifest **after** successful job completion — not before.

```python
from pyspark.sql import SparkSession
from pyspark.sql.functions import md5, col, lit, current_timestamp
import hashlib, boto3

def get_unprocessed_files(spark: SparkSession, landing_path: str, manifest_table: str) -> list[str]:
    """
    List all files in landing_path.
    Return only those not already in the manifest table.
    """
    # List landing zone
    s3 = boto3.client("s3")
    bucket, prefix = landing_path.replace("s3://", "").split("/", 1)
    paginator = s3.get_paginator("list_objects_v2")

    all_files = []
    for page in paginator.paginate(Bucket=bucket, Prefix=prefix):
        for obj in page.get("Contents", []):
            if obj["Key"].endswith(".parquet"):
                all_files.append(f"s3://{bucket}/{obj['Key']}")

    if not all_files:
        return []

    # Check manifest
    processed = spark.table(manifest_table) \
                     .select("file_path") \
                     .rdd.flatMap(lambda r: [r.file_path]) \
                     .collect()
    processed_set = set(processed)

    return [f for f in all_files if f not in processed_set]


def record_processed_files(spark: SparkSession, file_paths: list[str], manifest_table: str) -> None:
    """Write processed file paths to manifest AFTER successful job completion."""
    if not file_paths:
        return

    records = [(path, hashlib.md5(path.encode()).hexdigest()) for path in file_paths]
    manifest_df = spark.createDataFrame(records, ["file_path", "checksum"]) \
                       .withColumn("processed_at", current_timestamp())

    # INSERT if not already present (idempotent manifest write)
    manifest_df.createOrReplaceTempView("new_files")
    spark.sql(f"""
        INSERT INTO {manifest_table}
        SELECT file_path, checksum, processed_at
        FROM new_files
        WHERE file_path NOT IN (SELECT file_path FROM {manifest_table})
    """)


# --- Main pipeline ---
unprocessed = get_unprocessed_files(spark, "s3://bucket/landing/", "catalog.file_manifest")

if not unprocessed:
    print("No new files to process. Exiting.")
    raise SystemExit(0)

df = spark.read.schema(EXPECTED_SCHEMA).parquet(*unprocessed)

# ... transform ...

df.write.mode("append").format("delta").save("s3://bucket/delta/events/")

# Only record manifest AFTER successful write
record_processed_files(spark, unprocessed, "catalog.file_manifest")
```

### Layer 2 — Row-level idempotency (MERGE / UPSERT)

Use Delta Lake MERGE so writing the same rows twice produces the same table state.

```python
from delta.tables import DeltaTable

target = DeltaTable.forPath(spark, "s3://bucket/delta/events/")

# source_df: the incoming batch (may contain rows already in target)
(
    target.alias("target")
    .merge(
        source_df.alias("source"),
        condition="target.id = source.id AND target.event_date = source.event_date"
    )
    .whenMatchedUpdateAll()       # update if row exists and differs
    .whenNotMatchedInsertAll()    # insert if row is new
    .execute()
)

# MERGE is idempotent: running it twice on the same source_df produces the same target state
```

**Performance note:** MERGE without file skipping scans the entire target table. Use Z-ordering on the join key to enable data skipping:

```python
from delta.tables import DeltaTable

DeltaTable.forPath(spark, "s3://bucket/delta/events/") \
    .optimize() \
    .executeZOrderBy("id", "event_date")
```

### Layer 3 — Partition overwrite (simplest exactly-once for date-partitioned tables)

If data is partitioned by date and a full partition can always be recomputed, overwrite the partition. Running twice on the same date partition produces the same result.

```python
spark.conf.set("spark.sql.sources.partitionOverwriteMode", "DYNAMIC")

df.write \
  .mode("overwrite") \
  .format("delta") \
  .partitionBy("event_date") \
  .save("s3://bucket/delta/events/")

# Re-running on 2026-07-01 data overwrites only the 2026-07-01 partition.
# Other partitions are untouched. This is idempotent per partition.
```

**Risk:** If `event_date` has drift (e.g., late-arriving records with yesterday's date land in today's file), dynamic partition overwrite will overwrite yesterday's partition with incomplete data. Add a partition date assertion before writing:

```python
date_range = df.select("event_date").distinct().collect()
if len(date_range) > 1:
    raise ValueError(f"File contains multiple partition dates: {date_range}. Investigate late arrivals.")
```

### Layer 4 — Row hash deduplication (last line of defense)

Add a deterministic hash of business-key columns. Deduplicate on hash before writing. Catches duplicates that slip through all upstream layers.

```python
from pyspark.sql.functions import sha2, concat_ws, col

# Compute a deterministic row fingerprint
df_hashed = df.withColumn(
    "row_hash",
    sha2(concat_ws("|", col("id"), col("event_ts"), col("event_type")), 256)
)

# Deduplicate: keep first occurrence per hash
df_deduped = df_hashed.dropDuplicates(["row_hash"])

dedup_dropped = df_hashed.count() - df_deduped.count()
if dedup_dropped > 0:
    print(f"WARNING: Dropped {dedup_dropped} duplicate rows by row_hash. Check upstream for replay.")

df_deduped.drop("row_hash").write \
    .mode("overwrite") \
    .format("delta") \
    .partitionBy("event_date") \
    .save("s3://bucket/delta/events/")
```

### Delivery guarantee spectrum (mental model for interviews)

```
APPEND mode
  └─ at-least-once: duplicates on any retry
  
PARTITION OVERWRITE (DYNAMIC)
  └─ effectively-once: idempotent per partition date; unsafe if partition key drifts

MERGE / UPSERT on primary key
  └─ effectively-once: idempotent per business key; expensive without Z-ordering

FILE MANIFEST + MERGE + ROW HASH
  └─ exactly-once: file-level + row-level dedup; most robust; highest implementation cost

DELTA LAKE TRANSACTIONAL COMMIT
  └─ exactly-once: ACID commit log prevents partial writes; rollback is O(seconds)
```

### spark-submit config delta

```bash
spark-submit \
  --conf spark.sql.sources.partitionOverwriteMode=DYNAMIC \          # safe partition overwrite
  --conf spark.sql.sources.commitProtocolClass=org.apache.spark.sql.delta.files.DelayedCommitProtocol \  # Delta transactional commits
  --conf spark.databricks.delta.merge.enableLowShuffle=true \        # optimized MERGE (Databricks runtime)
  --conf spark.sql.shuffle.partitions=200 \
  --conf spark.sql.adaptive.enabled=true \
  your_job.py
```

No executor/driver sizing change for this fix. Exactly-once is an application-layer guarantee — config cannot substitute for correct write logic.

---

## 6. Gotchas

1. **Write the file manifest AFTER job success, never before.** If you record a file as processed before the write completes, a job failure leaves the file permanently skipped. The manifest entry exists; the data does not. This is the worst failure mode: silent data loss with no retry path.

2. **Dynamic partition overwrite is idempotent per partition, not per job.** If the source file for 2026-07-01 contains 5% late records with `event_date = 2026-06-30`, dynamic overwrite will partially overwrite the June 30 partition with an incomplete slice. Always assert on the set of partition dates in the incoming data.

3. **MERGE is expensive on large unoptimized Delta tables.** Without Z-ordering on the merge key, Delta performs a full table scan to find matching rows. On a 10 TB table this can be slower than a full overwrite. Run `OPTIMIZE ... ZORDER BY (id)` on a schedule, not on every MERGE.

4. **`dropDuplicates` on the full dataset is a shuffle.** It produces a stage with `spark.sql.shuffle.partitions` partitions regardless of input size. On a 500 GB dataset with 200 shuffle partitions, each partition is 2.5 GB — likely to spill. Set shuffle partitions = total_cores × 5 (baseline) and enable AQE to coalesce small ones.

5. **Idempotency and ordering are in tension.** If your pipeline emits events and downstream consumers care about order, idempotent writes (overwrite/MERGE) can reorder or re-emit events. Exactly-once for storage is not the same as exactly-once for downstream consumers.

6. **The file manifest itself can be a single point of failure.** If the manifest table is unavailable (Metastore outage, network partition), every file looks unprocessed and you run everything. Put a circuit breaker on the manifest check: if the manifest is unreadable, fail the job rather than defaulting to "process all files".

---

## 7. Interview One-Liner

> "I implement exactly-once in four layers: a file manifest to skip already-processed files, a Delta MERGE on the primary key for row-level idempotency, dynamic partition overwrite for the simple date-partitioned case, and a row hash dedup as a last-resort backstop — and I always write the manifest entry after the job succeeds, never before."
