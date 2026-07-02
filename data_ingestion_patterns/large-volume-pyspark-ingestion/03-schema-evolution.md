# Edge Case 03: Schema Evolution and Schema Drift

**Cluster baseline:** Driver 8c/32 GB heap + 4 GB overhead | Executor 5c/36 GB heap + 4 GB overhead  
**Throughput coefficient:** 25 MB/s per core | **Safe SLA window:** 2/3 of business SLA  
**Key configs:** `spark.sql.shuffle.partitions = total_cores × 5` | `mergeSchema=false` | AQE=true

---

## 1. The Problem

A new column appears overnight in upstream Parquet files — added by the source team without notice. The existing pipeline either:

- **Fails hard** with `AnalysisException: cannot resolve column 'new_col' given input columns [...]`
- **Silently drops** the new column because Spark used the first file's schema to infer the dataset shape
- **Slows catastrophically** if `mergeSchema=true` is set, because Spark opens every file's footer to reconcile schemas across hundreds of thousands of files

Either outcome is production-breaking. Silent data loss is worse than the crash.

---

## 2. Interview Trigger Phrases

Listen for any of these in the question:

- "schema changed overnight"
- "new column appeared in source files"
- "source team added a field without telling us"
- "schema evolution" / "schema drift"
- "backward compatibility" / "forward compatibility"
- "AnalysisException on read"
- "some columns are missing after the load"

---

## 3. Detection Signals

| Signal | Where to look |
|---|---|
| `AnalysisException: cannot resolve column X` | Driver logs, job failure email |
| Column count in new files != expected count | Pre-read schema diff check (see Fix Pattern) |
| Job runs 3–5× slower than baseline | Spark UI — Tasks tab shows driver reading footers serially |
| Missing column in downstream query results | Data quality check / row-level reconciliation |
| `mergeSchema` task spike visible on driver | Spark UI — Jobs tab, one long serial "schema merge" stage |

**Spark UI tell:** If `mergeSchema=true` is on and file count is large, you will see a single-task stage with 100% driver utilization and near-zero executor utilization. That is the driver walking every footer.

---

## 4. Root Cause

Parquet files carry their own schema in the **file footer** (not in a separate catalog). When Spark reads a directory:

1. It opens the **first file** it encounters and reads that footer as the dataset schema.
2. All subsequent files are read against that inferred schema — new columns in later files are silently ignored.
3. If `mergeSchema=true`, Spark instead opens **every file's footer** on the driver before dispatching any executor tasks. On 100k+ files this is a serial, single-threaded scan that can take hours.

The fundamental mismatch: Parquet schema-per-file was designed for single-writer scenarios. Multi-writer pipelines with independent schema versions break this assumption.

---

## 5. Fix Pattern

### Option A (Preferred): Explicit schema + PERMISSIVE mode

Define the expected schema in code. Spark reads only what you declare; extra columns in the source are silently discarded (which is intentional — you control the contract).

```python
from pyspark.sql.types import StructType, StructField, StringType, LongType, TimestampType

EXPECTED_SCHEMA = StructType([
    StructField("id",         LongType(),      nullable=False),
    StructField("event_type", StringType(),    nullable=True),
    StructField("event_ts",   TimestampType(), nullable=True),
    StructField("payload",    StringType(),    nullable=True),
])

df = (
    spark.read
    .schema(EXPECTED_SCHEMA)
    .option("mode", "PERMISSIVE")       # rows that don't fit go to _corrupt_record
    .option("columnNameOfCorruptRecord", "_corrupt_record")
    .parquet("s3://bucket/events/date=2026-07-01/")
)

# Quarantine corrupt/unexpected rows for manual inspection
corrupt_df = df.filter(df["_corrupt_record"].isNotNull())
clean_df   = df.filter(df["_corrupt_record"].isNull())

corrupt_count = corrupt_df.count()
if corrupt_count > 0:
    corrupt_df.write.mode("append").parquet("s3://bucket/quarantine/")
    raise ValueError(f"Schema mismatch: {corrupt_count} rows quarantined. Inspect s3://bucket/quarantine/")
```

