-- ============================================================
-- 08-dimension-types / 01-dimension-types.sql
-- Database: dm_warehouse
--
-- Demonstrates six dimension design patterns using the
-- employee/HR warehouse schema.
--
-- Sections:
--   1. Conformed Dimension    — dim_department (shared across facts)
--   2. Junk Dimension         — dim_employee_flags (boolean flags)
--   3. Role-Playing Dimension — dim_date (multiple aliases per query)
--   4. Degenerate Dimension   — leave_request_id, review_id in facts
--   5. Bridge Table           — bridge_emp_project (M:N relationship)
--   6. Calendar Dimension     — dim_date seed + gap detection
-- ============================================================

USE dm_warehouse;

-- ─────────────────────────────────────────────────────────────
-- SECTION 1: CONFORMED DIMENSION — dim_department
-- ─────────────────────────────────────────────────────────────
--
-- dim_department.dept_sk appears as a foreign key in:
--   fact_salary_payment      (dept_sk)
--   fact_monthly_headcount   (dept_sk)
--   fact_performance_review  (dept_sk)
--   fact_leave_lifecycle     (dept_sk)
--
-- SAME physical table, SAME surrogate keys, SAME attributes.
-- This enables "drill-across" queries that JOIN multiple fact
-- tables through one shared dimension — no translation layer needed.
--
-- Non-conformed anti-pattern: if each fact had its own
-- dept_id column mapped to a different lookup table with
-- different names or granularities, a cross-fact query would
-- require complex reconciliation logic and could produce
-- double-counted or mismatched results.
-- ─────────────────────────────────────────────────────────────

-- 1a. Prove conformance: dim_department keys appear in all three fact tables
SELECT
    dd.dept_name,
    -- From transaction fact
    COALESCE(sp.total_payroll, 0)        AS monthly_payroll,
    -- From periodic snapshot
    COALESCE(hc.headcount, 0)            AS snapshot_headcount,
    COALESCE(hc.avg_salary, 0)           AS snapshot_avg_salary,
    -- From transaction fact (performance)
    COALESCE(pr.review_count, 0)         AS reviews_this_year
FROM dim_department dd
-- Transaction fact: salary for a specific month
LEFT JOIN (
    SELECT dept_sk, SUM(salary_amount) AS total_payroll
    FROM fact_salary_payment
    WHERE pay_year = 2024 AND pay_month = 6
    GROUP BY dept_sk
) sp ON dd.dept_sk = sp.dept_sk
-- Periodic snapshot: headcount for same month
LEFT JOIN (
    SELECT dept_sk, headcount, avg_salary
    FROM fact_monthly_headcount
    WHERE snapshot_year = 2024 AND snapshot_month = 6
) hc ON dd.dept_sk = hc.dept_sk
-- Transaction fact: review count for full year
LEFT JOIN (
    SELECT dept_sk, COUNT(*) AS review_count
    FROM fact_performance_review
    WHERE review_date_sk BETWEEN 20240101 AND 20241231
    GROUP BY dept_sk
) pr ON dd.dept_sk = pr.dept_sk
ORDER BY dd.dept_name;

-- 1b. Drill-across: average salary vs average review rating per department
--     Only possible because dim_department is conformed across both facts.
SELECT
    dd.dept_name,
    AVG(sp.salary_amount)   AS avg_salary,
    AVG(pr.rating)          AS avg_review_rating,
    COUNT(DISTINCT sp.employee_sk) AS headcount
FROM dim_department          dd
LEFT JOIN fact_salary_payment       sp ON dd.dept_sk = sp.dept_sk
                                      AND sp.pay_year = 2024
LEFT JOIN fact_performance_review   pr ON dd.dept_sk = pr.dept_sk
GROUP BY dd.dept_name
ORDER BY avg_review_rating DESC;


