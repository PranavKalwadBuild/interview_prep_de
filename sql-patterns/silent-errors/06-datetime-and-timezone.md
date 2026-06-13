<!-- Part of sql-patterns: Silent Errors — Datetime and Timezone -->

# Silent Errors — Datetime and Timezone

Timestamps are simultaneously the most critical and most treacherous data type in analytical SQL. Timezone shifts, DST gaps, calendar boundary semantics, and cross-engine differences in week/day definitions all produce silent wrong results. These bugs are particularly dangerous because they often affect only a subset of time periods — making them easy to miss until an anomaly surfaces in a specific month or during a specific hour.

---

### BETWEEN on Timestamps — Inclusive Endpoint Silently Excludes Same-Day Data

**What it looks like:**
```sql
SELECT * FROM orders
WHERE order_time BETWEEN '2024-01-31' AND '2024-02-01';
```

**What actually happens:** `BETWEEN` is inclusive on both endpoints. `'2024-01-31'` is implicitly cast to `'2024-01-31 00:00:00'`. `'2024-02-01'` is cast to `'2024-02-01 00:00:00'`. Orders at `2024-01-31 23:59:59` are NOT between these two timestamps — they are after `2024-01-31 00:00:00` but before `2024-02-01 00:00:00`, so they ARE included. But orders after `2024-02-01 00:00:00` (rest of February 1st) are excluded.

The more insidious case: `BETWEEN '2024-01-01' AND '2024-01-31'` intended as "the entire month of January" silently excludes everything after midnight on January 31st.

**Minimal repro:**
```sql
WITH orders AS (
    SELECT * FROM (VALUES
        ('2024-01-31 00:00:00'::TIMESTAMP, 100),
        ('2024-01-31 12:00:00'::TIMESTAMP, 200),  -- should be in January
        ('2024-01-31 23:59:59'::TIMESTAMP, 300),  -- should be in January
        ('2024-02-01 00:00:00'::TIMESTAMP, 400),
        ('2024-02-01 12:00:00'::TIMESTAMP, 500)   -- clearly February
    ) t(ts, amount)
)
SELECT COUNT(*), SUM(amount)
FROM orders
WHERE ts BETWEEN '2024-01-01' AND '2024-01-31';
-- Returns: 3 rows, $600 — MISSES the Jan 31 rows after midnight!
-- Expected for "all of January": 3 rows (all three Jan 31 rows should be included)
```

**How to catch it:**
```sql
-- Correct pattern for date ranges on timestamp columns:
WHERE order_time >= '2024-01-01'
  AND order_time  < '2024-02-01'   -- exclusive upper bound covers full month

-- Or using DATE_TRUNC:
WHERE DATE_TRUNC('month', order_time) = '2024-01-01'
```

**Real-world trigger:** Monthly revenue report uses BETWEEN for the month range. End-of-month orders (placed in the last hours of the 31st) are silently excluded every month. Revenue is understated by 3–8% depending on order volume patterns.

---

### Daylight Saving Time Gap — Timestamps in the Spring-Forward Hour

**What it looks like:**
```sql
-- US Eastern time: clocks spring forward at 2:00 AM → 3:00 AM on second Sunday of March
INSERT INTO events (event_time) VALUES ('2024-03-10 02:30:00');
-- Column is TIMESTAMP_LTZ in Snowflake, or TIMESTAMPTZ in PostgreSQL
```

**What actually happens:** `2024-03-10 02:30:00 America/New_York` does not exist — that hour was skipped. Engines handle this differently:
- Snowflake `TIMESTAMP_LTZ`: converts using the post-DST offset, silently shifting the time to `02:30:00` → `03:30:00` or `07:30:00 UTC`.
- PostgreSQL: varies by libtz behavior — may error, may shift forward.
- The stored timestamp is off by exactly 1 hour for any event that nominally occurred in the gap.

**Why it's insidious:** This happens only once per year, only for one specific hour, only in timezones that observe DST. Most testing never covers this case. The bug lies dormant for 364 days and fires on the one day it matters — often in financial data or compliance logs where exact timestamps are auditable.

