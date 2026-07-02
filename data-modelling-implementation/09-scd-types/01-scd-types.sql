-- =============================================================================
-- FILE: 09-scd-types/01-scd-types.sql
-- DATABASE: dm_warehouse (source: dm_oltp)
-- PURPOSE: Demonstrate SCD Types 0, 1, 2, 3, 4, and 6 on the employee domain
-- MySQL 8.0+
-- =============================================================================

USE dm_warehouse;

-- =============================================================================
-- SECTION 1 — SCD TYPE 0: Retain Original / No Change
-- Rule: once written, the column is NEVER updated regardless of source changes.
-- Use cases: regulatory fields, original contract price, founding date,
--            the "as-was-on-hire" snapshot of any attribute.
-- =============================================================================

-- DDL: dept_name_original is protected by convention (application enforces no UPDATE)
CREATE TABLE IF NOT EXISTS dim_dept_type0 (
    dept_sk           INT          NOT NULL AUTO_INCREMENT,
    dept_id           INT          NOT NULL,
    dept_name_original VARCHAR(100) NOT NULL COMMENT 'SCD0 - written once at load time, never overwritten',
    location          VARCHAR(100),
    budget            DECIMAL(15,2),
    PRIMARY KEY (dept_sk),
    UNIQUE KEY uq_dept_id (dept_id)
);

-- Initial load: capture dept_name exactly as it exists in source today
INSERT INTO dim_dept_type0 (dept_id, dept_name_original, location, budget)
SELECT
    dept_id,
    dept_name,       -- captured once; future renames in OLTP do NOT flow here
    location,
    budget
FROM dm_oltp.departments
ON DUPLICATE KEY UPDATE
    -- SCD0: intentionally update NOTHING on dept_name_original
    location = VALUES(location),   -- non-SCD0 columns can still update if desired
    budget   = VALUES(budget);

-- Demonstration: even if the OLTP source renames 'Engineering' to 'Software Engineering',
-- the following UPDATE is intentionally ABSENT from ETL pipelines for SCD0 columns:
--
--   UPDATE dim_dept_type0
--   SET    dept_name_original = src.dept_name          -- <-- this line must NOT exist
--   FROM   dm_oltp.departments src
--   WHERE  dim_dept_type0.dept_id = src.dept_id;
--
-- Result: dim_dept_type0.dept_name_original always reflects the original name.

-- Verification: compare warehouse original vs current OLTP value
SELECT
    d0.dept_id,
    d0.dept_name_original                          AS warehouse_original,
    oltp.dept_name                                 AS oltp_current,
    IF(d0.dept_name_original = oltp.dept_name,
       'IN SYNC', 'OLTP CHANGED - warehouse preserved original') AS status
FROM   dim_dept_type0  d0
JOIN   dm_oltp.departments oltp USING (dept_id);


-- =============================================================================
-- SECTION 2 — SCD TYPE 1: Overwrite, No History
-- Rule: update the column in-place; old value is permanently lost.
-- Use cases: fixing typos, backfilling NULLs with newly discovered data,
--            correcting data-entry errors where history is irrelevant.
-- =============================================================================

-- Fix emp 22: email was NULL at load time; real email is now known
UPDATE dim_employee
SET    email = 'emp22@company.com'
WHERE  emp_id    = 22
  AND  is_current = 1;

-- Fix emp 19: salary recorded as 0.00 (data-entry error); correct value provided
UPDATE dim_employee
SET    salary = 72000.00
WHERE  emp_id    = 19
  AND  is_current = 1;

-- If SCD2 is also in play, SCD1 fixes should propagate to ALL versions of the row
-- (because the correction applies to the attribute, not to a point-in-time snapshot):
UPDATE dim_employee
SET    email = 'emp22@company.com'
WHERE  emp_id = 22;   -- no is_current filter — fix all historical rows too

-- Verification
SELECT emp_id, email, salary, is_current
FROM   dim_employee
WHERE  emp_id IN (22, 19)
ORDER  BY emp_id, effective_date;


-- =============================================================================
-- SECTION 3 — SCD TYPE 2: Add New Row, Preserve Full History
-- Rule: expire the current row (set expiry_date, is_current=0),
--       then INSERT a new row with the updated attributes.
-- Use cases: job title changes, department transfers, salary bands —
--            any attribute where "what was it THEN?" matters.
-- =============================================================================

