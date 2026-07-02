-- =============================================================================
-- FILE: 04-set-operations-anti-join.sql
-- TOPIC: Set Operations and Anti-Join Patterns
-- DB: sql-patterns
-- Covers: UNION, UNION ALL, INTERSECT (8.0.31+), anti-join via NOT IN /
--         NOT EXISTS / LEFT JOIN IS NULL, relational division, EXCEPT workaround
-- =============================================================================

USE `sql-patterns`;

-- =============================================================================
-- SECTION 1: UNION — all status values from employees OR projects (deduplicated)
-- =============================================================================
-- UNION removes duplicates across the two result sets.
-- The 'source' column tells you WHERE a status value appears.
-- Expected: employees has statuses like 'Active','Terminated','On Leave';
-- projects has 'Active','Planning','Completed'. 'Active' appears in both sources.

SELECT DISTINCT status AS status_value, 'employees' AS source
FROM employees

UNION

SELECT DISTINCT status, 'projects' AS source
FROM projects

ORDER BY status_value, source;

-- UNION deduplicates across BOTH sets: if you want to know which sources have
-- a given status, the DISTINCT on each branch ensures you don't get dups within
-- a source, and UNION deduplicates identical (status_value, source) pairs.
-- Expected result: 'Active' appears in BOTH employee and project source rows
-- (they are distinct rows because source differs).


-- =============================================================================
-- SECTION 2: UNION ALL — all salary values ever recorded (no dedup)
-- =============================================================================
-- UNION ALL keeps duplicates. Use when you need ALL occurrences, not just distinct.
-- salary_before IS NULL for initial hires — exclude them with WHERE.
-- Expected: 34 salary_history rows. salary_before NULLs excluded from first branch,
-- so result = (rows with non-null salary_before) + (all salary_after rows).

SELECT 'salary_before' AS salary_type, salary_before AS salary, emp_id, effective_date
FROM salary_history
WHERE salary_before IS NOT NULL     -- initial hires have NULL salary_before

UNION ALL

SELECT 'salary_after', salary_after, emp_id, effective_date
FROM salary_history

ORDER BY emp_id, effective_date, salary_type;

-- Typical use: feed this into an outer query to get MIN/MAX/AVG across both columns.
-- Example:
SELECT
    emp_id,
    MIN(salary) AS min_ever,
    MAX(salary) AS max_ever,
    COUNT(*)    AS data_points
FROM (
    SELECT emp_id, salary_before AS salary FROM salary_history WHERE salary_before IS NOT NULL
    UNION ALL
    SELECT emp_id, salary_after             FROM salary_history
) AS all_salaries
GROUP BY emp_id
ORDER BY emp_id;


-- =============================================================================
-- SECTION 3: INTERSECT — employees who are assigned to a project
-- =============================================================================
-- INTERSECT returns rows present in BOTH result sets.
-- Requires MySQL 8.0.31+. Produces the same result as an INNER JOIN or IN subquery.

-- Method A: INTERSECT (MySQL 8.0.31+)
SELECT emp_id FROM employees
INTERSECT
SELECT DISTINCT emp_id FROM project_assignments;

-- Method B: Workaround for MySQL < 8.0.31 — INNER JOIN equivalent
SELECT DISTINCT e.emp_id
FROM employees e
JOIN project_assignments pa ON e.emp_id = pa.emp_id
ORDER BY e.emp_id;

-- Method C: IN subquery (equivalent, readable)
SELECT emp_id
FROM employees
WHERE emp_id IN (SELECT DISTINCT emp_id FROM project_assignments)
ORDER BY emp_id;

-- All three methods return the same set of emp_ids.
-- Expected: the subset of 41 employees who appear in project_assignments.
-- project_assignments has no NULL emp_id, so IN subquery is safe here.


-- =============================================================================
-- SECTION 4: Anti-join via NOT IN — employees NOT assigned to any project
-- =============================================================================
-- NOT IN is concise but has a critical NULL trap: see explanation below.

