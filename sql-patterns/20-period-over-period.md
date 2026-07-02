<!-- sql-patterns: Period-over-Period Comparisons (MoM, YoY, DoD) -->

# Period-over-Period Comparisons (MoM, YoY, DoD)

## What it solves

Compare a metric in the current period to the same metric in a prior period (previous month, previous year, previous day).

## Keywords to spot

> "month-over-month", "year-over-year", "compared to last month",
> "growth rate", "change from previous period", "same period last year",
> "week-on-week", "DoD", "MoM", "YoY", "% change",
> "quarter-over-quarter", "QoQ", "vs prior week", "same day last year",
> "like-for-like", "comp growth", "baseline comparison", "variance to prior period"

## Business Context

- **Fintech:** Monthly trading volume growth (investor KPI); daily transaction count vs prior day (ops monitoring); fee revenue YoY per product line (annual business review)
- **E-commerce:** MoM revenue growth per category; YoY GMV comparison by quarter (earnings report); same-week-last-year order volume to account for seasonality
- **SaaS:** MoM new signup growth; churn rate YoY; feature adoption WoW for newly launched features; MRR expansion/contraction QoQ
- **Retail:** Same-store (like-for-like) sales YoY; weekly basket size DoD comparison during promotional events; comp sales excluding new store openings
- **Marketing:** WoW click-through rate change per campaign; MoM cost-per-acquisition trend; YoY brand search volume comparison

## Boilerplate — LAG approach

-- ANSI SQL approach: Extract year/month for grouping (most portable)
WITH monthly_volume AS (
    SELECT
        (EXTRACT(YEAR FROM executed_at) * 100 + EXTRACT(MONTH FROM executed_at)) AS year_month,
        EXTRACT(YEAR FROM executed_at) AS year,
        EXTRACT(MONTH FROM executed_at) AS month,
        trading_pair,
        SUM(trade_amount)                AS total_volume
    FROM trades
    GROUP BY EXTRACT(YEAR FROM executed_at), EXTRACT(MONTH FROM executed_at), trading_pair
)
SELECT
    year_month,
    year,
    month,
    trading_pair,
    total_volume,
    LAG(total_volume, 1) OVER (
        PARTITION BY trading_pair
        ORDER BY year, month
    ) AS prev_month_volume,
    ROUND(
        (total_volume - LAG(total_volume, 1) OVER (PARTITION BY trading_pair ORDER BY year, month))
        / NULLIF(LAG(total_volume, 1) OVER (PARTITION BY trading_pair ORDER BY year, month), 0)
        * 100, 2
    ) AS mom_growth_pct
FROM monthly_volume;

-- PostgreSQL fallback: DATE_TRUNC for when you need timestamp values
WITH monthly_volume_pg AS (
    SELECT
        DATE_TRUNC('month', executed_at) AS month,
        trading_pair,
        SUM(trade_amount)                AS total_volume
    FROM trades
    GROUP BY 1, 2
)
SELECT
    month,
    trading_pair,
    total_volume,
    LAG(total_volume, 1) OVER (
        PARTITION BY trading_pair
        ORDER BY month
    ) AS prev_month_volume,
    ROUND(
        (total_volume - LAG(total_volume, 1) OVER (PARTITION BY trading_pair ORDER BY month))
        / NULLIF(LAG(total_volume, 1) OVER (PARTITION BY trading_pair ORDER BY month), 0)
        * 100, 2
    ) AS mom_growth_pct
FROM monthly_volume_pg;

-- MySQL fallback: DATE_FORMAT for period grouping
WITH monthly_volume_my AS (
    SELECT
        DATE_FORMAT(executed_at, '%Y-%m') AS year_month,
        trading_pair,
        SUM(trade_amount)                AS total_volume
    FROM trades
    GROUP BY 1, 2
)
SELECT
    year_month,
    trading_pair,
    total_volume,
    LAG(total_volume, 1) OVER (
        PARTITION BY trading_pair
        ORDER BY year_month
    ) AS prev_month_volume,
    ROUND(
        (total_volume - LAG(total_volume, 1) OVER (PARTITION BY trading_pair ORDER BY year_month))
        / NULLIF(LAG(total_volume, 1) OVER (PARTITION BY trading_pair ORDER BY year_month), 0)
        * 100, 2
    ) AS mom_growth_pct
