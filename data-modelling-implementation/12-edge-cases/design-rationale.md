# Edge Cases — Rationale

Companion to `01-edge-cases.sql`. Explains the *why* behind each handling
strategy and the interview talking points.

---

## 1. Late-Arriving Facts

### The risk
SCD Type 2 dimensions maintain history by writing a new row whenever a tracked
attribute changes. Each row has an `effective_date`, `expiry_date`, and
`is_current` flag. If an ETL job uses `is_current = 1` to look up the surrogate
key for a late-arriving fact, it picks up the *current* dimension state —
not the state that existed when the business event occurred.

Example: emp 7 earned $6,500 in January 2024. In March 2024 they were promoted
(new SCD2 row, new `employee_sk`, `is_current = 1`). Loading the January payment
using `is_current = 1` links it to the *March* row. Every historical report now
shows the January salary under the post-promotion job title and department —
permanent data corruption that is hard to detect and costly to fix.

### The fix: effective-date window lookup
```sql
WHERE emp_id = 7
  AND effective_date  <= '<fact_date>'
  AND (expiry_date    >  '<fact_date>' OR expiry_date IS NULL)
```
This returns exactly one SCD2 row — the one valid on the date the business event
occurred. `<fact_date>` = the last day of the pay period (or the event date for
other fact types).

### If no row matches
The dimension was not populated correctly for that date (a gap in SCD2 coverage).
Do **not** fall back to `is_current = 1`. Instead: raise a data-quality alert,
load the fact with a sentinel `employee_sk = 0` ("Unknown Employee"), and
investigate the ETL gap separately.

### Missing dim_date dates
If the pay date does not exist in `dim_date` (invalid date, pre-loaded range
exceeded), use a sentinel `date_sk = 19000101` ("Unknown Date"). This keeps the
FK valid and the fact row loaded. Filter out the sentinel in reports
(`WHERE pay_date_sk != 19000101`).

---

## 2. NULL Handling Policy

### Three-layer approach (Bronze / Silver / Gold)

| Layer | NULL policy |
|---|---|
| **Bronze** (raw landing) | Preserve source NULLs exactly — no transformation |
| **Silver** (cleansed / conformed) | Fill semantically meaningful defaults (e.g., `status = 'Unknown'` where status is never truly absent). Do NOT fill numeric measures — a NULL salary is not $0. |
| **Gold / DW** (dimensional model) | Use sentinel rows for FK columns; preserve NULLs in measure columns; apply COALESCE only at query/report time |

### NULL in dimension attributes
Preserve NULLs in the dimension table. `budget = NULL` (Executive dept) means
"budget not yet approved" — replacing it with 0 is factually wrong. Apply
`COALESCE(budget, 0)` only in the presentation layer, with a descriptive label.

### NULL in fact measures
SQL aggregate functions (`SUM`, `AVG`) skip NULLs automatically per ANSI SQL.
This is correct behaviour — a NULL salary should not be counted as $0 in payroll
totals. Always include a parallel `COUNT(salary_amount)` vs `COUNT(*)` audit
to surface how many rows have NULL measures.

---

## 3. Sentinel / Unknown Member Rows

### Why they are required
Every nullable FK column in a fact table must resolve to a valid dimension row.
If a fact row has `dept_id = NULL` in the source and the ETL writes `dept_sk = NULL`
into the fact:
- JOINs to `dim_department` silently drop the row (`NULL != any dept_sk`).
- `GROUP BY dept_sk` produces a NULL group that many BI tools hide or mislabel.
- Referential integrity constraints cannot be enforced.

### Standard sentinel values

| Sentinel value | Meaning |
|---|---|
| `0` | Unknown — the value exists in source but was not captured |
| `-1` | Not Applicable — the dimension does not apply to this fact row |
| `-2` | Not Provided — the source system explicitly omitted the value |

Create one sentinel row per dimension table, once, during warehouse setup.
ETL uses `COALESCE(looked_up_sk, <sentinel_sk>)` to ensure no NULL FK reaches
the fact table.

