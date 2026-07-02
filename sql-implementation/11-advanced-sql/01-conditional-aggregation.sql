-- =============================================================================
-- FILE: 01-conditional-aggregation.sql
-- TOPIC: Conditional Aggregation Patterns
-- DB: sql-patterns
-- Covers: CASE WHEN inside SUM/COUNT, conditional AVG, PIVOT via CASE,
--         conditional HAVING, basket analysis, boolean flags, self-join pivot
-- =============================================================================

USE `sql-patterns`;

-- =============================================================================
-- SECTION 1: Employee count by status per department (SUM + CASE WHEN)
-- =============================================================================
-- Pattern: CASE WHEN inside SUM acts as a conditional counter.
-- NULL salary count reveals data quality issues per department.
-- Expected: 8 rows (one per dept); Engineering dept=1 shows 14 total employees.

SELECT
    d.dept_id,
    d.dept_name,
    COUNT(*)                                                           AS total_employees,
    SUM(CASE WHEN e.status = 'Active'     THEN 1 ELSE 0 END)          AS active_count,
    SUM(CASE WHEN e.status = 'Terminated' THEN 1 ELSE 0 END)          AS terminated_count,
    SUM(CASE WHEN e.status = 'On Leave'   THEN 1 ELSE 0 END)          AS on_leave_count,
    -- NULL salary audit: data quality flag per department
    SUM(CASE WHEN e.salary IS NULL        THEN 1 ELSE 0 END)          AS null_salary_count,
    -- Percentage of active employees
    ROUND(
        100.0 * SUM(CASE WHEN e.status = 'Active' THEN 1 ELSE 0 END)
              / COUNT(*),
        1
    )                                                                  AS pct_active
FROM departments d
JOIN employees e ON d.dept_id = e.dept_id
GROUP BY d.dept_id, d.dept_name
ORDER BY total_employees DESC;

-- Expected: Engineering (dept 1) has 14 employees and will show the highest count.
-- null_salary_count reveals emp 19 (salary=0.00) is NOT null; truly NULL salaries
-- are a different issue. Adjust if needed: CASE WHEN salary IS NULL OR salary = 0.


-- =============================================================================
-- SECTION 2: Conditional AVG — excluding outliers / filtering by status
-- =============================================================================
-- NULLIF trick: NULLIF(salary, 0) turns 0.00 into NULL so AVG ignores it.
-- AVG ignores NULLs natively, so wrapping in CASE...ELSE NULL also works.
-- Expected: avg_excl_zero will differ from avg_all only if emp 19 salary=0.

SELECT
    d.dept_id,
    d.dept_name,
    -- Naive average — includes 0.00 salary (emp 19 in Engineering)
    ROUND(AVG(e.salary), 2)                                              AS avg_salary_all,
    -- NULLIF turns 0.00 → NULL so AVG skips it
    ROUND(AVG(NULLIF(e.salary, 0)), 2)                                   AS avg_excl_zero,
    -- Active employees only: non-active rows yield NULL, AVG ignores them
    ROUND(AVG(CASE WHEN e.status = 'Active' THEN e.salary ELSE NULL END), 2)
                                                                         AS avg_active_only,
    -- Combined: active AND non-zero
    ROUND(AVG(CASE WHEN e.status = 'Active' AND e.salary > 0
                   THEN e.salary ELSE NULL END), 2)                      AS avg_active_nonzero
FROM departments d
JOIN employees e ON d.dept_id = e.dept_id
GROUP BY d.dept_id, d.dept_name
ORDER BY avg_active_only DESC NULLS LAST;

-- Note: MySQL does not support NULLS LAST; replace with:
-- ORDER BY CASE WHEN avg_active_only IS NULL THEN 1 ELSE 0 END, avg_active_only DESC


-- =============================================================================
-- SECTION 3: PIVOT — performance_reviews rotated to one row per employee
-- =============================================================================
-- Technique: MAX(CASE WHEN period=X THEN rating END) collapses multiple review
-- rows into a single wide row. NULL means "not reviewed that period" — not zero.
-- Expected: 20 review rows → up to ~14 distinct employees, 3 period columns.

SELECT
    e.emp_id,
    CONCAT(e.first_name, ' ', e.last_name)                             AS employee_name,
    e.dept_id,
    -- Each column shows the rating for that period; NULL = not reviewed
    MAX(CASE WHEN pr.review_period = '2023-H1' THEN pr.rating ELSE NULL END) AS rating_2023H1,
    MAX(CASE WHEN pr.review_period = '2023-H2' THEN pr.rating ELSE NULL END) AS rating_2023H2,
    MAX(CASE WHEN pr.review_period = '2024-H1' THEN pr.rating ELSE NULL END) AS rating_2024H1,
    -- Trend: 2024-H1 minus 2023-H2 (NULL if either period missing)
    MAX(CASE WHEN pr.review_period = '2024-H1' THEN pr.rating ELSE NULL END)
    - MAX(CASE WHEN pr.review_period = '2023-H2' THEN pr.rating ELSE NULL END)
                                                                       AS trend_H2_to_2024H1,
    COUNT(pr.review_id)                                                AS total_reviews
