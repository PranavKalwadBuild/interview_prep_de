<!-- Part of sql-patterns: Date Spine / Calendar Table -->
<!-- Source: sql_patterns.md lines 5449–5693 -->

## 11. Date Spine / Calendar Table

### What it solves

Generate a continuous series of dates so that time-series aggregations don't skip missing periods (e.g., days with zero trades).

### Keywords to spot

> "even when there are no events", "zero values for missing days",
> "fill gaps", "continuous time series", "no missing dates",
> "for every day in the range",
> "include days with no activity", "show zeros not nulls",
> "complete date range", "calendar join", "every business day",
> "dense time series", "no holes", "fill forward"

### Business Context

- **Any domain:** Daily/weekly/monthly metric charts must show 0 for periods with no data — not skip them (missing bars in charts confuse stakeholders)
- **E-commerce:** Daily revenue report showing every day including zero-revenue days (ops alert if day is missing); identify products with zero sales on specific days for out-of-stock detection
- **SaaS:** Weekly active users chart with no gaps; daily signup rate chart needs zeros for days with no signups to correctly compute 7-day rolling averages
- **Logistics:** Daily shipment counts including days with no dispatches; identify warehouse "dark days" (no outbound activity) for capacity planning
- **Finance:** SLA compliance report requires every calendar day — including weekends and holidays — to prove continuous data coverage
- **Retail:** Inventory level per day requires a date spine to forward-fill stock levels on days with no transactions

### Boilerplate — Recursive CTE date spine

```sql
-- Generate all dates between two bounds
WITH RECURSIVE date_spine AS (
    SELECT DATE('2024-01-01') AS dt
    UNION ALL
    SELECT DATE_ADD(dt, INTERVAL 1 DAY)
    FROM date_spine
    WHERE dt < DATE('2024-12-31')
),

daily_trades AS (
    SELECT
        DATE(executed_at) AS trade_date,
        COUNT(*)          AS num_trades
    FROM trades
    GROUP BY 1
)

SELECT
    ds.dt               AS date,
    COALESCE(dt.num_trades, 0) AS num_trades  -- 0 for missing days
FROM date_spine ds
LEFT JOIN daily_trades dt ON ds.dt = dt.trade_date
ORDER BY ds.dt;
```

### Gotchas

- MySQL recursive CTEs require `SET max_sp_recursion_depth` for long ranges — use `generate_series` in PostgreSQL instead
- Always use `LEFT JOIN` from the spine to actual data (not the other way)
- `COALESCE(metric, 0)` handles the NULLs introduced by the LEFT JOIN

### Edge Cases

#### Edge 11-A: Date spine missing leap day

**Problem:**

```sql
-- generate_series or equivalent with hardcoded end date may miss Feb 29 in leap years
-- Example: spine generated for 2024-01-01 to 2024-12-31 (2024 IS a leap year)
-- Feb 29 should be included — generate_series handles this correctly
-- But manual spine using UNION ALL with hardcoded dates often omits Feb 29

-- Safe approach: always use generate_series / SEQUENCE() / DATE_ADD loop
-- Never hardcode individual dates in a date spine

-- Engine-specific date spine patterns:
-- PostgreSQL: generate_series(start, end, '1 day'::INTERVAL)
```

**Fix:**

```sql
-- Always use engine-native sequence generation — never hardcode individual dates:

SELECT generate_series(
    '2024-01-01'::DATE,
    '2024-12-31'::DATE,
    '1 day'::INTERVAL
)::DATE AS spine_date;
-- Feb 29 (2024 is a leap year) is automatically included ✓

WHERE spine_date <= '2024-12-31';

SELECT dt FROM UNNEST(GENERATE_DATE_ARRAY('2024-01-01', '2024-12-31', INTERVAL 1 DAY)) AS dt;

SELECT explode(sequence(DATE '2024-01-01', DATE '2024-12-31', INTERVAL 1 DAY)) AS spine_date;
-- All of these handle leap years correctly — never hardcode UNION ALL lists of dates
```

