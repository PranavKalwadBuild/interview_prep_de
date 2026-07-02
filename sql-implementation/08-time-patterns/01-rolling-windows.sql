USE `sql-patterns`;

-- =============================================================================
-- ROLLING WINDOW PATTERNS IN MySQL 8.0+
-- Database: sql-patterns
-- Topics: ROWS BETWEEN, expanding/shrinking windows, rolling sum/avg/max/min,
--         NULL handling in windows, anomaly detection via rolling baseline
-- Reference date: 2024-12-31
-- =============================================================================


-- -----------------------------------------------------------------------------
-- 1. 3-MONTH ROLLING TOTAL PURCHASE AMOUNT
--    Step 1: aggregate purchase_orders to monthly totals (CTE)
--    Step 2: apply ROWS BETWEEN 2 PRECEDING AND CURRENT ROW over months
-- -----------------------------------------------------------------------------

WITH monthly_totals AS (
    SELECT
        YEAR(order_date)                            AS yr,
        MONTH(order_date)                           AS mo,
        DATE_FORMAT(order_date, '%Y-%m')            AS year_month,
        SUM(amount)                                 AS monthly_amount,
        COUNT(*)                                    AS order_count
    FROM purchase_orders
    GROUP BY YEAR(order_date), MONTH(order_date), DATE_FORMAT(order_date, '%Y-%m')
)
SELECT
    year_month,
    monthly_amount,
    order_count,
    SUM(monthly_amount) OVER (
        ORDER BY yr, mo
        ROWS BETWEEN 2 PRECEDING AND CURRENT ROW
    )                                               AS rolling_3mo_total,
    AVG(monthly_amount) OVER (
        ORDER BY yr, mo
        ROWS BETWEEN 2 PRECEDING AND CURRENT ROW
    )                                               AS rolling_3mo_avg
FROM monthly_totals
ORDER BY yr, mo;
-- Expected: 5 rows (Jan–May 2024)
-- Jan: rolling_total = Jan only (only 1 row exists before it)
-- Feb: rolling_total = Jan + Feb
-- Mar: rolling_total = Jan + Feb + Mar
-- Apr: rolling_total = Feb + Mar + Apr   (Jan drops off)
-- May: rolling_total = Mar + Apr + May

-- Note: ROWS BETWEEN counts physical rows, not calendar gaps.
-- If March had no orders and was missing from the CTE, Feb-to-Apr would
-- span 3 rows but would silently skip the missing month.
-- Use a date spine (see 03-date-spine.sql) to prevent silent gaps.


-- -----------------------------------------------------------------------------
-- 2. 3-PERIOD ROLLING AVERAGE OF PERFORMANCE RATINGS
--    review_period values: '2023-H1' (rank 1), '2023-H2' (rank 2), '2024-H1' (rank 3)
--    AVG ignores NULLs automatically; no COALESCE needed unless 0-fill is desired
-- -----------------------------------------------------------------------------

WITH period_avg AS (
    SELECT
        review_period,
        CASE review_period
            WHEN '2023-H1' THEN 1
            WHEN '2023-H2' THEN 2
            WHEN '2024-H1' THEN 3
        END                                         AS period_rank,
        AVG(rating)                                 AS avg_rating,   -- NULLs ignored by AVG
        COUNT(rating)                               AS rated_count,
        COUNT(*)                                    AS total_reviews
    FROM performance_reviews
    GROUP BY review_period
)
SELECT
    review_period,
    period_rank,
    ROUND(avg_rating, 2)                            AS avg_rating,
    rated_count,
    total_reviews,
    ROUND(
        AVG(avg_rating) OVER (
            ORDER BY period_rank
            ROWS BETWEEN 2 PRECEDING AND CURRENT ROW
        ), 2
    )                                               AS rolling_3period_avg
FROM period_avg
ORDER BY period_rank;
-- Expected: 3 rows
-- Period 1: rolling avg = avg of period 1 only
-- Period 2: rolling avg = avg of periods 1-2
-- Period 3: rolling avg = avg of periods 1-3
-- All three periods fit within the 3-row window, so window never shrinks here.

-- Note: AVG(rating) in the CTE already skips NULLs at row level.
-- The outer AVG(avg_rating) over the window then averages period-level averages
-- (not individual ratings), which is appropriate for comparing periods.


-- -----------------------------------------------------------------------------
-- 3. EXPANDING WINDOW (CUMULATIVE TOTAL FROM START)
--    ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
--    (a) Running total of purchase order amounts ordered by date
--    (b) Running headcount of employees hired over time
-- -----------------------------------------------------------------------------

