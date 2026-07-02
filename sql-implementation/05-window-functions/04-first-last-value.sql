USE `sql-patterns`;

-- =============================================================================
-- Window Functions: FIRST_VALUE, LAST_VALUE, NTH_VALUE Patterns
-- Covers: frame default trap, LAST_VALUE correct frame, NTH_VALUE, IGNORE NULLS
--         workaround, median approximation, interview tips
-- MySQL 8.0+
--
-- KEY RULE: LAST_VALUE always needs
--   ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING
--   Default frame (RANGE ... CURRENT ROW) stops at the current row, so
--   LAST_VALUE returns the CURRENT row's value — not the partition's last.
-- =============================================================================


-- =============================================================================
-- 1. FIRST_VALUE(salary_after) — initial hire salary for every row of an employee
--    Default frame (RANGE UNBOUNDED PRECEDING TO CURRENT ROW) works correctly
--    for FIRST_VALUE because the first row is always within the frame.
-- =============================================================================

SELECT
    hist_id,
    emp_id,
    effective_date,
    salary_after,
    FIRST_VALUE(salary_after) OVER (
        PARTITION BY emp_id
        ORDER BY effective_date
    ) AS initial_salary
FROM salary_history
ORDER BY emp_id, effective_date;

-- Expected:
-- emp_id | effective_date | salary_after | initial_salary
-- --------+----------------+--------------+---------------
--  1     | 2018-03-01     | 75000.00     | 75000.00  <- first row = itself
--  1     | 2020-06-01     | 80000.00     | 75000.00  <- still shows hire salary
--  1     | 2023-01-01     | 85000.00     | 75000.00  <- still shows hire salary
--  2     | 2018-05-15     | 60000.00     | 60000.00  <- resets for emp 2


-- =============================================================================
-- 2. LAST_VALUE with DEFAULT frame (RANGE UNBOUNDED PRECEDING TO CURRENT ROW)
--    WRONG result: frame ends at current row, so LAST_VALUE returns the CURRENT
--    row's own value — not the final salary in the partition.
-- =============================================================================

SELECT
    hist_id,
    emp_id,
    effective_date,
    salary_after,
    LAST_VALUE(salary_after) OVER (
        PARTITION BY emp_id
        ORDER BY effective_date
        -- default frame: RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ) AS current_salary_WRONG
FROM salary_history
ORDER BY emp_id, effective_date;

-- Expected (WRONG — each row shows its own salary, NOT the final salary):
-- emp_id | effective_date | salary_after | current_salary_WRONG
-- --------+----------------+--------------+---------------------
--  1     | 2018-03-01     | 75000.00     | 75000.00   <- should be 85000 but shows 75000
--  1     | 2020-06-01     | 80000.00     | 80000.00   <- should be 85000 but shows 80000
--  1     | 2023-01-01     | 85000.00     | 85000.00   <- coincidentally correct on last row


-- =============================================================================
-- 3. LAST_VALUE with correct frame (ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING)
--    Frame spans the entire partition → LAST_VALUE returns the actual last salary.
-- =============================================================================

SELECT
    hist_id,
    emp_id,
    effective_date,
    salary_after,
    LAST_VALUE(salary_after) OVER (
        PARTITION BY emp_id
        ORDER BY effective_date
        ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING
    ) AS current_salary_CORRECT
FROM salary_history
ORDER BY emp_id, effective_date;

-- Expected:
-- emp_id | effective_date | salary_after | current_salary_CORRECT
-- --------+----------------+--------------+------------------------
--  1     | 2018-03-01     | 75000.00     | 85000.00  <- correctly shows final salary
--  1     | 2020-06-01     | 80000.00     | 85000.00
--  1     | 2023-01-01     | 85000.00     | 85000.00


-- =============================================================================
-- 4. Side-by-side trap demonstration: WRONG frame vs CORRECT frame in one query
-- =============================================================================

SELECT
    hist_id,
    emp_id,
    effective_date,
    salary_after,
    -- WRONG: default frame
    LAST_VALUE(salary_after) OVER (
        PARTITION BY emp_id
        ORDER BY effective_date
    ) AS last_val_default_frame,
    -- CORRECT: full partition frame
    LAST_VALUE(salary_after) OVER (
        PARTITION BY emp_id
        ORDER BY effective_date
        ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING
    ) AS last_val_full_frame
FROM salary_history
ORDER BY emp_id, effective_date;

-- Expected diff on non-final rows:
-- emp_id | salary_after | last_val_default_frame | last_val_full_frame
-- --------+--------------+------------------------+--------------------
--  1     | 75000.00     | 75000.00  (WRONG)       | 85000.00  (correct)
--  1     | 80000.00     | 80000.00  (WRONG)       | 85000.00  (correct)
--  1     | 85000.00     | 85000.00  (same)         | 85000.00  (same)
-- Final row always matches — the trap only affects non-final rows.


-- =============================================================================
-- 5. NTH_VALUE(salary_after, 2) — the SECOND salary ever for each employee
--    Needs full frame or it returns NULL for rows before the 2nd occurrence.
-- =============================================================================

