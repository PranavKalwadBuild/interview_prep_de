USE `sql-patterns`;

-- ============================================================
-- FILE: 02-joins/02-self-join-cross-join.sql
-- DATABASE: sql-patterns
-- TOPIC: Self-join, Cross Join, Recursive CTE (org chart)
-- KEY DATA FACTS:
--   41 employees; emp 1 (CEO James Wilson) has manager_id = NULL (root)
--   emp 2 (CTO Sarah Chen)    manager_id = 1
--   emp 3 (VP Sales Carol)    manager_id = 1
--   emp 4 (VP Finance David)  manager_id = 1
--   8 departments, ratings 1-5 in performance_reviews
--   emp 10 salary = NULL (contractor); emp 15 salary = NULL
-- ============================================================


-- ============================================================
-- 1. SELF-JOIN — EMPLOYEE WITH THEIR MANAGER'S NAME
-- The employees table is joined to itself:
--   e = the employee row
--   m = the manager row (looked up via e.manager_id = m.emp_id)
-- CEO (emp 1) has manager_id = NULL → excluded from INNER JOIN.
-- Use LEFT JOIN to keep the CEO in the result with NULL manager columns.
-- Expected: 41 rows with LEFT JOIN; 40 rows with INNER JOIN (CEO dropped).
-- ============================================================

-- LEFT JOIN version — includes CEO (manager columns will be NULL)
SELECT
    e.emp_id                                AS emp_id,
    CONCAT(e.first_name, ' ', e.last_name)  AS employee_name,
    e.job_title,
    e.manager_id,
    CONCAT(m.first_name, ' ', m.last_name)  AS manager_name,
    m.job_title                             AS manager_title
FROM employees e
LEFT JOIN employees m ON e.manager_id = m.emp_id
ORDER BY e.manager_id, e.emp_id;
-- Expected: 41 rows; emp 1 (CEO) shows NULL for manager_name/manager_title.

-- INNER JOIN version — excludes root node (CEO)
SELECT
    e.emp_id,
    CONCAT(e.first_name, ' ', e.last_name)  AS employee_name,
    CONCAT(m.first_name, ' ', m.last_name)  AS manager_name
FROM employees e
INNER JOIN employees m ON e.manager_id = m.emp_id
ORDER BY m.emp_id, e.emp_id;
-- Expected: 40 rows (all employees except CEO who has no manager).


-- ============================================================
-- 2. SELF-JOIN — EMPLOYEES WHO EARN MORE THAN THEIR DIRECT MANAGER
-- Requires both salaries to be non-NULL.
-- emp 10 and emp 15 have NULL salary → excluded by IS NOT NULL filter.
-- ============================================================

SELECT
    e.emp_id,
    CONCAT(e.first_name, ' ', e.last_name)  AS employee_name,
    e.salary                                AS employee_salary,
    CONCAT(m.first_name, ' ', m.last_name)  AS manager_name,
    m.salary                                AS manager_salary,
    ROUND(e.salary - m.salary, 2)           AS excess_over_manager
FROM employees e
INNER JOIN employees m ON e.manager_id = m.emp_id
WHERE e.salary IS NOT NULL
  AND m.salary IS NOT NULL
  AND e.salary > m.salary
ORDER BY excess_over_manager DESC;
-- Expected: 0 or more rows; in normal org data most subordinates earn less.
-- If rows appear, it indicates either compression at the top or data issues.


-- ============================================================
-- 3. SELF-JOIN — PEER PAIRS IN THE SAME DEPARTMENT
-- e1.emp_id < e2.emp_id avoids duplicates (A-B and B-A would both appear otherwise).
-- Expected: C(n,2) = n*(n-1)/2 pairs per department where n = dept headcount.
-- Engineering (n=14) → 91 pairs; Sales (n=8) → 28 pairs; etc.
-- Total across all departments: sum of C(n,2) per dept.
-- ============================================================