### Option B: Fail-fast schema drift detection before bulk read

Read a single representative file, compare schema to expected, fail with a human-readable error before touching the full dataset.

```python
from pyspark.sql.functions import col
import difflib

def detect_schema_drift(spark, sample_path: str, expected_schema: StructType) -> None:
    """Read one file's schema and compare to expected. Raise on mismatch."""
    actual_schema = spark.read.parquet(sample_path).schema

    expected_fields = {f.name: str(f.dataType) for f in expected_schema.fields}
    actual_fields   = {f.name: str(f.dataType) for f in actual_schema.fields}

    added   = set(actual_fields) - set(expected_fields)
    removed = set(expected_fields) - set(actual_fields)
    type_changed = {
        k for k in expected_fields & actual_fields
        if expected_fields[k] != actual_fields[k]
    }

    if added or removed or type_changed:
        msg = (
            f"Schema drift detected in {sample_path}\n"
            f"  Added columns:        {added}\n"
            f"  Removed columns:      {removed}\n"
            f"  Type-changed columns: {type_changed}\n"
            "Update EXPECTED_SCHEMA or contact the source team."
        )
        raise RuntimeError(msg)

# Usage
detect_schema_drift(spark, "s3://bucket/events/date=2026-07-01/part-00000.parquet", EXPECTED_SCHEMA)

# Only reach here if schema matches
df = spark.read.schema(EXPECTED_SCHEMA).parquet("s3://bucket/events/date=2026-07-01/")
```

### Option C: Delta Lake auto schema evolution (use sparingly)

Safe only when the source team has an additive-only schema contract and new columns should flow through automatically.

```python
# On WRITE — allow new columns to be added to the Delta table automatically
df.write \
  .format("delta") \
  .mode("append") \
  .option("mergeSchema", "true") \   # auto-adds new columns to Delta schema
  .save("s3://bucket/delta/events/")

# On READ — Delta tracks schema history; reads always use the latest table schema
df = spark.read.format("delta").load("s3://bucket/delta/events/")
```

**When this is safe:** source team guarantees additive-only changes (new nullable columns only). Never use for type changes or column removals — Delta will reject those even with `mergeSchema=true`.

### spark-submit config delta

```bash
# Keep mergeSchema=false at the framework level — schema reconciliation is app-layer logic
spark-submit \
  --conf spark.sql.parquet.mergeSchema=false \         # default false; state explicitly
  --conf spark.sql.shuffle.partitions=200 \            # total_cores × 5 for baseline cluster
  --conf spark.sql.adaptive.enabled=true \
  your_job.py
```

No executor/driver sizing change needed for this fix. The schema validation step is driver-only and cheap.

---

## 6. Gotchas

1. **`mergeSchema=true` on 100k+ files is catastrophic.** The driver opens every footer serially. A 10-minute job becomes a 4-hour job. Always benchmark on representative file counts before enabling.

2. **Nested struct drift is the hardest to detect.** If `payload` is a `StructType` and a nested field changes, the top-level column name is the same — your field-name diff will miss it. Recursively compare nested schemas.

3. **Type widening is silent.** Spark will silently widen `IntegerType → LongType` on read. This sounds safe but can break downstream joins on typed columns or introduce subtle aggregate overflows. Your diff check must compare `dataType` strings, not just field names.

4. **`StringType → IntegerType` will fail at read time**, not at schema check time — it fails per-row when Parquet tries to deserialize. PERMISSIVE mode catches this but FAILFAST will kill the job mid-read.

5. **Column rename looks like add + remove.** A renamed column will appear as one removed column and one added column in your drift check. There is no rename event in Parquet metadata — treat this as a breaking change requiring a pipeline update.

6. **The "first file" problem with parallelism.** Spark's file listing order is non-deterministic on S3 (eventual consistency ordering). The "first file" whose schema is used can vary between runs, making silent schema drift intermittent and hard to reproduce.

---

## 7. Interview One-Liner

> "I never rely on schema inference in production — I pin an explicit schema in code, run a fail-fast drift check against a single sample file before touching the full dataset, and keep `mergeSchema=false` at the framework level so the driver never walks thousands of footers."
