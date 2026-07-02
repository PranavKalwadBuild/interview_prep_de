USE `sql-patterns`;

-- ============================================================
-- FILE: 09-cohort-funnel/01-cohort-analysis.sql
-- DATABASE: sql-patterns
-- TOPIC: Cohort Analysis — hire-year cohorts, retention via
--        performance reviews, attrition, department spread,
--        review latency, salary growth
-- KEY FLAWS IN DATA:
--   emp 41   hire_date = '2025-08-01'  (future — lands in 2025 cohort)
--   emp 35   status = 'Terminated'     (2020 cohort member, left 2024-03-31)
--   emp 15   hire_date = '2024-01-10'  (mixed: counted in 2024, not 2023)
--   salary_history  salary_before NULL = initial hire entry
--   Only 13 distinct employees have performance_reviews at all
-- ============================================================


-- ============================================================
-- 1. COHORT DEFINITION BY HIRE YEAR
-- Group employees by YEAR(hire_date) and count cohort size.
-- emp 41 (hire_date 2025-08-01) surfaces as a future cohort —
-- flagged with a data_flaw column.
-- ============================================================

SELECT
    YEAR(hire_date)                                     AS cohort_year,
    COUNT(*)                                            AS cohort_size,
    GROUP_CONCAT(emp_id ORDER BY emp_id SEPARATOR ', ') AS emp_ids,
    CASE
        WHEN MAX(hire_date) > CURDATE() THEN 'FLAW: future hire_date'
        ELSE 'OK'
    END                                                 AS data_flaw
FROM employees
GROUP BY YEAR(hire_date)
ORDER BY cohort_year;

-- Expected: 11 rows (2015-2025)
-- 2025 row: cohort_size=1, emp_ids='41', data_flaw='FLAW: future hire_date'
-- Largest cohort: 2021 with 6 employees (emp 9,14,17,23,28,34)


-- ============================================================
-- 2. COHORT RETENTION GRID VIA PERFORMANCE REVIEWS
-- "Retained in period X" = employee received a review in that period.
-- cohort_year | members | reviewed_2023H1 | reviewed_2023H2 | reviewed_2024H1
--           | pct_2023H1 | pct_2023H2 | pct_2024H1
-- Only 13 distinct employees have reviews; most cohorts show 0 for 2024-H1.
-- ============================================================

WITH cohort AS (
    SELECT
        emp_id,
        YEAR(hire_date) AS cohort_year
    FROM employees
),
reviews AS (
    SELECT DISTINCT emp_id, review_period
    FROM performance_reviews
)
SELECT
    c.cohort_year,
    COUNT(DISTINCT c.emp_id)                                     AS members,
    COUNT(DISTINCT CASE WHEN r23h1.emp_id IS NOT NULL
                        THEN c.emp_id END)                       AS reviewed_2023H1,
    COUNT(DISTINCT CASE WHEN r23h2.emp_id IS NOT NULL
                        THEN c.emp_id END)                       AS reviewed_2023H2,
    COUNT(DISTINCT CASE WHEN r24h1.emp_id IS NOT NULL
                        THEN c.emp_id END)                       AS reviewed_2024H1,
    ROUND(
        COUNT(DISTINCT CASE WHEN r23h1.emp_id IS NOT NULL
                            THEN c.emp_id END)
        / COUNT(DISTINCT c.emp_id) * 100, 1)                    AS pct_2023H1,
    ROUND(
        COUNT(DISTINCT CASE WHEN r23h2.emp_id IS NOT NULL
                            THEN c.emp_id END)
        / COUNT(DISTINCT c.emp_id) * 100, 1)                    AS pct_2023H2,
    ROUND(
        COUNT(DISTINCT CASE WHEN r24h1.emp_id IS NOT NULL
                            THEN c.emp_id END)
        / COUNT(DISTINCT c.emp_id) * 100, 1)                    AS pct_2024H1
FROM cohort c
LEFT JOIN reviews r23h1 ON c.emp_id = r23h1.emp_id
    AND r23h1.review_period = '2023-H1'
LEFT JOIN reviews r23h2 ON c.emp_id = r23h2.emp_id
    AND r23h2.review_period = '2023-H2'
