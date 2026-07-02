<!-- sql-patterns: Date Functions — Transformation Patterns, Quick Reference, Gotchas -->

# H. Most Common Date Transformation Patterns

These are the patterns that appear in almost every data engineering or analytics SQL interview.

## H1 — Group by time period (most used)

-- ANSI SQL approach: Extract year/month for grouping (most portable)
-- When you need period-start values for display, use fallbacks below
SELECT
    (EXTRACT(YEAR FROM executed_at) * 100 + EXTRACT(MONTH FROM executed_at)) AS year_month,
    COUNT(*)                          AS trades
FROM trades
GROUP BY EXTRACT(YEAR FROM executed_at), EXTRACT(MONTH FROM executed_at)
ORDER BY year_month;

-- PostgreSQL fallback: DATE_TRUNC for when you need timestamp values
SELECT
    DATE_TRUNC('month', executed_at) AS month_start,
    COUNT(*)                          AS trades
FROM trades
GROUP BY DATE_TRUNC('month', executed_at)
ORDER BY month_start;

-- MySQL fallback: DATE_FORMAT for period grouping
SELECT
    DATE_FORMAT(executed_at, '%Y-%m') AS year_month,
    COUNT(*)                          AS trades
FROM trades
GROUP BY DATE_FORMAT(executed_at, '%Y-%m')
ORDER BY year_month;

-- Group by week (ANSI SQL approach)
SELECT
    EXTRACT(YEAR FROM executed_at) AS year,
    EXTRACT(WEEK FROM executed_at) AS week_number,
    SUM(trade_amount)               AS weekly_volume
FROM trades
GROUP BY EXTRACT(YEAR FROM executed_at), EXTRACT(WEEK FROM executed_at)
ORDER BY year, week_number;

-- Group by hour (ANSI SQL approach)
SELECT
    EXTRACT(YEAR FROM executed_at) AS year,
    EXTRACT(MONTH FROM executed_at) AS month,
    EXTRACT(DAY FROM executed_at) AS day,
    EXTRACT(HOUR FROM executed_at) AS hour,
    COUNT(*)                         AS trades_per_hour
FROM trades
GROUP BY EXTRACT(YEAR FROM executed_at), EXTRACT(MONTH FROM executed_at), 
         EXTRACT(DAY FROM executed_at), EXTRACT(HOUR FROM executed_at)
ORDER BY year, month, day, hour;

## H2 — Day of week analysis (weekday vs weekend)


## H3 — Age / tenure calculation


## H4 — First and last day of a month


## H5 — Fiscal year / quarter (when fiscal year ≠ calendar year)

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

## H6 — "Same period last year" date offset


## H7 — Time bucket / histogram over hours or minutes


## H8 — Check if a date falls within a range (SLA / validity windows)

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

## H9 — Unix timestamp / epoch conversion


## H10 — Timezone handling


## H11 — Working days / business days between two dates

SQL has no built-in business days function — the standard approach uses a date spine or calendar table with an `is_business_day` flag:


## H12 — Date normalization and cleaning


---

# I. Date Function Quick Reference

| Function | ANSI SQL | PostgreSQL Fallback | MySQL Fallback |
|---|---|---|---|
| Current date | `CURRENT_DATE` | `CURRENT_DATE` | `CURRENT_DATE` |
| Current timestamp | `CURRENT_TIMESTAMP` | `CURRENT_TIMESTAMP` | `CURRENT_TIMESTAMP` |
| Extract year | `EXTRACT(YEAR FROM d)` | `EXTRACT(YEAR FROM d)` | `EXTRACT(YEAR FROM d)` |
| Truncate to month* | Range comparisons | `DATE_TRUNC('month',d)` | `DATE_FORMAT(d,'%Y-%m-01')` |
| Last day of month* | `date_trunc + 1 month - 1 day`^ | `date_trunc + 1 month - 1 day` | `LAST_DAY(d)` |
| Format as string** | Presentation layer | `TO_CHAR(d,'YYYY-MM')` | `DATE_FORMAT(d,'%Y-%m')` |
| Parse string to date | `CAST` (ISO formats) | `TO_DATE(s,'DD/MM/YYYY')` | `STR_TO_DATE(s,'%d/%m/%Y')` |

> * No direct ANSI SQL equivalent - use range comparisons for filtering
> ^ Uses date arithmetic which may vary by engine; see specific fallback implementations  
> ** ANSI SQL lacks date formatting - implement in application layer when possible

---

# J. Gotchas with Dates

- **BETWEEN with timestamps is inclusive on both bounds** — `BETWEEN '2024-01-01' AND '2024-01-31'` misses the last day's afternoon. Use `>= start AND < end + 1 day` instead.
  
  **Why it happens:** The BETWEEN operator includes both endpoints. For timestamps, '2024-01-31' is interpreted as '2024-01-31 00:00:00', so any time after midnight on Jan 31 is excluded.
  
  **Examples of problematic queries:**
  - `WHERE created_at BETWEEN '2024-01-01' AND '2024-01-31'` misses all Jan 31 events after midnight
  - `WHERE modified_on BETWEEN '2024-06-30' AND '2024-07-01'` misses most of July 1st
  
  **Fixed patterns:**
  - `WHERE created_at >= '2024-01-01' AND created_at < '2024-02-01'` (includes all Jan 1-31)
  - `WHERE modified_on >= '2024-06-30' AND modified_on < '2024-07-02'` (includes June 30 and July 1)
  
  **Best practice:** Always use half-open intervals [start, end) for datetime ranges.

