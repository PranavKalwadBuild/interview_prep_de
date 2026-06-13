<!-- Part of sql-patterns: Edge Case Detection — SQL Execution Order + Core Pattern Edge Cases (Part 1) -->
<!-- Source: sql_patterns.md lines 12330–12600 -->

## 33. Edge Case Detection — Where and How Queries Break

Every pattern in this guide has failure modes that are silent — no error, wrong results, reported with confidence. This section catalogs them by pattern with the exact input data that triggers the break, the engine-level explanation, and the fix. All examples use fintech/banking context (Slice-type workloads).

---

### 33-0. SQL Order of Execution — Edge Cases

#### Edge 0-A: Using a SELECT alias in WHERE

**Problem:**

```sql
-- BREAKS: alias 'fee' computed in SELECT, which runs AFTER WHERE
SELECT txn_amount * 0.02 AS fee, user_id
FROM transactions
WHERE fee > 100;           -- ERROR: column "fee" does not exist

-- Why: WHERE runs at step 2; SELECT at step 5. 'fee' doesn't exist yet.
```

**Fix A — repeat the expression:**

```sql
WHERE txn_amount * 0.02 > 100
```

**Fix B — wrap in CTE (CTE runs before main SELECT):**

```sql
WITH fees AS (SELECT *, txn_amount * 0.02 AS fee FROM transactions)
SELECT * FROM fees WHERE fee > 100;
```

#### Edge 0-B: Filtering on a window function result in WHERE

**Problem:**

```sql
-- BREAKS: window functions execute in SELECT (step 5), WHERE runs at step 2
SELECT *, ROW_NUMBER() OVER (PARTITION BY user_id ORDER BY executed_at DESC) AS rn
FROM trades
WHERE rn = 1;              -- ERROR: column "rn" does not exist
```

**Fix — wrap in CTE:**

```sql
WITH ranked AS (
    SELECT *, ROW_NUMBER() OVER (PARTITION BY user_id ORDER BY executed_at DESC) AS rn
    FROM trades
)
SELECT * FROM ranked WHERE rn = 1;

-- Snowflake/BigQuery/DuckDB alternative:
SELECT * FROM trades
QUALIFY ROW_NUMBER() OVER (PARTITION BY user_id ORDER BY executed_at DESC) = 1;
```

#### Edge 0-C: Aggregate in WHERE instead of HAVING

**Problem:**

```sql
-- BREAKS: COUNT(*) is an aggregate; aggregates not allowed in WHERE
SELECT user_id, COUNT(*) AS txn_count
FROM transactions
WHERE COUNT(*) > 10        -- ERROR: aggregate functions not allowed in WHERE
GROUP BY user_id;
```

**Fix — move to HAVING:**

```sql
SELECT user_id, COUNT(*) AS txn_count
FROM transactions
GROUP BY user_id
HAVING COUNT(*) > 10;
```

#### Edge 0-D: GROUP BY alias (engine-specific silently wrong behavior)

**Problem:**

```sql
-- Breaks in PostgreSQL/Redshift: GROUP BY runs before SELECT, alias unknown
SELECT DATE_TRUNC('month', txn_date) AS month, COUNT(*) AS txn_count
FROM transactions
GROUP BY month;        -- ERROR in PostgreSQL / Redshift

-- Works silently in MySQL and BigQuery (they allow GROUP BY aliases)
-- This query runs fine in MySQL but breaks in PostgreSQL — cross-engine trap
```

**Fix — repeat the full expression:**

```sql
GROUP BY DATE_TRUNC('month', txn_date)

-- Or use positional grouping (both safe):
GROUP BY 1
```

#### Edge 0-E: LEFT JOIN silently converted to INNER JOIN by WHERE filter

**Problem:**

```sql
-- BREAKS: WHERE on right-table column rejects NULL rows → LEFT JOIN becomes INNER JOIN
SELECT l.loan_id, l.amount, r.repaid_amount
FROM loans l
LEFT JOIN repayments r ON l.loan_id = r.loan_id
WHERE r.repaid_amount > 0;    -- NULL repaid_amount (unrepaid loans) = UNKNOWN → excluded
```

**Fix A — keep condition in ON clause:**

```sql
LEFT JOIN repayments r ON l.loan_id = r.loan_id AND r.repaid_amount > 0
-- Unrepaid loans still appear; repaid_amount is just NULL when condition fails
```

**Fix B — include NULLs explicitly in WHERE:**

```sql
WHERE r.repaid_amount > 0 OR r.repaid_amount IS NULL
```

