# 10 — Metadata/Catalog Failures: Missing Partitions, Stale Catalogs, Path Mismatches

---

## 1. The Problem

Two distinct failure modes, same root cause:

**Mode A — Invisible partitions:** Spark writes new files to the partition path on S3/HDFS, but the Hive Metastore / Glue Catalog / Unity Catalog has no record of the partition. `SELECT COUNT(*) FROM table` returns 0. Files exist, data is there — the catalog just doesn't know.

**Mode B — Ghost partitions:** Catalog contains metadata for partitions whose physical files were deleted (retention job, manual cleanup). Queries throw `FileNotFoundException`. The catalog is a lie.

Both cause silent correctness failures that are hard to distinguish from "no data was loaded."

---

## 2. Interview Trigger Phrases

- "partition not found"
- "MSCK REPAIR TABLE"
- "Hive metastore stale"
- "Glue crawler"
- "table shows 0 rows but files exist"
- "path mismatch"
- "catalog sync"
- "missing partition metadata"
- "Unity Catalog partition discovery"
- "FileNotFoundException on valid partition"

---

## 3. Detection Signals

| Signal | How to Detect |
|--------|---------------|
| `SELECT COUNT(*)` returns 0 after successful write | Run `SHOW PARTITIONS table` — compare to actual S3 prefixes |
| `SHOW PARTITIONS table` missing recent dates | `aws s3 ls s3://bucket/table/` vs. `SHOW PARTITIONS` output |
| `FileNotFoundException` on query | Catalog entry exists; `aws s3 ls` for that prefix returns nothing |
| Catalog partition path doesn't match actual S3 path | `DESCRIBE FORMATTED table PARTITION (...)` — check `Location` field |
| Glue Crawler hasn't run since last write | Check Glue Crawler last-run timestamp in AWS Console |

---

## 4. Root Cause

In Hive-compatible catalogs, metadata and data are two separate systems:

```
Filesystem (S3/HDFS)        Metastore (Hive/Glue/Unity)
─────────────────────        ─────────────────────────────
table/year=2024/month=12/   ← partition entry may or may not exist here
  part-00000.parquet
```

Writing files directly to the partition directory (via `df.write.parquet(path)` without using Spark SQL DDL) creates the physical files but does **not** register the partition in the metastore. The catalog and the filesystem diverge.

This is by design — Hive's architecture predates cloud object storage. Modern table formats (Delta Lake, Iceberg) solve this by embedding metadata in the data layer itself, eliminating the external metastore dependency for partition tracking.

---

## 5. Fix Pattern

### Fix 1 — MSCK REPAIR TABLE (Hive / Glue / Athena)

```sql
-- Scans HDFS/S3 for partition directories not registered in the metastore
-- Adds missing partitions; does NOT remove ghost partitions
MSCK REPAIR TABLE schema.table_name;
```

Boto3 equivalent for Glue:
```python
import boto3

glue = boto3.client("glue", region_name="us-east-1")

# Option A: trigger a Glue Crawler (async, may take minutes)
glue.start_crawler(Name="my-table-crawler")

# Option B: direct partition registration (faster, targeted)
glue.batch_create_partition(
    DatabaseName="schema",
    TableName="table_name",
    PartitionInputList=[
        {
            "Values": ["2024", "12", "01"],
            "StorageDescriptor": {
                "Location": "s3://bucket/table/year=2024/month=12/day=01/",
                ...
            }
        }
    ]
)
```

### Fix 2 — ALTER TABLE ADD PARTITION (targeted, preferred over MSCK for known paths)

```sql
-- Faster than MSCK because it targets a specific partition, not the entire table
ALTER TABLE schema.table_name ADD IF NOT EXISTS
  PARTITION (year='2024', month='12', day='01')
  LOCATION 's3://bucket/table/year=2024/month=12/day=01/';
```

