-- ============================================================
-- 07-fact-types / 01-fact-types.sql
-- Database: dm_warehouse
--
-- Demonstrates all four Kimball fact table types using the
-- employee/HR warehouse schema.
--
-- Sections:
--   1. Transaction Fact         — fact_salary_payment
--   2. Periodic Snapshot Fact   — fact_monthly_headcount
--   3. Accumulating Snapshot    — fact_leave_lifecycle
--   4. Factless Fact            — fact_project_coverage
-- ============================================================

USE dm_warehouse;

-- ─────────────────────────────────────────────────────────────
-- SECTION 1: TRANSACTION FACT — fact_salary_payment
-- ─────────────────────────────────────────────────────────────
--
-- Grain: one row per employee per monthly pay period.
--
-- A new row is INSERTED for every payment event. Rows are never
-- updated or deleted — this is the canonical append-only fact.
-- Each row captures the state of the world at the moment of the
-- transaction: which SCD2 employee record was current, which
-- department, which job level.
--
-- Measure additivity:
--   salary_amount  = FULLY ADDITIVE — safe to SUM across all dims
--                    (employee, dept, time, job level)
--   bonus_amount   = FULLY ADDITIVE — same rules as salary_amount
--   avg_salary     = NON-ADDITIVE   — NEVER SUM avg_salary;
--                    always re-derive as SUM(salary) / COUNT(emp)
-- ─────────────────────────────────────────────────────────────

-- 1a. Total payroll by department by month
--     salary_amount is FULLY ADDITIVE: SUM works correctly.
SELECT
    dd.dept_name,
    f.pay_year,
    f.pay_month,
    SUM(f.salary_amount)                         AS total_payroll,
    SUM(f.bonus_amount)                          AS total_bonus,
    SUM(f.salary_amount + COALESCE(f.bonus_amount, 0)) AS total_compensation
FROM fact_salary_payment  f
JOIN dim_department       dd ON f.dept_sk = dd.dept_sk
WHERE f.salary_amount IS NOT NULL               -- exclude NULL-salary contractors
GROUP BY dd.dept_name, f.pay_year, f.pay_month
ORDER BY dd.dept_name, f.pay_year, f.pay_month;

-- 1b. Average salary by job level
--     Derive avg as SUM/COUNT — do NOT store or SUM a pre-computed avg.
SELECT
    dj.job_level_label,
    dj.job_family,
    COUNT(DISTINCT f.employee_sk)                AS employee_count,
    SUM(f.salary_amount)                         AS total_payroll,
    SUM(f.salary_amount) / COUNT(DISTINCT f.employee_sk) AS derived_avg_salary
FROM fact_salary_payment  f
JOIN dim_job              dj ON f.job_sk = dj.job_sk
WHERE f.pay_year = 2024
  AND f.salary_amount IS NOT NULL
GROUP BY dj.job_level_label, dj.job_family
ORDER BY dj.job_level;

-- 1c. Employees who received a bonus
SELECT
    de.first_name,
    de.last_name,
    dj.job_title,
    dd.dept_name,
    f.pay_year,
    f.pay_month,
    f.bonus_amount
FROM fact_salary_payment  f
JOIN dim_employee         de ON f.employee_sk = de.employee_sk
JOIN dim_job              dj ON f.job_sk       = dj.job_sk
JOIN dim_department       dd ON f.dept_sk      = dd.dept_sk
WHERE f.bonus_amount > 0
  AND de.is_current = 1
ORDER BY f.bonus_amount DESC;

-- ─────────────────────────────────────────────────────────────
-- DOUBLE-COUNTING TRAP: avg_salary is NON-ADDITIVE
-- ─────────────────────────────────────────────────────────────
--
-- WRONG: summing a stored or pre-aggregated avg_salary across
-- departments gives a meaningless number — it ignores dept size.
--
-- Imagine two departments:
--   Engineering: 14 employees, avg_salary = 120,000
--   HR:           3 employees, avg_salary =  90,000
--
-- SUM(avg_salary) = 210,000   ← wrong: not a meaningful metric
-- AVG(avg_salary) = 105,000   ← wrong: treats depts as equal weight
--
-- CORRECT approach: always re-derive from the atomic rows.

