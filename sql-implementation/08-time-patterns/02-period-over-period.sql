USE `sql-patterns`;

-- =============================================================================
-- PERIOD-OVER-PERIOD PATTERNS IN MySQL 8.0+
-- Database: sql-patterns
-- Topics: LAG/LEAD, self-join period comparison, MoM/YoY growth,
--         index baseline, cohort period tracking, boundary NULLs
-- Reference date: 2024-12-31
-- =============================================================================


-- -----------------------------------------------------------------------------
-- 1. HALF-OVER-HALF RATING CHANGE PER EMPLOYEE (SELF-JOIN APPROACH)
--    Show H1 and H2 2023 ratings side by side; compute delta
-- -----------------------------------------------------------------------------

WITH employee_period_ratings AS (
    SELECT
        emp_id,
        MAX(CASE WHEN review_period = '2023-H1' THEN rating END) AS rating_h1,
        MAX(CASE WHEN review_period = '2023-H2' THEN rating END) AS rating_h2,
        MAX(CASE WHEN review_period = '2024-H1' THEN rating END) AS rating_2024_h1
    FROM performance_reviews
    GROUP BY emp_id
)
SELECT
    e.emp_id,
    CONCAT(e.first_name, ' ', e.last_name)          AS employee_name,
    e.dept_id,
    epr.rating_h1                                   AS rating_2023_h1,
    epr.rating_h2                                   AS rating_2023_h2,
    epr.rating_2024_h1,
    epr.rating_h2 - epr.rating_h1                   AS h2_vs_h1_delta,
    CASE
        WHEN epr.rating_h2 > epr.rating_h1  THEN 'IMPROVED'
        WHEN epr.rating_h2 < epr.rating_h1  THEN 'DECLINED'
        WHEN epr.rating_h2 = epr.rating_h1  THEN 'UNCHANGED'
        ELSE 'INCOMPLETE_DATA'                       -- one or both periods NULL
    END                                             AS h2_vs_h1_trend
FROM employees e
JOIN employee_period_ratings epr ON epr.emp_id = e.emp_id
WHERE e.status = 'active'
ORDER BY h2_vs_h1_delta DESC;
-- Expected: one row per active employee who has at least one review
-- Employees with NULL for either period get delta = NULL → INCOMPLETE_DATA
-- Sorting by delta DESC puts most-improved employees at top


-- -----------------------------------------------------------------------------
-- 2. LAG-BASED PERIOD-OVER-PERIOD (CLEANER THAN SELF-JOIN)
--    Per-employee: previous period rating, rating change, % change
--    NULL for first period is expected — no prior row to look back to
-- -----------------------------------------------------------------------------

WITH emp_period AS (
    SELECT
        emp_id,
        review_period,
        CASE review_period
            WHEN '2023-H1' THEN 1
            WHEN '2023-H2' THEN 2
            WHEN '2024-H1' THEN 3
        END                                         AS period_rank,
        rating
    FROM performance_reviews
    WHERE rating IS NOT NULL               -- exclude reviews with no rating
)
SELECT
    ep.emp_id,
    CONCAT(e.first_name, ' ', e.last_name)          AS employee_name,
    ep.review_period,
    ep.period_rank,
    ep.rating,
    LAG(ep.rating, 1) OVER (
        PARTITION BY ep.emp_id
        ORDER BY ep.period_rank
    )                                               AS prev_period_rating,
    ep.rating - LAG(ep.rating, 1) OVER (
        PARTITION BY ep.emp_id
        ORDER BY ep.period_rank
    )                                               AS rating_change,
    ROUND(
        (ep.rating - LAG(ep.rating, 1) OVER (
            PARTITION BY ep.emp_id
            ORDER BY ep.period_rank
        )) / LAG(ep.rating, 1) OVER (
            PARTITION BY ep.emp_id
            ORDER BY ep.period_rank
        ) * 100,
        1
    )                                               AS pct_change
FROM emp_period ep
JOIN employees e ON e.emp_id = ep.emp_id
ORDER BY ep.emp_id, ep.period_rank;
-- Expected: one row per (employee, review_period) with a rating
-- First period per employee: prev_period_rating = NULL, rating_change = NULL, pct_change = NULL
-- This is correct boundary behavior — there is no prior period to compare against.
-- pct_change division by zero is not possible here because LAG returns NULL (not 0)
-- for the first row, and NULL / anything = NULL.


-- -----------------------------------------------------------------------------
-- 3. MONTHLY SPEND GROWTH (PURCHASE_ORDERS)
--    Aggregate to monthly totals, then use LAG for MoM growth %
-- -----------------------------------------------------------------------------