Call this at the end of every ingestion job for the partitions just written:
```python
partition_spec = f"year='{year}', month='{month}', day='{day}'"
partition_path = f"s3://bucket/table/year={year}/month={month}/day={day}/"

spark.sql(f"""
    ALTER TABLE schema.table_name ADD IF NOT EXISTS
    PARTITION ({partition_spec})
    LOCATION '{partition_path}'
""")
```

### Fix 3 — Delta Lake / Iceberg (avoids the problem entirely)

```python
# Delta Lake — metadata is in the _delta_log/ transaction log, not the metastore
df.write.format("delta").mode("append").partitionBy("year", "month", "day") \
  .save("s3://bucket/delta/table_name/")

# Iceberg — metadata in metadata/ JSON files, no metastore sync needed
df.write.format("iceberg").mode("append").partitionBy("year", "month", "day") \
  .save("s3://bucket/iceberg/table_name/")
```

### Fix 4 — End-of-Job Repair Hook

```python
def register_partitions(spark, table: str, partitions: list[dict]):
    """Run at end of every ingestion job to ensure catalog is current."""
    for p in partitions:
        spec = ", ".join(f"{k}='{v}'" for k, v in p.items())
        path = "/".join(f"{k}={v}" for k, v in p.items())
        spark.sql(f"""
            ALTER TABLE {table} ADD IF NOT EXISTS
            PARTITION ({spec})
            LOCATION 's3://bucket/{table}/{path}/'
        """)
```

### Fix 5 — Ghost Partition Cleanup

```sql
-- Remove catalog entries for partitions whose files no longer exist
ALTER TABLE schema.table_name
  DROP IF EXISTS PARTITION (year='2023', month='01');
```

### Fix 6 — Enforce Hive-Compatible Partition Paths

Path mismatch: catalog expects `year=YYYY/month=MM` but files written as `YYYY/MM`.

```python
# WRONG: creates non-Hive-compatible paths (YYYY/MM/)
df.write.parquet(f"s3://bucket/table/{year}/{month}/")

# RIGHT: partitionBy generates year=YYYY/month=MM/ automatically
df.write.mode("append").partitionBy("year", "month", "day") \
  .parquet("s3://bucket/table/")
```

### spark-submit Config Delta

```bash
# Enable automatic partition refresh for catalog-managed tables
--conf spark.sql.hive.manageFilesourcePartitions=true

# Ensure Hive metastore is used (not in-memory Derby default)
--conf spark.sql.catalogImplementation=hive
--conf spark.hadoop.hive.metastore.uris=thrift://metastore-host:9083
```

---

## 6. Gotchas

- **MSCK REPAIR is O(n files).** On tables with millions of small files, MSCK can run for hours. Always prefer targeted `ALTER TABLE ADD PARTITION` for known partitions at job end.
- **MSCK does not remove ghost partitions.** For stale/deleted partition cleanup, use `DROP PARTITION` explicitly or a separate reconciliation job.
- **Delta Lake and Iceberg eliminate this problem.** The metastore sync issue is a Hive-era artifact. If you're designing a new system, use a transactional table format. Migrate legacy Hive tables when possible.
- **Unity Catalog (Databricks) auto-discovers partitions** — no MSCK needed for Delta tables registered in Unity Catalog.
- **Glue Crawlers are slow and non-deterministic.** A crawler that runs every hour still means up to 60 minutes of stale metadata. For SLA-critical pipelines, use direct `batch_create_partition` via boto3 at job end instead.
- **`IF NOT EXISTS` on ALTER TABLE is critical.** Without it, re-running the repair step on an existing partition raises an error and halts the job.

---

## 7. Interview One-Liner

> "The Hive metastore and the filesystem are two independent systems that drift when you write files directly to S3 — the fix is either `ALTER TABLE ADD PARTITION` at job end for targeted registration, `MSCK REPAIR TABLE` for bulk discovery, or migrating to Delta Lake / Iceberg which embed partition metadata in the data layer and eliminate the external catalog sync problem entirely."
