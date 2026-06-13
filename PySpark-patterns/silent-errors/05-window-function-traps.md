<!-- Part of PySpark-patterns: Silent Errors — Window Function Traps -->

# Silent Errors — Window Function Traps

Window functions are semantically complex. The interaction between `partitionBy`, `orderBy`,
and frame specification (`rowsBetween` / `rangeBetween`) is non-obvious. Adding `orderBy` to
a window spec silently changes the default frame. Omitting `orderBy` for lag/lead makes results
non-deterministic. These bugs pass all unit tests on small deterministic data and only manifest
at scale with partition-level randomness.

---

### 1. Window Without `orderBy` — Non-Deterministic `lag()` / `lead()`

**What it looks like:**
```python
w = Window.partitionBy("customer_id")
df.withColumn("prev_amount", F.lag("amount").over(w)).show()
```

**What actually happens:**
`lag()` and `lead()` require a defined ordering to have meaning. Without `orderBy`, the "previous"
row is whichever row the executor places first in the partition — which depends on the shuffle
hash, partition layout, and task scheduling. Different runs produce different results. No warning.
Spark does issue a warning in some versions (`WARN WindowExec: No Partition Defined for Window
operation!`) but it does not prevent execution.

**Why it's insidious:**
On a single-partition test dataset sorted by insertion order, `lag()` without `orderBy` produces
correct-looking results consistently. At scale with multiple partitions and a real shuffle, the
order within each partition is arbitrary, and the lag values are meaningless.

**Minimal repro:**
```python
from pyspark.sql import Window
import pyspark.sql.functions as F

w_no_order = Window.partitionBy("id")
df = spark.createDataFrame([(1, 10), (1, 20), (1, 30)], ["id", "val"])
df.withColumn("prev", F.lag("val").over(w_no_order)).show()
# Runs 1 and 2 may produce different "prev" values
```

**How to catch it:**
```python
# Lint check: flag any Window spec used with lag/lead/row_number/rank that has no orderBy
def validate_window_spec(window_spec, func_name):
    if func_name in ("lag", "lead", "row_number", "rank", "dense_rank"):
        # Inspect if orderSpec is empty
        assert window_spec._orderSpec, f"{func_name} requires orderBy in window spec"
```

**Real-world trigger:**
A session analytics pipeline computes time-between-events with `lag(timestamp)`. Without
`orderBy`, the "previous" timestamp is arbitrary. Session duration is silently wrong for all
multi-event sessions, but passes QA because the average looks plausible.

---

### 2. Default Frame Changes Silently When `orderBy` Is Added

**What it looks like:**
```python
# Intent: sum of all rows in the partition
w = Window.partitionBy("dept")
df.withColumn("dept_total", F.sum("salary").over(w)).show()

# Refactored: add orderBy for "nicer" output
w = Window.partitionBy("dept").orderBy("hire_date")
df.withColumn("dept_total", F.sum("salary").over(w)).show()
```

**What actually happens:**
Without `orderBy`, the default window frame is `ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED
FOLLOWING` — the entire partition. `sum("salary")` gives the partition total for every row.

With `orderBy`, the default frame changes to `RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW`
— a running cumulative sum. `sum("salary")` now gives the cumulative sum up to the current
`hire_date`, not the partition total.

The refactoring silently changed partition total → cumulative sum with no error.

**Why it's insidious:**
The code change looks like a cosmetic improvement (adding ordering for readability). The semantic
change — from partition aggregate to running aggregate — is invisible unless the developer knows
the default frame behavior. Unit tests on 3-row DataFrames may still pass if the last row
happens to equal the partition total.

**Minimal repro:**
```python
df = spark.createDataFrame([(1, "eng", 100), (1, "eng", 200), (1, "eng", 300)], ["id", "dept", "sal"])
w_unordered = Window.partitionBy("dept")
w_ordered   = Window.partitionBy("dept").orderBy("id")

df.withColumn("total_unordered", F.sum("sal").over(w_unordered)).show()
# All rows: 600

df.withColumn("total_ordered", F.sum("sal").over(w_ordered)).show()
# Row 1: 100, Row 2: 300, Row 3: 600  ← running sum, not total!
```

**How to catch it:**
Always specify the frame explicitly when the intent is partition-total:
```python
w = Window.partitionBy("dept").orderBy("hire_date").rowsBetween(
    Window.unboundedPreceding, Window.unboundedFollowing
)
```

**Real-world trigger:**
A compensation analysis pipeline computes each employee's salary as a percentage of department
total. An orderBy is added to sort by seniority. The denominator silently becomes a running sum;
all percentages except the last row in each department are wrong.

---

### 3. `rowsBetween` vs `rangeBetween` Tie Handling

