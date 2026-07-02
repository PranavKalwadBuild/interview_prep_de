<!-- PySpark-patterns: Statistical EDA -->

# Statistical EDA

A top-to-bottom practitioner's playbook for profiling an unknown dataset statistically.
Run after data cleaning (file 29). These steps surface distributional properties, relationships, and anomalies.

---

## Standard Imports

```python
from pyspark.sql import SparkSession, Window
from pyspark.sql import functions as F
from pyspark.sql.types import DoubleType, LongType, StringType

spark = SparkSession.builder.getOrCreate()
```

---

## Step 1: Summary Statistics

### 1a. Built-in describe()

```python
# Works on all columns — strings get count/min/max only
df.describe().show(truncate=False)

# Numeric columns only — more precise
numeric_cols = [f.name for f in df.schema.fields
                if str(f.dataType) in ("DoubleType()", "FloatType()",
                                       "IntegerType()", "LongType()", "DecimalType()")]
df.select(numeric_cols).describe().show(truncate=False)
```

`describe()` returns: count, mean, stddev, min, max.
It does **not** return median, percentiles, or skewness.

### 1b. summary() — adds percentiles

```python
# summary() adds 25%, 50%, 75% percentiles to describe()
df.select(numeric_cols).summary().show(truncate=False)
```

Returns: count, mean, stddev, min, 25%, 50%, 75%, max.

### 1c. Custom aggregation profile

```python
profile = df.select([
    F.count(F.col(c)).alias(f"{c}__count")
    for c in numeric_cols
] + [
    F.mean(F.col(c)).alias(f"{c}__mean")
    for c in numeric_cols
] + [
    F.stddev(F.col(c)).alias(f"{c}__stddev")
    for c in numeric_cols
] + [
    F.min(F.col(c)).alias(f"{c}__min")
    for c in numeric_cols
] + [
    F.max(F.col(c)).alias(f"{c}__max")
    for c in numeric_cols
])
profile.show(vertical=True, truncate=False)
```

---

## Step 2: Percentile Distributions

### 2a. approxQuantile — fast, approximate

```python
# Returns exact-ish values using Greenwald-Khanna algorithm
# relativeError=0.0 → exact (expensive); 0.01 → 1% error (fast)
percentiles = df.approxQuantile(
    col="revenue",
    probabilities=[0.01, 0.05, 0.10, 0.25, 0.50, 0.75, 0.90, 0.95, 0.99],
    relativeError=0.01
)

labels = ["p1", "p5", "p10", "p25", "p50", "p75", "p90", "p95", "p99"]
for label, val in zip(labels, percentiles):
    print(f"  {label}: {val:.4f}")
```

### 2b. Multiple columns at once

```python
results = df.approxQuantile(
    col=numeric_cols,
    probabilities=[0.25, 0.50, 0.75],
    relativeError=0.01
)
for col_name, (q1, median, q3) in zip(numeric_cols, results):
    print(f"{col_name:30s} Q1={q1:.2f}  Median={median:.2f}  Q3={q3:.2f}  IQR={q3-q1:.2f}")
```

### 2c. percentile_approx as SQL aggregate

```python
df.select([
    F.percentile_approx(F.col(c), [0.25, 0.5, 0.75]).alias(c)
    for c in numeric_cols
]).show(truncate=False)
```

---

## Step 3: Cardinality & Uniqueness

```python
total = df.count()

cardinality = df.select([
    F.countDistinct(F.col(c)).alias(c)
    for c in df.columns
])
cardinality.show(vertical=True)

# Uniqueness ratio — 1.0 means the column is a candidate key
print("Uniqueness ratio per column:")
for c in df.columns:
    dist = df.select(F.countDistinct(c)).collect()[0][0]
    ratio = dist / total if total > 0 else 0
    print(f"  {c:40s} {dist:10,d} distinct  ({ratio:.4f} uniqueness)")
```

**High-cardinality flags (candidate keys):**

```python
# Columns where every value is unique
candidate_keys = [
    c for c in df.columns
    if df.select(F.countDistinct(c)).collect()[0][0] == total
]
print("Candidate key columns:", candidate_keys)
```

**Low-cardinality flags (categorical columns):**

```python
# Columns with <= 50 distinct values → treat as categoricals
categoricals = [
    c for c in df.columns
    if df.select(F.countDistinct(c)).collect()[0][0] <= 50
]
print("Likely categorical columns:", categoricals)
```

---

## Step 4: Null & Completeness Rate Per Column

