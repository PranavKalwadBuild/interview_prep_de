<!-- Part of sql-patterns: NULL Handling Fundamentals Part 1 — 3VL, Boolean Logic, Arithmetic, IS NULL, COALESCE -->
<!-- Source: sql_patterns.md lines 693–914 -->

### I. NULL Handling — Complete Fundamentals

`NULL` means **unknown** or **missing**. It is not zero, not an empty string, not false — it is the **absence of a value**. NULL bugs are silent: wrong queries run without errors but return incorrect results.

---

#### I-1. Three-Valued Logic (3VL)

SQL uses **three-valued logic**: TRUE, FALSE, and **UNKNOWN**. Any comparison involving NULL produces UNKNOWN — never TRUE or FALSE.

```sql
-- Every one of these returns UNKNOWN, not TRUE or FALSE:
SELECT 1 = NULL;               -- UNKNOWN
SELECT NULL = NULL;            -- UNKNOWN  ← two NULLs are NOT equal!
SELECT NULL != NULL;           -- UNKNOWN
SELECT NULL < 5;               -- UNKNOWN
SELECT NULL > 5;               -- UNKNOWN
SELECT NULL BETWEEN 1 AND 10;  -- UNKNOWN
SELECT NULL IN (1, 2, 3);      -- UNKNOWN
SELECT NULL LIKE '%any%';      -- UNKNOWN
```

**The WHERE/HAVING rule:** Only rows where the condition evaluates to **TRUE** are kept. UNKNOWN rows are silently discarded — this is the source of almost every NULL bug.

```sql
-- Fintech scenario: upi_transactions has status = NULL for in-flight (PENDING) txns
-- status = 'SUCCESS' or 'FAILED' for completed ones

-- WRONG — discards all in-flight (NULL status) rows silently:
SELECT COUNT(*) FROM upi_transactions
WHERE status != 'FAILED';
-- NULL != 'FAILED' = UNKNOWN → in-flight rows are EXCLUDED from count

-- CORRECT — explicitly include NULLs:
SELECT COUNT(*) FROM upi_transactions
WHERE status = 'SUCCESS' OR status IS NULL;

-- CORRECT alternative — IS DISTINCT FROM (NULL-safe):
SELECT COUNT(*) FROM upi_transactions
WHERE status IS DISTINCT FROM 'FAILED';
---

#### I-2. NULL in Boolean Logic — AND / OR / NOT Truth Tables

These tables explain why NULL in WHERE conditions causes unexpected row exclusions.

**AND:**

| A | B | A AND B |
|---|---|---------|
| TRUE | TRUE | TRUE |
| TRUE | FALSE | FALSE |
| TRUE | UNKNOWN | UNKNOWN |
| FALSE | TRUE | FALSE |
| FALSE | FALSE | FALSE |
| FALSE | UNKNOWN | **FALSE** ← FALSE short-circuits |
| UNKNOWN | TRUE | UNKNOWN |
| UNKNOWN | FALSE | **FALSE** |
| UNKNOWN | UNKNOWN | UNKNOWN |

**OR:**

| A | B | A OR B |
|---|---|--------|
| TRUE | TRUE | TRUE |
| TRUE | FALSE | TRUE |
| TRUE | UNKNOWN | **TRUE** ← TRUE short-circuits |
| FALSE | TRUE | TRUE |
| FALSE | FALSE | FALSE |
| FALSE | UNKNOWN | UNKNOWN |
| UNKNOWN | TRUE | **TRUE** |
| UNKNOWN | FALSE | UNKNOWN |
| UNKNOWN | UNKNOWN | UNKNOWN |

**NOT:**

| A | NOT A |
|---|-------|
| TRUE | FALSE |
| FALSE | TRUE |
| UNKNOWN | **UNKNOWN** ← NOT NULL is NOT TRUE! |

```sql
-- Practical consequence:
-- WHERE NOT (status = 'FAILED')
-- When status IS NULL: NOT (UNKNOWN) = UNKNOWN → row EXCLUDED
-- This is why NOT IN with NULLs poisons results (see Part 4 of Section 32)