SELECT
    d.dept_name,
    e1.emp_id                                AS emp1_id,
    CONCAT(e1.first_name, ' ', e1.last_name) AS emp1_name,
    e2.emp_id                                AS emp2_id,
    CONCAT(e2.first_name, ' ', e2.last_name) AS emp2_name
FROM employees e1
INNER JOIN employees e2
    ON  e1.dept_id = e2.dept_id
    AND e1.emp_id  < e2.emp_id   -- avoids reverse duplicates and self-pairs
INNER JOIN departments d ON e1.dept_id = d.dept_id
ORDER BY d.dept_name, e1.emp_id, e2.emp_id;

-- Count of pairs per department:
SELECT
    d.dept_name,
    COUNT(*) AS peer_pairs
FROM employees e1
INNER JOIN employees e2
    ON  e1.dept_id = e2.dept_id
    AND e1.emp_id  < e2.emp_id
INNER JOIN departments d ON e1.dept_id = d.dept_id
GROUP BY d.dept_name
ORDER BY peer_pairs DESC;


-- ============================================================
-- 4. THREE-LEVEL HIERARCHY VIA TWO SELF-JOINS
-- e  = the employee
-- m  = direct manager (level 1 up)
-- gm = skip-level / grandparent manager (level 2 up)
-- Expected: employees who have both a manager AND a skip-level manager.
-- The CEO's direct reports (depth=1) have a manager but no grandparent →
-- they are excluded from INNER JOIN on gm; use LEFT JOIN to keep them.
-- ============================================================

SELECT
    e.emp_id,
    CONCAT(e.first_name,  ' ', e.last_name)  AS employee,
    e.job_title                               AS emp_title,
    CONCAT(m.first_name,  ' ', m.last_name)  AS manager,
    m.job_title                               AS mgr_title,
    CONCAT(gm.first_name, ' ', gm.last_name) AS skip_level_manager,
    gm.job_title                              AS skip_mgr_title