-- WRONG QUERY (illustrative — do not use in production):
-- SELECT SUM(avg_salary) AS wrong_total_avg
-- FROM fact_monthly_headcount;   -- this is non-additive, never SUM it

-- CORRECT: Re-derive a company-wide average from atomic salary rows:
SELECT
    f.pay_year,
    f.pay_month,
    SUM(f.salary_amount)                              AS total_payroll,
    COUNT(DISTINCT f.employee_sk)                     AS paid_employees,
    SUM(f.salary_amount) / COUNT(DISTINCT f.employee_sk) AS correct_company_avg
FROM fact_salary_payment f
WHERE f.salary_amount IS NOT NULL
GROUP BY f.pay_year, f.pay_month
ORDER BY f.pay_year, f.pay_month;


-- ─────────────────────────────────────────────────────────────
-- SECTION 2: PERIODIC SNAPSHOT FACT — fact_monthly_headcount
-- ─────────────────────────────────────────────────────────────
--
-- Grain: one row per department per end-of-month.
--
-- Rows are NEVER DELETED — even if a department's headcount
-- drops to 0, the snapshot row still exists. This preserves
-- the ability to query any historical month without gaps.
--
-- The ETL writes one row per (dept × month-end) on the last
-- business day of each month, recording the state as of that
-- moment. This is NOT derived on-the-fly; it is pre-aggregated
-- state capture.
--
-- Semi-additivity of headcount:
--   ACROSS departments on the SAME date: ADDITIVE (safe to SUM).
--     SUM(headcount) WHERE snapshot_month = 6 = total company staff.
--   ACROSS dates for ONE department:     NON-ADDITIVE (do NOT SUM).
--     SUM(headcount over 12 months) ≠ annual headcount;
--     it is cumulative occupancy — a meaningless number.
--   avg_salary is NON-ADDITIVE in all directions (re-derive always).
-- ─────────────────────────────────────────────────────────────

-- 2a. Cross-department headcount on a specific month (ADDITIVE across depts)
SELECT
    dd.dept_name,
    fmh.snapshot_year,
    fmh.snapshot_month,
    fmh.headcount,
    fmh.active_count,
    fmh.terminated_count,
    fmh.total_payroll,
    fmh.avg_salary
FROM fact_monthly_headcount fmh
JOIN dim_department         dd  ON fmh.dept_sk = dd.dept_sk
WHERE fmh.snapshot_year = 2024 AND fmh.snapshot_month = 6
ORDER BY fmh.headcount DESC;

-- Company-wide total for June 2024 — safe because all rows share the same date:
SELECT
    snapshot_year,
    snapshot_month,
    SUM(headcount)     AS company_headcount,   -- additive across depts on same date
    SUM(total_payroll) AS company_payroll       -- additive across depts on same date
    -- do NOT SUM(avg_salary): non-additive, re-derive below
FROM fact_monthly_headcount
WHERE snapshot_year = 2024 AND snapshot_month = 6;

-- 2b. Period-over-period headcount change using LAG()
--     LAG() looks back one partition row — department must be partitioned
--     so each dept's timeline is independent.
SELECT
    dd.dept_name,
    fmh.snapshot_year,
    fmh.snapshot_month,
    fmh.headcount,
    LAG(fmh.headcount) OVER (
        PARTITION BY fmh.dept_sk
        ORDER BY fmh.snapshot_year, fmh.snapshot_month
    )                                                    AS prev_month_headcount,
    fmh.headcount - LAG(fmh.headcount) OVER (
        PARTITION BY fmh.dept_sk
        ORDER BY fmh.snapshot_year, fmh.snapshot_month
    )                                                    AS headcount_change
FROM fact_monthly_headcount fmh
JOIN dim_department         dd ON fmh.dept_sk = dd.dept_sk
ORDER BY dd.dept_name, fmh.snapshot_year, fmh.snapshot_month;

-- 2c. Departments with zero headcount in any month
--     The no-delete rule means these rows exist — we can detect gaps.
SELECT
    dd.dept_name,
    fmh.snapshot_year,
    fmh.snapshot_month,
    fmh.headcount