-- FALSE AND UNKNOWN = FALSE (safe — short-circuit applies):
WHERE is_blocked = FALSE AND txn_amount > 1000000
-- If is_blocked is FALSE for a row, the second condition is never evaluated

-- TRUE OR UNKNOWN = TRUE (safe):
WHERE kyc_status = 'APPROVED' OR region = 'MUMBAI'
-- If kyc_status = 'APPROVED', the row is included even if region IS NULL
---

#### I-3. NULL in Arithmetic

**Any arithmetic operation on NULL produces NULL:**

```sql
SELECT 100 + NULL;      -- NULL (not 100)
SELECT NULL * 0;        -- NULL (not 0!)
SELECT NULL / 100;      -- NULL
SELECT NULL - NULL;     -- NULL
SELECT POWER(NULL, 2);  -- NULL

-- Real-world trap: EMI balance calculation
-- If repaid_amount is NULL (no repayment recorded yet), net_balance is NULL too
SELECT loan_id,
       principal - repaid_amount AS net_balance    -- NULL if repaid_amount IS NULL
FROM loans;

-- CORRECT:
SELECT loan_id,
       principal - COALESCE(repaid_amount, 0) AS net_balance
FROM loans;

-- Compound expression trap: one NULL poisons the whole expression
SELECT loan_id,
       (disbursement_amount + processing_fee + gst_amount) AS total_cost
FROM disbursements;
-- If ANY of the three columns is NULL → total_cost is NULL for that row
-- FIX:
       (COALESCE(disbursement_amount, 0)
      + COALESCE(processing_fee, 0)
      + COALESCE(gst_amount, 0))  AS total_cost
---

#### I-4. IS NULL / IS NOT NULL — The Only Correct NULL Check

```sql
-- WRONG — never returns rows (= with NULL = UNKNOWN):
WHERE status = NULL
WHERE manager_id != NULL

-- CORRECT:
WHERE status IS NULL
WHERE manager_id IS NOT NULL

-- In a CASE expression:
CASE
    WHEN repayment_date IS NULL THEN 'Outstanding'
    WHEN repayment_date <= due_date THEN 'On Time'
    ELSE 'Late'
END AS repayment_status
-- WRONG version:
CASE
    WHEN repayment_date = NULL THEN 'Outstanding'  -- never matched!
    ...
END
---

#### I-5. COALESCE — Return First Non-NULL

`COALESCE(expr1, expr2, ..., exprN)` returns the first argument that is not NULL. Short-circuits — stops evaluating once a non-NULL is found.

```sql
-- Replace NULL with a default
SELECT COALESCE(bonus, 0) AS bonus_safe FROM employees;

-- Fallback chain (try email → phone → 'unknown')
SELECT COALESCE(email, phone, 'unknown') AS contact FROM users;

-- Fintech: use T+1 settlement date if same-day is NULL
SELECT
    txn_id,
    COALESCE(same_day_settle_dt, t1_settle_dt, t2_settle_dt, t3_settle_dt) AS effective_settle_dt
FROM settlement_records;

-- Running total with COALESCE to handle NULL gaps in sparse data
SELECT
    dt,
    COALESCE(daily_revenue, 0) AS revenue,   -- 0 for days with no transactions
    SUM(COALESCE(daily_revenue, 0)) OVER (ORDER BY dt ROWS UNBOUNDED PRECEDING) AS running_total
FROM date_spine
LEFT JOIN daily_revenue_agg USING (dt);
---

#### I-6. NULLIF — Prevent Divide-by-Zero

`NULLIF(a, b)` returns NULL if a = b; otherwise returns a. Almost exclusively used to avoid divide-by-zero.

```sql
-- Without NULLIF: ERROR when denominator = 0
SELECT successful_kyc / total_attempts AS pass_rate FROM kyc_daily;

-- With NULLIF: returns NULL when total_attempts = 0 (no error)
SELECT successful_kyc / NULLIF(total_attempts, 0) AS pass_rate FROM kyc_daily;

