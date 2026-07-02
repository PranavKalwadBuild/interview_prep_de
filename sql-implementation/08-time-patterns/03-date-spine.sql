USE `sql-patterns`;

-- =============================================================================
-- DATE SPINE PATTERNS IN MySQL 8.0+
-- Database: sql-patterns
-- Topics: WITH RECURSIVE date/month/quarter/week spines, gap filling,
--         headcount over time, business day flags, island/gap detection
-- Reference date: 2024-12-31
-- Note: MySQL default cte_max_recursion_depth = 1000.
--       Set higher for spines that generate > 1000 rows.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- 1. SIMPLE DATE SPINE — every calendar date in 2024
--    SET SESSION before the CTE; 2024 is a leap year → 366 rows
-- -----------------------------------------------------------------------------

SET SESSION cte_max_recursion_depth = 400;

WITH RECURSIVE date_spine AS (
    SELECT DATE('2024-01-01') AS dt
    UNION ALL
    SELECT DATE_ADD(dt, INTERVAL 1 DAY)
    FROM date_spine
    WHERE dt < '2024-12-31'
)
SELECT dt
FROM date_spine
ORDER BY dt;
-- Expected: 366 rows (Jan 1 – Dec 31, 2024 inclusive; 2024 is a leap year)
-- First row: 2024-01-01
-- Last row:  2024-12-31
-- Use: LEFT JOIN any time-series table to expose gaps


-- -----------------------------------------------------------------------------
-- 2. MONTH SPINE — all (year, month) combinations from 2023-01 to 2024-12
--    Generates 24 rows; step is 1 month via INTERVAL 1 MONTH
-- -----------------------------------------------------------------------------

SET SESSION cte_max_recursion_depth = 30;

WITH RECURSIVE month_spine AS (
    SELECT
        DATE('2023-01-01')                          AS month_start,
        DATE('2023-01-31')                          AS month_end,
        YEAR(DATE('2023-01-01'))                    AS yr,
        MONTH(DATE('2023-01-01'))                   AS mo,
        DATE_FORMAT(DATE('2023-01-01'), '%Y-%m')    AS year_month
    UNION ALL
    SELECT
        DATE_ADD(month_start, INTERVAL 1 MONTH),
        LAST_DAY(DATE_ADD(month_start, INTERVAL 1 MONTH)),
        YEAR(DATE_ADD(month_start, INTERVAL 1 MONTH)),
        MONTH(DATE_ADD(month_start, INTERVAL 1 MONTH)),
        DATE_FORMAT(DATE_ADD(month_start, INTERVAL 1 MONTH), '%Y-%m')
    FROM month_spine
    WHERE month_start < '2024-12-01'
)
SELECT
    yr,
    mo,
    year_month,
    month_start,
    month_end
FROM month_spine
ORDER BY month_start;
-- Expected: 24 rows (2023-01 through 2024-12)
-- Each row includes first and last day of month for easy range joins.


-- -----------------------------------------------------------------------------
-- 3. JOIN DATE SPINE TO PURCHASE_ORDERS — FILL GAPS WITH $0
--    Months with no orders should appear with total_amount = 0.
--    Data covers 2024-01 through 2024-05; other months will show 0.
-- -----------------------------------------------------------------------------

SET SESSION cte_max_recursion_depth = 30;

WITH RECURSIVE month_spine AS (
    SELECT
        DATE('2024-01-01')                          AS month_start,
        DATE_FORMAT(DATE('2024-01-01'), '%Y-%m')    AS year_month
    UNION ALL
    SELECT
        DATE_ADD(month_start, INTERVAL 1 MONTH),
        DATE_FORMAT(DATE_ADD(month_start, INTERVAL 1 MONTH), '%Y-%m')
    FROM month_spine
    WHERE month_start < '2024-12-01'
),
monthly_orders AS (
    SELECT
        DATE_FORMAT(order_date, '%Y-%m')            AS year_month,
        SUM(amount)                                 AS total_amount,
        COUNT(*)                                    AS order_count
    FROM purchase_orders
    GROUP BY DATE_FORMAT(order_date, '%Y-%m')
)
SELECT
    ms.year_month,
    ms.month_start,
    COALESCE(mo.total_amount, 0)                    AS total_amount,
    COALESCE(mo.order_count, 0)                     AS order_count,
    CASE WHEN mo.year_month IS NULL THEN 'NO ORDERS' ELSE 'HAS ORDERS' END AS activity_flag
