USE `sql-patterns`;

-- =============================================================================
-- NULL HANDLING IN MySQL 8.0+
-- Database: sql-patterns
-- Topics: Three-valued logic, COUNT, AVG, COALESCE, NULLIF, IFNULL,
--         NULL in WHERE/JOIN/GROUP BY/CASE/window functions, propagation,
--         data quality audit
-- Reference date: 2024-12-31
-- =============================================================================


-- -----------------------------------------------------------------------------
-- 1. THREE-VALUED LOGIC (3VL)
--    NULL comparisons always produce UNKNOWN, never TRUE
--    UNKNOWN in WHERE → row excluded
-- -----------------------------------------------------------------------------

-- NULL = NULL  →  UNKNOWN  →  no rows returned
SELECT emp_id, salary
FROM employees
WHERE salary = NULL;
-- Expected: 0 rows  (even though emp 10 and 15 have NULL salary)

-- Correct test: IS NULL
SELECT emp_id, salary
FROM employees
WHERE salary IS NULL;
-- Expected: emp 10, emp 15  (2 rows)

-- NULL != NULL  →  UNKNOWN  →  no rows returned
SELECT emp_id, salary
FROM employees
WHERE salary != NULL;
-- Expected: 0 rows

-- Correct complement: IS NOT NULL
SELECT emp_id, salary
FROM employees
WHERE salary IS NOT NULL;
-- Expected: 39 rows


-- -----------------------------------------------------------------------------
-- 2. COUNT(*) vs COUNT(col)
--    COUNT(*) counts every row; COUNT(col) skips NULLs
-- -----------------------------------------------------------------------------

SELECT
    COUNT(*)        AS total_rows,      -- 41
    COUNT(salary)   AS non_null_salary, -- 39  (emp 10, 15 excluded)
    COUNT(email)    AS non_null_email   -- 40  (emp 22 excluded)
FROM employees;
-- Expected: total_rows=41, non_null_salary=39, non_null_email=40


-- -----------------------------------------------------------------------------
-- 3. AVG WITH NULLs
--    AVG silently skips NULLs — denominator is count of non-NULL rows, not COUNT(*)
--    This can silently inflate or deflate the average
-- -----------------------------------------------------------------------------

SELECT
    AVG(salary)                    AS avg_salary_builtin, -- divides by 39
    SUM(salary) / COUNT(*)         AS avg_over_all_rows,  -- divides by 41 (includes NULLs as 0 conceptually... actually SUM skips NULLs too)
    SUM(salary) / COUNT(salary)    AS avg_manual_same,    -- same as AVG()
    SUM(COALESCE(salary, 0)) / COUNT(*) AS avg_null_as_zero -- treat NULL salary as 0 contribution
FROM employees;
-- avg_salary_builtin  ≈ avg_manual_same  (both divide by 39)
-- avg_over_all_rows   = avg_null_as_zero (SUM skips NULLs; COUNT(*) = 41)
-- avg_null_as_zero  < avg_salary_builtin  — the difference reveals the NULL impact


-- -----------------------------------------------------------------------------
-- 4. COALESCE — replace NULL with a fallback value
--    Returns first non-NULL argument; short-circuits evaluation
-- -----------------------------------------------------------------------------

SELECT
    emp_id,
    salary,
    COALESCE(salary, 0)  AS salary_display
FROM employees
WHERE salary IS NULL
ORDER BY emp_id;
-- Expected: emp 10 → 0, emp 15 → 0


-- -----------------------------------------------------------------------------
-- 5. COALESCE MULTI-ARG — cascade through multiple fallbacks
--    Use email; if NULL fall back to generated address
-- -----------------------------------------------------------------------------

SELECT
    emp_id,
    email,
    COALESCE(email, CONCAT('emp', emp_id, '@noemail.internal')) AS contact_email
FROM employees
ORDER BY emp_id;
-- emp 22: email IS NULL → contact_email = 'emp22@noemail.internal'
-- All other employees: contact_email = actual email value


-- -----------------------------------------------------------------------------
-- 6. NULLIF — convert a sentinel value to NULL
--    NULLIF(expr, value) returns NULL when expr = value, else returns expr
--    Reveals emp 19 whose salary=0.00 is semantically NULL (no pay / data error)
-- -----------------------------------------------------------------------------

SELECT
    emp_id,
    salary,
    NULLIF(salary, 0)  AS salary_nullif
FROM employees
WHERE salary IS NULL OR salary = 0
ORDER BY emp_id;
-- emp 10:  salary=NULL  → salary_nullif=NULL  (already NULL, unchanged)
-- emp 15:  salary=NULL  → salary_nullif=NULL
-- emp 19:  salary=0.00  → salary_nullif=NULL  ← NULLIF exposes this as effectively missing

-- Use case: safe average that treats both NULL and 0 as absent
SELECT
    AVG(NULLIF(salary, 0)) AS avg_excluding_zero_and_null
FROM employees;
-- Denominator: count of rows where salary IS NOT NULL AND salary != 0


