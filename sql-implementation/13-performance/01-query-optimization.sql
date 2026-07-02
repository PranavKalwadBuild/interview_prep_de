-- =============================================================================
-- FILE: 01-query-optimization.sql
-- DATABASE: sql-patterns
-- PURPOSE: MySQL 8.0+ query optimization patterns — EXPLAIN, index usage,
--          join order, subquery vs JOIN, covering indexes, aggregate tuning,
--          window function efficiency, CTE vs temp table, anti-join patterns,
--          and the N+1 anti-pattern.
-- FORMAT: Each section has BAD vs GOOD examples where applicable, with
--         performance notes in comments.
-- =============================================================================

USE `sql-patterns`;

-- =============================================================================
-- SECTION 1: USING EXPLAIN AND EXPLAIN ANALYZE
-- =============================================================================

-- 1a. EXPLAIN on a simple SELECT — no index on status
EXPLAIN
SELECT emp_id, first_name, last_name, salary
FROM employees
WHERE status = 'Active';
-- Look for:
--   type=ALL   → full table scan (bad for large tables)
--   type=ref   → index lookup (good)
--   rows       → optimizer's estimated row count
--   Extra      → "Using where" = filter applied post-fetch
--                "Using index" = covering index (no row fetch needed)
--                "Using filesort" = sort not served by index

-- 1b. EXPLAIN on a JOIN — employees + departments
EXPLAIN
SELECT e.emp_id, e.first_name, e.last_name, d.dept_name
FROM employees e
JOIN departments d ON e.dept_id = d.dept_id
WHERE d.location = 'New York';
-- Look for:
--   driving table  = the table MySQL reads first (usually the one with the filter)
--   join type      = type column; ref/eq_ref = index join; ALL = nested-loop full scan
--   key            = which index MySQL chose
--   rows × rows    = estimated total work

-- 1c. EXPLAIN ANALYZE — shows actual row counts and timing (MySQL 8.0.18+)
--     Runs the query for real; use only in dev/non-prod.
EXPLAIN ANALYZE
SELECT e.emp_id, e.salary, d.dept_name
FROM employees e
JOIN departments d ON e.dept_id = d.dept_id
WHERE e.salary > 100000;
-- Output adds "actual time=X..Y rows=Z loops=N" to each node.
-- Compare "rows=estimated" vs "rows=actual" to spot bad cardinality estimates.


-- =============================================================================
-- SECTION 2: INDEX IMPACT ON WHERE CLAUSES
-- =============================================================================

-- Pattern A: function-wrapped column → index unusable (MySQL cannot use a B-tree
-- index when the column is wrapped in a function — the optimizer sees every row).

-- BAD: wrapping hire_date in YEAR() forces a full table scan
EXPLAIN
SELECT emp_id, hire_date FROM employees
WHERE YEAR(hire_date) = 2023;
-- type=ALL; cannot use index on hire_date

-- GOOD: range predicate on the raw column → index range scan
EXPLAIN
SELECT emp_id, hire_date FROM employees
WHERE hire_date BETWEEN '2023-01-01' AND '2023-12-31';
-- type=range; uses index on hire_date

-- Performance note: always rewrite date/function predicates to a range on the bare column.

-- -----------------------------------------------------------------------

-- Pattern B: leading wildcard in LIKE → B-tree index unusable

-- BAD: leading % means "match anywhere" — MySQL cannot use index prefix
EXPLAIN
SELECT emp_id, last_name FROM employees
WHERE last_name LIKE '%son';
-- type=ALL

-- GOOD: prefix search allows index scan from left edge
EXPLAIN
SELECT emp_id, last_name FROM employees
WHERE last_name LIKE 'Wil%';
-- type=range; uses index on last_name

-- Performance note: if you must search by suffix, consider a FULLTEXT index
-- or a reversed-string virtual column + index.

-- -----------------------------------------------------------------------

-- Pattern C: OR across different columns → neither index is fully used;
-- use UNION ALL to allow each branch to use its own index independently.

-- BAD: OR across dept_id and status; optimizer may fall back to full scan
SELECT emp_id, dept_id, status
FROM employees
WHERE dept_id = 3 OR status = 'Active';

-- GOOD: each branch uses its own index; UNION removes duplicates
SELECT emp_id, dept_id, status FROM employees WHERE dept_id = 3
UNION
SELECT emp_id, dept_id, status FROM employees WHERE status = 'Active';
-- Performance note: UNION ALL (no dedup) is faster when you know rows don't overlap.


-- =============================================================================
-- SECTION 3: JOIN ORDER AND DRIVING TABLE
-- =============================================================================