FROM month_spine ms
LEFT JOIN monthly_orders mo ON mo.year_month = ms.year_month
ORDER BY ms.month_start;
-- Expected: 12 rows (all months of 2024)
-- Jan–May 2024: HAS ORDERS with actual totals
-- Jun–Dec 2024: NO ORDERS, total_amount = 0
-- The spine makes silent gaps visible — without it, SELECT ... GROUP BY
-- would only return 5 rows and you'd never see the missing months.


-- -----------------------------------------------------------------------------
-- 4. DATE SPINE + EMPLOYEE HIRE DATES — DAILY HEADCOUNT PROGRESSION
--    For each date in 2023-2024: count employees where
--      hire_date <= dt AND (termination_date IS NULL OR termination_date > dt)
-- -----------------------------------------------------------------------------

SET SESSION cte_max_recursion_depth = 2000;

WITH RECURSIVE date_spine AS (
    SELECT DATE('2023-01-01') AS dt
    UNION ALL
    SELECT DATE_ADD(dt, INTERVAL 1 DAY)
    FROM date_spine
    WHERE dt < '2024-12-31'
)
SELECT
    ds.dt,
    COUNT(e.emp_id)                                 AS headcount,
    SUM(CASE WHEN e.dept_id = 1 THEN 1 ELSE 0 END) AS dept1_headcount,
    SUM(CASE WHEN e.dept_id = 2 THEN 1 ELSE 0 END) AS dept2_headcount
FROM date_spine ds
LEFT JOIN employees e
    ON e.hire_date <= ds.dt
    AND (e.termination_date IS NULL OR e.termination_date > ds.dt)
GROUP BY ds.dt
ORDER BY ds.dt;
-- Expected: 731 rows (2023-01-01 through 2024-12-31, 2 years including leap day 2024-02-29)
-- Headcount increases on each employee's hire_date.
-- Headcount decreases the day after termination_date (strict > comparison).
-- Employees with hire_date >= 2025 (e.g., emp 41) will NOT appear in this range —
-- their hire was in 2025, so they do not affect 2023-2024 headcount.
-- Note: SET SESSION cte_max_recursion_depth = 2000 required (731 rows > default 1000).


-- -----------------------------------------------------------------------------
-- 5. QUARTER SPINE — Q1–Q4 for 2023 and 2024
--    Each step advances 3 months; generate quarter label alongside dates
-- -----------------------------------------------------------------------------

SET SESSION cte_max_recursion_depth = 10;

WITH RECURSIVE quarter_spine AS (
    SELECT
        DATE('2023-01-01')                          AS qtr_start,
        DATE('2023-03-31')                          AS qtr_end,
        2023                                        AS yr,
        1                                           AS qtr_num
    UNION ALL
    SELECT
        DATE_ADD(qtr_start, INTERVAL 3 MONTH),
        LAST_DAY(DATE_ADD(DATE_ADD(qtr_start, INTERVAL 3 MONTH), INTERVAL 2 MONTH)),
        YEAR(DATE_ADD(qtr_start, INTERVAL 3 MONTH)),
        QUARTER(DATE_ADD(qtr_start, INTERVAL 3 MONTH))
    FROM quarter_spine
    WHERE qtr_start < '2024-10-01'
)
SELECT
    yr,
    qtr_num,
    CONCAT(yr, '-Q', qtr_num)                       AS quarter_label,
    qtr_start,
    qtr_end,
    DATEDIFF(qtr_end, qtr_start) + 1               AS days_in_quarter
