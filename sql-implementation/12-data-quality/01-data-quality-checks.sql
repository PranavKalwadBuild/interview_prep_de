-- =============================================================================
-- FILE: 01-data-quality-checks.sql
-- DATABASE: sql-patterns
-- PURPOSE: Comprehensive data quality checks: nulls, duplicates, range violations,
--          orphaned FKs, date overlaps, soft duplicates, distribution skew,
--          referential consistency, and a DQ scorecard.
-- KNOWN FLAWS SURFACED:
--   emp 10/15 salary NULL, emp 19 salary=0, emp 22 email NULL
--   emp 35 status=Terminated with termination_date
--   emp 41 future hire_date
--   salary_history exact dup (emp 5, 2022-04-01)
--   project 11 end_date < start_date; project 7 budget NULL
--   project_assignments exact dup (emp 9, proj 9)
--   purchase_orders 19-20 exact dup; order 25 dept_id NULL
--   leave_requests 1-2 emp 12 overlap; request 11 leave_type NULL
-- =============================================================================

USE `sql-patterns`;

-- =============================================================================
-- SECTION 1: NULL AUDIT (Completeness Checks)
-- =============================================================================

-- 1a. NULL audit on employees — key nullable columns
SELECT
    COUNT(*)                                                              AS total_rows,
    SUM(CASE WHEN email            IS NULL THEN 1 ELSE 0 END)            AS null_email,
    SUM(CASE WHEN salary           IS NULL THEN 1 ELSE 0 END)            AS null_salary,
    SUM(CASE WHEN termination_date IS NULL THEN 1 ELSE 0 END)            AS null_term_date,
    SUM(CASE WHEN phone            IS NULL THEN 1 ELSE 0 END)            AS null_phone,
    SUM(CASE WHEN dept_id          IS NULL THEN 1 ELSE 0 END)            AS null_dept_id,
    ROUND(SUM(CASE WHEN email   IS NULL THEN 1 ELSE 0 END)*100.0/COUNT(*), 2) AS pct_null_email,
    ROUND(SUM(CASE WHEN salary  IS NULL THEN 1 ELSE 0 END)*100.0/COUNT(*), 2) AS pct_null_salary,
    ROUND(SUM(CASE WHEN termination_date IS NULL THEN 1 ELSE 0 END)*100.0/COUNT(*), 2)
                                                                         AS pct_null_term_date
FROM employees;
-- Expected: 1 null email (emp 22), 2 null salary (emp 10, 15), many null termination_date (active emps)

-- 1b. NULL audit on purchase_orders — dept_id can be NULL (orphaned orders)
SELECT
    COUNT(*)                                                              AS total_rows,
    SUM(CASE WHEN dept_id IS NULL THEN 1 ELSE 0 END)                     AS null_dept_id,
    ROUND(SUM(CASE WHEN dept_id IS NULL THEN 1 ELSE 0 END)*100.0/COUNT(*), 2)
                                                                         AS pct_null_dept_id
FROM purchase_orders;
-- Expected: 1 null dept_id (order 25)

-- 1c. NULL audit on leave_requests — leave_type should not be NULL
SELECT
    COUNT(*)                                                              AS total_rows,
    SUM(CASE WHEN leave_type IS NULL THEN 1 ELSE 0 END)                  AS null_leave_type,
    ROUND(SUM(CASE WHEN leave_type IS NULL THEN 1 ELSE 0 END)*100.0/COUNT(*), 2)
                                                                         AS pct_null_leave_type
FROM leave_requests;
-- Expected: 1 null leave_type (request 11)

-- 1d. NULL audit on performance_reviews — rating and reviewer_id can be NULL
SELECT
    COUNT(*)                                                              AS total_rows,
    SUM(CASE WHEN rating      IS NULL THEN 1 ELSE 0 END)                 AS null_rating,
    SUM(CASE WHEN reviewer_id IS NULL THEN 1 ELSE 0 END)                 AS null_reviewer_id,
    ROUND(SUM(CASE WHEN rating IS NULL THEN 1 ELSE 0 END)*100.0/COUNT(*), 2)
                                                                         AS pct_null_rating
FROM performance_reviews;

