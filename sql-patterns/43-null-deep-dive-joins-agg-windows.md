<!-- Part of sql-patterns: NULL Deep Dive — In JOINs, Aggregate Functions, and Window Functions -->
<!-- Source: sql_patterns.md lines 11137–11471 -->

## 32. NULL Handling — Pattern-by-Pattern Deep Dive

This section dissects how NULL behaves inside every major SQL pattern. Each subsection gives you the trap, why it happens at the engine level, and the correct fix — all grounded in real fintech scenarios.

---

### 32-A. NULL in JOINs

#### LEFT JOIN produces NULLs — and that is the point

When a LEFT JOIN finds no matching row on the right side, **every column from the right table becomes NULL** for that row. This is how LEFT JOIN works. The danger is filtering those NULLs away accidentally.

```sql
-- Schema: loans(loan_id, borrower_id, ...), repayments(loan_id, repaid_amount, repaid_at)

-- Find all loans and their repayment (if any):
SELECT l.loan_id, l.principal, r.repaid_amount
FROM loans l
LEFT JOIN repayments r ON l.loan_id = r.loan_id;
-- Loans with no repayment row → repaid_amount IS NULL (outstanding)

-- TRAP: adding a WHERE on the right table silently converts LEFT → INNER JOIN:
SELECT l.loan_id, l.principal, r.repaid_amount
FROM loans l
LEFT JOIN repayments r ON l.loan_id = r.loan_id
WHERE r.repaid_amount > 0;   -- NULL > 0 = UNKNOWN → outstanding loans excluded!

-- FIX A: move the condition into ON (keeps the LEFT JOIN behaviour):
LEFT JOIN repayments r ON l.loan_id = r.loan_id AND r.repaid_amount > 0;
-- Outstanding loans still appear; repaid_amount just stays NULL when condition fails

-- FIX B: explicitly include NULLs in WHERE:
WHERE r.repaid_amount > 0 OR r.repaid_amount IS NULL;
```

#### NULL in the JOIN key itself

If the JOIN key column contains NULL, **rows with NULL keys never join** — NULL = NULL is UNKNOWN.

```sql
-- merchant_id IS NULL in some transactions (anonymous/unregistered merchants)
SELECT t.txn_id, m.merchant_name
FROM transactions t
LEFT JOIN merchants m ON t.merchant_id = m.merchant_id;
-- Rows where t.merchant_id IS NULL → no join match (NULL ≠ NULL), merchant_name IS NULL

-- This is correct behaviour — do NOT use COALESCE in the ON clause to force-match NULLs
-- WRONG:
ON COALESCE(t.merchant_id, -1) = COALESCE(m.merchant_id, -1)
-- This joins all NULL-merchant transactions to all NULL-merchant records, which is wrong

-- If you want a special "unknown merchant" row for NULLs, handle it after the join:
SELECT
    t.txn_id,
    COALESCE(m.merchant_name, 'Unknown Merchant') AS merchant_name
FROM transactions t
LEFT JOIN merchants m ON t.merchant_id = m.merchant_id;
```

#### FULL OUTER JOIN — NULLs on both sides

```sql
-- Reconcile expected disbursements vs actual disbursements for the day
SELECT
    COALESCE(e.loan_id, a.loan_id)   AS loan_id,
    e.expected_amount,
    a.actual_amount,
    CASE
        WHEN e.loan_id IS NULL THEN 'Unexpected disbursement'
        WHEN a.loan_id IS NULL THEN 'Missing disbursement'
        WHEN e.expected_amount IS DISTINCT FROM a.actual_amount THEN 'Amount mismatch'
        ELSE 'OK'
    END AS reconciliation_status
FROM expected_disbursements e
FULL OUTER JOIN actual_disbursements a ON e.loan_id = a.loan_id;

-- Key points:
-- 1. Use COALESCE(e.id, a.id) to get the ID regardless of which side has it
-- 2. Use IS DISTINCT FROM for amount comparison (handles NULLs on either side)
--    (e.loan_id IS NULL AND a.loan_id IS NULL)) if you want NULL keys to match
---

### 32-B. NULL in Aggregate Functions

This is the most nuanced NULL area — each function has its own NULL contract.

```sql
-- Sample data: bonuses table
-- emp_id | bonus
-- -------|-------
--  1     | 1000
--  2     | 2000
--  3     | NULL
--  4     | NULL
--  5     | 500