#### Edge 11-B: Timezone shift creates a 25-hour or 23-hour day in the spine

**Problem:**

```sql
-- For India (IST, UTC+5:30): no DST changes — safe for date spines
-- For US/EU timezones with DST: one day per year has 23 hours, one has 25 hours
-- If your spine is based on UTC dates but events are stored in local time,
-- a 23-hour DST-spring-forward day will have events "on two calendar days"
-- when viewed in UTC but only one calendar day in local time

-- Rule: always store timestamps in UTC, convert to local at presentation layer
-- Build date spines in UTC, join to UTC-timestamped events
-- Never build a date spine in local time and join to UTC events directly
```

**Fix:**

```sql
-- Always store timestamps in UTC and convert to local time only at the presentation layer:
SELECT
    event_id,
    event_at_utc,
FROM events;
-- Date spine is always built in UTC; local date derived at read time, not write time

-- For date spine used in joins: build it in UTC, add a local_date column:
WITH spine AS (
    SELECT generate_series('2024-01-01'::TIMESTAMPTZ, '2024-12-31'::TIMESTAMPTZ, '1 day') AS utc_day
)
SELECT
    utc_day,
    utc_day AT TIME ZONE 'America/New_York' AS ny_day   -- handles DST shift automatically
FROM spine;
-- The 23-hour and 25-hour days in local time are handled transparently
```

---

### At Scale

#### Failure Mechanism

A date spine CROSS JOINed to a large entity table creates a cartesian product:

- 100M users × 365 days = 36.5B row intermediate result
- Even at 10 bytes/row: 365GB of intermediate data — OOM in almost every engine

#### Code-Level Fix

```sql
-- BEFORE: date spine × users to fill daily activity gaps — 36.5B rows
WITH spine AS (
    SELECT generate_series('2024-01-01'::DATE, '2024-12-31'::DATE, '1 day') AS dt
),
user_dates AS (
    SELECT u.user_id, s.dt
    FROM users u             -- 100M users
    CROSS JOIN spine s       -- 365 days
    -- 36.5B rows: OOM or multi-hour query
)
...

-- FIX 1: Only generate spine for ACTIVE users in the relevant period
WITH active_users AS (
    SELECT DISTINCT user_id FROM transactions
    WHERE txn_date >= '2024-01-01'  -- ~2M active users, not 100M total
),
spine AS (
    SELECT generate_series('2024-01-01'::DATE, '2024-12-31'::DATE, '1 day') AS dt
),
user_dates AS (
    SELECT u.user_id, s.dt
    FROM active_users u   -- 2M users
    CROSS JOIN spine s    -- 365 days
    -- 2M × 365 = 730M rows: manageable (not 36.5B)
)
...

-- FIX 2: Avoid generating all user×date combinations — fill forward only where needed
-- Instead of a full cartesian spine, use a sparse LEFT JOIN approach:
-- Generate the spine for dates only, then join to actual activity
SELECT s.dt, t.user_id, COALESCE(SUM(t.amount), 0) AS daily_volume
FROM spine s
CROSS JOIN (SELECT DISTINCT user_id FROM transactions WHERE txn_date >= '2024-01-01') u
LEFT JOIN transactions t ON s.dt = t.txn_date AND u.user_id = t.user_id
GROUP BY s.dt, t.user_id;
-- Still 730M rows if 2M users × 365 days; need the FIX 1 filter

-- FIX 3: Per-entity date spines via generate_series with bounds
-- Only generate dates between each user's first and last activity:
WITH user_bounds AS (
    SELECT user_id, MIN(txn_date) AS min_dt, MAX(txn_date) AS max_dt
    FROM transactions GROUP BY user_id
),
user_spine AS (
    SELECT user_id, generate_series(min_dt, max_dt, '1 day')::DATE AS dt
    FROM user_bounds  -- each user's spine only covers their active period
)
-- This generates much less total rows for users with narrow activity windows
```

#### System-Level Fix


---

---