-- (a) Running total spend across all purchase orders
SELECT
    order_id,
    order_date,
    vendor,
    item_category,
    amount,
    SUM(amount) OVER (
        ORDER BY order_date, order_id   -- order_id breaks ties on same date
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    )                                               AS running_total_spend,
    COUNT(*) OVER (
        ORDER BY order_date, order_id
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    )                                               AS running_order_count
FROM purchase_orders
ORDER BY order_date, order_id;
-- Expected: 25 rows; final row running_total = grand total of all orders


-- (b) Running headcount — employees hired, ordered by hire_date
SELECT
    emp_id,
    CONCAT(first_name, ' ', last_name)              AS employee_name,
    hire_date,
    dept_id,
    COUNT(*) OVER (
        ORDER BY hire_date, emp_id
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    )                                               AS cumulative_headcount
FROM employees
ORDER BY hire_date, emp_id;
-- Expected: one row per employee (hire_dates 2015-2025)
-- Each row shows how many employees had been hired up to and including that date.


-- -----------------------------------------------------------------------------
-- 4. SHRINKING WINDOW (SUM FROM CURRENT ROW TO END)
--    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
--    Use case: "how much total spend remains from this order onward?"
-- -----------------------------------------------------------------------------

SELECT
    order_id,
    order_date,
    vendor,
    amount,
    SUM(amount) OVER (
        ORDER BY order_date, order_id
        ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    )                                               AS remaining_spend,
    SUM(amount) OVER ()                             AS grand_total,
    SUM(amount) OVER (
        ORDER BY order_date, order_id
        ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
    )                                               AS spend_before_this_order
FROM purchase_orders
ORDER BY order_date, order_id;
-- Expected: 25 rows
-- First row: remaining_spend = grand total (nothing came before)
-- Last row:  remaining_spend = amount of last order only
-- spend_before_this_order is NULL for the very first order (no preceding rows)

-- Interpretation: remaining_spend decreasing row-by-row shows budget burn-down.


-- -----------------------------------------------------------------------------
-- 5. N-ROW ROLLING WINDOW ON SALARY HISTORY
--    ROWS BETWEEN 4 PRECEDING AND CURRENT ROW  (5-row window)
--    IMPORTANT: ROWS counts physical rows, NOT actual date gaps.
-- -----------------------------------------------------------------------------

SELECT
    sh.emp_id,
    CONCAT(e.first_name, ' ', e.last_name)          AS employee_name,
    sh.effective_date,
    sh.salary_after,
    sh.change_reason,
    AVG(sh.salary_after) OVER (
        PARTITION BY sh.emp_id
        ORDER BY sh.effective_date
        ROWS BETWEEN 4 PRECEDING AND CURRENT ROW
    )                                               AS rolling_5row_avg_salary
FROM salary_history sh
JOIN employees e ON e.emp_id = sh.emp_id
ORDER BY sh.emp_id, sh.effective_date;
-- Expected: one row per salary_history record (covers 2015-2023)
-- Raises are sparse (every 2-4 years), so the 5-row window may span
-- up to ~20 years of actual time for a long-tenured employee.

-- LIMITATION NOTE:
-- "5-row rolling average" != "5-year rolling average".
-- If emp 1 had raises in 2015, 2017, 2021, 2023, the 4-row window
-- for the 2023 row covers all four raises regardless of the 8-year gap.
-- To enforce true date-based windows, use a self-join or
-- RANGE BETWEEN INTERVAL 4 YEAR PRECEDING AND CURRENT ROW
-- (MySQL 8.0 supports RANGE with date intervals for DATE/DATETIME columns).

-- RANGE-based alternative (true 4-year look-back):
SELECT
    sh.emp_id,
    sh.effective_date,
    sh.salary_after,
    AVG(sh.salary_after) OVER (
        PARTITION BY sh.emp_id
        ORDER BY sh.effective_date
        RANGE BETWEEN INTERVAL 4 YEAR PRECEDING AND CURRENT ROW
    )                                               AS true_4yr_rolling_avg_salary
FROM salary_history sh
ORDER BY sh.emp_id, sh.effective_date;


-- -----------------------------------------------------------------------------
-- 6. ROLLING WINDOW SKIPPING NULLs VS COALESCE(0)
--    AVG over a window naturally ignores NULLs.
--    COALESCE(col, 0) treats NULL as zero — changes the average.
-- -----------------------------------------------------------------------------

