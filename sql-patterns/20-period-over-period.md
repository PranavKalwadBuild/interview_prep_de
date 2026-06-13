<!-- Part of sql-patterns: Period-over-Period Comparisons (MoM, YoY, DoD) -->
<!-- Source: sql_patterns.md lines 5195–5448 -->

## 10. Period-over-Period Comparisons (MoM, YoY, DoD)

### What it solves

Compare a metric in the current period to the same metric in a prior period (previous month, previous year, previous day).

### Keywords to spot

> "month-over-month", "year-over-year", "compared to last month",
> "growth rate", "change from previous period", "same period last year",
> "week-on-week", "DoD", "MoM", "YoY", "% change",
> "quarter-over-quarter", "QoQ", "vs prior week", "same day last year",
> "like-for-like", "comp growth", "baseline comparison", "variance to prior period"

### Business Context

- **Fintech:** Monthly trading volume growth (investor KPI); daily transaction count vs prior day (ops monitoring); fee revenue YoY per product line (annual business review)
- **E-commerce:** MoM revenue growth per category; YoY GMV comparison by quarter (earnings report); same-week-last-year order volume to account for seasonality
- **SaaS:** MoM new signup growth; churn rate YoY; feature adoption WoW for newly launched features; MRR expansion/contraction QoQ
- **Retail:** Same-store (like-for-like) sales YoY; weekly basket size DoD comparison during promotional events; comp sales excluding new store openings
- **Marketing:** WoW click-through rate change per campaign; MoM cost-per-acquisition trend; YoY brand search volume comparison

### Boilerplate — LAG approach

```

```sql
-- MoM trading volume comparison
WITH monthly_volume AS (
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
FROM monthly_volume;

-- YoY: use LAG with offset = 12 (months)
LAG(total_volume, 12) OVER (PARTITION BY trading_pair ORDER BY month)
```

### Boilerplate — Self-join approach (more explicit)

```sql
SELECT
    curr.month,
    curr.trading_pair,
    curr.total_volume                                       AS current_volume,
    prev.total_volume                                       AS prev_volume,
    (curr.total_volume - prev.total_volume) / prev.total_volume * 100 AS growth_pct
FROM monthly_volume curr
LEFT JOIN monthly_volume prev
    ON  curr.trading_pair = prev.trading_pair
    AND curr.month = DATE_ADD(prev.month, INTERVAL 1 MONTH);
```

### Gotchas

- Always use `NULLIF(denominator, 0)` to avoid division by zero
- For YoY with monthly data, `LAG(col, 12)` only works if every month exists — use a date spine if there are gaps
- `DATE_TRUNC('month', date)` vs `DATE_FORMAT(date, '%Y-%m')` — prefer `DATE_TRUNC` for portability

### Edge Cases

#### Edge 10-A: Missing months create misleading LAG comparisons

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
```

#### Edge 10-B: YoY comparison using DATEADD — fiscal vs calendar year

**Problem:**

```sql
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

### At Scale

#### Failure Mechanism

MoM growth via LAG on a full monthly revenue CTE: the CTE itself requires a full-table GROUP BY scan. At 800M rows, the GROUP BY scans all data. For a 3-year history (36 months), this is acceptable if partitions are used. The real problem is **when analysts run ad-hoc period comparisons without partition filters** — triggering full 800M row scans for a query that just needs 2 months of data.

#### Code-Level Fix

```sql

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

#### System-Level Fix

```sql
-- Redshift: monthly_metrics table for BI layer
CREATE TABLE monthly_metrics (
    metric_date DATE,
    metric_name VARCHAR(50),
    metric_value DECIMAL(20,2)
)
DISTSTYLE ALL          -- tiny table; broadcast to all nodes
SORTKEY (metric_date, metric_name);

-- Populate from the large fact table ONCE per month:
INSERT INTO monthly_metrics
SELECT DATE_TRUNC('month', txn_date)::DATE, 'txn_revenue', SUM(amount)
FROM transactions WHERE txn_date >= DATE_TRUNC('month', CURRENT_DATE)
GROUP BY 1, 2;

-- All MoM/YoY queries run on monthly_metrics (36-120 rows) not transactions (800M rows)
-- Redshift compound sort key: date filter + metric_name filter both use zone maps

-- BigQuery: clustered summary table for pre-aggregated metrics
CREATE OR REPLACE TABLE monthly_metrics
CLUSTER BY metric_name, metric_date
AS SELECT ...;
-- Queries filtering on metric_name: cluster pruning reads only relevant blocks
```

```sql

---

---

