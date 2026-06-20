<!-- Part of sql-patterns: NULL Deep Dive — Conditional Aggregation, Set Operations, String Agg, Recursive CTEs, Date Spine, Funnel, Data Quality -->
<!-- Source: sql_patterns.md lines 11755–12065 -->

### 32-I. NULL in Conditional Aggregation / CASE WHEN

```sql
-- CASE WHEN with NULL conditions

-- WRONG — CASE WHEN col = NULL never matches:
SELECT
    COUNT(CASE WHEN status = NULL   THEN 1 END) AS null_status_count,  -- always 0
    COUNT(CASE WHEN status = 'FAIL' THEN 1 END) AS fail_count
FROM transactions;

-- CORRECT:
SELECT
    COUNT(CASE WHEN status IS NULL  THEN 1 END) AS pending_count,
    COUNT(CASE WHEN status = 'FAIL' THEN 1 END) AS fail_count,
    COUNT(CASE WHEN status = 'OK'   THEN 1 END) AS success_count,
    COUNT(*) AS total
FROM transactions;
-- NOTE: pending + fail + success may not equal total if there are other status values

-- CASE WHEN ELSE NULL vs CASE WHEN ELSE 0 — different aggregation behaviour:
SUM(CASE WHEN region = 'North' THEN txn_amount ELSE 0   END) AS north_sum  -- includes 0 for non-North
SUM(CASE WHEN region = 'North' THEN txn_amount ELSE NULL END) AS north_sum  -- NULLs ignored by SUM → same result for SUM
-- But for COUNT:
COUNT(CASE WHEN region = 'North' THEN 1 ELSE 0   END)  -- counts ALL rows (0 is not NULL!)
COUNT(CASE WHEN region = 'North' THEN 1 ELSE NULL END)  -- counts only North rows (NULL excluded)
COUNT(CASE WHEN region = 'North' THEN 1 END)            -- same as above (no ELSE = implicit NULL)

-- Real trap: counting users by KYC status
-- WRONG:
COUNT(CASE WHEN kyc_status = 'APPROVED' THEN 1 ELSE 0 END) AS approved_count
-- Returns TOTAL row count (0 is not NULL, COUNT counts it)!
-- CORRECT:
COUNT(CASE WHEN kyc_status = 'APPROVED' THEN 1 END) AS approved_count
-- Only counts rows where condition is TRUE (ELSE NULL is implicit)
---

### 32-J. NULL in Set Operations

```sql
-- UNION deduplication treats NULLs as equal:
SELECT NULL AS val UNION SELECT NULL AS val;
-- Result: one row with NULL (deduplicated — NULLs treated as equal for UNION purposes)

-- UNION ALL preserves all NULLs:
SELECT NULL AS val UNION ALL SELECT NULL AS val;
-- Result: two rows with NULL

