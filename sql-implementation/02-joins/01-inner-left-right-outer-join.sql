USE `sql-patterns`;

-- ============================================================
-- FILE: 02-joins/01-inner-left-right-outer-join.sql
-- DATABASE: sql-patterns
-- TOPIC: INNER JOIN, LEFT JOIN, RIGHT JOIN, FULL OUTER JOIN emulation,
--        multi-table JOINs, non-equality JOINs, USING clause, NULL behavior
-- KEY FLAWS / EDGE CASES IN DATA:
--   purchase_order 25  dept_id = NULL  → dropped by INNER JOIN, kept by LEFT JOIN
--   emp 10/15          salary  = NULL  → safe for JOIN; only affects salary arithmetic
--   emp 22             email   = NULL  → not a FK, does not affect JOINs
--   MySQL: no native FULL OUTER JOIN — emulate with LEFT JOIN UNION RIGHT JOIN
-- ============================================================


-- ============================================================
-- 1. INNER JOIN — EMPLOYEES WITH THEIR DEPARTMENT NAME
-- Returns only rows where emp.dept_id matches a dept_id in departments.
-- Any employee with a NULL dept_id would be excluded (none currently,
-- but the pattern is important to know).
-- Expected: 41 rows (all employees have a dept_id in this dataset).
-- ============================================================

SELECT
    e.emp_id,
    CONCAT(e.first_name, ' ', e.last_name) AS full_name,
    e.job_title,
    d.dept_name,
    d.location
FROM employees e
INNER JOIN departments d ON e.dept_id = d.dept_id
ORDER BY d.dept_name, e.last_name;


-- ============================================================
-- 2. LEFT JOIN — ALL EMPLOYEES INCLUDING THOSE WITH NO PROJECT ASSIGNMENT
-- LEFT JOIN keeps every row from the LEFT table (employees).
-- Employees with no row in project_assignments get NULLs for assignment columns.
-- Expected: every employee appears at least once;
--           employees on multiple projects appear multiple times.
-- ============================================================

SELECT
    e.emp_id,
    CONCAT(e.first_name, ' ', e.last_name) AS full_name,
    pa.project_id,
    pa.role,
    pa.start_date                           AS assignment_start
FROM employees e
LEFT JOIN project_assignments pa ON e.emp_id = pa.emp_id
ORDER BY e.emp_id;

-- Filter to only employees with NO assignment (NULLs from the RIGHT side):
SELECT
    e.emp_id,
    CONCAT(e.first_name, ' ', e.last_name) AS full_name,
    e.dept_id
FROM employees e
LEFT JOIN project_assignments pa ON e.emp_id = pa.emp_id
WHERE pa.assignment_id IS NULL   -- NULL here means no match was found
ORDER BY e.emp_id;
-- Expected: employees who are not assigned to any project.


-- ============================================================
-- 3. RIGHT JOIN — ALL PROJECTS INCLUDING THOSE WITH NO ASSIGNMENTS
-- RIGHT JOIN keeps every row from the RIGHT table (projects).
-- Projects with no rows in project_assignments get NULLs for assignment columns.
-- Expected: every project appears; projects with no staff show NULL assignment cols.
-- ============================================================

SELECT
    p.project_id,
    p.project_name,
    p.status        AS project_status,
    pa.emp_id,
    pa.role
FROM project_assignments pa
RIGHT JOIN projects p ON pa.project_id = p.project_id
ORDER BY p.project_id;

-- Projects with no assignments at all:
SELECT
    p.project_id,
    p.project_name,
    p.status
FROM project_assignments pa
RIGHT JOIN projects p ON pa.project_id = p.project_id
WHERE pa.assignment_id IS NULL;


-- ============================================================
-- 4. FULL OUTER JOIN EMULATION (MySQL has no FULL OUTER JOIN keyword)
-- Pattern: LEFT JOIN UNION RIGHT JOIN
-- Goal: departments with no employees AND employees with no department.
-- ============================================================
-- Note: In this dataset every employee has a dept_id, so the second half
-- of the UNION will not produce extra rows — but the pattern is correct.
-- ============================================================

SELECT
    d.dept_id,
    d.dept_name,
    e.emp_id,
    CONCAT(e.first_name, ' ', e.last_name) AS full_name
FROM departments d
LEFT JOIN employees e ON d.dept_id = e.dept_id

UNION

SELECT
    d.dept_id,
    d.dept_name,
    e.emp_id,
    CONCAT(e.first_name, ' ', e.last_name) AS full_name
FROM departments d
RIGHT JOIN employees e ON d.dept_id = e.dept_id

ORDER BY dept_id, emp_id;

-- Rows where dept_id IS NULL on the LEFT side → employees with no department.
-- Rows where emp_id  IS NULL on the RIGHT side → departments with no employees.


-- ============================================================
-- 5. MULTI-TABLE JOIN: EMPLOYEES + DEPARTMENTS + LATEST PERFORMANCE REVIEW
-- Three-table join: employees → departments → performance_reviews.
-- "Latest review" is found via a correlated subquery in the JOIN condition.
-- ============================================================

