<!-- PySpark-patterns: Delta Lake Patterns -->

# Delta Lake Patterns

## What Delta Lake Adds to Parquet

Delta Lake = Parquet files + a transaction log (`_delta_log/` directory).

| Feature | Parquet | Delta Lake |
|---------|---------|------------|
| ACID transactions | No | Yes |
| Schema enforcement | No | Yes |
| Time travel | No | Yes |
| MERGE/UPSERT | No | Yes |
| Audit history | No | Yes |
| Streaming source/sink | Limited | Yes |
| Compaction (OPTIMIZE) | Manual | Built-in |

---

## Creating Delta Tables

```python
# Option 1: DataFrame write
df.write.format("delta").mode("overwrite").save("/data/delta/customers/")

# Option 2: SQL CREATE TABLE
spark.sql("""
    CREATE TABLE customers (
        id       BIGINT,
        name     STRING,
        email    STRING,
        region   STRING,
        updated_at TIMESTAMP
    )
    USING DELTA
    LOCATION '/data/delta/customers/'
""")

# Option 3: Databricks managed table (no LOCATION)
spark.sql("""
    CREATE TABLE customers USING DELTA AS
    SELECT * FROM parquet.`/data/raw/customers/`
""")
```

---

## Reading Delta Tables

```python
# Read current version
df = spark.read.format("delta").load("/data/delta/customers/")

# SQL
df = spark.table("customers")
```

---

## MERGE INTO (Upsert)

MERGE matches rows between source and target. The most important Delta operation.

```python
from delta.tables import DeltaTable

target = DeltaTable.forPath(spark, "/data/delta/customers/")
source = updates_df   # the new/changed data

target.alias("t").merge(
    source.alias("s"),
    "t.id = s.id"     # match condition
).whenMatchedUpdate(set={
    "name":       "s.name",
    "email":      "s.email",
    "updated_at": "s.updated_at"
}).whenNotMatchedInsert(values={
    "id":         "s.id",
    "name":       "s.name",
    "email":      "s.email",
    "region":     "s.region",
    "updated_at": "s.updated_at"
}).execute()
```

### MERGE with Delete

```python
target.alias("t").merge(
    source.alias("s"),
    "t.id = s.id"
).whenMatchedDelete(
    condition="s.is_deleted = true"
).whenMatchedUpdate(set={
    "name": "s.name"
}).whenNotMatchedInsert(values={
    "id": "s.id", "name": "s.name"
}).execute()
```

---

## Time Travel

Delta stores previous versions of the table. Access them by version number or timestamp.

```python
# By version number
df = spark.read.format("delta") \
    .option("versionAsOf", 5) \
    .load("/data/delta/customers/")

# By timestamp
df = spark.read.format("delta") \
    .option("timestampAsOf", "2024-01-15 00:00:00") \
    .load("/data/delta/customers/")

# Show full history
from delta.tables import DeltaTable
dt = DeltaTable.forPath(spark, "/data/delta/customers/")
dt.history().show(truncate=False)

# SQL equivalent
spark.sql("SELECT * FROM customers VERSION AS OF 5")
spark.sql("SELECT * FROM customers TIMESTAMP AS OF '2024-01-15'")
```

---

## Schema Enforcement vs Schema Evolution

### Schema Enforcement (default)

Delta rejects writes that don't match the table schema.

```python
# This fails if source_df has a column not in the table, or different type
df.write.format("delta").mode("append").save("/data/delta/customers/")
# AnalysisException: A schema mismatch detected when writing to the Delta table
```

### Schema Evolution (opt-in)

```python
# Allow new columns to be added on write
df.write.format("delta") \
    .mode("append") \
    .option("mergeSchema", "true") \
    .save("/data/delta/customers/")

# Or set globally
spark.conf.set("spark.databricks.delta.schema.autoMerge.enabled", "true")
```

---

## OPTIMIZE — Compact Small Files

```python
from delta.tables import DeltaTable

dt = DeltaTable.forPath(spark, "/data/delta/customers/")

# Compact small files
dt.optimize().executeCompaction()

# Compact + Z-order (co-locate related data on disk)
dt.optimize().executeZOrderBy("user_id", "date")
```

**Z-ordering** sorts and co-locates rows by the specified columns within each
Parquet file's row groups. Queries that filter by `user_id` and/or `date` read
fewer row groups — better predicate pushdown.

Z-order works best when:
- You filter frequently by 1–3 high-cardinality columns
- The table is large enough for the effect to matter (> 10 GB)

---

## VACUUM — Remove Old Files

```python
from delta.tables import DeltaTable

dt = DeltaTable.forPath(spark, "/data/delta/customers/")

# Remove files older than 7 days (default retention)
dt.vacuum()

# Custom retention period (must be >= 7 days to preserve time travel)
dt.vacuum(168)  # 168 hours = 7 days

# DANGEROUS: vacuum below 7 days breaks time travel and concurrent reads
# Only do this if you are sure no readers use time travel
spark.conf.set("spark.databricks.delta.retentionDurationCheck.enabled", "false")
dt.vacuum(0)    # remove ALL old files — no time travel possible after this
```

---

## Delta as Streaming Source and Sink

```python
# Streaming source: read new Delta changes as they arrive
stream = spark.readStream.format("delta").load("/data/delta/events/")

# Streaming sink: write stream results to Delta
stream.writeStream \
    .format("delta") \
    .outputMode("append") \
    .option("checkpointLocation", "/checkpoints/events/") \
    .start("/data/delta/processed_events/")
```

---

## Delta Table Properties

```python
# Set table properties
spark.sql("""
    ALTER TABLE customers SET TBLPROPERTIES (
        'delta.autoOptimize.optimizeWrite' = 'true',
        'delta.autoOptimize.autoCompact' = 'true',
        'delta.logRetentionDuration' = 'interval 30 days',
        'delta.deletedFileRetentionDuration' = 'interval 7 days'
    )
""")
```

`optimizeWrite`: Databricks/Unity Catalog auto-coalesces small write partitions before writing.
`autoCompact`: Databricks auto-runs OPTIMIZE after writes (background).
