USE `sql-patterns`;

-- =============================================================================
-- Window Functions: LAG / LEAD Patterns
-- Covers: boundary NULLs, defaults, salary deltas, % change, offset=2,
--         consecutive-event gaps, FIRST/LAST via boundary, next project date,
--         salary decrease flag, period-over-period rating, global vs. partitioned gotcha
-- MySQL 8.0+
-- Note: LAG/LEAD access adjacent rows directly — no ROWS BETWEEN frame needed.
-- =============================================================================


-- =============================================================================
-- 1. LAG(salary_after, 1) — previous salary in salary_history per employee
--    First row per employee has no predecessor → NULL boundary
-- =============================================================================

SELECT
    hist_id,
    emp_id,
    effective_date,
    salary_after,
    LAG(salary_after, 1) OVER (PARTITION BY emp_id ORDER BY effective_date) AS prev_salary
FROM salary_history
ORDER BY emp_id, effective_date;

-- Expected:
-- hist_id | emp_id | effective_date | salary_after | prev_salary
-- --------+--------+----------------+--------------+------------
--  1      |  1     | 2018-03-01     | 75000.00     | NULL       <- first row
--  3      |  1     | 2020-06-01     | 80000.00     | 75000.00
--  7      |  1     | 2023-01-01     | 85000.00     | 80000.00


-- =============================================================================
-- 2. LEAD(effective_date, 1) — next change date per employee
--    Last row per employee has no successor → NULL boundary
-- =============================================================================

SELECT
    hist_id,
    emp_id,
    effective_date,
    salary_after,
    LEAD(effective_date, 1) OVER (PARTITION BY emp_id ORDER BY effective_date) AS next_change_date
FROM salary_history
ORDER BY emp_id, effective_date;

-- Expected:
-- emp_id | effective_date | next_change_date
-- --------+----------------+-----------------
--  1     | 2018-03-01     | 2020-06-01
--  1     | 2020-06-01     | 2023-01-01
--  1     | 2023-01-01     | NULL           <- last row


-- =============================================================================
-- 3. LAG with default value: replace NULL boundary with 0
--    Useful when downstream math would blow up on NULL
-- =============================================================================

SELECT
    hist_id,
    emp_id,
    effective_date,
    salary_after,
    LAG(salary_after, 1, 0) OVER (PARTITION BY emp_id ORDER BY effective_date) AS prev_salary_default0
FROM salary_history
ORDER BY emp_id, effective_date;

-- Expected:
-- emp_id | effective_date | salary_after | prev_salary_default0
-- --------+----------------+--------------+---------------------
--  1     | 2018-03-01     | 75000.00     | 0.00    <- default used


-- =============================================================================
-- 4. Salary change amount: period-over-period delta
--    salary_after - LAG(salary_after, 1) → NULL for first row (no default)
-- =============================================================================

SELECT
    hist_id,
    emp_id,
    effective_date,
    salary_after,
    LAG(salary_after, 1) OVER (PARTITION BY emp_id ORDER BY effective_date) AS prev_salary,
    salary_after - LAG(salary_after, 1) OVER (PARTITION BY emp_id ORDER BY effective_date) AS salary_delta
FROM salary_history
ORDER BY emp_id, effective_date;

-- Expected:
-- emp_id | salary_after | prev_salary | salary_delta
-- --------+--------------+-------------+-------------
--  1     | 75000.00     | NULL        | NULL
--  1     | 80000.00     | 75000.00    | 5000.00
--  1     | 85000.00     | 80000.00    | 5000.00


-- =============================================================================
-- 5. Salary change %: (salary_after - prev_salary) / prev_salary * 100
--    NULL-safe division; first row → NULL; prev_salary = 0 guarded with NULLIF
-- =============================================================================

SELECT
    hist_id,
    emp_id,
    effective_date,
    salary_after,
    LAG(salary_after, 1) OVER (PARTITION BY emp_id ORDER BY effective_date) AS prev_salary,
    ROUND(
        (salary_after - LAG(salary_after, 1) OVER (PARTITION BY emp_id ORDER BY effective_date))
        / NULLIF(LAG(salary_after, 1) OVER (PARTITION BY emp_id ORDER BY effective_date), 0)
        * 100,
        2
    ) AS pct_change
FROM salary_history
ORDER BY emp_id, effective_date;

-- Expected:
-- emp_id | salary_after | prev_salary | pct_change
-- --------+--------------+-------------+----------
--  1     | 75000.00     | NULL        | NULL
--  1     | 80000.00     | 75000.00    | 6.67
--  1     | 85000.00     | 80000.00    | 6.25


