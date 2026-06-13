<!-- Part of PySpark-patterns: Silent Errors — NULL and NaN Traps -->

# Silent Errors — NULL and NaN Traps

NaN and NULL are distinct types in Spark. Most engineers treat them interchangeably, which is
wrong. NULL is SQL's three-valued logic sentinel; NaN is an IEEE 754 floating-point bit pattern.
They propagate differently, sort differently, aggregate differently, and are detected differently.
Every confusion between them is a potential silent wrong result.

---

### 1. `filter(col == float('nan'))` Returns Zero Rows

**What it looks like:**
```python
df = spark.createDataFrame([(float('nan'),), (1.0,), (2.0,)], ["x"])
df.filter(F.col("x") == float('nan')).count()   # expected: 1
```

**What actually happens:**
IEEE 754 defines `NaN != NaN` as `True`. Any equality comparison with NaN returns False — even
comparing NaN to itself. `col("x") == float('nan')` evaluates to False for every row, including
the row that actually contains NaN. The filter silently returns 0 rows.

**Why it's insidious:**
This is correct IEEE 754 behavior, but it violates programmer intuition. Engineers who write
null-checks using equality (`== None`) then extend the pattern to NaN and silently miss every
NaN row.

**Minimal repro:**
```python
df = spark.createDataFrame([(float('nan'),), (1.0,)], ["x"])
print(df.filter(F.col("x") == float('nan')).count())   # 0 — wrong
print(df.filter(F.isnan(F.col("x"))).count())           # 1 — correct
```

**How to catch it:**
Use `F.isnan()` for NaN detection, `F.isNull()` for NULL detection, and combine them for full
missing-value coverage:
```python
df.filter(F.isnan("x") | F.col("x").isNull())
```

**Real-world trigger:**
A data quality gate that checks for missing user IDs with `filter(col("user_id") == None)`.
Works for NULL but silently passes NaN user IDs through to the downstream join, which then
fails to match any records.

---

### 2. `dropna()` Does Not Drop NaN Values

**What it looks like:**
```python
df = spark.createDataFrame([(float('nan'),), (None,), (1.0,)], ["x"])
df.dropna().show()   # expected: only row with 1.0
```

**What actually happens:**
`dropna()` (and `df.na.drop()`) operates on SQL NULLs only. NaN values are a valid IEEE 754
floating-point number — they are not NULL in Spark's type system. After `dropna()`, the NaN row
is still present in the DataFrame. Only the `None` row is removed.

**Why it's insidious:**
`dropna()` is the standard PySpark idiom for "remove missing data." Engineers assume it covers
all missing representations. NaN values survive `dropna()` and flow downstream, causing NaN
propagation in aggregations.

**Minimal repro:**
```python
df = spark.createDataFrame([(float('nan'),), (None,), (1.0,)], ["x"])
result = df.dropna()
result.show()
# Only shows: 1.0 and float('nan')  ← NaN survives
```

**How to catch it:**
```python
# Complete missing-value removal
df_clean = (df
    .replace(float('nan'), None)   # convert NaN to NULL first
    .dropna()                       # then drop NULL
)
```

**Real-world trigger:**
A feature engineering pipeline that applies `dropna()` to remove sparse rows before model
training. NaN features survive, causing XGBoost to produce `NaN` predictions for those rows.
The model appears to train successfully; inference silently returns NaN scores.

---

### 3. `fillna()` Does Not Fill NaN in DoubleType Columns

**What it looks like:**
```python
df = spark.createDataFrame([(float('nan'),), (None,), (1.0,)], ["x"])
df.fillna(0.0, subset=["x"]).show()
```

**What actually happens:**
`fillna()` (and `df.na.fill()`) fills SQL NULLs with the specified value. NaN in a DoubleType
column is not NULL — it remains NaN after `fillna()`. Only the `None` row is replaced with 0.0.

**Why it's insidious:**
`fillna(0)` is the standard "impute missing values with 0" idiom. Engineers apply it and assume
all missing values are covered. NaN values silently pass through and propagate into aggregations.