-- MySQL's optimizer automatically determines join order using cost estimates.
-- Rule of thumb: smaller table as the driving (outer) table reduces iterations.
-- departments = 8 rows; employees = 41 rows.
-- Optimal: drive with departments (8) and probe employees (41) per row.

-- Default join — optimizer usually picks the right order
EXPLAIN
SELECT e.emp_id, e.last_name, d.dept_name
FROM employees e
JOIN departments d ON e.dept_id = d.dept_id;

-- STRAIGHT_JOIN: forces MySQL to use the written join order (left = driving table).
-- Use only when EXPLAIN shows the optimizer chose wrong and it cannot be fixed
-- by adding an index or updating statistics (ANALYZE TABLE).
EXPLAIN
SELECT STRAIGHT_JOIN e.emp_id, e.last_name, d.dept_name
FROM departments d                     -- forcing departments as driver (8 rows)
JOIN employees e ON d.dept_id = e.dept_id;
-- Performance note: STRAIGHT_JOIN is a last resort. Prefer: add missing indexes,
-- run ANALYZE TABLE to refresh statistics, or restructure the query.


-- =============================================================================
-- SECTION 4: CORRELATED SUBQUERY VS JOIN (PERFORMANCE)
-- =============================================================================

-- Goal: find employees who earn the maximum salary in their department.

-- BAD: correlated subquery — re-executed once per outer row = O(n) executions
-- For 41 employees across 8 departments, the inner SELECT runs 41 times.
EXPLAIN
SELECT emp_id, first_name, last_name, dept_id, salary
FROM employees e
WHERE salary = (
    SELECT MAX(salary)
    FROM employees e2
    WHERE e2.dept_id = e.dept_id          -- correlated: depends on outer e.dept_id
);
-- Extra: "Dependent subquery" in EXPLAIN = correlated = re-runs per outer row.

-- GOOD: derived table / pre-aggregated JOIN — the subquery runs exactly once
EXPLAIN
SELECT e.emp_id, e.first_name, e.last_name, e.dept_id, e.salary
FROM employees e
JOIN (
    SELECT dept_id, MAX(salary) AS max_sal
    FROM employees
    GROUP BY dept_id
) dept_max ON e.dept_id = dept_max.dept_id
         AND e.salary   = dept_max.max_sal;
-- Inner SELECT executes once; result joined back. Scales to millions of rows.
-- Performance note: MySQL sometimes auto-transforms correlated subqueries into
-- joins internally (semi-join optimization), but it is not guaranteed.


-- =============================================================================
-- SECTION 5: AVOIDING SELECT *
-- =============================================================================

-- BAD: SELECT * fetches every column → cannot use a covering index; forces
-- the engine to read the full row even if only 2 columns are needed.
SELECT * FROM employees WHERE dept_id = 1;
-- With only an index on dept_id, MySQL must do a "back-to-table" lookup for
-- each matching emp_id to read the full row. Extra column: "Using index condition".

-- GOOD: list only the columns actually needed
SELECT emp_id, last_name, salary
FROM employees
WHERE dept_id = 1;
-- With a composite index on (dept_id, salary) that also covers emp_id and last_name,
-- this can be satisfied with an index-only scan: Extra = "Using index".
-- Performance note: covering indexes are most impactful on queries that return
-- many rows but only a few columns.

-- Example covering index DDL (add if missing):
-- CREATE INDEX idx_emp_dept_salary ON employees (dept_id, salary, emp_id, last_name);


-- =============================================================================
-- SECTION 6: AGGREGATE PERFORMANCE
-- =============================================================================

-- 6a. COUNT(*) vs COUNT(1) vs COUNT(col)
-- COUNT(*) and COUNT(1) are identical in MySQL — both count every row including NULLs.
-- COUNT(col) skips NULLs — useful for measuring completeness.
SELECT
    COUNT(*)        AS total_rows,          -- counts every row
    COUNT(1)        AS total_rows_alt,      -- same as COUNT(*)
    COUNT(salary)   AS rows_with_salary,    -- skips NULL salary (emps 10, 15)
    COUNT(email)    AS rows_with_email      -- skips NULL email  (emp 22)
FROM employees;
-- Performance: all three use the same execution path; no meaningful difference.

-- 6b. GROUP BY cardinality: low-cardinality columns are efficient
-- status has ~3 values → small GROUP BY hash table
SELECT status, COUNT(*) FROM employees GROUP BY status;

-- emp_id has 41 distinct values → larger GROUP BY (trivial here, matters at scale)
SELECT emp_id, COUNT(*) FROM salary_history GROUP BY emp_id ORDER BY COUNT(*) DESC;

