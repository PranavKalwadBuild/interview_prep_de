-- =============================================================================
-- FILE: 03-pivoting-string-agg.sql
-- TOPIC: Pivoting, Un-pivoting, and String Aggregation (GROUP_CONCAT)
-- DB: sql-patterns
-- Covers: leave-type pivot, project-status pivot, salary-change-year pivot,
--         un-pivot via UNION ALL, GROUP_CONCAT patterns, group_concat_max_len,
--         NULL handling in GROUP_CONCAT, JSON-like dept summary
-- =============================================================================

USE `sql-patterns`;

-- =============================================================================
-- SECTION 1: Pivot leave_type counts per employee
-- =============================================================================
-- Rotate leave_requests rows → one wide row per employee.
-- leave_type values: 'Annual Leave', 'Sick Leave', 'Parental Leave', NULL (req 11).
-- NULL leave_type handled with a dedicated IS NULL branch.
-- Expected: 20 leave_request rows, up to ~18 distinct employees.

SELECT
    e.emp_id,
    CONCAT(e.first_name, ' ', e.last_name)                          AS employee_name,
    COUNT(lr.request_id)                                            AS total_requests,
    SUM(CASE WHEN lr.leave_type = 'Annual Leave'   THEN 1 ELSE 0 END) AS annual_count,
    SUM(CASE WHEN lr.leave_type = 'Sick Leave'     THEN 1 ELSE 0 END) AS sick_count,
    SUM(CASE WHEN lr.leave_type = 'Parental Leave' THEN 1 ELSE 0 END) AS parental_count,
    -- NULL leave_type: must use IS NULL, not = NULL
    SUM(CASE WHEN lr.leave_type IS NULL            THEN 1 ELSE 0 END) AS unknown_type_count,
    -- Status breakdown across all leave types
    SUM(CASE WHEN lr.status = 'Approved'           THEN 1 ELSE 0 END) AS approved_count,
    SUM(CASE WHEN lr.status = 'Pending'            THEN 1 ELSE 0 END) AS pending_count,
    SUM(CASE WHEN lr.status = 'Rejected'           THEN 1 ELSE 0 END) AS rejected_count
FROM employees e
JOIN leave_requests lr ON e.emp_id = lr.emp_id
GROUP BY e.emp_id, e.first_name, e.last_name
ORDER BY total_requests DESC, e.emp_id;

-- unknown_type_count = 1 total (request_id=11 has NULL leave_type).
-- Note: CASE WHEN lr.leave_type = NULL → always evaluates to FALSE; use IS NULL.


-- =============================================================================
-- SECTION 2: Pivot project status count per department
-- =============================================================================
-- project.status values expected: 'Active', 'Planning', 'Completed'.
-- One row per department showing counts per status and a total.
-- Expected: departments with projects; some may have 0 in certain status columns.

SELECT
    d.dept_id,
    d.dept_name,
    COUNT(p.project_id)                                                  AS total_projects,
    SUM(CASE WHEN p.status = 'Active'    THEN 1 ELSE 0 END)             AS active_projects,
    SUM(CASE WHEN p.status = 'Planning'  THEN 1 ELSE 0 END)             AS planning_projects,
    SUM(CASE WHEN p.status = 'Completed' THEN 1 ELSE 0 END)             AS completed_projects,
    -- Catch any unexpected status values
    SUM(CASE WHEN p.status NOT IN ('Active','Planning','Completed')
                 OR p.status IS NULL     THEN 1 ELSE 0 END)             AS other_status_count,
    -- Budget pivot: total budget for active projects vs completed
    ROUND(SUM(CASE WHEN p.status = 'Active'    THEN p.budget ELSE 0 END), 2)
                                                                         AS active_budget,
    ROUND(SUM(CASE WHEN p.status = 'Completed' THEN p.budget ELSE 0 END), 2)
                                                                         AS completed_budget
FROM departments d
JOIN projects p ON d.dept_id = p.dept_id
GROUP BY d.dept_id, d.dept_name
ORDER BY total_projects DESC;