SELECT emp_id, first_name, last_name, dept_id, status
FROM employees
WHERE emp_id NOT IN (
    SELECT emp_id FROM project_assignments
    -- If ANY emp_id in project_assignments were NULL, this entire subquery
    -- would return UNKNOWN for every comparison and the outer result = 0 rows.
    -- project_assignments.emp_id has NO NULL values (FK constraint), so safe here.
)
ORDER BY emp_id;

-- THE NULL TRAP (3-valued logic):
-- SQL uses three truth values: TRUE, FALSE, UNKNOWN.
-- NOT IN is syntactic sugar for: emp_id != v1 AND emp_id != v2 AND ...
-- If ANY value in the list is NULL: emp_id != NULL → UNKNOWN.
-- UNKNOWN AND anything → UNKNOWN. So the WHERE clause returns UNKNOWN, not TRUE.
-- Result: a row where the emp_id genuinely is NOT in the list is filtered out.
-- In plain English: NOT IN with NULLs silently returns an EMPTY result set.

-- DEMO of the trap (do not run destructively — this is illustrative):
-- If you ran: WHERE emp_id NOT IN (SELECT NULL) → returns 0 rows for ANY emp_id.
-- Always inspect the subquery for potential NULLs before using NOT IN.


-- =============================================================================
-- SECTION 5: Anti-join via NOT EXISTS — the safe standard pattern
-- =============================================================================
-- NOT EXISTS is immune to the NULL trap. The correlated subquery returns
-- TRUE or FALSE (never UNKNOWN) for each outer row.
-- Expected: same result as Section 4.

SELECT e.emp_id, e.first_name, e.last_name, e.dept_id, e.status
FROM employees e
WHERE NOT EXISTS (
    SELECT 1
    FROM project_assignments pa
    WHERE pa.emp_id = e.emp_id
    -- Correlated: for each outer employee row, check if any assignment row exists.
    -- If project_assignments.emp_id were NULL, pa.emp_id = e.emp_id evaluates to
    -- UNKNOWN for that NULL row, so that row does NOT satisfy the EXISTS check.
    -- The correlated subquery as a whole still returns FALSE → outer row is kept.
)
ORDER BY e.emp_id;

-- NOT EXISTS behavior:
-- • If correlated subquery returns ≥1 row: EXISTS=TRUE → NOT EXISTS=FALSE → row excluded.
-- • If correlated subquery returns 0 rows: EXISTS=FALSE → NOT EXISTS=TRUE → row included.
-- • NULL values in pa.emp_id: the NULL row fails pa.emp_id = e.emp_id (UNKNOWN),
--   so it does NOT count as a match → safe.


-- =============================================================================
-- SECTION 6: Anti-join via LEFT JOIN ... IS NULL — often the fastest plan
-- =============================================================================
-- Left join + IS NULL on the right key is the traditional high-performance anti-join.
-- The optimizer often converts this to the same plan as NOT EXISTS.
-- Expected: same result as Sections 4 and 5.

SELECT e.emp_id, e.first_name, e.last_name, e.dept_id, e.status
FROM employees e
LEFT JOIN project_assignments pa ON e.emp_id = pa.emp_id
WHERE pa.emp_id IS NULL              -- NULL here means no match was found
ORDER BY e.emp_id;

-- Why pa.emp_id IS NULL works:
-- For rows where the join found a match, pa.emp_id = e.emp_id (not NULL).
-- For rows where no match existed, all right-side columns are NULL.
-- So WHERE pa.emp_id IS NULL selects exactly the unmatched left-side rows.
-- IMPORTANT: pa.assignment_id IS NULL would also work and is slightly safer
-- (assignment_id is the PK, guaranteed non-NULL in matched rows).


-- =============================================================================
-- SECTION 7: All three anti-join methods compared
-- =============================================================================
-- This query runs all three in one statement using subqueries + UNION to verify
-- they return the same set of emp_ids.

-- Anti-join result via NOT IN
SELECT 'NOT IN'      AS method, emp_id FROM employees
WHERE emp_id NOT IN (SELECT emp_id FROM project_assignments)

UNION ALL

-- Anti-join result via NOT EXISTS
SELECT 'NOT EXISTS'  AS method, e.emp_id FROM employees e
WHERE NOT EXISTS (SELECT 1 FROM project_assignments pa WHERE pa.emp_id = e.emp_id)

