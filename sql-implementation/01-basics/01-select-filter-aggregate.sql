USE `sql-patterns`;

-- ============================================================
-- FILE: 01-basics/01-select-filter-aggregate.sql
-- DATABASE: sql-patterns
-- TOPIC: SELECT, Filtering, Aggregation, CASE, CTEs, String Functions
-- KEY FLAWS IN DATA:
--   emp 10  salary = NULL  (contractor — excluded from SUM/AVG unless handled)
--   emp 15  salary = NULL  (pending)
--   emp 19  salary = 0.00  (soft-dup of emp 18 — counted in AVG, distorts it)
--   emp 22  email  = NULL
--   emp 35  status = 'Terminated'
--   emp 41  hire_date = '2025-08-01' (future)
-- ORDER OF EXECUTION:
--   FROM → WHERE → GROUP BY → HAVING → SELECT → ORDER BY → LIMIT
-- ============================================================


-- ============================================================
-- 1. BASIC SELECT WITH COLUMN ALIASES
-- Aliases rename output columns; backtick or AS keyword both work.
-- ============================================================

SELECT
    emp_id,
    CONCAT(first_name, ' ', last_name) AS full_name,
    job_title,
    salary                             AS annual_salary,
    hire_date                          AS start_date
FROM employees
ORDER BY hire_date;


-- ============================================================
-- 2. WHERE CLAUSE OPERATORS
-- = != > < BETWEEN IN LIKE IS NULL IS NOT NULL
-- FLAW SURFACED: emp 10, emp 15 have NULL salary → IS NULL check returns them.
-- ============================================================

-- Exact match
SELECT emp_id, first_name, status
FROM employees
WHERE status = 'Active';

-- Not equal
SELECT emp_id, first_name, status
FROM employees
WHERE status != 'Active';

-- Numeric comparisons
SELECT emp_id, first_name, salary
FROM employees
WHERE salary > 150000;

-- BETWEEN (inclusive on both ends)
SELECT emp_id, first_name, salary
FROM employees
WHERE salary BETWEEN 80000 AND 120000;

-- IN  (dept_id 1=Engineering, 2=Sales)
SELECT emp_id, first_name, dept_id
FROM employees
WHERE dept_id IN (1, 2);

-- LIKE  (names starting with 'J')
SELECT emp_id, first_name, last_name
FROM employees
WHERE first_name LIKE 'J%';

-- LIKE  (email containing 'company')
SELECT emp_id, first_name, email
FROM employees
WHERE email LIKE '%company%';

-- IS NULL  — surfaces emp 10 and emp 15
SELECT emp_id, first_name, salary
FROM employees
WHERE salary IS NULL;

-- IS NOT NULL  — 39 rows expected (41 total − 2 NULL-salary rows)
SELECT emp_id, first_name, salary
FROM employees
WHERE salary IS NOT NULL;


-- ============================================================
-- 3. ORDER BY — SINGLE COLUMN, MULTI-COLUMN, ASC/DESC
-- ============================================================

-- Single column DESC
SELECT emp_id, first_name, salary
FROM employees
ORDER BY salary DESC;

-- Multi-column: dept_id ASC, salary DESC within dept
SELECT emp_id, first_name, dept_id, salary
FROM employees
ORDER BY dept_id ASC, salary DESC;

-- ORDER BY column position (positional reference — valid SQL, but avoid in production)
SELECT emp_id, first_name, hire_date
FROM employees
ORDER BY 3 DESC;  -- 3 = hire_date


-- ============================================================
-- 4. LIMIT / OFFSET (PAGINATION)
-- Page size 5, page 1 = OFFSET 0, page 2 = OFFSET 5, etc.
-- ============================================================

-- Page 1: top 5 earners
SELECT emp_id, first_name, salary
FROM employees
WHERE salary IS NOT NULL
ORDER BY salary DESC
LIMIT 5 OFFSET 0;

-- Page 2: next 5
SELECT emp_id, first_name, salary
FROM employees
WHERE salary IS NOT NULL
ORDER BY salary DESC
LIMIT 5 OFFSET 5;


-- ============================================================
-- 5. GROUP BY + HAVING
-- HAVING filters AFTER aggregation; WHERE filters BEFORE.
-- ============================================================

-- Count employees per department
SELECT dept_id, COUNT(*) AS headcount
FROM employees
GROUP BY dept_id
ORDER BY headcount DESC;

-- Departments with more than 5 employees
SELECT dept_id, COUNT(*) AS headcount
FROM employees
GROUP BY dept_id
HAVING COUNT(*) > 5
ORDER BY headcount DESC;