-- Scenario: emp 7 (Alice Johnson) is promoted
--   Before: Senior Software Engineer, job_sk = 3, salary = 95 000
--   After:  Engineering Lead,         job_sk = 5, salary = 105 000
--   Effective: 2024-06-01

-- Step 1: look up the new job_sk (Engineering Lead)
-- SELECT job_sk FROM dim_job WHERE job_title = 'Engineering Lead';  -- returns 5

-- Step 2: expire the current row (close the window)
UPDATE dim_employee
SET    expiry_date = '2024-05-31',
       is_current  = 0
WHERE  emp_id     = 7
  AND  is_current = 1;

-- Step 3: insert the new version
INSERT INTO dim_employee
    (emp_id, first_name, last_name, email,
     job_sk, dept_sk, flag_sk,
     salary, manager_emp_id,
     hire_date, termination_date,
     effective_date, expiry_date, is_current)
SELECT
    emp_id, first_name, last_name, email,
    5      AS job_sk,           -- Engineering Lead
    dept_sk, flag_sk,
    105000 AS salary,
    manager_emp_id,
    hire_date, termination_date,
    '2024-06-01' AS effective_date,
    NULL         AS expiry_date,
    1            AS is_current
FROM  dim_employee
WHERE emp_id = 7
LIMIT 1;  -- pull non-changing attributes from the just-expired row

-- ── Point-in-time query: "What was Alice's role on 2024-01-01?" ──────────────
SELECT
    de.employee_sk,
    de.emp_id,
    de.first_name,
    de.last_name,
    dj.job_title,
    de.salary,
    de.effective_date,
    de.expiry_date
FROM   dim_employee de
JOIN   dim_job      dj ON de.job_sk = dj.job_sk
WHERE  de.emp_id           = 7
  AND  de.effective_date  <= '2024-01-01'
  AND (de.expiry_date      > '2024-01-01' OR de.expiry_date IS NULL);
-- Returns: Senior Software Engineer row (the pre-promotion version)

-- ── Current-state query: all active employees ────────────────────────────────
SELECT
    de.emp_id,
    de.first_name,
    de.last_name,
    dj.job_title,
    dd.dept_name,
    de.salary
FROM   dim_employee  de
JOIN   dim_job       dj ON de.job_sk  = dj.job_sk
JOIN   dim_department dd ON de.dept_sk = dd.dept_sk
WHERE  de.is_current = 1;

-- ── Fact join that respects SCD2 ─────────────────────────────────────────────
-- fact_salary_payment stores employee_sk (the SK valid at payment time).
-- The SK already points to the correct historical row — no date-range join needed.
SELECT
    fsp.pay_year,
    fsp.pay_month,
    de.emp_id,
    de.first_name,
    de.last_name,
    dj.job_title          AS job_at_payment_time,
    fsp.salary_amount,
    fsp.bonus_amount
FROM   fact_salary_payment fsp
JOIN   dim_employee        de  ON fsp.employee_sk = de.employee_sk   -- SK-level join
JOIN   dim_job             dj  ON de.job_sk        = dj.job_sk
WHERE  fsp.pay_year = 2024
ORDER  BY fsp.pay_month, de.emp_id;

-- All history for emp 7
SELECT
    employee_sk,
    emp_id,
    effective_date,
    expiry_date,
    is_current,
    salary
FROM   dim_employee
WHERE  emp_id = 7
ORDER  BY effective_date;


-- =============================================================================
-- SECTION 4 — SCD TYPE 3: Current + Previous Column
-- Rule: add a "previous_<attr>" column; on change, shift current → previous,
--       write new value into current column. Only ONE prior value is kept.
-- Use cases: "show me where this employee came from" (one transfer back only),
--            low-cardinality attributes that rarely change.
-- =============================================================================

CREATE TABLE IF NOT EXISTS dim_emp_type3 (
    emp_id           INT          NOT NULL,
    first_name       VARCHAR(100),
    last_name        VARCHAR(100),
    current_dept_id  INT          NOT NULL COMMENT 'SCD3 current value',
    previous_dept_id INT                   COMMENT 'SCD3 prior value — only one step back',
    dept_change_date DATE                  COMMENT 'when the most recent dept change occurred',
    PRIMARY KEY (emp_id)
);

-- Initial load (no history yet; previous = NULL)
INSERT INTO dim_emp_type3 (emp_id, first_name, last_name, current_dept_id, previous_dept_id, dept_change_date)
SELECT
    emp_id,
    first_name,
    last_name,
    dept_id AS current_dept_id,
    NULL    AS previous_dept_id,
    NULL    AS dept_change_date