UNION ALL

-- Anti-join result via LEFT JOIN IS NULL
SELECT 'LEFT JOIN'   AS method, e.emp_id FROM employees e
LEFT JOIN project_assignments pa ON e.emp_id = pa.emp_id
WHERE pa.emp_id IS NULL

ORDER BY method, emp_id;

-- All three methods should return the same emp_ids.
-- If counts differ: a NULL in project_assignments.emp_id is the most likely cause.
-- Verify: SELECT COUNT(*) FROM project_assignments WHERE emp_id IS NULL;

-- PERFORMANCE COMPARISON (general guidance):
-- • NOT EXISTS: correlated; optimizer usually converts to anti-join hash/merge.
-- • LEFT JOIN IS NULL: explicit anti-join; often identical plan to NOT EXISTS.
-- • NOT IN: subject to extra NULL-check overhead; avoided for large sets with NULLs.
-- Always EXPLAIN ANALYZE to verify the actual plan for your data distribution.


-- =============================================================================
-- SECTION 8: Relational division — departments that ordered EVERY item_category
-- =============================================================================
-- "Shopping cart completeness": which depts have at least one order in every
-- distinct item_category that appears across all purchase orders?
-- This is the relational division pattern: "for all X, there exists Y".
-- Expected: likely 0–1 depts given only 25 orders across 8 categories.

-- Step 1: How many distinct categories exist across all orders?
-- Step 2: Which depts have that same count of distinct categories?

SELECT
    po.dept_id,
    d.dept_name,
    COUNT(DISTINCT po.item_category)    AS distinct_categories_ordered,
    (SELECT COUNT(DISTINCT item_category)
     FROM purchase_orders)              AS total_categories_in_system
FROM purchase_orders po
LEFT JOIN departments d ON po.dept_id = d.dept_id
WHERE po.dept_id IS NOT NULL
GROUP BY po.dept_id, d.dept_name
HAVING COUNT(DISTINCT po.item_category) = (
    SELECT COUNT(DISTINCT item_category)
    FROM purchase_orders
)
ORDER BY po.dept_id;

-- If HAVING matches 0 rows: no single department ordered all 8 categories.
-- Alternative formulation using NOT EXISTS (pure relational division):
SELECT DISTINCT po1.dept_id
FROM purchase_orders po1
WHERE NOT EXISTS (
    -- "There is no category that this dept has NOT ordered"
    SELECT DISTINCT item_category FROM purchase_orders
    EXCEPT
    SELECT item_category FROM purchase_orders po2 WHERE po2.dept_id = po1.dept_id
    -- Note: EXCEPT not available in MySQL; use NOT IN workaround:
);

-- MySQL-safe relational division using NOT EXISTS + NOT IN:
SELECT DISTINCT po_outer.dept_id
FROM purchase_orders po_outer
WHERE NOT EXISTS (
    SELECT all_cats.item_category
    FROM (SELECT DISTINCT item_category FROM purchase_orders) AS all_cats
    WHERE all_cats.item_category NOT IN (
        SELECT po_inner.item_category
        FROM purchase_orders po_inner
        WHERE po_inner.dept_id = po_outer.dept_id
    )
)
ORDER BY dept_id;


-- =============================================================================
-- SECTION 9: INTERSECT logic — employees reviewed in BOTH 2023-H1 AND 2023-H2
-- =============================================================================
-- Business question: who has reviews in both H1 and H2 of 2023?
-- INTERSECT (MySQL 8.0.31+) vs INNER JOIN workaround for older versions.

-- Method A: INTERSECT (MySQL 8.0.31+)
SELECT emp_id FROM performance_reviews WHERE review_period = '2023-H1'
INTERSECT
SELECT emp_id FROM performance_reviews WHERE review_period = '2023-H2';

-- Method B: INNER JOIN workaround for MySQL < 8.0.31
SELECT DISTINCT r1.emp_id
FROM performance_reviews r1
JOIN performance_reviews r2
    ON  r1.emp_id       = r2.emp_id
    AND r1.review_period = '2023-H1'
    AND r2.review_period = '2023-H2'
ORDER BY r1.emp_id;

