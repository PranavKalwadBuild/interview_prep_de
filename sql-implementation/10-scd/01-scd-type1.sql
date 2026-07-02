USE `sql-patterns`;

-- =============================================================================
-- FILE: 01-scd-type1.sql
-- TOPIC: Slowly Changing Dimensions — Type 1 (Overwrite) + Type 3 (Previous Col)
-- DATABASE: sql-patterns
-- =============================================================================


-- =============================================================================
-- SECTION 1: What Is SCD Type 1?
-- =============================================================================
-- SCD Type 1: Overwrite the existing row in place. No history is retained.
--
-- When to use:
--   - Correcting data entry errors (typo in name, NULL email that should exist)
--   - Updating attributes where past values have zero business value
--   - Propagating a rename (department renamed, job title terminology changed)
--
-- When NOT to use:
--   - Salary changes (you lose the old salary — use SCD Type 2)
--   - Status transitions that need audit trails (active → terminated)
--   - Any attribute where "what was it last year?" is a valid business question
--
-- In this schema:
--   employees = our Type 1 "current state" table (job_title, dept_id, salary, status)
--   salary_history = the Type 2 table built alongside it (see 02-scd-type2.sql)
-- =============================================================================


-- =============================================================================
-- SECTION 2: Simple UPDATE (In-Place Overwrite)
-- =============================================================================

-- --- 2a: Fix NULL email for emp 22 (Victor Lee) ---

-- Before:
SELECT emp_id, first_name, last_name, email
FROM employees
WHERE emp_id = 22;
-- Expected: emp_id=22, email=NULL

-- Fix:
UPDATE employees
SET email = 'v.lee@corp.com'
WHERE emp_id = 22;

-- After:
SELECT emp_id, first_name, last_name, email
FROM employees
WHERE emp_id = 22;
-- Expected: email='v.lee@corp.com'
-- The old NULL value is gone — SCD1: no history retained.


-- --- 2b: Fix emp 19 (Samuel Clark) — salary=0.00 looks like a data load error ---
-- emp 18 is in the same band; correct emp 19 to 115000.00

-- Before:
SELECT emp_id, first_name, last_name, salary
FROM employees
WHERE emp_id IN (18, 19)
ORDER BY emp_id;
-- Expected: emp 18=115000.00, emp 19=0.00

-- Fix:
UPDATE employees
SET salary = 115000.00
WHERE emp_id = 19;

-- After:
SELECT emp_id, first_name, last_name, salary
FROM employees
WHERE emp_id IN (18, 19)
ORDER BY emp_id;
-- Expected: both emp 18 and emp 19 = 115000.00


-- =============================================================================
-- SECTION 3: Conditional UPDATE (Upsert-Like / Idempotent)
-- =============================================================================

-- --- 3a: Update only if incoming value differs from current ---
-- Prevents a no-op write from creating unnecessary lock contention.
-- Pattern: include the old value in the WHERE clause.

-- Promote emp 5 (Emma Davis) to Principal Engineer only if not already that title:
UPDATE employees
SET job_title = 'Principal Engineer'
WHERE emp_id = 5
  AND job_title != 'Principal Engineer';

-- Verify:
SELECT emp_id, first_name, last_name, job_title
FROM employees
WHERE emp_id = 5;
-- Expected: job_title='Principal Engineer'
-- If she was already 'Principal Engineer', zero rows affected — safe to re-run.


