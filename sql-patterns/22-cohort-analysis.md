<!-- Part of sql-patterns: Cohort Analysis and Retention -->
<!-- Source: sql_patterns.md lines 5694–5979 -->

## 12. Cohort Analysis & Retention

### What it solves

Group users by the period they first appeared (cohort) and track their behaviour over subsequent periods.

### Keywords to spot

> "cohort", "retention", "users who signed up in month X",
> "day 1 / day 7 / day 30 retention", "returning users",
> "how many users from cohort X were active in month Y",
> "churn", "repeat behaviour",
> "cohort curve", "engagement decay", "lifetime value by cohort",
> "resurface", "win-back", "reactivation", "month N retention",
> "what % are still active", "cohort heat map"

### Business Context

- **Fintech:** % of users who signed up in January still trading 3 months later (product-market fit signal); identify which acquisition channels produce cohorts with the highest 6-month retention
- **SaaS:** Day-7/Day-30/Day-90 retention curves by signup month; compare retention across pricing tiers to determine if paid users stay longer; cohort-based LTV calculation
- **E-commerce:** % of first-time buyers who repurchased within 90 days per acquisition channel (repeat purchase rate); identify seasonal cohorts that retain vs one-time buyers
- **Gaming/Apps:** Week-1 and Week-4 retention by install cohort; compare retention for users who completed onboarding vs those who skipped it
- **Subscription/Media:** Monthly cohort churn curves; identify which content genres keep subscribers longest; measure impact of price increase on cohort retention

### Boilerplate

```

```sql
-- Step 1: Find each user's first activity month (cohort assignment)
WITH user_cohorts AS (
    SELECT
        user_id,
        DATE_TRUNC('month', MIN(executed_at)) AS cohort_month
    FROM trades
    GROUP BY user_id
),

-- Step 2: Get all months each user was active
user_activity AS (
    SELECT DISTINCT
        user_id,
        DATE_TRUNC('month', executed_at) AS active_month
    FROM trades
),

-- Step 3: Join and compute months since cohort
cohort_data AS (
    SELECT
        uc.cohort_month,
        ua.active_month,
        DATEDIFF('month', uc.cohort_month, ua.active_month) AS months_since_cohort,
        COUNT(DISTINCT ua.user_id)                           AS active_users
    FROM user_cohorts uc
    JOIN user_activity ua USING (user_id)
    GROUP BY 1, 2, 3
),

-- Step 4: Get cohort sizes
cohort_sizes AS (
    SELECT cohort_month, COUNT(*) AS cohort_size
    FROM user_cohorts
    GROUP BY cohort_month
)

-- Step 5: Compute retention %
SELECT
    cd.cohort_month,
    cd.months_since_cohort,
    cd.active_users,
    cs.cohort_size,
    ROUND(cd.active_users * 100.0 / cs.cohort_size, 2) AS retention_pct