-- 1e. NULL session_id in emp_events (emp 14)
SELECT
    COUNT(*)                                                              AS total_rows,
    SUM(CASE WHEN session_id IS NULL THEN 1 ELSE 0 END)                  AS null_session_id,
    ROUND(SUM(CASE WHEN session_id IS NULL THEN 1 ELSE 0 END)*100.0/COUNT(*), 2)
                                                                         AS pct_null_session_id
FROM emp_events;


-- =============================================================================
-- SECTION 2: EXACT DUPLICATE DETECTION
-- =============================================================================

-- 2a. Exact duplicates in salary_history (all business columns, excluding auto-PK hist_id)
-- Expected: emp 5, 2022-04-01 appears twice with identical values
SELECT
    emp_id,
    salary_before,
    salary_after,
    effective_date,
    change_reason,
    changed_by,
    COUNT(*) AS dup_count
FROM salary_history
GROUP BY
    emp_id,
    salary_before,
    salary_after,
    effective_date,
    change_reason,
    changed_by
HAVING COUNT(*) > 1;

-- 2b. Exact duplicates in purchase_orders (all business columns, excluding order_id)
-- Expected: orders 19-20 are identical (same vendor, dept, amount, date, status, category)
SELECT
    dept_id,
    vendor,
    item_category,
    amount,
    order_date,
    status,
    COUNT(*) AS dup_count
FROM purchase_orders
GROUP BY
    dept_id,
    vendor,
    item_category,
    amount,
    order_date,
    status
HAVING COUNT(*) > 1;

-- 2c. Exact duplicates in project_assignments (all business columns, excluding assignment_id)
-- Expected: emp 9, proj 9 appears twice with same role, dates, hours_billed
SELECT
    emp_id,
    project_id,
    role,
    start_date,
    end_date,
    hours_billed,
    COUNT(*) AS dup_count
FROM project_assignments
GROUP BY
    emp_id,
    project_id,
    role,
    start_date,
    end_date,
    hours_billed
HAVING COUNT(*) > 1;


-- =============================================================================
-- SECTION 3: OUT-OF-RANGE / IMPOSSIBLE VALUES
-- =============================================================================

-- 3a. Employees with salary = 0 (suspicious; should likely be NULL for unknown)
SELECT emp_id, first_name, last_name, salary, status
FROM employees
WHERE salary = 0;
-- Expected: emp 19 (salary=0.00)

-- 3b. Employees with a future hire_date (data entry error)
SELECT emp_id, first_name, last_name, hire_date, status
FROM employees
WHERE hire_date > CURDATE();
-- Expected: emp 41 (hire_date='2025-08-01' — future relative to data load date)

-- 3c. Projects where end_date precedes start_date (impossible range)
SELECT project_id, project_name, start_date, end_date,
       DATEDIFF(end_date, start_date) AS days_duration
FROM projects
WHERE end_date IS NOT NULL
  AND end_date < start_date;
-- Expected: project 11 (end_date='2024-02-28' < start_date='2024-06-01')

-- 3d. Employees with a termination_date but status NOT = 'Terminated' (state mismatch)
SELECT emp_id, first_name, last_name, status, termination_date
FROM employees
WHERE termination_date IS NOT NULL
  AND status != 'Terminated';

-- 3e. Employees with status = 'Terminated' but NULL termination_date (missing end date)
SELECT emp_id, first_name, last_name, status, termination_date
FROM employees
WHERE status = 'Terminated'
  AND termination_date IS NULL;

-- 3f. Performance ratings outside allowed range 1–5
SELECT review_id, emp_id, review_date, rating
FROM performance_reviews
WHERE rating IS NOT NULL
  AND rating NOT BETWEEN 1 AND 5;

-- 3g. Leave requests where end_date precedes start_date
SELECT request_id, emp_id, leave_type, start_date, end_date,
       DATEDIFF(end_date, start_date) AS days
FROM leave_requests
WHERE end_date < start_date;

-- 3h. Salary history: salary_after = 0 (suspicious) or pay cut detection
SELECT
    hist_id,
    emp_id,
    salary_before,
    salary_after,
    effective_date,
    change_reason,
    CASE
        WHEN salary_after = 0 THEN 'Zero salary_after'
        WHEN salary_before IS NOT NULL AND salary_after < salary_before THEN 'Pay cut'
    END AS issue_type
