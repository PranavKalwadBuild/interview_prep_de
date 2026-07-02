USE `sql-patterns`;

-- =============================================================================
-- DATE FUNCTIONS IN MySQL 8.0+
-- Database: sql-patterns
-- Topics: Current date/time, arithmetic, DATEDIFF, extraction, formatting,
--         truncation, LAST_DAY, STR_TO_DATE, UNIX timestamps, range filtering,
--         TIMESTAMPDIFF, index-safe range queries, future dates, NULL dates
-- Reference date for calculations: 2024-12-31
-- =============================================================================


-- -----------------------------------------------------------------------------
-- 1. CURRENT DATE AND TIME FUNCTIONS
-- -----------------------------------------------------------------------------

SELECT
    CURDATE()        AS today,            -- DATE:     e.g. 2024-12-31
    NOW()            AS now_local,        -- DATETIME: e.g. 2024-12-31 14:30:00
    CURTIME()        AS current_time,     -- TIME:     e.g. 14:30:00
    UTC_TIMESTAMP()  AS utc_now,          -- DATETIME in UTC
    SYSDATE()        AS sysdate_now;      -- Like NOW() but evaluated at call time (differs inside stored procedures)
-- Use CURDATE() for date-only comparisons; NOW() when time component matters


-- -----------------------------------------------------------------------------
-- 2. DATE ARITHMETIC: DATE_ADD / DATE_SUB WITH INTERVAL
-- -----------------------------------------------------------------------------

SELECT
    CURDATE()                                    AS base_date,
    DATE_ADD(CURDATE(), INTERVAL 30 DAY)         AS plus_30_days,
    DATE_SUB(CURDATE(), INTERVAL 6 MONTH)        AS minus_6_months,
    DATE_ADD(CURDATE(), INTERVAL 1 YEAR)         AS next_year,
    DATE_ADD('2024-01-31', INTERVAL 1 MONTH)     AS jan31_plus_1mo,  -- 2024-02-29 (leap year)
    DATE_ADD('2023-01-31', INTERVAL 1 MONTH)     AS jan31_2023_plus_1mo; -- 2023-02-28 (clamped)
-- MySQL clamps month-end arithmetic to the last valid day of the resulting month

-- Employees hired more than 5 years ago
SELECT emp_id, first_name, last_name, hire_date
FROM employees
WHERE hire_date <= DATE_SUB(CURDATE(), INTERVAL 5 YEAR)
ORDER BY hire_date;
-- hire_date on or before 2019-12-31


-- -----------------------------------------------------------------------------
-- 3. DATEDIFF AND TIMESTAMPDIFF FOR TENURE
-- -----------------------------------------------------------------------------

-- DATEDIFF: tenure in calendar days
SELECT
    emp_id,
    first_name,
    last_name,
    hire_date,
    DATEDIFF(CURDATE(), hire_date)                      AS tenure_days
FROM employees
ORDER BY tenure_days DESC;
-- Most senior employee at top; emp 41 (hire_date=2025-08-01) → negative tenure_days (future hire)

-- TIMESTAMPDIFF: tenure in whole years/months (handles leap years correctly)
SELECT
    emp_id,
    first_name,
    last_name,
    hire_date,
    TIMESTAMPDIFF(YEAR,  hire_date, CURDATE()) AS tenure_years,
    TIMESTAMPDIFF(MONTH, hire_date, CURDATE()) AS tenure_months,
    TIMESTAMPDIFF(DAY,   hire_date, CURDATE()) AS tenure_days
FROM employees
ORDER BY hire_date;
-- TIMESTAMPDIFF(YEAR,...) is more accurate than DATEDIFF/365 for year calculations


-- -----------------------------------------------------------------------------
-- 4. DATE EXTRACTION FUNCTIONS
-- -----------------------------------------------------------------------------

SELECT
    hire_date,
    YEAR(hire_date)       AS yr,
    MONTH(hire_date)      AS mo,
    DAY(hire_date)        AS dy,
    DAYOFWEEK(hire_date)  AS dow_num,      -- 1=Sunday, 2=Monday, ..., 7=Saturday
    DAYNAME(hire_date)    AS dow_name,     -- 'Monday', 'Tuesday', etc.
    MONTHNAME(hire_date)  AS month_name,   -- 'January', etc.
    QUARTER(hire_date)    AS qtr,          -- 1-4
    WEEK(hire_date)       AS iso_week,     -- ISO week number
    DAYOFYEAR(hire_date)  AS doy           -- 1-366
FROM employees
ORDER BY hire_date
LIMIT 10;


-- -----------------------------------------------------------------------------
-- 5. DATE FORMATTING WITH DATE_FORMAT
-- -----------------------------------------------------------------------------

