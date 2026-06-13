<!-- PySpark-patterns: UDFs and Performance -->

# UDFs and Performance

## UDF Performance Hierarchy (Slowest to Fastest)

1. **Python UDF** (`F.udf`) — row-by-row, JVM Python serialization via Pickle
2. **Pandas UDF** (`@F.pandas_udf`) — vectorized via Apache Arrow, batch processing
3. **Arrow UDF / Python UDF with Arrow** (Spark 3.5+) — fastest Python path
4. **Built-in Spark functions** (`F.upper`, `F.regexp_replace`, etc.) — stay in JVM, no Python

**Always prefer built-in functions.** Only reach for UDFs when the logic truly
cannot be expressed with built-in functions.

---

## Python UDF — Row-by-Row

```python
from pyspark.sql import functions as F
from pyspark.sql.types import StringType

def clean_phone(phone):
    if phone is None:
        return None
    return "".join(c for c in phone if c.isdigit())

clean_phone_udf = F.udf(clean_phone, StringType())

df.withColumn("phone_clean", clean_phone_udf(F.col("phone")))
```

### The Performance Cost

For each row:
1. Spark serializes (pickles) the row data from JVM to Python process
2. Python executes the function
3. Spark deserializes (unpickles) the result back to JVM

This serialization round-trip is 10–100x slower than equivalent built-in operations.
For a 100M row dataset, this is a significant bottleneck.

### Decorator style

```python
@F.udf(returnType=StringType())
def clean_phone(phone):
    if phone is None:
        return None
    return "".join(c for c in phone if c.isdigit())

df.withColumn("phone_clean", clean_phone(F.col("phone")))
```

---

## Pandas UDF — Vectorized via Arrow

Processes a batch of rows as a Pandas Series (or DataFrame), using Apache Arrow
for efficient data transfer between JVM and Python.

```python
import pandas as pd
from pyspark.sql import functions as F
from pyspark.sql.types import StringType

@F.pandas_udf(StringType())
def clean_phone_vectorized(phones: pd.Series) -> pd.Series:
    return phones.str.replace(r"[^\d]", "", regex=True).where(phones.notna(), other=None)

df.withColumn("phone_clean", clean_phone_vectorized(F.col("phone")))
```

### Pandas UDF for Multiple Input Columns

```python
from pyspark.sql.types import DoubleType

@F.pandas_udf(DoubleType())
def weighted_score(score: pd.Series, weight: pd.Series) -> pd.Series:
    return score * weight / 100.0

df.withColumn("result", weighted_score(F.col("score"), F.col("weight")))
```

### Pandas UDF for GroupBy (GroupedMap)

```python
from pyspark.sql.types import StructType, StructField, StringType, DoubleType

schema = StructType([
    StructField("group", StringType()),
    StructField("normalized_value", DoubleType())
])

@F.pandas_udf(schema, F.PandasUDFType.GROUPED_MAP)
def normalize_group(pdf: pd.DataFrame) -> pd.DataFrame:
    pdf["normalized_value"] = (pdf["value"] - pdf["value"].mean()) / pdf["value"].std()
    return pdf[["group", "normalized_value"]]

df.groupby("group").apply(normalize_group)
```

---

## When You MUST Use a UDF

- Complex regex or string parsing not achievable with built-in functions
- External library calls (e.g., spaCy NLP, custom ML inference)
- Stateful logic that requires Python objects
- Business rules too complex for `when().otherwise()` chains

Before writing a UDF, check these built-in alternatives:
```python
# Instead of UDF for string manipulation
F.regexp_replace, F.regexp_extract, F.split, F.substring

# Instead of UDF for conditionals
F.when().otherwise()

# Instead of UDF for math
F.pow, F.sqrt, F.log, F.abs, F.round

# Instead of UDF for type conversion
F.cast, F.to_date, F.to_timestamp, F.from_unixtime
```

---

## Registering UDFs for SQL

```python
spark.udf.register("clean_phone", clean_phone, StringType())

# Now usable in spark.sql()
spark.sql("SELECT clean_phone(phone) FROM customers")
```

---

## NULL Handling Inside UDFs

Python UDFs receive Python `None` for NULL inputs. If you don't handle it, you get:
- `TypeError` or `AttributeError` (e.g., `None.upper()`)
- Or the function returns a Python value when it should return None

```python
# BAD: fails if phone is NULL
@F.udf(StringType())
def bad_clean(phone):
    return "".join(c for c in phone if c.isdigit())  # TypeError: argument of type 'NoneType' is not iterable

# GOOD: explicit NULL guard at the top
@F.udf(StringType())
def good_clean(phone):
    if phone is None:
        return None
    return "".join(c for c in phone if c.isdigit())
```

For Pandas UDFs, NULLs come in as `pd.NA` or `np.nan` depending on the dtype.
Use `.where(series.notna(), other=None)` to propagate NULLs correctly.

---

## UDF Performance Tips

```python
# 1. Cache UDF results if the same UDF is called multiple times on the same column
df = df.withColumn("cleaned_phone", clean_phone_udf(F.col("phone")))
df.cache()   # avoid recomputing the UDF

# 2. Filter before UDF — reduce rows processed
df.filter(F.col("phone").isNotNull()) \
  .withColumn("cleaned_phone", clean_phone_udf(F.col("phone")))

# 3. Prefer Pandas UDF over Python UDF for numerical/string operations
# Pandas UDF is typically 5–10x faster than Python UDF

# 4. Use broadcast for lookup tables inside UDFs
lookup = {"US": "United States", "CA": "Canada"}  # Python dict
lookup_broadcast = spark.sparkContext.broadcast(lookup)

@F.udf(StringType())
def expand_country(code):
    if code is None:
        return None
    return lookup_broadcast.value.get(code, code)
```

---

## Arrow UDF (Spark 3.5+)

```python
spark.conf.set("spark.sql.execution.pythonUDF.arrow.enabled", "true")
# Regular Python UDFs automatically use Arrow serialization — faster without code changes
```

---

## Common Mistake: Non-Deterministic UDFs Without Flag

```python
import random

@F.udf(StringType())
def random_id(x):
    return str(random.randint(1, 1000))

# Spark may recompute this UDF differently across retry attempts
# Mark it as non-deterministic to prevent caching optimizations
random_id_udf = F.udf(random_id, StringType()).asNondeterministic()
```
