USE `sql-patterns`;

-- =============================================================================
-- DATE TRANSFORMATION PATTERNS IN MySQL 8.0+
-- Database: sql-patterns
-- Topics: Fiscal year, week bucketing, tenure bands, anniversary, business days,
--         recursive month spine, last day of prior month, quarter labels,
--         cohort month, time-of-day buckets, date spine, cross-year leave,
--         leave duration in working days
-- Reference date for static examples: 2024-12-31
-- =============================================================================


-- -----------------------------------------------------------------------------
-- 1. FISCAL YEAR (APRIL–MARCH CYCLE)
--    FY starts April 1; a hire on 2023-05-01 belongs to FY2023 (Apr 2023–Mar 2024)
--    A hire on 2024-02-15 belongs to FY2023 (still in the Apr 2023–Mar 2024 window)
-- -----------------------------------------------------------------------------

SELECT
    emp_id,
    first_name,
    hire_date,
    MONTH(hire_date)                                          AS hire_month,
    CASE
        WHEN MONTH(hire_date) >= 4
        THEN YEAR(hire_date)
        ELSE YEAR(hire_date) - 1
    END                                                        AS fiscal_year,
    CONCAT('FY',
        CASE WHEN MONTH(hire_date) >= 4 THEN YEAR(hire_date) ELSE YEAR(hire_date) - 1 END,
        '-',
        CASE WHEN MONTH(hire_date) >= 4 THEN YEAR(hire_date) + 1 ELSE YEAR(hire_date) END
    )                                                          AS fiscal_year_label
FROM employees
ORDER BY fiscal_year, hire_date;
-- 2023-05-01 → FY2023 (FY2023-2024); 2024-02-15 → FY2023; 2024-04-01 → FY2024


-- -----------------------------------------------------------------------------
-- 2. WEEK-OVER-WEEK BUCKETING
--    Truncate event_ts to the Monday of its ISO week
--    DAYOFWEEK: 1=Sun, 2=Mon, ..., 7=Sat
--    Monday offset formula: subtract (DAYOFWEEK(d) + 5) % 7 days
-- -----------------------------------------------------------------------------

SELECT
    event_id,
    event_ts,
    DAYOFWEEK(event_ts)                                            AS dow_num,      -- 1=Sun
    DAYNAME(event_ts)                                              AS dow_name,
    DATE_SUB(DATE(event_ts), INTERVAL (DAYOFWEEK(event_ts) + 5) % 7 DAY)
                                                                   AS week_start_monday
FROM emp_events
ORDER BY week_start_monday, event_ts
LIMIT 20;
-- All events in the same Mon–Sun week share the same week_start_monday value

-- Aggregate events per week
SELECT
    DATE_SUB(DATE(event_ts), INTERVAL (DAYOFWEEK(event_ts) + 5) % 7 DAY)
                             AS week_start,
    COUNT(*)                 AS event_count,
    COUNT(DISTINCT emp_id)   AS unique_employees
FROM emp_events
GROUP BY week_start
ORDER BY week_start;


-- -----------------------------------------------------------------------------
-- 3. AGE / TENURE BANDS
--    Using TIMESTAMPDIFF(YEAR, hire_date, reference) to compute whole years of tenure
-- -----------------------------------------------------------------------------

SELECT
    emp_id,
    first_name,
    last_name,
    hire_date,
    TIMESTAMPDIFF(YEAR, hire_date, '2024-12-31')  AS tenure_years,
    CASE
        WHEN TIMESTAMPDIFF(YEAR, hire_date, '2024-12-31') <  1 THEN 'New'
        WHEN TIMESTAMPDIFF(YEAR, hire_date, '2024-12-31') <  3 THEN 'Junior'
        WHEN TIMESTAMPDIFF(YEAR, hire_date, '2024-12-31') <  7 THEN 'Mid'
        ELSE                                                          'Senior'
    END                                           AS tenure_band
FROM employees
ORDER BY hire_date;
-- emp 41 (hire_date=2025-08-01): tenure_years < 0 → 'New' (future hire; handle separately if needed)