FROM salary_history
WHERE salary_after = 0
   OR (salary_before IS NOT NULL AND salary_after < salary_before);

-- 3i. Projects with NULL budget (may block financial reporting)
SELECT project_id, project_name, dept_id, status, budget
FROM projects
WHERE budget IS NULL;
-- Expected: project 7


-- =============================================================================
-- SECTION 4: ORPHANED FOREIGN KEYS
-- =============================================================================

-- 4a. purchase_orders with NULL dept_id (no owning department — logically orphaned)
SELECT order_id, vendor, item_category, amount, order_date, status
FROM purchase_orders
WHERE dept_id IS NULL;
-- Expected: order 25

-- 4b. salary_history rows where emp_id does NOT exist in employees
--     (hard FK should prevent this, but useful after bulk loads / migrations)
SELECT sh.hist_id, sh.emp_id, sh.effective_date, sh.salary_after
FROM salary_history sh
LEFT JOIN employees e ON sh.emp_id = e.emp_id
WHERE e.emp_id IS NULL;

-- 4c. project_assignments referencing a non-existent project
--     (FK constraint should prevent this; pattern is valuable post-migration)
SELECT pa.assignment_id, pa.emp_id, pa.project_id, pa.start_date
FROM project_assignments pa
LEFT JOIN projects p ON pa.project_id = p.project_id
WHERE p.project_id IS NULL;

-- 4d. project_assignments referencing a non-existent employee
SELECT pa.assignment_id, pa.emp_id, pa.project_id
FROM project_assignments pa
LEFT JOIN employees e ON pa.emp_id = e.emp_id
WHERE e.emp_id IS NULL;


-- =============================================================================
-- SECTION 5: OVERLAPPING DATE RANGE DETECTION
-- =============================================================================

-- 5. Leave requests for the same employee whose date ranges overlap
--    Overlap condition: A.start_date <= B.end_date AND A.end_date >= B.start_date
--    Use lr1.request_id < lr2.request_id to avoid self-join and reverse duplicates
-- Expected: emp 12 requests 1 and 2 overlap
SELECT
    lr1.emp_id,
    lr1.request_id  AS request_id_1,
    lr1.start_date  AS start_1,
    lr1.end_date    AS end_1,
    lr2.request_id  AS request_id_2,
    lr2.start_date  AS start_2,
    lr2.end_date    AS end_2,
    -- How many days they overlap
    DATEDIFF(
        LEAST(lr1.end_date, lr2.end_date),
        GREATEST(lr1.start_date, lr2.start_date)
    ) + 1           AS overlap_days
FROM leave_requests lr1
JOIN leave_requests lr2
    ON  lr1.emp_id     = lr2.emp_id
    AND lr1.request_id < lr2.request_id
    AND lr1.start_date <= lr2.end_date
    AND lr1.end_date   >= lr2.start_date;


-- =============================================================================
-- SECTION 6: SOFT DUPLICATE DETECTION
-- =============================================================================

-- 6a. Employees who share (last_name, dept_id, hire_date) — likely duplicate records
-- Expected: emp 18 and emp 19 (Clark, dept 2, 2017-08-14)
SELECT
    last_name,
    dept_id,
    hire_date,
    COUNT(*)                             AS cnt,
    GROUP_CONCAT(emp_id ORDER BY emp_id) AS emp_ids
FROM employees
GROUP BY last_name, dept_id, hire_date
HAVING COUNT(*) > 1;

-- 6b. Employees with the exact same full name (possible duplicate entry)
SELECT
    first_name,
    last_name,
    COUNT(*)                             AS cnt,
    GROUP_CONCAT(emp_id ORDER BY emp_id) AS emp_ids
FROM employees
GROUP BY first_name, last_name
HAVING COUNT(*) > 1;