SELECT
    COUNT(*)        AS total_rows,          -- 5  (counts all rows, including NULL rows)
    COUNT(bonus)    AS rows_with_bonus,     -- 3  (NULL rows excluded)
    COUNT(DISTINCT bonus) AS unique_values, -- 2  (1000, 2000 — NULL excluded, 500 too?)
    SUM(bonus)      AS total_bonus,         -- 3500 (NULLs ignored)
    AVG(bonus)      AS avg_bonus,           -- 1166.67 = 3500/3, NOT 3500/5 (NULLs excluded from denominator!)
    MIN(bonus)      AS min_bonus,           -- 500 (NULLs ignored)
    MAX(bonus)      AS max_bonus,           -- 2000 (NULLs ignored)
    SUM(bonus) / COUNT(*) AS wrong_avg      -- 700 = 3500/5 (treats NULLs as 0 — usually wrong)
FROM bonuses;
```

**The AVG trap — denominator excludes NULLs:**

```sql
-- Business: credit utilization = outstanding_balance / credit_limit
-- Some accounts have NULL credit_limit (pending activation)

-- WRONG: AVG gives average over non-NULL rows only
-- If 40% of accounts have NULL credit_limit, you're computing avg over 60% of accounts
SELECT borrower_segment, AVG(outstanding_balance / NULLIF(credit_limit, 0)) AS avg_utilization
FROM accounts
GROUP BY borrower_segment;

-- CORRECT for "company-wide utilization" (use sum/sum, not avg of ratios):
SELECT
    borrower_segment,
    SUM(outstanding_balance) / NULLIF(SUM(credit_limit), 0) AS correct_utilization,
    COUNT(*) AS total_accounts,
    COUNT(credit_limit) AS active_accounts,
    COUNT(*) - COUNT(credit_limit) AS pending_activation
FROM accounts
GROUP BY borrower_segment;
```

**SUM returns NULL when ALL inputs are NULL:**

```sql
-- If a borrower has NO repayments at all, SUM(repaid_amount) = NULL, not 0
SELECT borrower_id, SUM(repaid_amount) AS total_repaid
FROM repayments
GROUP BY borrower_id;
-- Borrower with all-NULL repaid_amounts → total_repaid IS NULL

-- Usually you want 0 for "no repayments":
SELECT borrower_id, COALESCE(SUM(repaid_amount), 0) AS total_repaid
FROM repayments
GROUP BY borrower_id;
-- BUT: COALESCE(SUM(...), 0) only helps when the group exists
-- If the borrower has NO rows in repayments, they won't appear in this result at all
-- → Need a LEFT JOIN from borrowers to repayments to catch those cases
-- FILTER is a cleaner alternative to CASE WHEN inside aggregates
-- NULL behaviour: rows where the filter is FALSE contribute NULL (not 0) to the aggregate

SELECT
    COUNT(*) FILTER (WHERE status = 'SUCCESS') AS success_count,
    COUNT(*) FILTER (WHERE status = 'FAILED')  AS failed_count,
    -- FILTER works like: COUNT(CASE WHEN status = 'SUCCESS' THEN 1 END)
    -- Rows where status IS NULL do NOT match either filter → excluded from both counts
    COUNT(*) FILTER (WHERE status IS NULL)     AS pending_count  -- in-flight transactions
FROM upi_transactions;
---

### 32-C. NULL in Window Functions

#### Ranking (ROW_NUMBER, RANK, DENSE_RANK) — NULL in ORDER BY

```sql
-- When ORDER BY column has NULLs, NULL position depends on NULLS FIRST/LAST

-- Find each borrower's latest loan — order by disbursement_date DESC
-- Some loans have NULL disbursement_date (application submitted, not yet disbursed)
WITH ranked AS (
    SELECT *,
        ROW_NUMBER() OVER (
            PARTITION BY borrower_id
            ORDER BY disbursement_date DESC NULLS LAST  -- undisbursed loans rank LAST
        ) AS rn
    FROM loans
)
SELECT * FROM ranked WHERE rn = 1;
-- Returns the most recently disbursed loan per borrower
-- Borrowers with ALL NULL disbursement_dates → one of them gets rn=1 (arbitrary)

-- To explicitly exclude undisbursed loans from the ranking:
WITH ranked AS (
    SELECT *,
        ROW_NUMBER() OVER (
            PARTITION BY borrower_id
            ORDER BY disbursement_date DESC
        ) AS rn
    FROM loans
    WHERE disbursement_date IS NOT NULL  -- filter before windowing
)
SELECT * FROM ranked WHERE rn = 1;
```