**Minimal repro:**
```python
df = spark.createDataFrame([(float('nan'),), (None,), (2.0,)], ["x"])
result = df.fillna(0.0)
result.show()
# nan: still nan (not filled)
# None: 0.0 (filled correctly)
# 2.0: 2.0
```

**How to catch it:**
```python
# Replace NaN explicitly before fillna
df_clean = df.replace(float('nan'), None).fillna(0.0)
# Or use when/otherwise
df_clean = df.withColumn("x", F.when(F.isnan("x"), 0.0).otherwise(F.col("x")).alias("x")).fillna(0.0)
```

**Real-world trigger:**
A revenue imputation pipeline that fills missing revenue with 0 before computing daily totals.
NaN revenue rows survive; the sum returns NaN for the entire day's total — a single NaN
propagates to corrupt the entire aggregation result.

---

### 4. `F.mean()` / `F.sum()` NaN Propagation

**What it looks like:**
```python
df = spark.createDataFrame([(1.0,), (float('nan'),), (3.0,)], ["x"])
df.agg(F.mean("x")).show()   # expected: 2.0
```

**What actually happens:**
`F.mean()` and `F.sum()` in Spark SQL treat NaN as a regular number. A single NaN in the column
causes the entire aggregation to return NaN. This is different from NULL, which is excluded from
aggregations.

**Why it's insidious:**
NULL-containing columns aggregate correctly (NULLs are excluded). NaN-containing columns produce
NaN for the entire aggregation. If data from a source silently switches from using NULL to using
NaN for missing values (e.g., after a library upgrade), aggregations that were computing correct
means suddenly start returning NaN.

**Minimal repro:**
```python
# NULL version — aggregates correctly
df_null = spark.createDataFrame([(1.0,), (None,), (3.0,)], ["x"])
df_null.agg(F.mean("x")).show()   # 2.0

# NaN version — aggregation is corrupted
df_nan = spark.createDataFrame([(1.0,), (float('nan'),), (3.0,)], ["x"])
df_nan.agg(F.mean("x")).show()    # NaN
```

**How to catch it:**
```python
# Check for NaN before aggregation
nan_count = df.filter(F.isnan("x")).count()
if nan_count > 0:
    df = df.replace(float('nan'), None)   # normalize NaN to NULL
df.agg(F.mean("x")).show()
```

**Real-world trigger:**
A data vendor changes their API response format. Previously, missing numeric values were `null`
in JSON; after an API upgrade, they emit `"NaN"` (as a string). Spark parses this as the float
NaN. All aggregation metrics suddenly return NaN. The pipeline reports no errors.

---

### 5. `when(condition, value)` With No `otherwise()` Returns NULL for Unmatched Rows

**What it looks like:**
```python
df = df.withColumn("tier",
    F.when(F.col("spend") > 1000, "gold")
     .when(F.col("spend") > 500, "silver")
     # No .otherwise()
)
```

**What actually happens:**
For all rows where `spend <= 500`, the `when()` expression evaluates to NULL. There is no
default branch. If NULL is a valid-looking sentinel for "bronze" tier in the downstream system,
the bug is invisible until a query explicitly checks for it.