```sql

---

### 33-1. Window Functions — Ranking Edge Cases

> Full detail in [Pattern 1 — Window Functions Ranking → Edge Cases](#1-window-functions--ranking).
> Critical: non-deterministic `ROW_NUMBER` without unique tiebreaker `ORDER BY`; `RANK` gaps vs `DENSE_RANK` ties.

---

### 33-2. LAG / LEAD Edge Cases

> Full detail in [Pattern 2 — LAG / LEAD → Edge Cases](#2-window-functions--lag--lead).
> Critical: `LAG` returns NULL for first row (use default arg); LAG/LEAD do NOT skip NULLs.

---

### 33-3. Running Aggregates — Frame Edge Cases

> Full detail in [Pattern 3 — Running Aggregates → Edge Cases](#3-window-functions--running-aggregates).
> Critical: default `RANGE UNBOUNDED PRECEDING` double-counts ties — use `ROWS BETWEEN` instead.

---

### 33-4. FIRST_VALUE / LAST_VALUE Edge Cases

> Full detail in [Pattern 4 — FIRST_VALUE / LAST_VALUE → Edge Cases](#4-window-functions--first_value--last_value).
> Critical: `LAST_VALUE` requires `ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING` to see full partition.

---

### 33-5. Gap and Islands Edge Cases

> Full detail in [Pattern 5 — Gap and Islands → Edge Cases](#5-gap-and-islands).
> Critical: NULL `prev_date` makes first row always a gap start; date-only events need `DISTINCT` first.

---

### 33-6. Sessionization Edge Cases

> Full detail in [Pattern 6 — Sessionization → Edge Cases](#6-sessionization).
> Critical: session boundary at partition start always `is_break=1`; overlapping sessions silently merge.

---

### 33-7. Deduplication Edge Cases

> Full detail in [Pattern 7 — Deduplication → Edge Cases](#7-deduplication-patterns).
> Critical: keep-first dedup is non-deterministic without a unique tiebreaker `ORDER BY`.

---

### 33-8. Top-N per Group Edge Cases

> Full detail in [Pattern 8 — Top-N per Group → Edge Cases](#8-top-n-per-group).
> Critical: ties at rank boundary include more than N rows; need QUALIFY + LIMIT to cap exactly.

---

### 33-9. Rolling Window Aggregation Edge Cases

> Full detail in [Pattern 9 — Rolling Window → Edge Cases](#9-rolling-window-aggregations).
> Critical: `RANGE` frame groups ties (inflates averages); NULL gaps in date spine distort rolling avg.

---

### 33-10. Period-over-Period Edge Cases

> Full detail in [Pattern 10 — Period-over-Period → Edge Cases](#10-period-over-period-comparisons-mom-yoy-dod).
> Critical: `LAG(..., 12)` silently returns NULL for missing months; divide-by-zero when prior period = 0.

---

### 33-11. Date Spine Edge Cases

> Full detail in [Pattern 11 — Date Spine → Edge Cases](#11-date-spine--calendar-table).
> Critical: date spine without LEFT JOIN silently drops dates with no events.

---

### 33-12. Cohort Analysis Edge Cases

> Full detail in [Pattern 12 — Cohort Analysis → Edge Cases](#12-cohort-analysis--retention).
> Critical: cohort join on `DATE_TRUNC` loses mid-period signups; retention % inflated if cohort base is wrong.

---

### 33-13. Funnel Analysis Edge Cases

> Full detail in [Pattern 13 — Funnel Analysis → Edge Cases](#13-funnel-analysis).
> Critical: INNER JOIN funnel drops users who skip a step; repeated steps inflate counts.

---

### 33-14. SCD Type 2 Edge Cases

> Full detail in [Pattern 14 — SCD Type 2 → Edge Cases](#14-slowly-changing-dimensions-scd-type-2).
> Critical: zero-duration rows on same-day double change; gap between versions drops INNER JOINs; fact before first SCD2 version silently drops.

---

### 33-15. Conditional Aggregation Edge Cases

> Full detail in [Pattern 15 — Conditional Aggregation → Edge Cases](#15-conditional-aggregations).
> Critical: `COUNT(*)` with `ELSE 0` counts all rows — use `SUM(CASE WHEN ... THEN 1 ELSE 0 END)`.

---

### 33-16. Self Joins Edge Cases

> Full detail in [Pattern 16 — Self Joins → Edge Cases](#16-self-joins--consecutive-row-comparisons).
> Critical: self-join without strict inequality produces duplicates; NULL join key causes Cartesian product.

---

### 33-17. Recursive CTE Edge Cases

> Full detail in [Pattern 17 — Recursive CTEs → Edge Cases](#17-recursive-ctes-hierarchies).
> Critical: missing termination condition causes infinite loop; cycles require explicit cycle detection.

---

### 33-18. Pivoting Edge Cases

> Full detail in [Pattern 18 — Pivoting → Edge Cases](#18-pivoting--unpivoting).
> Critical: PIVOT requires all column values known at query time; dynamic pivot needs dynamic SQL.

---

### 33-19. String Aggregation Edge Cases

> Full detail in [Pattern 19 — String Aggregation → Edge Cases](#19-string-aggregation).
> Critical: aggregation order non-deterministic without `ORDER BY`; `GROUP_CONCAT` truncates silently.

---

### 33-20. Data Quality Pattern Edge Cases

> Full detail in [Pattern 20 — Data Quality → Edge Cases](#20-data-quality-patterns).
> Critical: NULL checks require `IS NULL` not `= NULL`; multi-column uniqueness must handle NULLs.

---