-- =============================================================================
-- 6. LAG(2) — salary from 2 changes ago (offset = 2)
-- =============================================================================

SELECT
    hist_id,
    emp_id,
    effective_date,
    salary_after,
    LAG(salary_after, 2) OVER (PARTITION BY emp_id ORDER BY effective_date) AS salary_2_changes_ago
FROM salary_history
ORDER BY emp_id, effective_date;

-- Expected:
-- emp_id | effective_date | salary_after | salary_2_changes_ago
-- --------+----------------+--------------+---------------------
--  1     | 2018-03-01     | 75000.00     | NULL
--  1     | 2020-06-01     | 80000.00     | NULL  <- only 1 prior row
--  1     | 2023-01-01     | 85000.00     | 75000.00


-- =============================================================================
-- 7. Detect inter-event gap (in minutes) for same employee in emp_events
--    Useful for session analysis: big gap → new session
-- =============================================================================

SELECT
    event_id,
    emp_id,
    event_ts,
    session_id,
    LAG(event_ts, 1) OVER (PARTITION BY emp_id ORDER BY event_ts) AS prev_event_ts,
    TIMESTAMPDIFF(
        MINUTE,
        LAG(event_ts, 1) OVER (PARTITION BY emp_id ORDER BY event_ts),
        event_ts
    ) AS minutes_since_prev_event
FROM emp_events
ORDER BY emp_id, event_ts;

-- Expected:
-- emp_id | event_ts            | prev_event_ts       | minutes_since_prev_event
-- --------+---------------------+---------------------+-------------------------
--  1     | 2024-01-10 09:00:00 | NULL                | NULL
--  1     | 2024-01-10 09:05:00 | 2024-01-10 09:00:00 | 5
--  1     | 2024-01-10 09:45:00 | 2024-01-10 09:05:00 | 40  <- possible new session


-- =============================================================================
-- 8. First and last salary per employee via LAG/LEAD boundary check
--    First row: LAG IS NULL → this IS the first salary
--    Last row:  LEAD IS NULL → this IS the last salary
-- =============================================================================

SELECT
    emp_id,
    effective_date,
    salary_after,
    CASE
        WHEN LAG(salary_after, 1) OVER (PARTITION BY emp_id ORDER BY effective_date) IS NULL
        THEN 'FIRST SALARY'
        ELSE NULL
    END AS is_first,
    CASE
        WHEN LEAD(salary_after, 1) OVER (PARTITION BY emp_id ORDER BY effective_date) IS NULL
        THEN 'CURRENT SALARY'
        ELSE NULL
    END AS is_last
FROM salary_history
ORDER BY emp_id, effective_date;

-- Expected:
-- emp_id | salary_after | is_first     | is_last
-- --------+--------------+--------------+---------------
--  1     | 75000.00     | FIRST SALARY | NULL
--  1     | 80000.00     | NULL         | NULL
--  1     | 85000.00     | NULL         | CURRENT SALARY


-- =============================================================================
-- 9. LEAD — next project start date per employee in project_assignments
--    Useful for detecting scheduling gaps or back-to-back project overlaps
-- =============================================================================

SELECT
    pa.assignment_id,
    pa.emp_id,
    CONCAT(e.first_name, ' ', e.last_name)       AS employee,
    p.project_name,
    pa.start_date                                 AS assignment_start,
    pa.end_date                                   AS assignment_end,
    LEAD(pa.start_date, 1) OVER (
        PARTITION BY pa.emp_id
        ORDER BY pa.start_date
    )                                             AS next_project_start,
    DATEDIFF(
        LEAD(pa.start_date, 1) OVER (PARTITION BY pa.emp_id ORDER BY pa.start_date),
        pa.end_date
    )                                             AS days_gap_before_next
FROM project_assignments pa
JOIN employees e  ON e.emp_id     = pa.emp_id
JOIN projects   p ON p.project_id = pa.project_id
ORDER BY pa.emp_id, pa.start_date;

-- Expected:
-- emp_id | assignment_start | assignment_end | next_project_start | days_gap_before_next
-- --------+------------------+----------------+--------------------+---------------------
--  1     | 2022-01-01       | 2022-06-30     | 2022-07-15         | 15  (gap)
--  1     | 2022-07-15       | 2023-03-01     | NULL               | NULL (last project)


-- =============================================================================
-- 10. Flag rows where salary_after < previous salary (salary decrease)
--     Rare but real: contract renegotiations, role changes
-- =============================================================================