FROM monthly_volume_my;

-- YoY: use LAG with offset = 12 (months) - works with all three approaches above

## Boilerplate — Self-join approach (more explicit)

-- ANSI SQL approach: Use year/month arithmetic
SELECT
    curr.year_month,
    curr.trading_pair,
    curr.total_volume                                       AS current_volume,
    prev.total_volume                                       AS prev_volume,
    (curr.total_volume - prev.total_volume) / prev.total_volume * 100 AS growth_pct
FROM monthly_volume curr
LEFT JOIN monthly_volume prev
    ON  curr.trading_pair = prev.trading_pair
    AND curr.year = prev.year + (curr.month - prev.month - 1) / 12
    AND curr.month = ((prev.month - 1) % 12) + 1;

-- Simpler ANSI approach for month-to-month (assuming no year boundary issues in data):
SELECT
    curr.year_month,
    curr.trading_pair,
    curr.total_volume                                       AS current_volume,
    prev.total_volume                                       AS prev_volume,
    (curr.total_volume - prev.total_volume) / prev.total_volume * 100 AS growth_pct
FROM monthly_volume curr
LEFT JOIN monthly_volume prev
    ON  curr.trading_pair = prev.trading_pair
    AND (curr.year = prev.year AND curr.month = prev.month + 1)
    OR (curr.year = prev.year + 1 AND curr.month = 1 AND prev.month = 12);

-- PostgreSQL fallback: DATE_TRUNC and INTERVAL
SELECT
    curr.month,
    curr.trading_pair,
    curr.total_volume                                       AS current_volume,
    prev.total_volume                                       AS prev_volume,
    (curr.total_volume - prev.total_volume) / prev.total_volume * 100 AS growth_pct
FROM monthly_volume curr
LEFT JOIN monthly_volume prev
    ON  curr.trading_pair = prev.trading_pair
    AND curr.month = prev.month + INTERVAL '1 month';

-- MySQL fallback: DATE_FORMAT and DATE_ADD
SELECT
    curr.year_month,
    curr.trading_pair,
    curr.total_volume                                       AS current_volume,
    prev.total_volume                                       AS prev_volume,
    (curr.total_volume - prev.total_volume) / prev.total_volume * 100 AS growth_pct
FROM monthly_volume curr
LEFT JOIN monthly_volume prev
    ON  curr.trading_pair = prev.trading_pair
    AND curr.month = DATE_ADD(prev.month, INTERVAL 1 MONTH);

## Gotchas

- **Always use `NULLIF(denominator, 0)` to avoid division by zero**
  
  **Why it happens:** Division by zero results in runtime errors that can crash your query or return NULL depending on the database engine.
  
  **Examples of dangerous patterns:**
  - `(current - previous) / previous * 100` when previous = 0
  - `growth_rate = (new_value - old_value) / old_value` without zero check
  - Calculating percentages where baseline can be zero (new users, initial inventory, etc.)
  
  **Solutions:**
  - Always wrap denominators in `NULLIF(value, 0)` or equivalent
  - Use `CASE` statements for more complex logic: `CASE WHEN previous = 0 THEN NULL ELSE (current - previous) / previous END`
  - Consider returning 0% or NULL for growth when baseline is zero, depending on business meaning
  
  **Best practice:** Make NULLIF a habit whenever calculating growth rates, ratios, or percentages.