-- Departments with no projects are excluded (INNER JOIN).
-- Use LEFT JOIN and HAVING COUNT(p.project_id) > 0 equivalent if you want all depts.


-- =============================================================================
-- SECTION 3: Pivot salary changes by year (2019–2022)
-- =============================================================================
-- salary_history has 34 rows. YEAR(effective_date) creates column buckets.
-- salary_before IS NULL for initial hires — those are new-hire events, not raises.
-- Focus years 2019–2022 as the meaningful salary change window.
-- Expected: one row per employee; years outside 2019-2022 appear in other_years_count.

SELECT
    e.emp_id,
    CONCAT(e.first_name, ' ', e.last_name)                               AS employee_name,
    COUNT(sh.hist_id)                                                     AS total_changes,
    -- Count of changes in each target year
    SUM(CASE WHEN YEAR(sh.effective_date) = 2019 THEN 1 ELSE 0 END)      AS changes_2019,
    SUM(CASE WHEN YEAR(sh.effective_date) = 2020 THEN 1 ELSE 0 END)      AS changes_2020,
    SUM(CASE WHEN YEAR(sh.effective_date) = 2021 THEN 1 ELSE 0 END)      AS changes_2021,
    SUM(CASE WHEN YEAR(sh.effective_date) = 2022 THEN 1 ELSE 0 END)      AS changes_2022,
    SUM(CASE WHEN YEAR(sh.effective_date) NOT IN (2019,2020,2021,2022)
             THEN 1 ELSE 0 END)                                           AS other_years_count,
    -- Latest salary after all changes
    MAX(sh.salary_after)                                                  AS latest_salary_after,
    -- Total $ increase across all changes (initial hires have salary_before=NULL → skip)
    ROUND(SUM(sh.salary_after - COALESCE(sh.salary_before, sh.salary_after)), 2)
                                                                          AS total_raise_amount
FROM employees e
JOIN salary_history sh ON e.emp_id = sh.emp_id
GROUP BY e.emp_id, e.first_name, e.last_name
ORDER BY total_changes DESC, e.emp_id;

-- total_raise_amount: COALESCE(salary_before, salary_after) makes initial-hire rows
-- contribute 0 to the raise sum (salary_after - salary_after = 0).
-- emp 5 has a duplicate row in salary_history — it will show changes_2019=2 (or
-- whichever year the duplicate falls in); verify with:
-- SELECT * FROM salary_history WHERE emp_id = 5 ORDER BY effective_date;


-- =============================================================================
-- SECTION 4: Un-pivot — normalize a pivoted structure back to rows
-- =============================================================================
-- MySQL has no UNPIVOT keyword. Simulate with UNION ALL, one branch per column.
-- Use case: you received a wide report; need to analyze it as a long table.
-- Source: the per-dept spend pivot from Section 5 of file 01 (re-created inline).

-- First, build the pivoted summary as a CTE:
WITH dept_spend AS (
    SELECT
        po.dept_id,
        ROUND(SUM(CASE WHEN po.item_category = 'Software'        THEN po.amount ELSE 0 END), 2) AS software_spend,
        ROUND(SUM(CASE WHEN po.item_category = 'Hardware'        THEN po.amount ELSE 0 END), 2) AS hardware_spend,
        ROUND(SUM(CASE WHEN po.item_category = 'Cloud Services'  THEN po.amount ELSE 0 END), 2) AS cloud_spend,
        ROUND(SUM(CASE WHEN po.item_category = 'Training'        THEN po.amount ELSE 0 END), 2) AS training_spend,
        ROUND(SUM(CASE WHEN po.item_category = 'Travel'          THEN po.amount ELSE 0 END), 2) AS travel_spend
    FROM purchase_orders po
    WHERE po.dept_id IS NOT NULL
    GROUP BY po.dept_id
)
-- Un-pivot: each column becomes a row via UNION ALL
SELECT dept_id, 'Software'       AS category, software_spend   AS amount FROM dept_spend
UNION ALL
SELECT dept_id, 'Hardware',       hardware_spend   FROM dept_spend
UNION ALL
SELECT dept_id, 'Cloud Services', cloud_spend      FROM dept_spend
UNION ALL
SELECT dept_id, 'Training',       training_spend   FROM dept_spend
UNION ALL
SELECT dept_id, 'Travel',         travel_spend     FROM dept_spend
ORDER BY dept_id, category;