-- Combined with COALESCE to return 0 instead of NULL
SELECT COALESCE(successful_kyc / NULLIF(total_attempts, 0), 0) AS pass_rate
FROM kyc_daily;

-- Real use: month-over-month growth rate (LAG returns NULL for first month)
SELECT
    month,
    revenue,
    ROUND(
        (revenue - LAG(revenue) OVER (ORDER BY month))
        / NULLIF(LAG(revenue) OVER (ORDER BY month), 0) * 100
    , 2) AS mom_growth_pct
FROM monthly_revenue;
-- LAG returns NULL for first month → NULL / NULLIF(NULL, 0) = NULL (no error)
-- NULLIF also guards against 0 prior revenue (new product launches)
---

#### I-7. IS DISTINCT FROM / IS NOT DISTINCT FROM

`IS DISTINCT FROM` is a **NULL-safe equality check**. Unlike `=`, it never returns UNKNOWN — it always returns TRUE or FALSE, treating NULL as a concrete value equal to itself.

| A | B | A = B | A IS DISTINCT FROM B |
|---|---|-------|----------------------|
| 1 | 1 | TRUE | FALSE |
| 1 | 2 | FALSE | TRUE |
| NULL | NULL | **UNKNOWN** | **FALSE** ← NULLs are equal here |
| NULL | 1 | **UNKNOWN** | **TRUE** |
| 1 | NULL | **UNKNOWN** | **TRUE** |

`IS NOT DISTINCT FROM` is the NULL-safe `=`: returns TRUE when both sides are equal **or both are NULL**.

```sql
-- Fintech scenario: loan_applications table
-- `co_applicant_id` is NULL when no co-applicant exists
-- Task: find rows where co_applicant_id changed between two snapshots

-- WRONG — misses cases where either side is NULL:
WHERE curr.co_applicant_id != prev.co_applicant_id
-- NULL != 5 = UNKNOWN → change from NULL→5 silently ignored

-- CORRECT — catches NULL→value, value→NULL, and value→different-value:
WHERE curr.co_applicant_id IS DISTINCT FROM prev.co_applicant_id

-- Inverse: find rows that did NOT change (including both NULL = both NULL):
WHERE curr.co_applicant_id IS NOT DISTINCT FROM prev.co_applicant_id
```sql
-- CDC / change-detection pattern: flag any column that changed across snapshots
-- Common in SCD Type 2 pipelines and audit-log generators

SELECT
    loan_id,
    CASE WHEN curr.status        IS DISTINCT FROM prev.status        THEN 1 ELSE 0 END AS status_changed,
    CASE WHEN curr.interest_rate IS DISTINCT FROM prev.interest_rate THEN 1 ELSE 0 END AS rate_changed,
    CASE WHEN curr.co_applicant_id IS DISTINCT FROM prev.co_applicant_id THEN 1 ELSE 0 END AS co_app_changed
FROM loan_snapshots curr
JOIN loan_snapshots prev USING (loan_id)
WHERE curr.snapshot_date = CURRENT_DATE
  AND prev.snapshot_date = CURRENT_DATE - 1;
```sql
-- WHERE filter that includes NULLs cleanly (equivalent to != but NULL-safe):
-- "Give me all transactions that are NOT 'FAILED'"
-- i.e., SUCCESS + PENDING (NULL status) should be included

-- WRONG:
WHERE status != 'FAILED'          -- excludes NULL-status rows (UNKNOWN → excluded)

-- CORRECT with IS DISTINCT FROM:
WHERE status IS DISTINCT FROM 'FAILED'   -- NULL IS DISTINCT FROM 'FAILED' = TRUE → included

-- CORRECT with explicit IS NULL:
WHERE status != 'FAILED' OR status IS NULL
```


**Key rules:**
- Use `IS DISTINCT FROM` wherever you would use `!=` but the columns can be NULL.
- Use `IS NOT DISTINCT FROM` wherever you would use `=` on nullable columns (especially JOIN keys, deduplication checks, SCD change detection).