-- -----------------------------------------------------------------------------
-- 7. IFNULL — MySQL-specific 2-arg shorthand (equivalent to COALESCE with 2 args)
-- -----------------------------------------------------------------------------

SELECT
    emp_id,
    salary,
    IFNULL(salary, 0)                  AS salary_ifnull,
    COALESCE(salary, 0)                AS salary_coalesce -- identical result
FROM employees
WHERE salary IS NULL
ORDER BY emp_id;
-- IFNULL and COALESCE(x, y) are semantically identical for 2 arguments
-- Prefer COALESCE for portability across databases; IFNULL is MySQL-only


-- -----------------------------------------------------------------------------
-- 8. NULL IN WHERE: IS NULL, IS NOT NULL, and the NOT IN TRAP
--    NOT IN with a NULL in the list causes ALL rows to be excluded (3VL)
-- -----------------------------------------------------------------------------

-- Straightforward IS NULL / IS NOT NULL
SELECT emp_id, dept_id FROM employees WHERE dept_id IS NULL;     -- 0 rows (all employees have a dept)
SELECT emp_id, dept_id FROM employees WHERE dept_id IS NOT NULL; -- 41 rows

-- THE NOT IN TRAP:
-- "Employees NOT in departments 1 or 2" — but we include NULL in the list by accident (or from a subquery)
SELECT emp_id
FROM employees
WHERE dept_id NOT IN (1, 2, NULL);
-- Expected: 0 rows
-- Why: NULL in the list → MySQL evaluates dept_id != NULL → UNKNOWN for every row
--      UNKNOWN is falsy in WHERE → every row excluded regardless of actual dept_id

-- Correct approach: filter NULL out of the exclusion set
SELECT emp_id
FROM employees
WHERE dept_id NOT IN (1, 2)
  AND dept_id IS NOT NULL;
-- Expected: employees whose dept_id is not 1, 2, and not NULL

-- Real-world trap: subquery that can return NULLs
-- BAD (if subquery returns any NULL, entire result is empty):
-- SELECT emp_id FROM employees WHERE dept_id NOT IN (SELECT dept_id FROM purchase_orders);
-- GOOD: exclude NULLs from subquery
SELECT emp_id
FROM employees
WHERE dept_id NOT IN (
    SELECT dept_id FROM purchase_orders WHERE dept_id IS NOT NULL
);
-- Expected: employees in departments that have no purchase orders


-- -----------------------------------------------------------------------------
-- 9. NULL IN JOIN
--    LEFT JOIN: NULL in the join key → row does not match any right-side row
--    purchase_orders.order 25 has dept_id=NULL → appears as orphaned row
-- -----------------------------------------------------------------------------

SELECT
    po.order_id,
    po.dept_id          AS po_dept_id,
    d.dept_name,
    po.amount
FROM purchase_orders po
LEFT JOIN departments d ON po.dept_id = d.dept_id
ORDER BY po.order_id;
-- order 25: dept_id=NULL → dept_name=NULL (never matches any department)
-- All other orders: dept_name populated

-- Identify orphaned purchase orders (dept_id IS NULL OR no matching department)
SELECT po.order_id, po.dept_id, po.vendor, po.amount
FROM purchase_orders po
LEFT JOIN departments d ON po.dept_id = d.dept_id
WHERE d.dept_id IS NULL;
-- Expected: order 25 (dept_id=NULL orphan) + any orders with invalid dept_id


-- -----------------------------------------------------------------------------
-- 10. NULL IN GROUP BY
--     MySQL groups NULL values together under a single NULL group key
-- -----------------------------------------------------------------------------

SELECT
    leave_type,
    COUNT(*) AS request_count
FROM leave_requests
GROUP BY leave_type
ORDER BY leave_type;
-- One row will have leave_type=NULL — MySQL collected all NULL leave_type rows into one group
-- This is standard SQL behavior: NULL is treated as a single group key value

-- To label the NULL group:
SELECT
    COALESCE(leave_type, '(unknown)')  AS leave_type_display,
    COUNT(*)                            AS request_count
FROM leave_requests
GROUP BY leave_type
ORDER BY leave_type_display;
-- request 11's leave_type=NULL → displayed as '(unknown)'


-- -----------------------------------------------------------------------------
-- 11. NULL IN CASE WHEN
--     CASE evaluates conditions top-to-bottom; NULL does not match any = comparison
--     Without an explicit IS NULL branch, NULLs fall through to ELSE
-- -----------------------------------------------------------------------------

-- Without IS NULL check: NULLs silently fall to ELSE
SELECT
    emp_id,
    salary,
    CASE
        WHEN salary > 100000 THEN 'High'
        WHEN salary BETWEEN 50000 AND 100000 THEN 'Mid'
        WHEN salary < 50000 THEN 'Low'
        ELSE 'Unknown'   -- emp 10, 15 (NULL) and emp 19 (0.00) land here
    END AS salary_band
FROM employees
ORDER BY emp_id;

-- With explicit IS NULL branch:
SELECT
    emp_id,
    salary,
    CASE
        WHEN salary IS NULL THEN 'No Salary Data'
        WHEN salary = 0    THEN 'Zero Salary'
        WHEN salary > 100000 THEN 'High'
        WHEN salary BETWEEN 50000 AND 100000 THEN 'Mid'
        ELSE 'Low'
    END AS salary_band
