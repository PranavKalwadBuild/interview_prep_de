<!-- PySpark-patterns: NULL Handling -->

# NULL Handling

## The Core Rule

NULL represents the absence of a value. Any operation on NULL returns NULL.
This is three-valued logic: TRUE, FALSE, NULL (unknown).

```python
from pyspark.sql import functions as F

# These all return NULL, not True or False
NULL == NULL   -> NULL
NULL != NULL   -> NULL
NULL > 5       -> NULL
NULL + 5       -> NULL
```

---

## Filtering NULLs — Never Use == None

```python
# WRONG: Python None comparison — evaluates at plan build time, not at runtime
df.filter(F.col("x") == None)         # always returns empty DataFrame
df.filter(F.col("x") != None)         # always returns all rows

# CORRECT
df.filter(F.col("x").isNull())        # rows where x IS NULL
df.filter(F.col("x").isNotNull())     # rows where x IS NOT NULL
```

Why `== None` is wrong: Python evaluates `F.col("x") == None` as a Column object
with a Python None comparison, which does not translate to SQL `IS NULL`.

---

## NULLs in Aggregations

```python
# Given: values = [1, NULL, 3, NULL, 5]
F.sum("col")    # = 9    (NULLs ignored)
F.avg("col")    # = 3.0  (9/3, denominator is non-NULL count)
F.count("col")  # = 3    (NULLs not counted)
F.count("*")    # = 5    (counts all rows including NULL rows)
F.min("col")    # = 1    (NULLs ignored)
F.max("col")    # = 5    (NULLs ignored)
```

If all values in a group are NULL:
- `sum`, `avg`, `min`, `max` return NULL
- `count("col")` returns 0

---

## NULLs in Joins

NULL keys never match — even NULL == NULL is NULL (not TRUE) in SQL logic.

```python
df1 = spark.createDataFrame([(1, "a"), (None, "b")], ["id", "val"])
df2 = spark.createDataFrame([(1, "x"), (None, "y")], ["id", "val2"])

df1.join(df2, "id", "inner").show()
# Only (1, "a", "x") — the NULL rows do NOT match
```

For NULL-safe matching:
```python
df1.join(df2, df1["id"].eqNullSafe(df2["id"]), "inner")
# Now (None, "b", "y") is also returned
```

---

## F.coalesce() vs F.when().otherwise()

### coalesce — first non-NULL wins

```python
# Returns the first non-NULL argument
F.coalesce(F.col("primary"), F.col("fallback"), F.lit("default"))
```

Use `coalesce` when you want to substitute a fallback column or literal.

### when/otherwise — conditional logic

```python
F.when(F.col("status").isNull(), F.lit("UNKNOWN")) \
 .otherwise(F.col("status"))

# Multiple conditions
F.when(F.col("amount") > 1000, "high") \
 .when(F.col("amount") > 100, "medium") \
 .otherwise("low")

# .otherwise() is optional — omitting it returns NULL for unmatched rows
F.when(F.col("flag") == 1, "active")  # returns NULL when flag != 1
```

---

## isnull() vs Python None Check

```python
F.isnull(F.col("x"))        # same as F.col("x").isNull() — correct
F.col("x").isNull()         # correct
F.col("x") == None          # WRONG — see above

# Python None in literals
F.lit(None)                 # creates a NULL literal column (correct)
F.coalesce(F.col("x"), F.lit(None))  # coalesce with NULL literal — returns x (pointless but valid)
```

---

## NULL-Safe Equality: eqNullSafe()

```python
# Standard equality: NULL == NULL is NULL (not TRUE)
df.filter(F.col("a") == F.col("b"))         # NULL rows excluded

# NULL-safe equality: NULL == NULL is TRUE
df.filter(F.col("a").eqNullSafe(F.col("b")))  # NULL rows included when both are NULL
```

---

## NaN vs NULL

NaN (Not a Number) is a valid IEEE 754 float value. NULL is the absence of a value.
They are completely different in Spark.

```python
import math

# NaN is a float value
df.withColumn("x", F.lit(float("nan")))   # x = NaN, not NULL

# Checking
F.isnan(F.col("x"))         # True if NaN
F.col("x").isNull()         # False — NaN is not NULL

# Aggregation behavior
# NaN propagates in arithmetic: NaN + 5 = NaN
# sum() does NOT skip NaN — if any value is NaN, sum is NaN
```

### nanvl() — Replace NaN but Not NULL

```python
F.nanvl(F.col("x"), F.lit(0.0))   # replaces NaN with 0.0, leaves NULL as NULL
```

### Handle Both NaN and NULL

```python
df.withColumn("x_clean",
    F.when(F.isnan(F.col("x")) | F.col("x").isNull(), F.lit(0.0))
     .otherwise(F.col("x"))
)
```

---

## F.fillna() and df.na.fill()

Both `fillna()` and `na.fill()` replace NULL AND NaN for numeric columns.

```python
# Replace all NULLs with 0 in numeric columns
df.fillna(0)

# Replace NULLs in specific columns
df.fillna({"amount": 0, "region": "UNKNOWN", "status": "active"})

# Equivalent using na.fill()
df.na.fill(0, subset=["amount", "price"])
```

**Warning:** `fillna(0)` on a string column has no effect.
`fillna("UNKNOWN")` on a numeric column has no effect. Types must match.

---

## NULL in ORDER BY

```python
# Ascending: NULLs appear LAST by default
df.orderBy(F.col("salary").asc())            # NULLs last
df.orderBy(F.col("salary").asc_nulls_last()) # explicit NULLS LAST

# Descending: NULLs appear FIRST by default
df.orderBy(F.col("salary").desc())             # NULLs first
df.orderBy(F.col("salary").desc_nulls_last())  # push NULLs to end

# Options: .asc_nulls_first(), .asc_nulls_last(), .desc_nulls_first(), .desc_nulls_last()
```

---

## Scale: NULL-Heavy Columns and Performance

- **Statistics:** Spark uses column statistics for join planning and AQE.
  NULL-heavy columns have skewed statistics — Spark may underestimate or overestimate data size.

- **Predicate pushdown:** Parquet/Delta stores min/max per column chunk.
  If a column is 90% NULL, min/max may be misleading and filter pushdown is less effective.

- **Sort behavior:** NULLs cluster at the start or end depending on order direction.
  Sorting NULL-heavy columns can create skewed partitions post-sort.

- **Audit NULLs in your pipeline:**

```python
# Count NULLs per column
from pyspark.sql import functions as F

null_counts = df.select([
    F.count(F.when(F.col(c).isNull(), c)).alias(c)
    for c in df.columns
])
null_counts.show()
```