FROM dm_oltp.employees;

-- Scenario: emp 3 transfers from Finance (dept 4) to Engineering (dept 1) on 2024-03-15
UPDATE dim_emp_type3
SET
    previous_dept_id = current_dept_id,    -- shift current → previous
    current_dept_id  = 1,                  -- Engineering
    dept_change_date = '2024-03-15'
WHERE emp_id = 3;

-- Query: find all employees who have changed departments
SELECT
    emp_id,
    first_name,
    last_name,
    previous_dept_id,
    current_dept_id,
    dept_change_date
FROM   dim_emp_type3
WHERE  previous_dept_id IS NOT NULL
  AND  current_dept_id != previous_dept_id;

-- ── LIMITATION: only one prior value ─────────────────────────────────────────
-- If emp 3 now moves AGAIN from Engineering (1) to HR (dept 6):
UPDATE dim_emp_type3
SET
    previous_dept_id = current_dept_id,   -- overwrites Finance (dept 4) — LOST forever
    current_dept_id  = 6,
    dept_change_date = '2025-01-10'
WHERE emp_id = 3;
-- At this point we know: was Engineering, now HR.
-- The original Finance stint is permanently gone.
-- If you need that, use SCD2 instead.


-- =============================================================================
-- SECTION 5 — SCD TYPE 4: Mini-Dimension / History Table
-- Pattern: separate the fast-changing attribute into its own history table.
--          The main dimension row stays stable; no SCD2 row explosion.
-- Use case: salary changes 2x/year on average; name changes ~0.1x/year.
--           Without SCD4, every salary bump doubles the dim_employee rows.
-- =============================================================================

-- History table: one row per salary change event
CREATE TABLE IF NOT EXISTS dim_employee_salary_hist (
    hist_sk        INT          NOT NULL AUTO_INCREMENT,
    emp_id         INT          NOT NULL,
    salary         DECIMAL(15,2) NOT NULL,
    effective_date DATE         NOT NULL,
    expiry_date    DATE                   COMMENT 'NULL means currently active',
    load_dts       DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (hist_sk),
    INDEX idx_emp_salary (emp_id, effective_date)
);

-- Populate from source salary history (assumes dm_oltp.salary_history exists)
-- In practice this is loaded by your ETL; shown here for completeness.
INSERT INTO dim_employee_salary_hist (emp_id, salary, effective_date, expiry_date)
SELECT
    emp_id,
    salary,
    effective_date,
    LEAD(effective_date - INTERVAL 1 DAY)
        OVER (PARTITION BY emp_id ORDER BY effective_date) AS expiry_date
FROM dm_oltp.salary_history;

-- Fallback: seed from current dim_employee if salary_history table doesn't exist
INSERT IGNORE INTO dim_employee_salary_hist (emp_id, salary, effective_date, expiry_date)
SELECT emp_id, salary, hire_date AS effective_date, NULL AS expiry_date
FROM   dm_oltp.employees
WHERE  salary IS NOT NULL AND salary > 0;

-- ── dim_employee stays stable: ONE row per employee ───────────────────────────
-- (no is_current flag needed for this pattern)
SELECT
    de.emp_id,
    de.first_name,
    de.last_name,
    -- current salary: join to history table, pick active row
    sh.salary AS current_salary
FROM   dim_employee           de
JOIN   dim_employee_salary_hist sh
       ON  sh.emp_id       = de.emp_id
       AND sh.expiry_date IS NULL   -- active row
WHERE  de.is_current = 1;

-- ── Point-in-time salary lookup ───────────────────────────────────────────────
SELECT
    de.emp_id,
    de.first_name,
    sh.salary,
    sh.effective_date
FROM   dim_employee            de
JOIN   dim_employee_salary_hist sh
       ON  sh.emp_id          = de.emp_id
       AND sh.effective_date <= '2023-01-01'
       AND (sh.expiry_date    > '2023-01-01' OR sh.expiry_date IS NULL)
WHERE  de.is_current = 1;

-- ── Salary history for one employee ──────────────────────────────────────────
SELECT
    hist_sk,
    emp_id,
    salary,
    effective_date,
    expiry_date,
    DATEDIFF(COALESCE(expiry_date, CURDATE()), effective_date) AS days_at_salary