-- Distribution summary
SELECT
    CASE
        WHEN TIMESTAMPDIFF(YEAR, hire_date, '2024-12-31') <  1 THEN 'New'
        WHEN TIMESTAMPDIFF(YEAR, hire_date, '2024-12-31') <  3 THEN 'Junior'
        WHEN TIMESTAMPDIFF(YEAR, hire_date, '2024-12-31') <  7 THEN 'Mid'
        ELSE 'Senior'
    END          AS tenure_band,
    COUNT(*)     AS headcount
FROM employees
GROUP BY tenure_band
ORDER BY FIELD(tenure_band, 'New', 'Junior', 'Mid', 'Senior');


-- -----------------------------------------------------------------------------
-- 4. DAYS UNTIL NEXT HIRE-DATE ANNIVERSARY
--    Find the next upcoming anniversary from reference date 2024-12-31
-- -----------------------------------------------------------------------------

SELECT
    emp_id,
    first_name,
    hire_date,
    -- Next anniversary date: set to this year's anniversary, then advance 1 year if already passed
    CASE
        WHEN DATE_FORMAT('2024-12-31', '%m-%d') >= DATE_FORMAT(hire_date, '%m-%d')
        -- This year's anniversary has passed (or is today) → next is next year
        THEN DATE_ADD(
                STR_TO_DATE(CONCAT(YEAR('2024-12-31') + 1, '-', DATE_FORMAT(hire_date, '%m-%d')), '%Y-%m-%d'),
                INTERVAL 0 DAY)
        ELSE
        -- This year's anniversary is still ahead
            STR_TO_DATE(CONCAT(YEAR('2024-12-31'), '-', DATE_FORMAT(hire_date, '%m-%d')), '%Y-%m-%d')
    END                                                   AS next_anniversary,
    DATEDIFF(
        CASE
            WHEN DATE_FORMAT('2024-12-31', '%m-%d') >= DATE_FORMAT(hire_date, '%m-%d')
            THEN STR_TO_DATE(CONCAT(YEAR('2024-12-31') + 1, '-', DATE_FORMAT(hire_date, '%m-%d')), '%Y-%m-%d')
            ELSE STR_TO_DATE(CONCAT(YEAR('2024-12-31'), '-', DATE_FORMAT(hire_date, '%m-%d')), '%Y-%m-%d')
        END,
        '2024-12-31'
    )                                                     AS days_until_anniversary
FROM employees
WHERE hire_date <= '2024-12-31'  -- exclude future hires
ORDER BY days_until_anniversary;
-- Employee whose anniversary is Jan 1 → days_until_anniversary=1


-- -----------------------------------------------------------------------------
-- 5. BUSINESS DAY APPROXIMATION (Mon–Fri, no holiday calendar)
--    Approximate business days = total days - (full_weeks * 2) - weekend_adjustment
--    Simplified: TIMESTAMPDIFF(DAY) - FLOOR(TIMESTAMPDIFF(DAY)/7)*2
-- -----------------------------------------------------------------------------

SELECT
    pa.assignment_id,
    pa.emp_id,
    pa.start_date,
    pa.end_date,
    DATEDIFF(pa.end_date, pa.start_date)                                    AS calendar_days,
    -- Subtract 2 days per complete week
    DATEDIFF(pa.end_date, pa.start_date)
        - (FLOOR(DATEDIFF(pa.end_date, pa.start_date) / 7) * 2)            AS approx_business_days
FROM project_assignments pa
WHERE pa.end_date IS NOT NULL
ORDER BY calendar_days DESC
LIMIT 10;
-- Approximation error: ±2 days depending on which weekday start/end fall on
-- For precision, use a calendar table with is_business_day flags


-- -----------------------------------------------------------------------------
-- 6. GENERATE MONTH-END DATES FOR A ROLLING 12-MONTH WINDOW (recursive CTE)
-- -----------------------------------------------------------------------------

WITH RECURSIVE month_ends AS (
    -- Anchor: last day of the 12th month back from reference date
    SELECT LAST_DAY(DATE_SUB('2024-12-31', INTERVAL 11 MONTH)) AS month_end_date

    UNION ALL

    SELECT LAST_DAY(DATE_ADD(month_end_date, INTERVAL 1 MONTH))
    FROM month_ends
    WHERE month_end_date < LAST_DAY('2024-12-31')
)
SELECT
    month_end_date,
    DATE_FORMAT(month_end_date, '%Y-%m')  AS year_month,
    DAY(month_end_date)                   AS days_in_month