WITH monthly_spend AS (
    SELECT
        DATE_FORMAT(order_date, '%Y-%m')            AS year_month,
        YEAR(order_date)                            AS yr,
        MONTH(order_date)                           AS mo,
        SUM(amount)                                 AS total_amount,
        COUNT(*)                                    AS order_count
    FROM purchase_orders
    GROUP BY DATE_FORMAT(order_date, '%Y-%m'), YEAR(order_date), MONTH(order_date)
)
SELECT
    year_month,
    total_amount,
    order_count,
    LAG(total_amount, 1) OVER (ORDER BY yr, mo)     AS prev_month_amount,
    total_amount - LAG(total_amount, 1) OVER (
        ORDER BY yr, mo
    )                                               AS mom_absolute_change,
    ROUND(
        (total_amount - LAG(total_amount, 1) OVER (ORDER BY yr, mo))
        / LAG(total_amount, 1) OVER (ORDER BY yr, mo)
        * 100,
        1
    )                                               AS mom_growth_pct
FROM monthly_spend
ORDER BY yr, mo;
-- Expected: 5 rows (Jan–May 2024)
-- January row: prev_month_amount = NULL, mom_growth_pct = NULL  (no prior month)
-- Subsequent rows show month-over-month growth or decline
-- Positive pct = spend increased; negative = spend decreased vs prior month


-- -----------------------------------------------------------------------------
-- 4. YEAR-OVER-YEAR SALARY GROWTH
--    Average salary_after per year across all salary history;
--    YoY % change using LAG
-- -----------------------------------------------------------------------------

WITH yearly_avg_salary AS (
    SELECT
        YEAR(effective_date)                        AS yr,
        ROUND(AVG(salary_after), 2)                 AS avg_salary,
        COUNT(*)                                    AS raise_count
    FROM salary_history
    GROUP BY YEAR(effective_date)
)
SELECT
    yr,
    avg_salary,
    raise_count,
    LAG(avg_salary, 1) OVER (ORDER BY yr)           AS prev_year_avg_salary,
    ROUND(
        avg_salary - LAG(avg_salary, 1) OVER (ORDER BY yr),
        2
    )                                               AS yoy_absolute_change,
    ROUND(
        (avg_salary - LAG(avg_salary, 1) OVER (ORDER BY yr))
        / LAG(avg_salary, 1) OVER (ORDER BY yr)
        * 100,
        1
    )                                               AS yoy_growth_pct
FROM yearly_avg_salary
ORDER BY yr;
-- Expected: one row per year between 2015 and 2023 (sparse — only years with raises)
-- First year row: prev_year_avg_salary = NULL, yoy_growth_pct = NULL
-- Note: this averages across ALL employees getting raises that year,
-- so the mix of employees can skew the average (composition effect).


-- -----------------------------------------------------------------------------
-- 5. LEAD FOR FORWARD-LOOKING COMPARISON
--    Per employee: when was the NEXT raise? Gap in days between raises?
--    Flag employees with no raise in > 2 years (730 days)
-- -----------------------------------------------------------------------------

WITH salary_with_next AS (
    SELECT
        sh.emp_id,
        sh.effective_date,
        sh.salary_after,
        sh.change_reason,
        LEAD(sh.effective_date, 1) OVER (
            PARTITION BY sh.emp_id
            ORDER BY sh.effective_date
        )                                           AS next_raise_date,
        LEAD(sh.salary_after, 1) OVER (
            PARTITION BY sh.emp_id
            ORDER BY sh.effective_date
        )                                           AS next_salary
    FROM salary_history sh
)
SELECT
    swn.emp_id,
    CONCAT(e.first_name, ' ', e.last_name)          AS employee_name,
    swn.effective_date                              AS this_raise_date,
    swn.salary_after                                AS this_salary,
    swn.next_raise_date,
    swn.next_salary,
    DATEDIFF(swn.next_raise_date, swn.effective_date) AS days_until_next_raise,
    CASE
        WHEN swn.next_raise_date IS NULL THEN
            DATEDIFF('2024-12-31', swn.effective_date)  -- days since last raise to reference date
        ELSE NULL
    END                                             AS days_since_last_raise,
    CASE
        WHEN swn.next_raise_date IS NULL
         AND DATEDIFF('2024-12-31', swn.effective_date) > 730
        THEN 'NO_RAISE_OVER_2_YEARS'
        ELSE NULL
    END                                             AS raise_alert
