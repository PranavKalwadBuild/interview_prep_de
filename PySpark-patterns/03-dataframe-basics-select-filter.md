<!-- PySpark-patterns: DataFrame Basics: Select and Filter -->

# DataFrame Basics: Select and Filter

## Column References — Three Styles

```python
from pyspark.sql import functions as F

# Style 1: F.col() — most portable, works anywhere
df.select(F.col("name"), F.col("age"))

# Style 2: df["col"] — tied to a specific DataFrame object
df.select(df["name"], df["age"])

# Style 3: df.col (attribute access) — shortest, most limited
df.select(df.name, df.age)
```

### When Each Style Breaks

**F.col() is always safe.** Use it by default.

**df["col"] breaks** when the DataFrame has been reassigned:
```python
df = df.withColumn("x", F.lit(1))
# The old df reference is now stale if used in a join expression
joined = df.join(other, df["id"] == other["id"])  # safe here, but risky in loops
```

**df.col breaks** when the column name conflicts with a DataFrame method:
```python
df.select(df.filter)   # AttributeError — "filter" is a method, not a column
df.select(df.count)    # same problem
```

**Ambiguous column after a join** — both styles break:
```python
joined = df1.join(df2, on="id")
joined.select("id")           # ambiguous if both df1 and df2 have "id"
# Fix: alias one of them before the join
df1 = df1.withColumnRenamed("id", "df1_id")
# Or use explicit column reference from the correct source
joined.select(df1["id"])      # works if df1 is still in scope
```

---

## .select() — Prefer Over Chained .withColumn()

`.select()` replaces the entire set of columns. One call, one projection.

```python
# GOOD: single .select() with all expressions
result = df.select(
    F.col("id"),
    F.col("name"),
    F.upper(F.col("email")).alias("email_upper"),
    (F.col("price") * 1.1).alias("price_with_tax"),
    F.coalesce(F.col("region"), F.lit("UNKNOWN")).alias("region")
)
```

### Why Chaining .withColumn() Is Slow

Each `.withColumn()` adds a projection node to the logical plan:

```python
# BAD: 50 .withColumn() calls = 50 projection nodes in the plan
df = df.withColumn("a", F.col("raw_a").cast("double"))
df = df.withColumn("b", F.col("raw_b").cast("double"))
# ... 48 more ...
df = df.withColumn("z", F.col("raw_z").cast("double"))
```

With many chained `.withColumn()` calls, the Catalyst optimizer must analyze a deeply
nested plan. This causes:
- Slow plan compilation (can take seconds just to build the plan)
- Potential StackOverflow on very long chains (50+ columns)
- No opportunity for the optimizer to collapse adjacent projections

```python
# GOOD: one .select() with all columns
df = df.select(
    *[F.col(f"raw_{c}").cast("double").alias(c) for c in "abcdefghijklmnopqrstuvwxyz"]
)
```

**Rule of thumb:** use `.withColumn()` for adding/modifying 1–3 columns.
Use `.select()` when changing many columns at once.

---

## .filter() / .where() — Predicate Pushdown

Both are identical — `.where()` is an alias for `.filter()`.

```python
df.filter(F.col("status") == "active")
df.where(F.col("status") == "active")   # same thing
```

### Combining Conditions

```python
# AND
df.filter((F.col("status") == "active") & (F.col("amount") > 100))

# OR
df.filter((F.col("region") == "US") | (F.col("region") == "CA"))

# NOT
df.filter(~F.col("is_deleted"))

# Multiple conditions (chained filter calls — equivalent, less common)
df.filter(F.col("status") == "active").filter(F.col("amount") > 100)
```

Parentheses around each condition are mandatory when using `&`, `|`, `~`.
Without parentheses, Python operator precedence causes bugs:
```python
# BUG: evaluated as F.col("status") == ("active" & F.col("amount") > 100)
df.filter(F.col("status") == "active" & F.col("amount") > 100)
```

### Predicate Pushdown to Parquet / Delta

Spark can push filters into the file scan when:
1. The filter is on a column stored in the file (not computed)
2. The format supports predicate pushdown (Parquet, ORC, Delta)
3. The filter is applied before any join or aggregation

```python
# Pushdown happens — filter on raw column before any transformation
df = spark.read.parquet("/data/sales") \
    .filter(F.col("date") >= "2024-01-01")

# Pushdown does NOT happen — filter on a computed column
df = spark.read.parquet("/data/sales") \
    .withColumn("date_str", F.col("date").cast("string")) \
    .filter(F.col("date_str") >= "2024-01-01")
```

For **partition-pruned reads** (Delta/Parquet written with `partitionBy`):
```python
# Reads only the 2024 partition folder — skips all other data on disk
df = spark.read.parquet("/data/sales") \
    .filter(F.col("year") == 2024)
```

Verify with `.explain()` — look for the filter inside the `FileScan` node.

---

## Projection Pruning

Spark only reads columns you actually select. On columnar formats (Parquet, ORC),
columns you don't select are not read from disk at all.

```python
# BAD: reads ALL columns from Parquet, then drops most
df = spark.read.parquet("/data/wide_table")   # 200 columns
result = df.select("id", "name", "amount")

# GOOD: select first — Spark prunes columns at scan time
result = spark.read.parquet("/data/wide_table").select("id", "name", "amount")
```

In practice, both produce the same physical plan via Catalyst optimization.
But being explicit makes intent clear and avoids accidentally carrying wide schemas
through a multi-step pipeline.

---

## Common Patterns

### Drop columns
```python
df.drop("col_to_remove", "another_col")
```

### Rename columns
```python
df.withColumnRenamed("old_name", "new_name")
# or in .select():
df.select(F.col("old_name").alias("new_name"), ...)
```

### Add a literal column
```python
df.withColumn("source", F.lit("salesforce"))
```

### Conditional column
```python
df.withColumn(
    "tier",
    F.when(F.col("amount") >= 10000, "gold")
     .when(F.col("amount") >= 1000, "silver")
     .otherwise("bronze")
)
```

### Select all columns plus a new one
```python
df.select("*", F.upper(F.col("name")).alias("name_upper"))
# or
df.withColumn("name_upper", F.upper(F.col("name")))
```