-- ─────────────────────────────────────────────────────────────
-- SECTION 2: JUNK DIMENSION — dim_employee_flags
-- ─────────────────────────────────────────────────────────────
--
-- Combines 5 low-cardinality boolean flags that don't belong to
-- any single business entity:
--   is_contractor    — employee vs contractor
--   is_terminated    — employment status flag
--   is_future_hire   — hire date is in the future
--   has_null_salary  — salary is NULL in source (emp 10, 15)
--   has_null_email   — email is NULL in source (emp 22)
--
-- WITHOUT a junk dimension, fact_salary_payment would carry 5
-- nullable boolean columns, and every query filtering on any
-- combination would need to handle NULLs inline. The junk dim
-- pre-enumerates all meaningful combinations and gives each a
-- single surrogate key.
--
-- With 5 binary flags: max 2^5 = 32 possible combinations.
-- In practice far fewer combinations are valid. The junk dim
-- table will have only as many rows as there are real combinations.
-- ─────────────────────────────────────────────────────────────

-- 2a. Seed the junk dimension with the combinations present in the dataset
INSERT INTO dim_employee_flags
    (is_contractor, is_terminated, is_future_hire, has_null_salary, has_null_email, flag_description)
VALUES
    (0, 0, 0, 0, 0, 'Normal active employee'),
    (1, 0, 0, 0, 0, 'Contractor — no salary'),
    (0, 0, 0, 1, 0, 'Active employee — NULL salary in source'),
    (0, 0, 0, 0, 1, 'Active employee — NULL email in source'),
    (0, 1, 0, 0, 0, 'Terminated employee'),
    (0, 0, 1, 0, 0, 'Future hire — hire date > today'),
    (1, 0, 0, 1, 0, 'Contractor — NULL salary (expected)'),
    (0, 1, 0, 0, 1, 'Terminated — NULL email');

-- 2b. Distribution of employees by flag combination
SELECT
    ef.flag_description,
    ef.is_contractor,
    ef.is_terminated,
    ef.is_future_hire,
    ef.has_null_salary,
    ef.has_null_email,
    COUNT(de.employee_sk)   AS employee_count
FROM dim_employee_flags ef
LEFT JOIN dim_employee  de ON ef.flag_sk = de.flag_sk
                           AND de.is_current = 1
GROUP BY
    ef.flag_sk,
    ef.flag_description,
    ef.is_contractor,
    ef.is_terminated,
    ef.is_future_hire,
    ef.has_null_salary,
    ef.has_null_email
ORDER BY employee_count DESC;

-- 2c. Find employees with data quality flags (NULL salary or NULL email)
--     Without junk dim: WHERE salary IS NULL OR email IS NULL (inline in fact)
--     With junk dim: clean single-column filter on flag_sk
SELECT
    de.emp_id,
    de.first_name,
    de.last_name,
    ef.flag_description,
    ef.has_null_salary,
    ef.has_null_email
FROM dim_employee       de
JOIN dim_employee_flags ef ON de.flag_sk = ef.flag_sk
WHERE (ef.has_null_salary = 1 OR ef.has_null_email = 1)
  AND de.is_current = 1;

-- 2d. What NOT to put in a junk dimension
--     High-cardinality attributes (department name, job title, city) belong
--     in their own full dimension table. Junk dims are for low-cardinality
--     flags and indicators only — typically 2-10 possible values per attribute.


-- ─────────────────────────────────────────────────────────────
-- SECTION 3: ROLE-PLAYING DIMENSION — dim_date
-- ─────────────────────────────────────────────────────────────
--
-- dim_date is the single physical calendar table. It appears in
-- fact_leave_lifecycle four times, each representing a different
-- business role:
--
--   submit_date_sk  → "the date the request was submitted"
--   approve_date_sk → "the date the request was approved"
--   start_date_sk   → "the date the leave period begins"
--   end_date_sk     → "the date the leave period ends"
--
-- In a single query, dim_date is aliased with a different name
-- for each role. Each alias gives the same physical columns
-- but interpreted with a different business meaning.
--
-- BI tool note: some tools (Tableau, Power BI) require creating
-- a named VIEW for each role (e.g., CREATE VIEW dim_submit_date AS
-- SELECT * FROM dim_date) to expose each role as a separate logical
-- table in the semantic layer.
-- ─────────────────────────────────────────────────────────────