**What it looks like:**
```python
w = Window.partitionBy("user_id").orderBy("event_date").rangeBetween(-7, 0)
df.withColumn("rolling_7d", F.sum("amount").over(w)).show()
```

**What actually happens:**
`rangeBetween(-7, 0)` means "rows where the ORDER BY value is within 7 units of the current
row's value." If `event_date` is a date and multiple rows have the same date, ALL rows on that
date are included in every row's window for that date. This is value-based and includes ties.

`rowsBetween(-7, 0)` means "the 7 rows physically preceding this row in partition order."
It never includes extra rows due to ties.

For a rolling 7-day window, `rangeBetween(-7, 0)` on a numeric day offset is correct.
For a "previous 7 rows" window, `rowsBetween(-7, 0)` is correct. They are not interchangeable,
and using the wrong one silently changes which rows are included.

**Why it's insidious:**
On data with no ties in the ORDER BY column, both produce the same result. Ties only appear with
high-frequency data (multiple transactions per second, per day). The bug is invisible in unit
tests with unique timestamps and only manifests in production at scale.

**Minimal repro:**
```python
df = spark.createDataFrame([
    (1, "2024-01-01", 100), (1, "2024-01-01", 200),  # same date
    (1, "2024-01-02", 50)
], ["user", "date", "amount"])

w_range = Window.partitionBy("user").orderBy(F.col("date").cast("int")).rangeBetween(0, 0)
w_rows  = Window.partitionBy("user").orderBy(F.col("date").cast("int")).rowsBetween(0, 0)

df.withColumn("range_sum", F.sum("amount").over(w_range)).show()
# date=2024-01-01: range_sum=300 for BOTH rows (includes tie partner)
df.withColumn("rows_sum", F.sum("amount").over(w_rows)).show()
# date=2024-01-01: rows_sum=100 and 200 separately
```

**How to catch it:**
Document the semantic intent of every window frame. Add a comment on whether "ties should be
included." Verify with a dataset that has intentional duplicate ORDER BY values.

**Real-world trigger:**
A risk model computes a 1-day rolling transaction sum with `rangeBetween(0, 0)` to flag same-day
spikes. On days with many transactions, the "sum for this row" includes all transactions on the
same day, not just the current one. All same-day transactions exceed the threshold simultaneously,
generating false alerts.

---

### 4. `first()` / `last()` Without `ignorenulls=True` on Unordered Window

**What it looks like:**
```python
w = Window.partitionBy("account_id").orderBy("event_ts")
df.withColumn("first_status", F.first("status").over(w)).show()
```

**What actually happens:**
`F.first()` on a window with `orderBy` returns the value from the first row *in frame order*.
But the default frame is `RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW`. For the first row
in the partition, the frame contains only that row — so `first()` returns the current row's
value, not the partition's first value. For the second row, the frame includes rows 1 and 2,
and `first()` returns row 1's value. This is correct for cumulative "first" semantics.

The trap: `F.first()` without `ignorenulls=True` returns NULL if the first row in the frame is
NULL — silently. The intent was usually to get the first non-NULL value.

**Minimal repro:**
```python
df = spark.createDataFrame([(1, None, 1), (1, "active", 2), (1, "closed", 3)], ["id", "status", "seq"])
w = Window.partitionBy("id").orderBy("seq")
df.withColumn("first_status", F.first("status").over(w)).show()
# Row 1: NULL (first in frame is NULL — not skipped)
# Row 2: NULL (first in frame — same NULL row 1 — still not skipped)
```

**How to catch it:**
```python
# Explicitly set ignorenulls
df.withColumn("first_status", F.first("status", ignorenulls=True).over(w))
```

**Real-world trigger:**
A SCD2 history table tracks account status changes. The first event for new accounts has
`status = NULL` (setup in progress). A window function to get the "first confirmed status"
returns NULL for all rows in an account's history until the NULL row is gone, silently missing
the first real status change.

---

### 5. `row_number()` With Ties: Non-Deterministic Assignment

**What it looks like:**
```python
w = Window.partitionBy("customer_id").orderBy("purchase_date")
df.withColumn("rn", F.row_number().over(w)).filter(F.col("rn") == 1)
```

**What actually happens:**
When multiple rows have the same `purchase_date` (ties in the ORDER BY), `row_number()` assigns
ranks 1, 2, 3... to them arbitrarily. Which row gets rank 1 is non-deterministic — it depends on
the physical order of rows in the partition, which changes with data size, shuffle configuration,
and cluster layout.

**Why it's insidious:**
On a deterministic test dataset (one row per date), `row_number()` is correct. In production
with high-volume dates (Black Friday: thousands of purchases on the same day), which purchase is
"first" changes each run. Machine learning features derived from "first purchase attributes" have
silent instability.

