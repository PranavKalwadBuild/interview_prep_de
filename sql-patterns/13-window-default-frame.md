<!-- Part of sql-patterns: Window Function Default Frame — The RANGE Trap (6 Traps, Engine Differences, Best Practices) -->
<!-- Source: sql_patterns.md lines 3211–3572 -->

## 3-A. Window Function Default Frame — The RANGE Trap

The most common source of **silent, undetected wrong results** in window functions is not a typo or a logic error — it is a frame you never wrote. When you add `ORDER BY` to a window function but omit the frame clause, every major SQL engine silently applies:

```sql
RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
```

This section focuses entirely on that default: what it means, the six distinct ways it produces wrong results, how to detect it in existing queries, engine-specific differences, and the one rule that eliminates the entire class of bugs.

> **Cross-reference:** For the full ROWS vs RANGE comparison (physical vs logical offsets, interval-based RANGE, GROUPS mode), see [ROWS BETWEEN vs RANGE BETWEEN — Deep Dive](#rows-between-vs-range-between--deep-dive) inside Pattern 3.

---

### The Default Frame Rules — One Table to Memorise

| What you wrote | Default frame the engine applies | Behaviour |
|---|---|---|
| `OVER()` — no ORDER BY, no frame | `RANGE BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING` | Entire partition (safe — all rows contribute) |
| `OVER(ORDER BY col)` — ORDER BY, no frame | `RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW` | Cumulative up to the current **peer group** (dangerous) |
| `OVER(ORDER BY col ROWS BETWEEN ...)` | Exactly what you wrote | Explicit — safe |
| `OVER(ORDER BY col RANGE BETWEEN ...)` | Exactly what you wrote | Explicit — safe |

The danger zone is row 2. Adding `ORDER BY` triggers a RANGE-based cumulative frame. If your ORDER BY column has any tied values, RANGE silently expands the frame to include all peers — giving every tied row the same, inflated result.

---

### Trap 1 — Running Total Inflates on Tied Dates

**The most common manifestation.** If two rows share the same ORDER BY value (e.g., two transactions on the same date), RANGE groups them as peers. Both see the cumulative sum *including all peers at their date*, not a row-by-row running total.

```sql
-- Source data: U1 has two transactions on 2024-01-01
-- user_id | txn_date   | amount
-- U1      | 2024-01-01 | 100
-- U1      | 2024-01-01 | 200   ← tied date
-- U1      | 2024-01-02 | 150

-- WRONG — default RANGE frame
SELECT user_id, txn_date, amount,
    SUM(amount) OVER (
        PARTITION BY user_id
        ORDER BY txn_date          -- no frame → RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ) AS running_total
FROM transactions;

-- Result:
-- U1 | 2024-01-01 | 100 | 300   ← wrong: should be 100 (or 300 only for the second row)
-- U1 | 2024-01-01 | 200 | 300   ← RANGE expanded frame to include both Jan 1 rows for both rows
-- U1 | 2024-01-02 | 150 | 450

-- CORRECT — explicit ROWS frame
SELECT user_id, txn_date, amount,
    SUM(amount) OVER (
        PARTITION BY user_id
        ORDER BY txn_date
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW   -- ← always add this
    ) AS running_total
FROM transactions;

-- Result:
-- U1 | 2024-01-01 | 100 | 100   ← correct
-- U1 | 2024-01-01 | 200 | 300   ← correct
-- U1 | 2024-01-02 | 150 | 450   ← correct
```

**Why this is silent:** The query runs without error. The result looks plausible. You only discover the bug when you compare the final cumulative total to a known total — or when a business analyst notices that two rows on the same date show identical running totals.

---

### Trap 2 — Adding ORDER BY Silently Switches Aggregate from Partition-Wide to Cumulative

This trap catches people who add `ORDER BY` to get deterministic output, not realising it changes the *aggregate behaviour* of the window function.

```sql
-- INTENT: get the total revenue for each user's region, shown on every row
-- (classic "show regional total alongside individual row" pattern)

-- Version 1: no ORDER BY — works correctly
SELECT user_id, region, amount,
    SUM(amount) OVER (PARTITION BY region) AS region_total  -- entire partition ✓
FROM sales;
-- region_total = 10000 for every row in 'North' region ✓

-- Version 2: ORDER BY added "for determinism" — silently broken
SELECT user_id, region, amount,
    SUM(amount) OVER (PARTITION BY region ORDER BY sale_date) AS region_total
FROM sales;
-- region_total is now a CUMULATIVE sum per region (not the partition total)
-- First row in 'North' gets region_total = (first sale's amount), not 10000 ✗
-- Last row in 'North' gets region_total = 10000 (happens to be correct) ✗ for all others

-- RULE: if you need the partition-wide total on every row, omit ORDER BY entirely.
-- If you need ORDER BY for something else, use an explicit frame that covers the whole partition:
SUM(amount) OVER (
    PARTITION BY region
    ORDER BY sale_date
    ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING  -- whole partition regardless of order
) AS region_total
```

**Detection signal:** If you see a window aggregate that produces different values per row within the same partition, but you expected a constant — check whether ORDER BY is present without an explicit frame.

---

### Trap 3 — LAST_VALUE Always Returns the Current Row's Value

`LAST_VALUE` is the most reliably broken window function under the default frame. The default frame ends at the current row, so "last value" means "last value *so far*" — which is always the current row's value.

```sql
-- INTENT: get the most recent credit tier for each borrower,
-- shown on every historical record

-- WRONG — default frame: last value up to current row = current row's value
SELECT borrower_id, event_date, credit_tier,
    LAST_VALUE(credit_tier) OVER (
        PARTITION BY borrower_id
        ORDER BY event_date       -- default: RANGE UNBOUNDED PRECEDING AND CURRENT ROW
    ) AS latest_tier             -- always equals credit_tier — completely useless
FROM credit_history;

-- CORRECT — frame must extend to the end of the partition
SELECT borrower_id, event_date, credit_tier,
    LAST_VALUE(credit_tier) OVER (
        PARTITION BY borrower_id
        ORDER BY event_date
        ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING   -- ← required for LAST_VALUE
    ) AS latest_tier
FROM credit_history;

-- FIRST_VALUE: opposite problem — default frame works correctly for FIRST_VALUE
-- because the frame starts at UNBOUNDED PRECEDING, which always includes the first row.
-- However: if tied ORDER BY values exist, FIRST_VALUE under RANGE still expands peers.
-- Safe habit: always use ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING
-- for both FIRST_VALUE and LAST_VALUE.
```

**Rule of thumb:** Every `LAST_VALUE()` call without an explicit `ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING` frame is almost certainly wrong.

---

### Trap 4 — NULL Values in ORDER BY Column Have Non-Intuitive RANGE Behaviour

When the ORDER BY column contains NULLs, RANGE frame boundaries behave in ways that are never obvious from reading the query.

```sql
-- ORDER BY event_date ASC (NULLS LAST by default in most engines)
-- RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
-- For a row where event_date IS NULL:
--   "CURRENT ROW" in RANGE = all rows with the same ORDER BY value = all other NULLs
--   → the frame for a NULL row includes ALL NULL rows
--   → SUM for NULL rows = sum of all NULL-date rows, not "unknown"

-- RANGE BETWEEN 10 PRECEDING AND 10 FOLLOWING on a numeric col with NULLs:
--   A NULL row: its value is NULL, NULL ± 10 = NULL
--   → frame start = NULL, frame end = NULL
--   → frame includes ONLY other NULL rows (NULL is a peer of NULL in RANGE)

-- ROWS handles NULLs predictably: each NULL row is a distinct physical row,
-- counted by position regardless of its ORDER BY value.

-- FIX: if ORDER BY column can contain NULLs, use ROWS (not RANGE),
-- and explicitly handle NULLs in the ORDER BY:
SUM(amount) OVER (
    PARTITION BY user_id
    ORDER BY COALESCE(event_date, DATE '9999-12-31')   -- push NULLs to end deterministically
    ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
)
```

---

### Trap 5 — RANGE with Explicit Offsets Has Strict Type and Cardinality Constraints

When you intentionally use RANGE (for time-distance windows), it imposes constraints that ROWS does not.


---

### Trap 6 — LAG / LEAD / ROW_NUMBER / RANK Silently Ignore Frame Clauses

Writing a frame clause on these functions is not an error — but the frame has no effect. This creates a false sense of security.

```sql
-- This does NOT restrict LAG to look back within a ROWS frame:
LAG(amount, 1) OVER (
    PARTITION BY user_id
    ORDER BY event_date
    ROWS BETWEEN 6 PRECEDING AND CURRENT ROW   -- ← silently ignored by LAG
)
-- LAG always looks back exactly 1 row (or N rows per the offset argument),
-- regardless of any frame clause. The frame clause is meaningless here.

-- Functions that IGNORE the frame clause:
-- LAG, LEAD, ROW_NUMBER, RANK, DENSE_RANK, NTILE, PERCENT_RANK, CUME_DIST

-- Functions that RESPECT the frame clause:
-- SUM, AVG, MIN, MAX, COUNT, FIRST_VALUE, LAST_VALUE, NTH_VALUE
```

---

### Engine-Specific Default Frame Behaviour

All major engines agree on the SQL standard default: `RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW` when ORDER BY is present. However, edge-case behaviour differs.

| Engine | Default (ORDER BY, no frame) | RANGE INTERVAL support | NULL-in-ORDER-BY behaviour |
|---|---|---|---|
| PostgreSQL | `RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW` | Full (`INTERVAL '7 days'`) | NULL rows peer with each other under RANGE |
| MySQL 8+ | `RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW` | Partial (8.0+) | Same |

**The one place engines differ:** when `ORDER BY` is absent.

| Engine | No ORDER BY default |
|---|---|

---

### How to Detect This Bug in Existing Queries

Use this checklist when reviewing any window function query:

```sql
-- DIAGNOSTIC QUERY: find all window function calls in a query that have
-- ORDER BY but no explicit frame clause (these are candidates for the default-frame trap)

-- Look for this pattern in your SQL:
-- FUNCTION() OVER (... ORDER BY col)          ← no ROWS/RANGE keyword = default frame applied
-- FUNCTION() OVER (... ORDER BY col ROWS ...) ← explicit = safe
-- FUNCTION() OVER (... ORDER BY col RANGE ...) ← explicit = safe

-- Quick smell test on results:
-- 1. Do two rows with the same ORDER BY value show the same window aggregate result?
--    → If yes and you didn't intend that: RANGE is grouping peers. Use ROWS.
-- 2. Does LAST_VALUE return the same value as the current row's column?
--    → Default frame is cutting off at the current row. Add ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING.
-- 3. Does SUM() produce the full partition total instead of a running total (or vice versa)?
--    → Check whether ORDER BY was accidentally added or omitted.

-- Validation query: compare ROWS vs implicit RANGE to detect discrepancy
SELECT
    *,
    SUM(amount) OVER (PARTITION BY user_id ORDER BY txn_date)                                        AS implicit_sum,
    SUM(amount) OVER (PARTITION BY user_id ORDER BY txn_date ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS explicit_rows_sum,
    implicit_sum <> explicit_rows_sum AS has_default_frame_discrepancy   -- TRUE = you have a tie-expansion bug
FROM transactions;
```

---

### Best Practices — The Always-Explicit-Frame Rule

**Rule:** Any window function call that uses an aggregate (`SUM`, `AVG`, `MIN`, `MAX`, `COUNT`, `FIRST_VALUE`, `LAST_VALUE`) with an `ORDER BY` clause **must have an explicit frame clause**. No exceptions.

```sql
-- ✗ NEVER write these (frame is implicit and dangerous):
SUM(amount)      OVER (PARTITION BY user_id ORDER BY txn_date)
AVG(score)       OVER (PARTITION BY dept_id ORDER BY review_date)
MAX(price)       OVER (PARTITION BY product_id ORDER BY updated_at)
LAST_VALUE(tier) OVER (PARTITION BY borrower_id ORDER BY valid_from)

-- ✓ ALWAYS write an explicit frame:
SUM(amount)      OVER (PARTITION BY user_id ORDER BY txn_date ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
AVG(score)       OVER (PARTITION BY dept_id ORDER BY review_date ROWS BETWEEN 2 PRECEDING AND CURRENT ROW)
MAX(price)       OVER (PARTITION BY product_id ORDER BY updated_at ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
LAST_VALUE(tier) OVER (PARTITION BY borrower_id ORDER BY valid_from ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING)
```

**When to omit ORDER BY entirely** (and use no frame):

```sql
-- Partition-wide constant (grand total, partition count, partition max):
-- Do NOT add ORDER BY if the result should be the same on every row in the partition.
SUM(amount)   OVER (PARTITION BY region)          -- entire partition total ✓
COUNT(*)      OVER (PARTITION BY dept_id)         -- headcount ✓
MAX(salary)   OVER (PARTITION BY dept_id)         -- max in department ✓
-- Adding ORDER BY to any of these silently turns them into running aggregates.
```

---

### Quick Reference — Explicit Frame by Use Case

| Use Case | Correct Frame |
|---|---|
| Row-by-row running total / cumulative sum | `ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW` |
| Partition-wide total on every row | Omit ORDER BY and frame entirely |
| Rolling N-row window (last N data points) | `ROWS BETWEEN N-1 PRECEDING AND CURRENT ROW` |
| First value in partition | `ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING` |
| Last value in partition | `ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING` |
| Centred moving average (N rows before and after) | `ROWS BETWEEN N PRECEDING AND N FOLLOWING` |
| Entire partition (explicit) | `ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING` |
| All peers of current row only | `RANGE BETWEEN CURRENT ROW AND CURRENT ROW` |
| LAG / LEAD / ROW_NUMBER / RANK | No frame clause — these functions ignore it |

---

### Gotchas Summary

| Gotcha | What happens | Fix |
|---|---|---|
| ORDER BY with no frame | RANGE default silently groups tied rows | Always write explicit ROWS frame |
| Adding ORDER BY to a partition-wide aggregate | Turns constant into a running total | Omit ORDER BY; or use ROWS UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING |
| LAST_VALUE without full frame | Returns current row's value (useless) | Add ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING |
| NULLs in ORDER BY column with RANGE | NULL rows are peers of each other — unpredictable frame | Use ROWS; COALESCE the ORDER BY column |
| RANGE with multiple ORDER BY cols | Error in most engines | Use ROWS, or reduce to single ORDER BY col |
| Frame clause on LAG/LEAD/ROW_NUMBER | Silently ignored — false security | Remove it; understand these functions have no frame |

---