```python
total = df.count()

completeness = df.select([
    (1.0 - F.count(F.when(F.col(c).isNull(), c)) / total).alias(c)
    for c in df.columns
])
completeness.show(vertical=True)

# Print sorted by completeness ascending (worst first)
rows = completeness.collect()[0].asDict()
sorted_rows = sorted(rows.items(), key=lambda x: x[1])
print("\nCompleteness (worst to best):")
for col_name, rate in sorted_rows:
    bar = "█" * int(rate * 20)
    print(f"  {col_name:40s} {rate*100:6.1f}%  {bar}")
```

---

## Step 5: Frequency Tables (Value Counts)

```python
# Top N values for a single column
df.groupBy("country") \
  .count() \
  .withColumn("pct", F.round(F.col("count") / total * 100, 2)) \
  .orderBy(F.col("count").desc()) \
  .show(20, truncate=False)

# All categorical columns at once
string_cols = [f.name for f in df.schema.fields if str(f.dataType) == "StringType()"]

for c in string_cols:
    print(f"\n=== {c} ===")
    df.groupBy(c) \
      .count() \
      .withColumn("pct", F.round(F.col("count") / total * 100, 2)) \
      .orderBy(F.col("count").desc()) \
      .show(10, truncate=False)
```

---

## Step 6: Approximate Histograms

Spark has no native histogram for DataFrames. Use bin bucketing or `rdd.histogram()`.

### 6a. Manual bin bucketing

```python
NUM_BINS = 20

stats = df.select(
    F.min("revenue").alias("min_val"),
    F.max("revenue").alias("max_val")
).collect()[0]

min_val = stats["min_val"]
max_val = stats["max_val"]
bin_width = (max_val - min_val) / NUM_BINS

df_hist = (
    df.filter(F.col("revenue").isNotNull())
      .withColumn(
          "bin",
          F.floor((F.col("revenue") - min_val) / bin_width).cast(LongType())
      )
      .withColumn("bin", F.least(F.col("bin"), F.lit(NUM_BINS - 1)))  # clamp top edge
      .groupBy("bin")
      .count()
      .orderBy("bin")
      .withColumn("bin_lower", F.round(min_val + F.col("bin") * bin_width, 2))
      .withColumn("bin_upper", F.round(min_val + (F.col("bin") + 1) * bin_width, 2))
      .select("bin_lower", "bin_upper", "count")
)
df_hist.show(NUM_BINS, truncate=False)
```

### 6b. RDD histogram (exact)

```python
# Collect revenue values to driver — only use on sampled data
sample_rdd = df.select("revenue").filter(F.col("revenue").isNotNull()) \
               .sample(fraction=0.01) \
               .rdd.map(lambda r: float(r[0]))

buckets, counts = sample_rdd.histogram(20)
for i, cnt in enumerate(counts):
    print(f"  [{buckets[i]:.1f}, {buckets[i+1]:.1f})  {cnt}")
```

---

## Step 7: Skewness & Kurtosis

Skewness and kurtosis measure distributional shape of numeric columns.

```python
# skewness: 0 = symmetric, >0 = right tail, <0 = left tail
# kurtosis: 3 = normal, >3 = heavy tails (leptokurtic), <3 = light tails (platykurtic)

shape_stats = df.select([
    F.skewness(F.col(c)).alias(f"{c}__skew")
    for c in numeric_cols
] + [
    F.kurtosis(F.col(c)).alias(f"{c}__kurt")
    for c in numeric_cols
])
shape_stats.show(vertical=True)

# Interpretation helper
print("\nSkewness interpretation:")
for c in numeric_cols:
    skew = df.select(F.skewness(c)).collect()[0][0]
    if skew is None:
        label = "N/A (all null)"
    elif abs(skew) < 0.5:
        label = "approximately symmetric"
    elif skew > 1.0:
        label = "strongly right-skewed (long right tail)"
    elif skew > 0.5:
        label = "moderately right-skewed"
    elif skew < -1.0:
        label = "strongly left-skewed (long left tail)"
    else:
        label = "moderately left-skewed"
    print(f"  {c:40s} skew={skew:+.3f}  →  {label}")
```

**Implication for Spark jobs:** Highly skewed numeric columns often correspond to data skew in `groupBy` — the rows with extreme values may land on the same partition, causing straggler tasks.

---

## Step 8: Correlation Analysis

### 8a. Pairwise Pearson correlation (linear)