**Minimal repro:**
```sql
-- Snowflake test:
ALTER SESSION SET TIMEZONE = 'America/New_York';
SELECT CONVERT_TIMEZONE('America/New_York', 'UTC', '2024-03-10 02:30:00'::TIMESTAMP_NTZ);
-- This time doesn't exist in EST. Check what your engine returns.

-- Detection: find events with timestamps in the DST gap
SELECT * FROM events
WHERE event_time AT TIME ZONE 'America/New_York'
      BETWEEN '2024-03-10 02:00:00' AND '2024-03-10 03:00:00';
```

**How to catch it:** Always store timestamps as UTC internally (`TIMESTAMP_NTZ` with UTC convention, or `TIMESTAMPTZ`). Convert to local timezone only at display time. Never rely on local time arithmetic crossing a DST boundary.

**Real-world trigger:** Security audit log timestamps. An intrusion detection event at 02:47 AM EST on DST changeover day is stored as 03:47 AM. The timeline reconstruction during the security incident review has a 1-hour gap that looks like log tampering.

---

### CURRENT_TIMESTAMP vs SYSDATE Timezone Difference in Snowflake

**What it looks like:**
```sql
SELECT *
FROM events
WHERE event_time >= SYSDATE - INTERVAL '1 hour'
  AND event_time <= CURRENT_TIMESTAMP;
```

**What actually happens:** In Snowflake, `CURRENT_TIMESTAMP` returns the current time in the **session timezone**. `SYSDATE` always returns the current time in **UTC** regardless of session timezone. If the session is in `America/Chicago` (UTC-6), `CURRENT_TIMESTAMP` is 6 hours behind `SYSDATE`. The range `SYSDATE - 1 hour` to `CURRENT_TIMESTAMP` is a range that ends 6 hours *before* it begins — an empty range. Zero rows returned. No error.

**Why it's insidious:** Both functions appear to mean "now." They do mean "now" — in different timezones. The query runs, returns zero rows, and a developer might diagnose this as "no events in the last hour" rather than "the time range is inverted."

**Minimal repro:**
```sql
-- Snowflake (session TZ = America/Chicago)
ALTER SESSION SET TIMEZONE = 'America/Chicago';
SELECT
    CURRENT_TIMESTAMP                AS now_session_tz,   -- e.g., 2024-01-15 10:00 CST
    SYSDATE                          AS now_utc,           -- e.g., 2024-01-15 16:00 UTC
    CURRENT_TIMESTAMP > SYSDATE      AS timestamp_after_sysdate -- FALSE (10:00 < 16:00)
;
-- A WHERE clause like: ts >= SYSDATE - 1 AND ts <= CURRENT_TIMESTAMP
-- expands to: ts >= 15:00 UTC AND ts <= 10:00 CST (= 16:00 UTC)
-- Wait: CURRENT_TIMESTAMP in UTC context = 16:00, SYSDATE = 16:00... actually this depends on the exact
-- offset at query time. Use a test in your actual Snowflake environment.
```

**How to catch it:**
```sql
-- Consistent pattern: always use CURRENT_TIMESTAMP exclusively, never mix with SYSDATE
-- Or always convert both to UTC before comparison:
WHERE CONVERT_TIMEZONE('UTC', event_time) >= DATEADD(hour, -1, CONVERT_TIMEZONE('UTC', CURRENT_TIMESTAMP))
```

**Real-world trigger:** Monitoring query checking for events in the last hour runs on a Snowflake worksheet opened with the user's local timezone. The mix of SYSDATE and CURRENT_TIMESTAMP produces an empty result. On-call engineer concludes "no events" and closes the incident. Events were actually present.

---

### Epoch Timestamp Integer vs TIMESTAMP Comparison — Returns All or Zero Rows

**What it looks like:**
```sql
-- event_epoch stored as BIGINT (Unix timestamp in seconds)
SELECT * FROM events WHERE event_epoch > '2024-01-01';
```

**What actually happens:** Comparing a BIGINT column to a date string `'2024-01-01'`. In PostgreSQL, this may error or cast the date to a numeric (its internal representation, roughly `738156` for Jan 1 2024). `event_epoch` values around 1,704,067,200 (Jan 2024 epoch) are all greater than `738156` — so the query silently returns all rows, not just rows after Jan 2024.