FROM month_ends
ORDER BY month_end_date;
-- Expected: 12 rows from 2024-01-31 through 2024-12-31


-- -----------------------------------------------------------------------------
-- 7. LAST DAY OF THE PREVIOUS MONTH
-- -----------------------------------------------------------------------------

SELECT
    CURDATE()                                                      AS today,
    DATE_FORMAT(CURDATE(), '%Y-%m-01')                             AS first_of_this_month,
    DATE_SUB(DATE_FORMAT(CURDATE(), '%Y-%m-01'), INTERVAL 1 DAY)   AS last_day_prev_month;
-- As of 2024-12-31: last_day_prev_month = 2024-11-30

-- Use in a filter: all purchase orders from last month
SELECT order_id, order_date, amount
FROM purchase_orders
WHERE order_date BETWEEN
    DATE_FORMAT(DATE_SUB(CURDATE(), INTERVAL 1 MONTH), '%Y-%m-01')
    AND DATE_SUB(DATE_FORMAT(CURDATE(), '%Y-%m-01'), INTERVAL 1 DAY)
ORDER BY order_date;


-- -----------------------------------------------------------------------------
-- 8. QUARTER LABEL
-- -----------------------------------------------------------------------------

SELECT
    emp_id,
    hire_date,
    QUARTER(hire_date)                                       AS quarter_num,
    YEAR(hire_date)                                          AS hire_year,
    CONCAT('Q', QUARTER(hire_date), '-', YEAR(hire_date))   AS quarter_label
FROM employees
ORDER BY hire_date;
-- e.g. hired 2022-07-14 → 'Q3-2022'

-- Headcount by quarter hired
SELECT
    CONCAT('Q', QUARTER(hire_date), '-', YEAR(hire_date))  AS quarter_label,
    COUNT(*)                                                 AS hires
FROM employees
GROUP BY YEAR(hire_date), QUARTER(hire_date)
ORDER BY YEAR(hire_date), QUARTER(hire_date);


-- -----------------------------------------------------------------------------
-- 9. COHORT MONTH: DATE_FORMAT(hire_date, '%Y-%m')
-- -----------------------------------------------------------------------------

SELECT
    DATE_FORMAT(hire_date, '%Y-%m')  AS cohort_month,
    COUNT(*)                          AS cohort_size,
    AVG(salary)                       AS avg_starting_salary
FROM employees
GROUP BY cohort_month
ORDER BY cohort_month;
-- Each row = one hiring cohort; NULL salary excluded from avg by MySQL automatically

-- Per-cohort headcount vs current active headcount
SELECT
    DATE_FORMAT(hire_date, '%Y-%m')          AS cohort_month,
    COUNT(*)                                  AS ever_hired,
    SUM(CASE WHEN status = 'Active' THEN 1 ELSE 0 END) AS still_active,
    ROUND(100 * SUM(CASE WHEN status = 'Active' THEN 1 ELSE 0 END) / COUNT(*), 1)
                                              AS retention_pct
FROM employees
GROUP BY cohort_month
ORDER BY cohort_month;


-- -----------------------------------------------------------------------------
-- 10. TIME-OF-DAY BUCKETING FOR emp_events
-- -----------------------------------------------------------------------------

SELECT
    event_id,
    emp_id,
    event_ts,
    HOUR(event_ts)   AS event_hour,
    CASE
        WHEN HOUR(event_ts) BETWEEN  6 AND 11 THEN 'Morning'
        WHEN HOUR(event_ts) BETWEEN 12 AND 13 THEN 'Lunch'
        WHEN HOUR(event_ts) BETWEEN 14 AND 17 THEN 'Afternoon'
        WHEN HOUR(event_ts) BETWEEN 18 AND 21 THEN 'Evening'
        ELSE 'Off-Hours'
    END              AS time_bucket
FROM emp_events
ORDER BY event_ts
LIMIT 20;

