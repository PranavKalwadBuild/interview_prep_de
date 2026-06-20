<!-- Part of sql-patterns: NULL Deep Dive — Anti-Joins, Gap/Island, Deduplication, SCD Type 2, Period-over-Period -->
<!-- Source: sql_patterns.md lines 11472–11754 -->

### 32-D. NULL in Anti-Joins — The Most Dangerous NULL Trap

This is the pattern that causes the most silent data bugs in production SQL. Know it cold.

**The setup:** You want to find rows in table A that have no corresponding row in table B.

```sql
-- Scenario: find borrowers who have NEVER defaulted

-- Table: borrowers(borrower_id, ...)
-- Table: defaults(borrower_id, default_date, ...)
-- Some defaults.borrower_id values are NULL (data quality issue — unknown borrower)

-- METHOD 1: NOT IN — BROKEN when subquery returns NULLs
SELECT borrower_id FROM borrowers
WHERE borrower_id NOT IN (SELECT borrower_id FROM defaults);

-- What the engine does:
-- NOT IN expands to: borrower_id != d1 AND borrower_id != d2 AND ... AND borrower_id != NULL
-- borrower_id != NULL = UNKNOWN
-- UNKNOWN AND anything = UNKNOWN (never TRUE)
-- Result: ZERO rows returned — every single borrower is excluded!

-- This is not an error. No warnings. Complete silence. All rows vanish.

-- CORRECT METHOD 1: add NULL guard in the subquery
SELECT borrower_id FROM borrowers
WHERE borrower_id NOT IN (
    SELECT borrower_id FROM defaults WHERE borrower_id IS NOT NULL
);

-- CORRECT METHOD 2: NOT EXISTS (NULL-safe by design)
SELECT b.borrower_id FROM borrowers b
WHERE NOT EXISTS (
    SELECT 1 FROM defaults d WHERE d.borrower_id = b.borrower_id
);
-- NOT EXISTS uses EXISTS semantics — never poisoned by NULLs in the subquery
-- If d.borrower_id IS NULL: NULL = b.borrower_id = UNKNOWN → EXISTS returns FALSE for that row
-- → NOT EXISTS is TRUE → borrower IS included ← correct!

-- CORRECT METHOD 3: LEFT JOIN IS NULL
SELECT b.borrower_id
FROM borrowers b
LEFT JOIN defaults d ON b.borrower_id = d.borrower_id
WHERE d.borrower_id IS NULL;
-- borrower_id in defaults is NULL → join never matches → d.borrower_id stays NULL → included

-- WHICH TO USE:
-- Production code: NOT EXISTS or LEFT JOIN IS NULL (NULL-safe)
-- Interviews: explain all three, name the NOT IN trap, prefer NOT EXISTS
```

**Performance note:**

```sql
-- NOT EXISTS short-circuits on first match — stops scanning defaults as soon as a match is found
-- NOT IN must evaluate the ENTIRE subquery result first, then compare each value
-- For large tables: NOT EXISTS is faster
-- For filtered subqueries (WHERE subquery is small): all three are similar
---

### 32-E. NULL in Gap-and-Island / Sessionization

#### Null dates break streak detection

```sql
-- Consecutive trading day streak — gap-and-island pattern
-- Some activity_date values are NULL (event logged but date extraction failed)

WITH daily AS (
    SELECT DISTINCT user_id, activity_date
    FROM user_activity
    WHERE activity_date IS NOT NULL  -- ← MUST filter NULLs before the streak logic
    -- Without this filter: NULL dates cause incorrect streak groups because
    -- NULL - ROW_NUMBER() = NULL, and NULL <> any other NULL so groups break unpredictably
),
grouped AS (
    SELECT
        user_id,
        activity_date,
        activity_date - ROW_NUMBER() OVER (
            PARTITION BY user_id ORDER BY activity_date
        )::INT AS streak_group
    FROM daily
)
SELECT user_id, COUNT(*) AS streak_length, MIN(activity_date), MAX(activity_date)
FROM grouped
GROUP BY user_id, streak_group
ORDER BY streak_length DESC;
```

#### Sessionization — NULL timestamps and NULL gaps

```sql
-- Session detection based on 30-minute inactivity
-- NULL event_at means event time was not captured

SELECT
    user_id,
    event_at,
    event_type,
    LAG(event_at) OVER (PARTITION BY user_id ORDER BY event_at) AS prev_event_at,
    -- TRAP: if prev_event_at IS NULL (first event), the gap expression returns NULL
    -- NULL > INTERVAL '30 minutes' = UNKNOWN → treated as NOT a session boundary
    -- This is CORRECT — the first event in a partition IS the start of a new session
    CASE
        WHEN LAG(event_at) OVER (PARTITION BY user_id ORDER BY event_at) IS NULL
             THEN 1  -- first event = new session start
        WHEN event_at - LAG(event_at) OVER (PARTITION BY user_id ORDER BY event_at)
             > INTERVAL '30 minutes'
             THEN 1  -- gap > 30 min = new session
        ELSE 0
    END AS is_session_start
FROM user_events
WHERE event_at IS NOT NULL;  -- filter NULL timestamps before session logic

-- What happens if you don't filter NULL event_at:
-- ORDER BY event_at with NULLs: position depends on engine (NULLS FIRST/LAST varies)
-- LAG of a NULL = NULL; gap calculation: NULL - NULL = NULL = UNKNOWN → wrong session boundaries
---

### 32-F. NULL in Deduplication

#### NULL in the dedup key — NULLs never deduplicate each other