FROM   dim_employee_salary_hist
WHERE  emp_id = 7
ORDER  BY effective_date;


-- =============================================================================
-- SECTION 6 — SCD TYPE 6: Hybrid (Type 1 + Type 2 + Type 3)
-- Rule:
--   current_dept_name  = SCD1 (always shows the LATEST value; updated on ALL rows)
--   original_dept_name = SCD0 (first value ever; never changes)
--   effective/expiry/is_current = SCD2 (full versioning of each change)
-- Use case: "as-was" history AND "as-is" current state in a single table,
--           without needing two separate queries.
-- =============================================================================

CREATE TABLE IF NOT EXISTS dim_emp_type6 (
    employee_sk        INT           NOT NULL AUTO_INCREMENT,
    emp_id             INT           NOT NULL,
    first_name         VARCHAR(100),
    last_name          VARCHAR(100),
    current_dept_name  VARCHAR(100)  NOT NULL COMMENT 'SCD1 — always the latest dept name, updated on ALL versions',
    original_dept_name VARCHAR(100)  NOT NULL COMMENT 'SCD0 — dept at time of first load, never overwritten',
    effective_date     DATE          NOT NULL,
    expiry_date        DATE                   COMMENT 'NULL = current row',
    is_current         TINYINT(1)    NOT NULL DEFAULT 1,
    PRIMARY KEY (employee_sk),
    INDEX idx_emp_id (emp_id),
    INDEX idx_current (is_current)
);

-- Initial load for all employees (single version per employee)
INSERT INTO dim_emp_type6
    (emp_id, first_name, last_name,
     current_dept_name, original_dept_name,
     effective_date, expiry_date, is_current)
SELECT
    e.emp_id,
    e.first_name,
    e.last_name,
    d.dept_name AS current_dept_name,   -- SCD1: starts as current
    d.dept_name AS original_dept_name,  -- SCD0: locked in at first load
    e.hire_date AS effective_date,
    NULL        AS expiry_date,
    1           AS is_current
FROM   dm_oltp.employees    e
JOIN   dm_oltp.departments  d ON e.dept_id = d.dept_id;

-- ── Scenario: emp 3 transfers from Finance → Engineering on 2024-03-15 ────────

-- Step A: SCD2 — expire the current row
UPDATE dim_emp_type6
SET    expiry_date = '2024-03-14',
       is_current  = 0
WHERE  emp_id     = 3
  AND  is_current = 1;

-- Step B: SCD2 — insert new version
INSERT INTO dim_emp_type6
    (emp_id, first_name, last_name,
     current_dept_name, original_dept_name,
     effective_date, expiry_date, is_current)
SELECT
    emp_id, first_name, last_name,
    'Engineering' AS current_dept_name,   -- new dept
    original_dept_name,                   -- SCD0: unchanged
    '2024-03-15' AS effective_date,
    NULL         AS expiry_date,
    1            AS is_current
FROM  dim_emp_type6
WHERE emp_id = 3
LIMIT 1;

-- Step C: SCD1 — update current_dept_name on ALL rows for emp 3
--         (historical rows now also show the latest dept, enabling "as-is" lookups
--          without a separate query)
UPDATE dim_emp_type6
SET    current_dept_name = 'Engineering'
WHERE  emp_id = 3;          -- applies to both old and new rows

-- ── What you get ─────────────────────────────────────────────────────────────
-- "As-was" (where was emp 3 on 2024-01-01?): use effective_date / expiry_date
SELECT
    emp_id, first_name, last_name,
    original_dept_name,
    current_dept_name,
    effective_date,
    expiry_date
FROM   dim_emp_type6
WHERE  emp_id          = 3
  AND  effective_date <= '2024-01-01'
  AND (expiry_date     > '2024-01-01' OR expiry_date IS NULL);
-- Returns the Finance row — but current_dept_name already shows 'Engineering'

-- "As-is" (where is emp 3 now?): use is_current = 1
SELECT emp_id, first_name, current_dept_name, original_dept_name
FROM   dim_emp_type6
WHERE  emp_id = 3 AND is_current = 1;

-- Full history for emp 3
SELECT
    employee_sk,
    emp_id,
    current_dept_name,
    original_dept_name,
    effective_date,
    expiry_date,
    is_current
FROM   dim_emp_type6
WHERE  emp_id = 3
ORDER  BY effective_date;

-- =============================================================================
-- END OF FILE
-- =============================================================================