- **For YoY with monthly data, `LAG(col, 12)` only works if every month exists — use a date spine if there are gaps**
  
  **Why it happens:** LAG operates on the actual result set, not on a continuous time series. Missing months cause LAG to skip over gaps.
  
  **Examples of misleading results:**
  - If February data is missing, March's LAG(1) will return January's value (comparing to 2 months ago)
  - For YoY: if any month in the previous year is missing, the LAG(12) comparison becomes inaccurate
  - Seasonal businesses may appear to have abnormal growth/slump due to skipped periods
  
  **Detection techniques:**
  - Check for gaps: `SELECT month, LAG(month) OVER (ORDER BY month) AS prev_month FROM ...`
  - Look for unexpected jumps in sequential values
  - Compare row count to expected number of periods in date range
  
  **Solutions:**
  - Generate a complete date spine using recursive CTEs or calendar tables
  - Left join your aggregated data to the date spine to fill missing periods with zeros
  - Use time-series aware functions when available (timescaledb, etc.)
  
  **Best practice:** Always validate temporal continuity before relying on LAG/LEAD for period-over-period calculations.

- **`DATE_TRUNC('month', date)` vs `DATE_FORMAT(date, '%Y-%m')` — prefer `DATE_TRUNC` for portability**
  
  **Why it happens:** Different databases implement date truncation/formatting differently, leading to compatibility issues.
  
  **Engine-specific behaviors:**
  - PostgreSQL: `DATE_TRUNC` returns timestamp, `TO_CHAR` returns string
  - MySQL: `DATE_FORMAT` returns string, no direct DATE_TRUNC equivalent
  - SQLite: Uses `strftime()` for both operations
  - Oracle: `TRUNC()` function for dates, `TO_CHAR()` for formatting
  
  **Portability issues:**
  - String comparison vs timestamp comparison can yield different results
  - Timezone handling varies between formatting and truncation functions
  - Performance characteristics differ significantly between approaches
  
  **Recommended approach:**
  1. Use ANSI SQL methods first (EXTRACT year/month) for grouping
  2. If timestamp values are needed, use engine-specific fallbacks with clear labeling
  3. Document which approach you chose and why in your code comments
  4. Consider creating database-specific views or functions to abstract the differences


## Edge Cases

### Edge 10-A: Missing months create misleading LAG comparisons

**Problem:**

```sql
-- Monthly revenue: Jan=100, Feb=0 (no transactions, missing from agg), Mar=150
-- After aggregation, Feb doesn't exist in the result set
-- LAG on the sorted result: Mar's LAG = Jan (skips the missing Feb entirely!)
-- "MoM growth for March" = (150-100)/100 = 50% — but comparing to January, not February!

WITH monthly AS (
    SELECT DATE_TRUNC('month', txn_date) AS month, SUM(amount) AS revenue
    FROM transactions
    GROUP BY 1   -- Feb missing if no transactions in Feb
)
SELECT month, revenue,
    LAG(revenue) OVER (ORDER BY month) AS prev_revenue,
    -- For March: prev_revenue = January's revenue (February is absent from the CTE)
    -- This is WRONG: "30-day-ago" comparison is actually "61-day-ago"
    ...
FROM monthly;
```

**Fix — always join to a complete date spine:**

```sql
WITH spine AS (
    SELECT generate_series(
        DATE_TRUNC('month', MIN(txn_date)),
        DATE_TRUNC('month', MAX(txn_date)),
        INTERVAL '1 month'
    )::DATE AS month
    FROM transactions
),
monthly AS (
    SELECT DATE_TRUNC('month', txn_date) AS month, SUM(amount) AS revenue
    FROM transactions GROUP BY 1
)
SELECT s.month,
    COALESCE(m.revenue, 0) AS revenue,
    LAG(COALESCE(m.revenue, 0)) OVER (ORDER BY s.month) AS prev_revenue
FROM spine s LEFT JOIN monthly m ON s.month = m.month
ORDER BY s.month;
-- Feb now exists with revenue = 0; March's LAG correctly points to February
-- Calendar year YoY: compare 2024-Q1 to 2023-Q1
-- This is straightforward. But fiscal year YoY (FY starting April 1) is different.

-- BREAKS: comparing "same month" when the business uses fiscal periods
-- March 2024 (FY2024 month 12) vs March 2023 (FY2023 month 12) → correct FY comparison
-- But if you use LAG(12) on calendar months:
LAG(revenue, 12) OVER (ORDER BY calendar_month)
-- March 2024 LAG(12) = March 2023 → correct for FY in this case
-- April 2024 (FY2025 month 1) vs April 2023 (FY2024 month 1) → also correct
-- Works IF you want same-calendar-month comparison regardless of fiscal year

-- BREAKS when fiscal year has 13 periods (some accounting systems):
LAG(revenue, 13) OVER (ORDER BY fiscal_period)  -- 13-period year requires LAG(13) not LAG(12)

-- Best practice: include a fiscal_year and fiscal_period column in your date dimension
-- Join to it rather than using LAG(N) arithmetic
```