-- 3a. Four aliases of dim_date in one query
SELECT
    de.first_name,
    de.last_name,
    dd.dept_name,
    fll.leave_request_id,
    fll.leave_type,
    fll.current_status,
    submit.date_actual   AS submitted_on,
    approved.date_actual AS approved_on,
    lv_start.date_actual AS leave_starts,
    lv_end.date_actual   AS leave_ends,
    fll.duration_days,
    fll.days_to_decision
FROM fact_leave_lifecycle fll
JOIN dim_date             submit   ON fll.submit_date_sk  = submit.date_sk
LEFT JOIN dim_date        approved ON fll.approve_date_sk = approved.date_sk
LEFT JOIN dim_date        lv_start ON fll.start_date_sk   = lv_start.date_sk
LEFT JOIN dim_date        lv_end   ON fll.end_date_sk     = lv_end.date_sk
JOIN dim_employee         de       ON fll.employee_sk     = de.employee_sk
JOIN dim_department       dd       ON fll.dept_sk         = dd.dept_sk
WHERE de.is_current = 1
ORDER BY submitted_on DESC;

-- 3b. Role-playing in fact_performance_review:
--     reviewer_sk is also a role-playing reference to dim_employee
--     (the same physical table aliased as "reviewer").
SELECT
    reviewee.first_name                   AS employee_name,
    reviewer.first_name                   AS reviewer_name,
    dd.dept_name,
    review_dt.date_actual                 AS review_date,
    fpr.review_period,
    fpr.rating
FROM fact_performance_review fpr
JOIN dim_employee             reviewee  ON fpr.employee_sk  = reviewee.employee_sk
LEFT JOIN dim_employee        reviewer  ON fpr.reviewer_sk  = reviewer.employee_sk
JOIN dim_department           dd        ON fpr.dept_sk      = dd.dept_sk
JOIN dim_date                 review_dt ON fpr.review_date_sk = review_dt.date_sk
WHERE reviewee.is_current = 1
  AND reviewer.is_current = 1
ORDER BY review_dt.date_actual DESC;

-- 3c. Year/quarter attributes from the role-playing dim_date
--     Each alias gives access to all calendar attributes (year, quarter, etc.)
--     for that specific role.
SELECT
    submit.year      AS submission_year,
    submit.quarter   AS submission_quarter,
    COUNT(*)         AS requests_submitted,
    SUM(CASE WHEN fll.approve_date_sk IS NOT NULL THEN 1 ELSE 0 END) AS approved,
    AVG(fll.days_to_decision) AS avg_days_to_decision
FROM fact_leave_lifecycle fll
JOIN dim_date             submit ON fll.submit_date_sk = submit.date_sk
GROUP BY submit.year, submit.quarter
ORDER BY submit.year, submit.quarter;


-- ─────────────────────────────────────────────────────────────
-- SECTION 4: DEGENERATE DIMENSION
-- ─────────────────────────────────────────────────────────────
--
-- A degenerate dimension is a natural key from the source system
-- stored directly in the fact table — there is no separate
-- dimension table because the key has no additional attributes
-- worth materializing.
--
-- In this schema:
--   fact_leave_lifecycle.leave_request_id  — source PK from leave_requests
--   fact_performance_review.review_id      — source PK from performance_reviews
--
-- When to use degenerate instead of a full dimension:
--   - The only attribute is the ID itself (no description, no status,
--     no attributes that benefit from grouped reporting)
--   - The primary use case is point lookup ("find me leave request 12")
--     or grouping back to the source system record
--   - Creating a full dimension table would add a join with no new info
--
-- When NOT to use degenerate:
--   - The ID has associated attributes (e.g., if leave_request_id had a
--     "request category" or "priority level" — those warrant a dim table)
--   - You need to report by groups of IDs with shared attributes
-- ─────────────────────────────────────────────────────────────