SELECT
    emp_id,
    hire_date,
    DATE_FORMAT(hire_date, '%Y-%m')            AS year_month,        -- '2021-03'
    DATE_FORMAT(hire_date, '%Y-%m-%d')         AS iso_date,          -- '2021-03-15'
    DATE_FORMAT(hire_date, '%d %b %Y')         AS display_date,      -- '15 Mar 2021'
    DATE_FORMAT(hire_date, '%W, %M %e, %Y')    AS long_format,       -- 'Monday, March 15, 2021'
    DATE_FORMAT(hire_date, '%m/%d/%Y')         AS us_format          -- '03/15/2021'
FROM employees
ORDER BY hire_date
LIMIT 10;


-- -----------------------------------------------------------------------------
-- 6. DATE TRUNCATION (to month-start, week-start)
--    MySQL has no TRUNC() for dates; use DATE_FORMAT to truncate to month
-- -----------------------------------------------------------------------------

SELECT
    hire_date,
    -- Truncate to first of the month
    DATE_FORMAT(hire_date, '%Y-%m-01')                         AS month_start,
    -- Truncate to Monday of the week (ISO: week starts Monday)
    DATE_SUB(hire_date, INTERVAL (DAYOFWEEK(hire_date) + 5) % 7 DAY) AS week_start_monday
FROM employees
ORDER BY hire_date
LIMIT 10;
-- week_start_monday formula: (DAYOFWEEK returns 1=Sun..7=Sat; offset maps to Monday)


-- -----------------------------------------------------------------------------
-- 7. LAST_DAY: LAST DAY OF MONTH FOR A GIVEN DATE
-- -----------------------------------------------------------------------------

SELECT
    hire_date,
    LAST_DAY(hire_date)                                             AS last_of_hire_month,
    LAST_DAY(DATE_ADD(hire_date, INTERVAL 1 MONTH))                 AS last_of_next_month,
    DATEDIFF(LAST_DAY(hire_date), hire_date)                        AS days_remaining_in_month
FROM employees
ORDER BY hire_date
LIMIT 8;


-- -----------------------------------------------------------------------------
-- 8. STR_TO_DATE: PARSE A STRING INTO A DATE
-- -----------------------------------------------------------------------------

SELECT STR_TO_DATE('01/15/2024', '%m/%d/%Y')  AS parsed_us_date;      -- 2024-01-15
SELECT STR_TO_DATE('15-Jan-2024', '%d-%b-%Y') AS parsed_display_date; -- 2024-01-15
SELECT STR_TO_DATE('2024-01-15', '%Y-%m-%d')  AS parsed_iso_date;     -- 2024-01-15 (same as CAST)

-- Practical: compare a string-stored date against a column
SELECT emp_id, hire_date
FROM employees
WHERE hire_date >= STR_TO_DATE('01/01/2023', '%m/%d/%Y');
-- Returns employees hired from 2023 onward


-- -----------------------------------------------------------------------------
-- 9. UNIX TIMESTAMPS
-- -----------------------------------------------------------------------------

SELECT
    hire_date,
    UNIX_TIMESTAMP(hire_date)                         AS unix_ts,           -- seconds since epoch
    FROM_UNIXTIME(UNIX_TIMESTAMP(hire_date))          AS back_to_datetime,  -- roundtrip
    FROM_UNIXTIME(UNIX_TIMESTAMP(hire_date), '%Y-%m') AS formatted_from_unix
FROM employees
ORDER BY hire_date
LIMIT 5;

-- UNIX timestamps are useful for duration math in seconds
SELECT
    event_id,
    event_ts,
    UNIX_TIMESTAMP(event_ts)  AS event_unix
FROM emp_events
ORDER BY event_ts
LIMIT 5;


-- -----------------------------------------------------------------------------
-- 10. DATE COMPARISON AND RANGE FILTERING
-- -----------------------------------------------------------------------------

-- Employees hired in calendar year 2023
SELECT emp_id, first_name, last_name, hire_date
FROM employees
WHERE hire_date BETWEEN '2023-01-01' AND '2023-12-31'
ORDER BY hire_date;

-- Employees hired in last 365 days from reference date 2024-12-31
SELECT emp_id, first_name, last_name, hire_date
FROM employees
WHERE hire_date BETWEEN DATE_SUB('2024-12-31', INTERVAL 365 DAY) AND '2024-12-31'
ORDER BY hire_date;
-- Range: 2023-12-31 to 2024-12-31 (note: 365 days may span a leap year)
-- For "last 12 calendar months" use the pattern in section 11 instead


-- -----------------------------------------------------------------------------
-- 11. RELATIVE DATES: EMPLOYEES HIRED IN THE LAST FULL CALENDAR YEAR (2023)
-- -----------------------------------------------------------------------------

