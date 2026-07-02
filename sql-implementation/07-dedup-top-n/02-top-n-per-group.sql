-- =============================================================================
-- FILE: 02-top-n-per-group.sql
-- DATABASE: sql-patterns
-- TOPIC: Top-N Per Group Patterns in MySQL 8.0+
-- COVERS: ROW_NUMBER / RANK / DENSE_RANK for top-1, top-3, bottom-N,
--         latest record per entity, tie-breaking, global top-N, filtered top-N,
--         and running-sum payroll coverage (top rows covering 50% of spend)
-- KNOWN DATA NOTES:
--   emp 35 has status != 'Active' (terminated) — excluded from Section 7
--   emp 15 has NULL salary — affects bottom-N ordering
--   salary_history emp_id=5 has two rows on 2022-04-01 — tie-breaking in Section 4
-- =============================================================================

USE `sql-patterns`;

-- =============================================================================
-- SECTION 1: TOP-1 PER GROUP — HIGHEST SALARY PER DEPARTMENT
-- Two methods: ROW_NUMBER() (always 1 row per dept even on salary tie) vs
-- GROUP BY + MAX subquery (returns multiple rows if salaries are tied at max).
-- =============================================================================

-- Method A: ROW_NUMBER() — deterministic, exactly 1 row per department.
-- COALESCE(salary, -1) DESC pushes NULL salaries to the bottom of each partition
-- so they are only selected if they are the only employee in the department.
-- emp_id ASC as secondary sort ensures a stable, deterministic winner on ties.
SELECT
    dept_id,
    emp_id,
    CONCAT(first_name, ' ', last_name) AS full_name,
    job_title,
    salary
FROM (
    SELECT
        emp_id,
        first_name,
        last_name,
        job_title,
        dept_id,
        salary,
        ROW_NUMBER() OVER (
            PARTITION BY dept_id
            ORDER BY COALESCE(salary, -1) DESC, emp_id ASC
        ) AS rn
    FROM employees
) ranked
WHERE rn = 1
ORDER BY dept_id;
-- Expected: 1 row per department. Employees with NULL salary will not win unless
-- they are the only person in their dept.

-- Method B: GROUP BY + MAX subquery — simpler but returns ties.
-- If two employees in the same dept share the exact same max salary, both appear.
SELECT
    e.dept_id,
    e.emp_id,
    CONCAT(e.first_name, ' ', e.last_name) AS full_name,
    e.job_title,
    e.salary
FROM employees e
JOIN (
    SELECT dept_id, MAX(salary) AS max_sal
    FROM employees
    GROUP BY dept_id
) m ON e.dept_id = m.dept_id
   AND e.salary  = m.max_sal
ORDER BY e.dept_id, e.emp_id;
-- Expected: usually same result as Method A, but if any two employees in a dept
-- share the same max salary, BOTH rows appear here (Method A would only show one).
-- NOTE: employees with NULL salary are automatically excluded because NULL != any value,
-- so they can never match m.max_sal even if MAX(salary) is NULL.

-- When to use each:
--   ROW_NUMBER → when you need exactly 1 row per group (pagination, ranked lists).
--   MAX subquery → when you want all tied winners (e.g., "show everyone at the top").


-- =============================================================================
-- SECTION 2: TOP-3 PER GROUP — ROW_NUMBER vs RANK vs DENSE_RANK
-- Key difference: ROW_NUMBER always gives distinct positions; RANK skips numbers
-- after a tie; DENSE_RANK never skips. In a department where 2 employees tie at
-- salary rank 3, ROW_NUMBER returns 3 rows total, RANK and DENSE_RANK return 4.
-- =============================================================================

