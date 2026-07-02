USE `sql-patterns`;

-- =============================================================================
-- Window Functions: Ranking Patterns
-- Covers: ROW_NUMBER, RANK, DENSE_RANK, NTILE, percentile, top/bottom-N,
--         global vs. within-dept rank, performance rating rank, gotchas
-- MySQL 8.0+
-- =============================================================================


-- =============================================================================
-- 1. ROW_NUMBER() — rank employees by salary within dept (DESC)
--    NULLs sort LAST in DESC order; emp 10, emp 15 get the highest row numbers
-- =============================================================================

SELECT
    emp_id,
    first_name,
    last_name,
    dept_id,
    salary,
    ROW_NUMBER() OVER (PARTITION BY dept_id ORDER BY salary DESC) AS rn_salary_desc
FROM employees
ORDER BY dept_id, rn_salary_desc;

-- Expected (dept_id=1, Engineering, 14 employees):
-- emp_id | dept_id | salary  | rn_salary_desc
-- -------+---------+---------+----------------
--  5     |  1      | 120000  |  1
--  7     |  1      | 115000  |  2
--  ...   |  1      | ...     |  ...
--  10    |  1      | NULL    |  14   <- NULL last in DESC


-- =============================================================================
-- 2. RANK() — equal salaries produce equal ranks WITH gaps
-- =============================================================================

SELECT
    emp_id,
    first_name,
    dept_id,
    salary,
    RANK() OVER (PARTITION BY dept_id ORDER BY salary DESC) AS rnk_salary
FROM employees
ORDER BY dept_id, rnk_salary;

-- If two employees in dept 1 both earn 115000:
-- emp_id | salary  | rnk_salary
-- -------+---------+-----------
--  5     | 120000  |  1
--  7     | 115000  |  2   <- tie
--  12    | 115000  |  2   <- tie
--  9     | 110000  |  4   <- gap (skips 3)


-- =============================================================================
-- 3. DENSE_RANK() — equal ranks, no gaps
-- =============================================================================

SELECT
    emp_id,
    first_name,
    dept_id,
    salary,
    DENSE_RANK() OVER (PARTITION BY dept_id ORDER BY salary DESC) AS dense_rnk
FROM employees
ORDER BY dept_id, dense_rnk;

-- Same tie scenario:
-- emp_id | salary  | dense_rnk
-- -------+---------+----------
--  5     | 120000  |  1
--  7     | 115000  |  2
--  12    | 115000  |  2
--  9     | 110000  |  3   <- no gap


-- =============================================================================
-- 4. Side-by-side comparison: ROW_NUMBER / RANK / DENSE_RANK for dept 1
--    Deliberately filter to dept with known salary ties to see the difference
-- =============================================================================

SELECT
    emp_id,
    CONCAT(first_name, ' ', last_name) AS full_name,
    salary,
    ROW_NUMBER()  OVER w AS row_num,
    RANK()        OVER w AS rnk,
    DENSE_RANK()  OVER w AS dense_rnk
FROM employees
WHERE dept_id = 1
WINDOW w AS (ORDER BY salary DESC)
ORDER BY row_num;

-- Interview note:
--   ROW_NUMBER: always unique (1,2,3,4,...) — non-deterministic for true ties
--   RANK:       gaps after ties (1,2,2,4,...)
--   DENSE_RANK: no gaps       (1,2,2,3,...)


-- =============================================================================
-- 5. NTILE(4) — bucket employees by salary into quartiles within dept
--    Quartile 1 = top earners, quartile 4 = bottom earners (DESC ORDER BY)
-- =============================================================================

SELECT
    emp_id,
    CONCAT(first_name, ' ', last_name) AS full_name,
    dept_id,
    COALESCE(salary, 0)                AS salary_coalesced,
    NTILE(4) OVER (PARTITION BY dept_id ORDER BY salary DESC) AS salary_quartile
FROM employees
ORDER BY dept_id, salary_quartile;

-- Note: NULL salaries (emp 10, 15) are treated as lowest; COALESCE shown in
-- the SELECT for display only — NTILE uses the raw ORDER BY, NULLs go last in DESC.