-- 6c. HAVING vs WHERE — HAVING is applied AFTER aggregation (not a pre-filter)
-- BAD: filtering on a non-aggregate column in HAVING reads all groups first
SELECT dept_id, COUNT(*) AS cnt
FROM employees
HAVING dept_id = 3;           -- reads all depts, then discards non-matching groups
-- type=ALL; no WHERE clause for the optimizer to exploit

-- GOOD: move non-aggregate filters to WHERE → rows eliminated before grouping
SELECT dept_id, COUNT(*) AS cnt
FROM employees
WHERE dept_id = 3             -- optimizer can use index on dept_id
GROUP BY dept_id;

-- HAVING is correct only when filtering on an aggregate result:
SELECT dept_id, COUNT(*) AS cnt
FROM employees
GROUP BY dept_id
HAVING COUNT(*) > 5;          -- correct use of HAVING: filter on aggregate


-- =============================================================================
-- SECTION 7: WINDOW FUNCTION OPTIMIZATION
-- =============================================================================

-- Each unique (PARTITION BY + ORDER BY) combination in a window function
-- requires a separate sort pass. Combining same-partition functions into a
-- single SELECT reuses the sort.

-- BAD: two separate window specs → two sort passes over the employees table
SELECT
    emp_id,
    salary,
    RANK() OVER (PARTITION BY dept_id ORDER BY salary DESC) AS dept_rank
FROM employees;

-- (Separate query)
SELECT
    emp_id,
    salary,
    AVG(salary) OVER (PARTITION BY dept_id)                 AS dept_avg_salary
FROM employees;

-- GOOD: same PARTITION BY → share the sort pass in one SELECT
SELECT
    emp_id,
    first_name,
    last_name,
    dept_id,
    salary,
    RANK()       OVER (PARTITION BY dept_id ORDER BY salary DESC) AS dept_rank,
    AVG(salary)  OVER (PARTITION BY dept_id)                      AS dept_avg_salary,
    MAX(salary)  OVER (PARTITION BY dept_id)                      AS dept_max_salary,
    salary - AVG(salary) OVER (PARTITION BY dept_id)              AS delta_from_avg
FROM employees
WHERE salary IS NOT NULL
ORDER BY dept_id, dept_rank;
-- Performance note: MySQL 8 can reuse a single sort for multiple window functions
-- sharing identical (PARTITION BY + ORDER BY). Different ORDER BYs still require
-- separate sorts even within the same PARTITION BY.


-- =============================================================================
-- SECTION 8: CTE VS SUBQUERY VS TEMPORARY TABLE
-- =============================================================================

-- CTE (WITH clause): syntactic sugar in MySQL — NOT guaranteed to materialize.
-- MySQL may inline it as a subquery. If a CTE is referenced twice, MySQL may
-- re-execute it twice (unlike SQL Server / PostgreSQL which materialize by default).

-- Subquery (inline): also not materialized; if correlated, re-executes per outer row.

-- Temporary table: always materialized to disk/memory; use when the dataset is
-- large, expensive to compute, and read more than once.

-- 8a. CTE referenced once — fine as a CTE
WITH dept_headcount AS (
    SELECT dept_id, COUNT(*) AS cnt
    FROM employees
    GROUP BY dept_id
)
SELECT d.dept_name, dh.cnt
FROM departments d
JOIN dept_headcount dh ON d.dept_id = dh.dept_id
ORDER BY dh.cnt DESC;

-- 8b. CTE referenced twice — MySQL may re-execute it; materialize instead
-- Pattern that can cause double execution:
WITH salary_stats AS (
    SELECT dept_id, AVG(salary) AS avg_sal, STDDEV_POP(salary) AS std_sal
    FROM employees WHERE salary IS NOT NULL
    GROUP BY dept_id
)
SELECT
    e.emp_id, e.salary,
    ss.avg_sal,
    (e.salary - ss.avg_sal) / NULLIF(ss.std_sal, 0) AS z_score
FROM employees e
JOIN salary_stats ss ON e.dept_id = ss.dept_id     -- 1st reference
WHERE e.salary > ss.avg_sal                         -- 2nd reference (same CTE)
  AND e.salary IS NOT NULL;
-- If MySQL re-executes salary_stats for the WHERE clause join, it runs twice.

-- GOOD: materialize to a temp table for guaranteed single execution
CREATE TEMPORARY TABLE tmp_salary_stats AS
    SELECT dept_id, AVG(salary) AS avg_sal, STDDEV_POP(salary) AS std_sal
    FROM employees WHERE salary IS NOT NULL
    GROUP BY dept_id;

SELECT
    e.emp_id, e.salary,
    ts.avg_sal,
    (e.salary - ts.avg_sal) / NULLIF(ts.std_sal, 0) AS z_score