-- Expected: 5 categories × N depts = 5N rows (includes rows where amount=0).
-- Filter WHERE amount > 0 to keep only depts that spent in each category.


-- =============================================================================
-- SECTION 5: GROUP_CONCAT — all employees per department
-- =============================================================================
-- ORDER BY inside GROUP_CONCAT controls list sort order.
-- SEPARATOR overrides the default comma.
-- Expected: 8 rows (one per dept); Engineering row has 14 names.

SET SESSION group_concat_max_len = 4096;   -- see Section 7 for explanation

SELECT
    d.dept_id,
    d.dept_name,
    COUNT(e.emp_id)                         AS headcount,
    GROUP_CONCAT(
        CONCAT(e.first_name, ' ', e.last_name)
        ORDER BY e.last_name, e.first_name
        SEPARATOR ', '
    )                                       AS employee_list
FROM departments d
JOIN employees e ON d.dept_id = e.dept_id
GROUP BY d.dept_id, d.dept_name
ORDER BY d.dept_id;

-- The default group_concat_max_len = 1024 bytes. Engineering with 14 employees
-- (avg ~15 chars/name) = ~210 chars + separators — fits in 1024.
-- For larger depts or longer names, the string silently truncates at the limit.


-- =============================================================================
-- SECTION 6: GROUP_CONCAT — project roles per employee
-- =============================================================================
-- DISTINCT removes duplicate roles; ORDER BY makes output deterministic.
-- Employees not assigned to any project are excluded (INNER JOIN).
-- Expected: one row per assigned employee; roles separated by ' | '.

SELECT
    e.emp_id,
    CONCAT(e.first_name, ' ', e.last_name)   AS employee_name,
    COUNT(pa.assignment_id)                  AS total_assignments,
    GROUP_CONCAT(
        DISTINCT pa.role
        ORDER BY pa.role
        SEPARATOR ' | '
    )                                        AS distinct_roles,
    GROUP_CONCAT(
        pa.project_id
        ORDER BY pa.start_date
        SEPARATOR ', '
    )                                        AS project_ids_chronological
FROM employees e
JOIN project_assignments pa ON e.emp_id = pa.emp_id
GROUP BY e.emp_id, e.first_name, e.last_name
ORDER BY total_assignments DESC, e.emp_id;

-- Without DISTINCT: an employee assigned as 'Developer' on 3 projects would show
-- 'Developer | Developer | Developer'. DISTINCT collapses to just 'Developer'.


-- =============================================================================
-- SECTION 7: group_concat_max_len — default limit and how to raise it
-- =============================================================================
-- Default: 1024 bytes per aggregated string (silently truncates, no error).
-- Silent truncation is dangerous: you get a partial list with no warning.
-- Set SESSION to avoid affecting other connections; set GLOBAL for persistence.

-- Check current setting:
SELECT @@SESSION.group_concat_max_len AS session_limit,
       @@GLOBAL.group_concat_max_len  AS global_limit;

-- Raise for current session only:
SET SESSION group_concat_max_len = 4096;

-- Raise globally (requires SUPER or SYSTEM_VARIABLES_ADMIN privilege):
-- SET GLOBAL group_concat_max_len = 65536;

-- Verify truncation risk for the largest group in your query:
SELECT
    dept_id,
    LENGTH(GROUP_CONCAT(
        CONCAT(first_name, ' ', last_name) SEPARATOR ', '
    ))                                       AS concat_length,
    -- Flag if close to the limit (within 10%)
    CASE
        WHEN LENGTH(GROUP_CONCAT(
            CONCAT(first_name, ' ', last_name) SEPARATOR ', '
        )) > @@SESSION.group_concat_max_len * 0.9
        THEN 'WARNING: near limit'
        ELSE 'OK'
    END                                      AS truncation_risk
FROM employees
GROUP BY dept_id
ORDER BY concat_length DESC;

