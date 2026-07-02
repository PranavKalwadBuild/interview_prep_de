-- =============================================================================
-- FILE: 02-percentiles-histograms.sql
-- DATABASE: sql-patterns
-- PURPOSE: Statistical distributions for salary and categorical columns.
--          Covers descriptive stats, median, percentiles, IQR outlier detection,
--          histograms, NTILE buckets, frequency distributions, and mode.
-- MYSQL NOTES:
--   No PERCENTILE_CONT / PERCENTILE_DISC — use ROW_NUMBER + COUNT approach.
--   No STDDEV_POP in window frame — use standalone aggregate STDDEV_POP(col).
--   NTILE in MySQL orders NULLs first (ASC); filter NULLs before NTILE.
--   GROUP_CONCAT instead of STRING_AGG.
-- =============================================================================

USE `sql-patterns`;

-- =============================================================================
-- SECTION 1: DESCRIPTIVE STATISTICS (MIN, MAX, AVG, STDDEV)
-- =============================================================================

-- 1a. With NULLs replaced by 0 via COALESCE — distorts mean/stddev downward
SELECT
    COUNT(*)                            AS total_employees,
    MIN(COALESCE(salary, 0))            AS min_salary_incl_null,
    MAX(COALESCE(salary, 0))            AS max_salary_incl_null,
    ROUND(AVG(COALESCE(salary, 0)), 2)  AS avg_salary_incl_null,
    ROUND(STDDEV_POP(COALESCE(salary, 0)), 2) AS stddev_incl_null
FROM employees;
-- Note: treating NULL as 0 suppresses missing data but skews all statistics.

-- 1b. Excluding NULLs — honest statistics on employees who have a salary on record
SELECT
    COUNT(*)                            AS total_employees,
    COUNT(salary)                       AS employees_with_salary,
    COUNT(*) - COUNT(salary)            AS employees_null_salary,
    MIN(salary)                         AS min_salary,
    MAX(salary)                         AS max_salary,
    ROUND(AVG(salary), 2)               AS avg_salary,
    ROUND(STDDEV_POP(salary), 2)        AS stddev_salary,
    ROUND(STDDEV_POP(salary) / AVG(salary) * 100, 1)
                                        AS coeff_of_variation_pct
    -- median: see Section 2
FROM employees
WHERE salary IS NOT NULL;
-- COUNT(salary) automatically skips NULLs; COUNT(*) counts every row.


-- =============================================================================
-- SECTION 2: MEDIAN SALARY (ROW_NUMBER + COUNT approach)
-- =============================================================================
-- MySQL has no PERCENTILE_CONT. Strategy:
--   1. Rank every non-NULL salary row with ROW_NUMBER().
--   2. Record total count (COUNT(*) OVER ()).
--   3. Identify the one or two middle positions: FLOOR((n+1)/2) and CEIL((n+1)/2).
--   4. AVG of those positions handles both odd (same row twice) and even (two rows).

WITH ranked AS (
    SELECT
        salary,
        ROW_NUMBER() OVER (ORDER BY salary)   AS rn,
        COUNT(*)     OVER ()                  AS total
    FROM employees
    WHERE salary IS NOT NULL
)
SELECT
    ROUND(AVG(salary), 2) AS median_salary
FROM ranked
WHERE rn IN (FLOOR((total + 1) / 2), CEIL((total + 1) / 2));
-- For 39 non-NULL rows (41 - 2 NULLs): middle positions are 20 and 20 (same) → row 20.
-- For even n: positions differ by 1 → AVG of the two middle values.


-- =============================================================================
-- SECTION 3: PERCENTILES AT P25, P50, P75, P90
-- =============================================================================
-- Generic approach: CEIL(p * n) gives the row index for the p-th percentile.
-- MAX(CASE WHEN rn <= threshold THEN salary END) returns the value at that position.

