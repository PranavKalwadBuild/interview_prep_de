<!-- PySpark-patterns: Data Cleaning Workflow -->

# Data Cleaning Workflow

A top-to-bottom practitioner's playbook for cleaning an unknown dataset in PySpark.
Run these steps in order. Each step surfaces problems the next step depends on.

---

## Standard Imports

```python
from pyspark.sql import SparkSession, Window
from pyspark.sql import functions as F
from pyspark.sql.types import (
    StructType, StructField, StringType, IntegerType, LongType,
    DoubleType, TimestampType, DateType, BooleanType, DecimalType
)

spark = SparkSession.builder.getOrCreate()
```

---

## Step 1: Load & First Look

```python
df = spark.read.parquet("s3://bucket/path/")   # or .csv(), .json(), .orc()

# Dimensions
print(f"Rows: {df.count()}")
print(f"Cols: {len(df.columns)}")

# First few rows
df.show(5, truncate=False)

# Schema as printed tree
df.printSchema()
```

**What to look for:**
- Are numeric columns inferred as strings? (happens with CSV if nulls written as `"NULL"` or `""`)
- Are timestamps inferred as strings? (CSV has no native type)
- Unexpectedly nested schemas (JSON explosion)
- Column names with spaces, special characters, or reserved SQL keywords

---

## Step 2: Schema Inspection & Type Audit

```python
# Programmatic schema access
for field in df.schema.fields:
    print(f"{field.name:40s} {str(field.dataType):30s} nullable={field.nullable}")

# Check for columns Spark inferred as string that should be numeric
string_cols = [f.name for f in df.schema.fields if str(f.dataType) == "StringType()"]
print("String columns:", string_cols)

# Check for duplicate column names (happens with self-joins or messy CSVs)
from collections import Counter
dupes = [col for col, cnt in Counter(df.columns).items() if cnt > 1]
if dupes:
    print(f"DUPLICATE COLUMN NAMES: {dupes}")
    # Fix: rename before any other operation
    df = df.toDF(*[f"{c}_{i}" if df.columns[:i].count(c) > 0 else c
                   for i, c in enumerate(df.columns)])
```

**Schema drift detection** — compare current schema to an expected schema:

```python
EXPECTED_SCHEMA = StructType([
    StructField("user_id",    LongType(),      nullable=False),
    StructField("email",      StringType(),    nullable=True),
    StructField("created_at", TimestampType(), nullable=True),
    StructField("revenue",    DoubleType(),    nullable=True),
])

expected_fields = {f.name: f.dataType for f in EXPECTED_SCHEMA}
actual_fields   = {f.name: f.dataType for f in df.schema.fields}

missing  = set(expected_fields) - set(actual_fields)
extra    = set(actual_fields)   - set(expected_fields)
mistyped = {c for c in expected_fields & actual_fields
            if str(expected_fields[c]) != str(actual_fields[c])}

print(f"Missing columns : {missing}")
print(f"Extra columns   : {extra}")
print(f"Type mismatches : {mistyped}")
```

---

## Step 3: Row & Column Profiling

```python
# Non-null count and null count per column
null_counts = df.select([
    F.count(F.when(F.col(c).isNull(), c)).alias(c)
    for c in df.columns
])
null_counts.show(vertical=True)

# Null percentage per column
total = df.count()
null_pct = df.select([
    (F.count(F.when(F.col(c).isNull(), c)) / total * 100).alias(c)
    for c in df.columns
])
null_pct.show(vertical=True)

# Columns with > 50% nulls (candidates for dropping)
null_heavy = [
    c for c in df.columns
    if df.filter(F.col(c).isNull()).count() / total > 0.5
]
print("Null-heavy columns (>50% null):", null_heavy)
```

---

## Step 4: NaN and NULL Detection

NaN and NULL are different. NULL = absent value. NaN = invalid float result (0.0/0.0).
Both must be treated separately.

```python
# NULL check — works on any type
df.filter(F.col("revenue").isNull()).count()

# NaN check — only meaningful on DoubleType / FloatType
df.filter(F.isnan(F.col("revenue"))).count()

# Combined check for float columns
float_cols = [f.name for f in df.schema.fields
              if str(f.dataType) in ("DoubleType()", "FloatType()")]

null_nan_counts = df.select([
    F.count(F.when(F.col(c).isNull() | F.isnan(F.col(c)), c)).alias(c)
    for c in float_cols
])
null_nan_counts.show()
```