SELECT
    e.emp_id,
    CONCAT(e.first_name, ' ', e.last_name) AS full_name,
    d.dept_name,
    pr.review_date,
    pr.review_period,
    pr.rating
FROM employees e
INNER JOIN departments d  ON e.dept_id = d.dept_id
LEFT JOIN performance_reviews pr
    ON pr.emp_id = e.emp_id
    AND pr.review_date = (
        SELECT MAX(pr2.review_date)
        FROM performance_reviews pr2
        WHERE pr2.emp_id = e.emp_id
    )
ORDER BY d.dept_name, e.last_name;
-- Expected: employees without any review show NULL in review columns (LEFT JOIN).
-- Employees with multiple reviews on the same max date could show duplicates —
-- use ROW_NUMBER() in window function files for a cleaner solution.


-- ============================================================
-- 6. NON-EQUALITY JOIN — EMPLOYEES WHO EARN MORE THAN THEIR DIRECT MANAGER
-- Self-join with a comparison condition (>, not =).
-- Only employees who have a manager_id (not top-level CEO) can appear.
-- ============================================================

SELECT
    e.emp_id,
    CONCAT(e.first_name, ' ', e.last_name) AS employee_name,
    e.salary                                AS employee_salary,
    m.emp_id                                AS manager_id,
    CONCAT(m.first_name, ' ', m.last_name)  AS manager_name,
    m.salary                                AS manager_salary,
    e.salary - m.salary                     AS salary_diff
FROM employees e
INNER JOIN employees m ON e.manager_id = m.emp_id
WHERE e.salary  IS NOT NULL
  AND m.salary  IS NOT NULL
  AND e.salary  > m.salary
ORDER BY salary_diff DESC;
-- Expected: 0 or more rows depending on data; most reports < manager is normal.


-- ============================================================
-- 7. NULL IN JOIN KEYS — PURCHASE_ORDER 25 WITH NULL dept_id
-- INNER JOIN silently drops the row with NULL dept_id.
-- LEFT JOIN (po as left table) preserves it with NULLs for dept columns.
-- ============================================================

-- INNER JOIN drops purchase_order rows with NULL dept_id:
SELECT
    po.order_id,
    po.vendor,
    po.amount,
    po.dept_id          AS po_dept_id,
    d.dept_name
FROM purchase_orders po
INNER JOIN departments d ON po.dept_id = d.dept_id
ORDER BY po.order_id;
-- Expected: purchase_order 25 (dept_id = NULL) will NOT appear here.

-- LEFT JOIN preserves the orphaned purchase_order:
SELECT
    po.order_id,
    po.vendor,
    po.amount,
    po.dept_id          AS po_dept_id,
    d.dept_name         -- NULL for order 25
FROM purchase_orders po
LEFT JOIN departments d ON po.dept_id = d.dept_id
ORDER BY po.order_id;
-- Expected: purchase_order 25 appears with dept_name = NULL.
-- This is why LEFT JOIN is safer for auditing orphaned records.


-- ============================================================
-- 8. JOIN WITH USING CLAUSE
-- USING is shorthand when the join column has the same name in both tables.
-- Produces a single column in the output (not duplicated).
-- ============================================================

-- employees JOIN departments USING dept_id
SELECT
    emp_id,
    CONCAT(first_name, ' ', last_name) AS full_name,
    dept_id,      -- appears once (not duplicated) when USING is used
    dept_name
FROM employees
INNER JOIN departments USING (dept_id)
ORDER BY dept_id, emp_id;

-- Compare with ON — dept_id appears from both tables (same value, but listed twice):
-- SELECT e.emp_id, e.dept_id, d.dept_id, d.dept_name
-- FROM employees e INNER JOIN departments d ON e.dept_id = d.dept_id;
-- USING avoids the ambiguity and is more concise when column names match.


-- ============================================================
-- 9. MULTIPLE LEFT JOINS — EMPLOYEE + DEPARTMENT + LATEST PROJECT ASSIGNMENT
-- Shows how NULLs propagate: employees with no assignment have NULL project cols.
-- Chain of LEFT JOINs: each can independently produce NULLs.
-- ============================================================

SELECT
    e.emp_id,
    CONCAT(e.first_name, ' ', e.last_name) AS full_name,
    d.dept_name,
    pa.project_id,
    p.project_name,
    pa.role,
    pa.start_date                           AS assignment_start,
    pa.end_date                             AS assignment_end
FROM employees e
LEFT JOIN departments d          ON e.dept_id    = d.dept_id
LEFT JOIN project_assignments pa ON e.emp_id     = pa.emp_id
                                 AND pa.end_date IS NULL    -- only active assignments
LEFT JOIN projects p             ON pa.project_id = p.project_id
ORDER BY d.dept_name, e.last_name;
-- Expected: every employee appears; those without an active assignment
-- show NULL for project_id, project_name, role, assignment dates.
-- Employees on multiple active projects appear once per project.