-- EXCEPT (MINUS) with NULLs:
SELECT NULL AS val
EXCEPT
SELECT NULL AS val;
-- Result: empty (NULL is treated as equal in EXCEPT, so it's subtracted)

-- Practical reconciliation using EXCEPT — detecting missing records:
-- Find UPI transactions in source that are missing from DWH
SELECT txn_id, amount, status FROM source_upi_transactions
EXCEPT
SELECT txn_id, amount, status FROM dwh_upi_transactions;
-- If status IS NULL in source but 'PENDING' in DWH → NOT subtracted → appears in diff
-- If status IS NULL in BOTH → subtracted (NULLs treated as equal for EXCEPT)
-- This means NULL-NULL pairs are correctly treated as "same value" in EXCEPT

-- INTERSECT with NULLs:
SELECT NULL INTERSECT SELECT NULL;
-- Result: one row with NULL (NULL intersects with NULL — treated as equal)
---

### 32-K. NULL in String Aggregation

```sql
SELECT
    dept_id,
    STRING_AGG(employee_name, ', ' ORDER BY employee_name) AS employee_list
FROM employees
GROUP BY dept_id;
-- Employees with NULL names are silently excluded from the list
-- COUNT(*) might be 5 but STRING_AGG only lists 4 names → confusing

-- To explicitly handle NULLs:
STRING_AGG(COALESCE(employee_name, 'Unknown'), ', ' ORDER BY employee_name)

-- MySQL GROUP_CONCAT — also ignores NULLs:
GROUP_CONCAT(employee_name ORDER BY employee_name SEPARATOR ', ')
-- Same behaviour — NULLs silently dropped

LISTAGG(employee_name, ', ') WITHIN GROUP (ORDER BY employee_name)

-- The ONLY way to include NULL representation is COALESCE before aggregation.
-- There is NO option on STRING_AGG/GROUP_CONCAT to include NULLs literally.

-- Detecting aggregation with missing values:
SELECT
    dept_id,
    COUNT(*) AS total_employees,
    COUNT(employee_name) AS named_employees,
    COUNT(*) - COUNT(employee_name) AS unnamed_employees,
    STRING_AGG(COALESCE(employee_name, '[NULL]'), ', ') AS employee_list
FROM employees
GROUP BY dept_id;
---

### 32-L. NULL in Recursive CTEs

```sql
-- Org hierarchy — NULL manager_id means root (CEO)
WITH RECURSIVE org_tree AS (
    -- Anchor: start from root nodes (manager_id IS NULL)
    SELECT emp_id, full_name, manager_id, 0 AS depth, CAST(full_name AS VARCHAR(1000)) AS path
    FROM employees
    WHERE manager_id IS NULL  -- ← must use IS NULL, not = NULL

    UNION ALL

    SELECT e.emp_id, e.full_name, e.manager_id, o.depth + 1,
           o.path || ' > ' || e.full_name
    FROM employees e
    JOIN org_tree o ON e.manager_id = o.emp_id
    -- This JOIN uses = not IS NULL — rows with NULL manager_id in recursive part
    -- would never match (NULL = any emp_id = UNKNOWN) → they are correctly not recursed
)
SELECT * FROM org_tree ORDER BY depth, full_name;

-- TRAP: if both manager_id IS NULL rows exist AND manager_id = 0 rows exist
-- and you use WHERE manager_id = 0 as the anchor condition, you miss the NULL-manager rows
-- and vice versa. Pick one convention (NULL or sentinel 0 for root) and document it.

-- Loan chain / referral hierarchy where referred_by can be NULL (organic user):
WITH RECURSIVE referral_chain AS (
    SELECT user_id, referred_by, 0 AS depth
    FROM users
    WHERE user_id = :target_user_id  -- start from a specific user

    UNION ALL

    SELECT u.user_id, u.referred_by, rc.depth + 1
    FROM users u
    JOIN referral_chain rc ON u.user_id = rc.referred_by
    WHERE rc.referred_by IS NOT NULL  -- stop recursion when referred_by is NULL (organic)
)
SELECT * FROM referral_chain;
---

### 32-M. NULL in Date Spine / Forward-Fill

```sql
-- Date spine joined to sparse event data — NULLs appear on no-event days
-- Goal: forward-fill the last known credit score for each borrower across all days

WITH date_spine AS (
    SELECT generate_series('2024-01-01'::DATE, '2024-12-31'::DATE, '1 day'::INTERVAL)::DATE AS dt
),
borrower_dates AS (
    SELECT b.borrower_id, d.dt
    FROM borrowers b
    CROSS JOIN date_spine d
),
with_scores AS (
    SELECT bd.borrower_id, bd.dt, cs.credit_score
    FROM borrower_dates bd
    LEFT JOIN credit_score_events cs
        ON cs.borrower_id = bd.borrower_id AND cs.score_date = bd.dt
    -- Many dates will have NULL credit_score (no event that day)
)
SELECT
    borrower_id,
    dt,
    credit_score,  -- NULL on days with no update
    -- Forward-fill using LAST_VALUE IGNORE NULLS:
    LAST_VALUE(credit_score IGNORE NULLS) OVER (
        PARTITION BY borrower_id
        ORDER BY dt
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ) AS filled_credit_score  -- carries last known score forward
FROM with_scores;

-- PostgreSQL workaround (no IGNORE NULLS):
-- Use the group-by-cumulative-count trick (see Section I-7 FIRST_VALUE/LAST_VALUE)

-- TRAP: if a borrower has NO credit score events at all,
-- filled_credit_score is NULL for all their rows — IGNORE NULLS has nothing to carry forward.
-- Handle with COALESCE(filled_credit_score, default_score) or a separate business rule.
---

### 32-N. NULL in Funnel Analysis

```sql
-- Loan application funnel:
-- Step 1: app_submitted_at  (always set on submission)
-- Step 2: kyc_approved_at   (NULL if KYC not done or failed)
-- Step 3: credit_check_at   (NULL if credit check not triggered)
-- Step 4: disbursed_at      (NULL if loan not disbursed)

-- Count users at each funnel step
SELECT
    COUNT(*)                AS total_applicants,
    COUNT(kyc_approved_at)  AS reached_kyc,          -- non-NULL = KYC done
    COUNT(credit_check_at)  AS reached_credit_check,
    COUNT(disbursed_at)     AS disbursed,

    -- Conversion rates:
    ROUND(100.0 * COUNT(kyc_approved_at) / NULLIF(COUNT(*), 0), 2)             AS kyc_pct,
    ROUND(100.0 * COUNT(credit_check_at) / NULLIF(COUNT(kyc_approved_at), 0), 2) AS credit_pct,
    ROUND(100.0 * COUNT(disbursed_at)    / NULLIF(COUNT(credit_check_at), 0), 2)  AS disburse_pct
FROM loan_applications;

-- IMPORTANT: COUNT(col) counts non-NULL values.
-- A user with NULL kyc_approved_at did NOT complete that step.
-- This is the correct use of NULL as a "step not reached" marker.

-- Time-to-complete each step (NULL means not yet reached):
SELECT
    application_id,
    app_submitted_at,
    kyc_approved_at,
    -- Flag if still in funnel (not abandoned):
    CASE WHEN disbursed_at IS NULL AND app_submitted_at > CURRENT_DATE - 30
         THEN 'Active' ELSE 'Stalled/Complete' END AS funnel_status
FROM loan_applications;
---

### 32-O. NULL in Data Quality Checks

```sql
-- Comprehensive NULL audit — essential for every new data source

SELECT
    -- Column-level NULL counts
    COUNT(*) AS total_rows,
    COUNT(*) - COUNT(txn_id)        AS null_txn_id,         -- should be 0 (primary key)
    COUNT(*) - COUNT(user_id)       AS null_user_id,
    COUNT(*) - COUNT(amount)        AS null_amount,
    COUNT(*) - COUNT(status)        AS null_status,          -- in-flight transactions = NULL
    COUNT(*) - COUNT(merchant_id)   AS null_merchant,        -- anonymous transactions OK
    COUNT(*) - COUNT(txn_date)      AS null_date,            -- should be 0

    -- NULL percentages (useful for threshold alerts)
    ROUND(100.0 * (COUNT(*) - COUNT(amount))  / NULLIF(COUNT(*), 0), 2) AS pct_null_amount,
    ROUND(100.0 * (COUNT(*) - COUNT(status))  / NULLIF(COUNT(*), 0), 2) AS pct_null_status,

    -- Detect if NULLs are concentrated in a time window (pipeline outage signature):
    MIN(CASE WHEN amount IS NULL THEN txn_date END) AS first_null_amount_date,
    MAX(CASE WHEN amount IS NULL THEN txn_date END) AS last_null_amount_date

FROM upi_transactions;

-- Per-column NULL distribution over time (detect regression):
SELECT
    DATE_TRUNC('day', created_at) AS day,
    COUNT(*) AS total,
    SUM(CASE WHEN credit_score IS NULL THEN 1 ELSE 0 END) AS null_credit_score,
    ROUND(100.0 * SUM(CASE WHEN credit_score IS NULL THEN 1 ELSE 0 END)
        / NULLIF(COUNT(*), 0), 2) AS pct_null
FROM users
GROUP BY 1
ORDER BY 1
HAVING SUM(CASE WHEN credit_score IS NULL THEN 1 ELSE 0 END) > 0;

-- Detect "null island" — a specific partition or segment with ALL NULLs:
SELECT region, COUNT(*) AS rows, COUNT(txn_amount) AS non_null_amounts
FROM transactions
GROUP BY region
HAVING COUNT(txn_amount) = 0;  -- entire region has no amounts → data issue
---