FROM employees e
INNER JOIN employees m  ON e.manager_id  = m.emp_id     -- must have a manager
LEFT JOIN  employees gm ON m.manager_id  = gm.emp_id    -- may or may not have a skip-level
ORDER BY gm.emp_id NULLS LAST, m.emp_id, e.emp_id;
-- Expected: ~38 rows with LEFT JOIN (CEO + CEO's direct reports have partial NULLs).
-- Rows where skip_level_manager IS NULL = depth-1 employees (CEO's direct reports).


-- ============================================================
-- 5. CROSS JOIN — ALL (DEPARTMENT, RATING) COMBINATIONS
-- CROSS JOIN produces the Cartesian product: every row from left × every row from right.
-- Use case: generate a completeness scaffold to detect which (dept, rating) pairs
-- have ZERO performance reviews — a gap analysis pattern.
-- Expected row count from CROSS JOIN alone: 8 depts × 5 ratings = 40 rows.
-- ============================================================

-- Step 1: generate the scaffold
WITH rating_values AS (
    SELECT 1 AS rating UNION ALL
    SELECT 2 UNION ALL
    SELECT 3 UNION ALL
    SELECT 4 UNION ALL
    SELECT 5
)
SELECT
    d.dept_id,
    d.dept_name,
    rv.rating                               AS possible_rating,
    COUNT(pr.review_id)                     AS review_count
FROM departments d
CROSS JOIN rating_values rv
LEFT JOIN employees e        ON e.dept_id    = d.dept_id
LEFT JOIN performance_reviews pr ON pr.emp_id = e.emp_id
                              AND pr.rating   = rv.rating
GROUP BY d.dept_id, d.dept_name, rv.rating
ORDER BY d.dept_id, rv.rating;
-- Expected: 40 rows (8 × 5); rows with review_count = 0 are the gaps.


-- ============================================================
-- 6. CROSS JOIN WITH WHERE — EQUIVALENT TO AN INNER JOIN (ANTI-PATTERN)
-- A CROSS JOIN + WHERE on equality is functionally the same as INNER JOIN
-- but is much harder to read and often slower (optimizer may not rewrite it).
-- Shown here to illustrate WHY the explicit JOIN syntax is preferred.
-- ============================================================

-- Anti-pattern (avoid in production):
SELECT
    e.emp_id,
    CONCAT(e.first_name, ' ', e.last_name) AS full_name,
    d.dept_name
FROM employees e
CROSS JOIN departments d
WHERE e.dept_id = d.dept_id   -- this WHERE filter IS the join condition
ORDER BY e.emp_id;
-- Expected: same 41 rows as INNER JOIN employees e ON e.dept_id = d.dept_id.

-- Preferred equivalent (explicit INNER JOIN):
SELECT
    e.emp_id,
    CONCAT(e.first_name, ' ', e.last_name) AS full_name,
    d.dept_name
FROM employees e
INNER JOIN departments d ON e.dept_id = d.dept_id
ORDER BY e.emp_id;
-- Intent is explicit, optimizer hint is clearer, and accidental Cartesian products
-- are impossible if the ON clause is accidentally omitted (it's a syntax error).


-- ============================================================
-- 7. RECURSIVE CTE — FULL ORG CHART
-- WITH RECURSIVE builds the tree top-down from the CEO (manager_id IS NULL).
-- Each iteration adds one level of depth until no more children are found.
-- Columns: emp_id, full_name, manager_id, depth (0=CEO), path (breadcrumb).
-- MySQL requires explicit RECURSIVE keyword in the WITH clause.
-- Expected: 41 rows total (full org from depth 0 to max depth in data).
-- ============================================================

WITH RECURSIVE org_chart AS (

    -- Anchor: start at the root (CEO — no manager)
    SELECT
        e.emp_id,
        CONCAT(e.first_name, ' ', e.last_name) AS full_name,
        e.manager_id,
        e.job_title,
        e.dept_id,
        0                                       AS depth,
        CAST(CONCAT(e.first_name, ' ', e.last_name) AS CHAR(1000)) AS path
    FROM employees e
    WHERE e.manager_id IS NULL   -- CEO (emp 1 James Wilson)

    UNION ALL

    -- Recursive step: join each employee to their parent already in the CTE
    SELECT
        e.emp_id,
        CONCAT(e.first_name, ' ', e.last_name) AS full_name,
        e.manager_id,
        e.job_title,
        e.dept_id,
        oc.depth + 1                            AS depth,
        CAST(CONCAT(oc.path, ' > ', e.first_name, ' ', e.last_name) AS CHAR(1000)) AS path
    FROM employees e
    INNER JOIN org_chart oc ON e.manager_id = oc.emp_id

)
SELECT
    emp_id,
    REPEAT('  ', depth)                 AS indent,   -- visual indentation
    full_name,
    job_title,
    manager_id,
    depth,
    path
FROM org_chart
ORDER BY path;
-- Expected: 41 rows; depth 0 = CEO, depth 1 = C-suite, depth 2 = directors, etc.
-- The path column shows the full ancestry chain for each employee.
-- REPEAT('  ', depth) creates visual indentation proportional to depth.

-- Count employees at each level:
WITH RECURSIVE org_chart AS (
    SELECT emp_id, manager_id, 0 AS depth
    FROM employees
    WHERE manager_id IS NULL
    UNION ALL
    SELECT e.emp_id, e.manager_id, oc.depth + 1
    FROM employees e
    INNER JOIN org_chart oc ON e.manager_id = oc.emp_id
)
SELECT depth, COUNT(*) AS headcount
FROM org_chart
GROUP BY depth
ORDER BY depth;
-- Expected example output (depends on data):
--   depth 0 → 1   (CEO)
--   depth 1 → 3   (CTO, VP Sales, VP Finance, etc.)
--   depth 2 → ~10 (directors / senior managers)
--   depth 3 → ~27 (individual contributors)