```python
from pyspark.ml.stat import Correlation
from pyspark.ml.feature import VectorAssembler

# Requires non-null values — fill or drop first
df_corr = df.select(numeric_cols).dropna()

assembler = VectorAssembler(inputCols=numeric_cols, outputCol="features")
df_vec = assembler.transform(df_corr).select("features")

corr_matrix = Correlation.corr(df_vec, "features", method="pearson")
matrix = corr_matrix.collect()[0][0].toArray()

print("\nPearson Correlation Matrix:")
header = f"{'':25s}" + "".join(f"{c[:10]:>12s}" for c in numeric_cols)
print(header)
for i, row_name in enumerate(numeric_cols):
    row = f"{row_name[:25]:25s}" + "".join(f"{matrix[i][j]:+12.3f}" for j in range(len(numeric_cols)))
    print(row)
```

### 8b. Spearman rank correlation (monotonic, handles outliers better)

```python
corr_spearman = Correlation.corr(df_vec, "features", method="spearman")
matrix_s = corr_spearman.collect()[0][0].toArray()
# same printing pattern as above
```

### 8c. Two-column correlation shortcut

```python
# Quick check between two columns
r = df.stat.corr("revenue", "session_duration", method="pearson")
print(f"Pearson r(revenue, session_duration) = {r:.4f}")
```

### 8d. Interpreting correlation

| |r| range | Interpretation |
|------------|----------------|
| 0.90 – 1.00 | Very strong — consider dropping one column (multicollinearity) |
| 0.70 – 0.89 | Strong relationship |
| 0.50 – 0.69 | Moderate relationship |
| 0.30 – 0.49 | Weak relationship |
| 0.00 – 0.29 | Negligible linear relationship (may still have nonlinear) |

---

## Step 9: Cross-Tabulations & Contingency Tables

```python
# crosstab between two categorical columns
df.stat.crosstab("country", "subscription_tier").show(truncate=False)

# Normalized crosstab (row-wise percentages)
ct = df.groupBy("country", "subscription_tier").count()
totals = df.groupBy("country").count().withColumnRenamed("count", "total")

ct_normalized = ct.join(totals, on="country") \
                  .withColumn("pct", F.round(F.col("count") / F.col("total") * 100, 1)) \
                  .orderBy("country", "subscription_tier")
ct_normalized.show(truncate=False)

# freqItems — finds values that appear in > minSupport fraction of rows
df.stat.freqItems(["country", "status"], support=0.01).show(truncate=False)
```

---

## Step 10: Outlier Profile

```python
def outlier_profile(df, col_name):
    q1, q3 = df.approxQuantile(col_name, [0.25, 0.75], 0.01)
    iqr    = q3 - q1
    lower  = q1 - 1.5 * iqr
    upper  = q3 + 1.5 * iqr

    stats = df.select(
        F.count(F.col(col_name)).alias("n"),
        F.mean(F.col(col_name)).alias("mean"),
        F.min(F.col(col_name)).alias("min"),
        F.max(F.col(col_name)).alias("max"),
        F.count(F.when(F.col(col_name) < lower, True)).alias("below_fence"),
        F.count(F.when(F.col(col_name) > upper, True)).alias("above_fence"),
    ).collect()[0]

    print(f"\n=== Outlier Profile: {col_name} ===")
    print(f"  N         : {stats['n']:,}")
    print(f"  Mean      : {stats['mean']:.4f}")
    print(f"  Min / Max : {stats['min']:.4f} / {stats['max']:.4f}")
    print(f"  IQR fence : [{lower:.4f}, {upper:.4f}]")
    print(f"  Below fence: {stats['below_fence']:,}  ({stats['below_fence']/stats['n']*100:.2f}%)")
    print(f"  Above fence: {stats['above_fence']:,}  ({stats['above_fence']/stats['n']*100:.2f}%)")

for c in numeric_cols:
    outlier_profile(df, c)
```

---

## Step 11: Time-Series Profile (if date/timestamp column exists)

```python
# Rows per day
df.withColumn("date", F.to_date(F.col("event_ts"))) \
  .groupBy("date") \
  .count() \
  .orderBy("date") \
  .show(30)

# Rows per hour of day (detect batch patterns vs continuous)
df.withColumn("hour", F.hour(F.col("event_ts"))) \
  .groupBy("hour") \
  .count() \
  .orderBy("hour") \
  .show(24)

# Rows per day of week
df.withColumn("dow", F.dayofweek(F.col("event_ts"))) \
  .groupBy("dow") \
  .count() \
  .orderBy("dow") \
  .show()

# Date range
df.select(
    F.min("event_ts").alias("earliest"),
    F.max("event_ts").alias("latest"),
    F.datediff(F.max("event_ts").cast("date"), F.min("event_ts").cast("date")).alias("span_days")
).show()

# Gaps — days with zero records (detect pipeline outages)
date_range = spark.range(0, span_days + 1) \
    .withColumn("date", F.date_add(F.lit(earliest_date), F.col("id").cast("int"))) \
    .drop("id")

daily_counts = df.withColumn("date", F.to_date("event_ts")) \
                 .groupBy("date").count()

gaps = date_range.join(daily_counts, on="date", how="left") \
                 .filter(F.col("count").isNull()) \
                 .orderBy("date")
print(f"Days with zero records: {gaps.count()}")
gaps.show()
```