-- Volume by time bucket
SELECT
    CASE
        WHEN HOUR(event_ts) BETWEEN  6 AND 11 THEN 'Morning'
        WHEN HOUR(event_ts) BETWEEN 12 AND 13 THEN 'Lunch'
        WHEN HOUR(event_ts) BETWEEN 14 AND 17 THEN 'Afternoon'
        WHEN HOUR(event_ts) BETWEEN 18 AND 21 THEN 'Evening'
        ELSE 'Off-Hours'
    END              AS time_bucket,
    COUNT(*)         AS event_count
FROM emp_events
GROUP BY time_bucket
ORDER BY event_count DESC;


-- -----------------------------------------------------------------------------
-- 11. DATE SPINE: FIRST 10 DAYS STARTING FROM 2024-01-01 (recursive CTE)
-- -----------------------------------------------------------------------------

WITH RECURSIVE date_spine AS (
    SELECT DATE('2024-01-01') AS spine_date

    UNION ALL

    SELECT DATE_ADD(spine_date, INTERVAL 1 DAY)
    FROM date_spine
    WHERE spine_date < DATE_ADD('2024-01-01', INTERVAL 9 DAY)
)
SELECT
    spine_date,
    DAYNAME(spine_date)  AS day_name,
    DAYOFWEEK(spine_date) AS dow        -- 1=Sun, 7=Sat
FROM date_spine;
-- Expected: 2024-01-01 (Mon) through 2024-01-10 (Wed)

-- Extend for a full year spine and join to daily event counts
WITH RECURSIVE date_spine AS (
    SELECT DATE('2024-01-01') AS spine_date
    UNION ALL
    SELECT DATE_ADD(spine_date, INTERVAL 1 DAY)
    FROM date_spine
    WHERE spine_date < '2024-12-31'
)
SELECT
    ds.spine_date,
    COUNT(ee.event_id)  AS daily_events
FROM date_spine ds
LEFT JOIN emp_events ee ON DATE(ee.event_ts) = ds.spine_date
GROUP BY ds.spine_date
ORDER BY ds.spine_date
LIMIT 10;
-- LEFT JOIN ensures every date in spine appears, even days with 0 events


-- -----------------------------------------------------------------------------
-- 12. CROSS-YEAR LEAVE: REQUESTS SPANNING DEC 31 → JAN 1
-- -----------------------------------------------------------------------------

SELECT
    request_id,
    emp_id,
    leave_type,
    start_date,
    end_date,
    YEAR(start_date)  AS start_year,
    YEAR(end_date)    AS end_year,
    DATEDIFF(end_date, start_date) + 1  AS total_days
FROM leave_requests
WHERE YEAR(start_date) != YEAR(end_date)
ORDER BY start_date;
-- These requests straddle two calendar years; important for annual leave accrual reports
-- Also catches multi-year leaves (edge case)

-- Flag all year-boundary leave requests with a label
SELECT
    request_id,
    emp_id,
    start_date,
    end_date,
    CONCAT(YEAR(start_date), ' → ', YEAR(end_date))  AS year_span_label
FROM leave_requests
WHERE YEAR(start_date) != YEAR(end_date);


-- -----------------------------------------------------------------------------
-- 13. LEAVE DURATION IN WORKING DAYS (simplified: calendar days minus weekend days)
-- -----------------------------------------------------------------------------

SELECT
    request_id,
    emp_id,
    leave_type,
    start_date,
    end_date,
    DATEDIFF(end_date, start_date) + 1                        AS calendar_days,
    -- Approximate working days: remove 2 days per full week, then handle partial week
    DATEDIFF(end_date, start_date) + 1
        - (FLOOR((DATEDIFF(end_date, start_date) + 1) / 7) * 2)
        -- Additional adjustment for partial-week start/end falling on weekends would need a calendar table
                                                               AS approx_working_days
FROM leave_requests
ORDER BY calendar_days DESC;
-- Note: leave_request 11 has leave_type=NULL — COALESCE if needed for reporting

-- With COALESCE for display:
SELECT
    request_id,
    emp_id,
    COALESCE(leave_type, 'Unspecified')                        AS leave_type_display,
    start_date,
    end_date,
    DATEDIFF(end_date, start_date) + 1                         AS calendar_days,
    DATEDIFF(end_date, start_date) + 1
        - (FLOOR((DATEDIFF(end_date, start_date) + 1) / 7) * 2) AS approx_working_days
FROM leave_requests
ORDER BY start_date;