-- 6c. Same vendor + dept_id + item_category within 7 days (soft dup in purchase_orders)
--     Catches near-duplicate orders that differ only by order_id and date
SELECT
    po1.order_id    AS order_id_1,
    po2.order_id    AS order_id_2,
    po1.vendor,
    po1.dept_id,
    po1.item_category,
    po1.amount,
    po1.order_date  AS date_1,
    po2.order_date  AS date_2,
    ABS(DATEDIFF(po1.order_date, po2.order_date)) AS days_apart
FROM purchase_orders po1
JOIN purchase_orders po2
    ON  po1.vendor        = po2.vendor
    AND po1.dept_id       = po2.dept_id
    AND po1.item_category = po2.item_category
    AND po1.amount        = po2.amount
    AND po1.order_id      < po2.order_id
    AND ABS(DATEDIFF(po1.order_date, po2.order_date)) <= 7;


-- =============================================================================
-- SECTION 7: DISTRIBUTION SKEW CHECK
-- =============================================================================

-- 7a. Employee headcount per department — identify over-concentrated departments
SELECT
    d.dept_id,
    d.dept_name,
    COUNT(e.emp_id)                                              AS headcount,
    ROUND(COUNT(e.emp_id) * 100.0 / SUM(COUNT(e.emp_id)) OVER (), 1) AS pct_of_total,
    CASE
        WHEN COUNT(e.emp_id) * 100.0 / SUM(COUNT(e.emp_id)) OVER () > 25
        THEN 'SKEWED — > 25% of workforce'
        ELSE 'OK'
    END                                                          AS skew_flag
FROM departments d
LEFT JOIN employees e ON d.dept_id = e.dept_id
GROUP BY d.dept_id, d.dept_name
ORDER BY headcount DESC;
-- Expected: Engineering dept has 14/41 ≈ 34% — flagged as SKEWED

-- 7b. Summary: what % of all employees are in the single largest department?
SELECT
    d.dept_name,
    COUNT(e.emp_id)                                              AS headcount,
    ROUND(COUNT(e.emp_id) * 100.0 / (SELECT COUNT(*) FROM employees), 1)
                                                                 AS pct_of_total
FROM departments d
JOIN employees e ON d.dept_id = e.dept_id
GROUP BY d.dept_id, d.dept_name
ORDER BY headcount DESC
LIMIT 1;


-- =============================================================================
-- SECTION 8: REFERENTIAL CONSISTENCY CHECK (SOFT FK)
-- =============================================================================

-- 8a. departments.manager_id must point to a valid employee
--     A NULL manager_id is allowed (department may be unmanaged); non-NULL must resolve
SELECT
    d.dept_id,
    d.dept_name,
    d.manager_id            AS referenced_manager_id,
    e.emp_id                AS resolved_emp_id
FROM departments d
LEFT JOIN employees e ON d.manager_id = e.emp_id
WHERE d.manager_id IS NOT NULL
  AND e.emp_id IS NULL;
-- Returns rows = broken references; empty = all good

-- 8b. salary_history.changed_by must point to a valid employee (who approved the change)
SELECT
    sh.hist_id,
    sh.emp_id,
    sh.changed_by           AS referenced_changer_id,
    e.emp_id                AS resolved_emp_id
FROM salary_history sh
LEFT JOIN employees e ON sh.changed_by = e.emp_id
WHERE sh.changed_by IS NOT NULL
  AND e.emp_id IS NULL;

-- 8c. performance_reviews.reviewer_id must point to a valid employee (when not NULL)
SELECT
    pr.review_id,
    pr.emp_id,
    pr.reviewer_id          AS referenced_reviewer_id,
    e.emp_id                AS resolved_emp_id
FROM performance_reviews pr
LEFT JOIN employees e ON pr.reviewer_id = e.emp_id
WHERE pr.reviewer_id IS NOT NULL
  AND e.emp_id IS NULL;

-- 8d. employees.manager_id must point to a valid employee (self-referential)
SELECT
    e.emp_id,
    e.first_name,
    e.last_name,
    e.manager_id            AS referenced_manager_id,
    m.emp_id                AS resolved_manager_id
FROM employees e
LEFT JOIN employees m ON e.manager_id = m.emp_id
WHERE e.manager_id IS NOT NULL
  AND m.emp_id IS NULL;