FROM fact_monthly_headcount fmh
JOIN dim_department         dd ON fmh.dept_sk = dd.dept_sk
WHERE fmh.headcount = 0
ORDER BY fmh.snapshot_year, fmh.snapshot_month;


-- ─────────────────────────────────────────────────────────────
-- SECTION 3: ACCUMULATING SNAPSHOT FACT — fact_leave_lifecycle
-- ─────────────────────────────────────────────────────────────
--
-- Grain: one row per leave request, updated as it moves through
--        the approval lifecycle.
--
-- Unlike transaction or periodic facts, this fact table is both
-- INSERTED (when a request is submitted) and UPDATED (as it
-- advances through stages). The row accumulates milestone dates:
--
--   Stage 1: submitted  → submit_date_sk set, current_status = 'Pending'
--   Stage 2: decided    → approve_date_sk OR reject_date_sk set,
--                         current_status = 'Approved' / 'Rejected',
--                         days_to_decision derived and stored
--   Stage 3: taken      → start_date_sk, end_date_sk, duration_days confirmed
--
-- Appropriate only for well-defined, bounded pipelines (leave approval,
-- loan processing, hiring pipeline). Not appropriate for open-ended
-- processes with many optional or repeated stages.
-- ─────────────────────────────────────────────────────────────

-- 3a. UPDATE pattern: approve a pending leave request
--     This is the defining operation of an accumulating snapshot.
--     ETL runs daily; when the source shows a newly approved request,
--     it updates the existing warehouse row in-place.
UPDATE fact_leave_lifecycle
SET
    approve_date_sk  = 20240315,           -- FK to dim_date for approval date
    current_status   = 'Approved',
    days_to_decision = DATEDIFF(
                           (SELECT date_actual FROM dim_date WHERE date_sk = 20240315),
                           (SELECT date_actual FROM dim_date WHERE date_sk = submit_date_sk)
                       )
WHERE leave_request_id = 5;               -- degenerate dim: point lookup by source PK

-- 3b. Velocity query: average days from submission to decision by department
--     days_to_decision is NULL for still-pending requests — excluded by IS NOT NULL.
SELECT
    dd.dept_name,
    COUNT(fll.leave_sk)                    AS total_requests,
    COUNT(fll.approve_date_sk)             AS approved_count,
    COUNT(fll.reject_date_sk)              AS rejected_count,
    AVG(fll.days_to_decision)              AS avg_days_to_decision,
    MIN(fll.days_to_decision)              AS fastest_decision,
    MAX(fll.days_to_decision)              AS slowest_decision
FROM fact_leave_lifecycle fll
JOIN dim_department       dd  ON fll.dept_sk = dd.dept_sk
WHERE fll.days_to_decision IS NOT NULL     -- only decided requests
GROUP BY dd.dept_name
ORDER BY avg_days_to_decision DESC;

-- 3c. Incomplete pipeline: requests still pending (approve_date_sk IS NULL)
--     A key advantage of the accumulating snapshot: you can instantly
--     see which rows have NOT yet reached a milestone.
SELECT
    de.emp_id,
    de.first_name,
    de.last_name,
    dd.dept_name,
    fll.leave_request_id,
    fll.leave_type,
    fll.current_status,
    submit.date_actual                     AS submitted_on,
    DATEDIFF(CURDATE(), submit.date_actual) AS days_waiting
FROM fact_leave_lifecycle fll
JOIN dim_employee         de     ON fll.employee_sk   = de.employee_sk
JOIN dim_department       dd     ON fll.dept_sk       = dd.dept_sk
JOIN dim_date             submit ON fll.submit_date_sk = submit.date_sk
WHERE fll.approve_date_sk IS NULL
  AND fll.reject_date_sk  IS NULL
  AND de.is_current = 1
ORDER BY days_waiting DESC;

-- 3d. Intentional flaw: leave_request_id = 11 has NULL leave_type
--     The accumulating snapshot preserves this NULL — it reflects a
--     data quality issue in the source that must be investigated/fixed.
SELECT
    leave_request_id,
    leave_type,
    current_status,
    duration_days
FROM fact_leave_lifecycle
WHERE leave_request_id = 11;