```sql
-- Dedup on (txn_id, status) — keep latest record per transaction
-- Some txn_id values are NULL (batch insert without ID assignment)

WITH ranked AS (
    SELECT *,
        ROW_NUMBER() OVER (
            PARTITION BY txn_id, status
            ORDER BY updated_at DESC
        ) AS rn
    FROM raw_transactions
)
SELECT * FROM ranked WHERE rn = 1;

-- TRAP: rows where txn_id IS NULL each get rn = 1 because NULL != NULL in PARTITION BY
-- Two rows with txn_id = NULL are in SEPARATE partitions (each is its own group)
-- → ALL NULL-key rows pass the rn = 1 filter — none are deduplicated!

-- To dedup NULL keys together, use a sentinel value:
PARTITION BY COALESCE(txn_id, 'NULL_SENTINEL'), status

-- Better: investigate why txn_id is NULL and fix upstream.
-- A NULL primary key is a data quality bug, not a dedup problem.

-- Dedup on a computed hash key — NULL columns poison the hash:
SELECT *, MD5(CONCAT(user_id, '|', merchant_id, '|', amount, '|', txn_date)) AS row_hash
FROM transactions;
-- If ANY of those columns is NULL → CONCAT = NULL → MD5 = NULL → all such rows get same hash!
-- FIX:
MD5(CONCAT_WS('|', user_id, COALESCE(merchant_id, ''), amount, txn_date)) AS row_hash
-- CONCAT_WS skips NULLs but that loses the NULL vs empty string distinction
-- BETTER: substitute a unique sentinel per column type:
MD5(CONCAT(
    COALESCE(CAST(user_id AS VARCHAR), 'NULL_USER'), '|',
    COALESCE(merchant_id, 'NULL_MERCHANT'), '|',
    COALESCE(CAST(amount AS VARCHAR), 'NULL_AMT'), '|',
    COALESCE(CAST(txn_date AS VARCHAR), 'NULL_DATE')
)) AS row_hash
---

### 32-G. NULL in SCD Type 2

SCD2 tables use NULL extensively and correctly — but misunderstanding that leads to broken queries.

```sql
-- SCD2 table: dim_credit_tier
-- surrogate_key | borrower_id | credit_tier | valid_from   | valid_to
-- --------------|-------------|-------------|--------------|----------
--     1         | B001        | Bronze      | 2024-01-01   | 2024-06-30
--     2         | B001        | Silver      | 2024-07-01   | NULL        ← current record
--     3         | B002        | Gold        | 2024-01-01   | NULL        ← current record

-- NULL valid_to = current (active) record. This is the convention.
-- Do NOT use a far-future sentinel like 9999-12-31 if you're using NULL — pick one convention and stick to it.

-- Query: get current credit tier for all borrowers
-- WRONG — misses NULLs entirely:
WHERE valid_to >= CURRENT_DATE   -- NULL >= date = UNKNOWN → current records excluded!

-- CORRECT:
WHERE valid_to IS NULL           -- current records only

-- CORRECT alternative (handles both NULL and sentinel):
WHERE COALESCE(valid_to, '9999-12-31') >= CURRENT_DATE

-- Point-in-time query: what was borrower B001's tier on 2024-05-15?
SELECT credit_tier
FROM dim_credit_tier
WHERE borrower_id = 'B001'
  AND valid_from <= '2024-05-15'
  AND (valid_to IS NULL OR valid_to >= '2024-05-15');
-- Returns: Bronze (valid_from=2024-01-01, valid_to=2024-06-30)

-- SCD2 INSERT — detecting actual changes with IS DISTINCT FROM:
INSERT INTO dim_credit_tier (borrower_id, credit_tier, valid_from, valid_to)
SELECT
    s.borrower_id,
    s.new_tier,
    CURRENT_DATE,
    NULL
FROM staging_tiers s
JOIN dim_credit_tier d
    ON s.borrower_id = d.borrower_id AND d.valid_to IS NULL
WHERE s.new_tier IS DISTINCT FROM d.credit_tier;
-- IS DISTINCT FROM handles the case where either old or new tier is NULL
-- (e.g., first-time credit assignment: old_tier IS NULL, new_tier IS NOT NULL → IS DISTINCT FROM = TRUE → insert)

-- Change detection with standard =:
WHERE s.new_tier != d.credit_tier  -- if either is NULL → UNKNOWN → change NOT detected!
-- This would miss: NULL → 'Bronze' (new credit assignment)
-- And miss: 'Gold' → NULL (credit line closed)
---

### 32-H. NULL in Period-over-Period / LAG

```sql
-- Monthly revenue with MoM growth
-- First month of data: LAG returns NULL (no prior month)
-- Also handle months where revenue IS NULL (no transactions that month, after LEFT JOIN with date spine)

WITH monthly AS (
    SELECT
        DATE_TRUNC('month', txn_date) AS month,
        SUM(COALESCE(txn_amount, 0))  AS revenue  -- NULL → 0 for months with NULLs
    FROM date_spine
    LEFT JOIN transactions USING (txn_date)
    GROUP BY 1
)
SELECT
    month,
    revenue,
    LAG(revenue) OVER (ORDER BY month) AS prev_revenue,

    -- Growth rate: NULL for first month, NULL if prev_revenue = 0 (new entry)
    CASE
        WHEN LAG(revenue) OVER (ORDER BY month) IS NULL  THEN NULL   -- first month
        WHEN LAG(revenue) OVER (ORDER BY month)  = 0    THEN NULL   -- divide by zero
        ELSE ROUND(
            100.0 * (revenue - LAG(revenue) OVER (ORDER BY month))
                  / LAG(revenue) OVER (ORDER BY month), 2)
    END AS mom_growth_pct,

    -- Flag months where current revenue is NULL (no data, not zero)
    CASE WHEN revenue IS NULL THEN TRUE ELSE FALSE END AS is_data_gap
FROM monthly
ORDER BY month;
---


