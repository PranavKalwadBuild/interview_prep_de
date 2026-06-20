<!-- Part of sql-patterns: NULL Deep Dive — Percentiles, NTILE, Cohort Analysis, End-to-End Example, Quick Reference Card -->
<!-- Source: sql_patterns.md lines 12066–12329 -->

### 32-P. NULL in Percentiles and Histograms

```sql
-- PERCENTILE_CONT / PERCENTILE_DISC ignore NULLs (like other aggregates)
SELECT
    PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY credit_score)  AS median_score,
    PERCENTILE_CONT(0.9) WITHIN GROUP (ORDER BY credit_score)  AS p90_score,
    COUNT(*)             AS total_users,
    COUNT(credit_score)  AS users_with_score,   -- NULL = score not yet computed
    COUNT(*) - COUNT(credit_score) AS users_without_score
FROM users;
-- median_score is computed over ONLY the non-NULL credit_scores
-- If 30% of users have NULL score, you're computing percentiles on 70% of data — document this

-- Window percentile functions also ignore NULLs:
SELECT
    user_id,
    credit_score,
    PERCENT_RANK() OVER (ORDER BY credit_score) AS percentile_rank
    -- NULL credit_score rows: their percentile_rank is undefined
    -- Most engines: NULL in ORDER BY → NULLS LAST by default → they get the highest percentile rank
FROM users;
-- Often you want to exclude NULLs:
SELECT * FROM (
    SELECT user_id, credit_score,
           PERCENT_RANK() OVER (ORDER BY credit_score) AS percentile_rank
    FROM users
    WHERE credit_score IS NOT NULL
) t;

-- Histogram bucketing with NULL handling:
SELECT
    CASE
        WHEN credit_score IS NULL         THEN 'No Score'
        WHEN credit_score < 600           THEN '< 600'
        WHEN credit_score BETWEEN 600 AND 699 THEN '600–699'
        WHEN credit_score BETWEEN 700 AND 749 THEN '700–749'
        WHEN credit_score >= 750          THEN '750+'
    END AS score_bucket,
    COUNT(*) AS user_count
FROM users
GROUP BY 1
ORDER BY 1;
-- Always add an explicit NULL bucket — otherwise NULLs are silently lumped into ELSE (if any)
-- and if there's no ELSE, NULL rows return NULL from CASE and GROUP BY puts them in the NULL group
---

### 32-Q. NULL in NTILE / Bucketing

```sql
-- NTILE distributes rows evenly across N buckets
-- NTILE ignores NULLs in ORDER BY? No — it includes ALL rows, NULLs sort to NULLS LAST/FIRST

SELECT
    user_id,
    loan_amount,
    NTILE(4) OVER (ORDER BY loan_amount DESC NULLS LAST) AS quartile
    -- Rows with NULL loan_amount get the LAST quartile (quartile 4) when NULLS LAST
    -- Rows with NULL loan_amount get the FIRST quartile (quartile 1) when NULLS FIRST
FROM loan_applications;

-- To exclude NULLs from quartile calculation:
SELECT user_id, loan_amount,
       NTILE(4) OVER (ORDER BY loan_amount DESC) AS quartile
FROM loan_applications
WHERE loan_amount IS NOT NULL;  -- filter before NTILE

-- Then handle NULLs separately:
SELECT
    user_id,
    loan_amount,
    CASE
        WHEN loan_amount IS NULL THEN NULL
        ELSE NTILE(4) OVER (
            PARTITION BY (CASE WHEN loan_amount IS NULL THEN 0 ELSE 1 END)
            ORDER BY loan_amount DESC
        )
    END AS quartile
FROM loan_applications;
---

### 32-R. NULL in Cohort Analysis

