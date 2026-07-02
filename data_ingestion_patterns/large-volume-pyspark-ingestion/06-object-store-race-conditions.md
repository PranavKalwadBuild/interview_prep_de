# 06 — Object Store Race Conditions

## 1. The Problem

Spark lists S3 files at job start — but the writer is still uploading. Spark misses in-flight files and processes a silently incomplete dataset. Alternatively, the writer finishes but S3 LIST returns a stale cache, so Spark sees 99.8% of files and drops 0.2% with no error raised.

Nobody notices for days. Row counts are slightly off. Downstream aggregates are wrong. Reconciliation reveals missing records.

---

## 2. Interview Trigger Phrases

- "files missing right after write"
- "S3 eventual consistency"
- "job runs but misses some files"
- "manifest file"
- "file listing slow"
- "100k files in one partition prefix"
- "S3 LIST costs"

---

## 3. Detection Signals

| Signal | Where to Look |
|---|---|
| Row count post-load < expected | Compare `df.count()` against source system record count |
| S3 LIST API calls in driver logs for minutes before job starts | Driver stdout / CloudWatch S3 API metrics |
| Files exist in S3 but Spark cannot see them | `aws s3 ls` returns file; `spark.read.load()` raises `FileNotFoundException` |
| Intermittent `FileNotFoundException` on retry | Executor task stderr in Spark UI |
| `parallelPartitionDiscovery` taking > 60s | Spark UI → Jobs → job submission delay before any task runs |

---

## 4. Root Cause

S3 (and to a lesser extent GCS and ADLS) is an eventually consistent key-value store, **not a POSIX filesystem**. Key behaviors that break Spark assumptions:

- **LIST pagination races concurrent writes**: Even with S3 Strong Consistency (added December 2020), a concurrent `PUT` during a paginated `LIST` can be missed if pagination started before the object was created.
- **Large directory LIST latency**: Directories with 100k+ files can take minutes to fully enumerate via paginated `LIST` calls. Spark issues these serially by default.
- **No atomic directory rename**: Hadoop's `_temporary/` commit protocol relies on directory rename, which does not exist on S3. This is why Spark jobs writing to S3 can leave partial data visible.

S3 Strong Consistency (2020) fixed read-after-write for `GET` and `HEAD`. It does **not** eliminate all race conditions during concurrent multi-file writes with LIST pagination.

---

## 5. Fix Pattern

### Option A — Manifest-based ingestion (preferred)

The writer generates a manifest file listing all completed paths after finishing all uploads. Spark reads paths from the manifest, bypassing S3 LIST entirely.

```python
# Writer side: generate manifest after all uploads complete
manifest_paths = [
    "s3://bucket/data/part-00000.parquet",
    "s3://bucket/data/part-00001.parquet",
    # ... all paths
]
manifest_content = "\n".join(manifest_paths)
s3_client.put_object(
    Bucket="bucket",
    Key="manifests/job_20240101_manifest.txt",
    Body=manifest_content
)

# Reader side: read manifest, load only listed files
import boto3

s3 = boto3.client("s3")
manifest_obj = s3.get_object(Bucket="bucket", Key="manifests/job_20240101_manifest.txt")
paths = manifest_obj["Body"].read().decode().strip().split("\n")

df = spark.read.parquet(*paths)  # explicit paths, no LIST call
```

### Option B — Wait for `_SUCCESS` marker

```python
import time
from pyspark.sql import SparkSession

def wait_for_success(spark, path, timeout_seconds=300, poll_interval=10):
    """Poll for _SUCCESS marker before reading."""
    success_path = f"{path}/_SUCCESS"
    deadline = time.time() + timeout_seconds
    while time.time() < deadline:
        try:
            fs = spark._jvm.org.apache.hadoop.fs.FileSystem.get(
                spark._jvm.java.net.URI(path),
                spark._jsc.hadoopConfiguration()
            )
            if fs.exists(spark._jvm.org.apache.hadoop.fs.Path(success_path)):
                return True
        except Exception:
            pass
        time.sleep(poll_interval)
    raise TimeoutError(f"_SUCCESS not found at {success_path} after {timeout_seconds}s")

wait_for_success(spark, "s3://bucket/data/landing/")
df = spark.read.parquet("s3://bucket/data/landing/")
```