-- Assign all three rankings to every employee, ordered by salary DESC per dept.
WITH ranked AS (
    SELECT
        dept_id,
        emp_id,
        CONCAT(first_name, ' ', last_name) AS full_name,
        salary,
        ROW_NUMBER() OVER (
            PARTITION BY dept_id
            ORDER BY COALESCE(salary, -1) DESC, emp_id ASC
        ) AS rn,
        RANK() OVER (
            PARTITION BY dept_id
            ORDER BY COALESCE(salary, -1) DESC
        ) AS rnk,
        DENSE_RANK() OVER (
            PARTITION BY dept_id
            ORDER BY COALESCE(salary, -1) DESC
        ) AS drk
    FROM employees
)
SELECT * FROM ranked
ORDER BY dept_id, rn;

-- Top-3 by ROW_NUMBER: exactly 3 rows per dept, no ties honored.
SELECT dept_id, emp_id, full_name, salary, rn
FROM (
    SELECT
        dept_id,
        emp_id,
        CONCAT(first_name, ' ', last_name) AS full_name,
        salary,
        ROW_NUMBER() OVER (
            PARTITION BY dept_id
            ORDER BY COALESCE(salary, -1) DESC, emp_id ASC
        ) AS rn
    FROM employees
) t
WHERE rn <= 3
ORDER BY dept_id, rn;

-- Top-3 by RANK: position 3 may include extra rows when salaries tie at rank 3.
-- A department with two employees tied at the 3rd-highest salary returns 4 rows.
SELECT dept_id, emp_id, full_name, salary, rnk
FROM (
    SELECT
        dept_id,
        emp_id,
        CONCAT(first_name, ' ', last_name) AS full_name,
        salary,
        RANK() OVER (
            PARTITION BY dept_id
            ORDER BY COALESCE(salary, -1) DESC
        ) AS rnk
    FROM employees
) t
WHERE rnk <= 3
ORDER BY dept_id, rnk;

-- Top-3 by DENSE_RANK: same tie behavior as RANK (shows all tied rows at rank 3)
-- but positions are consecutive — rank 1, 2, 3 with no gaps.
SELECT dept_id, emp_id, full_name, salary, drk
FROM (
    SELECT
        dept_id,
        emp_id,
        CONCAT(first_name, ' ', last_name) AS full_name,
        salary,
        DENSE_RANK() OVER (
            PARTITION BY dept_id
            ORDER BY COALESCE(salary, -1) DESC
        ) AS drk
    FROM employees
) t
WHERE drk <= 3
ORDER BY dept_id, drk;

-- Summary of differences:
--   Scenario: dept has salaries [100k, 90k, 80k, 80k, 70k]
--   ROW_NUMBER  → positions 1,2,3,4,5   — WHERE rn<=3 returns 3 rows (one 80k excluded)
--   RANK        → positions 1,2,3,3,5   — WHERE rnk<=3 returns 4 rows (both 80k included)
--   DENSE_RANK  → positions 1,2,3,3,4   — WHERE drk<=3 returns 4 rows (both 80k included)


-- =============================================================================
-- SECTION 3: LATEST RECORD PER ENTITY — MOST RECENT SALARY CHANGE PER EMPLOYEE
-- Three approaches shown with their trade-offs.
-- =============================================================================

-- Method A: ROW_NUMBER() window function — most efficient for large tables.
-- Scans salary_history once; no correlated subquery per row.
SELECT
    hist_id,
    emp_id,
    salary_before,
    salary_after,
    effective_date,
    change_reason
FROM (
    SELECT
        hist_id,
        emp_id,
        salary_before,
        salary_after,
        effective_date,
        change_reason,
        ROW_NUMBER() OVER (
            PARTITION BY emp_id
            ORDER BY effective_date DESC, hist_id DESC
        ) AS rn
    FROM salary_history
) t
WHERE rn = 1
ORDER BY emp_id;
-- Expected: 1 row per employee — their most recent salary change.

-- Method B: Self-join to derived MAX date — readable, works pre-MySQL 8.
SELECT sh.*
FROM salary_history sh
JOIN (
    SELECT emp_id, MAX(effective_date) AS max_date
    FROM salary_history
    GROUP BY emp_id
) latest ON sh.emp_id        = latest.emp_id
        AND sh.effective_date = latest.max_date