**Whitespace-only strings masquerading as valid values:**

```python
string_cols = [f.name for f in df.schema.fields if str(f.dataType) == "StringType()"]

# Count whitespace-only strings
ws_counts = df.select([
    F.count(F.when(F.trim(F.col(c)) == "", c)).alias(c)
    for c in string_cols
])
ws_counts.show()

# Normalize: convert whitespace-only to NULL
df = df.select([
    F.when(F.trim(F.col(c)) == "", None).otherwise(F.col(c)).alias(c)
    if c in string_cols else F.col(c)
    for c in df.columns
])
```

**String sentinel values masquerading as nulls** (common in CSV exports):

```python
NULL_SENTINELS = {"NULL", "null", "None", "none", "NA", "N/A", "na", "n/a",
                  "NaN", "nan", "#N/A", "missing", "MISSING", "", " "}

df = df.select([
    F.when(F.col(c).isin(NULL_SENTINELS), None).otherwise(F.col(c)).alias(c)
    if c in string_cols else F.col(c)
    for c in df.columns
])
```

---

## Step 5: Null Treatment

Choose strategy per column based on business semantics. Never apply one strategy blindly to all columns.

### 5a. Drop rows where critical columns are null

```python
# Single column — must have user_id
df = df.filter(F.col("user_id").isNotNull())

# Multiple columns — all must be non-null
df = df.dropna(subset=["user_id", "event_type"])

# Drop rows where ANY column is null
df = df.dropna(how="any")

# Drop rows where ALL columns are null
df = df.dropna(how="all")
```

### 5b. Fill nulls with a constant

```python
# Type-specific fill
df = df.fillna({
    "country":   "UNKNOWN",    # string
    "revenue":   0.0,          # double
    "is_active": False,        # boolean
    "qty":       0,            # integer
})
```

### 5c. Fill nulls with a derived value

```python
# Forward fill within a partition (requires Window + careful ordering)
w = Window.partitionBy("user_id").orderBy("event_ts").rowsBetween(
    Window.unboundedPreceding, 0
)
df = df.withColumn(
    "country_filled",
    F.last("country", ignorenulls=True).over(w)
)

# Fill with column median (approximate)
median_val = df.approxQuantile("revenue", [0.5], 0.01)[0]
df = df.fillna({"revenue": median_val})

# Fill with column mean
mean_val = df.select(F.avg("revenue")).collect()[0][0]
df = df.fillna({"revenue": mean_val})

# Fill with mode (most frequent value)
mode_val = (
    df.groupBy("country")
      .count()
      .orderBy(F.col("count").desc())
      .first()["country"]
)
df = df.fillna({"country": mode_val})
```

### 5d. Impute using coalesce (first non-null wins)

```python
# Use backup column if primary is null
df = df.withColumn(
    "email",
    F.coalesce(F.col("email"), F.col("email_backup"), F.lit("no-email@unknown.com"))
)
```

### 5e. Drop null-heavy columns

```python
THRESHOLD = 0.8  # drop columns with >80% nulls
cols_to_drop = [
    c for c in df.columns
    if df.filter(F.col(c).isNull()).count() / total > THRESHOLD
]
df = df.drop(*cols_to_drop)
print(f"Dropped {len(cols_to_drop)} columns: {cols_to_drop}")
```

---

## Step 6: Duplicate Detection

```python
total = df.count()
distinct_total = df.distinct().count()
print(f"Exact duplicates: {total - distinct_total}")

# Which primary key values have duplicate rows?
pk = ["user_id", "event_ts"]   # adjust to your key
dupe_keys = (
    df.groupBy(*pk)
      .count()
      .filter(F.col("count") > 1)
)
print(f"Keys with duplicates: {dupe_keys.count()}")
dupe_keys.orderBy(F.col("count").desc()).show(10)
```

**Detect duplicates across subset of columns only:**

```python
# Are there multiple rows for the same user_id with different emails?
df.groupBy("user_id") \
  .agg(F.countDistinct("email").alias("email_versions")) \
  .filter(F.col("email_versions") > 1) \
  .show()
```

---

## Step 7: Duplicate Removal

### 7a. Exact dedup (all columns identical)

