<!-- Part of PySpark-patterns: Silent Errors — Schema and Type Coercion -->

# Silent Errors — Schema and Type Coercion

Spark's schema system is permissive by default. Mismatches between data and schema produce NULLs,
not exceptions. Type widening in UNIONs, positional column reads in Parquet, and integer overflow
are all silent in production unless ANSI mode is enabled (it isn't, by default).

---

### 1. Schema Inference Samples Only the First N Rows

**What it looks like:**
```python
df = spark.read.option("inferSchema", True).csv("s3://bucket/events/*.csv")
df.filter(F.col("user_id") > 1000).show()
```

**What actually happens:**
By default, Spark samples the first 1000 rows to infer the schema of a CSV file. If those
rows all have `"user_id": "12345"` (numeric string), Spark infers `IntegerType`. Row 1001 with
`"user_id": "N/A"` is silently cast to `NULL` with no error or warning. All subsequent rows
with non-numeric user IDs become `NULL`.

**Why it's insidious:**
The sampling heuristic covers 99.9% of rows. The malformed rows are an exception that the
inference window never sees. `df.count()` returns the full row count; only `user_id.isNull()`
reveals the data loss.

**Minimal repro:**
```python
# Create CSV with a non-integer in row 1001
data = [f"{i}" for i in range(1000)] + ["N/A"] + [f"{i}" for i in range(1001, 2000)]
# First 1000 rows → IntegerType inferred
# Row 1001 → silently NULL
```

**How to catch it:**
```python
# After reading, validate for unexpected NULLs
null_pct = df.filter(F.col("user_id").isNull()).count() / df.count()
assert null_pct < 0.001, f"user_id has {null_pct:.1%} NULLs — schema inference failure?"
```
Always define explicit schemas for production pipelines.

**Real-world trigger:**
A marketing events CSV where the first partition has clean numeric IDs but the second partition
(a new data provider) uses alphanumeric IDs. All cross-provider IDs become NULL silently.

---

### 2. `mergeSchema` on Parquet with Renamed Column Creates Doubled Columns

**What it looks like:**
```python
# Week 1: column named "revenue"
df_week1.write.parquet("s3://bucket/sales/week=1")

# Week 2: column renamed to "gross_revenue" in the source schema
df_week2.write.parquet("s3://bucket/sales/week=2")

# Read all weeks with mergeSchema
df_all = spark.read.option("mergeSchema", True).parquet("s3://bucket/sales/")
df_all.agg(F.sum("gross_revenue")).show()
```

**What actually happens:**
`mergeSchema` creates a union of all column names seen across all Parquet files. The result has
*both* `revenue` and `gross_revenue` as separate columns. Week 1 rows have `gross_revenue = NULL`
and `revenue = actual_value`. Week 2 rows have `revenue = NULL` and `gross_revenue = actual_value`.
`sum("gross_revenue")` silently ignores all week 1 data (it's NULL there).

**Why it's insidious:**
No error. `df_all.printSchema()` shows two columns that look like aliases. The SUM result
undercounts by the entire week 1 contribution. This only surfaces when the analyst notices
the weekly trend plot has a suspicious discontinuity.

**How to catch it:**
```python
# Check for column pairs that suggest a rename
cols = df_all.columns
print(f"Total columns: {len(cols)}")  # unexpectedly high → schema drift
# Check null rates per column per partition
df_all.groupBy("week").agg(*[F.sum(F.col(c).isNull().cast("int")).alias(c) for c in cols])
```

**Real-world trigger:**
A finance team renames "revenue" to "net_revenue" and "gross_revenue" in a refactor. The
historical Parquet lake now has three revenue columns, each covering different date ranges.
All historical aggregations are wrong.

---

### 3. Integer Overflow in Spark Arithmetic Is Silent by Default

**What it looks like:**
```python
df = spark.createDataFrame([(2_000_000_000,), (2_000_000_000,)], ["count_col"])
df.withColumn("doubled", F.col("count_col") * 2).show()
```

**What actually happens:**
`IntegerType` holds values from -2,147,483,648 to 2,147,483,647. Multiplying 2,000,000,000 by 2
overflows silently to -294,967,296. No exception. No warning. The result is a negative number
that passes any downstream filter like `F.col("doubled") > 0` trivially.

**Why it's insidious:**
ANSI mode (`spark.sql.ansi.enabled`) is disabled by default in most clusters. Without it, Spark
mimics Java/JVM integer wraparound semantics. Large-value arithmetic in analytics pipelines
commonly exceeds INT range when multiplying row counts, pageview minutes, or byte sizes.

**Minimal repro:**
```python
spark.conf.set("spark.sql.ansi.enabled", "false")   # default
df = spark.createDataFrame([(2_100_000_000,)], ["x"])
df.withColumn("overflow", F.col("x").cast(IntegerType()) * 2).show()
# Shows: -94967296  ← wrong, no error
```

**How to catch it:**
```python
# Detect potential overflow before arithmetic
MAX_INT = 2_147_483_647
overflow_rows = df.filter(F.col("x") > MAX_INT / 2)
assert overflow_rows.count() == 0, "Values may overflow IntegerType multiplication"
# Or: enable ANSI mode in production
spark.conf.set("spark.sql.ansi.enabled", "true")
```

**Real-world trigger:**
An ad-tech platform that multiplies `impressions * bid_price_microcents`. Both columns are
`IntegerType` in the schema inherited from Hive. Products exceed INT range; daily revenue
reports show randomly negative totals.

---

### 4. `union()` Aligns by Position, Not by Name

**What it looks like:**
```python
schema1 = StructType([StructField("name", StringType()), StructField("age", IntegerType())])
schema2 = StructType([StructField("age", IntegerType()), StructField("name", StringType())])  # swapped

df1 = spark.createDataFrame([("Alice", 30)], schema1)
df2 = spark.createDataFrame([(25, "Bob")], schema2)

df1.union(df2).show()
```

**What actually happens:**
`union()` is purely positional. Column 1 from df2 (`age=25`) maps to column 1 of the result
schema (`name`), so "25" appears under "name" and "Bob" appears under "age". No error is raised.
The data is silently cross-assigned.

**Why it's insidious:**
If both DataFrames have the same number of columns and compatible types (e.g., both StringType
after implicit cast), Spark happily merges them. The output schema looks correct; the values
are wrong.

**Minimal repro:**
```python
df1 = spark.createDataFrame([("Alice", 30)], ["name", "age"])
df2 = spark.createDataFrame([(25, "Bob")], ["age", "name"])   # reversed
df1.union(df2).show()
# Row 2: name=25, age=Bob  ← wrong
```

**How to catch it:**
Always use `unionByName()`:
```python
df1.unionByName(df2)                          # raises if schema differs
df1.unionByName(df2, allowMissingColumns=True) # Spark 3.1+
```
Add a pre-union schema check in your pipeline utilities.

**Real-world trigger:**
Two microservices write daily event files with the same columns in different orders. A nightly
union job has silently been putting country codes in the timestamp column for months.

---

### 5. Parquet Read by Position Misaligns Columns After Schema Change

**What it looks like:**
```python
# Original Parquet written with: [user_id, event_type, timestamp]
# Schema evolved; new code reads with: [user_id, timestamp, event_type]  # different order

schema = StructType([
    StructField("user_id", StringType()),
    StructField("timestamp", TimestampType()),   # position 2
    StructField("event_type", StringType()),      # position 3
])
df = spark.read.schema(schema).parquet("s3://bucket/events/")
```

**What actually happens:**
Parquet stores column metadata by name in the file footer — so Parquet readers that respect the
footer will match by name. However, when you provide an explicit schema to Spark and that schema
has different column ordering than the file, Spark may read by position in some edge cases
(particularly with older Parquet libraries or specific Spark versions). The result is that
`timestamp` receives what was written as `event_type` and vice versa.

**Why it's insidious:**
This is version- and format-specific. Some environments read correctly by name; others read
positionally. The bug silently activates after a library upgrade or migration to a different
cluster type.

**How to catch it:**
```python
# After reading, spot-check known values against expected types
sample = df.limit(10).toPandas()
assert sample["timestamp"].dtype == "datetime64[ns]", "timestamp column has wrong type"
```

**Real-world trigger:**
A migration from an old on-premise Hive cluster to Databricks. The Parquet files have the same
columns but the new cluster's Spark version handles schema provision differently. Timestamp and
event_type are transposed in the output tables.

---

### 6. Timestamp Precision Loss Through Parquet Round-Trip

**What it looks like:**
```python
from datetime import datetime
ts = datetime(2024, 1, 15, 12, 0, 0, 123456)   # microsecond precision
df = spark.createDataFrame([(ts,)], ["ts"])
df.write.parquet("/tmp/ts_test")
df2 = spark.read.parquet("/tmp/ts_test")
df2.show(truncate=False)
```

**What actually happens:**
Spark's `TimestampType` is microsecond precision. Writing to Parquet preserves microseconds.
But writing to JDBC (e.g., PostgreSQL TIMESTAMP columns with millisecond precision) silently
truncates to milliseconds. Writing to CSV or JSON and reading back can lose precision entirely.
A delta of 123 microseconds becomes 0 microseconds silently.

**Why it's insidious:**
For most business metrics, microsecond precision doesn't matter. For event sequencing, financial
transaction ordering, or duplicate detection based on timestamps, silent precision loss causes
incorrect deduplication or wrong event ordering.

**How to catch it:**
```python
# Round-trip test for timestamp precision
original_ts = df.select(F.col("ts").cast("long")).collect()[0][0]
roundtrip_ts = df2.select(F.col("ts").cast("long")).collect()[0][0]
assert original_ts == roundtrip_ts, f"Precision loss: {original_ts} vs {roundtrip_ts}"
```

**Real-world trigger:**
A trading system that uses Spark to write tick data to JDBC. Two events with microsecond
separation appear at the same millisecond timestamp after the round-trip, causing duplicate
detection logic to drop one event silently.

---

### 7. Implicit Type Widening in `union()` With IntegerType and LongType

**What it looks like:**
```python
df_int = spark.createDataFrame([(1,), (2,)], StructType([StructField("x", IntegerType())]))
df_long = spark.createDataFrame([(3_000_000_000,)], StructType([StructField("x", LongType())]))
result = df_int.union(df_long)
result.printSchema()
result.show()
```

**What actually happens:**
Spark widens `IntegerType` to `LongType` silently. This is generally safe for values within INT
range. The danger is the reverse: `LongType` unioned with `StringType` silently casts the long
to string. Arithmetic operations on the string column then fail or return wrong results.

**Why it's insidious:**
Type promotion feels correct and is usually documented — but when StringType is involved, the
promoted type is String, and all numeric operations on that column now silently return NULL or
throw at runtime.

**Minimal repro:**
```python
df_num = spark.createDataFrame([(1,)], ["x"])        # LongType
df_str = spark.createDataFrame([("abc",)], ["x"])    # StringType
result = df_num.union(df_str)
result.agg(F.sum("x")).show()   # NULL, no error
```

**How to catch it:**
Validate column types after union:
```python
assert result.schema["x"].dataType == LongType(), f"Unexpected type: {result.schema['x'].dataType}"
```

**Real-world trigger:**
A pipeline that unions hourly event files from two systems. One system writes numeric user IDs
(LongType); the other writes hashed user IDs (StringType). The union silently produces a
StringType column; all downstream `SUM(user_id)` aggregations return NULL.

---

### 8. `nullable=False` in Schema Is Not Enforced by Spark

**What it looks like:**
```python
schema = StructType([
    StructField("id", IntegerType(), nullable=False),
    StructField("value", DoubleType(), nullable=False),
])
df = spark.read.schema(schema).csv("s3://bucket/data.csv")
df.filter(F.col("id").isNull()).count()   # expected: 0; actual: may be > 0
```

**What actually happens:**
`nullable=False` in a Spark schema is an *optimizer hint*, not an enforcement constraint. Spark
does not reject or error on NULL values in nullable=False columns. The schema metadata is used
by the Catalyst optimizer to skip NULL checks in some operations — which can cause incorrect
results if NULLs are actually present but the optimizer assumes they can't be.

**Why it's insidious:**
Code that checks `nullable` from the schema assumes it means "this column has no NULLs." The
optimizer may skip NULL propagation logic, producing wrong aggregation results on data that
contains NULLs the schema claims don't exist.

**How to catch it:**
```python
for field in df.schema.fields:
    if not field.nullable:
        null_count = df.filter(F.col(field.name).isNull()).count()
        assert null_count == 0, f"Column '{field.name}' declared non-nullable but has {null_count} NULLs"
```

**Real-world trigger:**
A Hive table created with `NOT NULL` constraints (which Hive also doesn't enforce). The Spark
schema inherits `nullable=False`. The Catalyst optimizer skips null coalescing; GROUP BY on
that column produces wrong group keys when NULL rows exist.

---

### 9. `ArrayType` vs Nested `StructType` Confusion With `explode()`

**What it looks like:**
```python
# Schema inference reads nested JSON incorrectly
df = spark.read.json("s3://bucket/nested_events.json")
df_exploded = df.withColumn("item", F.explode(F.col("items")))
```

**What actually happens:**
If `items` is actually a `StructType` (a single nested object) but schema inference infers it
as `ArrayType` because some rows have it as an array and others as a single object, `explode()`
works on the array rows but silently produces wrong results on the struct rows (it explodes a
struct into its fields rather than its elements).

Conversely, if `items` is a struct but is accidentally accessed with array indexing (`col("items")[0]`),
Spark silently returns NULL for all rows instead of erroring.

**How to catch it:**
```python
print(df.schema["items"])   # inspect type before exploding
# ArrayType(StructType(...)) is correct for explode
# StructType(...) requires .* expansion, not explode
```

**Real-world trigger:**
A JSON feed from a third-party API where single-item events wrap the payload in a struct
(`{"items": {...}}`) but multi-item events use an array (`{"items": [{...}, {...}]}`). Schema
inference sees the array version first; struct-version rows are silently exploded incorrectly.

---

### 10. `DecimalType` Scale Truncation Without Exception

**What it looks like:**
```python
df = spark.createDataFrame([(1.23456789,)], ["price"])
df2 = df.withColumn("price", F.col("price").cast(DecimalType(10, 2)))
df2.show()   # shows 1.23 — silently truncated, not rounded
```

**What actually happens:**
Casting to `DecimalType(precision, scale)` truncates (not rounds) extra decimal places by
default. `1.23456789` becomes `1.23`. No warning. If the downstream use is financial
(e.g., summing prices), the accumulated truncation error across millions of rows is
significant and non-recoverable.

**How to catch it:**
```python
# Compare pre- and post-cast sums to detect truncation error
original_sum = df.agg(F.sum("price")).collect()[0][0]
cast_sum = df2.agg(F.sum(F.col("price").cast(DoubleType()))).collect()[0][0]
truncation_error = abs(original_sum - cast_sum)
assert truncation_error < 0.01, f"Truncation error: {truncation_error}"
```

**Real-world trigger:**
A billing pipeline that casts unit prices to `DecimalType(10,2)` for JDBC write. The truncation
error across 50M invoice rows amounts to $8,000 per month in systematic underbilling.