### Verification query (run after every ETL load)
```sql
SELECT COUNT(*) FROM fact_salary_payment WHERE dept_sk     IS NULL;
SELECT COUNT(*) FROM fact_salary_payment WHERE employee_sk IS NULL;
SELECT COUNT(*) FROM fact_salary_payment WHERE pay_date_sk IS NULL;
-- All must return 0.
```

---

## 4. Partitioning Strategy

### Facts: partition by time dimension
- Use `PARTITION BY RANGE (pay_year)` for annual fact tables.
- Use `PARTITION BY RANGE (YEAR(pay_date))` or composite range if the
  table needs monthly granularity.
- Effect: a `WHERE pay_year = 2023` query skips all other partitions
  ("partition pruning"), reducing I/O proportionally.
- MySQL constraint: the partition column must be part of every UNIQUE KEY
  (including the PRIMARY KEY). Adjust PKs accordingly.

### Dimensions: no partitioning
Dimension tables are small (hundreds to low millions of rows) and are
almost always accessed via a PK or surrogate-key lookup. Partition overhead
exceeds the benefit. Use standard B-tree indexes instead.

### Index priorities (fact tables)
1. FK columns used in JOINs (`employee_sk`, `dept_sk`, `pay_date_sk`)
2. Composite index on time columns (`pay_year`, `pay_month`) for range scans
3. Covering indexes for the most frequent reporting query shapes

### Index priorities (dim_employee)
- `(emp_id, is_current)` — satisfies the most common ETL lookup pattern
- `(emp_id, effective_date, expiry_date)` — satisfies the late-arriving-fact
  window lookup without a full table scan

---

## 5. Skew Mitigation

### In a Kimball MySQL warehouse
Skew (Engineering dept = 34% of employees) is a query planner concern.
Proper indexes mean most queries never full-scan the fact table by dept.
Skew only matters for full-table aggregations — ensure the `dept_sk` index
is in place and GROUP BY queries use it.

### In distributed / Spark environments
The same 34% skew causes one partition to receive 34% of the data during
a shuffle while others receive ~8%. This creates stragglers that slow the
entire job to the speed of the heaviest partition.

**Mitigation options:**

| Technique | How it works | Trade-off |
|---|---|---|
| **Salting** | Append `RAND() * N` suffix to dept_sk, shuffle into more buckets, aggregate partial sums, then sum again | Two-pass aggregation; more complex code |
| **Broadcast join** | Keep `dim_department` small enough to broadcast to all executors | No shuffle for the dim join; eliminates dept-skew in join steps |
| **Sub-partitioning** | Partition facts by `(dept_sk, pay_month)` instead of only `dept_sk` | More even partition sizes; effective if months are uniform |
| **Adaptive query execution (AQE)** | Spark 3.0+ auto-splits skewed partitions at runtime | Transparent; enable with `spark.sql.adaptive.enabled=true` |

---

## 6. Interview Question: Late-Arriving Facts

**"How would you handle a fact that arrives 3 months late after the dimension
has already been updated?"**

Structured answer:

1. **Identify the risk**: the dimension is SCD Type 2. Three months ago the
   employee may have changed jobs, departments, or salary bands. Using `is_current = 1`
   links the late fact to the wrong historical context — corrupting every
   historical report permanently.

2. **Correct approach**: use the effective-date window lookup on `dim_employee`:
   `effective_date <= <event_date> AND (expiry_date > <event_date> OR expiry_date IS NULL)`.
   This returns the dimension row that was valid when the event occurred.

3. **If no matching row**: raise a data-quality alert. Load with a sentinel
   employee_sk. Do not guess or use the current row.

4. **Prevent recurrence**: add a pipeline check that compares the fact's
   event date against the dimension's covered date range. Alert if coverage
   gaps exist before loading.

5. **Downstream**: re-run any downstream aggregations (fact_monthly_headcount,
   BI dashboards) that covered the affected time period, since they were built
   without the late fact.
