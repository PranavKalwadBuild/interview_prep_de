<!-- Part of sql-patterns: Date Functions — Transformation Patterns, Quick Reference, Gotchas -->
<!-- Source: sql_patterns.md lines 1408–1716 -->

### H. Most Common Date Transformation Patterns

These are the patterns that appear in almost every data engineering or analytics SQL interview.

#### H1 — Group by time period (most used)

```sql
-- Group by month (DATE_TRUNC is the most portable approach)
SELECT
    DATE_TRUNC('month', executed_at) AS month,
    COUNT(*)                          AS trades
FROM trades
GROUP BY DATE_TRUNC('month', executed_at)
ORDER BY month;

-- Group by week
SELECT
    DATE_TRUNC('week', executed_at) AS week_start,
    SUM(trade_amount)               AS weekly_volume
FROM trades
GROUP BY DATE_TRUNC('week', executed_at);

-- Group by hour (for intraday analysis)
SELECT
    DATE_TRUNC('hour', executed_at) AS hour_bucket,
    COUNT(*)                         AS trades_per_hour
FROM trades
GROUP BY DATE_TRUNC('hour', executed_at);
```

#### H2 — Day of week analysis (weekday vs weekend)

```sql
-- Find which day of the week has the most trades
SELECT
    EXTRACT(DOW FROM executed_at)          AS day_of_week_num,   -- 0=Sun, 6=Sat (PostgreSQL/Spark)
    TO_CHAR(executed_at, 'Day')            AS day_name,           -- PostgreSQL
    COUNT(*)                               AS trade_count,
    CASE
        WHEN EXTRACT(DOW FROM executed_at) IN (0, 6) THEN 'Weekend'
        ELSE 'Weekday'
    END                                    AS day_type
FROM trades
GROUP BY 1, 2, 4
ORDER BY trade_count DESC;
```

#### H3 — Age / tenure calculation

```sql
-- User age in years at time of trade
SELECT
    user_id,
    date_of_birth,
    executed_at,
    -- PostgreSQL / Snowflake
    EXTRACT(YEAR FROM AGE(executed_at, date_of_birth)) AS age_at_trade,

    -- Universal approach (works everywhere):
    FLOOR(DATEDIFF(executed_at, date_of_birth) / 365.25) AS age_at_trade_universal,

    -- Employee tenure in months
    DATEDIFF('month', hire_date, CURRENT_DATE)           AS tenure_months  -- Snowflake
FROM trades JOIN users USING (user_id);
```

#### H4 — First and last day of a month

```sql
-- First day of the current month
DATE_TRUNC('month', CURRENT_DATE)                          -- PostgreSQL/Snowflake/Spark

-- Last day of the current month
DATE_TRUNC('month', CURRENT_DATE) + INTERVAL '1 month' - INTERVAL '1 day'  -- PostgreSQL/Spark
LAST_DAY(CURRENT_DATE)                                     -- MySQL / Snowflake / Spark SQL
EOMONTH(GETDATE())                                         -- SQL Server

-- First day of next month
DATE_TRUNC('month', CURRENT_DATE) + INTERVAL '1 month'

-- First day of the year
DATE_TRUNC('year', CURRENT_DATE)

-- Last day of the year
DATE_TRUNC('year', CURRENT_DATE) + INTERVAL '1 year' - INTERVAL '1 day'
```

#### H5 — Fiscal year / quarter (when fiscal year ≠ calendar year)

```sql
-- Example: fiscal year starts April 1 (common in UK/India)
SELECT
    executed_at,
    -- Fiscal year: Jan–Mar belongs to prior year's FY
    CASE
        WHEN EXTRACT(MONTH FROM executed_at) >= 4
        THEN EXTRACT(YEAR FROM executed_at)
        ELSE EXTRACT(YEAR FROM executed_at) - 1
    END AS fiscal_year,

    -- Fiscal quarter
    CASE
        WHEN EXTRACT(MONTH FROM executed_at) BETWEEN 4  AND 6  THEN 'Q1'
        WHEN EXTRACT(MONTH FROM executed_at) BETWEEN 7  AND 9  THEN 'Q2'
        WHEN EXTRACT(MONTH FROM executed_at) BETWEEN 10 AND 12 THEN 'Q3'
        WHEN EXTRACT(MONTH FROM executed_at) BETWEEN 1  AND 3  THEN 'Q4'
    END AS fiscal_quarter
FROM trades;
```

#### H6 — "Same period last year" date offset

```sql
-- Get the equivalent date one year ago (for YoY comparisons)
SELECT
    trade_date,
    revenue,
    -- Go back exactly 1 year
    trade_date - INTERVAL '1 year'           AS same_date_ly,     -- PostgreSQL/Spark
    DATEADD(year, -1, trade_date)            AS same_date_ly_sf,  -- Snowflake/SQL Server
    DATE_SUB(trade_date, INTERVAL 1 YEAR)    AS same_date_ly_my   -- MySQL

FROM daily_revenue;

-- YoY comparison using LAG or self-join:
WITH monthly AS (
    SELECT DATE_TRUNC('month', executed_at) AS month, SUM(trade_amount) AS vol
    FROM trades GROUP BY 1
)
SELECT
    curr.month,
    curr.vol                                      AS current_vol,
    prev.vol                                      AS prior_year_vol,
    ROUND((curr.vol - prev.vol) / prev.vol * 100, 2) AS yoy_growth_pct
FROM monthly curr
LEFT JOIN monthly prev
    ON prev.month = curr.month - INTERVAL '1 year';
```