-- In MySQL 8.0, JSON_ARRAYAGG() is an alternative that returns a JSON array
-- and is not subject to group_concat_max_len:
-- SELECT dept_id, JSON_ARRAYAGG(last_name) FROM employees GROUP BY dept_id;


-- =============================================================================
-- SECTION 8: GROUP_CONCAT leave types per employee — NULL handling
-- =============================================================================
-- GROUP_CONCAT silently excludes NULL values from the aggregation.
-- This is different from COALESCE: no placeholder appears for NULL entries.
-- Employee with only NULL leave_type (request 11) gets NULL from GROUP_CONCAT.
-- Expected: ~18-19 rows; employee tied to request 11 shows 'Unknown' via COALESCE.

SELECT
    e.emp_id,
    CONCAT(e.first_name, ' ', e.last_name)   AS employee_name,
    COUNT(lr.request_id)                     AS total_requests,
    -- NULLs silently excluded: employee with only NULL leave_type → NULL result
    GROUP_CONCAT(
        DISTINCT lr.leave_type
        ORDER BY lr.leave_type
        SEPARATOR ', '
    )                                        AS leave_types_raw,
    -- COALESCE before GROUP_CONCAT to represent NULLs as 'Unknown'
    GROUP_CONCAT(
        DISTINCT COALESCE(lr.leave_type, 'Unknown')
        ORDER BY COALESCE(lr.leave_type, 'Unknown')
        SEPARATOR ', '
    )                                        AS leave_types_with_unknown
FROM employees e
JOIN leave_requests lr ON e.emp_id = lr.emp_id
GROUP BY e.emp_id, e.first_name, e.last_name
ORDER BY e.emp_id;

-- leave_types_raw for request 11's employee: if they only have NULL leave_type,
-- GROUP_CONCAT returns NULL (not an empty string).
-- leave_types_with_unknown: shows 'Unknown' for that employee instead.
-- Feature vs. bug: NULLs-excluded is documented behavior, but surprises analysts
-- who expect GROUP_CONCAT to behave like SUM (which treats NULL as 0).


-- =============================================================================
-- SECTION 9: JSON-like summary per department using string functions
-- =============================================================================
-- Pure string manipulation to build a pseudo-JSON summary without JSON functions.
-- Also shown: the clean MySQL 8.0 approach using JSON_OBJECT.
-- Expected: 8 rows; one JSON-like string per department.

SELECT
    d.dept_id,
    d.dept_name,
    -- Manual string concatenation approach (works on all MySQL versions):
    CONCAT(
        '{',
        '"dept_id":', d.dept_id, ',',
        '"dept":"', d.dept_name, '",',
        '"location":"', COALESCE(d.location, 'Unknown'), '",',
        '"employees":', COUNT(e.emp_id), ',',
        '"avg_salary":', COALESCE(ROUND(AVG(e.salary), 0), 'null'), ',',
        '"active":', SUM(CASE WHEN e.status='Active' THEN 1 ELSE 0 END),
        '}'
    )                                        AS dept_summary_manual,
    -- MySQL 8.0 clean approach: JSON_OBJECT (properly escapes special chars)
    JSON_OBJECT(
        'dept_id',   d.dept_id,
        'dept',      d.dept_name,
        'location',  d.location,
        'employees', COUNT(e.emp_id),
        'avg_salary', ROUND(AVG(e.salary), 0),
        'active',     SUM(CASE WHEN e.status='Active' THEN 1 ELSE 0 END)
    )                                        AS dept_summary_json
FROM departments d
LEFT JOIN employees e ON d.dept_id = e.dept_id
GROUP BY d.dept_id, d.dept_name, d.location
ORDER BY d.dept_id;

-- Prefer JSON_OBJECT over manual concatenation:
-- • Automatically escapes quotes and special characters in string values
-- • Returns a proper JSON type, not VARCHAR — can be queried with JSON path operators
-- • dept_name or location containing a " would break the manual version

-- Example downstream use: extract a field from the JSON column:
-- SELECT dept_summary_json->>'$.employees' AS emp_count FROM (above query) AS t;