FROM quarter_spine
ORDER BY qtr_start;
-- Expected: 8 rows (Q1 2023 through Q4 2024)
-- Q1: 90 days (non-leap year 2023), Q1 2024: 91 days (leap year)
-- Use qtr_start/qtr_end for BETWEEN joins to quarterly aggregations.


-- -----------------------------------------------------------------------------
-- 6. WEEK SPINE (MONDAY-START) — all Mondays in 2024
--    Find first Monday on or before 2024-01-01, then step by 7 days
-- -----------------------------------------------------------------------------

SET SESSION cte_max_recursion_depth = 60;

WITH RECURSIVE week_spine AS (
    -- DAYOFWEEK: 1=Sunday, 2=Monday, ..., 7=Saturday
    -- Subtract (DAYOFWEEK - 2) days to land on Monday; mod 7 handles Sunday edge case
    SELECT
        DATE_SUB('2024-01-01', INTERVAL MOD(DAYOFWEEK('2024-01-01') + 5, 7) DAY)
            AS week_start
    UNION ALL
    SELECT DATE_ADD(week_start, INTERVAL 7 DAY)
    FROM week_spine
    WHERE week_start < '2024-12-31'
),
weekly_orders AS (
    SELECT
        DATE_SUB(order_date, INTERVAL MOD(DAYOFWEEK(order_date) + 5, 7) DAY) AS week_start,
        COUNT(*)                                    AS orders_that_week,
        SUM(amount)                                 AS weekly_spend
    FROM purchase_orders
    GROUP BY DATE_SUB(order_date, INTERVAL MOD(DAYOFWEEK(order_date) + 5, 7) DAY)
)
SELECT
    ws.week_start,
    DATE_ADD(ws.week_start, INTERVAL 6 DAY)        AS week_end,
    WEEKOFYEAR(ws.week_start)                       AS iso_week_num,
    COALESCE(wo.orders_that_week, 0)                AS orders_count,
    COALESCE(wo.weekly_spend, 0)                    AS weekly_spend,
    CASE WHEN wo.week_start IS NULL THEN 'NO ACTIVITY' ELSE 'ACTIVE' END AS activity_flag
FROM week_spine ws
LEFT JOIN weekly_orders wo ON wo.week_start = ws.week_start
ORDER BY ws.week_start;
-- Expected: ~53 rows (52 full weeks + possible partial week overlap at year boundary)
-- 2024-01-01 is a Monday, so first week_start = 2024-01-01
-- Weeks with no purchase orders show orders_count = 0 (gap weeks visible)
-- purchase_orders span Jan–May 2024; Jun–Dec weeks all show NO ACTIVITY


-- -----------------------------------------------------------------------------
-- 7. DATE SPINE WITH BUSINESS DAY FLAG
--    Mark weekdays vs weekends; count business days per month of 2024
-- -----------------------------------------------------------------------------

SET SESSION cte_max_recursion_depth = 400;

WITH RECURSIVE date_spine AS (
    SELECT DATE('2024-01-01') AS dt
    UNION ALL
    SELECT DATE_ADD(dt, INTERVAL 1 DAY)
    FROM date_spine
    WHERE dt < '2024-12-31'
),
day_flags AS (
    SELECT
        dt,
        YEAR(dt)                                    AS yr,
        MONTH(dt)                                   AS mo,
        DATE_FORMAT(dt, '%Y-%m')                    AS year_month,
        DAYOFWEEK(dt)                               AS dow,          -- 1=Sun, 7=Sat
        DAYNAME(dt)                                 AS day_name,
        CASE WHEN DAYOFWEEK(dt) IN (1, 7) THEN 0 ELSE 1 END
                                                    AS is_business_day
    FROM date_spine
)
SELECT
    year_month,
    COUNT(*)                                        AS total_days,
    SUM(is_business_day)                            AS business_days,
    COUNT(*) - SUM(is_business_day)                 AS weekend_days