#### H7 — Time bucket / histogram over hours or minutes

```sql
-- Count events per 15-minute bucket
SELECT
    DATE_TRUNC('hour', executed_at)
        + (EXTRACT(MINUTE FROM executed_at)::INT / 15) * INTERVAL '15 minutes'
        AS bucket_15min,
    COUNT(*) AS events
FROM trades
GROUP BY 1
ORDER BY 1;

-- Simpler using integer division (Spark SQL / BigQuery):
SELECT
    TIMESTAMP_TRUNC(executed_at, MINUTE) AS minute_bucket,   -- BigQuery
    COUNT(*) AS events
FROM trades
GROUP BY 1;
```

#### H8 — Check if a date falls within a range (SLA / validity windows)

```sql
-- Active records: valid_from <= check_date < valid_to
SELECT *
FROM user_tiers
WHERE valid_from <= CURRENT_DATE
  AND (valid_to IS NULL OR valid_to > CURRENT_DATE);

-- Records modified in the last 7 days
SELECT *
FROM trades
WHERE executed_at >= CURRENT_DATE - INTERVAL '7 days'
  AND executed_at <  CURRENT_DATE + INTERVAL '1 day';  -- inclusive of today

-- BETWEEN for dates: INCLUSIVE on both ends — be careful with timestamps
-- BAD for timestamps:
WHERE executed_at BETWEEN '2024-01-01' AND '2024-01-31'  -- misses 2024-01-31 23:59:59

-- GOOD:
WHERE executed_at >= '2024-01-01' AND executed_at < '2024-02-01'
```

#### H9 — Unix timestamp / epoch conversion

```sql
-- Timestamp → epoch (seconds since 1970-01-01)
EXTRACT(EPOCH FROM executed_at)               -- PostgreSQL
UNIX_TIMESTAMP(executed_at)                   -- MySQL / Spark SQL
DATE_PART('epoch', executed_at)               -- Snowflake / DuckDB
UNIX_SECONDS(executed_at)                     -- BigQuery (TIMESTAMP)

-- Epoch → timestamp
TO_TIMESTAMP(1710000000)                      -- PostgreSQL / Snowflake
FROM_UNIXTIME(1710000000)                     -- MySQL / Spark SQL
TIMESTAMP_SECONDS(1710000000)                 -- BigQuery

-- Why useful in SQL:
-- RANGE BETWEEN numeric intervals uses epoch for time-based rolling windows
SUM(amount) OVER (
    PARTITION BY user_id
    ORDER BY UNIX_TIMESTAMP(trade_date)        -- numeric ORDER BY for RANGE
    RANGE BETWEEN 604800 PRECEDING AND CURRENT ROW  -- 7 days = 7×86400 seconds
)
```

#### H10 — Timezone handling

```sql
-- Convert UTC timestamp to a local timezone
-- PostgreSQL
executed_at AT TIME ZONE 'UTC' AT TIME ZONE 'Asia/Kolkata'
executed_at AT TIME ZONE 'Asia/New_York'

-- Snowflake
CONVERT_TIMEZONE('UTC', 'America/New_York', executed_at)
CONVERT_TIMEZONE('Asia/Kolkata', executed_at)    -- assumes source is UTC

-- BigQuery
TIMESTAMP(executed_at, 'Asia/Kolkata')
DATETIME(executed_at, 'America/New_York')

-- MySQL / Spark SQL
CONVERT_TZ(executed_at, 'UTC', 'Asia/Kolkata')

-- General rule: always store timestamps in UTC in the warehouse;
-- convert to local timezone only at presentation/reporting layer
```

#### H11 — Working days / business days between two dates

SQL has no built-in business days function — the standard approach uses a date spine or calendar table with an `is_business_day` flag:

```sql
-- Using a pre-built calendar table:
SELECT
    t.trade_id,
    COUNT(*) AS business_days_to_settle
FROM trades t
JOIN calendar c
    ON c.dt BETWEEN t.trade_date AND t.settlement_date
    AND c.is_business_day = TRUE
    AND c.is_holiday = FALSE
GROUP BY t.trade_id;

-- Without a calendar table (approximate — counts Mon–Fri only, ignores public holidays):
SELECT
    DATEDIFF(end_date, start_date)
    - (DATEDIFF(end_date, start_date) / 7) * 2
    - CASE WHEN DAYOFWEEK(start_date) = 1 THEN 1 ELSE 0 END
    - CASE WHEN DAYOFWEEK(end_date)   = 7 THEN 1 ELSE 0 END
    AS approx_business_days
FROM sla_records;
```

#### H12 — Date normalization and cleaning