```python
df = df.distinct()
# or equivalently:
df = df.dropDuplicates()
```

### 7b. Dedup on key columns — keep latest record

```python
w = Window.partitionBy("user_id").orderBy(F.col("updated_at").desc())
df = (
    df.withColumn("rn", F.row_number().over(w))
      .filter(F.col("rn") == 1)
      .drop("rn")
)
```

### 7c. Dedup on key columns — keep record with highest completeness

```python
# Score each row by number of non-null fields
all_cols = df.columns
df = df.withColumn(
    "completeness_score",
    sum(F.when(F.col(c).isNotNull(), 1).otherwise(0) for c in all_cols)
)

w = Window.partitionBy("user_id").orderBy(F.col("completeness_score").desc())
df = (
    df.withColumn("rn", F.row_number().over(w))
      .filter(F.col("rn") == 1)
      .drop("rn", "completeness_score")
)
```

### 7d. Dedup with tie-breaking on multiple criteria

```python
w = Window.partitionBy("order_id").orderBy(
    F.col("updated_at").desc(),
    F.col("source_system").asc()    # secondary tie-break
)
df = (
    df.withColumn("rn", F.row_number().over(w))
      .filter(F.col("rn") == 1)
      .drop("rn")
)
```

**Edge case — replayed batches / exactly-once ingestion:**

```python
# If ingesting a batch file again, dedup against already-loaded data
existing = spark.read.parquet("s3://warehouse/events/")
new_batch = spark.read.parquet("s3://landing/events_2024_01_01/")

# Anti-join: keep only rows in new_batch not already in existing
net_new = new_batch.join(
    existing.select("event_id"),
    on="event_id",
    how="left_anti"
)
```

---

## Step 8: Type Casting & Coercion

Always cast explicitly. Never trust CSV/JSON inference.

```python
from pyspark.sql.functions import col

df = df.withColumn("user_id",    col("user_id").cast(LongType()))
df = df.withColumn("revenue",    col("revenue").cast(DoubleType()))
df = df.withColumn("is_active",  col("is_active").cast(BooleanType()))
df = df.withColumn("created_at", col("created_at").cast(TimestampType()))
```

**Safe cast — silently returns NULL on failure instead of crashing:**

```python
# cast() already returns NULL on failure for most types
df = df.withColumn("qty", col("qty").cast(IntegerType()))

# Verify: count how many rows failed the cast
failed_casts = df.filter(col("qty").isNull() & col("qty_raw").isNotNull()).count()
print(f"Rows that failed int cast: {failed_casts}")
```

**Boolean coercion from string flags:**

```python
df = df.withColumn(
    "is_active",
    F.when(F.upper(F.col("is_active_str")).isin("Y", "YES", "TRUE", "1"), True)
     .when(F.upper(F.col("is_active_str")).isin("N", "NO", "FALSE", "0"), False)
     .otherwise(None)
)
```

**Integer-encoded booleans:**

```python
df = df.withColumn("is_deleted", F.col("is_deleted_flag").cast(BooleanType()))
# cast(BooleanType()) treats 0 -> False, non-zero -> True, NULL -> NULL
```

**Decimal precision — avoid double rounding errors in financial data:**

```python
df = df.withColumn("amount", col("amount").cast(DecimalType(18, 4)))
```

---

## Step 9: String Standardization

```python
# Trim leading/trailing whitespace
df = df.withColumn("email", F.trim(F.col("email")))

# Normalize case
df = df.withColumn("country_code", F.upper(F.col("country_code")))
df = df.withColumn("name",         F.initcap(F.col("name")))    # Title Case

# Collapse internal multiple spaces
df = df.withColumn("address", F.regexp_replace(F.col("address"), r"\s+", " "))

# Remove non-printable / control characters
df = df.withColumn("name", F.regexp_replace(F.col("name"), r"[\x00-\x1F\x7F]", ""))

# Standardize phone numbers — strip all non-digit chars
df = df.withColumn("phone", F.regexp_replace(F.col("phone"), r"[^\d]", ""))

# Email validation — flag invalid, don't silently drop
df = df.withColumn(
    "email_valid",
    F.col("email").rlike(r"^[a-zA-Z0-9._%+\-]+@[a-zA-Z0-9.\-]+\.[a-zA-Z]{2,}$")
)

# Truncate oversized strings (prevents downstream VARCHAR overflow)
df = df.withColumn("description", F.col("description").substr(1, 1000))
```