**Fix:**

```sql
-- Use a dedicated fiscal calendar dimension table rather than arithmetic:
WITH fiscal_revenue AS (
    SELECT d.fiscal_year, d.fiscal_period, SUM(t.amount) AS revenue
    FROM transactions t
    JOIN date_dim d ON t.txn_date = d.cal_date
    GROUP BY d.fiscal_year, d.fiscal_period
)
SELECT cur.fiscal_year, cur.fiscal_period,
       cur.revenue AS current_revenue,
       py.revenue  AS prior_year_revenue,
       ROUND(100.0 * (cur.revenue - py.revenue) / NULLIF(py.revenue, 0), 2) AS yoy_pct
FROM fiscal_revenue cur
LEFT JOIN fiscal_revenue py
    ON  cur.fiscal_period = py.fiscal_period
    AND cur.fiscal_year   = py.fiscal_year + 1   -- same period, prior fiscal year
ORDER BY cur.fiscal_year, cur.fiscal_period;
-- Works correctly for 13-period fiscal years, non-April fiscal starts, and calendar years
```

---

## At Scale

### Failure Mechanism

MoM growth via LAG on a full monthly revenue CTE: the CTE itself requires a full-table GROUP BY scan. At 800M rows, the GROUP BY scans all data. For a 3-year history (36 months), this is acceptable if partitions are used. The real problem is **when analysts run ad-hoc period comparisons without partition filters** — triggering full 800M row scans for a query that just needs 2 months of data.

### Code-Level Fix

```sql
-- BEFORE: ad-hoc MoM on full transaction history
WITH monthly AS (
    SELECT DATE_TRUNC('month', txn_date) AS month, SUM(amount) AS revenue
    FROM transactions   -- 800M rows, all years
    GROUP BY 1
)
SELECT month, revenue,
    LAG(revenue) OVER (ORDER BY month) AS prev_month_revenue
FROM monthly;

-- FIX 1: Partition filter — read only the months you need
WITH monthly AS (
    SELECT DATE_TRUNC('month', txn_date) AS month, SUM(amount) AS revenue
    FROM transactions
    WHERE txn_date >= '2024-01-01'   -- partition pruning: 2 years not 5 years
    GROUP BY 1
)
SELECT month, revenue,
    LAG(revenue) OVER (ORDER BY month) AS prev_month_revenue
FROM monthly;

-- FIX 2: Pre-materialised monthly metrics table (remove the GROUP BY from query time)
-- A dedicated monthly_metrics table is the correct architecture for BI/reporting layers
SELECT month, revenue,
    LAG(revenue) OVER (ORDER BY month) AS prev_revenue,
    ROUND(100.0 * (revenue - LAG(revenue) OVER (ORDER BY month))
                / NULLIF(LAG(revenue) OVER (ORDER BY month), 0), 2) AS mom_pct
FROM monthly_metrics   -- 36 rows per year; instant query
WHERE month >= '2024-01-01';

-- FIX 3: For YoY: self-join on the materialised monthly table
SELECT cur.month, cur.revenue AS current_revenue, py.revenue AS prior_year_revenue,
    ROUND(100.0 * (cur.revenue - py.revenue) / NULLIF(py.revenue, 0), 2) AS yoy_pct
FROM monthly_metrics cur
LEFT JOIN monthly_metrics py
    ON cur.month = py.month + INTERVAL '1 year';   -- self-join on 36 rows: trivially fast
```

### System-Level Fix


---

---