FROM employees e
LEFT JOIN performance_reviews pr ON e.emp_id = pr.emp_id
GROUP BY e.emp_id, e.first_name, e.last_name, e.dept_id
HAVING COUNT(pr.review_id) > 0        -- only employees with at least one review
ORDER BY e.emp_id;

-- NULL in rating_2023H1 means that employee had no '2023-H1' review row.
-- This is NOT the same as a NULL rating value — distinguish them:
-- MAX(CASE WHEN review_period='2023-H1' AND rating IS NULL THEN -1 ELSE rating END)
-- would surface "reviewed but no rating given" as -1 vs "not reviewed" as NULL.


-- =============================================================================
-- SECTION 4: Conditional COUNT with HAVING — departments >50% high-earners
-- =============================================================================
-- Business question: which departments have majority of staff earning >100k?
-- HAVING filters groups after aggregation; cannot use window functions in HAVING.
-- Expected: likely Engineering, Finance, or leadership-heavy depts.

SELECT
    d.dept_id,
    d.dept_name,
    COUNT(*)                                                            AS total_headcount,
    SUM(CASE WHEN e.salary > 100000 THEN 1 ELSE 0 END)                 AS above_100k_count,
    SUM(CASE WHEN e.salary <= 100000 OR e.salary IS NULL THEN 1 ELSE 0 END)
                                                                        AS at_or_below_100k,
    ROUND(
        100.0 * SUM(CASE WHEN e.salary > 100000 THEN 1 ELSE 0 END)
              / COUNT(*),
        1
    )                                                                   AS pct_above_100k
FROM departments d
JOIN employees e ON d.dept_id = e.dept_id
GROUP BY d.dept_id, d.dept_name
HAVING SUM(CASE WHEN e.salary > 100000 THEN 1 ELSE 0 END) > COUNT(*) * 0.5
ORDER BY pct_above_100k DESC;

-- Note: NULL salaries are NOT > 100000 so they fall into "at_or_below" bucket.
-- If you want to exclude NULLs from the denominator:
--   HAVING SUM(...) > SUM(CASE WHEN salary IS NOT NULL THEN 1 ELSE 0 END) * 0.5


-- =============================================================================
-- SECTION 5: Conditional SUM — purchase basket / spend by category per dept
-- =============================================================================
-- Pivot purchase_orders: one row per dept, one column per item_category.
-- All 8 categories from the schema are represented. Zero (not NULL) for missing.
-- Expected: 25 purchase_order rows spread across depts; some depts have 0 in several cols.

SELECT
    po.dept_id,
    d.dept_name,
    COUNT(po.order_id)                                                  AS total_orders,
    ROUND(SUM(po.amount), 2)                                            AS total_spend,
    -- Conditional SUM per category
    ROUND(SUM(CASE WHEN po.item_category = 'Software'        THEN po.amount ELSE 0 END), 2)
                                                                        AS software_spend,
    ROUND(SUM(CASE WHEN po.item_category = 'Hardware'        THEN po.amount ELSE 0 END), 2)
                                                                        AS hardware_spend,
    ROUND(SUM(CASE WHEN po.item_category = 'Cloud Services'  THEN po.amount ELSE 0 END), 2)
                                                                        AS cloud_spend,
    ROUND(SUM(CASE WHEN po.item_category = 'Training'        THEN po.amount ELSE 0 END), 2)
                                                                        AS training_spend,
    ROUND(SUM(CASE WHEN po.item_category = 'Travel'          THEN po.amount ELSE 0 END), 2)
                                                                        AS travel_spend,
    ROUND(SUM(CASE WHEN po.item_category = 'Office Supplies' THEN po.amount ELSE 0 END), 2)
                                                                        AS office_spend,
    ROUND(SUM(CASE WHEN po.item_category = 'Legal Services'  THEN po.amount ELSE 0 END), 2)
                                                                        AS legal_spend,
    ROUND(SUM(CASE WHEN po.item_category = 'Consulting'      THEN po.amount ELSE 0 END), 2)
                                                                        AS consulting_spend
