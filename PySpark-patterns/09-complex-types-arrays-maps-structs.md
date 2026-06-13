<!-- PySpark-patterns: Complex Types: Arrays, Maps, Structs -->

# Complex Types: Arrays, Maps, Structs

## Defining Complex Types in Schema

```python
from pyspark.sql.types import (
    StructType, StructField, StringType, IntegerType,
    ArrayType, MapType, LongType
)
from pyspark.sql import functions as F

schema = StructType([
    StructField("id", StringType(), True),
    StructField("tags", ArrayType(StringType()), True),           # array of strings
    StructField("metadata", MapType(StringType(), StringType()), True),  # map<string, string>
    StructField("address", StructType([                            # nested struct
        StructField("city", StringType(), True),
        StructField("zip", StringType(), True)
    ]), True)
])
```

---

## Accessing Nested Fields

```python
# Accessing struct fields
df.select("address.city")
df.select(F.col("address.city"))
df.select(F.col("address")["city"])   # bracket notation

# Accessing array element by index (0-based)
df.select(F.col("tags")[0])           # first element

# Accessing map value by key
df.select(F.col("metadata")["source"])
```

---

## explode() vs explode_outer()

`explode()` creates one row per array/map element.

```python
df = spark.createDataFrame([
    (1, ["a", "b", "c"]),
    (2, None),             # NULL array
    (3, [])                # empty array
], ["id", "tags"])

df.select("id", F.explode("tags").alias("tag")).show()
# id=1 -> rows for "a", "b", "c"
# id=2 -> DROPPED (explode drops NULL arrays)
# id=3 -> DROPPED (explode drops empty arrays)
```

`explode_outer()` keeps rows with NULL or empty arrays (produces a single NULL row).

```python
df.select("id", F.explode_outer("tags").alias("tag")).show()
# id=1 -> rows for "a", "b", "c"
# id=2 -> one row with tag=NULL
# id=3 -> one row with tag=NULL
```

**Rule:** use `explode_outer` when you can't lose parent rows. Use `explode` when
NULL/empty arrays should be filtered out naturally.

---

## posexplode() — Explode with Position Index

```python
df.select("id", F.posexplode("tags").alias("pos", "tag")).show()
# id=1: (0, "a"), (1, "b"), (2, "c")
```

Useful when you need to reconstruct the original array order.

---

## Array Functions

```python
F.array("col1", "col2", "col3")          # create array from columns
F.array_contains(F.col("tags"), "sale")  # True/False/NULL if element exists
F.array_distinct(F.col("tags"))          # remove duplicates from array
F.array_intersect(F.col("a"), F.col("b"))  # elements in both arrays
F.array_union(F.col("a"), F.col("b"))    # all elements from both (deduplicated)
F.array_except(F.col("a"), F.col("b"))  # elements in a but not in b
F.array_remove(F.col("tags"), "old")     # remove specific value
F.array_sort(F.col("tags"))              # sort array ascending
F.sort_array(F.col("tags"), asc=False)  # sort descending
F.size(F.col("tags"))                   # array length (-1 if NULL for size(), 0 for cardinality())
F.cardinality(F.col("tags"))            # array length (NULL if array is NULL)
F.flatten(F.col("nested_array"))        # flatten array of arrays
F.array_zip(F.col("a"), F.col("b"))     # zip two arrays into array of structs
F.slice(F.col("tags"), 1, 3)            # slice(array, start (1-based), length)
F.element_at(F.col("tags"), 1)          # element at position (1-based), NULL-safe
F.arrays_overlap(F.col("a"), F.col("b"))  # True if any element in common
```

---

## Map Functions

```python
F.map_keys(F.col("metadata"))            # array of keys
F.map_values(F.col("metadata"))          # array of values
F.map_from_arrays(F.col("keys"), F.col("vals"))  # create map from two arrays
F.map_contains_key(F.col("meta"), "src") # True if key exists (Spark 3.3+)
F.map_filter(F.col("meta"), lambda k, v: v.isNotNull())  # filter map entries
F.map_concat(F.col("m1"), F.col("m2"))  # merge two maps (m2 overwrites m1 on key conflict)
F.element_at(F.col("metadata"), "key")  # access map value by key (NULL if missing)
F.explode(F.col("metadata"))            # creates key, value columns — one row per entry
```

---

## Struct Functions

```python
# Create a struct
df.withColumn("location", F.struct(F.col("city"), F.col("zip")))

# Access struct fields
df.select("location.city")

# Update a struct field (must recreate the struct)
df.withColumn("location",
    F.struct(
        F.upper(F.col("location.city")).alias("city"),
        F.col("location.zip")
    )
)

# Convert struct to map
# (requires schema to be known — usually done in Scala; in Python use custom logic)
```

---

## Creating Arrays and Maps from Existing Data

```python
# Array from multiple columns
df.withColumn("scores", F.array(F.col("q1"), F.col("q2"), F.col("q3")))

# Map from two array columns
df.withColumn("score_map",
    F.map_from_arrays(
        F.array(F.lit("q1"), F.lit("q2"), F.lit("q3")),
        F.array(F.col("q1"), F.col("q2"), F.col("q3"))
    )
)

# Collect values into array within a group
df.groupBy("order_id").agg(F.collect_list("item").alias("items"))
```

---

## How Complex Types Break at Scale

### Schema inference with JSON/semi-structured data

```python
# Spark infers schema by sampling — can get it wrong
df = spark.read.json("/path/to/data")  # schema inferred from sample
# If the sample doesn't include all fields or types vary, inference is wrong

# Fix: provide explicit schema
df = spark.read.schema(my_schema).json("/path/to/data")
```

### Parquet nesting limits

Parquet supports nested types, but very deep nesting (5+ levels) can cause:
- Schema complexity in downstream tools (Athena, Snowflake, etc.)
- Slow schema resolution
- Compatibility issues with some readers

Flatten before writing to Parquet for wide compatibility:
```python
df.select(
    "id",
    F.col("address.city").alias("address_city"),
    F.col("address.zip").alias("address_zip")
)
```

### Large arrays in explode

If arrays contain millions of elements, `explode()` produces millions of rows per input row.
Always check array size distribution before exploding:

```python
df.select(F.size("tags").alias("tag_count")).describe().show()
```
