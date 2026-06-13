<!-- PySpark-patterns: SCD Patterns -->

# SCD Patterns (Slowly Changing Dimensions)

## SCD Type 1 — Overwrite (No History)

Keep only the current value. Previous values are lost.

```python
from delta.tables import DeltaTable
from pyspark.sql import functions as F

# Using Delta MERGE
target = DeltaTable.forPath(spark, "/data/delta/customers/")

target.alias("t").merge(
    source_df.alias("s"),
    "t.customer_id = s.customer_id"
).whenMatchedUpdate(set={
    "name":       "s.name",
    "email":      "s.email",
    "region":     "s.region",
    "updated_at": "s.updated_at"
}).whenNotMatchedInsert(values={
    "customer_id": "s.customer_id",
    "name":        "s.name",
    "email":       "s.email",
    "region":      "s.region",
    "updated_at":  "s.updated_at"
}).execute()
```

SCD Type 1 is simple but irreversible — you lose historical attribute values.
Use when history is not needed (e.g., phone number lookup, status flags).

---

## SCD Type 2 — History (Keep All Versions)

Add `effective_date`, `expiry_date`, and `is_current` columns.
Each change creates a new row; the old row is expired.

### Table Structure

```sql
customer_id | name        | region | effective_date | expiry_date  | is_current
1           | Alice Smith | US     | 2023-01-01     | 2024-03-15   | false
1           | Alice Jones | US     | 2024-03-15     | 9999-12-31   | true
```

---

## SCD Type 2 with Delta MERGE

This pattern expires the current record and inserts the new version in one MERGE.

```python
from delta.tables import DeltaTable
from pyspark.sql import functions as F
from pyspark.sql.types import DateType

target = DeltaTable.forPath(spark, "/data/delta/dim_customer/")

# Source: new/changed records
# The MERGE uses a compound condition: match on business key AND is_current=true

(
    target.alias("t")
    .merge(
        source_df.alias("s"),
        "t.customer_id = s.customer_id AND t.is_current = true"
    )
    # When the current row exists and has CHANGED: expire it
    .whenMatchedUpdate(
        condition="t.region != s.region OR t.name != s.name OR t.email != s.email",
        set={
            "is_current":   "false",
            "expiry_date":  "s.effective_date"
        }
    )
    # When no current row exists: insert new record (also handles first-time inserts)
    .whenNotMatchedInsert(values={
        "customer_id":    "s.customer_id",
        "name":           "s.name",
        "email":          "s.email",
        "region":         "s.region",
        "effective_date": "s.effective_date",
        "expiry_date":    F.lit("9999-12-31"),
        "is_current":     F.lit(True)
    })
    .execute()
)

# After the MERGE, insert the new (current) version for expired rows
# Note: whenMatchedUpdate only expires the old row — we need a separate insert for the new version
# A common approach is to INSERT the new rows directly after the MERGE

new_rows = source_df.withColumn("expiry_date", F.lit("9999-12-31")) \
                    .withColumn("is_current", F.lit(True))

# Only insert rows that had a match (i.e., were changed) — identify by joining to target
changed = source_df.join(
    target.toDF().filter(F.col("is_current") == False)  # just expired rows
        .select("customer_id"),
    on="customer_id",
    how="inner"
)

changed.withColumn("expiry_date", F.lit("9999-12-31")) \
       .withColumn("is_current", F.lit(True)) \
       .write.format("delta").mode("append").save("/data/delta/dim_customer/")
```

**Simpler two-step approach (easier to reason about):**

```python
from pyspark.sql import Window

# Step 1: Identify what changed
current_target = spark.read.format("delta").load("/data/delta/dim_customer/") \
                      .filter(F.col("is_current") == True)

# Join to find changed records
changed = source_df.join(current_target, on="customer_id", how="inner") \
    .filter(
        (source_df["region"] != current_target["region"]) |
        (source_df["name"] != current_target["name"])
    ) \
    .select(source_df["customer_id"])

# Step 2: Expire old rows for changed records
target = DeltaTable.forPath(spark, "/data/delta/dim_customer/")
target.alias("t").merge(
    changed.alias("s"),
    "t.customer_id = s.customer_id AND t.is_current = true"
).whenMatchedUpdate(set={
    "is_current": "false",
    "expiry_date": F.lit(str(date.today()))
}).execute()

# Step 3: Insert new current rows
new_current = source_df.join(
    source_df.join(current_target, on="customer_id", how="left_anti"),  # truly new
    source_df.join(changed, on="customer_id", how="inner"),              # changed
    how="full"
)

# Simpler: insert all source rows as new current, rely on dedup downstream
source_df.withColumn("effective_date", F.current_date()) \
         .withColumn("expiry_date", F.lit("9999-12-31")) \
         .withColumn("is_current", F.lit(True)) \
         .write.format("delta").mode("append").save("/data/delta/dim_customer/")
```

---

## How Duplicates Break SCD

```python
# If source_df has two rows for the same customer_id:
# customer_id=1, name="Alice", effective_date=2024-01-01
# customer_id=1, name="Alice Smith", effective_date=2024-01-01

# MERGE inserts BOTH as "current" rows
# Result: two rows with is_current=true for customer_id=1

# Fix: dedup source before MERGE
source_df = source_df.dropDuplicates(["customer_id"])
# Or keep latest:
w = Window.partitionBy("customer_id").orderBy(F.col("effective_date").desc())
source_df = source_df \
    .withColumn("rn", F.row_number().over(w)) \
    .filter(F.col("rn") == 1) \
    .drop("rn")
```

---

## How NULLs Break SCD

```python
# NULL customer_id: MERGE condition "t.customer_id = s.customer_id" never matches NULL
# NULL rows always go to whenNotMatchedInsert
# Each run inserts a new NULL-key row — unbounded growth

# Fix 1: filter out NULL keys from source before MERGE
source_df = source_df.filter(F.col("customer_id").isNotNull())

# Fix 2: NULL-safe join condition
target.alias("t").merge(
    source_df.alias("s"),
    "t.customer_id <=> s.customer_id AND t.is_current = true"
    # <=> is NULL-safe equality in SQL
)
```

---

## SCD Type 2 ROW_NUMBER Approach (Batch, No Delta)

For non-Delta environments:

```python
from pyspark.sql import Window

# Combine existing history with new source
combined = existing_history.union(
    source_df.withColumn("effective_date", F.current_date())
             .withColumn("expiry_date", F.lit("9999-12-31"))
             .withColumn("is_current", F.lit(True))
)

# Rank and assign expiry dates
w = Window.partitionBy("customer_id").orderBy(F.col("effective_date").asc())

result = combined \
    .withColumn("next_effective", F.lead("effective_date").over(w)) \
    .withColumn("expiry_date",
        F.coalesce(F.col("next_effective"), F.lit("9999-12-31"))
    ) \
    .withColumn("is_current",
        F.when(F.col("expiry_date") == "9999-12-31", True).otherwise(False)
    ) \
    .dropDuplicates(["customer_id", "effective_date"])
```