### Option C — Checkpoint metadata table

Writer records each file path, size, and checksum in a metadata DB on write completion. Ingestion job queries the DB instead of calling S3 LIST.

```python
# Writer side: record to metadata table after each file upload
metadata_df = spark.createDataFrame([
    ("s3://bucket/data/part-00000.parquet", 1048576, "abc123"),
    ("s3://bucket/data/part-00001.parquet", 2097152, "def456"),
], ["file_path", "size_bytes", "checksum"])

metadata_df.write.mode("append").saveAsTable("ingestion_metadata.file_registry")

# Reader side: query metadata table, load only confirmed files
confirmed = spark.sql("""
    SELECT file_path FROM ingestion_metadata.file_registry
    WHERE job_id = '20240101' AND status = 'complete'
""")
paths = [row.file_path for row in confirmed.collect()]
df = spark.read.parquet(*paths)
```

### Option D — Accelerate file listing when unavoidable

```python
# Parallelize S3 LIST when you must enumerate a large directory
spark.conf.set("spark.sql.sources.parallelPartitionDiscovery.parallelism", "64")
spark.conf.set("spark.sql.sources.parallelPartitionDiscovery.threshold", "32")

# Hadoop-level parallelism for file status listing
spark.conf.set("mapreduce.input.fileinputformat.list-status.num-threads", "64")
```

### Option E — Use Delta Lake (sidesteps problem entirely)

```python
# Delta keeps its own transaction log — no S3 LIST involved
df = spark.read.format("delta").load("s3://bucket/delta/my_table/")

# Or use Delta table name
df = spark.read.table("my_delta_table")
```

Delta's `_delta_log/` transaction log is a single source of truth for which files exist. Spark reads the log (a handful of JSON/Parquet files), not the full directory.

### spark-submit config delta

```bash
spark-submit \
  --conf spark.sql.sources.parallelPartitionDiscovery.parallelism=64 \
  --conf spark.hadoop.mapreduce.input.fileinputformat.list-status.num-threads=64 \
  ...
```

---

## 6. Gotchas

- **Never assume LIST is complete immediately after a write.** Even with S3 Strong Consistency, concurrent multi-part uploads can create windows where LIST is incomplete.
- **Manifest approach requires writer cooperation.** If you don't own the writer, negotiate a contract (manifest file, `_SUCCESS` marker, or metadata DB entry) before building the reader.
- **Delta Lake eliminates this class of problem entirely.** If your org uses Delta, frame the answer around Delta's transaction log, not workarounds.
- **S3 LIST costs money.** `$0.005` per 1,000 requests. A directory with 10M files costs **$50 just to list once**. Repeated runs of a pipeline multiply this. Manifest-based ingestion also saves cost.
- **`pathGlobFilter` still triggers a LIST.** Filtering with glob patterns does not skip the LIST operation; it just filters results afterward.
- **Avoid wildcard paths on huge directories.** `spark.read.parquet("s3://bucket/year=2024/month=*/day=*/")` will LIST every matching prefix — slow and expensive.
- **ADLS Gen2 and GCS behave differently.** ADLS Gen2 with HNS enabled is closer to POSIX and has less listing inconsistency. GCS also has stronger consistency than classic S3. Acknowledge this nuance in interviews.

---

## 7. Interview One-Liner

> "S3 is an eventually consistent key-value store, not a filesystem — Spark's S3 LIST at job start can miss in-flight files, so production pipelines use manifest files or Delta Lake's transaction log to eliminate directory listing entirely."