```sql
-- User cohort = first transaction month
-- Users who registered but never transacted have NULL first_txn_date

WITH cohorts AS (
    SELECT
        u.user_id,
        u.registered_at,
        MIN(t.txn_date) AS first_txn_date  -- NULL if no transactions
    FROM users u
    LEFT JOIN transactions t ON u.user_id = t.user_id
    GROUP BY u.user_id, u.registered_at
)
SELECT
    -- Cohort by registration month (all users, including non-transacting ones)
    DATE_TRUNC('month', registered_at) AS reg_cohort,

    -- Cohort by first transaction month (only transacting users — NULLs excluded)
    DATE_TRUNC('month', first_txn_date) AS txn_cohort,  -- NULL for non-transacting users

    COUNT(*) AS total_users,
    COUNT(first_txn_date) AS transacting_users,     -- non-NULL = made at least one txn
    COUNT(*) - COUNT(first_txn_date) AS dormant_users,

    -- Activation rate
    ROUND(100.0 * COUNT(first_txn_date) / NULLIF(COUNT(*), 0), 2) AS activation_rate_pct
FROM cohorts
GROUP BY 1, 2;

-- TRAP: grouping by txn_cohort puts all NULL (dormant) users into one group
-- If you GROUP BY txn_cohort, the NULL cohort lumps ALL dormant users together
-- regardless of when they registered — usually wrong
-- Fix: group by reg_cohort for counts, and separately report activation rate
---

### 32-S. Full End-to-End Example — UPI Transaction Pipeline with NULL Everywhere

This example ties together every pattern. The scenario is a real Slice-type analytics query.

**Context:** Daily report of UPI transaction health — volume, success rate, unmatched merchants, outstanding settlements, and top failure reasons.

```sql
WITH
-- Step 1: Clean transactions — handle NULL status (in-flight = PENDING)
clean_txns AS (
    SELECT
        txn_id,
        user_id,
        merchant_id,                            -- NULL = unregistered merchant
        txn_date,
        amount,
        COALESCE(status, 'PENDING') AS status,  -- treat NULL status as PENDING
        settlement_date                          -- NULL = not yet settled
    FROM upi_transactions
    WHERE txn_date IS NOT NULL                  -- filter rows with no date (data quality)
),

-- Step 2: Enrich with merchant name (LEFT JOIN — anonymous txns get NULL name)
enriched AS (
    SELECT
        t.*,
        COALESCE(m.merchant_name, 'Anonymous') AS merchant_display_name,
        m.merchant_category                      -- NULL for anonymous merchants
    FROM clean_txns t
    LEFT JOIN merchants m ON t.merchant_id = m.merchant_id
    -- merchant_id = NULL never joins (NULL = NULL = UNKNOWN), stays as Anonymous
),

-- Step 3: Settlement lag — NULL settlement_date means outstanding
with_lag AS (
    SELECT
        *,
        -- NULL settlement_date → days_to_settle is NULL (outstanding)

        -- Running balance per user: treat NULL amounts as 0
        SUM(COALESCE(amount, 0)) OVER (
            PARTITION BY user_id
            ORDER BY txn_date, txn_id
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) AS user_running_balance,

        -- Flag if this is the user's first transaction (LAG IS NULL = first row)
        CASE
            WHEN LAG(txn_id) OVER (PARTITION BY user_id ORDER BY txn_date, txn_id) IS NULL
            THEN TRUE ELSE FALSE
        END AS is_first_txn
    FROM enriched
)

-- Step 4: Daily summary
SELECT
    txn_date,
    COUNT(*)                                              AS total_txns,
    COUNT(*) FILTER (WHERE status = 'SUCCESS')            AS success_count,
    COUNT(*) FILTER (WHERE status = 'FAILED')             AS failed_count,
    COUNT(*) FILTER (WHERE status = 'PENDING')            AS pending_count,   -- includes original NULLs
    COUNT(*) FILTER (WHERE settlement_date IS NULL
                      AND status = 'SUCCESS')             AS unsettled_success,  -- T+N pending
    COUNT(*) FILTER (WHERE merchant_id IS NULL)           AS anonymous_txns,
    SUM(COALESCE(amount, 0))                              AS total_volume,

    -- Success rate: NULLIF prevents divide-by-zero if no transactions on a day
    ROUND(100.0 * COUNT(*) FILTER (WHERE status = 'SUCCESS')
        / NULLIF(COUNT(*) FILTER (WHERE status IN ('SUCCESS','FAILED')), 0), 2)
        AS success_rate_pct,

    -- Avg settlement lag for settled transactions only (NULLs excluded by AVG)
    ROUND(AVG(days_to_settle), 2)                        AS avg_settlement_lag_days,

    -- P95 settlement lag (PERCENTILE_CONT ignores NULLs — settled txns only)
    PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY days_to_settle) AS p95_settlement_lag

FROM with_lag
GROUP BY txn_date
ORDER BY txn_date DESC;

