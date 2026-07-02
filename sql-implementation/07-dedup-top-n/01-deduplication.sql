-- =============================================================================
-- FILE: 01-deduplication.sql
-- DATABASE: sql-patterns
-- TOPIC: Deduplication Patterns in MySQL 8.0+
-- COVERS: Exact dup detection, ROW_NUMBER() dedup, self-join detection,
--         soft duplicate detection, NULL-aware completeness scoring,
--         GROUP BY + MIN dedup (no window functions)
-- KNOWN FLAWS IN DATA:
--   salary_history  : hist_id 15 & 16 exact dup (emp_id=5, 2022-04-01 Promotion)
--   project_assignments: last 2 rows exact dup (emp_id=9, project_id=9)
--   purchase_orders : order_id 19 & 20 exact dup (LearnFast Training, dept 5)
--   employees       : emp 18 & 19 soft dup (Clark, dept 2, same hire_date+job_title)
-- =============================================================================

USE `sql-patterns`;

-- =============================================================================
-- SECTION 1: DETECT EXACT DUPLICATES (GROUP BY ALL BUSINESS COLUMNS)
-- Technique: GROUP BY every business column (exclude the surrogate PK), then
-- HAVING COUNT(*) > 1 surfaces any set of rows that are identical on content.
-- Use this as the first diagnostic step before deciding what to delete.
-- =============================================================================

-- 1a. Exact duplicates in salary_history
-- Business key: everything except hist_id (the auto-increment PK).
-- Expected: 1 group returned — emp_id=5, salary_before=132000, salary_after=145000,
--           effective_date='2022-04-01', change_reason='Promotion', changed_by=2 (cnt=2)
SELECT
    emp_id,
    salary_before,
    salary_after,
    effective_date,
    change_reason,
    changed_by,
    COUNT(*) AS cnt
FROM salary_history
GROUP BY
    emp_id,
    salary_before,
    salary_after,
    effective_date,
    change_reason,
    changed_by
HAVING COUNT(*) > 1;

-- 1b. Exact duplicates in purchase_orders
-- Business key: dept_id, vendor, item_category, amount, order_date (exclude order_id, status
-- if status is operationally assigned; include status here since both rows are identical).
-- Expected: 1 group — dept_id=5, vendor='LearnFast', item_category='Training',
--           amount=5500.00, order_date='2024-03-01', status='Approved' (cnt=2)
SELECT
    dept_id,
    vendor,
    item_category,
    amount,
    order_date,
    status,
    COUNT(*) AS cnt
FROM purchase_orders
GROUP BY
    dept_id,
    vendor,
    item_category,
    amount,
    order_date,
    status
HAVING COUNT(*) > 1;

-- 1c. Exact duplicates in project_assignments
-- Business key: all columns except assignment_id.
-- Expected: 1 group — emp_id=9, project_id=9, role='Data Engineer',
--           start_date='2023-11-01', end_date=NULL, hours_billed=300.00 (cnt=2)
-- NOTE: NULL = NULL is FALSE in a WHERE predicate but GROUP BY treats NULLs as equal,
--       so end_date NULL rows do group together correctly here.
SELECT
    emp_id,
    project_id,
    role,
    start_date,
    end_date,
    hours_billed,
    COUNT(*) AS cnt
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
-- SECTION 2: IDENTIFY ROWS TO KEEP VS DELETE WITH ROW_NUMBER()
-- Technique: Assign ROW_NUMBER() partitioned by all business columns, ordered by
-- the surrogate PK ascending (lowest ID = oldest = keep). Rows with rn > 1 are
-- duplicates to delete.
-- =============================================================================

-- 2a. Show ALL rows in salary_history with their duplicate rank.
-- rn=1 → keep; rn>1 → delete candidate.
-- Expected: hist_id 15 gets rn=1, hist_id 16 gets rn=2.
SELECT
    hist_id,
    emp_id,
    salary_before,
    salary_after,
    effective_date,
    change_reason,
    changed_by,
    ROW_NUMBER() OVER (
        PARTITION BY emp_id, salary_before, salary_after, effective_date, change_reason, changed_by
        ORDER BY hist_id ASC
    ) AS rn
FROM salary_history
ORDER BY emp_id, effective_date, hist_id;