**Why it's insidious:**
NULL looks like missing data, not like a deliberate code omission. A downstream `GROUP BY tier`
will create a separate NULL group with all the unmatched rows. Any join on `tier` will lose
those rows (NULLs don't match in equi-joins). The `otherwise()` omission is visually subtle —
especially in long `when()` chains.

**Minimal repro:**
```python
df = spark.createDataFrame([(200,), (600,), (1200,)], ["spend"])
result = df.withColumn("tier", F.when(F.col("spend") > 1000, "gold").when(F.col("spend") > 500, "silver"))
result.show()
# spend=200 → tier=null  ← silent NULL
```

**How to catch it:**
```python
# Always add .otherwise() — even if it's .otherwise(F.lit(None)) to make the intent explicit
result = df.withColumn("tier",
    F.when(F.col("spend") > 1000, "gold")
     .when(F.col("spend") > 500, "silver")
     .otherwise("bronze")   # explicit default
)
# Validate no unexpected NULLs post-assignment
assert result.filter(F.col("tier").isNull()).count() == 0
```

**Real-world trigger:**
A pricing engine that applies tier-based discounts. The `otherwise()` was accidentally omitted
for the "standard" tier. Standard-tier customers receive NULL discounts. Downstream, NULL
propagates through discount arithmetic, and standard-tier invoices show no discount applied —
but also no error.

---

### 6. NULL in `GROUP BY` Key Creates a Separate Group Silently

**What it looks like:**
```python
df = spark.createDataFrame([
    ("US", 100), ("UK", 200), (None, 50), (None, 75)
], ["country", "revenue"])
result = df.groupBy("country").agg(F.sum("revenue").alias("total"))
result.show()
```

**What actually happens:**
Rows with `country = NULL` form their own group with `total = 125`. This is correct SQL behavior
(GROUP BY treats NULL as a single group key). However, engineers who assume NULL rows are
excluded from GROUP BY get wrong total counts and wrong per-group sums.

**Why it's insidious:**
The NULL group is a legitimate row in the output. If you sum the "total" column, you include the
NULL-country revenue. If you join the result to a country dimension table, the NULL group is
lost (no match). The discrepancy between grouped totals and the source total reveals the bug —
but only if someone checks.

**How to catch it:**
```python
# Check for NULL group in GROUP BY output
null_group = result.filter(F.col("country").isNull())
if null_group.count() > 0:
    print(f"WARNING: NULL group exists with {null_group.collect()[0]['total']} total revenue")
```

**Real-world trigger:**
A regional revenue report that groups by country. NULL-country rows (from users who didn't
provide location) form a silent group. The "grand total" row in the report does not match the
actual sum of country totals — the NULL group revenue is unaccounted for.

---

### 7. `countDistinct` on Column With NULLs: Inconsistent Behavior Across Contexts

**What it looks like:**
```python
df = spark.createDataFrame([("a",), ("b",), (None,), ("a",)], ["x"])
df.agg(F.countDistinct("x")).show()
```

**What actually happens:**
`countDistinct` excludes NULLs from the distinct count — this is standard SQL behavior. The
result is 2 (`"a"` and `"b"`), not 3. However, `approx_count_distinct` may or may not include
NULLs depending on the implementation version. If the column is expected to have NULLs for
unknown users, the distinct count silently understates the true cardinality.

**Why it's insidious:**
Rate calculations like CTR (clicks / unique users) use distinct counts in the denominator. If
NULLs represent real users whose IDs weren't captured, excluding them silently inflates the CTR.

**How to catch it:**
```python
# Explicit NULL handling in distinct count
total_distinct = df.agg(F.countDistinct("x")).collect()[0][0]
null_count = df.filter(F.col("x").isNull()).count()
true_distinct = total_distinct + (1 if null_count > 0 else 0)
print(f"Distinct (excluding NULL): {total_distinct}, including NULL group: {true_distinct}")
```

**Real-world trigger:**
A DAU (Daily Active Users) metric that uses `countDistinct("user_id")`. Users who are logged
out have `user_id = NULL`. They are all excluded from the distinct count. DAU is systematically
understated by the anonymous user population.

---

### 8. Three-Valued Logic in Filter: NOT(NULL) Is NULL, Not True

**What it looks like:**
```python
df = spark.createDataFrame([(1, True), (2, False), (3, None)], ["id", "is_active"])
df.filter(~F.col("is_active")).show()   # expected: rows 2 and 3
```

**What actually happens:**
In three-valued SQL logic, `NOT(NULL)` evaluates to `NULL`, not `True`. The filter
`~col("is_active")` with NULL produces NULL, which is treated as False in filter predicates.
Row 3 is silently excluded from the result.

**Why it's insidious:**
In Python, `not None` evaluates to `True`. Spark (SQL semantics) evaluates `NOT(NULL)` to
`NULL`, which is falsy in a filter. The two languages have opposite behavior for the same
looking expression.

**Minimal repro:**
```python
df = spark.createDataFrame([(1, True), (2, False), (3, None)], ["id", "flag"])
df.filter(~F.col("flag")).show()   # only row 2; row 3 (NULL) is silently excluded
```

**How to catch it:**
```python
# Null-safe NOT filter
df.filter(~F.col("flag") | F.col("flag").isNull())
# Or use eqNullSafe
df.filter(F.col("flag").eqNullSafe(False))
```

**Real-world trigger:**
A churn model that filters for "not confirmed subscribers" (`~col("is_confirmed")`). Users with
NULL confirmation status (signed up but not confirmed) are silently excluded. The churn model
never sees unconfirmed users; predictions for that cohort are never generated.

---

### 9. `min()` and `max()` With NaN: Spark vs Python Behavior Divergence

**What it looks like:**
```python
from pyspark.sql.functions import min as spark_min, max as spark_max
df = spark.createDataFrame([(1.0,), (float('nan'),), (3.0,)], ["x"])
df.agg(spark_min("x"), spark_max("x")).show()
```

**What actually happens:**
In Spark SQL, `min()` and `max()` treat NaN as greater than any other value. So `min(1.0, NaN, 3.0)`
returns `1.0` and `max(1.0, NaN, 3.0)` returns `NaN`. This is different from Python's `min()`
(which returns 1.0 by ignoring NaN in some versions) and from Pandas' `min()` (which skips NaN
by default). The inconsistency across tools makes it easy to develop wrong intuitions.