ORDER BY sh.emp_id, sh.hist_id;
-- CAVEAT: if an employee has two rows on the same max effective_date (e.g., emp_id=5
-- on 2022-04-01), BOTH rows are returned here. Method A handles this via hist_id DESC.

-- Method C: Correlated subquery — clearest to read, slowest to execute.
-- MySQL executes the inner SELECT once per outer row; use only on small tables.
SELECT *
FROM salary_history sh
WHERE sh.effective_date = (
    SELECT MAX(effective_date)
    FROM salary_history
    WHERE emp_id = sh.emp_id   -- correlates to outer row
)
ORDER BY sh.emp_id, sh.hist_id;
-- PERFORMANCE NOTE: For a table with N employees and M history rows, this runs M
-- correlated subqueries. Method A (window function) or Method B (JOIN) is O(M)
-- with a single scan + sort, making them dramatically faster on large datasets.


-- =============================================================================
-- SECTION 4: LATEST RECORD WITH TIE-BREAKING ON hist_id
-- emp_id=5 has two rows on 2022-04-01 (hist_id 15 and 16 — the exact dup pair).
-- Without a tie-breaker, both rows surface. Adding hist_id DESC picks exactly one.
-- =============================================================================

-- Without tie-breaker: effective_date alone. emp_id=5 returns TWO rows.
SELECT
    hist_id,
    emp_id,
    effective_date,
    change_reason
FROM (
    SELECT
        hist_id,
        emp_id,
        effective_date,
        change_reason,
        ROW_NUMBER() OVER (
            PARTITION BY emp_id
            ORDER BY effective_date DESC   -- no secondary sort
        ) AS rn
    FROM salary_history
) t
WHERE rn = 1
ORDER BY emp_id;
-- NOTE: ROW_NUMBER always returns exactly 1 row per emp_id because ties are broken
-- arbitrarily by the engine. The result is non-deterministic for emp_id=5.

-- With tie-breaker: hist_id DESC selects the HIGHER (later-inserted) hist_id on ties.
-- This deterministically picks hist_id=16 for emp_id=5.
SELECT
    hist_id,
    emp_id,
    salary_before,
    salary_after,
    effective_date,
    change_reason
FROM (
    SELECT
        hist_id,
        emp_id,
        salary_before,
        salary_after,
        effective_date,
        change_reason,
        ROW_NUMBER() OVER (
            PARTITION BY emp_id
            ORDER BY effective_date DESC, hist_id DESC   -- hist_id breaks the tie
        ) AS rn
    FROM salary_history
) t
WHERE rn = 1
ORDER BY emp_id;
-- Expected: emp_id=5 now deterministically returns hist_id=16 (the later duplicate).
-- This confirms that tie-breaking matters for correctness, and also surfaces the
-- duplicate insert in salary_history that Section 3 of dedup queries would remove.


-- =============================================================================
-- SECTION 5: BOTTOM-N PER GROUP — LOWEST-PAID EMPLOYEES PER DEPARTMENT
-- NULL salary handling is the key challenge: decide whether NULL means "unknown"
-- (treat as worst) or "unpaid" (treat as 0 / worst). Two idioms shown.
-- =============================================================================

-- Method A: COALESCE(salary, -1) ASC — NULLs treated as salary=-1 → appear first.
-- Bottom-2 per department; NULL salary employees surface at position 1 or 2.
SELECT
    dept_id,
    emp_id,
    CONCAT(first_name, ' ', last_name) AS full_name,
    salary,
    rn
FROM (
    SELECT
        dept_id,
        emp_id,
        first_name,
        last_name,
        salary,
        ROW_NUMBER() OVER (
            PARTITION BY dept_id
            ORDER BY COALESCE(salary, -1) ASC, emp_id ASC
        ) AS rn
    FROM employees
) t
WHERE rn <= 2
ORDER BY dept_id, rn;
-- Expected: emp 15 (NULL salary) will appear in rn=1 for their department because
-- COALESCE maps NULL → -1 which sorts before any real salary.

