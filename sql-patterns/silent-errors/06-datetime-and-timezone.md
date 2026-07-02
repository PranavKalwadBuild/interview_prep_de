<!-- sql-patterns: Silent Errors — Datetime and Timezone -->

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

**What actually happens:** `2024-03-10 02:30:00 America/New_York` does not exist — that hour was skipped. Engines handle this differently:
- PostgreSQL: varies by libtz behavior — may error, may shift forward.
- The stored timestamp is off by exactly 1 hour for any event that nominally occurred in the gap.

**Why it's insidious:** This happens only once per year, only for one specific hour, only in timezones that observe DST. Most testing never covers this case. The bug lies dormant for 364 days and fires on the one day it matters — often in financial data or compliance logs where exact timestamps are auditable.

**Minimal repro:**


**Real-world trigger:** Security audit log timestamps. An intrusion detection event at 02:47 AM EST on DST changeover day is stored as 03:47 AM. The timeline reconstruction during the security incident review has a 1-hour gap that looks like log tampering.

---


**What it looks like:**


**Why it's insidious:** Both functions appear to mean "now." They do mean "now" — in different timezones. The query runs, returns zero rows, and a developer might diagnose this as "no events in the last hour" rather than "the time range is inverted."

**Minimal repro:**

**How to catch it:**


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


**What it looks like:**




**Minimal repro:**

**How to catch it:**

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
- PostgreSQL: truncates to **Monday**.
- MySQL `WEEK()`: defaults to Sunday unless mode is specified.


**Why it's insidious:** Both results look correct. Both produce 7-day aggregations. The difference only surfaces when comparing weekly reports across environments or when the weekly boundary is used as a JOIN key between two systems.

**Minimal repro:**

**How to catch it:**


---


**What it looks like:**



**Minimal repro:**

**How to catch it:**