-- --- 3b: INSERT ... ON DUPLICATE KEY UPDATE (MySQL's single-row MERGE substitute) ---
-- MySQL has no MERGE INTO. For a single-row upsert on a PK, use this pattern.
-- If emp_id=5 exists  → triggers the ON DUPLICATE KEY branch (UPDATE).
-- If emp_id=5 doesn't exist → INSERT fires.

INSERT INTO employees
    (emp_id, first_name, last_name, email, phone, dept_id, manager_id,
     job_title, hire_date, salary, status, termination_date)
VALUES
    (5, 'Emma', 'Davis', 'e.davis@corp.com', '555-0105', 2, 1,
     'Principal Engineer', '2018-09-10', 160000.00, 'Active', NULL)
ON DUPLICATE KEY UPDATE
    job_title        = VALUES(job_title),
    salary           = VALUES(salary),
    email            = VALUES(email);

-- Explanation:
--   VALUES(col) inside ON DUPLICATE KEY refers to the value in the INSERT row.
--   This is MySQL's closest equivalent to: MERGE ... WHEN MATCHED THEN UPDATE.
--   Limitation: only handles a single row cleanly; for bulk, see Section 4.

SELECT emp_id, first_name, last_name, job_title, salary
FROM employees
WHERE emp_id = 5;
-- Expected: job_title='Principal Engineer', salary=160000.00


-- =============================================================================
-- SECTION 4: Bulk MERGE Simulation (Staging CTE → Target Table)
-- =============================================================================
-- MySQL has no MERGE INTO statement.
-- The two-step workaround:
--   Step 1 — UPDATE rows that already exist (WHEN MATCHED THEN UPDATE)
--   Step 2 — INSERT rows that do not exist (WHEN NOT MATCHED THEN INSERT)

-- Simulated incoming staging data:
WITH staging AS (
    SELECT 2  AS emp_id, 'Sarah'  AS first_name, 'Chen'     AS last_name,
           's.chen@corp.com'   AS email, '555-0202' AS phone,
           1  AS dept_id, NULL AS manager_id,
           'Chief Technology Officer' AS job_title,
           '2016-06-15' AS hire_date, 290000.00 AS salary,
           'Active' AS status, NULL AS termination_date
    UNION ALL
    SELECT 35, 'Irene', 'Nelson',
           'i.nelson@corp.com', '555-0335',
           4, 3,
           'Data Analyst',
           '2021-11-01', 72000.00,
           'Terminated', '2024-03-31'
    UNION ALL
    SELECT 99, 'New', 'Employee',
           'new.emp@corp.com', '555-0999',
           3, 2,
           'Junior Developer',
           '2024-12-01', 75000.00,
           'Active', NULL
)

-- Step 1: UPDATE existing employees from staging (MATCHED branch)
-- Run as a standalone UPDATE joining employees to the staging CTE.
-- (CTEs cannot be referenced across separate DML statements in MySQL;
--  in practice, load staging into a real temp table first.)
SELECT 'STEP 1 — rows to UPDATE (emp_id exists in both):' AS step;

SELECT s.*
FROM staging s
WHERE s.emp_id IN (SELECT emp_id FROM employees);
-- Expected: emp_id 2 (Sarah Chen raise) and emp_id 35 (Irene Nelson termination)

-- Step 1 actual UPDATE (using a subquery workaround since MySQL CTEs can't span DML):
UPDATE employees e
JOIN (
    SELECT 2 AS emp_id, 290000.00 AS salary, 'Chief Technology Officer' AS job_title,
           'Active' AS status, NULL AS termination_date
    UNION ALL
    SELECT 35, 72000.00, 'Data Analyst', 'Terminated', '2024-03-31'
) AS incoming ON e.emp_id = incoming.emp_id
SET e.salary           = incoming.salary,
    e.job_title        = incoming.job_title,
    e.status           = incoming.status,
    e.termination_date = incoming.termination_date;

-- Verify:
SELECT emp_id, first_name, last_name, salary, status, termination_date
FROM employees
WHERE emp_id IN (2, 35);
-- Expected: emp 2 salary=290000, emp 35 status='Terminated'


SELECT 'STEP 2 — rows to INSERT (emp_id NOT in employees):' AS step;

-- Step 2: INSERT new employees that do not exist yet (NOT MATCHED branch)
INSERT INTO employees
    (emp_id, first_name, last_name, email, phone, dept_id, manager_id,
     job_title, hire_date, salary, status, termination_date)
SELECT emp_id, first_name, last_name, email, phone, dept_id, manager_id,
       job_title, hire_date, salary, status, termination_date
FROM (
    SELECT 99 AS emp_id, 'New' AS first_name, 'Employee' AS last_name,
           'new.emp@corp.com' AS email, '555-0999' AS phone,
           3 AS dept_id, 2 AS manager_id,
           'Junior Developer' AS job_title,
           '2024-12-01' AS hire_date, 75000.00 AS salary,
           'Active' AS status, NULL AS termination_date
) AS incoming
WHERE incoming.emp_id NOT IN (SELECT emp_id FROM employees);

-- Verify:
SELECT emp_id, first_name, last_name, job_title, salary
FROM employees
WHERE emp_id = 99;
-- Expected: 1 row, emp_id=99 'New Employee'

-- NOTE: MySQL has no single MERGE statement. This two-step pattern is the
-- standard workaround. A staging table (not a CTE) is preferred in production
-- because CTEs cannot be referenced across multiple DML statements.


-- =============================================================================
-- SECTION 5: SCD1 with NULL Coalescing (Never Overwrite With NULL)
-- =============================================================================
-- Problem: source system sends NULL for an email when the value is simply
-- "not provided in this feed," not "intentionally cleared."
-- A blind UPDATE would destroy a valid email already in the database.

-- Safe pattern — only overwrite if incoming value is non-NULL:
UPDATE employees
SET email = COALESCE('v.lee@corp.com', email)  -- incoming_email replaces only if non-NULL
WHERE emp_id = 22;

-- If incoming_email were NULL:
UPDATE employees
SET email = COALESCE(NULL, email)   -- COALESCE(NULL, existing) = existing → no-op
WHERE emp_id = 22;

-- Bulk version with a source join:
UPDATE employees e
JOIN (
    SELECT 22 AS emp_id, NULL AS new_email   -- source sends NULL
    UNION ALL
    SELECT 19, 's.clark@corp.com'             -- source sends real value
) AS src ON e.emp_id = src.emp_id
SET e.email = COALESCE(src.new_email, e.email);
-- Result: emp 22 email unchanged (NULL coalesced to existing); emp 19 email updated.

SELECT emp_id, email
FROM employees
WHERE emp_id IN (19, 22);
-- Expected: emp 22 keeps existing email; emp 19 gets 's.clark@corp.com'


-- =============================================================================
-- SECTION 6: Audit Trail Pattern (When Type 1 Becomes Type 2)
-- =============================================================================
-- SCD Type 1 discards the old value. If you need to know what it was before,
-- you must capture it BEFORE the UPDATE — which turns this into Type 2 behavior.

-- Hypothetical audit table (not in the schema; shown as conceptual DDL):
-- CREATE TABLE employees_audit (
--     audit_id      INT AUTO_INCREMENT PRIMARY KEY,
--     emp_id        INT          NOT NULL,
--     column_name   VARCHAR(64)  NOT NULL,
--     old_value     VARCHAR(255),
--     new_value     VARCHAR(255),
--     changed_at    DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
--     changed_by    INT
-- );

-- Pattern: capture old value first, then overwrite
--
-- Step 1 — Log the old value:
-- INSERT INTO employees_audit (emp_id, column_name, old_value, new_value, changed_by)
-- SELECT emp_id, 'email', email, 'v.lee@corp.com', 1
-- FROM employees
-- WHERE emp_id = 22;
--
-- Step 2 — Overwrite (SCD1):
-- UPDATE employees SET email = 'v.lee@corp.com' WHERE emp_id = 22;

-- Key point: the moment you need to answer "what was the email before?",
-- Type 1 is no longer appropriate — you've crossed into Type 2 territory.
-- Use an audit table or an event log if the change history has business value.


-- =============================================================================
-- SECTION 7: SCD Type 3 — Previous Value Column
-- =============================================================================
-- Type 3: Keep only ONE prior version of an attribute in a dedicated column.
-- Trade-off: trivial to query "current vs. previous" but loses all older history.

-- Conceptual DDL (do NOT run — schema is read-only for this exercise):
-- ALTER TABLE employees
--     ADD COLUMN previous_salary DECIMAL(12,2) NULL,
--     ADD COLUMN salary_changed_date DATE NULL;

-- UPDATE pattern (shift current → previous, apply new):
UPDATE employees
SET
    previous_salary    = salary,            -- archive current into "previous" column
    salary             = 160000.00,         -- overwrite with new value
    salary_changed_date = CURRENT_DATE
WHERE emp_id = 5;

-- Query current vs. previous:
SELECT emp_id, first_name, last_name,
       salary           AS current_salary,
       -- previous_salary AS prior_salary,   -- would exist if column were added
       -- salary_changed_date
       'previous_salary column would live here' AS note
FROM employees
WHERE emp_id = 5;

-- Limitation: only 1 level of history is retained.
-- When a 3rd salary change arrives:
--   current=160000  previous=145000  (oldest: 132000 is PERMANENTLY LOST)
-- Use SCD Type 2 (salary_history table) when the full history matters.