WITH ranked AS (
    SELECT
        salary,
        ROW_NUMBER() OVER (ORDER BY salary) AS rn,
        COUNT(*)     OVER ()                AS n
    FROM employees
    WHERE salary IS NOT NULL
)
SELECT
    MAX(CASE WHEN rn <= CEIL(0.25 * n) THEN salary END) AS p25,
    MAX(CASE WHEN rn <= CEIL(0.50 * n) THEN salary END) AS p50,
    MAX(CASE WHEN rn <= CEIL(0.75 * n) THEN salary END) AS p75,
    MAX(CASE WHEN rn <= CEIL(0.90 * n) THEN salary END) AS p90,
    MAX(salary)                                          AS p100_max
FROM ranked;
-- p50 == median from Section 2 (minor rounding differences possible at boundaries).


-- =============================================================================
-- SECTION 4: IQR AND OUTLIER DETECTION
-- =============================================================================
-- IQR = Q3 - Q1
-- Lower fence = Q1 - 1.5 * IQR   (Tukey rule)
-- Upper fence = Q3 + 1.5 * IQR
-- Rows outside fences are statistical outliers.

WITH ranked AS (
    SELECT
        emp_id,
        first_name,
        last_name,
        salary,
        ROW_NUMBER() OVER (ORDER BY salary) AS rn,
        COUNT(*)     OVER ()                AS n
    FROM employees
    WHERE salary IS NOT NULL
),
quartiles AS (
    SELECT
        MAX(CASE WHEN rn <= CEIL(0.25 * n) THEN salary END) AS q1,
        MAX(CASE WHEN rn <= CEIL(0.75 * n) THEN salary END) AS q3
    FROM ranked
),
fences AS (
    SELECT
        q1,
        q3,
        q3 - q1                    AS iqr,
        q1 - 1.5 * (q3 - q1)      AS lower_fence,
        q3 + 1.5 * (q3 - q1)      AS upper_fence
    FROM quartiles
)
SELECT
    r.emp_id,
    r.first_name,
    r.last_name,
    r.salary,
    f.q1,
    f.q3,
    f.iqr,
    ROUND(f.lower_fence, 2)        AS lower_fence,
    ROUND(f.upper_fence, 2)        AS upper_fence,
    CASE
        WHEN r.salary < f.lower_fence THEN 'LOW OUTLIER'
        WHEN r.salary > f.upper_fence THEN 'HIGH OUTLIER'
        ELSE 'normal'
    END                            AS outlier_flag
FROM ranked r
CROSS JOIN fences f
WHERE r.salary < f.lower_fence
   OR r.salary > f.upper_fence
ORDER BY r.salary DESC;
-- Expected high outliers: emp 1 (350k) and emp 2 (280k) vs median ~115k.
-- Expected low outlier:   emp 19 (salary=0.00).

-- Companion: show fence values alone for context
WITH ranked AS (
    SELECT salary,
           ROW_NUMBER() OVER (ORDER BY salary) AS rn,
           COUNT(*)     OVER ()                AS n
    FROM employees WHERE salary IS NOT NULL
),
quartiles AS (
    SELECT
        MAX(CASE WHEN rn <= CEIL(0.25 * n) THEN salary END) AS q1,
        MAX(CASE WHEN rn <= CEIL(0.75 * n) THEN salary END) AS q3
    FROM ranked
)
SELECT
    q1,
    q3,
    q3 - q1                 AS iqr,
    q1 - 1.5*(q3-q1)        AS lower_fence,
    q3 + 1.5*(q3-q1)        AS upper_fence
FROM quartiles;


-- =============================================================================
-- SECTION 5: HISTOGRAM / BUCKET DISTRIBUTION
-- =============================================================================

-- 5a. Salary histogram with fixed-width bands
--     NULL rows included separately so the total adds up.
SELECT
    CASE
        WHEN salary IS NULL          THEN 'NULL (unknown)'
        WHEN salary <   80000        THEN '< 80k'
        WHEN salary <  100000        THEN '80k–100k'
        WHEN salary <  130000        THEN '100k–130k'
        WHEN salary <  180000        THEN '130k–180k'
        WHEN salary <  250000        THEN '180k–250k'
        ELSE                              '>= 250k'
    END                                              AS salary_band,
    COUNT(*)                                         AS emp_count,
    ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER (), 1) AS pct
