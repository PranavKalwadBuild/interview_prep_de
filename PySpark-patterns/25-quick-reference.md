<!-- PySpark-patterns: Quick Reference -->

# Quick Reference

## Standard Import Block

```python
from pyspark.sql import SparkSession, Window
from pyspark.sql import functions as F
from pyspark.sql.types import (
    StructType, StructField,
    StringType, IntegerType, LongType, DoubleType, FloatType,
    BooleanType, DateType, TimestampType, DecimalType,
    ArrayType, MapType
)
from delta.tables import DeltaTable
```

---

## SparkSession (Local / Test)

```python
spark = SparkSession.builder \
    .appName("job-name") \
    .config("spark.sql.shuffle.partitions", "200") \
    .config("spark.sql.adaptive.enabled", "true") \
    .getOrCreate()
```

---

## NULL-Safe Patterns

```python
# Check for NULL
F.col("x").isNull()
F.col("x").isNotNull()

# Never use == None
# WRONG: df.filter(F.col("x") == None)

# NULL-safe equality (NULL == NULL is TRUE)
F.col("a").eqNullSafe(F.col("b"))

# Replace NULL
F.coalesce(F.col("x"), F.lit("default"))
F.when(F.col("x").isNull(), F.lit("default")).otherwise(F.col("x"))
df.fillna({"x": "default", "amount": 0})

# NaN vs NULL
F.isnan(F.col("x"))          # True if NaN
F.nanvl(F.col("x"), F.lit(0.0))  # replace NaN, leave NULL

# Handle both NaN and NULL
F.when(F.isnan(F.col("x")) | F.col("x").isNull(), F.lit(0.0)).otherwise(F.col("x"))

# NULL-safe ORDER BY
F.col("x").asc_nulls_last()
F.col("x").desc_nulls_last()
```

---

## Dedup Template

```python
# Exact dedup
df.dropDuplicates(["key_col"])

# Keep latest by timestamp (ROW_NUMBER pattern)
from pyspark.sql import Window

w = Window.partitionBy("key_col").orderBy(F.col("updated_at").desc_nulls_last())
df_deduped = df \
    .withColumn("_rn", F.row_number().over(w)) \
    .filter(F.col("_rn") == 1) \
    .drop("_rn")
```

---

## Window Function Template

```python
from pyspark.sql import Window

# Ranking
w_rank = Window.partitionBy("dept").orderBy(F.col("salary").desc_nulls_last())
df.withColumn("rn",    F.row_number().over(w_rank))
df.withColumn("rnk",   F.rank().over(w_rank))
df.withColumn("dense", F.dense_rank().over(w_rank))

# Running total (explicit row frame — avoids default RANGE frame trap)
w_running = Window.partitionBy("customer_id") \
    .orderBy("txn_date") \
    .rowsBetween(Window.unboundedPreceding, Window.currentRow)
df.withColumn("running_total", F.sum("amount").over(w_running))

# LAG / LEAD
w_ordered = Window.partitionBy("id").orderBy("date")
df.withColumn("prev_val", F.lag("amount", 1).over(w_ordered))
df.withColumn("next_val", F.lead("amount", 1).over(w_ordered))

# Partition-wide aggregation (no orderBy, no frame)
w_part = Window.partitionBy("dept")
df.withColumn("dept_avg", F.avg("salary").over(w_part))
df.withColumn("dept_size", F.count("*").over(w_part))
```

---

## Broadcast Join Template

```python
# Explicit broadcast
result = large_df.join(F.broadcast(dim_df), on="id", how="left")

# Set broadcast threshold (auto-broadcast tables under this size)
spark.conf.set("spark.sql.autoBroadcastJoinThreshold", str(50 * 1024 * 1024))  # 50MB
```

---

## Join Cheat Sheet