FROM cohort_data cd
JOIN cohort_sizes cs USING (cohort_month)
ORDER BY cd.cohort_month, cd.months_since_cohort;
```

### Gotchas

- Month 0 retention should always be 100% (all users in cohort were active in their sign-up month) — use this to validate your query
- Use `DATEDIFF('month', ...)` not date arithmetic to ensure clean month offsets
- Cohort analysis almost always requires 4–5 CTEs — don't try to do it in fewer

### Edge Cases

#### Edge 12-A: Month-0 retention is not 100% — your cohort query is broken

**Problem:**

```sql
-- By definition: a cohort is the set of users active in their first month
-- Month-0 retention = active users in cohort month / cohort size = 100% always
-- If your query shows Month-0 retention < 100%, one of these is wrong:
-- 1. Cohort is defined as registration date, but activity is first transaction date
--    (some users register but don't transact in the same month → Month 0 < 100%)
-- 2. The activity table has missing data for the cohort month
-- 3. Timezone misalignment: registration is in UTC+5:30, activity in UTC
--    → some users' first activity falls in the "wrong" calendar month after conversion

-- DIAGNOSTIC QUERY:
WITH cohort_members AS (
    SELECT user_id, DATE_TRUNC('month', first_txn_date) AS cohort_month
    FROM users WHERE first_txn_date IS NOT NULL
),
month_0 AS (
    SELECT c.cohort_month, COUNT(DISTINCT c.user_id) AS cohort_size,
           COUNT(DISTINCT CASE WHEN DATE_TRUNC('month', t.txn_date) = c.cohort_month
                               THEN t.user_id END) AS month_0_actives
    FROM cohort_members c
    LEFT JOIN transactions t ON c.user_id = t.user_id
    GROUP BY c.cohort_month
)
SELECT cohort_month, cohort_size, month_0_actives,
       ROUND(100.0 * month_0_actives / cohort_size, 2) AS month_0_retention_pct
FROM month_0
ORDER BY cohort_month;
-- Any row with month_0_retention_pct < 100 is a bug in cohort definition or data
```

**Fix:**

```sql
-- Fix 1: Define cohort using first_txn_date, not registered_at,
-- so Month-0 activity is guaranteed to be 100%:
WITH cohort_members AS (
    SELECT
        user_id,
        DATE_TRUNC('month', MIN(txn_date)) AS cohort_month   -- cohort = month of FIRST TRANSACTION
    FROM transactions
    GROUP BY user_id
),
retention AS (
    SELECT
        c.cohort_month,
        DATEDIFF('month', c.cohort_month, DATE_TRUNC('month', t.txn_date)) AS month_num,
        COUNT(DISTINCT t.user_id) AS retained_users
    FROM cohort_members c
    JOIN transactions t ON c.user_id = t.user_id
    GROUP BY c.cohort_month, month_num
)
SELECT cohort_month, month_num, retained_users,
    FIRST_VALUE(retained_users) OVER (PARTITION BY cohort_month ORDER BY month_num) AS cohort_size,
    ROUND(100.0 * retained_users
              / FIRST_VALUE(retained_users) OVER (PARTITION BY cohort_month ORDER BY month_num), 2)
        AS retention_pct
FROM retention
ORDER BY cohort_month, month_num;
-- Month-0 retention_pct = 100% by construction ✓

-- Fix 2: If cohort must use registered_at, diagnose and patch the mismatches:
-- Use GREATEST(registered_at, first_txn_date) as the cohort anchor:
SELECT user_id,
    DATE_TRUNC('month', GREATEST(registered_at, MIN(txn_date))) AS cohort_month
FROM users u JOIN transactions t USING(user_id)
GROUP BY user_id, registered_at;
```

#### Edge 12-B: User active BEFORE their registration date — data quality crisis

**Problem:**

```sql
-- Can happen when: event tracking predates user account creation,
-- system clock skew, backdated account creation, test accounts

SELECT
    u.user_id,
    u.registered_at,
    MIN(t.txn_date) AS first_txn_date,
    DATEDIFF('day', u.registered_at, MIN(t.txn_date)) AS days_to_first_txn
FROM users u
LEFT JOIN transactions t ON u.user_id = t.user_id
GROUP BY u.user_id, u.registered_at
HAVING MIN(t.txn_date) < u.registered_at;  -- txn BEFORE registration → data issue
-- These users' cohort months will be wrong
```

**Fix:**

```sql
-- Use GREATEST(registered_at, first_txn_date) as the cohort anchor
-- so pre-registration events don't shift the cohort month:
WITH user_bounds AS (
    SELECT
        u.user_id,
        u.registered_at,
        MIN(t.txn_date) AS first_txn_date,
        -- Cohort month = later of registration and first transaction
        DATE_TRUNC('month', GREATEST(u.registered_at, MIN(t.txn_date))) AS cohort_month
    FROM users u
    LEFT JOIN transactions t ON u.user_id = t.user_id
    GROUP BY u.user_id, u.registered_at
)
SELECT * FROM user_bounds
WHERE first_txn_date < registered_at;  -- inspect the anomalous users first

-- After investigation, if they are valid (clock skew / backfill):
-- Mark them with a data quality flag rather than silently patching:
SELECT user_id, cohort_month,
    CASE WHEN first_txn_date < registered_at THEN TRUE ELSE FALSE END AS has_pre_reg_activity
FROM user_bounds;
-- Downstream retention queries can filter or include these users as appropriate
```

---

### At Scale

#### Failure Mechanism

Cohort analysis requires **4–5 CTEs** with multiple shuffles:

1. First activity per user: `GROUP BY user_id` → shuffle on 100M users
2. Cohort assignment: JOIN users back to activity → second shuffle
3. Month-since-cohort calculation: join again → third shuffle
4. Retention percentage: GROUP BY cohort × month → fourth aggregation

At 100M users × 24 retention months → 2.4B intermediate rows in the join step.

#### Code-Level Fix

```sql
-- FIX 1: Materialise the cohort assignment (the most expensive step)
-- The cohort month per user changes rarely (only when new users join)
-- Don't recompute from raw events every time

-- One-time or daily-incremental:
CREATE TABLE user_cohorts AS
SELECT user_id,
    DATE_TRUNC('month', MIN(txn_date)) AS cohort_month
FROM transactions
GROUP BY user_id;
-- This table has ONE row per user (100M rows) — recompute only incrementally

-- Cohort retention query now starts from the materialised table:
WITH activity AS (
    SELECT DISTINCT user_id, DATE_TRUNC('month', txn_date) AS active_month
    FROM transactions
    WHERE txn_date >= '2024-01-01'   -- limit to cohorts in scope
)
SELECT
    c.cohort_month,
    DATEDIFF('month', c.cohort_month, a.active_month) AS month_num,
    COUNT(DISTINCT a.user_id) AS retained_users,
    SUM(COUNT(DISTINCT a.user_id)) OVER (PARTITION BY c.cohort_month) AS cohort_size,
    ROUND(100.0 * COUNT(DISTINCT a.user_id)
              / SUM(COUNT(DISTINCT a.user_id)) OVER (PARTITION BY c.cohort_month), 2) AS retention_pct
FROM user_cohorts c
JOIN activity a ON c.user_id = a.user_id
WHERE c.cohort_month >= '2024-01-01'
GROUP BY c.cohort_month, month_num;

-- FIX 2: Pre-aggregate cohort retention into a summary table
-- Run nightly, stored in cohort_retention_summary
-- Dashboard queries: SELECT * FROM cohort_retention_summary WHERE cohort_month >= ...
-- Zero aggregation cost at query time
```

#### System-Level Fix

```sql
-- Delta Lake: user_cohorts table with incremental updates
CREATE TABLE user_cohorts (
    user_id       STRING,
    cohort_month  DATE
)
USING DELTA;
OPTIMIZE user_cohorts ZORDER BY (user_id);   -- fast lookup join on user_id

-- Redshift: user_cohorts co-located with transactions
CREATE TABLE user_cohorts (user_id BIGINT, cohort_month DATE)
DISTSTYLE KEY DISTKEY(user_id);   -- same distkey as transactions → co-located join

-- BigQuery: partition the cohort retention summary by cohort_month
CREATE OR REPLACE TABLE cohort_retention_summary
PARTITION BY cohort_month
CLUSTER BY cohort_month, month_num
AS SELECT ...;
-- Dashboard query: reads only the partitions for cohort_months in the filter
-- All aggregation is pre-done at ETL time
```sql

---

---

