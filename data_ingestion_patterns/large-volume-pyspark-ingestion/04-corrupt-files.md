# Edge Case 04: Corrupt, Malformed, and Partially Written Input Files

**Cluster baseline:** Driver 8c/32 GB heap + 4 GB overhead | Executor 5c/36 GB heap + 4 GB overhead  
**Throughput coefficient:** 25 MB/s per core | **Safe SLA window:** 2/3 of business SLA  
**Key configs:** `spark.sql.shuffle.partitions = total_cores × 5` | `mergeSchema=false` | AQE=true

---

## 1. The Problem

The job fails mid-read with a stack trace like:

```
SparkException: Malformed Parquet file. Its footer doesn't contain split offset:
  file: s3://bucket/events/date=2026-07-01/part-00047.parquet
```

Or, more dangerously, it succeeds — but with a row count 12% lower than the source system reports. The missing rows came from partially written files that Spark treated as valid until it silently skipped the truncated row groups.

Both outcomes are production-breaking. Silent undercounting is worse than the crash because it passes SLA checks and poisons downstream aggregates for days before anyone notices.

---

## 2. Interview Trigger Phrases

Listen for any of these in the question:

- "job crashes on read"
- "malformed Parquet / ORC file"
- "partially written file landed in the path"
- "failed upload made it to S3"
- "S3 multipart upload was aborted"
- "ORC footer missing" / "Parquet footer missing"
- "EOFException reading file"
- "task fails on a specific file"
- "row count lower than expected after load"

---

## 3. Detection Signals

| Signal | Where to look |
|---|---|
| `SparkException: Could not read footer for file` | Driver logs, task failure log |
| `EOFException` in executor stderr | Spark UI — Stages tab, failed task details |
| Task retry storm on a single executor | Spark UI — Tasks tab, tasks with 3+ retry attempts |
| One executor/file keeps appearing in failures | Spark UI — Failed Tasks, check `Locality Level` and file path |
| `inputRowCount` < source system count | Post-load reconciliation / data quality check |
| File size outlier (0 bytes or << median) | Pre-read file listing + size check |

**Spark UI tell:** A corrupt file causes task failures that exhaust retries (`spark.task.maxFailures`, default 4). The job then aborts with the file path visible in the last task failure reason. Look for the same file path repeated across retries.

---

## 4. Root Cause

Parquet and ORC writes are **not atomic at the file level**.

**Parquet write sequence:**
1. Row group data is written sequentially to the file body.
2. The file **footer** (schema + row group offsets + statistics) is written **last**.
3. If the writer process dies between steps 1 and 2 — network partition, OOM kill, spot instance eviction — a partial file exists in the object store with valid row group bytes but **no footer**.
4. Spark reads the footer first to plan the read. No footer → `SparkException`.