FROM purchase_orders po
LEFT JOIN departments d ON po.dept_id = d.dept_id
GROUP BY po.dept_id, d.dept_name
ORDER BY total_spend DESC;

-- ELSE 0 (not ELSE NULL) ensures missing categories show 0, not NULL.
-- Use ELSE NULL if you need to distinguish "no orders" from "orders totaling 0".


-- =============================================================================
-- SECTION 6: Boolean flags as columns — per-employee data quality profile
-- =============================================================================
-- These 1/0 flags can be summed at higher aggregation levels or used in WHERE.
-- Expected: 41 rows; emp 19 shows has_zero_salary=1; some show has_null_email=1.

SELECT
    e.emp_id,
    CONCAT(e.first_name, ' ', e.last_name)                              AS employee_name,
    e.dept_id,
    e.status,
    -- Data quality flags
    CASE WHEN e.salary IS NULL           THEN 1 ELSE 0 END              AS has_null_salary,
    CASE WHEN e.salary = 0               THEN 1 ELSE 0 END              AS has_zero_salary,
    CASE WHEN e.email IS NULL            THEN 1 ELSE 0 END              AS has_null_email,
    -- Status flags
    CASE WHEN e.status = 'Terminated'    THEN 1 ELSE 0 END              AS is_terminated,
    CASE WHEN e.status = 'On Leave'      THEN 1 ELSE 0 END              AS is_on_leave,
    -- Future hire: hire_date after today (data anomaly check)
    CASE WHEN e.hire_date > CURDATE()    THEN 1 ELSE 0 END              AS is_future_hire,
    -- Manager flag: this employee manages someone else
    CASE WHEN EXISTS (
        SELECT 1 FROM employees sub WHERE sub.manager_id = e.emp_id
    )                                    THEN 1 ELSE 0 END              AS is_manager,
    -- Has open project assignment
    CASE WHEN EXISTS (
        SELECT 1 FROM project_assignments pa
        WHERE pa.emp_id = e.emp_id AND pa.end_date IS NULL
    )                                    THEN 1 ELSE 0 END              AS has_open_assignment
FROM employees e
ORDER BY e.emp_id;

-- Aggregate the flags to get a company-wide data quality summary:
-- SELECT SUM(has_null_salary), SUM(has_null_email), SUM(is_terminated), ...
-- FROM (above query) AS flags;


-- =============================================================================
-- SECTION 7: Conditional aggregation vs self-join pivot — equivalence demo
-- =============================================================================
-- Approach A: Conditional aggregation (single pass, efficient)
-- Approach B: Self-join (three-way join, verbose, less efficient)
-- Both produce identical results for the rating pivot.

-- Approach A: Conditional aggregation (preferred)
SELECT
    e.emp_id,
    CONCAT(e.first_name, ' ', e.last_name)                              AS employee_name,
    MAX(CASE WHEN pr.review_period = '2023-H1' THEN pr.rating END)      AS h1_2023_cond,
    MAX(CASE WHEN pr.review_period = '2023-H2' THEN pr.rating END)      AS h2_2023_cond,
    MAX(CASE WHEN pr.review_period = '2024-H1' THEN pr.rating END)      AS h1_2024_cond
FROM employees e
JOIN performance_reviews pr ON e.emp_id = pr.emp_id
GROUP BY e.emp_id, e.first_name, e.last_name;

-- Approach B: Self-join equivalent (one join per period — does NOT scale)
SELECT
    e.emp_id,
    CONCAT(e.first_name, ' ', e.last_name)                              AS employee_name,
    r1.rating                                                            AS h1_2023_selfjoin,
    r2.rating                                                            AS h2_2023_selfjoin,
    r3.rating                                                            AS h1_2024_selfjoin
FROM employees e
LEFT JOIN performance_reviews r1
    ON r1.emp_id = e.emp_id AND r1.review_period = '2023-H1'
LEFT JOIN performance_reviews r2
    ON r2.emp_id = e.emp_id AND r2.review_period = '2023-H2'
LEFT JOIN performance_reviews r3
    ON r3.emp_id = e.emp_id AND r3.review_period = '2024-H1'
WHERE r1.review_id IS NOT NULL
   OR r2.review_id IS NOT NULL
   OR r3.review_id IS NOT NULL   -- only employees with at least one review
ORDER BY e.emp_id;

-- Why conditional aggregation wins:
-- • Single table scan of performance_reviews vs 3 separate lookups
-- • Adding a 4th period = 1 CASE WHEN line vs another JOIN clause
-- • Self-join produces duplicate rows if an employee has multiple reviews
--   per period; conditional agg collapses with MAX/SUM cleanly.
-- • Self-join approach requires careful DISTINCT or GROUP BY to deduplicate.