**How to catch it:**
```python
# Add a tiebreaker column to make row_number deterministic
w = Window.partitionBy("customer_id").orderBy("purchase_date", "transaction_id")  # unique tiebreaker
df.withColumn("rn", F.row_number().over(w))

# Detect ties in production
tie_count = df.groupBy("customer_id", "purchase_date").count().filter(F.col("count") > 1).count()
assert tie_count == 0, f"{tie_count} tie groups detected — add tiebreaker to orderBy"
```

**Real-world trigger:**
A loyalty program pipeline assigns "first purchase date" using `row_number()`. On promotional
dates, thousands of customers make their first purchase simultaneously (same date, high ties).
Points are awarded to an arbitrary "first" transaction; the others get the "returning customer"
rate silently.

---

### 6. Partition Explosion From High-Cardinality `partitionBy`

**What it looks like:**
```python
w = Window.partitionBy("user_id", "session_id")   # 10M unique combinations
df.withColumn("event_rank", F.row_number().over(w)).write.parquet(...)
```

**What actually happens:**
Each unique partition key creates a separate physical partition during the window shuffle. 10M
unique (user_id, session_id) combinations = 10M shuffle partitions. Each partition writes to
disk independently. The executor handles 10M tiny files; the write produces 10M Parquet files.
No error. But subsequent reads on that path are catastrophically slow (10M file metadata lookups),
and the shuffle itself may OOM on the coordinator.

**Why it's insidious:**
The window function produces correct results. The silent damage is to the storage layer and
downstream read performance. The bug surfaces weeks later when a downstream team tries to read
the output path.

**How to catch it:**
```python
# Estimate partition cardinality before window operations
partition_count = df.select("user_id", "session_id").distinct().count()
print(f"Window partition cardinality: {partition_count:,}")
if partition_count > 1_000_000:
    print("WARNING: High-cardinality window partition may produce too many shuffle files")
```

**Real-world trigger:**
A clickstream pipeline partitions window functions by `(user_id, session_id, page_id)`. 5M daily
users × 3 sessions each × 10 pages = 150M window partitions. The Spark job produces 150M
Parquet files; Delta Lake compaction runs for 12 hours; the table is unreadable until OPTIMIZE.

---

### 7. `LAST_VALUE` Without Frame Specification Returns Current Row

**What it looks like:**
```python
w = Window.partitionBy("account_id").orderBy("event_date")
df.withColumn("last_status", F.last("status").over(w)).show()
```

**What actually happens:**
With the default frame (`RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW`), `last()` returns
the last value *in the current frame* — which is the current row's value itself. The frame never
extends beyond the current row with the default. So `last()` is equivalent to `F.col("status")`
here — it doesn't get the last value in the partition.

**Why it's insidious:**
The intent is "what is the final status for this account" for every row. The actual result is
"what is the current row's status." Both look plausible; the first few rows where status is
changing look identical. The bug is only visible at the end of a sequence where the "last" status
differs from intermediate statuses.

**How to catch it:**
Always use `Window.unboundedFollowing` explicitly when the intent is "last in partition":
```python
w = Window.partitionBy("account_id").orderBy("event_date").rowsBetween(
    Window.unboundedPreceding, Window.unboundedFollowing
)
df.withColumn("last_status", F.last("status").over(w))
```

**Real-world trigger:**
A customer lifecycle model backfills "final account state" for all historical events. The `last()`
without explicit unbounded frame returns the current row's state for every event, not the final
state. The model is trained on "current state" features, not "final outcome" labels — the entire
target variable is wrong.

---

### 8. Window Function on Large Skewed Partition Causes Silent OOM

**What it looks like:**
```python
w = Window.partitionBy("country").orderBy("timestamp")
df.withColumn("running_revenue", F.sum("revenue").over(w)).write.parquet(...)
```

**What actually happens:**
All rows for "US" (60% of the data) must be shuffled to the same executor partition for the
window computation. That single partition holds 60% of the dataset in memory during the sort-
and-compute phase. The executor OOMs. Spark retries on other executors; if they also OOM,
the job fails — but only after the other 40% has been written. With speculation or partial
writes enabled, you may get a partially written output that looks complete.

**Why it's insidious:**
The bug surfaces on the largest partition in production but passes tests on sampled data. The
partial write scenario means the output path exists but contains only the non-US rows — silently
incomplete.

**How to catch it:**
```python
# Check partition cardinality before window ops
df.groupBy("country").count().orderBy(F.col("count").desc()).show(5)
# If top partition > 10% of total rows, consider salting or pre-aggregation
```

**Real-world trigger:**
A global revenue window function partitioned by region. The "North America" region contains
70% of all rows. The executor allocated 32GB for the task runs out of memory. The job is retried
3 times; on the 4th attempt, the North America partition is split by salting and the job completes
— but the first 3 attempts have already written partial results to intermediate paths.