- **Implicit string-to-date casting is engine-specific** — `WHERE date_col = '2024-01-15'` works in most engines but the string must be ISO 8601 (YYYY-MM-DD). Non-standard formats will fail or produce wrong results silently.
  
  **Why it happens:** Different databases have different rules for implicit casting. Some are strict, others attempt interpretation based on locale settings.
  
  **Examples of failures:**
  - `'01/15/2024'` might be interpreted as Jan 15 (US) or Jan 5 (European) depending on locale
  - `'15-Jan-2024'` works in some engines but fails in others
  - Empty strings or invalid dates may convert to NULL or default dates silently
  
  **Prevention techniques:**
  - Always use explicit casting: `WHERE date_col = CAST('2024-01-15' AS DATE)`
  - Use ISO 8601 format (YYYY-MM-DD) for maximum compatibility
  - Validate date inputs before use in queries
  - Consider using parameterized queries to avoid casting issues entirely

- **NULL in date arithmetic** — any arithmetic on NULL returns NULL. Use `COALESCE(end_date, CURRENT_DATE)` to handle open-ended intervals.
  
  **Why it happens:** In SQL, NULL represents unknown values. Any operation involving unknown results in unknown.
  
  **Examples of silent errors:**
  - `SELECT DATEDIFF(day, start_date, end_date)` returns NULL when end_date is NULL
  - `WHERE DATE_ADD(created_at, INTERVAL 30 DAY) > CURRENT_DATE` excludes rows where created_at is NULL
  - `AVG(DATEDIFF(day, start_date, end_date))` skews results if NULLs are treated as zero vs excluded
  
  **Solutions:**
  - Use `COALESCE` or `IFNULL` to provide defaults: `COALESCE(end_date, CURRENT_DATE)`
  - Filter out NULLs explicitly when they don't make sense for the calculation
  - Consider using NULLIF to prevent division by zero in derived calculations

- **DATE_TRUNC on a DATE type vs TIMESTAMP type** — truncating a DATE type to 'hour' or 'minute' is a no-op or error in most engines. Ensure the column is a TIMESTAMP before truncating to sub-day units.
  
  **Why it happens:** DATE types don't have time components, so truncating to sub-day intervals has no effect or causes errors.
  
  **Examples of issues:**
  - `DATE_TRUNC('hour', DATE '2024-01-15')` returns the same date (no time to truncate)
  - `DATE_TRUNC('minute', DATE '2024-01-15')` may return error in some engines
  - Mixing DATE and TIMESTAMP in same operation can cause implicit conversions
  
  **Best practices:**
  - Store timestamps as TIMESTAMP/TIMESTAMPTZ when time component matters
  - Use explicit casting: `DATE_TRUNC('hour', CAST(date_col AS TIMESTAMP))`
  - Check column types in your schema before applying truncation functions
  - Consider using EXTRACT for getting specific date parts instead of truncation

- **Leap years and month-end arithmetic** — `'2024-01-31' + INTERVAL '1 month'` gives `2024-02-29` in some engines and errors in others. Test month-end date arithmetic explicitly.
  
  **Why it happens:** Months have varying lengths (28-31 days), and leap years add complexity to February.
  
  **Examples of inconsistent behavior:**
  - `'2024-01-31' + INTERVAL '1 month'` → `'2024-02-29'` (correct for leap year)
  - `'2023-01-31' + INTERVAL '1 month'` → `'2023-02-28'` (correct for non-leap year)
  - `'2024-03-31' + INTERVAL '1 month'` → error or `'2024-04-30'` (April has 30 days)
  
  **Safer approaches:**
  - For month boundaries: Use `DATE_ADD(month_start, INTERVAL 1 month)` where month_start is first day of month
  - For elapsed time: Calculate exact day difference instead of assuming 30 days/month
  - For reporting: Use calendar tables with pre-computed month boundaries
  - Always test edge cases: Jan 31, Mar 31, May 31, Aug 31, Oct 31, Dec 31, and leap year Feb 29

- **Timezone-naïve vs timezone-aware timestamps** — mixing TIMESTAMP and TIMESTAMPTZ in the same query produces unexpected offsets. Standardise on UTC at ingest and convert only for display.
  
  **Why it happens:** TIMESTAMP is often timezone-naïve (assumes server timezone), while TIMESTAMPTZ stores UTC with timezone metadata.
  
  **Examples of timezone errors:**
  - Comparing `TIMESTAMP '2024-01-15 12:00:00'` (server time) with `TIMESTAMPTZ '2024-01-15 12:00:00+00'` (UTC)
  - Converting between timezones incorrectly due to assuming wrong base timezone
  - Daylight saving time transitions causing skipped or duplicated hours
  
  **Best practices:**
  - Store all timestamps in UTC using TIMESTAMPTZ or equivalent
  - Convert to local time only for display purposes
  - Be explicit about timezones: `TIMESTAMP '2024-01-15 12:00:00 America/New_York'`
  - Use AT TIME ZONE clause for conversions when supported
  - Test applications across different timezone scenarios and DST transitions

---