**Why it's insidious:**
A column range check `max("x") < threshold` returns `False` when NaN is present (because NaN
is treated as +infinity), even if all real values are below the threshold. The validation gate
fires incorrectly.

**How to catch it:**
```python
# Always normalize NaN before range comparisons
df_clean = df.replace(float('nan'), None)
df_clean.agg(F.min("x"), F.max("x")).show()   # NaN excluded, correct range
```

**Real-world trigger:**
A data quality check that validates sensor readings are within `[0, 100]` using
`max("reading") <= 100`. A faulty sensor emits NaN. The check returns `False` (NaN treated as
> 100), triggering a false alert and blocking valid data from being processed.

---

### 10. NULL Propagation in Arithmetic — Silent Cascading Nullification

**What it looks like:**
```python
df = spark.createDataFrame([(100, None, 0.1)], ["revenue", "cost", "tax_rate"])
df.withColumn("profit", F.col("revenue") - F.col("cost")).show()
df.withColumn("final", F.col("profit") * (1 - F.col("tax_rate"))).show()
```

**What actually happens:**
`revenue - cost` → NULL (because `cost` is NULL). `NULL * (1 - 0.1)` → NULL. A single NULL
in `cost` cascades through the entire calculation chain silently, producing NULL for `final`.
If `final` is used in a SUM aggregation, that row's entire contribution is lost.

**Why it's insidious:**
The NULL propagation is silent and spans multiple transformation steps. The original NULL in
`cost` may be obvious; its effect on `final` three `withColumn` steps later is not.

**Minimal repro:**
```python
df = spark.createDataFrame([(100, None)], ["a", "b"])
df.withColumn("c", F.col("a") - F.col("b")).withColumn("d", F.col("c") * 2).show()
# c=NULL, d=NULL — entire chain nullified
```

**How to catch it:**
```python
# Audit for unexpected NULL propagation
for col_name in ["profit", "final"]:
    null_pct = df.filter(F.col(col_name).isNull()).count() / df.count()
    if null_pct > 0.05:
        print(f"WARNING: {col_name} has {null_pct:.1%} NULLs — check upstream sources")
```

**Real-world trigger:**
A P&L pipeline where `cost` is populated from a late-arriving feed. For the first hour of each
day, `cost` is NULL for all rows. The daily profit calculation is entirely NULL for that hour's
data, causing the daily total to undercount revenue silently.