-- Method C: Double IN subquery
SELECT emp_id
FROM performance_reviews
WHERE review_period = '2023-H1'
  AND emp_id IN (
      SELECT emp_id FROM performance_reviews WHERE review_period = '2023-H2'
  )
ORDER BY emp_id;

-- All three methods return the same emp_ids.
-- Expected: some employees; performance_reviews has 20 rows across 3 periods.


-- =============================================================================
-- SECTION 10: EXCEPT logic — reviewed in 2023-H1 but NOT in 2023-H2
-- =============================================================================
-- MySQL has no EXCEPT keyword. Use NOT EXISTS (safest) or NOT IN.
-- Business question: employees who got a H1 review but fell through the cracks
-- for H2 — useful for compliance or follow-up tracking.

-- Method A: NOT EXISTS (recommended — safe with NULLs, readable)
SELECT DISTINCT r1.emp_id
FROM performance_reviews r1
WHERE r1.review_period = '2023-H1'
  AND NOT EXISTS (
      SELECT 1
      FROM performance_reviews r2
      WHERE r2.emp_id       = r1.emp_id
        AND r2.review_period = '2023-H2'
  )
ORDER BY r1.emp_id;

-- Method B: LEFT JOIN IS NULL
SELECT DISTINCT r1.emp_id
FROM performance_reviews r1
LEFT JOIN performance_reviews r2
    ON  r1.emp_id       = r2.emp_id
    AND r2.review_period = '2023-H2'
WHERE r1.review_period = '2023-H1'
  AND r2.emp_id IS NULL           -- no 2023-H2 review found for this employee
ORDER BY r1.emp_id;

-- Method C: NOT IN (safe here — emp_id has no NULLs in performance_reviews)
SELECT DISTINCT emp_id
FROM performance_reviews
WHERE review_period = '2023-H1'
  AND emp_id NOT IN (
      SELECT emp_id FROM performance_reviews WHERE review_period = '2023-H2'
  )
ORDER BY emp_id;

-- All three return the same result.
-- Expected: the set difference between 2023-H1 reviewees and 2023-H2 reviewees.
-- If performance_reviews.emp_id could be NULL: Methods A and B remain safe;
-- Method C would return 0 rows (NULL trap). Always prefer A or B for robustness.

-- FULL OUTER JOIN equivalent (for completeness):
-- MySQL has no FULL OUTER JOIN. Simulate with UNION of LEFT JOIN + RIGHT JOIN:
SELECT
    r1.emp_id                                   AS h1_emp,
    r2.emp_id                                   AS h2_emp,
    COALESCE(r1.emp_id, r2.emp_id)              AS emp_id,
    CASE WHEN r1.emp_id IS NOT NULL THEN 'Yes' ELSE 'No' END AS has_2023H1,
    CASE WHEN r2.emp_id IS NOT NULL THEN 'Yes' ELSE 'No' END AS has_2023H2
FROM (SELECT DISTINCT emp_id FROM performance_reviews WHERE review_period = '2023-H1') r1
LEFT JOIN
     (SELECT DISTINCT emp_id FROM performance_reviews WHERE review_period = '2023-H2') r2
    ON r1.emp_id = r2.emp_id

UNION

SELECT
    r1.emp_id,
    r2.emp_id,
    COALESCE(r1.emp_id, r2.emp_id),
    CASE WHEN r1.emp_id IS NOT NULL THEN 'Yes' ELSE 'No' END,
    CASE WHEN r2.emp_id IS NOT NULL THEN 'Yes' ELSE 'No' END
FROM (SELECT DISTINCT emp_id FROM performance_reviews WHERE review_period = '2023-H1') r1
RIGHT JOIN
      (SELECT DISTINCT emp_id FROM performance_reviews WHERE review_period = '2023-H2') r2
    ON r1.emp_id = r2.emp_id

ORDER BY emp_id;

-- This full outer join equivalent shows:
-- has_2023H1=Yes, has_2023H2=No → reviewed in H1 only (EXCEPT result)
-- has_2023H1=Yes, has_2023H2=Yes → reviewed in both (INTERSECT result)
-- has_2023H1=No,  has_2023H2=Yes → reviewed in H2 only (reverse EXCEPT result)