SELECT
    hist_id,
    emp_id,
    effective_date,
    salary_after,
    LAG(salary_after, 1) OVER (PARTITION BY emp_id ORDER BY effective_date) AS prev_salary,
    CASE
        WHEN salary_after < LAG(salary_after, 1) OVER (PARTITION BY emp_id ORDER BY effective_date)
        THEN 'DECREASE'
        WHEN salary_after > LAG(salary_after, 1) OVER (PARTITION BY emp_id ORDER BY effective_date)
        THEN 'INCREASE'
        WHEN salary_after = LAG(salary_after, 1) OVER (PARTITION BY emp_id ORDER BY effective_date)
        THEN 'UNCHANGED'
        ELSE 'INITIAL'
    END AS change_direction
FROM salary_history
ORDER BY emp_id, effective_date;

-- Expected (emp 5 has duplicate row on 2022-04-01 → UNCHANGED for the dup):
-- emp_id | salary_after | change_direction
-- --------+--------------+-----------------
--  5     | 95000.00     | INITIAL
--  5     | 100000.00    | INCREASE
--  5     | 100000.00    | UNCHANGED    <- duplicate row


-- =============================================================================
-- 11. Period-over-period: compare current rating vs. previous review period rating
--     per employee using LAG on performance_reviews
-- =============================================================================

SELECT
    pr.review_id,
    pr.emp_id,
    CONCAT(e.first_name, ' ', e.last_name)      AS employee,
    pr.review_period,
    pr.rating                                    AS current_rating,
    LAG(pr.rating, 1) OVER (
        PARTITION BY pr.emp_id
        ORDER BY pr.review_period
    )                                            AS prev_period_rating,
    pr.rating - LAG(pr.rating, 1) OVER (
        PARTITION BY pr.emp_id ORDER BY pr.review_period
    )                                            AS rating_delta,
    CASE
        WHEN pr.rating > LAG(pr.rating, 1) OVER (PARTITION BY pr.emp_id ORDER BY pr.review_period)
            THEN 'IMPROVED'
        WHEN pr.rating < LAG(pr.rating, 1) OVER (PARTITION BY pr.emp_id ORDER BY pr.review_period)
            THEN 'DECLINED'
        WHEN pr.rating = LAG(pr.rating, 1) OVER (PARTITION BY pr.emp_id ORDER BY pr.review_period)
            THEN 'STABLE'
        ELSE 'FIRST REVIEW'
    END AS trend
FROM performance_reviews pr
JOIN employees e ON e.emp_id = pr.emp_id
WHERE pr.rating IS NOT NULL
ORDER BY pr.emp_id, pr.review_period;

-- Expected:
-- emp_id | review_period | current_rating | prev_period_rating | rating_delta | trend
-- --------+---------------+----------------+--------------------+--------------+------
--  1     | 2023-H1       |  4             | NULL               | NULL         | FIRST REVIEW
--  1     | 2023-H2       |  5             | 4                  |  1           | IMPROVED
--  1     | 2024-H1       |  3             | 5                  | -2           | DECLINED


-- =============================================================================
-- 12. Common mistake: LAG WITHOUT PARTITION BY → global previous row
--     This leaks values across employees — the "previous" salary may belong to a
--     completely different employee's last row in the ORDER BY sequence.
-- =============================================================================

-- WRONG — no PARTITION BY: rows from different employees contaminate each other
SELECT
    hist_id,
    emp_id,
    effective_date,
    salary_after,
    LAG(salary_after, 1) OVER (ORDER BY emp_id, effective_date) AS WRONG_prev_salary
FROM salary_history
ORDER BY emp_id, effective_date
LIMIT 10;
-- The first row of emp 2 will show the last salary of emp 1 as "prev_salary".
-- This is silent cross-employee contamination — no error, wrong answer.

-- CORRECT — PARTITION BY emp_id isolates each employee's salary history
SELECT
    hist_id,
    emp_id,
    effective_date,
    salary_after,
    LAG(salary_after, 1) OVER (
        PARTITION BY emp_id        -- <-- the critical fix
        ORDER BY effective_date
    ) AS correct_prev_salary
FROM salary_history
ORDER BY emp_id, effective_date
LIMIT 10;

-- Rule: whenever you want "previous row for THIS entity", always PARTITION BY that entity's key.
-- Omitting PARTITION BY only makes sense when the whole table is one logical sequence (e.g., a time-series log with no grouping dimension).