-- 3e. Emp 12 overlapping leave dates — both requests visible in the fact table
--     Business rule: overlapping requests are a data quality issue;
--     the fact table preserves both rows for auditability.
SELECT
    fll.leave_request_id,
    de.emp_id,
    de.first_name,
    fll.leave_type,
    s.date_actual  AS leave_start,
    e.date_actual  AS leave_end,
    fll.duration_days,
    fll.current_status
FROM fact_leave_lifecycle fll
JOIN dim_employee         de ON fll.employee_sk  = de.employee_sk
JOIN dim_date             s  ON fll.start_date_sk = s.date_sk
JOIN dim_date             e  ON fll.end_date_sk   = e.date_sk
WHERE de.emp_id = 12
ORDER BY s.date_actual;


-- ─────────────────────────────────────────────────────────────
-- SECTION 4: FACTLESS FACT — fact_project_coverage
-- ─────────────────────────────────────────────────────────────
--
-- Grain: one row per employee per project assignment.
--
-- There are NO numeric measures in this table. The "fact" is the
-- existence of the row — the relationship between an employee and
-- a project. Count of rows, presence/absence of rows, and date
-- range overlaps are the only analytics this table supports.
--
-- This is the correct design when the business event is inherently
-- relational (coverage, enrollment, staffing) and no additive
-- measure is associated with each occurrence.
-- ─────────────────────────────────────────────────────────────

-- 4a. Projects with NO employees assigned
--     The factless fact's LEFT JOIN pattern: absence of a row is the signal.
SELECT
    p.project_id,
    p.project_name
FROM (
    -- Build a reference list of all known projects from the factless fact
    SELECT DISTINCT project_id, project_name
    FROM fact_project_coverage
) p
LEFT JOIN fact_project_coverage fpc ON p.project_id = fpc.project_id
                                   AND fpc.employee_sk IS NOT NULL
WHERE fpc.employee_sk IS NULL;

-- 4b. Employee count per project (counting rows IS the measure)
SELECT
    fpc.project_id,
    fpc.project_name,
    COUNT(fpc.employee_sk)          AS employees_assigned,
    COUNT(DISTINCT de.dept_sk)      AS departments_involved
FROM fact_project_coverage fpc
JOIN dim_employee           de  ON fpc.employee_sk = de.employee_sk
WHERE de.is_current = 1
GROUP BY fpc.project_id, fpc.project_name
ORDER BY employees_assigned DESC;

-- 4c. Employees on 3+ projects simultaneously
--     Self-join on overlapping date ranges.
--     Overlap condition: a.start <= b.end AND a.end >= b.start
SELECT
    de.emp_id,
    de.first_name,
    de.last_name,
    COUNT(DISTINCT a.project_id)    AS concurrent_project_count,
    GROUP_CONCAT(a.project_name ORDER BY a.project_id SEPARATOR ', ') AS projects
FROM fact_project_coverage a
JOIN fact_project_coverage b
    ON  a.employee_sk  = b.employee_sk
    AND a.project_id  != b.project_id
    AND a.start_date_sk <= COALESCE(b.end_date_sk, 99991231)
    AND COALESCE(a.end_date_sk, 99991231) >= b.start_date_sk
JOIN dim_employee de ON a.employee_sk = de.employee_sk
WHERE de.is_current = 1
GROUP BY de.emp_id, de.first_name, de.last_name
HAVING COUNT(DISTINCT a.project_id) >= 3
ORDER BY concurrent_project_count DESC;

-- 4d. Department coverage rate: % of employees currently on at least one project
SELECT
    dd.dept_name,
    COUNT(DISTINCT de.employee_sk)                          AS dept_headcount,
    COUNT(DISTINCT fpc.employee_sk)                         AS employees_on_projects,
    ROUND(
        COUNT(DISTINCT fpc.employee_sk) * 100.0
        / NULLIF(COUNT(DISTINCT de.employee_sk), 0)
    , 1)                                                    AS coverage_pct
FROM dim_employee de
JOIN dim_department dd ON de.dept_sk = dd.dept_sk
LEFT JOIN fact_project_coverage fpc
       ON de.employee_sk = fpc.employee_sk
WHERE de.is_current = 1
GROUP BY dd.dept_name
ORDER BY coverage_pct DESC;