FROM employees e
JOIN tmp_salary_stats ts ON e.dept_id = ts.dept_id
WHERE e.salary > ts.avg_sal
  AND e.salary IS NOT NULL;

DROP TEMPORARY TABLE IF EXISTS tmp_salary_stats;
-- Performance note: temp tables are most valuable for complex intermediate results
-- that are joined or filtered multiple times in the same session.


-- =============================================================================
-- SECTION 9: NOT IN vs NOT EXISTS vs LEFT JOIN ANTI-JOIN
-- =============================================================================

-- Goal: find departments that have no employees.

-- BAD: NOT IN is dangerous — if the subquery returns even one NULL, the entire
-- NOT IN evaluates to UNKNOWN and returns 0 rows (silent data loss).
SELECT dept_id, dept_name
FROM departments
WHERE dept_id NOT IN (
    SELECT dept_id FROM employees   -- if any employee.dept_id is NULL, result = empty
);
-- Note: employees.dept_id has a NOT NULL constraint here, so it works — but the
-- pattern is fragile. Any schema change allowing NULLs will silently break it.

-- GOOD: NOT EXISTS is NULL-safe and typically optimized to an anti-semi-join
SELECT d.dept_id, d.dept_name
FROM departments d
WHERE NOT EXISTS (
    SELECT 1 FROM employees e WHERE e.dept_id = d.dept_id
);
-- Performance: MySQL rewrites NOT EXISTS to an anti-join internally.
-- EXPLAIN will show "Antijoin" in the table row.

-- GOOD: LEFT JOIN anti-join — explicit, predictable, and readable
SELECT d.dept_id, d.dept_name
FROM departments d
LEFT JOIN employees e ON d.dept_id = e.dept_id
WHERE e.emp_id IS NULL;       -- no matching employee row → the department is empty
-- Performance note: equivalent plan to NOT EXISTS in modern MySQL (8.0+).
-- Prefer NOT EXISTS or LEFT JOIN IS NULL over NOT IN whenever NULLs are possible.

-- -----------------------------------------------------------------------
-- Second example: employees without any performance review
-- BAD
SELECT emp_id FROM employees
WHERE emp_id NOT IN (SELECT emp_id FROM performance_reviews);

-- GOOD (NOT EXISTS)
SELECT e.emp_id, e.first_name, e.last_name
FROM employees e
WHERE NOT EXISTS (
    SELECT 1 FROM performance_reviews pr WHERE pr.emp_id = e.emp_id
);

-- GOOD (LEFT JOIN anti-join)
SELECT e.emp_id, e.first_name, e.last_name
FROM employees e
LEFT JOIN performance_reviews pr ON e.emp_id = pr.emp_id
WHERE pr.review_id IS NULL;


-- =============================================================================
-- SECTION 10: N+1 QUERY ANTI-PATTERN
-- =============================================================================

-- Goal: for each department, find the highest-paid employee.

-- BAD (N+1 pattern): conceptually equivalent to running one query per department
-- in application code — or using a correlated subquery that re-executes per dept.
-- The correlated subquery runs once per department row = 8 executions here,
-- but O(n) for n departments at scale.
SELECT
    d.dept_id,
    d.dept_name,
    (
        SELECT CONCAT(e.first_name, ' ', e.last_name)
        FROM employees e
        WHERE e.dept_id = d.dept_id                    -- correlated: re-runs per dept
          AND e.salary = (
              SELECT MAX(e2.salary)
              FROM employees e2 WHERE e2.dept_id = d.dept_id  -- nested correlated!
          )
        LIMIT 1
    ) AS top_earner
FROM departments d;
-- EXPLAIN shows "DEPENDENT SUBQUERY" + "DEPENDENT SUBQUERY" nested — O(n²) in worst case.

-- GOOD: single-pass solution using ROW_NUMBER() window function
WITH ranked_emps AS (
    SELECT
        emp_id,
        first_name,
        last_name,
        dept_id,
        salary,
        ROW_NUMBER() OVER (PARTITION BY dept_id ORDER BY salary DESC) AS rn
    FROM employees
    WHERE salary IS NOT NULL
)
SELECT
    d.dept_id,
    d.dept_name,
    re.emp_id,
    re.first_name,
    re.last_name,
    re.salary AS max_salary
FROM departments d
JOIN ranked_emps re ON d.dept_id = re.dept_id
                   AND re.rn = 1
ORDER BY d.dept_id;
-- MySQL scans employees once, computes ROW_NUMBER in a single pass,
-- then joins to departments (8 rows). Total cost: O(n log n) for the sort,
-- not O(n × m) for nested correlated subqueries.
-- Performance note: this also handles ties correctly — use RANK() instead of
-- ROW_NUMBER() if you want all employees tied at the maximum salary per dept.