SELECT
    hist_id,
    emp_id,
    effective_date,
    salary_after,
    NTH_VALUE(salary_after, 2) OVER (
        PARTITION BY emp_id
        ORDER BY effective_date
        ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING
    ) AS second_salary
FROM salary_history
ORDER BY emp_id, effective_date;

-- Expected:
-- emp_id | effective_date | salary_after | second_salary
-- --------+----------------+--------------+--------------
--  1     | 2018-03-01     | 75000.00     | 80000.00  <- even first row shows 2nd salary
--  1     | 2020-06-01     | 80000.00     | 80000.00
--  1     | 2023-01-01     | 85000.00     | 80000.00
-- employees with only 1 salary entry: second_salary = NULL


-- =============================================================================
-- 6. FIRST_VALUE(job_title) — first job title held
--    Employees table has no job history; we use the current job_title as-is.
--    In a real system with a job_history table you'd partition by emp_id and
--    order by effective_date. Here we show the pattern using employees directly.
-- =============================================================================

SELECT
    emp_id,
    CONCAT(first_name, ' ', last_name)        AS full_name,
    dept_id,
    job_title                                  AS current_job,
    hire_date,
    -- Without a history table, FIRST_VALUE on a single-row-per-employee set
    -- just returns the same value. Pattern is meaningful when combined with
    -- a salary_history-style job_history table.
    FIRST_VALUE(job_title) OVER (
        PARTITION BY emp_id
        ORDER BY hire_date
    ) AS first_job_title
FROM employees
ORDER BY emp_id;

-- Note: In practice, join with a job_history table (emp_id, job_title, start_date)
-- and apply FIRST_VALUE(job_title) OVER (PARTITION BY emp_id ORDER BY start_date)
-- to get the true first title vs. the current title.


-- =============================================================================
-- 7. FIRST_VALUE to find each dept's highest-paid employee name
--    Window ordered by salary DESC → FIRST_VALUE picks the top earner's name.
--    Every row in the dept shows the top earner's name alongside their own salary.
-- =============================================================================

SELECT
    emp_id,
    CONCAT(first_name, ' ', last_name)             AS full_name,
    dept_id,
    salary,
    FIRST_VALUE(CONCAT(first_name, ' ', last_name)) OVER (
        PARTITION BY dept_id
        ORDER BY COALESCE(salary, -1) DESC    -- NULLs → -1 so they don't win
    ) AS top_earner_in_dept,
    FIRST_VALUE(COALESCE(salary, 0)) OVER (
        PARTITION BY dept_id
        ORDER BY COALESCE(salary, -1) DESC
    ) AS top_salary_in_dept
FROM employees
ORDER BY dept_id, salary DESC;

-- Expected:
-- dept_id | full_name       | salary    | top_earner_in_dept | top_salary_in_dept
-- --------+-----------------+-----------+--------------------+-------------------
--  1      | Alice Smith     | 120000.00 | Alice Smith        | 120000.00
--  1      | Bob Jones       | 115000.00 | Alice Smith        | 120000.00
--  ...
--  1      | emp10           | NULL      | Alice Smith        | 120000.00


-- =============================================================================
-- 8. LAST_VALUE — most recent review rating per employee
--    Must use ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING
-- =============================================================================

SELECT
    pr.review_id,
    pr.emp_id,
    CONCAT(e.first_name, ' ', e.last_name)  AS employee,
    pr.review_date,
    pr.review_period,
    pr.rating,
    LAST_VALUE(pr.rating) OVER (
        PARTITION BY pr.emp_id
        ORDER BY pr.review_date
        ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING
    ) AS most_recent_rating
FROM performance_reviews pr
JOIN employees e ON e.emp_id = pr.emp_id
ORDER BY pr.emp_id, pr.review_date;

-- Expected:
-- emp_id | review_period | rating | most_recent_rating
-- --------+---------------+--------+-------------------
--  1     | 2023-H1       |  4     |  3   <- shows the 2024-H1 rating on every row
--  1     | 2023-H2       |  5     |  3
--  1     | 2024-H1       |  3     |  3
-- NULL ratings: LAST_VALUE will propagate NULLs if the last review has NULL rating.


-- =============================================================================
-- 9. FIRST_VALUE with IGNORE NULLS — MySQL 8.0 does NOT support IGNORE NULLS.
--    Workaround 1: Use CASE WHEN inside FIRST_VALUE to skip NULLs by substituting
--                  a sentinel value, then re-filter.
--    Workaround 2: Subquery / CTE to pre-filter NULLs.
-- =============================================================================

-- WOULD WORK in Oracle/Spark SQL (MySQL REJECTS this syntax):
-- FIRST_VALUE(salary) IGNORE NULLS OVER (PARTITION BY dept_id ORDER BY hire_date)

-- Workaround 1: CASE WHEN sentinel — does NOT truly skip NULLs for FIRST_VALUE
-- (if the very first row is NULL, the sentinel -1 becomes the "first non-null")
-- This approach is unreliable. Use Workaround 2 instead.