-- 2b. Show only the rows that WOULD BE DELETED (rn > 1) in salary_history.
-- Expected: 1 row — hist_id=16 (the later duplicate).
WITH dups AS (
    SELECT
        hist_id,
        emp_id,
        salary_before,
        salary_after,
        effective_date,
        change_reason,
        changed_by,
        ROW_NUMBER() OVER (
            PARTITION BY emp_id, salary_before, salary_after, effective_date, change_reason, changed_by
            ORDER BY hist_id ASC
        ) AS rn
    FROM salary_history
)
SELECT *
FROM dups
WHERE rn > 1;

-- 2c. Same pattern for purchase_orders — show rows to delete.
-- Expected: 1 row — order_id=20.
WITH dups AS (
    SELECT
        order_id,
        dept_id,
        vendor,
        item_category,
        amount,
        order_date,
        status,
        ROW_NUMBER() OVER (
            PARTITION BY dept_id, vendor, item_category, amount, order_date, status
            ORDER BY order_id ASC
        ) AS rn
    FROM purchase_orders
)
SELECT *
FROM dups
WHERE rn > 1;

-- 2d. Same pattern for project_assignments — show rows to delete.
-- COALESCE handles NULLs in end_date/hours_billed so the PARTITION sees them as equal.
-- Expected: 1 row — the second assignment_id for emp_id=9, project_id=9.
WITH dups AS (
    SELECT
        assignment_id,
        emp_id,
        project_id,
        role,
        start_date,
        end_date,
        hours_billed,
        ROW_NUMBER() OVER (
            PARTITION BY emp_id, project_id, role, start_date,
                         COALESCE(end_date, '9999-12-31'),
                         COALESCE(hours_billed, -1)
            ORDER BY assignment_id ASC
        ) AS rn
    FROM project_assignments
)
SELECT *
FROM dups
WHERE rn > 1;


-- =============================================================================
-- SECTION 3: DELETE DUPLICATES USING ROW_NUMBER() — MYSQL WORKAROUND
-- MySQL 8.0 does NOT allow DELETE directly referencing a CTE or a subquery that
-- reads the same table being deleted from. The workaround: materialize the
-- subquery in a second level of nesting so MySQL sees it as a derived table.
-- =============================================================================

-- 3a. DELETE duplicate salary_history rows (keeps lowest hist_id per business key).
-- The inner SELECT is wrapped in another SELECT so MySQL materializes it first,
-- avoiding "You can't specify target table ... for update in FROM clause".
-- DRY RUN: replace DELETE with SELECT * to verify before executing.
DELETE FROM salary_history
WHERE hist_id IN (
    SELECT hist_id
    FROM (
        SELECT
            hist_id,
            ROW_NUMBER() OVER (
                PARTITION BY emp_id, salary_before, salary_after, effective_date, change_reason, changed_by
                ORDER BY hist_id ASC
            ) AS rn
        FROM salary_history
    ) t
    WHERE rn > 1
);
-- Expected: 1 row deleted (hist_id=16). salary_history now has no dups.

-- 3b. DELETE duplicate purchase_orders rows (keeps lowest order_id per business key).
DELETE FROM purchase_orders
WHERE order_id IN (
    SELECT order_id
    FROM (
        SELECT
            order_id,
            ROW_NUMBER() OVER (
                PARTITION BY dept_id, vendor, item_category, amount, order_date, status
                ORDER BY order_id ASC
            ) AS rn
        FROM purchase_orders
    ) t
    WHERE rn > 1
);
-- Expected: 1 row deleted (order_id=20).

-- 3c. DELETE duplicate project_assignments rows (keeps lowest assignment_id).
DELETE FROM project_assignments
WHERE assignment_id IN (
    SELECT assignment_id
    FROM (
        SELECT
            assignment_id,
            ROW_NUMBER() OVER (
                PARTITION BY emp_id, project_id, role, start_date,
                             COALESCE(end_date, '9999-12-31'),
                             COALESCE(hours_billed, -1)
                ORDER BY assignment_id ASC
            ) AS rn
        FROM project_assignments
    ) t
    WHERE rn > 1
);
-- Expected: 1 row deleted (second assignment for emp_id=9, project_id=9).


-- =============================================================================
-- SECTION 4: SELF-JOIN DUPLICATE DETECTION
-- Technique: Join the table to itself on all business columns with t1.id < t2.id.
-- This returns every pair of duplicates so you can review them before deleting.
-- Advantage over GROUP BY: you see both rows of each pair side by side.
-- =============================================================================