FROM employees
GROUP BY salary_band
ORDER BY MIN(COALESCE(salary, -1));
-- Ordering by MIN(salary) within each band keeps bands in ascending order.
-- emp 19 (salary=0) falls into '< 80k'; emp 10,15 (NULL) appear in 'NULL (unknown)'.

-- 5b. Purchase order amount histogram — variable-width buckets to show skew
SELECT
    CASE
        WHEN amount <  10000   THEN '< 10k'
        WHEN amount <  25000   THEN '10k–25k'
        WHEN amount <  50000   THEN '25k–50k'
        WHEN amount <  75000   THEN '50k–75k'
        ELSE                        '>= 75k'
    END                                              AS amount_band,
    COUNT(*)                                         AS order_count,
    ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER (), 1) AS pct,
    ROUND(MIN(amount), 0)                            AS band_min,
    ROUND(MAX(amount), 0)                            AS band_max
FROM purchase_orders
GROUP BY amount_band
ORDER BY MIN(amount);
-- Most orders cluster in lower bands; a few 85k–90k orders surface as outliers.


-- =============================================================================
-- SECTION 6: NTILE BUCKETS (QUARTILES AND DECILES)
-- =============================================================================
-- NTILE splits ordered rows into N equal-sized buckets.
-- In MySQL, NULLs sort first in ASC ORDER BY, landing in bucket 1.
-- Best practice: filter NULLs before NTILE to get clean bucket labels.

-- 6a. Quartile (Q1–Q4) per employee
SELECT
    emp_id,
    first_name,
    last_name,
    salary,
    NTILE(4) OVER (ORDER BY salary)  AS quartile   -- 1=bottom 25%, 4=top 25%
FROM employees
WHERE salary IS NOT NULL
ORDER BY salary;

-- 6b. Average salary per quartile bucket
WITH bucketed AS (
    SELECT
        salary,
        NTILE(4) OVER (ORDER BY salary) AS quartile
    FROM employees
    WHERE salary IS NOT NULL
)
SELECT
    quartile,
    COUNT(*)            AS emp_count,
    ROUND(MIN(salary))  AS min_salary,
    ROUND(MAX(salary))  AS max_salary,
    ROUND(AVG(salary))  AS avg_salary
FROM bucketed
GROUP BY quartile
ORDER BY quartile;

-- 6c. Decile (D1–D10) per employee
SELECT
    emp_id,
    first_name,
    last_name,
    salary,
    NTILE(10) OVER (ORDER BY salary) AS decile
FROM employees
WHERE salary IS NOT NULL
ORDER BY salary;

-- 6d. Average salary per decile
WITH bucketed AS (
    SELECT
        salary,
        NTILE(10) OVER (ORDER BY salary) AS decile
    FROM employees
    WHERE salary IS NOT NULL
)
SELECT
    decile,
    COUNT(*)            AS emp_count,
    ROUND(MIN(salary))  AS min_salary,
    ROUND(MAX(salary))  AS max_salary,
    ROUND(AVG(salary))  AS avg_salary
FROM bucketed
GROUP BY decile
ORDER BY decile;


-- =============================================================================
-- SECTION 7: FREQUENCY DISTRIBUTION (CATEGORICAL COLUMNS)
-- =============================================================================

-- 7a. Performance review rating distribution (1–5 scale, with NULLs)
SELECT
    COALESCE(CAST(rating AS CHAR), 'NULL') AS rating,
    COUNT(*)                                AS cnt,
    ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER (), 1) AS pct
FROM performance_reviews
GROUP BY rating
ORDER BY rating;

-- 7b. Leave type distribution including NULL (request 11 has NULL leave_type)
SELECT
    COALESCE(leave_type, 'NULL/Unknown')   AS leave_type,
    COUNT(*)                                AS cnt,
    ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER (), 1) AS pct
FROM leave_requests
GROUP BY leave_type
ORDER BY cnt DESC;

-- 7c. Employee status distribution
SELECT
    status,
    COUNT(*)                                AS cnt,
    ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER (), 1) AS pct