-- Using explicit year boundary (most readable, index-friendly)
SELECT emp_id, first_name, last_name, hire_date
FROM employees
WHERE hire_date >= '2023-01-01'
  AND hire_date <  '2024-01-01'
ORDER BY hire_date;

-- Dynamic version: always returns the previous full calendar year
SELECT emp_id, first_name, last_name, hire_date
FROM employees
WHERE hire_date >= DATE_FORMAT(DATE_SUB(CURDATE(), INTERVAL 1 YEAR), '%Y-01-01')
  AND hire_date <  DATE_FORMAT(CURDATE(), '%Y-01-01')
ORDER BY hire_date;
-- DATE_FORMAT(..., '%Y-01-01') truncates to Jan 1 of that year


-- -----------------------------------------------------------------------------
-- 12. TIMESTAMPDIFF: AGE IN YEARS, MONTHS, DAYS BETWEEN TWO DATES
-- -----------------------------------------------------------------------------

-- Tenure components for each employee
SELECT
    emp_id,
    first_name,
    hire_date,
    TIMESTAMPDIFF(YEAR,  hire_date, '2024-12-31')  AS tenure_years,
    TIMESTAMPDIFF(MONTH, hire_date, '2024-12-31')
        - TIMESTAMPDIFF(YEAR, hire_date, '2024-12-31') * 12  AS remaining_months,
    DATEDIFF('2024-12-31',
        DATE_ADD(hire_date,
            INTERVAL TIMESTAMPDIFF(MONTH, hire_date, '2024-12-31') MONTH
        )
    )                                               AS remaining_days
FROM employees
ORDER BY hire_date;
-- Example: hired 2021-03-15 → 3 years, 9 months, 16 days as of 2024-12-31


-- -----------------------------------------------------------------------------
-- 13. DATE IN WHERE vs FUNCTION-WRAPPED COLUMN
--     Wrapping a column in a function PREVENTS index use
-- -----------------------------------------------------------------------------

-- SLOW: function on indexed column → full table scan
-- EXPLAIN shows type=ALL
SELECT emp_id, hire_date
FROM employees
WHERE YEAR(hire_date) = 2023;

-- FAST: sargable range predicate → index range scan
-- EXPLAIN shows type=range (if hire_date is indexed)
SELECT emp_id, hire_date
FROM employees
WHERE hire_date BETWEEN '2023-01-01' AND '2023-12-31';

-- Same principle for MONTH():
-- SLOW:
SELECT emp_id, hire_date FROM employees WHERE MONTH(hire_date) = 6;
-- FAST (if filtering within a known year):
SELECT emp_id, hire_date FROM employees WHERE hire_date BETWEEN '2024-06-01' AND '2024-06-30';


-- -----------------------------------------------------------------------------
-- 14. HANDLING FUTURE DATES: FLAG EMPLOYEES WHERE hire_date > CURDATE()
-- -----------------------------------------------------------------------------

SELECT
    emp_id,
    first_name,
    last_name,
    hire_date,
    DATEDIFF(hire_date, CURDATE()) AS days_until_start
FROM employees
WHERE hire_date > CURDATE()
ORDER BY hire_date;
-- Expected: emp 41 with hire_date='2025-08-01'
-- days_until_start will be positive (future hire); use this to exclude from active headcount

-- Headcount excluding future hires and terminated employees
SELECT COUNT(*) AS active_headcount
FROM employees
WHERE status = 'Active'
  AND hire_date <= CURDATE();


-- -----------------------------------------------------------------------------
-- 15. NULL DATE HANDLING: termination_date
--     NULL termination_date = still active; NOT NULL = terminated
-- -----------------------------------------------------------------------------

-- Active employees (termination_date IS NULL)
SELECT emp_id, first_name, last_name, hire_date, status
FROM employees
WHERE termination_date IS NULL
ORDER BY hire_date;
-- Expected: 40 rows (all except emp 35 who has a termination_date)

-- Terminated employees
SELECT emp_id, first_name, last_name, hire_date, termination_date,
       DATEDIFF(termination_date, hire_date) AS days_employed
FROM employees
WHERE termination_date IS NOT NULL
ORDER BY termination_date;
-- Expected: emp 35

-- Data quality: employees with status='Terminated' but NULL termination_date
SELECT emp_id, first_name, last_name, status, termination_date
FROM employees
WHERE status = 'Terminated'
  AND termination_date IS NULL;
-- Expected: 0 rows ideally; any result indicates a data quality issue

-- Tenure for active vs terminated (COALESCE termination_date to today for active)
SELECT
    emp_id,
    hire_date,
    termination_date,
    status,
    TIMESTAMPDIFF(YEAR, hire_date,
        COALESCE(termination_date, '2024-12-31')
    )  AS tenure_years
FROM employees
ORDER BY hire_date;
