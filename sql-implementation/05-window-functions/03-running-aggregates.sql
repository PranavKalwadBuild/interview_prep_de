USE `sql-patterns`;

-- =============================================================================
-- Window Functions: Running / Window Aggregate Patterns
-- Covers: running SUM, running AVG, partition totals, ROWS vs. RANGE trap,
--         rolling 3-row window, COUNT OVER, % of dept total, running count,
--         UNBOUNDED FOLLOWING, FIRST_VALUE/LAST_VALUE, NULL handling
-- MySQL 8.0+
-- =============================================================================


-- =============================================================================
-- 1. Running SUM of salary_after ordered by effective_date — all employees
--    Represents cumulative payroll commitment over time (all salary changes)
-- =============================================================================

SELECT
    hist_id,
    emp_id,
    effective_date,
    salary_after,
    SUM(salary_after) OVER (
        ORDER BY effective_date
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ) AS running_total_salary
FROM salary_history
ORDER BY effective_date, hist_id;

-- Expected:
-- hist_id | effective_date | salary_after | running_total_salary
-- --------+----------------+--------------+---------------------
--  1      | 2018-03-01     | 75000.00     | 75000.00
--  2      | 2018-05-15     | 60000.00     | 135000.00
--  3      | 2019-01-10     | 90000.00     | 225000.00
--  ...


-- =============================================================================
-- 2. Running SUM PARTITION BY emp_id — cumulative salary per employee over time
-- =============================================================================

SELECT
    hist_id,
    emp_id,
    effective_date,
    salary_after,
    SUM(salary_after) OVER (
        PARTITION BY emp_id
        ORDER BY effective_date
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ) AS cumulative_salary_per_emp
FROM salary_history
ORDER BY emp_id, effective_date;

-- Expected:
-- emp_id | effective_date | salary_after | cumulative_salary_per_emp
-- --------+----------------+--------------+---------------------------
--  1     | 2018-03-01     | 75000.00     | 75000.00
--  1     | 2020-06-01     | 80000.00     | 155000.00
--  1     | 2023-01-01     | 85000.00     | 240000.00
--  2     | 2018-05-15     | 60000.00     | 60000.00   <- resets for emp 2


-- =============================================================================
-- 3. Running AVG — moving average salary per employee over their history
-- =============================================================================

SELECT
    hist_id,
    emp_id,
    effective_date,
    salary_after,
    ROUND(
        AVG(salary_after) OVER (
            PARTITION BY emp_id
            ORDER BY effective_date
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ),
        2
    ) AS running_avg_salary
FROM salary_history
ORDER BY emp_id, effective_date;

-- Expected:
-- emp_id | effective_date | salary_after | running_avg_salary
-- --------+----------------+--------------+-------------------
--  1     | 2018-03-01     | 75000.00     | 75000.00
--  1     | 2020-06-01     | 80000.00     | 77500.00
--  1     | 2023-01-01     | 85000.00     | 80000.00


-- =============================================================================
-- 4. SUM OVER (PARTITION BY dept_id) — total dept salary as a window aggregate
--    No ORDER BY → default frame = entire partition; same value on every row
-- =============================================================================

SELECT
    emp_id,
    CONCAT(first_name, ' ', last_name)              AS full_name,
    dept_id,
    COALESCE(salary, 0)                             AS salary,
    SUM(COALESCE(salary, 0)) OVER (
        PARTITION BY dept_id
    )                                               AS dept_total_salary
FROM employees
ORDER BY dept_id, salary DESC;

-- Expected:
-- dept_id | emp_id | salary    | dept_total_salary
-- --------+--------+-----------+------------------
--  1      |  5     | 120000.00 | 1150000.00   <- same for every row in dept 1
--  1      |  7     | 115000.00 | 1150000.00
--  ...


-- =============================================================================
-- 5. SUM OVER (ORDER BY hire_date) — running hiring cost (salary) across all employees
--    ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW — explicit, safe
-- =============================================================================

SELECT
    emp_id,
    CONCAT(first_name, ' ', last_name)   AS full_name,
    hire_date,
    COALESCE(salary, 0)                  AS salary,
    SUM(COALESCE(salary, 0)) OVER (
        ORDER BY hire_date
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    )                                    AS running_hiring_cost
FROM employees
ORDER BY hire_date;

-- Expected:
-- emp_id | hire_date  | salary    | running_hiring_cost
-- --------+------------+-----------+--------------------
--  1     | 2018-03-01 | 75000.00  | 75000.00
--  2     | 2018-05-15 | 60000.00  | 135000.00
--  ...