---

## Step 10: Date & Timestamp Normalization

```python
# Parse string dates with known format
df = df.withColumn(
    "created_date",
    F.to_date(F.col("created_date_str"), "yyyy-MM-dd")
)

# Multiple possible formats — try each, coalesce first non-null
df = df.withColumn(
    "event_date",
    F.coalesce(
        F.to_date(F.col("raw_date"), "yyyy-MM-dd"),
        F.to_date(F.col("raw_date"), "MM/dd/yyyy"),
        F.to_date(F.col("raw_date"), "dd-MMM-yyyy"),
    )
)

# Flag rows where date parsing failed
df = df.withColumn(
    "date_parse_failed",
    F.col("event_date").isNull() & F.col("raw_date").isNotNull()
)

# Unix epoch to timestamp
df = df.withColumn("created_at", F.from_unixtime(F.col("epoch_sec")).cast(TimestampType()))

# Normalize timezone to UTC
df = df.withColumn(
    "event_ts_utc",
    F.to_utc_timestamp(F.col("event_ts_local"), "America/New_York")
)

# Sanity check: no future dates, no dates before business start
df = df.withColumn(
    "date_suspicious",
    (F.col("created_date") > F.current_date()) |
    (F.col("created_date") < F.lit("2000-01-01").cast(DateType()))
)

df.filter(F.col("date_suspicious")).count()
```

---

## Step 11: Outlier Detection & Treatment

### 11a. IQR-based outlier flagging

```python
q1, q3 = df.approxQuantile("revenue", [0.25, 0.75], 0.01)
iqr = q3 - q1
lower_fence = q1 - 1.5 * iqr
upper_fence = q3 + 1.5 * iqr

df = df.withColumn(
    "revenue_outlier",
    (F.col("revenue") < lower_fence) | (F.col("revenue") > upper_fence)
)

print(f"IQR range: [{lower_fence:.2f}, {upper_fence:.2f}]")
df.filter(F.col("revenue_outlier")).count()
```

### 11b. Z-score outlier flagging

```python
from pyspark.sql.functions import stddev, mean

stats = df.select(
    F.mean("revenue").alias("mu"),
    F.stddev("revenue").alias("sigma")
).collect()[0]

df = df.withColumn(
    "revenue_zscore",
    (F.col("revenue") - stats["mu"]) / stats["sigma"]
).withColumn(
    "revenue_outlier_zscore",
    F.abs(F.col("revenue_zscore")) > 3.0
)
```

### 11c. Outlier treatment options

```python
# Option 1: Cap at fence (Winsorization)
df = df.withColumn(
    "revenue_capped",
    F.least(F.greatest(F.col("revenue"), F.lit(lower_fence)), F.lit(upper_fence))
)

# Option 2: Null out outliers (let downstream imputation handle)
df = df.withColumn(
    "revenue_clean",
    F.when(F.col("revenue_outlier"), None).otherwise(F.col("revenue"))
)

# Option 3: Route outliers to a quarantine path
quarantine_df = df.filter(F.col("revenue_outlier"))
clean_df      = df.filter(~F.col("revenue_outlier"))

quarantine_df.write.mode("append").parquet("s3://quarantine/revenue_outliers/")
```

---

## Step 12: Categorical Standardization

```python
# Check distinct values (cardinality audit)
df.groupBy("status") \
  .count() \
  .orderBy(F.col("count").desc()) \
  .show(50, truncate=False)

# Normalize case and whitespace inconsistencies
df = df.withColumn("status", F.trim(F.upper(F.col("status"))))

# Map known variants to canonical values
STATUS_MAP = {
    "ACTIVE":    "ACTIVE",
    "ACT":       "ACTIVE",
    "A":         "ACTIVE",
    "1":         "ACTIVE",
    "INACTIVE":  "INACTIVE",
    "INACT":     "INACTIVE",
    "I":         "INACTIVE",
    "0":         "INACTIVE",
    "CANCELLED": "CANCELLED",
    "CANCEL":    "CANCELLED",
    "CNCL":      "CANCELLED",
}

mapping_expr = F.create_map([F.lit(k) for kv in STATUS_MAP.items() for k in kv])
df = df.withColumn("status_clean", mapping_expr[F.col("status")])

# Flag unmapped values for review
df = df.withColumn(
    "status_unknown",
    F.col("status_clean").isNull() & F.col("status").isNotNull()
)
df.filter(F.col("status_unknown")).groupBy("status").count().show()
```