-- 4a. Find duplicate pairs in salary_history via self-join.
-- Condition: same business columns, lower hist_id on left side.
-- Expected: 1 pair — (hist_id=15, hist_id=16) for emp_id=5.
SELECT
    t1.hist_id  AS keep_id,
    t2.hist_id  AS delete_id,
    t1.emp_id,
    t1.salary_before,
    t1.salary_after,
    t1.effective_date,
    t1.change_reason,
    t1.changed_by
FROM salary_history t1
JOIN salary_history t2
    ON  t1.emp_id         = t2.emp_id
    AND t1.salary_after   = t2.salary_after
    AND t1.effective_date = t2.effective_date
    AND t1.change_reason  = t2.change_reason
    AND t1.changed_by     = t2.changed_by
    AND (t1.salary_before = t2.salary_before
         OR (t1.salary_before IS NULL AND t2.salary_before IS NULL))
    AND t1.hist_id < t2.hist_id;

-- 4b. Find duplicate pairs in purchase_orders via self-join.
-- Expected: 1 pair — (order_id=19, order_id=20).
SELECT
    t1.order_id AS keep_id,
    t2.order_id AS delete_id,
    t1.dept_id,
    t1.vendor,
    t1.item_category,
    t1.amount,
    t1.order_date,
    t1.status
FROM purchase_orders t1
JOIN purchase_orders t2
    ON  t1.order_id        < t2.order_id
    AND (t1.dept_id = t2.dept_id OR (t1.dept_id IS NULL AND t2.dept_id IS NULL))
    AND t1.vendor          = t2.vendor
    AND t1.item_category   = t2.item_category
    AND t1.amount          = t2.amount
    AND t1.order_date      = t2.order_date
    AND t1.status          = t2.status;


-- =============================================================================
-- SECTION 5: SOFT DUPLICATE DETECTION
-- Technique: Find records that represent the same real-world entity but differ in
-- at least one column (name spelling, salary=0, etc.). Use a relaxed key.
-- =============================================================================

-- 5a. Employees with same (last_name, dept_id, hire_date, job_title) but different emp_id.
-- A hire on the same date with the same title in the same dept is suspicious.
-- Expected: emp_id=18 (Rachel Clark) and emp_id=19 (Samuel Clark) both surface.
SELECT
    e1.emp_id          AS emp_id_1,
    CONCAT(e1.first_name, ' ', e1.last_name) AS name_1,
    e1.salary          AS salary_1,
    e2.emp_id          AS emp_id_2,
    CONCAT(e2.first_name, ' ', e2.last_name) AS name_2,
    e2.salary          AS salary_2,
    e1.dept_id,
    e1.hire_date,
    e1.job_title
FROM employees e1
JOIN employees e2
    ON  e1.last_name  = e2.last_name
    AND e1.dept_id    = e2.dept_id
    AND e1.hire_date  = e2.hire_date
    AND e1.job_title  = e2.job_title
    AND e1.emp_id     < e2.emp_id;
-- Expected: 1 pair — (emp 18 Rachel Clark, emp 19 Samuel Clark), dept 2, 2017-08-14,
--           Regional Sales Lead. emp 19 has salary=0.00 flagging it as likely bogus.

-- 5b. Employees with identical (first_name, last_name) — exact name collision.
-- Expected: may surface name matches across the 41-employee dataset.
SELECT
    first_name,
    last_name,
    COUNT(*)          AS cnt,
    GROUP_CONCAT(emp_id ORDER BY emp_id) AS emp_ids,
    GROUP_CONCAT(dept_id ORDER BY emp_id) AS dept_ids
FROM employees
GROUP BY first_name, last_name
HAVING COUNT(*) > 1
ORDER BY cnt DESC, last_name;
-- If data has Karen Wilson twice (emp 7 is Grace Wilson, emp 1 is James Wilson —
-- last-name collision but different first names — they will NOT appear here).
-- Any true (first+last) duplicates will appear; run to verify against actual seed data.


-- =============================================================================
-- SECTION 6: DEDUP KEEPING THE MOST COMPLETE RECORD (FEWEST NULLs)
-- Technique: Score each row by counting its NULL columns. When multiple rows
-- share the same business key, keep the one with the lowest null_count;
-- use the surrogate PK as a tie-breaker for determinism.
-- =============================================================================

