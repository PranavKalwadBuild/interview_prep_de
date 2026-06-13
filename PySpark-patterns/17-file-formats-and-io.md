<!-- PySpark-patterns: File Formats and IO -->

# File Formats and IO

## Format Comparison

| Format | Layout | Compression | Schema | Predicate Pushdown | Best For |
|--------|--------|-------------|--------|-------------------|----------|
| Parquet | Columnar | Yes (Snappy/ZSTD) | In file | Yes | Analytics, data lake standard |
| ORC | Columnar | Yes (ZLIB/Snappy) | In file | Yes | Hive/Hudi, ACID |
| Delta | Columnar (Parquet+log) | Yes | Enforced | Yes + Z-order | Lakehouse, ACID, time travel |
| Avro | Row-based | Yes | In file | No | Streaming, schema evolution |
| JSON | Row-based | Optional | Inferred | No | Flexible ingestion, debugging |
| CSV | Row-based | No | None | No | Legacy, human-readable exchange |

---

## Parquet

```python
# Read
df = spark.read.parquet("/data/sales/")
df = spark.read.schema(my_schema).parquet("/data/sales/")  # explicit schema
df = spark.read \
    .option("mergeSchema", "true") \
    .parquet("/data/sales/")   # merge schemas from multiple files

# Write
df.write.mode("overwrite").parquet("/output/sales/")
df.write.mode("append").partitionBy("year", "month").parquet("/output/sales/")

# Compression (default: snappy)
df.write.option("compression", "zstd").parquet("/output/")  # better ratio than snappy
df.write.option("compression", "none").parquet("/output/")  # for fast reads, large files
```

**Parquet strengths:**
- Column pruning: only columns you select are read from disk
- Predicate pushdown: filter values skip row groups
- Good compression with columnar storage (similar values in same column compress well)
- Schema stored in file footer — no separate schema registry needed

---

## ORC

```python
df = spark.read.orc("/data/hive_table/")
df.write.mode("overwrite").orc("/output/")
```

ORC is common in Hive and HBase ecosystems. Slightly better compression than Parquet
for some workloads. Supports ACID transactions in Hive.
In pure Spark workflows, Parquet and Delta are preferred.

---

## JSON

```python
# Single-line JSON (one JSON object per line — JSONL format)
df = spark.read.json("/data/events/")

# Multi-line JSON (one JSON object spanning multiple lines)
df = spark.read \
    .option("multiLine", "true") \
    .json("/data/events.json")

# Explicit schema (recommended)
df = spark.read.schema(my_schema).json("/data/events/")

# Write
df.write.mode("overwrite").json("/output/")
```

**JSON traps:**
- Schema inference reads ALL data to determine types (slow, uses a full pass)
- Mixed types in a field: `"amount": "100"` vs `"amount": 100` → inferred as StringType
- Nested objects are inferred as StructType — can change between files if keys vary
- `multiLine=true` can't be split across workers — reads each file on one core (slow for large files)

---

## CSV

```python
# Read
df = spark.read \
    .option("header", "true") \
    .option("inferSchema", "true") \
    .csv("/data/export.csv")

# With explicit schema (recommended for production)
df = spark.read \
    .schema(my_schema) \
    .option("header", "true") \
    .option("quote", '"') \
    .option("escape", '"') \
    .option("nullValue", "N/A") \
    .option("dateFormat", "yyyy-MM-dd") \
    .option("timestampFormat", "yyyy-MM-dd HH:mm:ss") \
    .csv("/data/export.csv")

# Write
df.write \
    .mode("overwrite") \
    .option("header", "true") \
    .option("quote", '"') \
    .csv("/output/export/")
```

**CSV traps:**
- Quoting: commas inside quoted fields confuse parsers if `quote` option is wrong
- Encoding: non-UTF-8 files (Latin-1, Windows-1252) fail silently or corrupt data
- No schema: all columns are strings unless `inferSchema=true` or explicit schema
- `inferSchema` is slow (two passes over the data)

---

## Avro

```python
# Requires spark-avro package
df = spark.read.format("avro").load("/data/kafka_topic/")
df.write.format("avro").mode("append").save("/output/")
```

Avro stores the schema in the file — good for Kafka/schema registry workflows.
Row-based, so not ideal for analytical queries that access few columns.

---

## Delta Lake

```python
# Read
df = spark.read.format("delta").load("/data/delta_table/")

# Write
df.write.format("delta").mode("overwrite").save("/data/delta_table/")
df.write.format("delta").mode("append").save("/data/delta_table/")
```

See `18-delta-lake-patterns.md` for full Delta Lake coverage.

---

## Read Options Reference

```python
spark.read \
    .option("header", "true")              # CSV: first row is header
    .option("inferSchema", "true")         # infer types (slow; use explicit schema)
    .option("multiLine", "true")           # JSON: multi-line JSON objects
    .option("mergeSchema", "true")         # Parquet/Delta: merge schemas
    .option("recursiveFileLookup", "true") # recurse into subdirectories
    .option("pathGlobFilter", "*.parquet") # only read files matching pattern
    .option("modifiedAfter", "2024-01-01T00:00:00") # only files modified after
    .option("encoding", "UTF-8")           # CSV/JSON encoding
    .option("nullValue", "N/A")            # treat this string as NULL
    .option("nanValue", "nan")             # treat this string as NaN
    .option("sep", "|")                    # CSV delimiter (default: ,)
    .option("escape", "\\")               # CSV escape character
    .option("comment", "#")               # skip lines starting with this
    .option("ignoreLeadingWhiteSpace", "true")
    .option("ignoreTrailingWhiteSpace", "true")
```

---

## Write Modes

```python
df.write.mode("overwrite")       # replace existing data
df.write.mode("append")          # add to existing data
df.write.mode("ignore")          # do nothing if data exists
df.write.mode("error")           # error if data exists (default)
df.write.mode("errorifexists")   # same as "error"
```

**overwrite with partitionBy:** by default, overwrites only the partitions present
in the current write. Other partitions are preserved.

```python
# Only overwrites year=2024/month=01 — other partitions untouched
df.filter((F.col("year") == 2024) & (F.col("month") == 1)) \
  .write \
  .mode("overwrite") \
  .partitionBy("year", "month") \
  .parquet("/data/sales/")
```

To overwrite ALL partitions (full table replacement):
```python
spark.conf.set("spark.sql.sources.partitionOverwriteMode", "static")
# or in Databricks:
df.write.option("overwriteSchema", "true").mode("overwrite").format("delta").save(path)
```

---

## Writing a Single File

```python
# coalesce(1) before write — one partition = one file
df.coalesce(1).write.mode("overwrite").csv("/output/result.csv")
# Creates: /output/result.csv/part-00000.csv (still a directory)

# For a true single file, use pandas (only for small data)
df.toPandas().to_csv("/output/result.csv", index=False)
```