```sql
-- Safely cast a string column that may have nulls or bad formats:
CASE
    WHEN date_str REGEXP '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
    THEN CAST(date_str AS DATE)
    ELSE NULL
END AS clean_date

-- Snowflake / SQL Server: TRY_CAST for safe conversion
TRY_CAST(date_str AS DATE)   -- returns NULL instead of error on bad input

-- BigQuery: SAFE.PARSE_DATE
SAFE.PARSE_DATE('%Y-%m-%d', date_str)

-- Truncate a timestamp to date only (remove time component)
CAST(executed_at AS DATE)                   -- most engines
DATE(executed_at)                           -- MySQL / BigQuery / Spark
CONVERT(DATE, executed_at)                  -- SQL Server
```sql

---

### I. Date Function Quick Reference

| Operation | PostgreSQL | MySQL / Spark | Snowflake | BigQuery | SQL Server |
|---|---|---|---|---|---|
| Current date | `CURRENT_DATE` | `CURDATE()` | `CURRENT_DATE` | `CURRENT_DATE()` | `CAST(GETDATE() AS DATE)` |
| Current timestamp | `NOW()` | `NOW()` | `CURRENT_TIMESTAMP` | `CURRENT_TIMESTAMP()` | `GETDATE()` |
| Extract year | `EXTRACT(YEAR FROM d)` | `YEAR(d)` | `YEAR(d)` | `EXTRACT(YEAR FROM d)` | `YEAR(d)` |
| Truncate to month | `DATE_TRUNC('month',d)` | `DATE_FORMAT(d,'%Y-%m-01')` | `DATE_TRUNC('month',d)` | `DATE_TRUNC(d, MONTH)` | `DATETRUNC(month,d)` |
| Add 7 days | `d + INTERVAL '7 days'` | `DATE_ADD(d, INTERVAL 7 DAY)` | `DATEADD(day,7,d)` | `DATE_ADD(d, INTERVAL 7 DAY)` | `DATEADD(day,7,d)` |
| Days between | `end - start` (integer) | `DATEDIFF(end,start)` | `DATEDIFF('day',start,end)` | `DATE_DIFF(end,start,DAY)` | `DATEDIFF(day,start,end)` |
| Day of week | `EXTRACT(DOW FROM d)` | `DAYOFWEEK(d)` | `DAYOFWEEK(d)` | `EXTRACT(DAYOFWEEK FROM d)` | `DATEPART(dw,d)` |
| Last day of month | `date_trunc + 1 month - 1 day` | `LAST_DAY(d)` | `LAST_DAY(d)` | `LAST_DAY(d)` | `EOMONTH(d)` |
| To epoch | `EXTRACT(EPOCH FROM ts)` | `UNIX_TIMESTAMP(ts)` | `DATE_PART('epoch',ts)` | `UNIX_SECONDS(ts)` | `DATEDIFF(s,'1970-01-01',ts)` |
| Format as string | `TO_CHAR(d,'YYYY-MM')` | `DATE_FORMAT(d,'%Y-%m')` | `TO_VARCHAR(d,'YYYY-MM')` | `FORMAT_DATE('%Y-%m',d)` | `FORMAT(d,'yyyy-MM')` |
| Parse string to date | `TO_DATE(s,'DD/MM/YYYY')` | `STR_TO_DATE(s,'%d/%m/%Y')` | `TO_DATE(s,'DD/MM/YYYY')` | `PARSE_DATE('%d/%m/%Y',s)` | `CONVERT(DATE,s,103)` |

---

### J. Gotchas with Dates

- **BETWEEN with timestamps is inclusive on both bounds** — `BETWEEN '2024-01-01' AND '2024-01-31'` misses the last day's afternoon. Use `>= start AND < end + 1 day` instead.
- **Implicit string-to-date casting is engine-specific** — `WHERE date_col = '2024-01-15'` works in most engines but the string must be ISO 8601 (YYYY-MM-DD). Non-standard formats will fail or produce wrong results silently.
- **NULL in date arithmetic** — any arithmetic on NULL returns NULL. Use `COALESCE(end_date, CURRENT_DATE)` to handle open-ended intervals.
- **DATEDIFF argument order is reversed between MySQL and SQL Server/Snowflake** — MySQL: `DATEDIFF(end, start)`, SQL Server: `DATEDIFF(unit, start, end)`, Snowflake: `DATEDIFF(unit, start, end)`. This is the #1 date bug in interview questions.
- **DATE_TRUNC on a DATE type vs TIMESTAMP type** — truncating a DATE type to 'hour' or 'minute' is a no-op or error in most engines. Ensure the column is a TIMESTAMP before truncating to sub-day units.
- **Leap years and month-end arithmetic** — `'2024-01-31' + INTERVAL '1 month'` gives `2024-02-29` in some engines and errors in others. Test month-end date arithmetic explicitly.
- **Timezone-naïve vs timezone-aware timestamps** — mixing TIMESTAMP and TIMESTAMPTZ in the same query produces unexpected offsets. Standardise on UTC at ingest and convert only for display.

---