-- Workaround 2: CTE pre-filter — reliable, interview-safe
-- Goal: first non-NULL rating per employee in performance_reviews
WITH non_null_ratings AS (
    SELECT
        emp_id,
        review_date,
        rating,
        ROW_NUMBER() OVER (
            PARTITION BY emp_id
            ORDER BY review_date ASC
        ) AS rn
    FROM performance_reviews
    WHERE rating IS NOT NULL   -- pre-filter NULLs here
)
SELECT
    pr.emp_id,
    CONCAT(e.first_name, ' ', e.last_name)  AS employee,
    pr.review_period,
    pr.rating                               AS this_period_rating,
    fnr.rating                              AS first_non_null_rating,
    fnr.review_date                         AS first_non_null_date
FROM performance_reviews pr
JOIN employees e              ON e.emp_id = pr.emp_id
LEFT JOIN non_null_ratings fnr ON fnr.emp_id = pr.emp_id AND fnr.rn = 1
ORDER BY pr.emp_id, pr.review_date;

-- Workaround 3: MIN/MAX with CASE (when you only need the value, not the window row)
SELECT
    emp_id,
    MIN(CASE WHEN rating IS NOT NULL THEN review_date END) AS first_rated_date,
    -- Then join back to get the rating for that date
    MIN(CASE WHEN rating IS NOT NULL THEN rating END)       AS first_non_null_rating_approx
FROM performance_reviews
GROUP BY emp_id;

-- Note: Workaround 3 gives the MIN rating for rows where rating IS NOT NULL,
-- not necessarily the chronologically-first non-null rating.
-- Workaround 2 (CTE with ROW_NUMBER) is the most reliable.


-- =============================================================================
-- 10. NTH_VALUE for median approximation
--     MySQL has no MEDIAN() or PERCENTILE_CONT().
--     Median position = FLOOR((COUNT + 1) / 2) for odd counts,
--                     = average of rows COUNT/2 and COUNT/2+1 for even counts.
--     Simplified: use NTH_VALUE at CEIL(COUNT/2) position within the partition.
-- =============================================================================

-- Median salary per department using NTH_VALUE
WITH dept_stats AS (
    SELECT
        emp_id,
        dept_id,
        salary,
        COUNT(*) OVER (PARTITION BY dept_id)  AS dept_count,
        -- NTH_VALUE needs the exact position; calculate it
        CEIL(COUNT(*) OVER (PARTITION BY dept_id) / 2.0) AS median_pos
    FROM employees
    WHERE salary IS NOT NULL
),
ranked AS (
    SELECT
        emp_id,
        dept_id,
        salary,
        dept_count,
        median_pos,
        ROW_NUMBER() OVER (PARTITION BY dept_id ORDER BY salary ASC) AS rn
    FROM dept_stats
)
SELECT
    dept_id,
    dept_count,
    -- Pick the row at the median position
    MAX(CASE WHEN rn = median_pos THEN salary END) AS approx_median_salary
FROM ranked
GROUP BY dept_id, dept_count
ORDER BY dept_id;

-- Alternative: NTH_VALUE directly (requires pre-computed position — MySQL NTH_VALUE
-- does not accept a subquery or expression as the N parameter, only a literal integer)
-- So the ROW_NUMBER CTE approach above is more practical for dynamic median.

-- For a fixed known N (e.g., 3rd salary in a dept's sorted list):
SELECT
    emp_id,
    dept_id,
    salary,
    NTH_VALUE(salary, 3) OVER (
        PARTITION BY dept_id
        ORDER BY salary ASC
        ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING
    ) AS third_lowest_salary_in_dept
FROM employees
WHERE salary IS NOT NULL
ORDER BY dept_id, salary;

-- Expected: every row in dept 1 shows the 3rd-lowest salary in Engineering.
-- Rows where the dept has fewer than 3 salary values: NULL.


-- =============================================================================
-- 11. Interview tip: LAST_VALUE frame requirement — summary
-- =============================================================================

-- FUNCTION      | DEFAULT FRAME WORKS? | WHY
-- --------------+---------------------+------------------------------------------
-- FIRST_VALUE   | YES                 | First row is always ≤ current row in frame
-- LAST_VALUE    | NO                  | Default frame ends at current row; last row
--               |                     | of partition is outside the frame
-- NTH_VALUE(n)  | ONLY FOR EARLY ROWS | Nth row may be beyond the default frame end
--               |                     | → returns NULL for rows before position N
--               |                     | without full frame
--
-- RULE: always add ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING
--       to LAST_VALUE and NTH_VALUE to get correct results on all rows.
--
-- WINDOW NAMED SHORTHAND (MySQL 8.0):
-- WINDOW w AS (PARTITION BY emp_id ORDER BY effective_date
--              ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING)
-- Then reference: LAST_VALUE(salary_after) OVER w

-- Demo using named window:
SELECT
    hist_id,
    emp_id,
    effective_date,
    salary_after,
    FIRST_VALUE(salary_after) OVER w  AS hire_salary,
    LAST_VALUE(salary_after)  OVER w  AS current_salary,
    NTH_VALUE(salary_after, 2) OVER w AS second_salary
FROM salary_history
WINDOW w AS (
    PARTITION BY emp_id
    ORDER BY effective_date
    ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING
)
ORDER BY emp_id, effective_date;