-- Method B: MySQL NULL-last equivalent for ASC order — NULLs treated as worst (highest).
-- MySQL idiom: ORDER BY CASE WHEN salary IS NULL THEN 1 ELSE 0 END ASC, salary ASC
-- NULL rows sort AFTER all real salaries (appear only if dept has < N real employees).
SELECT
    dept_id,
    emp_id,
    CONCAT(first_name, ' ', last_name) AS full_name,
    salary,
    rn
FROM (
    SELECT
        dept_id,
        emp_id,
        first_name,
        last_name,
        salary,
        ROW_NUMBER() OVER (
            PARTITION BY dept_id
            ORDER BY
                CASE WHEN salary IS NULL THEN 1 ELSE 0 END ASC,  -- NULLs last
                salary ASC
        ) AS rn
    FROM employees
) t
WHERE rn <= 2
ORDER BY dept_id, rn;
-- Expected: emp 15 (NULL salary) does NOT appear in the bottom-2 unless their
-- department has fewer than 2 employees with non-NULL salaries.
-- Choose Method A or B based on business meaning of NULL salary.


-- =============================================================================
-- SECTION 6: GLOBAL TOP-N ACROSS ALL GROUPS
-- No partitioning needed — just ORDER BY + LIMIT with NULL handling.
-- =============================================================================

-- Global top-5 employees by salary (NULLs excluded via COALESCE or IS NOT NULL).
SELECT
    emp_id,
    CONCAT(first_name, ' ', last_name) AS full_name,
    dept_id,
    job_title,
    salary
FROM employees
WHERE salary IS NOT NULL
ORDER BY salary DESC
LIMIT 5;
-- Expected: 5 highest-paid employees across all departments.

-- With RANK to handle ties correctly (all employees at the 5th salary still appear):
SELECT
    emp_id,
    full_name,
    dept_id,
    job_title,
    salary,
    rnk
FROM (
    SELECT
        emp_id,
        CONCAT(first_name, ' ', last_name) AS full_name,
        dept_id,
        job_title,
        salary,
        RANK() OVER (ORDER BY salary DESC) AS rnk
    FROM employees
    WHERE salary IS NOT NULL
) t
WHERE rnk <= 5
ORDER BY rnk, emp_id;
-- Expected: 5+ rows if there are salary ties at position 5. LIMIT 5 above would
-- arbitrarily exclude tied employees; RANK <= 5 is fairer for reporting.


-- =============================================================================
-- SECTION 7: TOP-N WITH ADDITIONAL FILTER — TOP-PAID ACTIVE EMPLOYEES PER DEPT
-- Apply WHERE status = 'Active' BEFORE the window function so the partition only
-- considers active employees. emp 35 (terminated) is excluded.
-- =============================================================================

SELECT
    dept_id,
    emp_id,
    CONCAT(first_name, ' ', last_name) AS full_name,
    job_title,
    salary,
    status,
    rn
FROM (
    SELECT
        dept_id,
        emp_id,
        first_name,
        last_name,
        job_title,
        salary,
        status,
        ROW_NUMBER() OVER (
            PARTITION BY dept_id
            ORDER BY COALESCE(salary, -1) DESC, emp_id ASC
        ) AS rn
    FROM employees
    WHERE status = 'Active'   -- filter BEFORE windowing; inactive employees never rank
) t
WHERE rn <= 3
ORDER BY dept_id, rn;
-- Expected: top-3 active employees per department. emp 35 does not appear.
-- Filtering inside the subquery (not in outer WHERE) is critical: if you filter in
-- the outer WHERE, ROW_NUMBER() would have already assigned ranks to all employees
-- including terminated ones, and their rn slots would remain gaps.


