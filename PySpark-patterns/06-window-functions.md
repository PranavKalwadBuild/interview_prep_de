<!-- PySpark-patterns: Window Functions -->

# Window Functions

## Window Spec Basics

```python
from pyspark.sql import Window
from pyspark.sql import functions as F

# Basic window: partition only (no ordering, no frame needed)
w = Window.partitionBy("department")

# With ordering: default frame applies (see below)
w = Window.partitionBy("department").orderBy("salary")

# Explicit frame
w = Window.partitionBy("department").orderBy("date") \
    .rowsBetween(Window.unboundedPreceding, Window.currentRow)
```

---

## The Default Frame Trap

When you specify `orderBy` in a window spec WITHOUT an explicit frame,
Spark uses `RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW`.

This is a range-based frame, not a row-based frame. It includes all rows with the
same ORDER BY value as the current row (ties).

```python
w = Window.partitionBy("dept").orderBy("salary")

# For ranking functions (row_number, rank, dense_rank): frame doesn't matter
df.withColumn("rn", F.row_number().over(w))

# For aggregations: the default RANGE frame causes unexpected results with ties
df.withColumn("running_sum", F.sum("salary").over(w))
# If two rows have salary=5000, BOTH are included in "current row's range"
# The running sum at both tie rows equals the sum including ALL ties — not a true running total
```

**Fix:** always specify the frame explicitly for running aggregations:

```python
# Row-based frame: each row is distinct regardless of value ties
w_running = Window.partitionBy("dept").orderBy("date") \
    .rowsBetween(Window.unboundedPreceding, Window.currentRow)

df.withColumn("running_sum", F.sum("amount").over(w_running))
```

---

## ROW_NUMBER, RANK, DENSE_RANK

```python
w = Window.partitionBy("department").orderBy(F.col("salary").desc())

df.withColumn("row_number", F.row_number().over(w))   # unique, sequential: 1, 2, 3, 4
df.withColumn("rank",       F.rank().over(w))         # gaps on ties: 1, 2, 2, 4
df.withColumn("dense_rank", F.dense_rank().over(w))   # no gaps: 1, 2, 2, 3
```

### Behavior with Ties

Given salaries: 9000, 8000, 8000, 7000:

| salary | row_number | rank | dense_rank |
|--------|-----------|------|------------|
| 9000   | 1         | 1    | 1          |
| 8000   | 2         | 2    | 2          |
| 8000   | 3         | 2    | 2          |
| 7000   | 4         | 4    | 3          |

`row_number()` with ties: the order between tied rows is non-deterministic.
Add a tiebreaker to the `orderBy` for deterministic results:

```python
w = Window.partitionBy("department") \
    .orderBy(F.col("salary").desc(), F.col("employee_id").asc())
```

### NULLs in ORDER BY

NULLs are placed at the END of ascending order (NULLS LAST) and at the START of descending
(NULLS FIRST) by default. This means a window ordered by `.desc()` puts NULLs first —
they get row_number = 1 even though they have no value.

Control explicitly:
```python
w = Window.partitionBy("dept") \
    .orderBy(F.col("salary").desc_nulls_last())   # NULLs get last rank
```

---

## Running Totals

```python
w_running = Window.partitionBy("customer_id") \
    .orderBy("txn_date") \
    .rowsBetween(Window.unboundedPreceding, Window.currentRow)

df.withColumn("running_balance", F.sum("amount").over(w_running))
```

`rowsBetween` uses physical row positions (ignores value).
`rangeBetween` uses value offsets (e.g., rows within 7 days of current).

---

## LAST_VALUE Trap

`last_value()` with a window ordered by some column only sees up to the current row
by default (because of the default RANGE frame). It does NOT look ahead.

```python
# BUG: last_value only looks up to current row — returns current row's value
w = Window.partitionBy("id").orderBy("date")
df.withColumn("last_status", F.last("status").over(w))  # wrong

# FIX: extend frame to unbounded following
w_full = Window.partitionBy("id").orderBy("date") \
    .rowsBetween(Window.unboundedPreceding, Window.unboundedFollowing)
df.withColumn("last_status", F.last("status").over(w_full))  # correct
```

Same issue applies to `first_value()` in descending order — be explicit.

---

## LAG and LEAD

```python
w = Window.partitionBy("customer_id").orderBy("txn_date")

# Previous row's value (1 row back)
df.withColumn("prev_amount", F.lag("amount", 1).over(w))

# Next row's value (1 row forward)
df.withColumn("next_amount", F.lead("amount", 1).over(w))

# With default for boundary rows (first/last row where lag/lead has no value)
df.withColumn("prev_amount", F.lag("amount", 1, 0).over(w))  # default 0 instead of NULL
```

---

## Other Useful Window Functions

```python
w = Window.partitionBy("dept").orderBy("salary")

F.percent_rank().over(w)                        # 0.0 to 1.0
F.ntile(4).over(w)                              # divide into N buckets (quartiles = ntile(4))
F.cume_dist().over(w)                           # cumulative distribution
F.sum("amount").over(w_running)                 # running sum
F.avg("amount").over(w_running)                 # running average
F.count("*").over(Window.partitionBy("dept"))   # partition size (no orderBy needed)
```

---

## Scale: Window Functions and OOM

Window functions require the entire partition to be in memory on one executor.

**If one partition is too large:**
- The executor runs out of memory and spills to disk (slow) or crashes (OOM)
- There is no parallel processing within a partition for window functions

**Diagnosis:** Spark UI -> Stages -> find the window stage -> look at partition sizes.

**Fix: pre-filter before windowing**

```python
# Instead of windowing over all-time data, window only over recent data
df.filter(F.col("date") >= "2024-01-01") \
    .withColumn("rn", F.row_number().over(w))
```

**Fix: partition on high-cardinality keys**

```python
# BAD: one partition per region (low cardinality = few large partitions)
w = Window.partitionBy("region").orderBy("date")

# GOOD: partition by customer_id (high cardinality = many small partitions)
w = Window.partitionBy("customer_id").orderBy("date")
```

If you need a global window (no partition key), Spark puts ALL data in one partition.
This is almost always an OOM waiting to happen on large datasets.