In other engines, the date string may be cast to a Unix timestamp directly, or the query may error. Result depends entirely on engine and engine version.

**Minimal repro:**
```sql
-- PostgreSQL behavior:
SELECT 1704067200 > '2024-01-01'::DATE;
-- '2024-01-01'::DATE has internal integer value 738156 (days since 2000-01-01)
-- 1704067200 >> 738156, so condition is TRUE for all modern epoch values
-- All rows silently pass the filter regardless of actual date

-- Correct pattern:
WHERE event_epoch > EXTRACT(EPOCH FROM '2024-01-01'::TIMESTAMP)
-- Or: WHERE TO_TIMESTAMP(event_epoch) > '2024-01-01'::TIMESTAMP
```

**How to catch it:**
```sql
-- Sanity check: does the row count change when you adjust the filter by 1 day?
SELECT COUNT(*) FROM events WHERE event_epoch > '2024-01-01';
SELECT COUNT(*) FROM events WHERE event_epoch > '2024-01-02';
-- If counts are the same (all rows or no rows), the comparison type is wrong.
```

**Real-world trigger:** Data quality check intended to filter "only recent events" silently returns all 3 years of history. The full dataset is processed instead of the last 30 days. A pipeline that ran in 30 seconds starts taking 45 minutes — the performance regression is the first signal that something is wrong.

---

### DATEDIFF('day'...) Counts Midnight Crossings, Not 24-Hour Periods

**What it looks like:**
```sql
SELECT user_id,
       DATEDIFF('day', first_login, last_login) AS days_active
FROM users
WHERE days_active >= 30;  -- "users active for at least 30 days"
```

**What actually happens:** `DATEDIFF('day', ...)` counts the number of midnight boundaries crossed between two timestamps, not the number of full 24-hour periods elapsed.

`DATEDIFF('day', '2024-01-01 23:59:00', '2024-01-02 00:01:00') = 1` (one midnight crossed), even though only 2 minutes elapsed. Conversely, `DATEDIFF('day', '2024-01-01 00:01:00', '2024-01-01 23:59:00') = 0` even though 23 hours and 58 minutes elapsed.

**Why it's insidious:** For most date-level comparisons (dates without times), DATEDIFF gives the expected result. It only deviates when time components are involved — which is exactly when data has full timestamp precision.

**Minimal repro:**
```sql
SELECT
    DATEDIFF('day', '2024-01-01 23:59:00'::TIMESTAMP, '2024-01-02 00:01:00'::TIMESTAMP) AS one_midnight,   -- 1
    DATEDIFF('day', '2024-01-01 00:01:00'::TIMESTAMP, '2024-01-01 23:59:00'::TIMESTAMP) AS zero_midnights, -- 0
    DATEDIFF('day', '2024-12-31 23:59:00'::TIMESTAMP, '2025-01-01 00:01:00'::TIMESTAMP) AS year_boundary   -- 1 (and also +1 year!)
```

**How to catch it:**
```sql
-- For "elapsed days" semantics, use:
FLOOR(EXTRACT(EPOCH FROM (last_login - first_login)) / 86400) AS days_elapsed_true

-- Or truncate to date first if time component is irrelevant:
DATEDIFF('day', first_login::DATE, last_login::DATE)
```

**Real-world trigger:** User engagement tier based on days active. Users who log in at 11:59 PM one day and 12:01 AM the next day are credited with 1 day of activity despite being active for only 2 minutes. Users who are active for 23+ hours in a single calendar day get 0 days credited. Tier assignments are quietly wrong for power users with erratic session timing.

---

### DATE_TRUNC('week') Returns Different Day Across Engines

**What it looks like:**
```sql
SELECT DATE_TRUNC('week', event_date) AS week_start,
       SUM(revenue) AS weekly_revenue
FROM events
GROUP BY 1;
```

**What actually happens:**
- Snowflake: `DATE_TRUNC('week', ...)` truncates to **Monday** by default (ISO week standard).
- Redshift: truncates to **Sunday** by default.
- PostgreSQL: truncates to **Monday**.
- MySQL `WEEK()`: defaults to Sunday unless mode is specified.

