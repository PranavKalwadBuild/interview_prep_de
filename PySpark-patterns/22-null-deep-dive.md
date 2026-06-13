<!-- PySpark-patterns: NULL Deep Dive -->

# NULL Deep Dive

## Three-Valued Logic

SQL (and PySpark) uses three-valued logic: TRUE, FALSE, NULL (unknown).
Any operation with a NULL operand returns NULL, which is neither TRUE nor FALSE.

```python
# In a WHERE/filter clause: only rows where the condition is TRUE pass through
# Rows where the condition is NULL are excluded (same as FALSE)

df.filter(F.col("amount") > 100)
# Rows with amount=NULL are EXCLUDED — the comparison returns NULL, not FALSE
```

---

## NULL Behavior Matrix

### Filters

```python
F.col("x") == 5        # NULL x → NULL (row excluded)
F.col("x") != 5        # NULL x → NULL (row excluded)
F.col("x") > 5         # NULL x → NULL (row excluded)
F.col("x").isNull()    # NULL x → TRUE (row included)
F.col("x").isNotNull() # NULL x → FALSE (row excluded)
~F.col("x").isNull()   # NULL x → FALSE (row excluded)
```

### Arithmetic

```python
F.col("a") + F.col("b")     # NULL a or b → NULL
F.col("a") * F.col("b")     # NULL a or b → NULL
F.col("a") / F.col("b")     # NULL a or b → NULL; b=0 → NULL (no ZeroDivisionError)
F.col("a") / 0               # → NULL (not an error in Spark SQL)
```

### Boolean Logic

```python
# AND: NULL AND TRUE = NULL, NULL AND FALSE = FALSE
# OR:  NULL OR TRUE = TRUE,  NULL OR FALSE = NULL
# NOT: NOT NULL = NULL

# Practical impact:
df.filter((F.col("a") == 1) & (F.col("b") == 2))
# If a=1 and b=NULL: condition is NULL → row excluded
# If a=NULL and b=2: condition is NULL → row excluded
```

---

## NULL in JOIN Keys

NULL keys never match in any join (NULL != NULL returns NULL, not TRUE).

```python
# Neither of these NULL rows will match each other
df1 = spark.createDataFrame([(None, "a")], ["id", "val1"])
df2 = spark.createDataFrame([(None, "b")], ["id", "val2"])
df1.join(df2, "id", "inner").count()   # 0 rows

# NULL-safe join: NULL == NULL is TRUE
df1.join(df2, df1["id"].eqNullSafe(df2["id"]), "inner").count()  # 1 row
```

### Checking for "match failure" in a left join

```python
# Left join: rows from df1 that did NOT match
result = df1.join(df2, "id", "left")
unmatched = result.filter(F.col("val2").isNull())
# But careful: val2 could also be NULL in a matched row if the source had NULLs
# Better: use left anti join
unmatched = df1.join(df2, "id", "left_anti")
```

---

## NULL in Aggregations

```python
# values = [1, NULL, 3, NULL, 5]
F.sum("x")    # 9   (NULLs ignored)
F.avg("x")    # 3.0 (9/3, denominator = non-NULL count)
F.count("x")  # 3   (non-NULL count)
F.count("*")  # 5   (all rows)
F.min("x")    # 1
F.max("x")    # 5
F.stddev("x") # stddev of [1,3,5] = 2.0

# GROUP BY: NULLs ARE grouped together (unlike JOIN where NULL != NULL)
df.groupBy("region").count()
# Rows with region=NULL are grouped into one "NULL group"
```

**This is one of the few places NULL == NULL is TRUE in PySpark — GROUP BY keys.**

---

## NULL in Window Functions

```python
from pyspark.sql import Window

# NULL in PARTITION BY key: rows with NULL key form their own partition
w = Window.partitionBy("region")  # NULL region rows are one partition

# NULL in ORDER BY: default behavior differs by direction
w_asc  = Window.partitionBy("dept").orderBy(F.col("salary").asc())   # NULLs last
w_desc = Window.partitionBy("dept").orderBy(F.col("salary").desc())  # NULLs first

# Explicit control:
w = Window.partitionBy("dept").orderBy(F.col("salary").asc_nulls_first())
w = Window.partitionBy("dept").orderBy(F.col("salary").desc_nulls_last())

# LAG/LEAD: returns NULL at boundaries AND when source value is NULL
F.lag("amount", 1).over(w)   # NULL for first row in partition
                              # NULL if the lagged row's amount is NULL
```

---

## NaN vs NULL

NaN (Not a Number) is a valid IEEE 754 float value. NULL is absence of value.

```python
import math

# Create NaN vs NULL
df = spark.createDataFrame([
    (1, float("nan"), None),
    (2, 0.0,          0.0),
    (3, 1.0,          1.0)
], ["id", "x_nan", "x_null"])

# Checking
F.isnan(F.col("x_nan"))         # True  for NaN, False for others
F.col("x_nan").isNull()         # False for NaN (NaN is a value, not NULL)
F.col("x_null").isNull()        # True  for NULL

# Aggregation behavior:
# sum() propagates NaN: sum([1.0, NaN, 2.0]) = NaN
# sum() ignores NULL:  sum([1.0, NULL, 2.0]) = 3.0
```

### Handling Both

```python
# Replace both NaN and NULL with 0
df.withColumn("x_clean",
    F.when(F.isnan(F.col("x")) | F.col("x").isNull(), F.lit(0.0))
     .otherwise(F.col("x"))
)

# df.fillna() fills both NaN and NULL for numeric columns
df.fillna({"x": 0.0})

# F.nanvl() replaces NaN but NOT NULL
F.nanvl(F.col("x"), F.lit(0.0))   # NaN → 0.0, NULL stays NULL
```

---

## NULL in UDFs

```python
# Python UDF receives None for NULL inputs — must handle explicitly
@F.udf("string")
def safe_upper(s):
    if s is None:
        return None          # propagate NULL
    return s.upper()

# Pandas UDF: NULL comes as pd.NA or np.nan depending on dtype
@F.pandas_udf("string")
def safe_upper_vec(s: pd.Series) -> pd.Series:
    return s.str.upper()    # pandas str methods handle NaN automatically (return NaN)
```

---

## NULL in Complex Types

```python
# Array: NULL element vs NULL array
F.array(F.lit(1), F.lit(None), F.lit(3))   # [1, NULL, 3] — NULL inside array
F.col("arr").isNull()                        # True only if the whole array is NULL

# Accessing NULL array element
F.col("arr")[0]      # NULL if arr is NULL, or if arr[0] is NULL
F.element_at("arr", 1)  # NULL-safe access (Spark 3.0+)

# Explode: NULL array → row dropped (use explode_outer to keep)
F.explode(F.col("arr"))         # drops rows where arr is NULL
F.explode_outer(F.col("arr"))   # keeps row with NULL for arr
```

---

## Detecting NULL Propagation Bugs

```python
# After a chain of transformations, audit for unexpected NULLs
def null_audit(df, columns):
    null_counts = df.select([
        F.count(F.when(F.col(c).isNull(), c)).alias(f"{c}_nulls")
        for c in columns
    ])
    null_counts.show()

null_audit(result_df, ["revenue", "customer_id", "region"])
```

If a column has unexpected NULLs, trace back which transformation introduced them
by adding `.filter(F.col("suspicious_col").isNull())` after each step.