LEFT JOIN reviews r24h1 ON c.emp_id = r24h1.emp_id
    AND r24h1.review_period = '2024-H1'
GROUP BY c.cohort_year
ORDER BY c.cohort_year;

-- Expected highlights:
--   2015 cohort (3 members): emp 1 no reviews; emp 33 has 2023-H2 review
--   2021 cohort (6 members): emp 9 reviewed in 2023-H1 and 2023-H2
--   2024-H1: only emp 5 (2018 cohort) — pct_2024H1 = 0% for all others
--   Cohorts 2022-2025 have low/zero review coverage (expected for newer hires)


-- ============================================================
-- 3. MONTH-BASED COHORT WITH STATUS BREAKDOWN
-- Cohort = DATE_FORMAT(hire_date, '%Y-%m')
-- Show cohort_month, cohort_size, active_count, terminated_count.
-- 2020-02 cohort contains emp 35 (Terminated 2024-03-31).
-- ============================================================

SELECT
    DATE_FORMAT(hire_date, '%Y-%m')          AS cohort_month,
    COUNT(*)                                 AS cohort_size,
    SUM(CASE WHEN status = 'Active'
             THEN 1 ELSE 0 END)              AS active_count,
    SUM(CASE WHEN status = 'Terminated'
             THEN 1 ELSE 0 END)              AS terminated_count,
    GROUP_CONCAT(
        CONCAT(emp_id, ':', status)
        ORDER BY emp_id SEPARATOR ' | ')     AS emp_status_detail
FROM employees
GROUP BY DATE_FORMAT(hire_date, '%Y-%m')
ORDER BY cohort_month;

-- Expected:
--   2020-02 row: cohort_size=1, terminated_count=1 → emp 35 Terminated
--   Most months: single-employee cohorts; some months have 2-3 hires
--   2025-08: emp 41 — Active but hire_date is future (data flaw)


-- ============================================================
-- 4. COHORT RETENTION RATE — ACTIVE VS TERMINATED
-- For each hire_year cohort: count Active vs Terminated employees.
-- Retention rate = Active / Total per cohort.
-- emp 35 (2020 cohort) is the only terminated employee.
-- ============================================================

SELECT
    YEAR(hire_date)                              AS cohort_year,
    COUNT(*)                                     AS total_hired,
    SUM(CASE WHEN status = 'Active'
             THEN 1 ELSE 0 END)                  AS still_active,
    SUM(CASE WHEN status = 'Terminated'
             THEN 1 ELSE 0 END)                  AS terminated,
    ROUND(
        SUM(CASE WHEN status = 'Active' THEN 1 ELSE 0 END)
        / COUNT(*) * 100, 1)                     AS retention_pct
FROM employees
GROUP BY YEAR(hire_date)
ORDER BY cohort_year;

-- Expected:
--   Only 2020 cohort has terminated_count > 0 (emp 35)
--   2020: total=4, still_active=3, terminated=1, retention_pct=75.0
--   All other cohorts: retention_pct=100.0
--   2025 cohort (emp 41): retention_pct=100.0 despite future hire_date (still Active)


-- ============================================================
-- 5. DEPARTMENT COHORT ANALYSIS — HIRES PER YEAR PER DEPT
-- One row per cohort_year; one column per department.
-- dept_id mapping: 1=Engineering, 2=Sales, 3=Marketing,
--                  4=HR, 5=Finance, 6=Operations, 7=Executive
-- Uses conditional aggregation — MySQL-compatible pivot substitute.
-- ============================================================

SELECT
    YEAR(hire_date)                                                AS cohort_year,
    COUNT(*)                                                       AS total_hires,
    SUM(CASE WHEN dept_id = 1 THEN 1 ELSE 0 END)                  AS engineering,
    SUM(CASE WHEN dept_id = 2 THEN 1 ELSE 0 END)                  AS sales,
    SUM(CASE WHEN dept_id = 3 THEN 1 ELSE 0 END)                  AS marketing,
    SUM(CASE WHEN dept_id = 4 THEN 1 ELSE 0 END)                  AS hr,
    SUM(CASE WHEN dept_id = 5 THEN 1 ELSE 0 END)                  AS finance,
    SUM(CASE WHEN dept_id = 6 THEN 1 ELSE 0 END)                  AS operations,
    SUM(CASE WHEN dept_id = 7 THEN 1 ELSE 0 END)                  AS executive