-- Demonstration using purchase_orders.amount (no NULLs there),
-- so we simulate NULL behavior by treating amounts < 100 as "not reported"
-- via a NULLIF expression, then compare AVG with and without COALESCE.

SELECT
    order_id,
    order_date,
    amount,
    NULLIF(amount, 0)                               AS amount_nullable,  -- hypothetical nulls

    -- NULL-aware: window AVG ignores the NULL rows → avg of non-null values only
    AVG(NULLIF(amount, 0)) OVER (
        ORDER BY order_date, order_id
        ROWS BETWEEN 2 PRECEDING AND CURRENT ROW
    )                                               AS rolling_avg_skip_null,

    -- NULL-as-zero: COALESCE replaces NULL with 0 before aggregation
    AVG(COALESCE(NULLIF(amount, 0), 0)) OVER (
        ORDER BY order_date, order_id
        ROWS BETWEEN 2 PRECEDING AND CURRENT ROW
    )                                               AS rolling_avg_null_as_zero

FROM purchase_orders
ORDER BY order_date, order_id;
-- Key difference: if a window contains [100, NULL, 200]:
--   skip_null  → AVG(100, 200)     = 150.00
--   null_as_zero → AVG(100, 0, 200) = 100.00
-- Choose based on business meaning: "no data" vs "zero activity".


-- -----------------------------------------------------------------------------
-- 7. ROLLING MAX / ROLLING MIN
--    Running high-water mark and floor salary per employee
-- -----------------------------------------------------------------------------

SELECT
    sh.emp_id,
    CONCAT(e.first_name, ' ', e.last_name)          AS employee_name,
    sh.effective_date,
    sh.salary_after,
    MAX(sh.salary_after) OVER (
        PARTITION BY sh.emp_id
        ORDER BY sh.effective_date
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    )                                               AS running_high_water_salary,
    MIN(sh.salary_after) OVER (
        PARTITION BY sh.emp_id
        ORDER BY sh.effective_date
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    )                                               AS running_floor_salary,
    sh.salary_after - MIN(sh.salary_after) OVER (
        PARTITION BY sh.emp_id
        ORDER BY sh.effective_date
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    )                                               AS salary_above_floor
FROM salary_history sh
JOIN employees e ON e.emp_id = sh.emp_id
ORDER BY sh.emp_id, sh.effective_date;
-- Expected: one row per salary_history record
-- running_high_water_salary is non-decreasing per employee
-- If a salary ever decreases (e.g., demotion), the floor remains the prior low
-- salary_above_floor = 0 at the employee's lowest recorded salary


-- -----------------------------------------------------------------------------
-- 8. ROLLING BASELINE ANOMALY DETECTION (Z-SCORE-LIKE)
--    Flag purchase orders where amount > 2× the rolling 4-row average
--    for the same department.
-- -----------------------------------------------------------------------------

WITH order_with_rolling_baseline AS (
    SELECT
        order_id,
        dept_id,
        vendor,
        item_category,
        order_date,
        amount,
        AVG(amount) OVER (
            PARTITION BY dept_id
            ORDER BY order_date, order_id
            ROWS BETWEEN 3 PRECEDING AND CURRENT ROW   -- current + 3 prior = 4-row window
        )                                               AS rolling_4row_avg_dept,
        COUNT(*) OVER (
            PARTITION BY dept_id
            ORDER BY order_date, order_id
            ROWS BETWEEN 3 PRECEDING AND CURRENT ROW
        )                                               AS rows_in_window
    FROM purchase_orders
    WHERE dept_id IS NOT NULL
)
SELECT
    order_id,
    dept_id,
    vendor,
    item_category,
    order_date,
    amount,
    ROUND(rolling_4row_avg_dept, 2)                 AS rolling_avg,
    rows_in_window,
    CASE
        WHEN amount > 2 * rolling_4row_avg_dept THEN 'ANOMALY'
        WHEN amount > 1.5 * rolling_4row_avg_dept THEN 'ELEVATED'
        ELSE 'NORMAL'
    END                                             AS spend_flag
FROM order_with_rolling_baseline
ORDER BY dept_id, order_date, order_id;
-- Expected: rows for all non-NULL dept_id orders
-- ANOMALY rows warrant review; amount is more than double the recent average
-- rows_in_window < 4 for the first few orders per dept (window hasn't filled yet)
-- Note: with only 25 total orders and sparse dept distribution,
-- most depts will have small windows — anomaly detection is more meaningful
-- with larger datasets.
