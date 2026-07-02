# 09 — Data Quality Validation, Quarantine Paths, and Row-Count Reconciliation

---

## 1. The Problem

Bad rows — nulls in NOT NULL columns, out-of-range values, type mismatches — silently load into the data warehouse. Dashboards display wrong numbers. Downstream ML models train on corrupted data. Root cause is discovered three weeks later after a business escalation.

Parquet is schema-aware at the type level (int vs string) but enforces no business-rule constraints. Spark will happily write a `customer_id = NULL` or `amount = -9999999` without complaint.

---

## 2. Interview Trigger Phrases

- "null violations"
- "bad rows in production"
- "data quality checks"
- "quarantine path"
- "row count mismatch"
- "reconciliation"
- "DQ rules"
- "bad data in production"
- "data contract"
- "silent data corruption"

---

## 3. Detection Signals

| Signal | Where to Look |
|--------|---------------|
| Post-load row count != pre-load count | Compare `source.count()` vs `target.count()` after job |
| Null rate > threshold in critical columns | Profile with `df.select([F.count(F.when(F.col(c).isNull(), c)).alias(c) for c in cols])` |
| Distribution shift in numeric columns | Min/max/mean drift across runs |
| Downstream query returns NULLs unexpectedly | Application logs, BI tool alerts |
| Row count in catalog metadata != physical file count | Hive/Glue partition row stats |

---

## 4. Root Cause

No validation layer exists between `read` and `write`. The pipeline is:

```
Source → Spark Read → [NO VALIDATION] → Spark Write → Target
```

Parquet enforces structural schema only (column names and types). It has no concept of:
- Referential integrity (`customer_id` must exist in `customers`)
- Range constraints (`amount BETWEEN 0 AND 1_000_000`)
- Temporal validity (`event_date >= '2020-01-01'`)
- Business keys (`order_id IS NOT NULL`)

The result: every bad row that enters the pipeline exits into the target table.

---

## 5. Fix Pattern

### Layer 1 — Row Count Reconciliation

```python
source_count = spark.read.parquet(source_path).count()
target_count = spark.read.parquet(target_path).count()

assert target_count >= source_count * 0.98, (
    f"Row count drop: {target_count} written vs {source_count} source "
    f"({(source_count - target_count) / source_count:.1%} loss)"
)
```

### Layer 2 — Column-Level DQ Rules with Quarantine

```python
from pyspark.sql import functions as F
from functools import reduce

dq_rules = [
    F.col("customer_id").isNotNull(),
    F.col("amount").between(0, 1_000_000),
    F.col("event_date") >= "2020-01-01",
]

# Tag each row — single pass
combined_rule = reduce(lambda a, b: a & b, dq_rules)
df = df.withColumn("_dq_pass", combined_rule)

good_df = df.filter("_dq_pass").drop("_dq_pass")
bad_df  = df.filter(~F.col("_dq_pass")).drop("_dq_pass")

# Write good rows to target
good_df.write.mode("append").parquet(target_path)

# Write bad rows to quarantine with partition for investigation
bad_df.write.mode("append").partitionBy("year", "month", "day") \
      .parquet(quarantine_path)

# Alert if bad rate exceeds threshold
total = df.count()
bad_count = bad_df.count()
bad_rate = bad_count / total if total > 0 else 0.0

if bad_rate > 0.01:  # 1% threshold
    raise Exception(
        f"DQ failure: {bad_rate:.1%} of rows failed validation "
        f"({bad_count:,} of {total:,} rows quarantined)"
    )
```

**Quarantine path structure:**
```
s3://bucket/quarantine/
  table_name/
    year=YYYY/month=MM/day=DD/
      part-00000-abc123.parquet
```

### Layer 3 — Schema Contract Enforcement

```python
from pyspark.sql.types import StructType

expected_schema: StructType = ...  # defined in a schema registry or config

actual_fields   = set((f.name, str(f.dataType)) for f in df.schema.fields)
expected_fields = set((f.name, str(f.dataType)) for f in expected_schema.fields)

schema_drift = expected_fields - actual_fields
if schema_drift:
    raise ValueError(f"Schema mismatch — missing or changed fields: {schema_drift}")
```

### Layer 4 — Great Expectations / dbt Integration

For enterprise pipelines, integrate an established DQ framework:
- **Great Expectations**: `ge_df = ge.from_pandas(df.toPandas()); ge_df.expect_column_values_to_not_be_null("customer_id")`
- **dbt tests**: `not_null`, `accepted_values`, `relationships` tests run post-load
- **Soda Core**: connects directly to Spark SQL and runs DQ checks without pulling data to driver

### spark-submit Config Delta

```bash
# No Spark config changes required — DQ is application-layer logic.
# Optional: enable Arrow for faster Pandas-based DQ rule evaluation on samples
--conf spark.sql.execution.arrow.pyspark.enabled=true
```

---

## 6. Gotchas

- **Never silently drop bad rows.** Always quarantine AND alert. Silent drops make data loss invisible.
- **Quarantine path must be monitored.** Without monitoring, it fills quietly. Add a quarantine row-count metric to your observability dashboard.
- **`count()` is a full-scan action.** Calling it multiple times adds latency. For very large datasets, run DQ checks on a 10% sample first; only trigger a full scan if sampling detects failures.
- **`reduce` on rules evaluates all predicates.** A NULL in a non-nullable column will short-circuit `&` correctly in Spark — no risk of NPE in the boolean evaluation.
- **The 1% threshold is a starting point.** For financial tables, 0.001% may be the right threshold. For event logs, 5% might be acceptable. Calibrate per table criticality.
- **Quarantine is not the same as rejection.** Quarantined rows may be fixable (upstream data team corrects the source). Design reprocessing workflows alongside quarantine writes.

---

## 7. Interview One-Liner

> "We add a single-pass DQ tagging column that forks the DataFrame into `good_df` (written to target) and `bad_df` (written to a dated quarantine path), then raise an exception if the bad-row rate exceeds a configurable threshold — because Spark's schema enforcement is type-level only, not business-rule level."