-- =============================================================================
-- SECTION 8: TOP EMPLOYEES COVERING 50% OF DEPARTMENT SALARY SPEND
-- Technique: running SUM of salary (ordered by salary DESC) divided by total dept
-- salary gives a running percentage. The smallest set of employees whose running
-- percentage reaches 50% is the answer. This is a "coverage" / "Pareto" query.
-- =============================================================================

WITH dept_totals AS (
    -- Total payroll per department (exclude NULLs from total)
    SELECT
        dept_id,
        SUM(salary) AS total_salary
    FROM employees
    WHERE salary IS NOT NULL
      AND status  = 'Active'
    GROUP BY dept_id
),
running AS (
    -- Running salary sum per department, highest earners first
    SELECT
        e.dept_id,
        e.emp_id,
        CONCAT(e.first_name, ' ', e.last_name) AS full_name,
        e.salary,
        dt.total_salary,
        SUM(e.salary) OVER (
            PARTITION BY e.dept_id
            ORDER BY e.salary DESC, e.emp_id ASC
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) AS running_salary,
        ROUND(
            100.0 * SUM(e.salary) OVER (
                PARTITION BY e.dept_id
                ORDER BY e.salary DESC, e.emp_id ASC
                ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
            ) / dt.total_salary,
            2
        ) AS running_pct
    FROM employees e
    JOIN dept_totals dt ON e.dept_id = dt.dept_id
    WHERE e.salary IS NOT NULL
      AND e.status  = 'Active'
)
SELECT
    dept_id,
    emp_id,
    full_name,
    salary,
    running_salary,
    total_salary,
    running_pct
FROM running
WHERE running_pct <= 50
   OR running_pct = (
        -- Include the first row that crosses 50% (the tipping-point employee)
        SELECT MIN(r2.running_pct)
        FROM running r2
        WHERE r2.dept_id    = running.dept_id
          AND r2.running_pct >= 50
   )
ORDER BY dept_id, running_pct;
-- Expected: for each dept, the smallest set of top earners whose combined salary
-- is >= 50% of the dept's total active payroll. Departments with 1-2 dominant
-- earners will have short lists; more even departments will have longer lists.

-- Simplified version (slightly over-inclusive — keeps all rows up to and including
-- the first row that exceeds 50%):
WITH dept_totals AS (
    SELECT dept_id, SUM(salary) AS total_salary
    FROM employees
    WHERE salary IS NOT NULL AND status = 'Active'
    GROUP BY dept_id
),
running AS (
    SELECT
        e.dept_id,
        e.emp_id,
        CONCAT(e.first_name, ' ', e.last_name) AS full_name,
        e.salary,
        ROUND(
            100.0 * SUM(e.salary) OVER (
                PARTITION BY e.dept_id
                ORDER BY e.salary DESC, e.emp_id ASC
                ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
            ) / dt.total_salary,
            2
        ) AS running_pct,
        -- Lag to check if the PREVIOUS row already cleared 50%
        LAG(
            ROUND(
                100.0 * SUM(e.salary) OVER (
                    PARTITION BY e.dept_id
                    ORDER BY e.salary DESC, e.emp_id ASC
                    ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
                ) / dt.total_salary,
                2
            )
        ) OVER (PARTITION BY e.dept_id ORDER BY e.salary DESC, e.emp_id ASC) AS prev_pct
    FROM employees e
    JOIN dept_totals dt ON e.dept_id = dt.dept_id
    WHERE e.salary IS NOT NULL AND e.status = 'Active'
)
SELECT dept_id, emp_id, full_name, salary, running_pct
FROM running
WHERE COALESCE(prev_pct, 0) < 50   -- include all rows before 50% is crossed
ORDER BY dept_id, running_pct;
-- Expected: same result as the primary query above. Each dept shows the employees
-- needed to reach 50% payroll — high earners appear first, list stops as soon as
-- the cumulative crosses 50%.