-- Average salary per department; only show depts where avg > 100k
-- NOTE: AVG ignores NULLs but emp 19 salary=0.00 is included and drags the average down.
SELECT
    dept_id,
    COUNT(*)                   AS headcount,
    ROUND(AVG(salary), 2)     AS avg_salary
FROM employees
WHERE salary IS NOT NULL
GROUP BY dept_id
HAVING AVG(salary) > 100000
ORDER BY avg_salary DESC;


-- ============================================================
-- 6. AGGREGATE FUNCTIONS
-- COUNT(*) counts rows including NULLs.
-- COUNT(col) counts non-NULL values only.
-- SUM / AVG skip NULLs automatically.
-- FLAW: emp 10 and emp 15 salary = NULL → excluded from SUM/AVG.
--        emp 19 salary = 0.00 → INCLUDED in AVG, lowers it.
-- ============================================================

SELECT
    COUNT(*)                            AS total_rows,            -- 41
    COUNT(salary)                       AS rows_with_salary,      -- 39 (skips NULLs)
    COUNT(email)                        AS rows_with_email,       -- 40 (emp 22 is NULL)
    SUM(salary)                         AS total_salary,          -- NULLs excluded
    ROUND(AVG(salary), 2)               AS avg_salary,            -- NULLs excluded; 0.00 included
    MIN(salary)                         AS min_salary,
    MAX(salary)                         AS max_salary
FROM employees;

-- COUNT(*) vs COUNT(col) difference — shows how many NULLs exist
SELECT
    COUNT(*)       - COUNT(salary) AS null_salary_count,   -- 2
    COUNT(*)       - COUNT(email)  AS null_email_count     -- 1
FROM employees;


-- ============================================================
-- 7. CASE WHEN IN SELECT — SALARY BANDS
-- Bands: <80k=Junior, 80k-120k=Mid, 120k-160k=Senior, >160k=Lead
-- NULLs fall into the ELSE bucket here (labeled 'Unknown').
-- ============================================================

SELECT
    emp_id,
    CONCAT(first_name, ' ', last_name) AS full_name,
    salary,
    CASE
        WHEN salary IS NULL       THEN 'Unknown'
        WHEN salary < 80000       THEN 'Junior'
        WHEN salary < 120000      THEN 'Mid'
        WHEN salary < 160000      THEN 'Senior'
        ELSE                           'Lead'
    END AS salary_band
FROM employees
ORDER BY salary DESC;


-- ============================================================
-- 8. CASE WHEN INSIDE AGGREGATE — CONDITIONAL AGGREGATION
-- Count active vs terminated per department in a single pass.
-- ============================================================

SELECT
    d.dept_name,
    COUNT(*)                                              AS total_employees,
    COUNT(CASE WHEN e.status = 'Active'     THEN 1 END)  AS active_count,
    COUNT(CASE WHEN e.status = 'Terminated' THEN 1 END)  AS terminated_count,
    COUNT(CASE WHEN e.status = 'On Leave'   THEN 1 END)  AS on_leave_count
FROM employees e
JOIN departments d ON e.dept_id = d.dept_id
GROUP BY d.dept_id, d.dept_name
ORDER BY total_employees DESC;


-- ============================================================
-- 9. SUBQUERY IN WHERE
-- Employees earning above the company average salary.
-- NOTE: AVG in subquery excludes NULLs (emp 10, 15) and includes 0 (emp 19).
-- ============================================================

SELECT
    emp_id,
    CONCAT(first_name, ' ', last_name) AS full_name,
    salary
FROM employees
WHERE salary > (
    SELECT AVG(salary)
    FROM employees
    WHERE salary IS NOT NULL
)
ORDER BY salary DESC;


-- ============================================================
-- 10. CTE FOR READABILITY — SAME QUERY AS ABOVE REWRITTEN
-- CTE makes the average visible as a named step.
-- ============================================================

WITH avg_salary AS (
    SELECT AVG(salary) AS company_avg
    FROM employees
    WHERE salary IS NOT NULL
)
SELECT
    e.emp_id,
    CONCAT(e.first_name, ' ', e.last_name) AS full_name,
    e.salary,
    ROUND(a.company_avg, 2)                AS company_avg
FROM employees e
CROSS JOIN avg_salary a
WHERE e.salary > a.company_avg
ORDER BY e.salary DESC;


-- ============================================================
-- 11. COALESCE TO HANDLE NULL SALARY
-- COALESCE(salary, 0) substitutes 0 for NULL in expressions.
-- WARNING: replacing NULL with 0 lowers AVG — use carefully.
-- Here we use it to produce a safe display column, not in AVG.
-- ============================================================