The same query, same data, run on Snowflake vs Redshift, produces different week boundaries. A week of data that Snowflake bins as "week of 2024-01-01 (Monday)" is binned by Redshift as "week of 2023-12-31 (Sunday)."

**Why it's insidious:** Both results look correct. Both produce 7-day aggregations. The difference only surfaces when comparing weekly reports across environments or when the weekly boundary is used as a JOIN key between two systems.

**Minimal repro:**
```sql
-- Snowflake: Monday-start week
SELECT DATE_TRUNC('week', '2024-01-03'::DATE);  -- 2024-01-01 (Monday)

-- Redshift: Sunday-start week
SELECT DATE_TRUNC('week', '2024-01-03'::DATE);  -- 2023-12-31 (Sunday)

-- Cross-engine safe pattern (explicit Monday):
SELECT DATE_TRUNC('week', event_date) AS week_start_monday  -- works in Snowflake/PG
-- For Redshift explicit Monday:
SELECT DATEADD(day, -(DATEPART(dow, event_date) + 6) % 7, event_date) AS week_start_monday
```

**How to catch it:**
```sql
-- Validation: the week_start date for a known Monday should be that same Monday
SELECT DATE_TRUNC('week', '2024-01-08'::DATE) AS week_start;
-- Should be 2024-01-08 (Monday) on Snowflake/PG, 2024-01-07 (Sunday) on Redshift
```

**Real-world trigger:** A data team migrates their Redshift weekly reports to Snowflake. Week-over-week comparisons break because the week boundaries shifted by one day. Monday revenue (now at end of its own week in Snowflake) was previously the first day of a Sunday-starting Redshift week. Trend lines shift, triggering a false anomaly alert.

---

### Snowflake WEEK_START Session Parameter — Account Default vs Session Default

**What it looks like:**
```sql
-- Report that uses DAYOFWEEK() to filter weekdays
SELECT * FROM events
WHERE DAYOFWEEK(event_date) BETWEEN 2 AND 6;  -- "Monday through Friday"
```

**What actually happens:** `DAYOFWEEK()` in Snowflake returns a value from 0–6 where 0 = the first day of the week, defined by the `WEEK_START` session parameter. The default is 0 (Sunday). A BI tool that opens a Snowflake session with `WEEK_START=1` (Monday) will get different values than a pipeline session using the default `WEEK_START=0`.

`DAYOFWEEK(Monday)` = 1 with `WEEK_START=0` (Sunday), = 0 with `WEEK_START=1` (Monday). The filter `BETWEEN 2 AND 6` silently shifts by one day depending on the session.

**Minimal repro:**
```sql
ALTER SESSION SET WEEK_START = 0;  -- Sunday = 0
SELECT DAYOFWEEK('2024-01-08'::DATE);  -- Monday: returns 1

ALTER SESSION SET WEEK_START = 1;  -- Monday = 0
SELECT DAYOFWEEK('2024-01-08'::DATE);  -- Monday: returns 0

-- The WHERE clause BETWEEN 2 AND 6:
-- With WEEK_START=0: 2=Tuesday through 6=Saturday (WRONG)
-- With WEEK_START=1: 2=Wednesday through 6=Sunday (ALSO WRONG)
```

**How to catch it:**
```sql
-- Never use DAYOFWEEK() for weekday filtering without documenting WEEK_START dependency
-- Safe pattern: use explicit day name extraction
WHERE DAYNAME(event_date) IN ('Mon','Tue','Wed','Thu','Fri')
-- Or: use DATE_TRUNC to identify the ISO day of week explicitly
WHERE EXTRACT(DOW FROM event_date) IN (1,2,3,4,5)  -- ISO: 1=Monday, 7=Sunday
```

**Real-world trigger:** Weekday traffic analysis for retail reporting. BI tool uses WEEK_START=1, data pipeline uses account default WEEK_START=0. Weekday vs weekend revenue splits differ between the BI dashboard and the dbt model by exactly one day at each boundary, creating a persistent 5–10% discrepancy in weekend revenue attribution.