FROM salary_with_next swn
JOIN employees e ON e.emp_id = swn.emp_id
ORDER BY swn.emp_id, swn.effective_date;
-- Expected: one row per salary_history record
-- next_raise_date = NULL for each employee's LAST salary record (LEAD has no following row)
-- days_since_last_raise is populated only for the terminal record
-- raise_alert flags employees whose most recent raise was > 2 years before 2024-12-31


-- -----------------------------------------------------------------------------
-- 6. INDEX COMPARISON (PERFORMANCE VS BASELINE PERIOD)
--    Set '2023-H1' as baseline index = 100
--    Each subsequent period's avg rating expressed as an index relative to baseline
-- -----------------------------------------------------------------------------

WITH period_avg AS (
    SELECT
        review_period,
        CASE review_period
            WHEN '2023-H1' THEN 1
            WHEN '2023-H2' THEN 2
            WHEN '2024-H1' THEN 3
        END                                         AS period_rank,
        ROUND(AVG(rating), 4)                       AS avg_rating
    FROM performance_reviews
    WHERE rating IS NOT NULL
    GROUP BY review_period
),
baseline AS (
    SELECT avg_rating AS baseline_rating
    FROM period_avg
    WHERE review_period = '2023-H1'
)
SELECT
    pa.review_period,
    pa.period_rank,
    ROUND(pa.avg_rating, 2)                         AS avg_rating,
    b.baseline_rating                               AS baseline_2023_h1,
    ROUND((pa.avg_rating / b.baseline_rating) * 100, 1)  AS performance_index
FROM period_avg pa
CROSS JOIN baseline b
ORDER BY pa.period_rank;
-- Expected: 3 rows
-- 2023-H1: performance_index = 100.0  (by definition)
-- 2023-H2: index > 100 if avg improved, < 100 if declined
-- 2024-H1: same interpretation
-- CROSS JOIN baseline is safe here because baseline returns exactly 1 row.
-- This pattern is equivalent to: (current / first_value) * 100
-- using FIRST_VALUE() window function as an alternative:

SELECT
    review_period,
    CASE review_period
        WHEN '2023-H1' THEN 1
        WHEN '2023-H2' THEN 2
        WHEN '2024-H1' THEN 3
    END                                             AS period_rank,
    ROUND(AVG(rating), 2)                           AS avg_rating,
    ROUND(
        AVG(rating) /
        FIRST_VALUE(AVG(rating)) OVER (
            ORDER BY
                CASE review_period
                    WHEN '2023-H1' THEN 1
                    WHEN '2023-H2' THEN 2
                    WHEN '2024-H1' THEN 3
                END
        ) * 100,
        1
    )                                               AS performance_index_fv
FROM performance_reviews
WHERE rating IS NOT NULL
GROUP BY review_period
ORDER BY period_rank;
-- FIRST_VALUE approach is more concise; CROSS JOIN approach is easier to debug.


-- -----------------------------------------------------------------------------
-- 7. COHORT PERIOD-OVER-PERIOD (REVIEW COUNT PER PERIOD)
--    Track how many reviews were submitted each period;
--    show absolute count change and % change period-over-period
-- -----------------------------------------------------------------------------

WITH period_counts AS (
    SELECT
        review_period,
        CASE review_period
            WHEN '2023-H1' THEN 1
            WHEN '2023-H2' THEN 2
            WHEN '2024-H1' THEN 3
        END                                         AS period_rank,
        COUNT(*)                                    AS total_reviews,
        COUNT(rating)                               AS rated_reviews,
        COUNT(*) - COUNT(rating)                    AS unrated_reviews
    FROM performance_reviews
    GROUP BY review_period
)
SELECT
    review_period,
    period_rank,
    total_reviews,
    rated_reviews,
    unrated_reviews,
    LAG(total_reviews, 1) OVER (ORDER BY period_rank)  AS prev_period_count,
    total_reviews - LAG(total_reviews, 1) OVER (
        ORDER BY period_rank
    )                                               AS count_change,
    ROUND(
        (total_reviews - LAG(total_reviews, 1) OVER (ORDER BY period_rank))
        / LAG(total_reviews, 1) OVER (ORDER BY period_rank)
        * 100,
        1
    )                                               AS pct_change
FROM period_counts
ORDER BY period_rank;
-- Expected: 3 rows (one per period)
-- First period: prev_period_count = NULL, count_change = NULL, pct_change = NULL
-- Increasing total_reviews over time may indicate org growth or review policy changes.
-- Tracking rated_reviews separately highlights periods where ratings were skipped.