FROM day_flags
GROUP BY year_month, yr, mo
ORDER BY yr, mo;
-- Expected: 12 rows (one per month of 2024)
-- January 2024: 31 total days, 23 business days, 8 weekend days
-- February 2024: 29 days (leap year), 21 business days
-- Business day counts do NOT account for public holidays —
-- add a calendar_holidays table and LEFT JOIN to exclude them if needed.

-- To see individual day flags:
-- SELECT dt, day_name, is_business_day FROM day_flags ORDER BY dt;
-- Expected: 366 rows


-- -----------------------------------------------------------------------------
-- 8. DATE SPINE FOR GAP DETECTION IN LEAVE REQUESTS
--    Employee: emp_id = 5 (Emma Davis)
--    Range: 2024-01-01 to 2024-03-31 (Jan–Mar 2024)
--    Show which days are covered by leave vs working days; find contiguous blocks
-- -----------------------------------------------------------------------------

SET SESSION cte_max_recursion_depth = 100;

WITH RECURSIVE date_spine AS (
    SELECT DATE('2024-01-01') AS dt
    UNION ALL
    SELECT DATE_ADD(dt, INTERVAL 1 DAY)
    FROM date_spine
    WHERE dt < '2024-03-31'
),
emma_leave AS (
    -- Explode each leave_request into individual dates
    -- by joining spine to leave requests where dt falls within [start_date, end_date]
    SELECT lr.request_id, lr.leave_type, lr.start_date, lr.end_date, lr.status
    FROM leave_requests lr
    WHERE lr.emp_id = 5
      AND lr.status IN ('approved', 'pending')
      AND lr.end_date   >= '2024-01-01'
      AND lr.start_date <= '2024-03-31'
),
day_status AS (
    SELECT
        ds.dt,
        DAYNAME(ds.dt)                              AS day_name,
        CASE WHEN DAYOFWEEK(ds.dt) IN (1, 7) THEN 1 ELSE 0 END AS is_weekend,
        el.request_id,
        el.leave_type,
        el.status                                   AS leave_status,
        CASE
            WHEN el.request_id IS NOT NULL THEN 'ON LEAVE'
            WHEN DAYOFWEEK(ds.dt) IN (1, 7) THEN 'WEEKEND'
            ELSE 'WORKING DAY'
        END                                         AS day_classification
    FROM date_spine ds
    LEFT JOIN emma_leave el
        ON ds.dt BETWEEN el.start_date AND el.end_date
)
SELECT
    dt,
    day_name,
    day_classification,
    leave_type,
    leave_status
FROM day_status
ORDER BY dt;
-- Expected: 91 rows (Jan 1 – Mar 31, 2024 inclusive)
-- Each row is classified as ON LEAVE, WEEKEND, or WORKING DAY
-- Contiguous ON LEAVE rows form islands (consecutive leave blocks)
-- Gaps between leave blocks = WORKING DAY rows between islands

-- SUMMARY: count of each classification
SELECT
    day_classification,
    COUNT(*)                                        AS day_count
FROM (
    SELECT
        ds.dt,
        CASE
            WHEN el.request_id IS NOT NULL THEN 'ON LEAVE'
            WHEN DAYOFWEEK(ds.dt) IN (1, 7) THEN 'WEEKEND'
            ELSE 'WORKING DAY'
        END                                         AS day_classification
    FROM date_spine ds
    LEFT JOIN emma_leave el
        ON ds.dt BETWEEN el.start_date AND el.end_date
) classified
GROUP BY day_classification
ORDER BY day_count DESC;
-- Expected: 3 rows (ON LEAVE / WEEKEND / WORKING DAY with respective counts summing to 91)
-- If emp 5 has no leave_requests in this range, all non-weekend days = WORKING DAY.
