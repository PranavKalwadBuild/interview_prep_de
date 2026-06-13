<!-- Part of sql-patterns: Rolling Window Aggregations -->
<!-- Source: sql_patterns.md lines 4932–5194 -->

## 9. Rolling Window Aggregations

### What it solves

Compute aggregates over a sliding window of N rows or N time units (7-day moving average, 30-day rolling sum, etc.).

### Keywords to spot

> "7-day", "30-day", "rolling", "moving average", "trailing",
> "last N days", "sliding window", "moving sum", "smoothed",
> "recent trend", "exponential smoothing", "trailing average",
> "week-over-week smoothed", "noise reduction", "baseline window",
> "anomaly vs rolling baseline", "over the last N periods"

### Business Context

- **Fintech:** 7-day rolling average trading volume per pair to smooth intraday noise; 30-day moving deposit total for AML anomaly detection (flag if today's deposit is 5× the rolling average)
- **E-commerce:** 7-day rolling revenue per product to smooth weekday/weekend effects; rolling 30-day cart abandonment rate to detect checkout degradation
- **DevOps/Platform:** Rolling p99 API latency over last 5 minutes (alert if > SLA threshold); 1-hour rolling error rate to distinguish spikes from sustained degradation
- **Retail/CPG:** 4-week moving average sales to smooth seasonality for replenishment forecasting; rolling 13-week baseline for promotional lift measurement
- **Fraud/Risk:** 7-day rolling average spend per card to detect sudden deviation (velocity check); 30-day rolling login count to flag dormant accounts that suddenly become active

### Boilerplate — Row-based rolling window

```

```sql
-- 7-day moving average price (last 7 rows)
SELECT
    trading_pair,
    trade_date,
    close_price,
    AVG(close_price) OVER (
        PARTITION BY trading_pair
        ORDER BY trade_date
        ROWS BETWEEN 6 PRECEDING AND CURRENT ROW   -- 7 rows total
    ) AS moving_avg_7d,
    SUM(volume) OVER (
        PARTITION BY trading_pair
        ORDER BY trade_date
        ROWS BETWEEN 29 PRECEDING AND CURRENT ROW  -- 30-day rolling sum
    ) AS rolling_volume_30d
FROM daily_prices;
```

### Boilerplate — Time-based rolling window (RANGE)

```sql
-- Rolling sum of deposits in the last 7 days for each user
-- (handles irregular dates — not just 7 rows, but 7 days of actual time)
SELECT
    user_id,
    deposit_date,
    amount,
    SUM(amount) OVER (
        PARTITION BY user_id
        ORDER BY UNIX_TIMESTAMP(deposit_date)
        RANGE BETWEEN 604800 PRECEDING AND CURRENT ROW  -- 7 days in seconds
    ) AS rolling_7d_deposits
FROM deposits;

-- Simpler approach using a self-join or CTE with date filter:
WITH base AS (
    SELECT user_id, deposit_date, amount FROM deposits
)
SELECT
    b1.user_id,
    b1.deposit_date,
    SUM(b2.amount) AS rolling_7d
FROM base b1
JOIN base b2
    ON  b1.user_id = b2.user_id
    AND b2.deposit_date BETWEEN b1.deposit_date - INTERVAL 6 DAY AND b1.deposit_date
GROUP BY b1.user_id, b1.deposit_date;
```

### Gotchas

- `ROWS BETWEEN 6 PRECEDING AND CURRENT ROW` = 7 total rows (0-indexed offset)
- `RANGE` frame with dates requires numeric representation (epoch) in most dialects
- Rolling windows on sparse data (missing dates) need a date spine — see Pattern 11

### Edge Cases

#### Edge 9-A: ROWS frame with sparse / missing dates gives misleading "N-day" labels

**Problem:**

```sql
-- "7-day rolling average of daily transaction volume"
-- Data has gaps: Jan 1, Jan 2, Jan 5, Jan 9 (no entries for Jan 3, 4, 6, 7, 8)

SELECT
    txn_date,
    daily_volume,
    AVG(daily_volume) OVER (
        ORDER BY txn_date
        ROWS BETWEEN 6 PRECEDING AND CURRENT ROW   -- "7 rows" not "7 days"!
    ) AS rolling_7_row_avg
FROM daily_volumes;
-- On Jan 9: the "7 rows" look back is: Jan 1, Jan 2, Jan 5, Jan 9 (only 4 dates exist!)
-- The avg is over 4 dates but labeled as "7-day rolling" — MISLEADING
```

**Fix A — use RANGE with a date interval (true 7-calendar-day window):**

```sql
AVG(daily_volume) OVER (
    ORDER BY txn_date
    RANGE BETWEEN INTERVAL '6 days' PRECEDING AND CURRENT ROW
)
-- Jan 9's window: only includes dates from Jan 3–Jan 9 that actually exist = Jan 5, Jan 9
```

**Fix B — use a date spine so every date has a row (even if volume = 0):**

```sql
WITH spine AS (
    SELECT generate_series('2024-01-01'::DATE, '2024-01-31'::DATE, '1 day')::DATE AS dt
)
SELECT s.dt, COALESCE(d.daily_volume, 0) AS daily_volume,
    AVG(COALESCE(d.daily_volume, 0)) OVER (
        ORDER BY s.dt
        ROWS BETWEEN 6 PRECEDING AND CURRENT ROW
    ) AS rolling_7_day_avg
FROM spine s LEFT JOIN daily_volumes d ON s.dt = d.txn_date;
-- Now "7 rows" = "7 actual calendar days" — aligned
```

#### Edge 9-B: Rolling average with RANGE on non-numeric/non-date ORDER BY

**Problem:**

```sql
-- RANGE with INTERVAL requires a DATE or NUMERIC ORDER BY column
-- BREAKS if ORDER BY column is a string or other type

AVG(amount) OVER (
    ORDER BY txn_category        -- STRING! Cannot use RANGE with string ORDER BY
    RANGE BETWEEN 1 PRECEDING AND CURRENT ROW  -- ERROR in most engines
)
-- Fix: RANGE only works with ordinal (numeric/date) columns
-- For string ORDER BY use ROWS instead, or restructure the query
```

**Fix:**

```sql
-- RANGE requires an ordinal (numeric or date) ORDER BY column.
-- For string or non-ordinal ORDER BY, use ROWS instead:

-- Instead of RANGE on a string column, convert to an ordinal position first:
WITH ordered_categories AS (
    SELECT txn_category,
           ROW_NUMBER() OVER (ORDER BY txn_category) AS cat_order,
           amount
    FROM transactions
)
SELECT txn_category, amount,
    AVG(amount) OVER (
        ORDER BY cat_order         -- numeric → RANGE works
        ROWS BETWEEN 1 PRECEDING AND CURRENT ROW   -- or use ROWS for safety
    ) AS rolling_avg
FROM ordered_categories;
-- Always use ROWS (not RANGE) when ORDER BY column is not a numeric/date type
```

---

### At Scale

#### Failure Mechanism

`SUM(amount) OVER (ORDER BY txn_date RANGE BETWEEN INTERVAL '7' DAY PRECEDING AND CURRENT ROW)` on 800M rows:

- RANGE with an interval: engine must join each row to all rows within 7 days — this is an **inequality join**, the most expensive join type in SQL
- At 800M rows with daily data: average row participates in 7 windows → ~5.6B comparisons
- In Spark: converted to a sort-merge join with a bloom filter — still O(N log N) with high constant

#### Code-Level Fix

```sql

```sql
-- BEFORE: 7-day rolling sum on raw 800M transaction table
SELECT user_id, txn_date, SUM(amount) OVER (
    PARTITION BY user_id
    ORDER BY txn_date
    RANGE BETWEEN INTERVAL '7' DAY PRECEDING AND CURRENT ROW
) AS rolling_7d_volume
FROM transactions;   -- 800M rows; RANGE interval join

-- FIX 1: Pre-aggregate to daily granularity, then compute rolling sum on daily totals
WITH daily AS (
    SELECT user_id, txn_date, SUM(amount) AS daily_volume
    FROM transactions
    GROUP BY user_id, txn_date   -- 800M → 5M daily rows (160× reduction)
),
date_spine AS (
    -- Ensure all dates exist so ROWS frame is equivalent to RANGE frame
    SELECT DISTINCT user_id FROM transactions,
    LATERAL (SELECT explode(sequence(
        MIN(txn_date) OVER (PARTITION BY user_id),
        MAX(txn_date) OVER (PARTITION BY user_id),
        INTERVAL 1 DAY
    )) AS txn_date) spine_dates
),
filled AS (
    SELECT s.user_id, s.txn_date, COALESCE(d.daily_volume, 0) AS daily_volume
    FROM date_spine s LEFT JOIN daily d USING (user_id, txn_date)
)
SELECT user_id, txn_date, daily_volume,
    SUM(daily_volume) OVER (
        PARTITION BY user_id
        ORDER BY txn_date
        ROWS BETWEEN 6 PRECEDING AND CURRENT ROW   -- ROWS safe because date_spine is complete
    ) AS rolling_7d_volume
FROM filled;
-- Window function now runs on 5M rows with ROWS frame (faster than RANGE on 800M)

-- FIX 2: For real-time rolling windows, use a materialised daily summary table
-- and maintain it with streaming updates (Flink / Spark Structured Streaming)
-- Final query: simple SUM over 7 rows from the daily summary table
```

#### System-Level Fix

```sql
-- Delta Lake: materialise daily user summaries for rolling window efficiency
CREATE TABLE user_daily_summary (
    user_id       STRING,
    summary_date  DATE,
    daily_volume  DECIMAL(20,2),
    daily_count   BIGINT,
    avg_amount    DECIMAL(15,2)
)
USING DELTA
PARTITIONED BY (summary_date)   -- fast date-range reads
TBLPROPERTIES ('delta.autoOptimize.optimizeWrite' = 'true');
OPTIMIZE user_daily_summary ZORDER BY (user_id);   -- fast per-user reads

-- Rolling 7-day query on this table: reads 7 small partitions, already aggregated
-- Cost: 7 × (partition_size) vs. 800M rows scan — orders of magnitude cheaper

-- Snowflake: dynamic table for rolling metrics
CREATE OR REPLACE DYNAMIC TABLE rolling_7d_metrics
  LAG = '1 hour' WAREHOUSE = reporting_wh
AS
SELECT user_id, summary_date,
    SUM(daily_volume) OVER (
        PARTITION BY user_id
        ORDER BY summary_date
        ROWS BETWEEN 6 PRECEDING AND CURRENT ROW
    ) AS rolling_7d_volume
FROM user_daily_summary;
```

```sql

---

---