FROM employees
ORDER BY emp_id;
-- emp 10, 15 → 'No Salary Data'; emp 19 → 'Zero Salary'


-- -----------------------------------------------------------------------------
-- 12. NULL IN WINDOW FUNCTIONS
--     Aggregate window functions (SUM, AVG) skip NULLs
--     LAG/LEAD return NULL at partition boundary (no previous/next row)
-- -----------------------------------------------------------------------------

-- SUM() OVER skips NULL salary rows
SELECT
    emp_id,
    dept_id,
    salary,
    SUM(salary) OVER (PARTITION BY dept_id)   AS dept_salary_total,
    AVG(salary) OVER (PARTITION BY dept_id)   AS dept_salary_avg
FROM employees
ORDER BY dept_id, emp_id;
-- dept containing emp 10 or 15: total/avg computed without those rows (NULLs skipped)

-- LAG returns NULL at the first row of each partition (no prior row)
SELECT
    emp_id,
    hire_date,
    salary,
    LAG(salary) OVER (ORDER BY hire_date)      AS prev_hire_salary,
    salary - LAG(salary) OVER (ORDER BY hire_date) AS salary_diff
FROM employees
ORDER BY hire_date;
-- First row: prev_hire_salary=NULL, salary_diff=NULL (NULL propagation)
-- Any row where LAG returns a NULL salary: salary_diff=NULL


-- -----------------------------------------------------------------------------
-- 13. NULL PROPAGATION IN EXPRESSIONS
--     Any arithmetic or string operation involving NULL produces NULL
-- -----------------------------------------------------------------------------

-- Arithmetic: NULL + 100 = NULL
SELECT
    emp_id,
    salary,
    salary + 100                         AS salary_plus_100,       -- NULL for emp 10, 15
    COALESCE(salary, 0) + 100            AS salary_plus_100_safe   -- 100 for NULL rows
FROM employees
WHERE salary IS NULL OR emp_id <= 5
ORDER BY emp_id;

-- String concatenation: CONCAT with NULL → NULL in MySQL (not '' like PostgreSQL)
SELECT
    emp_id,
    first_name,
    email,
    CONCAT('Contact: ', email)                                      AS contact_raw,   -- NULL for emp 22
    CONCAT('Contact: ', COALESCE(email, 'N/A'))                     AS contact_safe,  -- 'Contact: N/A'
    CONCAT_WS(' | ', first_name, last_name, email)                  AS concat_ws_demo  -- CONCAT_WS skips NULLs
FROM employees
WHERE email IS NULL OR emp_id <= 3
ORDER BY emp_id;
-- CONCAT_WS (concat with separator) automatically skips NULL arguments — useful for building display strings


-- -----------------------------------------------------------------------------
-- 14. DATA QUALITY: MULTI-COLUMN NULL AUDIT
--     Find employees with any critical field missing
-- -----------------------------------------------------------------------------

SELECT
    emp_id,
    CONCAT(first_name, ' ', last_name)  AS full_name,
    CASE WHEN salary           IS NULL THEN 'Y' ELSE 'N' END AS salary_null,
    CASE WHEN email            IS NULL THEN 'Y' ELSE 'N' END AS email_null,
    CASE WHEN dept_id          IS NULL THEN 'Y' ELSE 'N' END AS dept_null,
    CASE WHEN job_title        IS NULL THEN 'Y' ELSE 'N' END AS jobtitle_null,
    CASE WHEN manager_id       IS NULL THEN 'Y' ELSE 'N' END AS manager_null,
    CASE WHEN termination_date IS NULL
          AND status = 'Terminated'    THEN 'Y' ELSE 'N' END AS term_date_missing
FROM employees
WHERE salary IS NULL
   OR email IS NULL
   OR dept_id IS NULL
   OR job_title IS NULL
ORDER BY emp_id;
-- Expected: emp 10 (salary), emp 15 (salary), emp 22 (email) at minimum
-- Terminated employees without termination_date flagged separately

-- Aggregate NULL counts across the table (column-level null audit)
SELECT
    COUNT(*) - COUNT(salary)           AS salary_nulls,
    COUNT(*) - COUNT(email)            AS email_nulls,
    COUNT(*) - COUNT(dept_id)          AS dept_id_nulls,
    COUNT(*) - COUNT(manager_id)       AS manager_id_nulls,
    COUNT(*) - COUNT(termination_date) AS termination_date_nulls
FROM employees;
-- salary_nulls=2, email_nulls=1, manager_id_nulls=N (top-level mgrs), termination_date_nulls=40 (active employees)

-- Purchase orders with NULL dept_id (orphaned)
SELECT order_id, vendor, amount FROM purchase_orders WHERE dept_id IS NULL;
-- Expected: order 25

-- Performance reviews with NULL rating (incomplete reviews)
SELECT review_id, emp_id, review_date, rating
FROM performance_reviews
WHERE rating IS NULL
ORDER BY review_date;