-- Expected (dept 1, 14 employees → 14/4 → buckets of size 4,4,3,3):
-- emp_id | salary_quartile
-- -------+----------------
--  5     |  1   (Q1 = top 25%)
--  7     |  1
--  ...
--  10    |  4   (Q4 = bottom 25%, NULL salary)


-- =============================================================================
-- 6. NTILE(3) — bucket employees by tenure (hire_date) into terciles globally
--    Tercile 1 = most tenured (earliest hire date), Tercile 3 = newest hires
-- =============================================================================

SELECT
    emp_id,
    CONCAT(first_name, ' ', last_name) AS full_name,
    hire_date,
    NTILE(3) OVER (ORDER BY hire_date ASC) AS tenure_tercile
FROM employees
ORDER BY tenure_tercile, hire_date;

-- Expected (41 employees → 14,14,13 per bucket):
-- emp_id | hire_date  | tenure_tercile
-- -------+------------+----------------
--  1     | 2018-03-01 |  1   (most tenured)
--  ...
--  41    | 2024-11-15 |  3   (newest)


-- =============================================================================
-- 7. Salary percentile rank within dept using ROW_NUMBER
--    MySQL has no PERCENT_RANK that's commonly asked — but PERCENT_RANK() exists!
--    Also show the ROW_NUMBER-based manual calculation.
-- =============================================================================

-- 7a. Built-in PERCENT_RANK() — value in [0, 1]
SELECT
    emp_id,
    dept_id,
    salary,
    ROUND(
        PERCENT_RANK() OVER (PARTITION BY dept_id ORDER BY salary ASC) * 100,
        1
    ) AS pct_rank_in_dept
FROM employees
WHERE salary IS NOT NULL
ORDER BY dept_id, pct_rank_in_dept;

-- 7b. Manual ROW_NUMBER approach (interview workaround when PERCENT_RANK not mentioned)
SELECT
    emp_id,
    dept_id,
    salary,
    rn,
    dept_count,
    ROUND((rn - 1) / (dept_count - 1) * 100, 1) AS manual_pct_rank
FROM (
    SELECT
        emp_id,
        dept_id,
        salary,
        ROW_NUMBER() OVER (PARTITION BY dept_id ORDER BY salary ASC) AS rn,
        COUNT(*)     OVER (PARTITION BY dept_id)                      AS dept_count
    FROM employees
    WHERE salary IS NOT NULL
) ranked
ORDER BY dept_id, manual_pct_rank;

-- Expected: employee with lowest salary in dept → pct_rank = 0
--           employee with highest salary in dept → pct_rank = 100


-- =============================================================================
-- 8. Top-1 per dept (highest-paid) using ROW_NUMBER in a CTE
-- =============================================================================

WITH ranked AS (
    SELECT
        emp_id,
        CONCAT(first_name, ' ', last_name) AS full_name,
        dept_id,
        salary,
        ROW_NUMBER() OVER (PARTITION BY dept_id ORDER BY salary DESC) AS rn
    FROM employees
    WHERE salary IS NOT NULL   -- exclude NULL-salary employees from top-1
)
SELECT
    r.dept_id,
    d.dept_name,
    r.emp_id,
    r.full_name,
    r.salary AS highest_salary
FROM ranked r
JOIN departments d ON d.dept_id = r.dept_id
WHERE r.rn = 1
ORDER BY r.dept_id;

-- Expected (one row per dept):
-- dept_id | dept_name   | emp_id | full_name        | highest_salary
-- --------+-------------+--------+------------------+---------------
--  1      | Engineering |  5     | Alice Smith      | 120000.00
--  2      | Marketing   |  ...   | ...              | ...


-- =============================================================================
-- 9. Bottom-2 per dept using ROW_NUMBER (exclude NULLs; emp 10/15 intentionally excluded)
-- =============================================================================

WITH ranked_asc AS (
    SELECT
        emp_id,
        CONCAT(first_name, ' ', last_name) AS full_name,
        dept_id,
        salary,
        ROW_NUMBER() OVER (PARTITION BY dept_id ORDER BY salary ASC) AS rn_asc
    FROM employees
    WHERE salary IS NOT NULL AND salary > 0   -- also exclude emp 19 (salary=0.00)
)
SELECT
    dept_id,
    emp_id,
    full_name,
    salary,
    rn_asc AS bottom_rank