-- =============================================================================
-- 6. ROWS vs RANGE trap: the default frame when ORDER BY is present
--
--    Without an explicit frame clause, ORDER BY activates:
--      RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
--    This lumps all "peer" rows (same ORDER BY value = same effective_date) into
--    the same frame, so they all get the same running sum.
--
--    ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW treats each physical row
--    independently, giving each its own cumulative sum.
--
--    Demo: two salary_history rows with the same effective_date (emp 5 duplicate)
-- =============================================================================

-- RANGE (default) — both rows on the same date see the SAME running sum
SELECT
    hist_id,
    emp_id,
    effective_date,
    salary_after,
    SUM(salary_after) OVER (
        ORDER BY effective_date
        -- implicit: RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ) AS range_running_sum
FROM salary_history
WHERE emp_id = 5
ORDER BY effective_date, hist_id;

-- ROWS — each physical row sees its own running sum
SELECT
    hist_id,
    emp_id,
    effective_date,
    salary_after,
    SUM(salary_after) OVER (
        ORDER BY effective_date
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ) AS rows_running_sum
FROM salary_history
WHERE emp_id = 5
ORDER BY effective_date, hist_id;

-- Expected difference for emp 5 (duplicate on 2022-04-01, both salary_after=100000):
-- hist_id | effective_date | salary_after | range_running_sum | rows_running_sum
-- --------+----------------+--------------+-------------------+-----------------
--  (row A) | 2022-04-01   | 100000.00    | 295000.00         | 195000.00  <- differ!
--  (row B) | 2022-04-01   | 100000.00    | 295000.00         | 295000.00
-- RANGE: both rows are "peers" → both see the sum that includes both peers.
-- ROWS:  each row adds only itself incrementally.


-- =============================================================================
-- 7. Rolling 3-row window: last 2 prior rows + current row (ROWS BETWEEN 2 PRECEDING)
-- =============================================================================

SELECT
    hist_id,
    emp_id,
    effective_date,
    salary_after,
    ROUND(
        AVG(salary_after) OVER (
            PARTITION BY emp_id
            ORDER BY effective_date
            ROWS BETWEEN 2 PRECEDING AND CURRENT ROW
        ),
        2
    ) AS rolling_3row_avg,
    SUM(salary_after) OVER (
        PARTITION BY emp_id
        ORDER BY effective_date
        ROWS BETWEEN 2 PRECEDING AND CURRENT ROW
    ) AS rolling_3row_sum
FROM salary_history
ORDER BY emp_id, effective_date;

-- Expected (emp 1, 3 salary events):
-- effective_date | salary_after | rolling_3row_avg | rolling_3row_sum
-- ---------------+--------------+------------------+-----------------
-- 2018-03-01     | 75000.00     | 75000.00         | 75000.00  (only 1 row in window)
-- 2020-06-01     | 80000.00     | 77500.00         | 155000.00 (2 rows)
-- 2023-01-01     | 85000.00     | 80000.00         | 240000.00 (3 rows)


-- =============================================================================
-- 8. COUNT OVER — employee count in each dept (no ORDER BY → whole partition)
-- =============================================================================

SELECT
    emp_id,
    CONCAT(first_name, ' ', last_name) AS full_name,
    dept_id,
    COUNT(*) OVER (PARTITION BY dept_id) AS employees_in_dept
FROM employees
ORDER BY dept_id, emp_id;

-- Expected:
-- dept_id | emp_id | employees_in_dept
-- --------+--------+------------------
--  1      |  1     | 14   <- Engineering has 14
--  1      |  2     | 14
--  ...
--  2      | 15     |  5   (example)


-- =============================================================================
-- 9. Percentage of dept total: salary / SUM(salary) OVER (PARTITION BY dept_id)
-- =============================================================================

SELECT
    emp_id,
    CONCAT(first_name, ' ', last_name)        AS full_name,
    dept_id,
    COALESCE(salary, 0)                       AS salary,
    SUM(COALESCE(salary, 0)) OVER (
        PARTITION BY dept_id
    )                                         AS dept_total,
    ROUND(
        COALESCE(salary, 0)
        / NULLIF(SUM(COALESCE(salary, 0)) OVER (PARTITION BY dept_id), 0)
        * 100,
        2
    )                                         AS pct_of_dept_total
FROM employees
ORDER BY dept_id, salary DESC;

-- Expected:
-- dept_id | salary    | dept_total  | pct_of_dept_total
-- --------+-----------+-------------+------------------
--  1      | 120000.00 | 1150000.00  | 10.43
--  1      | 115000.00 | 1150000.00  |  9.96
--  ...
--  1      |   0.00    | 1150000.00  |  0.00  (emp with NULL salary → coalesced to 0)


-- =============================================================================
-- 10. Running count of salary changes per employee
-- =============================================================================