-- 4a. Point lookup on degenerate dimension — no dim table join needed
SELECT
    fll.leave_request_id,    -- degenerate dim: the fact IS the source record
    de.emp_id,
    de.first_name,
    fll.leave_type,
    fll.current_status,
    fll.duration_days,
    fll.days_to_decision
FROM fact_leave_lifecycle fll
JOIN dim_employee          de ON fll.employee_sk = de.employee_sk
WHERE fll.leave_request_id = 12;  -- direct filter on degenerate key

-- 4b. Degenerate dimension in fact_performance_review
SELECT
    fpr.review_id,            -- degenerate: maps back to source performance_reviews.review_id
    de.first_name,
    de.last_name,
    fpr.review_period,
    fpr.rating
FROM fact_performance_review fpr
JOIN dim_employee             de ON fpr.employee_sk = de.employee_sk
WHERE fpr.review_id BETWEEN 1 AND 5;

-- 4c. Group by a degenerate key to aggregate across multiple fact rows
--     (less common — usually degenerate dims appear once per fact row)
SELECT
    fll.leave_request_id,
    fll.current_status,
    de.emp_id,
    de.first_name
FROM fact_leave_lifecycle fll
JOIN dim_employee          de ON fll.employee_sk = de.employee_sk
ORDER BY fll.leave_request_id;


-- ─────────────────────────────────────────────────────────────
-- SECTION 5: BRIDGE TABLE — bridge_emp_project
-- ─────────────────────────────────────────────────────────────
--
-- Employees and projects have a many-to-many relationship:
--   one employee can be on many projects simultaneously
--   one project has many employees assigned to it
--
-- A bridge table resolves the M:N relationship by sitting between
-- the employee dimension and the project natural key. It also
-- carries an allocation_weight (fraction of time: 0.0 to 1.0)
-- to enable weighted payroll calculations.
--
-- Without a bridge table, you would have to store a comma-separated
-- list of project IDs in the employee record (an anti-pattern that
-- makes filtering and aggregation impossible in SQL).
-- ─────────────────────────────────────────────────────────────

-- 5a. Seed the bridge table with sample assignments
INSERT INTO bridge_emp_project
    (employee_sk, project_id, project_name, allocation_weight, effective_date, expiry_date)
VALUES
    -- Three employees on Project 1 (Alpha Platform)
    (1,  1, 'Alpha Platform', 0.50, '2024-01-01', '2024-12-31'),
    (2,  1, 'Alpha Platform', 0.75, '2024-01-01', '2024-06-30'),
    (3,  1, 'Alpha Platform', 1.00, '2024-01-01', NULL),
    -- Emp 9 on three projects simultaneously (will appear in factless fact query 4c)
    (9,  1, 'Alpha Platform', 0.33, '2024-03-01', '2024-09-30'),
    (9,  2, 'Beta Analytics', 0.33, '2024-03-01', '2024-09-30'),
    (9,  3, 'Gamma Infra',    0.34, '2024-03-01', '2024-09-30'),
    -- Additional assignments for coverage
    (4,  2, 'Beta Analytics', 1.00, '2024-02-01', '2024-12-31'),
    (5,  3, 'Gamma Infra',    0.60, '2024-04-01', NULL),
    (6,  3, 'Gamma Infra',    0.40, '2024-04-01', NULL);

-- 5b. THE WRONG QUERY: fan-out double-counting
--     Joining fact_salary_payment to bridge_emp_project through employee_sk
--     multiplies salary rows — each salary row is duplicated once per project.
--     DO NOT use this pattern.
/*
SELECT
    b.project_name,
    SUM(f.salary_amount) AS WRONG_total_payroll   -- inflated by fan-out
FROM fact_salary_payment  f
JOIN bridge_emp_project   b ON f.employee_sk = b.employee_sk
GROUP BY b.project_name;
-- If emp 9 is on 3 projects, their salary is counted 3× in this query.
*/