```python
df1.join(df2, on="id",   how="inner")       # only matching rows
df1.join(df2, on="id",   how="left")        # all df1 rows, NULL for no match
df1.join(df2, on="id",   how="right")       # all df2 rows, NULL for no match
df1.join(df2, on="id",   how="full")        # all rows from both
df1.join(df2, on="id",   how="left_semi")   # df1 rows WITH match (no df2 cols)
df1.join(df2, on="id",   how="left_anti")   # df1 rows WITHOUT match
df1.join(df2, on=["a","b"], how="inner")    # multi-column join
df1.join(df2,
    on=(df1["id"] == df2["id"]) & (df1["date"] == df2["date"]),
    how="left")                              # expression join
```

---

## Delta MERGE Template (Upsert)

```python
from delta.tables import DeltaTable

target = DeltaTable.forPath(spark, "/path/to/delta/")

target.alias("t").merge(
    source_df.alias("s"),
    "t.id = s.id"
).whenMatchedUpdate(set={
    "col_a": "s.col_a",
    "col_b": "s.col_b",
    "updated_at": "s.updated_at"
}).whenNotMatchedInsert(values={
    "id":         "s.id",
    "col_a":      "s.col_a",
    "col_b":      "s.col_b",
    "updated_at": "s.updated_at"
}).execute()
```

---

## Delta Time Travel

```python
spark.read.format("delta").option("versionAsOf", 5).load(path)
spark.read.format("delta").option("timestampAsOf", "2024-01-01").load(path)
DeltaTable.forPath(spark, path).history().show()
```

---

## Most-Used Functions by Category

### String
```python
F.upper, F.lower, F.trim, F.ltrim, F.rtrim
F.concat_ws(",", F.col("a"), F.col("b"))
F.split(F.col("str"), ",")
F.regexp_replace, F.regexp_extract
F.substring(F.col("str"), 1, 5)
F.length, F.instr, F.lpad, F.rpad
F.sha2(F.col("col"), 256)
```

### Date / Time
```python
F.to_date(F.col("str"), "yyyy-MM-dd")
F.to_timestamp(F.col("str"), "yyyy-MM-dd HH:mm:ss")
F.date_add, F.date_sub, F.add_months
F.datediff(F.col("end"), F.col("start"))
F.date_trunc("month", F.col("ts"))
F.trunc(F.col("date"), "month")
F.year, F.month, F.dayofmonth, F.hour
F.from_unixtime(F.col("epoch"))
F.current_date(), F.current_timestamp()
```

### Conditional
```python
F.when(condition, value).when(...).otherwise(default)
F.coalesce(F.col("a"), F.col("b"), F.lit("default"))
F.nullif(F.col("x"), F.lit(0))   # returns NULL if x == 0
F.if_null(F.col("x"), F.lit(0))  # alias for coalesce(x, 0)
```

### Aggregation
```python
F.count("*"), F.count("col")
F.countDistinct("col")
F.approx_count_distinct("col", rsd=0.05)
F.sum, F.avg, F.min, F.max
F.stddev, F.variance
F.collect_list, F.collect_set
F.percentile_approx("col", 0.5)
F.first("col", ignorenulls=True)
```

### Array / Map
```python
F.explode, F.explode_outer, F.posexplode
F.array_contains, F.array_distinct, F.size
F.collect_list, F.sort_array
F.map_keys, F.map_values, F.map_from_arrays
```

---

## Performance One-Liners

```python
# Check plan
df.explain(mode="formatted")

# Count NULLs per column
df.select([F.count(F.when(F.col(c).isNull(), c)).alias(c) for c in df.columns]).show()

# Check for duplicates
print(df.count() - df.dropDuplicates(["key_col"]).count())

# Check fan-out from join
before = df1.count(); after = df1.join(df2, "id", "left").count()
print(f"Fan-out: {after/before:.2f}x")

# Partition size estimate
df.rdd.mapPartitions(lambda x: [sum(1 for _ in x)]).collect()

# Cache and materialize
df.cache(); df.count()
```