FROM employees
GROUP BY status
ORDER BY cnt DESC;

-- 7d. Purchase order status distribution
SELECT
    status,
    COUNT(*)                                AS cnt,
    ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER (), 1) AS pct
FROM purchase_orders
GROUP BY status
ORDER BY cnt DESC;


-- =============================================================================
-- SECTION 8: MODE (MOST FREQUENT VALUE)
-- =============================================================================
-- MySQL has no MODE() aggregate. Pattern: GROUP BY → ORDER BY COUNT DESC → LIMIT 1.

-- 8a. Mode salary (most common exact salary amount)
SELECT
    salary,
    COUNT(*) AS frequency
FROM employees
WHERE salary IS NOT NULL
GROUP BY salary
ORDER BY frequency DESC, salary DESC
LIMIT 1;
-- If multiple salaries tie, return the highest (or use LIMIT 5 to see top modes).

-- 8b. Mode review rating
SELECT
    rating,
    COUNT(*) AS frequency
FROM performance_reviews
WHERE rating IS NOT NULL
GROUP BY rating
ORDER BY frequency DESC
LIMIT 1;

-- 8c. Top-5 salary modes (ties visible)
SELECT
    salary,
    COUNT(*) AS frequency
FROM employees
WHERE salary IS NOT NULL
GROUP BY salary
ORDER BY frequency DESC, salary DESC
LIMIT 5;


-- =============================================================================
-- SECTION 9: PURCHASE ORDER AMOUNT DISTRIBUTION
-- =============================================================================

-- 9a. Full descriptive statistics for purchase_orders.amount
SELECT
    COUNT(*)                            AS total_orders,
    ROUND(MIN(amount), 2)               AS min_amount,
    ROUND(MAX(amount), 2)               AS max_amount,
    ROUND(AVG(amount), 2)               AS avg_amount,
    ROUND(STDDEV_POP(amount), 2)        AS stddev_amount,
    ROUND(STDDEV_POP(amount) / AVG(amount) * 100, 1)
                                        AS coeff_of_variation_pct
    -- High CV (> 100%) = highly skewed distribution
FROM purchase_orders;

-- 9b. Histogram of purchase order amounts by dynamic-width buckets
SELECT
    CASE
        WHEN amount <   5000  THEN 'A: < 5k'
        WHEN amount <  15000  THEN 'B: 5k–15k'
        WHEN amount <  30000  THEN 'C: 15k–30k'
        WHEN amount <  50000  THEN 'D: 30k–50k'
        WHEN amount <  75000  THEN 'E: 50k–75k'
        ELSE                       'F: >= 75k'
    END                                               AS amount_band,
    COUNT(*)                                          AS order_count,
    ROUND(SUM(amount))                                AS total_spend,
    ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER (), 1) AS pct_of_orders,
    ROUND(SUM(amount) * 100.0 / SUM(SUM(amount)) OVER (), 1) AS pct_of_spend
FROM purchase_orders
GROUP BY amount_band
ORDER BY amount_band;
-- Skew expected: most orders are small-to-mid range, but a few large orders
-- in band F drive disproportionate total spend (Pareto/80-20 pattern).

-- 9c. Percentile breakdown for purchase order amounts
WITH ranked AS (
    SELECT
        amount,
        ROW_NUMBER() OVER (ORDER BY amount) AS rn,
        COUNT(*)     OVER ()                AS n
    FROM purchase_orders
)
SELECT
    MAX(CASE WHEN rn <= CEIL(0.25 * n) THEN amount END) AS p25,
    MAX(CASE WHEN rn <= CEIL(0.50 * n) THEN amount END) AS p50_median,
    MAX(CASE WHEN rn <= CEIL(0.75 * n) THEN amount END) AS p75,
    MAX(CASE WHEN rn <= CEIL(0.90 * n) THEN amount END) AS p90,
    MAX(CASE WHEN rn <= CEIL(0.95 * n) THEN amount END) AS p95,
    MAX(amount)                                          AS max_amount
FROM ranked;