---

## Step 12: Full Profile Report Template

Run this once against any new dataset to get a complete statistical snapshot.

```python
def full_eda_report(df, table_name="dataset"):
    print(f"\n{'='*60}")
    print(f"  EDA REPORT: {table_name}")
    print(f"{'='*60}")

    total = df.count()
    print(f"\nShape: {total:,} rows × {len(df.columns)} columns")

    # Schema
    print("\n--- Schema ---")
    for f in df.schema.fields:
        print(f"  {f.name:40s} {str(f.dataType):25s} nullable={f.nullable}")

    # Null rates
    print("\n--- Null Rates ---")
    null_expr = [
        (F.count(F.when(F.col(c).isNull(), c)) / total * 100).alias(c)
        for c in df.columns
    ]
    null_rates = df.select(null_expr).collect()[0].asDict()
    for col_name, rate in sorted(null_rates.items(), key=lambda x: -x[1]):
        bar  = "█" * int(rate / 5)
        flag = " ← HIGH" if rate > 50 else ""
        print(f"  {col_name:40s} {rate:6.1f}%  {bar}{flag}")

    # Cardinality
    print("\n--- Cardinality ---")
    for c in df.columns:
        n_dist = df.select(F.countDistinct(c)).collect()[0][0]
        ratio  = n_dist / total if total > 0 else 0
        tag    = " [key?]" if ratio > 0.99 else (" [cat]" if n_dist <= 50 else "")
        print(f"  {c:40s} {n_dist:>10,} distinct  ({ratio:.4f}){tag}")

    # Numeric summary
    numeric_cols = [f.name for f in df.schema.fields
                    if str(f.dataType) in ("DoubleType()", "FloatType()",
                                           "IntegerType()", "LongType()")]
    if numeric_cols:
        print("\n--- Numeric Summary (mean ± stddev  |  p25 / p50 / p75) ---")
        for c in numeric_cols:
            stats = df.select(
                F.mean(c).alias("mean"), F.stddev(c).alias("std"),
                F.skewness(c).alias("skew")
            ).collect()[0]
            p25, p50, p75 = df.approxQuantile(c, [0.25, 0.5, 0.75], 0.01)
            print(f"  {c:35s} "
                  f"mean={stats['mean']:>10.2f} ± {stats['std']:>10.2f}  "
                  f"| p25={p25:>10.2f}  p50={p50:>10.2f}  p75={p75:>10.2f}  "
                  f"skew={stats['skew']:+.2f}")

    # Top categoricals
    string_cols = [f.name for f in df.schema.fields if str(f.dataType) == "StringType()"]
    low_card = [c for c in string_cols
                if df.select(F.countDistinct(c)).collect()[0][0] <= 20]
    if low_card:
        print("\n--- Top Values (low-cardinality columns) ---")
        for c in low_card[:5]:   # cap at 5 to avoid flooding output
            top = df.groupBy(c).count().orderBy(F.col("count").desc()).limit(5).collect()
            top_str = "  |  ".join(f"{r[c]}={r['count']:,}" for r in top)
            print(f"  {c:35s} {top_str}")

    print(f"\n{'='*60}\n")


full_eda_report(df, table_name="orders_2024")
```

---

## EDA Decision Guide

| Observation | Implication |
|------------|-------------|
| Skewness > 1.0 on a join/groupBy key | Likely data skew — add salting or use AQE skewJoin |
| Cardinality ratio ≈ 1.0 on a column | Candidate primary key — validate uniqueness |
| Null rate > 80% | Consider dropping the column |
| Two columns with \|r\| > 0.95 | Multicollinearity — consider dropping one for ML features |
| Time-series gaps | Pipeline outage or late-arriving data — check upstream sources |
| Bimodal histogram (two peaks) | Two distinct sub-populations mixed — consider partitioning by a segmenting column |
| Kurtosis >> 3 | Heavy tails — outliers will be extreme; z-score detection unreliable, use IQR instead |
| `countDistinct` << `count` on supposed key | Duplicates exist — run dedup (file 29 Step 7) |
| `freqItems` finds a dominant value | Potential skew source — check partition distribution |