-- 5c. CORRECT query: project headcount from the bridge table directly
SELECT
    b.project_name,
    COUNT(DISTINCT b.employee_sk)  AS employees_assigned
FROM bridge_emp_project b
WHERE b.expiry_date IS NULL OR b.expiry_date >= CURDATE()  -- active assignments
GROUP BY b.project_id, b.project_name
ORDER BY employees_assigned DESC;

-- 5d. Weighted payroll per project using allocation_weight
--     employee's salary × their share of time allocated to the project
--     avoids double-counting by applying the weight rather than summing full salary
SELECT
    b.project_name,
    COUNT(DISTINCT b.employee_sk)                           AS employee_count,
    SUM(de.salary * b.allocation_weight)                    AS weighted_payroll_cost,
    AVG(b.allocation_weight)                                AS avg_allocation
FROM bridge_emp_project b
JOIN dim_employee        de ON b.employee_sk = de.employee_sk
                            AND de.is_current = 1
WHERE de.salary IS NOT NULL
  AND (b.expiry_date IS NULL OR b.expiry_date >= CURDATE())
GROUP BY b.project_id, b.project_name
ORDER BY weighted_payroll_cost DESC;

-- 5e. Find employees with total allocation > 100% (overcommitted)
SELECT
    de.emp_id,
    de.first_name,
    de.last_name,
    SUM(b.allocation_weight)    AS total_allocation,
    GROUP_CONCAT(b.project_name ORDER BY b.project_id SEPARATOR ', ') AS projects
FROM bridge_emp_project b
JOIN dim_employee        de ON b.employee_sk = de.employee_sk
                            AND de.is_current = 1
WHERE (b.expiry_date IS NULL OR b.expiry_date >= CURDATE())
GROUP BY de.emp_id, de.first_name, de.last_name
HAVING SUM(b.allocation_weight) > 1.00
ORDER BY total_allocation DESC;


-- ─────────────────────────────────────────────────────────────
-- SECTION 6: CALENDAR DIMENSION — dim_date
-- ─────────────────────────────────────────────────────────────
--
-- A calendar dimension is pre-built and fully populated for the
-- entire date range the warehouse will ever need (commonly ±5 years
-- from deployment). It is NEVER derived on-the-fly.
--
-- Advantages over computed date logic in queries:
--   - Fiscal year / fiscal quarter variants stored as columns
--     (cannot be computed from DATE functions alone)
--   - is_weekend, is_month_start, is_month_end simplify WHERE clauses
--   - Month names, week numbers available without FORMAT() calls
--   - Indexable integer key (YYYYMMDD) is faster than range scans on DATE
--   - Enables LEFT JOIN gap detection (missing fact rows for a date)
--
-- Column reference:
--   date_sk        YYYYMMDD integer (PK, FK target in all fact tables)
--   date_actual    DATE
--   year, quarter, month, month_name, week_of_year
--   day_of_month, day_of_week (1=Monday … 7=Sunday), day_name
--   is_weekend, is_month_start, is_month_end
--   fiscal_year, fiscal_quarter (for non-calendar fiscal year orgs)
-- ─────────────────────────────────────────────────────────────

-- 6a. Seed dim_date with representative rows
--     Covers key dates in the dataset: 2020-2025 month-starts, month-ends,
--     hire dates, and representative mid-month dates.
--     In production this would be generated by a stored procedure or ETL
--     to populate every calendar day for a 15-year range.

INSERT INTO dim_date
    (date_sk, date_actual, year, quarter, month, month_name,
     week_of_year, day_of_month, day_of_week, day_name,
     is_weekend, is_month_start, is_month_end,
     fiscal_year, fiscal_quarter)