-- 6a. Score every salary_history row by NULL count, then pick the best per group.
-- Columns that can be NULL: salary_before (only nullable business column here).
-- Expected: for the emp_id=5 dup group, both rows have salary_before=132000 (non-NULL),
--           so null_count=0 for both → hist_id tie-breaker keeps hist_id=15.
WITH scored AS (
    SELECT
        hist_id,
        emp_id,
        salary_before,
        salary_after,
        effective_date,
        change_reason,
        changed_by,
        -- Count NULLs across all nullable business columns
        (CASE WHEN salary_before IS NULL THEN 1 ELSE 0 END) AS null_count
    FROM salary_history
),
ranked AS (
    SELECT
        *,
        ROW_NUMBER() OVER (
            PARTITION BY emp_id, salary_after, effective_date, change_reason, changed_by
            ORDER BY null_count ASC, hist_id ASC   -- fewest NULLs first, then oldest ID
        ) AS rn
    FROM scored
)
SELECT *
FROM ranked
WHERE rn > 1;   -- rows to discard (completeness-aware dedup)

-- 6b. Richer example on employees: score each employee by nullable column NULLs,
-- then within soft-dup groups (last_name, dept_id, hire_date, job_title) keep
-- the most complete record.
WITH scored AS (
    SELECT
        emp_id,
        first_name,
        last_name,
        dept_id,
        hire_date,
        job_title,
        salary,
        email,
        termination_date,
        (CASE WHEN email            IS NULL THEN 1 ELSE 0 END
       + CASE WHEN salary           IS NULL THEN 1 ELSE 0 END
       + CASE WHEN termination_date IS NULL THEN 1 ELSE 0 END) AS null_count
    FROM employees
),
ranked AS (
    SELECT
        *,
        ROW_NUMBER() OVER (
            PARTITION BY last_name, dept_id, hire_date, job_title
            ORDER BY null_count ASC, emp_id ASC
        ) AS rn
    FROM scored
)
SELECT *
FROM ranked
WHERE rn > 1;
-- Expected: emp_id=19 (Samuel Clark, salary=0.00 but not NULL, so null_count
-- depends on email/termination_date). The row with more non-NULLs is kept (rn=1);
-- the other surfaces here as the discard candidate.


-- =============================================================================
-- SECTION 7: DEDUP USING GROUP BY + MIN() (NO WINDOW FUNCTIONS)
-- Technique: Find the minimum surrogate PK per unique business-key group.
-- Rows whose PK does NOT equal the group minimum are duplicates. This approach
-- works on MySQL 5.7 and earlier where window functions are unavailable.
-- =============================================================================

-- 7a. Find the keeper order_id per unique business group in purchase_orders.
-- Expected: order_id 19 is the MIN (keeper); order_id 20 is the duplicate.
SELECT
    dept_id,
    vendor,
    item_category,
    amount,
    order_date,
    status,
    MIN(order_id) AS keep_order_id,
    COUNT(*)      AS cnt
FROM purchase_orders
GROUP BY
    dept_id,
    vendor,
    item_category,
    amount,
    order_date,
    status
HAVING COUNT(*) > 1;

-- 7b. Identify all duplicate order_ids to remove (NOT IN the keeper list).
-- Safe for SELECT review before deleting.
SELECT *
FROM purchase_orders
WHERE order_id NOT IN (
    SELECT MIN(order_id)
    FROM purchase_orders
    GROUP BY
        dept_id,
        vendor,
        item_category,
        amount,
        order_date,
        status
);
-- Expected: 1 row — order_id=20 (the duplicate LearnFast Training PO).

-- 7c. DELETE using GROUP BY + MIN (no window functions needed).
-- Same double-nesting workaround as Section 3 to avoid MySQL self-reference error.
DELETE FROM purchase_orders
WHERE order_id NOT IN (
    SELECT keep_id
    FROM (
        SELECT MIN(order_id) AS keep_id
        FROM purchase_orders
        GROUP BY
            dept_id,
            vendor,
            item_category,
            amount,
            order_date,
            status
    ) t
);
-- Expected: 1 row deleted (order_id=20).

-- 7d. Same GROUP BY + MIN approach for salary_history.
DELETE FROM salary_history
WHERE hist_id NOT IN (
    SELECT keep_id
    FROM (
        SELECT MIN(hist_id) AS keep_id
        FROM salary_history
        GROUP BY
            emp_id,
            salary_before,
            salary_after,
            effective_date,
            change_reason,
            changed_by
    ) t
);
-- Expected: 1 row deleted (hist_id=16).
-- IMPORTANT: GROUP BY treats NULL = NULL as the same group, so salary_before NULLs
-- are handled correctly here (unlike a self-join with = comparison).