---

## Step 13: Structural & Referential Checks

```python
# Referential integrity — every order must have a valid customer
customers = spark.read.parquet("s3://warehouse/customers/")
orders    = df  # current df

orphan_orders = orders.join(
    customers.select("customer_id"),
    on="customer_id",
    how="left_anti"
)
print(f"Orphan orders (no matching customer): {orphan_orders.count()}")

# Logical constraint check — end_date must be >= start_date
invalid_dates = df.filter(F.col("end_date") < F.col("start_date"))
print(f"Rows with end_date < start_date: {invalid_dates.count()}")

# Range check — age must be 0-150
df = df.withColumn(
    "age_valid",
    F.col("age").between(0, 150)
)

# Cross-column consistency — if is_premium is True, premium_since must not be null
inconsistent = df.filter(
    (F.col("is_premium") == True) & F.col("premium_since").isNull()
)
print(f"Premium users missing premium_since: {inconsistent.count()}")
```

---

## Step 14: Handle Corrupt and Malformed Input Files

When reading CSV/JSON, Spark silently drops or nullifies bad rows by default. Make corruption explicit.

```python
# CSV with explicit corrupt record column
df = spark.read \
    .option("mode", "PERMISSIVE") \
    .option("columnNameOfCorruptRecord", "_corrupt_record") \
    .csv("s3://landing/data.csv", header=True, inferSchema=False)

corrupt_rows = df.filter(F.col("_corrupt_record").isNotNull())
print(f"Corrupt rows: {corrupt_rows.count()}")

# Route corrupt rows to quarantine
corrupt_rows.write.mode("append").text("s3://quarantine/corrupt_records/")
clean_df = df.filter(F.col("_corrupt_record").isNull()).drop("_corrupt_record")

# JSON with badRecordsPath — writes unparseable records to a separate path
df = spark.read \
    .option("badRecordsPath", "s3://quarantine/bad_json/") \
    .json("s3://landing/events.json")
```

**Partially written / empty files:**

```python
# Detect zero-byte files before reading (prevents silent empty DataFrames)
import subprocess
result = subprocess.run(
    ["aws", "s3", "ls", "--recursive", "s3://landing/data/"],
    capture_output=True, text=True
)
# Parse for 0-byte files — omitted here; point: always audit file sizes before job

# After read, verify row count against expected minimum
MIN_EXPECTED_ROWS = 1_000_000
actual_rows = df.count()
if actual_rows < MIN_EXPECTED_ROWS:
    raise ValueError(f"Row count {actual_rows} below minimum {MIN_EXPECTED_ROWS} — possible partial file")
```

---

## Step 15: Final Validation Checklist

Run this after all cleaning steps to confirm the dataset is ready for downstream use.

```python
def validate_dataframe(df, pk_cols, not_null_cols, expected_min_rows):
    issues = []

    # 1. Minimum row count
    count = df.count()
    if count < expected_min_rows:
        issues.append(f"Row count {count} below minimum {expected_min_rows}")

    # 2. Primary key uniqueness
    pk_dupes = df.groupBy(*pk_cols).count().filter(F.col("count") > 1).count()
    if pk_dupes > 0:
        issues.append(f"Primary key has {pk_dupes} duplicate values")

    # 3. Required columns are non-null
    for col_name in not_null_cols:
        null_cnt = df.filter(F.col(col_name).isNull()).count()
        if null_cnt > 0:
            issues.append(f"Column '{col_name}' has {null_cnt} nulls (expected 0)")

    # 4. No fully-null rows
    all_null_rows = df.filter(
        F.array_min(F.array([F.col(c).isNotNull() for c in df.columns])) == False
    ).count()
    if all_null_rows > 0:
        issues.append(f"{all_null_rows} completely null rows exist")

    # 5. Report
    if issues:
        for issue in issues:
            print(f"FAIL: {issue}")
        raise AssertionError(f"Validation failed with {len(issues)} issue(s)")
    else:
        print(f"PASS: {count:,} rows, all checks passed")


validate_dataframe(
    df           = df,
    pk_cols      = ["user_id", "event_ts"],
    not_null_cols= ["user_id", "event_type"],
    expected_min_rows = 100_000
)
```