SELECT
    hist_id,
    emp_id,
    effective_date,
    change_reason,
    COUNT(*) OVER (
        PARTITION BY emp_id
        ORDER BY effective_date
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ) AS change_number   -- 1 = first change (hire), 2 = second raise, etc.
FROM salary_history
ORDER BY emp_id, effective_date;

-- Expected:
-- emp_id | effective_date | change_reason | change_number
-- --------+----------------+---------------+--------------
--  1     | 2018-03-01     | Initial Hire  | 1
--  1     | 2020-06-01     | Promotion     | 2
--  1     | 2023-01-01     | Annual Review | 3


-- =============================================================================
-- 11. SUM with UNBOUNDED FOLLOWING — total of all future salary changes after each row
-- =============================================================================

SELECT
    hist_id,
    emp_id,
    effective_date,
    salary_after,
    SUM(salary_after) OVER (
        PARTITION BY emp_id
        ORDER BY effective_date
        ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    ) AS future_total_including_current,
    SUM(salary_after) OVER (
        PARTITION BY emp_id
        ORDER BY effective_date
        ROWS BETWEEN 1 FOLLOWING AND UNBOUNDED FOLLOWING
    ) AS future_total_excluding_current  -- NULL on last row (no rows follow)
FROM salary_history
ORDER BY emp_id, effective_date;

-- Expected (emp 1):
-- effective_date | salary_after | future_total_including_current | future_total_excluding_current
-- ---------------+--------------+--------------------------------+-------------------------------
-- 2018-03-01     | 75000.00     | 240000.00                      | 165000.00
-- 2020-06-01     | 80000.00     | 165000.00                      |  85000.00
-- 2023-01-01     | 85000.00     |  85000.00                      |  NULL


-- =============================================================================
-- 12. FIRST_VALUE and LAST_VALUE on salary_history per employee
--     LAST_VALUE requires explicit ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING
--     otherwise default frame stops at current row and returns current salary, not last.
-- =============================================================================

SELECT
    hist_id,
    emp_id,
    effective_date,
    salary_after,
    -- Initial (hire) salary — correct with default frame because first row is always in it
    FIRST_VALUE(salary_after) OVER (
        PARTITION BY emp_id
        ORDER BY effective_date
    ) AS initial_salary,
    -- WRONG: default frame → current row is "last" → returns salary_after itself
    LAST_VALUE(salary_after) OVER (
        PARTITION BY emp_id
        ORDER BY effective_date
        -- implicit: RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ) AS current_salary_wrong,
    -- CORRECT: extend frame to end of partition
    LAST_VALUE(salary_after) OVER (
        PARTITION BY emp_id
        ORDER BY effective_date
        ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING
    ) AS current_salary_correct
FROM salary_history
ORDER BY emp_id, effective_date;

-- Expected (emp 1):
-- effective_date | salary_after | initial_salary | current_salary_wrong | current_salary_correct
-- ---------------+--------------+----------------+----------------------+------------------------
-- 2018-03-01     | 75000.00     | 75000.00       | 75000.00             | 85000.00
-- 2020-06-01     | 80000.00     | 75000.00       | 80000.00             | 85000.00  <- correct!
-- 2023-01-01     | 85000.00     | 75000.00       | 85000.00             | 85000.00


-- =============================================================================
-- 13. NULL handling: COALESCE before SUM OVER to prevent NULL propagation
--     emp 10 and emp 15 have NULL salary; without COALESCE, dept totals are wrong
--     when dept has NULLs (SUM ignores NULLs in aggregate, but COALESCE makes it explicit)
-- =============================================================================

-- WITHOUT COALESCE — SUM already ignores NULLs, but the individual row still shows NULL
SELECT
    emp_id,
    dept_id,
    salary,
    SUM(salary) OVER (PARTITION BY dept_id) AS dept_total_without_coalesce
FROM employees
WHERE dept_id = 1
ORDER BY salary DESC;

-- WITH COALESCE — NULL salary employees contribute 0; consistent display
SELECT
    emp_id,
    dept_id,
    COALESCE(salary, 0)                                            AS salary_safe,
    SUM(COALESCE(salary, 0)) OVER (PARTITION BY dept_id)           AS dept_total_with_coalesce
FROM employees
WHERE dept_id = 1
ORDER BY salary_safe DESC;

-- Expected: dept_total is the same (SUM ignores NULLs), but NULL salary rows now
-- show 0.00 instead of NULL — safer for downstream calculations and reporting.
-- If you compute pct_of_dept = salary / dept_total, NULL salary without COALESCE
-- gives NULL; with COALESCE it gives 0.00 as expected.