VALUES
-- 2020 sample: Jan start, Jan end, Mar 15
(20200101, '2020-01-01', 2020, 1,  1,  'January',  1,  1,  3, 'Wednesday', 0, 1, 0, 2020, 1),
(20200131, '2020-01-31', 2020, 1,  1,  'January',  5, 31,  5, 'Friday',    0, 0, 1, 2020, 1),
(20200315, '2020-03-15', 2020, 1,  3,  'March',   11, 15,  7, 'Sunday',    1, 0, 0, 2020, 1),
(20200331, '2020-03-31', 2020, 1,  3,  'March',   14, 31,  2, 'Tuesday',   0, 0, 1, 2020, 1),
(20200630, '2020-06-30', 2020, 2,  6,  'June',    27, 30,  2, 'Tuesday',   0, 0, 1, 2020, 2),
(20200930, '2020-09-30', 2020, 3,  9,  'September',40, 30,  3, 'Wednesday', 0, 0, 1, 2020, 3),
(20201231, '2020-12-31', 2020, 4, 12,  'December', 53, 31,  4, 'Thursday',  0, 0, 1, 2020, 4),
-- 2021
(20210101, '2021-01-01', 2021, 1,  1,  'January',  1,  1,  5, 'Friday',    0, 1, 0, 2021, 1),
(20210331, '2021-03-31', 2021, 1,  3,  'March',   13, 31,  3, 'Wednesday', 0, 0, 1, 2021, 1),
(20210630, '2021-06-30', 2021, 2,  6,  'June',    26, 30,  3, 'Wednesday', 0, 0, 1, 2021, 2),
(20210930, '2021-09-30', 2021, 3,  9,  'September',39, 30,  4, 'Thursday',  0, 0, 1, 2021, 3),
(20211231, '2021-12-31', 2021, 4, 12,  'December', 52, 31,  5, 'Friday',    0, 0, 1, 2021, 4),
-- 2022
(20220101, '2022-01-01', 2022, 1,  1,  'January',  1,  1,  6, 'Saturday',  1, 1, 0, 2022, 1),
(20220331, '2022-03-31', 2022, 1,  3,  'March',   13, 31,  4, 'Thursday',  0, 0, 1, 2022, 1),
(20220630, '2022-06-30', 2022, 2,  6,  'June',    26, 30,  4, 'Thursday',  0, 0, 1, 2022, 2),
(20220930, '2022-09-30', 2022, 3,  9,  'September',39, 30,  5, 'Friday',    0, 0, 1, 2022, 3),
(20221231, '2022-12-31', 2022, 4, 12,  'December', 52, 31,  6, 'Saturday',  1, 0, 1, 2022, 4),
-- 2023
(20230101, '2023-01-01', 2023, 1,  1,  'January',  1,  1,  7, 'Sunday',    1, 1, 0, 2023, 1),
(20230331, '2023-03-31', 2023, 1,  3,  'March',   13, 31,  5, 'Friday',    0, 0, 1, 2023, 1),
(20230630, '2023-06-30', 2023, 2,  6,  'June',    26, 30,  5, 'Friday',    0, 0, 1, 2023, 2),
(20230930, '2023-09-30', 2023, 3,  9,  'September',39, 30,  6, 'Saturday',  1, 0, 1, 2023, 3),
(20231231, '2023-12-31', 2023, 4, 12,  'December', 52, 31,  7, 'Sunday',    1, 0, 1, 2023, 4),
-- 2024 — primary analysis year
(20240101, '2024-01-01', 2024, 1,  1,  'January',  1,  1,  1, 'Monday',    0, 1, 0, 2024, 1),
(20240131, '2024-01-31', 2024, 1,  1,  'January',  5, 31,  3, 'Wednesday', 0, 0, 1, 2024, 1),
(20240201, '2024-02-01', 2024, 1,  2,  'February', 5,  1,  4, 'Thursday',  0, 1, 0, 2024, 1),
(20240229, '2024-02-29', 2024, 1,  2,  'February', 9, 29,  4, 'Thursday',  0, 0, 1, 2024, 1),
(20240301, '2024-03-01', 2024, 1,  3,  'March',    9,  1,  5, 'Friday',    0, 1, 0, 2024, 1),
(20240315, '2024-03-15', 2024, 1,  3,  'March',   11, 15,  5, 'Friday',    0, 0, 0, 2024, 1),
(20240331, '2024-03-31', 2024, 1,  3,  'March',   13, 31,  7, 'Sunday',    1, 0, 1, 2024, 1),
(20240630, '2024-06-30', 2024, 2,  6,  'June',    26, 30,  7, 'Sunday',    1, 0, 1, 2024, 2),
(20240930, '2024-09-30', 2024, 3,  9,  'September',40, 30,  1, 'Monday',    0, 0, 1, 2024, 3),
(20241231, '2024-12-31', 2024, 4, 12,  'December', 53, 31,  2, 'Tuesday',   0, 0, 1, 2024, 4),
-- 2025
(20250101, '2025-01-01', 2025, 1,  1,  'January',  1,  1,  3, 'Wednesday', 0, 1, 0, 2025, 1),
(20250331, '2025-03-31', 2025, 1,  3,  'March',   14, 31,  1, 'Monday',    0, 0, 1, 2025, 1),
(20250630, '2025-06-30', 2025, 2,  6,  'June',    27, 30,  1, 'Monday',    0, 0, 1, 2025, 2),
(20250930, '2025-09-30', 2025, 3,  9,  'September',40, 30,  2, 'Tuesday',   0, 0, 1, 2025, 3),
(20251231, '2025-12-31', 2025, 4, 12,  'December', 53, 31,  3, 'Wednesday', 0, 0, 1, 2025, 4);