#### LAG / LEAD — NULL at partition boundaries and NULL default

```sql
-- LAG returns NULL for the first row of each partition (no previous row)
-- This is the "natural NULL" for LAG

SELECT
    user_id,
    txn_date,
    txn_amount,
    LAG(txn_amount) OVER (PARTITION BY user_id ORDER BY txn_date) AS prev_amount
    -- ↑ NULL for each user's very first transaction
FROM transactions;

-- THREE sources of NULL in LAG results:
-- 1. First row of partition (no prior row) → NULL
-- 2. The prior row's value was NULL → NULL propagates
-- 3. Third argument default not provided → NULL

-- Distinguish source 1 from source 2 using the third argument:
LAG(txn_amount, 1, -1) OVER (...)  -- sentinel -1 means "first row in partition"
-- If result = -1: first row. If result = NULL: prior row had NULL amount.
-- If result = positive number: prior row had that amount.

-- Real pattern: MoM growth, guard against first month:
WITH monthly AS (
    SELECT DATE_TRUNC('month', txn_date) AS month, SUM(txn_amount) AS revenue
    FROM transactions GROUP BY 1
)
SELECT
    month,
    revenue,
    LAG(revenue) OVER (ORDER BY month) AS prev_revenue,
    CASE
        WHEN LAG(revenue) OVER (ORDER BY month) IS NULL THEN NULL  -- first month, no growth
        WHEN LAG(revenue) OVER (ORDER BY month) = 0    THEN NULL  -- guard divide-by-zero
        ELSE ROUND((revenue - LAG(revenue) OVER (ORDER BY month))
                 / LAG(revenue) OVER (ORDER BY month) * 100, 2)
    END AS mom_growth_pct
FROM monthly;
```

#### FIRST_VALUE / LAST_VALUE with IGNORE NULLS

Some columns have sparse values — only populated for certain events (e.g., credit tier assigned only at KYC approval, NULL otherwise). IGNORE NULLS lets you carry forward the last known non-NULL value.

```sql
-- credit_tier is only set at kyc_approval events; NULL for all other events
-- Goal: show the current credit tier for each event row

SELECT
    user_id,
    event_date,
    event_type,
    credit_tier,
    -- Standard LAST_VALUE: may return NULL if last row in partition has NULL credit_tier
    LAST_VALUE(credit_tier) OVER (
        PARTITION BY user_id
        ORDER BY event_date
        ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING
    ) AS last_tier_standard,

    -- IGNORE NULLS: carries forward the last non-NULL credit_tier seen
    LAST_VALUE(credit_tier IGNORE NULLS) OVER (
        PARTITION BY user_id
        ORDER BY event_date
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ) AS current_tier_forward_filled
FROM user_events;

-- If a user has never had a credit_tier set → all rows return NULL (correct)
-- If a user's latest credit_tier was set in row 3 → rows 4,5,6 show that tier

-- Engine support for IGNORE NULLS:
-- PostgreSQL: NOT supported natively — use a workaround (see below)
-- MySQL: NOT supported

-- PostgreSQL workaround for forward-fill (LAST_VALUE IGNORE NULLS equivalent):
SELECT
    user_id, event_date, credit_tier,
    LAST_VALUE(credit_tier) OVER (
        PARTITION BY user_id, grp
        ORDER BY event_date
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ) AS forward_filled_tier
FROM (
    SELECT *,
           COUNT(credit_tier) OVER (  -- counts non-NULLs seen so far
               PARTITION BY user_id ORDER BY event_date
               ROWS UNBOUNDED PRECEDING
           ) AS grp                   -- grp increments only when a non-NULL appears
    FROM user_events
) t;
```

#### Running Aggregates — NULL in SUM / AVG

```sql
-- Running total with NULL gaps
-- SUM ignores NULLs, so a NULL day is simply skipped in the running total (not zeroed)

SELECT
    txn_date,
    daily_revenue,      -- NULL on days with no transactions
    SUM(daily_revenue) OVER (
        ORDER BY txn_date
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ) AS running_total
    -- Running total on a NULL day = same as the day before (NULL contributes 0 to SUM)
FROM date_spine
LEFT JOIN daily_revenue_agg USING (txn_date);

-- TRAP: if ALL rows in the partition are NULL, SUM returns NULL (not 0)
-- Protect with COALESCE if needed:
COALESCE(SUM(daily_revenue) OVER (...), 0) AS running_total
---