---

## Full Pipeline Template

```python
# ── 0. Load ──────────────────────────────────────────────────────────────────
df = spark.read \
    .option("mode", "PERMISSIVE") \
    .option("columnNameOfCorruptRecord", "_corrupt_record") \
    .csv("s3://landing/data.csv", header=True, inferSchema=False)

corrupt = df.filter(F.col("_corrupt_record").isNotNull())
corrupt.write.mode("append").text("s3://quarantine/corrupt/")
df = df.filter(F.col("_corrupt_record").isNull()).drop("_corrupt_record")

# ── 1. Cast types explicitly ──────────────────────────────────────────────────
df = df \
    .withColumn("user_id",    F.col("user_id").cast(LongType())) \
    .withColumn("revenue",    F.col("revenue").cast(DoubleType())) \
    .withColumn("created_at", F.to_timestamp(F.col("created_at"), "yyyy-MM-dd HH:mm:ss"))

# ── 2. Normalize nulls ────────────────────────────────────────────────────────
STRING_NULLS = {"NULL", "null", "NA", "N/A", ""}
string_cols  = [f.name for f in df.schema.fields if str(f.dataType) == "StringType()"]

for c in string_cols:
    df = df.withColumn(
        c,
        F.when(F.trim(F.col(c)).isin(STRING_NULLS) | (F.trim(F.col(c)) == ""), None)
         .otherwise(F.trim(F.col(c)))
    )

# ── 3. Drop rows missing primary key ──────────────────────────────────────────
df = df.dropna(subset=["user_id"])

# ── 4. Dedup — keep latest ────────────────────────────────────────────────────
w  = Window.partitionBy("user_id").orderBy(F.col("updated_at").desc())
df = df.withColumn("rn", F.row_number().over(w)).filter(F.col("rn") == 1).drop("rn")

# ── 5. Standardize strings ────────────────────────────────────────────────────
df = df.withColumn("email",   F.lower(F.trim(F.col("email"))))
df = df.withColumn("country", F.upper(F.trim(F.col("country"))))

# ── 6. Fill non-critical nulls ────────────────────────────────────────────────
df = df.fillna({"country": "UNKNOWN", "revenue": 0.0})

# ── 7. Outlier capping ────────────────────────────────────────────────────────
q1, q3 = df.approxQuantile("revenue", [0.25, 0.75], 0.01)
iqr = q3 - q1
df  = df.withColumn("revenue",
        F.least(F.greatest(F.col("revenue"), F.lit(q1 - 1.5 * iqr)),
                F.lit(q3 + 1.5 * iqr)))

# ── 8. Validate ───────────────────────────────────────────────────────────────
validate_dataframe(df, pk_cols=["user_id"], not_null_cols=["user_id"], expected_min_rows=1000)

# ── 9. Write ──────────────────────────────────────────────────────────────────
df.write.mode("overwrite").partitionBy("country").parquet("s3://warehouse/users_clean/")
```

---

## Edge Case Quick Reference

| Problem | Detection | Fix |
|---------|-----------|-----|
| NULL vs NaN confusion | `F.isnan()` on float cols | `F.when(F.isnan(c), None).otherwise(c)` |
| Whitespace-only strings | `F.trim(col) == ""` | Replace with `None` |
| Sentinel nulls (`"NA"`, `"NULL"`) | `.isin(SENTINEL_SET)` | Replace with `None` |
| Duplicate column names | `Counter(df.columns)` | Rename before any operation |
| Schema drift (new/missing cols) | Compare to expected StructType | Add missing cols as `F.lit(None)`, drop extra |
| Partially written files | Row count check after load | Raise if below threshold |
| Corrupt CSV rows | `columnNameOfCorruptRecord` | Route to quarantine path |
| Exactly-once re-ingestion | Left anti-join against existing | Keep only net-new rows |
| cast() silent failure | Check nulls vs pre-cast nulls | Count & alert on cast failures |
| Future dates / prehistoric dates | `col > current_date()` check | Flag and quarantine |
| Orphan foreign keys | Left anti-join to parent table | Route to quarantine or fill with default |
| Inconsistent categoricals | `groupBy().count()` audit | Map variants via `create_map` |
