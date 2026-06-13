<!-- PySpark-patterns: Schema and Types -->

# Schema and Types

## Schema Inference vs Explicit Schema

### Schema Inference (avoid in production)

```python
# Inference reads a sample of the data, guesses types
df = spark.read.csv("/path/to/data.csv", header=True, inferSchema=True)
df = spark.read.json("/path/to/data.json")
```

**Problems with inference:**
1. **Extra job:** Spark reads the data twice — once to infer schema, once to process
2. **Wrong types:** integers inferred as LongType, mixed columns inferred as StringType
3. **Inconsistent across runs:** if sample changes, inferred schema changes
4. **Slow on large files:** schema inference reads all files (or a sample from each)

### Explicit Schema (use in production)

```python
from pyspark.sql.types import (
    StructType, StructField,
    StringType, IntegerType, LongType, DoubleType, FloatType,
    BooleanType, DateType, TimestampType, DecimalType,
    ArrayType, MapType
)

schema = StructType([
    StructField("id",         LongType(),    nullable=False),
    StructField("name",       StringType(),  nullable=True),
    StructField("amount",     DoubleType(),  nullable=True),
    StructField("order_date", DateType(),    nullable=True),
    StructField("is_active",  BooleanType(), nullable=True),
    StructField("tags",       ArrayType(StringType()), nullable=True)
])

df = spark.read.schema(schema).csv("/path/to/data.csv", header=True)
```

---

## Type Reference

| PySpark Type | SQL Equivalent | Notes |
|-------------|---------------|-------|
| `ByteType()` | TINYINT | 8-bit signed (-128 to 127) |
| `ShortType()` | SMALLINT | 16-bit signed |
| `IntegerType()` | INT | 32-bit signed |
| `LongType()` | BIGINT | 64-bit signed (use for IDs) |
| `FloatType()` | FLOAT | 32-bit IEEE 754 (imprecise) |
| `DoubleType()` | DOUBLE | 64-bit IEEE 754 |
| `DecimalType(p, s)` | DECIMAL(p,s) | Exact numeric; use for money |
| `StringType()` | STRING/VARCHAR | Variable length |
| `BooleanType()` | BOOLEAN | True/False/NULL |
| `DateType()` | DATE | No time component |
| `TimestampType()` | TIMESTAMP | With timezone offset |
| `BinaryType()` | BINARY | Byte array |

---

## F.cast() — Safe Type Casting

```python
from pyspark.sql import functions as F

# Cast returns NULL on failure — no exception
df.withColumn("amount", F.col("amount_str").cast("double"))
df.withColumn("date", F.col("date_str").cast("date"))
df.withColumn("id", F.col("id_str").cast(LongType()))

# Common cast shorthand strings
# "string", "int", "long", "double", "float", "boolean", "date", "timestamp"
```

When a value can't be cast (e.g., casting "abc" to int), the result is NULL.
This is silent — check for unexpected NULLs after casting.

```python
# Audit failed casts
df = df.withColumn("amount", F.col("amount_str").cast("double"))
failed = df.filter(F.col("amount").isNull() & F.col("amount_str").isNotNull())
print(f"Cast failures: {failed.count()}")
```

### F.try_cast() (Spark 3.4+)

```python
# Explicit "try" cast — same behavior as cast() but semantically clearer
df.withColumn("amount", F.try_cast(F.col("amount_str"), DoubleType()))
```

---

## Inspecting Schema

```python
# Print human-readable schema
df.printSchema()

# Get list of (column_name, type_string) tuples
df.dtypes

# Get StructType object
df.schema

# Check a specific column type
df.schema["amount"].dataType   # returns DoubleType() or similar
```

---

## Schema Evolution

### Adding Columns — Safe

Adding columns is backward compatible. Existing readers get NULL for new columns.

```python
df.write.format("delta").mode("append").option("mergeSchema", "true").save(path)
```

### Changing Types — Dangerous

Changing a column from `int` to `string` or `double` to `decimal` can break downstream.

```python
# Schema enforcement (Delta default): rejects writes with incompatible schema
# Schema evolution (opt-in): merges schemas
spark.conf.set("spark.databricks.delta.schema.autoMerge.enabled", "true")
# or per-write:
df.write.format("delta").mode("append").option("mergeSchema", "true").save(path)
```

### Renaming Columns — Breaks Everything

Column renames are not backward compatible. All downstream queries that reference
the old name break.

---

## mergeSchema — Parquet and Delta

```python
# Parquet: combine files with different schemas
df = spark.read.option("mergeSchema", "true").parquet("/data/mixed_schema/")

# Delta: allow schema evolution on write
df.write.format("delta") \
    .mode("append") \
    .option("mergeSchema", "true") \
    .save("/data/delta_table/")
```

`mergeSchema` adds new columns. It does NOT handle type conflicts —
if the same column exists with different types in different files, Spark either
errors or picks one (behavior depends on the format and conflict).

---

## Creating DataFrames with Explicit Types

```python
from pyspark.sql.types import StructType, StructField, StringType, IntegerType

schema = StructType([
    StructField("name", StringType(), True),
    StructField("age",  IntegerType(), True)
])

df = spark.createDataFrame([
    ("Alice", 30),
    ("Bob", None)
], schema=schema)
```

Without schema, Spark infers types from the Python objects:
- Python `int` -> `LongType`
- Python `float` -> `DoubleType`
- Python `str` -> `StringType`
- Python `None` -> `NullType` (can cause issues)

---

## Type Coercion in Operations

Spark automatically promotes types in mixed-type arithmetic:

```python
# int + double -> double
df.withColumn("result", F.col("int_col") + F.col("double_col"))

# string + int -> error (no implicit cast from string to numeric)
df.withColumn("result", F.col("string_col") + F.col("int_col"))  # AnalysisException
```

For string-to-numeric operations, cast explicitly:
```python
df.withColumn("result", F.col("string_col").cast("double") + F.col("int_col"))
```