**S3 multipart upload mechanics make this worse:**
- S3 multipart uploads create a visible, addressable object as soon as the final `CompleteMultipartUpload` call arrives — or they can leave a partial object if the client crashes after uploading parts but before completing.
- Unlike HDFS, S3 has no "in-progress write" visibility guard. A partial object looks identical to a complete one to any `ListObjects` call.
- The `_SUCCESS` file convention (Hadoop's commit protocol) helps but is not enforced at the S3 API level.

**ORC corrupts differently:** ORC uses **stripes** (analogous to Parquet row groups) and a file tail (footer). A partial stripe write produces a file where Spark can read early stripes but fails on the truncated stripe boundary — this can produce a lower row count without any exception, depending on how the ORC reader handles it.

---

## 5. Fix Pattern

### Option A (Spark): Read-time resilience with `ignoreCorruptFiles`

Use only when data loss is acceptable and you have a downstream reconciliation check. Never use in isolation.

```python
# Read-time: skip unreadable files entirely
spark.conf.set("spark.sql.files.ignoreCorruptFiles", "true")

df = spark.read.parquet("s3://bucket/events/date=2026-07-01/")

# MANDATORY: reconcile row count against source system
actual_count   = df.count()
expected_count = get_source_count(date="2026-07-01")  # your audit API / manifest

tolerance = 0.001  # 0.1% tolerance
if abs(actual_count - expected_count) / expected_count > tolerance:
    raise ValueError(
        f"Row count mismatch: got {actual_count}, expected {expected_count}. "
        f"Corrupt files may have been silently skipped. Investigate before proceeding."
    )
```

**Mode comparison** (for `spark.read.csv` / text formats — Parquet ignores `mode` and uses `ignoreCorruptFiles`):

| Mode | Behavior | Use when |
|---|---|---|
| `PERMISSIVE` (default) | Corrupt rows go to `_corrupt_record` column | You want to quarantine and inspect |
| `DROPMALFORMED` | Silently skip corrupt rows | You can tolerate minor loss with reconciliation |
| `FAILFAST` | Raise exception on first bad row | Zero-tolerance pipelines, fail loudly |

### Option B: Pre-validation — scan files before reading

Read file metadata before dispatching the full job. Catch problems when they are cheap to fix.

```python
import boto3
from pyspark.sql import SparkSession

def validate_parquet_files(bucket: str, prefix: str, min_size_bytes: int = 512) -> list[str]:
    """
    List all Parquet files under prefix.
    Return paths of files that are suspiciously small (likely truncated).
    min_size_bytes: anything below this is almost certainly incomplete.
    Parquet magic bytes are 4 bytes at start + 4 at end; footer overhead is ~200 bytes minimum.
    """
    s3 = boto3.client("s3")
    paginator = s3.get_paginator("list_objects_v2")

    suspect_files = []
    for page in paginator.paginate(Bucket=bucket, Prefix=prefix):
        for obj in page.get("Contents", []):
            key = obj["Key"]
            size = obj["Size"]
            if key.endswith(".parquet") and size < min_size_bytes:
                suspect_files.append(f"s3://{bucket}/{key}")

    return suspect_files

suspect = validate_parquet_files("bucket", "events/date=2026-07-01/")
if suspect:
    raise RuntimeError(
        f"Suspect files detected before read — likely partial writes:\n"
        + "\n".join(suspect)
        + "\nFix upstream or remove these files before proceeding."
    )

# Only reach here if all files look healthy
df = spark.read.parquet("s3://bucket/events/date=2026-07-01/")
```

### Option C: Write-side fix — atomic rename pattern

Fix the problem at the source. Write to a staging path, validate, then move atomically.

```python
# Writer side — use staging path
staging_path = "s3://bucket/staging/events/date=2026-07-01/"
final_path   = "s3://bucket/events/date=2026-07-01/"

df.write \
  .mode("overwrite") \
  .parquet(staging_path)

# Validate staging output before promoting
staged_df    = spark.read.parquet(staging_path)
staged_count = staged_df.count()

if staged_count != expected_count:
    raise ValueError(f"Staging count {staged_count} != expected {expected_count}. Aborting promotion.")

# "Rename" on S3: copy objects to final path, then delete staging
# True atomic rename doesn't exist on S3; use boto3 copy + delete
import boto3
s3 = boto3.resource("s3")
# ... (copy each object from staging to final, then delete staging)
# In practice: use AWS CLI `aws s3 mv` or a Hadoop FileSystem rename call
# Delta Lake handles this internally via its commit log

# _SUCCESS sentinel file — downstream jobs check for this before reading
spark.sparkContext.parallelize([""]).saveAsTextFile(final_path + "_SUCCESS")
```

### Option D: Delta Lake rollback

When a bad write makes it through to a Delta table, roll back cleanly without dropping and recreating.

```python
from delta.tables import DeltaTable

dt = DeltaTable.forPath(spark, "s3://bucket/delta/events/")

# Inspect history to find the last good version
dt.history(10).select("version", "timestamp", "operation", "operationParameters").show(truncate=False)

# Roll back to the last known-good version
dt.restoreToVersion(42)   # version number from history

# Verify
restored_count = spark.read.format("delta").load("s3://bucket/delta/events/").count()
print(f"Restored row count: {restored_count}")
```

### spark-submit config delta

```bash
spark-submit \
  --conf spark.sql.files.ignoreCorruptFiles=true \     # resilient reads — pair with row-count check
  --conf spark.sql.files.ignoreMissingFiles=true \     # tolerate files deleted between listing and read
  --conf spark.task.maxFailures=4 \                    # default; increase to 8 if transient S3 errors common
  --conf spark.sql.shuffle.partitions=200 \
  --conf spark.sql.adaptive.enabled=true \
  your_job.py
```

**Warning:** `ignoreCorruptFiles=true` is a last resort. Always accompany it with a post-read row count check.

---

## 6. Gotchas

1. **`ignoreCorruptFiles=true` masks real problems.** A corrupt file is almost always a symptom — upstream writer died, network partition, insufficient disk space. Swallowing the error without alerting means the root cause recurs. Always log which files were skipped and alert on any skip.

2. **Partial writes are more common in streaming than batch.** Spark Structured Streaming with file sinks can leave `.part-XXXX.parquet.tmp` files if a task is killed mid-write. Use `checkpointLocation` and the `forEachBatch` sink to get atomic batch commits.

3. **ORC and Parquet corrupt differently.**
   - Parquet: missing footer → immediate `SparkException` on task start. Detectable.
   - ORC: truncated stripe → Spark reads valid stripes, silently stops at the broken one. Row count is wrong but no exception. Much harder to detect without reconciliation.

4. **S3 eventual consistency is mostly gone (strong consistency since Dec 2020), but multipart upload zombies persist.** An aborted multipart upload leaves orphaned parts in S3 that do NOT appear in `ListObjects` — they cost money but aren't readable. Run `aws s3api list-multipart-uploads` to find and abort them. This is different from a completed-but-truncated object.

5. **`_SUCCESS` is a convention, not a guarantee.** Any process can write a `_SUCCESS` file without having written valid data. Validate actual file contents (size, footer check), not just the sentinel.

6. **File size alone is insufficient for Snappy-compressed Parquet.** A valid 1 million-row Snappy Parquet file can be under 1 MB. Use footer integrity (try reading schema) rather than size thresholds alone for large-scale validation.

---

## 7. Interview One-Liner

> "I treat input paths as untrusted: I run a pre-read file size and footer check to quarantine suspect files before the main read, set `ignoreCorruptFiles=true` only as a safety net, and always reconcile the output row count against the source system manifest — silent undercounting is the failure mode that kills you in production."