-- 6b. Fiscal quarter reporting
--     fiscal_year / fiscal_quarter decouple calendar from business year.
--     If the org's FY starts April 1, Q1 FY = April-June.
--     This cannot be reliably computed with MONTH() alone — it requires
--     the pre-built columns.
SELECT
    fiscal_year,
    fiscal_quarter,
    MIN(date_actual)  AS quarter_start,
    MAX(date_actual)  AS quarter_end,
    COUNT(*)          AS calendar_days
FROM dim_date
GROUP BY fiscal_year, fiscal_quarter
ORDER BY fiscal_year, fiscal_quarter;

-- 6c. Weekend vs weekday distribution
SELECT
    year,
    SUM(CASE WHEN is_weekend = 0 THEN 1 ELSE 0 END) AS weekdays,
    SUM(CASE WHEN is_weekend = 1 THEN 1 ELSE 0 END) AS weekend_days
FROM dim_date
GROUP BY year
ORDER BY year;

-- 6d. Gap detection: months with no salary records for an employee
--     The date spine makes gaps visible — a LEFT JOIN from dim_date
--     produces a row for every month; NULL on the right side means
--     no salary record exists for that employee in that month.
SELECT
    de.emp_id,
    de.first_name,
    de.last_name,
    d.year        AS missing_year,
    d.month       AS missing_month
FROM dim_date d
-- Generate one row per (month-end × employee) for active employees
CROSS JOIN (
    SELECT DISTINCT employee_sk, emp_id, first_name, last_name
    FROM dim_employee
    WHERE is_current = 1
      AND hire_date <= CURDATE()
) de
-- Only consider month-end dates within the employee's tenure
LEFT JOIN fact_salary_payment f
       ON f.employee_sk = de.employee_sk
      AND f.pay_year    = d.year
      AND f.pay_month   = d.month
WHERE d.is_month_end = 1
  AND d.year BETWEEN 2023 AND 2024
  AND f.payment_sk IS NULL             -- NULL = no salary row for that month
ORDER BY de.emp_id, d.year, d.month;

-- 6e. Month-name convenience: human-readable period labels without FORMAT()
SELECT
    CONCAT(d.month_name, ' ', d.year) AS period_label,
    SUM(f.salary_amount)              AS total_payroll
FROM fact_salary_payment f
JOIN dim_date             d ON f.pay_date_sk = d.date_sk
WHERE d.is_month_end = 1
GROUP BY d.year, d.month, d.month_name
ORDER BY d.year, d.month;