-- =============================================================================
-- SECTION 9: SUMMARY DQ SCORECARD
-- =============================================================================
-- Returns one row per table with: table_name, total_rows, null_count, dup_count, invalid_count
-- Useful as a single-query "data health dashboard" at the start of any pipeline audit.

SELECT
    'employees'             AS table_name,
    COUNT(*)                AS total_rows,
    -- null_count: any critical column is NULL
    SUM(CASE WHEN email IS NULL OR salary IS NULL THEN 1 ELSE 0 END)
                            AS null_count,
    -- dup_count: approximate — identical (first_name, last_name, dept_id, hire_date)
    (
        SELECT COUNT(*) FROM (
            SELECT first_name, last_name, dept_id, hire_date
            FROM employees
            GROUP BY first_name, last_name, dept_id, hire_date
            HAVING COUNT(*) > 1
        ) d
    )                       AS dup_count,
    -- invalid_count: salary=0, future hire_date, terminated status inconsistency
    SUM(
        CASE WHEN salary = 0
               OR hire_date > CURDATE()
               OR (status = 'Terminated' AND termination_date IS NULL)
               OR (termination_date IS NOT NULL AND status != 'Terminated')
             THEN 1 ELSE 0 END
    )                       AS invalid_count
FROM employees

UNION ALL

SELECT
    'salary_history',
    COUNT(*),
    SUM(CASE WHEN salary_after IS NULL THEN 1 ELSE 0 END),
    (
        SELECT COUNT(*) FROM (
            SELECT emp_id, salary_before, salary_after, effective_date, change_reason, changed_by
            FROM salary_history
            GROUP BY emp_id, salary_before, salary_after, effective_date, change_reason, changed_by
            HAVING COUNT(*) > 1
        ) d
    ),
    SUM(CASE WHEN salary_after = 0
               OR (salary_before IS NOT NULL AND salary_after < salary_before)
             THEN 1 ELSE 0 END)
FROM salary_history

UNION ALL

SELECT
    'projects',
    COUNT(*),
    SUM(CASE WHEN budget IS NULL THEN 1 ELSE 0 END),
    0,   -- no soft-dup check on projects
    SUM(CASE WHEN end_date IS NOT NULL AND end_date < start_date THEN 1 ELSE 0 END)
FROM projects

UNION ALL

SELECT
    'project_assignments',
    COUNT(*),
    SUM(CASE WHEN hours_billed IS NULL THEN 1 ELSE 0 END),
    (
        SELECT COUNT(*) FROM (
            SELECT emp_id, project_id, role, start_date, end_date, hours_billed
            FROM project_assignments
            GROUP BY emp_id, project_id, role, start_date, end_date, hours_billed
            HAVING COUNT(*) > 1
        ) d
    ),
    SUM(CASE WHEN end_date IS NOT NULL AND end_date < start_date THEN 1 ELSE 0 END)
FROM project_assignments

UNION ALL

SELECT
    'purchase_orders',
    COUNT(*),
    SUM(CASE WHEN dept_id IS NULL THEN 1 ELSE 0 END),
    (
        SELECT COUNT(*) FROM (
            SELECT dept_id, vendor, item_category, amount, order_date, status
            FROM purchase_orders
            GROUP BY dept_id, vendor, item_category, amount, order_date, status
            HAVING COUNT(*) > 1
        ) d
    ),
    0
FROM purchase_orders

UNION ALL

SELECT
    'leave_requests',
    COUNT(*),
    SUM(CASE WHEN leave_type IS NULL THEN 1 ELSE 0 END),
    0,
    SUM(CASE WHEN end_date < start_date THEN 1 ELSE 0 END)
FROM leave_requests

UNION ALL

SELECT
    'performance_reviews',
    COUNT(*),
    SUM(CASE WHEN rating IS NULL OR reviewer_id IS NULL THEN 1 ELSE 0 END),
    0,
    SUM(CASE WHEN rating IS NOT NULL AND rating NOT BETWEEN 1 AND 5 THEN 1 ELSE 0 END)
FROM performance_reviews

UNION ALL

SELECT
    'emp_events',
    COUNT(*),
    SUM(CASE WHEN session_id IS NULL THEN 1 ELSE 0 END),
    0,
    0
FROM emp_events;