FROM employees
GROUP BY YEAR(hire_date)
ORDER BY cohort_year;

-- Expected:
--   Engineering column dominates most years (36% skew noted in schema)
--   2015: executive=1 (emp 1 CEO), plus engineering hires
--   2021 cohort (6 hires): highest single-year total


-- ============================================================
-- 6. FIRST PERFORMANCE REVIEW LATENCY
-- Days between hire_date and an employee's first review_date.
-- Employees with no reviews: NULL days_to_first_review.
-- Only 13 distinct employees have reviews at all.
-- ============================================================

WITH first_review AS (
    SELECT
        emp_id,
        MIN(review_date) AS first_review_date
    FROM performance_reviews
    GROUP BY emp_id
)
SELECT
    e.emp_id,
    CONCAT(e.first_name, ' ', e.last_name)          AS full_name,
    YEAR(e.hire_date)                                AS cohort_year,
    e.hire_date,
    fr.first_review_date,
    DATEDIFF(fr.first_review_date, e.hire_date)      AS days_to_first_review
FROM employees e
LEFT JOIN first_review fr ON e.emp_id = fr.emp_id
ORDER BY days_to_first_review NULLS LAST, e.emp_id;

-- Expected:
--   28 employees with NULL days_to_first_review (no reviews on record)
--   13 employees with a review date
--   Longer tenure employees (2015-2018 cohorts) have higher latency values
--   Average latency query below:

SELECT
    ROUND(AVG(DATEDIFF(fr.first_review_date, e.hire_date)), 1)  AS avg_days_to_first_review,
    MIN(DATEDIFF(fr.first_review_date, e.hire_date))             AS min_days,
    MAX(DATEDIFF(fr.first_review_date, e.hire_date))             AS max_days,
    COUNT(fr.emp_id)                                             AS employees_with_review
FROM employees e
INNER JOIN (
    SELECT emp_id, MIN(review_date) AS first_review_date
    FROM performance_reviews
    GROUP BY emp_id
) fr ON e.emp_id = fr.emp_id;

-- Expected: count=13 (distinct employees with any review)
-- Long-tenured employees (2015 cohort) will have the highest day counts


-- ============================================================
-- 7. COHORT SALARY GROWTH (2015 AND 2016 COHORTS)
-- Compare average initial salary (salary_before IS NULL in salary_history)
-- vs average current salary (employees.salary) for 2015 and 2016 hires.
-- Growth multiple = current_avg / initial_avg.
-- salary_before IS NULL flags the hire-in entry for each employee.
-- ============================================================

WITH initial_salary AS (
    SELECT
        sh.emp_id,
        sh.salary_after AS starting_salary
    FROM salary_history sh
    WHERE sh.salary_before IS NULL   -- initial hire entry
),
early_cohorts AS (
    SELECT
        e.emp_id,
        YEAR(e.hire_date)  AS cohort_year,
        e.salary           AS current_salary,
        ish.starting_salary
    FROM employees e
    LEFT JOIN initial_salary ish ON e.emp_id = ish.emp_id
    WHERE YEAR(e.hire_date) IN (2015, 2016)
)
SELECT
    cohort_year,
    COUNT(emp_id)                                             AS cohort_size,
    ROUND(AVG(starting_salary), 2)                           AS avg_starting_salary,
    ROUND(AVG(current_salary), 2)                            AS avg_current_salary,
    ROUND(AVG(current_salary) / NULLIF(AVG(starting_salary), 0), 2)
                                                             AS growth_multiple
FROM early_cohorts
GROUP BY cohort_year
ORDER BY cohort_year;

-- Expected:
--   2015 cohort (3 members): avg_current_salary higher than avg_starting_salary
--   2016 cohort (4 members): similar growth pattern
--   growth_multiple > 1.0 for both cohorts (salary increased over ~9-10 years)
--   NULL current_salary employees excluded from AVG automatically