FROM ranked_asc
WHERE rn_asc <= 2
ORDER BY dept_id, rn_asc;

-- Expected: 2 lowest-paid employees per dept
-- dept_id | emp_id | salary  | bottom_rank
-- --------+--------+---------+------------
--  1      |  ...   | 65000   |  1
--  1      |  ...   | 70000   |  2
--  2      |  ...   | 55000   |  1
--  ...


-- =============================================================================
-- 10. Global rank vs. within-dept rank — compare both in one result set
-- =============================================================================

SELECT
    emp_id,
    CONCAT(first_name, ' ', last_name)                             AS full_name,
    dept_id,
    salary,
    DENSE_RANK() OVER (ORDER BY salary DESC)                       AS global_rank,
    DENSE_RANK() OVER (PARTITION BY dept_id ORDER BY salary DESC)  AS dept_rank,
    -- diff shows how much the dept rank "flatters" vs. the global picture
    DENSE_RANK() OVER (ORDER BY salary DESC) -
        DENSE_RANK() OVER (PARTITION BY dept_id ORDER BY salary DESC) AS rank_diff
FROM employees
WHERE salary IS NOT NULL
ORDER BY global_rank;

-- Expected:
-- A highly-paid employee in a small dept might be dept_rank=1 but global_rank=5.
-- rank_diff > 0 means global rank is worse than dept rank (they look better in dept).
-- rank_diff < 0 means global rank is better than dept rank.


-- =============================================================================
-- 11. Dense rank on performance rating within review_period
--     NULL ratings handled: NULLs pushed to lowest rank (rank = 0 bucket)
-- =============================================================================

SELECT
    pr.review_id,
    pr.emp_id,
    CONCAT(e.first_name, ' ', e.last_name) AS employee,
    pr.review_period,
    pr.rating,
    -- Push NULLs to end by treating them as -1 in the ORDER BY CASE
    DENSE_RANK() OVER (
        PARTITION BY pr.review_period
        ORDER BY CASE WHEN pr.rating IS NULL THEN -1 ELSE pr.rating END DESC
    ) AS rating_rank_in_period
FROM performance_reviews pr
JOIN employees e ON e.emp_id = pr.emp_id
ORDER BY pr.review_period, rating_rank_in_period;

-- Expected:
-- review_period | emp_id | rating | rating_rank_in_period
-- -------------+--------+--------+----------------------
-- 2024-H1       |  5     |  5     |  1   (best)
-- 2024-H1       |  7     |  5     |  1   (tie)
-- 2024-H1       |  9     |  4     |  2
-- 2024-H1       |  3     | NULL   |  n   (last — treated as -1)


-- =============================================================================
-- 12. Interview gotcha: ROW_NUMBER is always deterministic (one row per rank)
--     RANK/DENSE_RANK can assign the same rank to multiple rows on ties.
--     If you use ROW_NUMBER to pick "top 1" on a tie, the winner is arbitrary.
-- =============================================================================

-- WRONG for "get the single best-rated employee per period when there's a tie":
-- ROW_NUMBER picks one arbitrarily if ratings are equal.
WITH rn_pick AS (
    SELECT
        emp_id,
        review_period,
        rating,
        ROW_NUMBER() OVER (PARTITION BY review_period ORDER BY rating DESC) AS rn
    FROM performance_reviews
    WHERE rating IS NOT NULL
)
SELECT emp_id, review_period, rating
FROM rn_pick
WHERE rn = 1;
-- Problem: if two employees both rated 5, only one is returned. The other is silently dropped.

-- CORRECT for "get all employees tied for the best rating":
WITH dr_pick AS (
    SELECT
        emp_id,
        review_period,
        rating,
        DENSE_RANK() OVER (PARTITION BY review_period ORDER BY rating DESC) AS dr
    FROM performance_reviews
    WHERE rating IS NOT NULL
)
SELECT emp_id, review_period, rating
FROM dr_pick
WHERE dr = 1;
-- Returns ALL employees with the top rating in each period.

-- Rule of thumb:
--   ROW_NUMBER → unique sequential integer; use when you need exactly N rows
--   RANK       → gaps after ties; use when "position" semantics matter (like sports)
--   DENSE_RANK → no gaps;   use when you want "tier" semantics without holes