-- Show salary with a fallback display value
SELECT
    emp_id,
    CONCAT(first_name, ' ', last_name) AS full_name,
    salary,
    COALESCE(salary, 0)                AS salary_or_zero,
    COALESCE(CAST(salary AS CHAR), 'Not Set') AS salary_display
FROM employees
ORDER BY emp_id;

-- Correct average excluding NULLs (default AVG behavior):
SELECT ROUND(AVG(salary), 2) AS avg_excluding_nulls FROM employees;

-- Incorrect average that treats NULL as 0 (using COALESCE):
SELECT ROUND(AVG(COALESCE(salary, 0)), 2) AS avg_treating_null_as_zero FROM employees;
-- Expected: second value is lower because 2 extra zeros are added to the average.


-- ============================================================
-- 12. STRING FUNCTIONS
-- CONCAT, UPPER, LOWER, LENGTH, TRIM, SUBSTRING
-- ============================================================

SELECT
    emp_id,
    CONCAT(first_name, ' ', last_name)          AS full_name,
    UPPER(last_name)                             AS last_name_upper,
    LOWER(first_name)                            AS first_name_lower,
    LENGTH(CONCAT(first_name, ' ', last_name))   AS full_name_length,
    TRIM('  extra spaces  ')                     AS trimmed_demo,       -- static demo
    SUBSTRING(hire_date, 1, 4)                   AS hire_year,          -- first 4 chars of date
    SUBSTRING(email, 1, LOCATE('@', email) - 1)  AS email_username      -- part before @
FROM employees
WHERE email IS NOT NULL   -- emp 22 has NULL email; LOCATE would return 0 → error
ORDER BY emp_id;

-- Email domain extraction
SELECT
    emp_id,
    email,
    SUBSTRING(email, LOCATE('@', email) + 1) AS email_domain
FROM employees
WHERE email IS NOT NULL;


-- ============================================================
-- 13. CONDITIONAL AGGREGATION — PER-DEPARTMENT ACTIVE VS TERMINATED
-- One scan of the table produces both counts.
-- This is the pattern preferred over two separate filtered queries.
-- ============================================================

SELECT
    d.dept_id,
    d.dept_name,
    COUNT(e.emp_id)                                             AS total,
    SUM(CASE WHEN e.status = 'Active'     THEN 1 ELSE 0 END)   AS active,
    SUM(CASE WHEN e.status = 'Terminated' THEN 1 ELSE 0 END)   AS terminated,
    SUM(CASE WHEN e.status = 'On Leave'   THEN 1 ELSE 0 END)   AS on_leave,
    ROUND(
        100.0 * SUM(CASE WHEN e.status = 'Active' THEN 1 ELSE 0 END)
        / NULLIF(COUNT(e.emp_id), 0)
    , 1)                                                        AS active_pct
FROM departments d
LEFT JOIN employees e ON d.dept_id = e.dept_id
GROUP BY d.dept_id, d.dept_name
ORDER BY d.dept_id;


-- ============================================================
-- 14. ORDER OF EXECUTION (reference block — not a query)
-- SQL logical processing order:
--   1. FROM        — identify tables, evaluate JOINs
--   2. WHERE       — filter individual rows
--   3. GROUP BY    — group remaining rows
--   4. HAVING      — filter groups
--   5. SELECT      — compute output columns (aliases defined here,
--                    not available in WHERE or HAVING in standard SQL;
--                    MySQL allows HAVING to reference SELECT aliases)
--   6. DISTINCT    — deduplicate if requested
--   7. ORDER BY    — sort final result set
--   8. LIMIT/OFFSET— page/trim the sorted result
--
-- Common mistake: using a SELECT alias in WHERE → fails in standard SQL
-- because WHERE runs before SELECT.
--
-- This is WHY you cannot do:
--   SELECT salary * 1.1 AS new_salary FROM employees WHERE new_salary > 100000;
-- You must repeat the expression:
--   SELECT salary * 1.1 AS new_salary FROM employees WHERE salary * 1.1 > 100000;
-- OR use a subquery / CTE.
-- ============================================================

-- Demonstration of the execution order pitfall — correct form:
SELECT
    emp_id,
    ROUND(salary * 1.1, 2) AS new_salary
FROM employees
WHERE salary * 1.1 > 100000   -- cannot use alias 'new_salary' here
  AND salary IS NOT NULL
ORDER BY new_salary DESC;
