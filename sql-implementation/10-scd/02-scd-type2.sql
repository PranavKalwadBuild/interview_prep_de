USE `sql-patterns`;

-- =============================================================================
-- FILE: 02-scd-type2.sql
-- TOPIC: Slowly Changing Dimensions — Type 2 (Full History via salary_history)
-- DATABASE: sql-patterns
-- =============================================================================


-- =============================================================================
-- SECTION 1: What Is SCD Type 2?
-- =============================================================================
-- SCD Type 2: Every change creates a NEW row. History is fully preserved.
-- Each row represents one "version" of the record, with a validity window.
--
-- Classic implementation columns:
--   valid_from  — when this version became active (our: effective_date)
--   valid_to    — when this version was superseded (NULL = currently active)
--   is_current  — optional boolean flag
--
-- salary_history IS the pre-built Type 2 table in this schema:
--   hist_id       = surrogate key (AUTO_INCREMENT — unique per row/version)
--   emp_id        = business key (identifies the employee across versions)
--   salary_before = salary at the start of this version window (NULL = initial hire)
--   salary_after  = salary during this version window
--   effective_date = valid_from (when this salary took effect)
--   valid_to      = NOT stored as a column — derived via LEAD() on effective_date
--
-- employees table = the Type 1 "current state" companion (salary reflects today's value)
-- salary_history  = the Type 2 log (every salary state, ever)
--
-- SCD Type 2 is the right tool whenever the question "what was it on date X?" matters.
-- =============================================================================


-- =============================================================================
-- SECTION 2: Reconstruct the SCD2 View (Add valid_to via LEAD)
-- =============================================================================
-- salary_history stores effective_date but not valid_to.
-- We derive valid_to as the NEXT row's effective_date within the same employee.
-- If there is no next row, valid_to = NULL → meaning this version is still current.

WITH salary_scd2 AS (
    SELECT
        hist_id,
        emp_id,
        salary_before,
        salary_after,
        effective_date,
        LEAD(effective_date) OVER (
            PARTITION BY emp_id
            ORDER BY effective_date
        ) AS valid_to,
        change_reason
    FROM salary_history
)
SELECT
    hist_id,
    emp_id,
    salary_before,
    salary_after,
    effective_date              AS valid_from,
    valid_to,
    CASE WHEN valid_to IS NULL THEN 'CURRENT' ELSE 'HISTORICAL' END AS record_status,
    change_reason
FROM salary_scd2
WHERE emp_id IN (1, 2, 5)   -- James Wilson, Sarah Chen, Emma Davis
ORDER BY emp_id, effective_date;

-- Expected for emp 5 (Emma Davis):
--   hist_id  effective_date  salary_after  valid_to     record_status
--   ...      2018-09-10      120000        2020-01-01   HISTORICAL
--   ...      2020-01-01      132000        2022-04-01   HISTORICAL
--   ...      2022-04-01      145000        2022-04-01   HISTORICAL  ← duplicate row!
--   ...      2022-04-01      145000        NULL         CURRENT     ← duplicate row!
-- The duplicate effective_date for emp 5 is a known data flaw (see Section 4).

-- NOTE: to query "which version was active on 2021-06-01?":
-- WHERE '2021-06-01' BETWEEN effective_date AND COALESCE(valid_to, '9999-12-31')


-- =============================================================================
-- SECTION 3: Point-in-Time Query (As-Of Query)
-- =============================================================================
-- Business question: "What was emp 5's (Emma Davis) salary on 2021-01-01?"

WITH salary_scd2 AS (
    SELECT
        emp_id,
        salary_after,
        effective_date,
        LEAD(effective_date) OVER (
            PARTITION BY emp_id ORDER BY effective_date
        ) AS valid_to
    FROM salary_history
)
SELECT
    e.emp_id,
    e.first_name,
    e.last_name,
    s.salary_after     AS salary_on_date,
    s.effective_date   AS valid_from,
    s.valid_to,
    '2021-01-01'       AS as_of_date
FROM salary_scd2 s
JOIN employees e ON s.emp_id = e.emp_id
WHERE s.emp_id = 5
  AND '2021-01-01' BETWEEN s.effective_date
                       AND COALESCE(DATE_SUB(s.valid_to, INTERVAL 1 DAY), '9999-12-31');

-- Expected: salary_after=132000, valid_from=2020-01-01, valid_to=2022-04-01
-- Reasoning: raise to 132000 took effect 2020-01-01; next raise was 2022-04-01.
-- On 2021-01-01 the 132000 version was active.
--
-- DATE_SUB(valid_to, INTERVAL 1 DAY) avoids double-counting on exact boundary dates.
-- Alternative: use < valid_to instead of BETWEEN:
--   AND '2021-01-01' >= effective_date
--   AND (valid_to IS NULL OR '2021-01-01' < valid_to)


-- --- Additional point-in-time examples ---

-- emp 1 (James Wilson) salary on 2018-06-01:
WITH salary_scd2 AS (
    SELECT emp_id, salary_after, effective_date,
           LEAD(effective_date) OVER (PARTITION BY emp_id ORDER BY effective_date) AS valid_to
    FROM salary_history
)
SELECT emp_id, salary_after, effective_date AS valid_from, valid_to
FROM salary_scd2
WHERE emp_id = 1
  AND '2018-06-01' >= effective_date
  AND (valid_to IS NULL OR '2018-06-01' < valid_to);
-- Expected: salary_after=320000 (raised 2017-01-01, next raise 2020-01-01)


-- emp 2 (Sarah Chen) salary on 2020-07-01:
WITH salary_scd2 AS (
    SELECT emp_id, salary_after, effective_date,
           LEAD(effective_date) OVER (PARTITION BY emp_id ORDER BY effective_date) AS valid_to
    FROM salary_history
)
SELECT emp_id, salary_after, effective_date AS valid_from, valid_to
FROM salary_scd2
WHERE emp_id = 2
  AND '2020-07-01' >= effective_date
  AND (valid_to IS NULL OR '2020-07-01' < valid_to);
-- Expected: salary_after=265000 (raised 2019-01-01, next raise 2022-01-01)


-- =============================================================================
-- SECTION 4: Current Record Query + Duplicate Exposure
-- =============================================================================
-- "What is every employee's current salary?"
-- = the most recent effective_date row per employee.

-- --- Approach A: Using the SCD2 view (valid_to IS NULL) ---
WITH salary_scd2 AS (
    SELECT
        hist_id,
        emp_id,
        salary_after,
        effective_date,
        LEAD(effective_date) OVER (PARTITION BY emp_id ORDER BY effective_date) AS valid_to
    FROM salary_history
)
SELECT
    s.emp_id,
    e.first_name,
    e.last_name,
    s.salary_after     AS current_salary,
    s.effective_date   AS since
FROM salary_scd2 s
JOIN employees e ON s.emp_id = e.emp_id
WHERE s.valid_to IS NULL
ORDER BY s.emp_id;

-- *** WARNING: emp 5 (Emma Davis) returns 2 rows ***
-- Both her 2022-04-01 duplicate rows get valid_to=NULL via LEAD because
-- LEAD sees the same effective_date for both rows — neither has a "next" row.
-- This surfaces as two "current" records for one employee.


-- --- Approach B: ROW_NUMBER (more robust against duplicates) ---
WITH ranked AS (
    SELECT
        hist_id,
        emp_id,
        salary_after,
        effective_date,
        ROW_NUMBER() OVER (
            PARTITION BY emp_id
            ORDER BY effective_date DESC, hist_id DESC  -- tie-break by hist_id
        ) AS rn
    FROM salary_history
)
SELECT
    r.emp_id,
    e.first_name,
    e.last_name,
    r.salary_after   AS current_salary,
    r.effective_date AS since
FROM ranked r
JOIN employees e ON r.emp_id = e.emp_id
WHERE r.rn = 1
ORDER BY r.emp_id;

-- ROW_NUMBER tie-breaks by hist_id DESC (higher hist_id = later inserted row).
-- emp 5 returns exactly 1 row — the duplicate is resolved.
-- This is the safer approach when duplicate effective_dates may exist.


-- --- Exposing the duplicate for emp 5 ---
SELECT hist_id, emp_id, salary_before, salary_after, effective_date, change_reason
FROM salary_history
WHERE emp_id = 5
ORDER BY effective_date, hist_id;
-- Expected: two rows both with effective_date='2022-04-01', salary_after=145000
-- This is the data flaw. In production:
--   Option A: DELETE the duplicate (keep lower or higher hist_id depending on data lineage)
--   Option B: Add a UNIQUE constraint on (emp_id, effective_date) to prevent future dupes
--   Option C: Accept it and always use ROW_NUMBER (not valid_to IS NULL) for "current"


-- =============================================================================
-- SECTION 5: Inserting a New Type 2 Record (New Salary Change)
-- =============================================================================
-- Business event: emp 9 (Iris Taylor) receives a raise from 120000 → 128000
-- effective 2024-07-01.

-- Step 1: Verify the current record exists
SELECT hist_id, emp_id, salary_after, effective_date
FROM salary_history
WHERE emp_id = 9
ORDER BY effective_date DESC
LIMIT 1;
-- Expected: salary_after=120000, effective_date='2023-01-01' (current row)

-- Step 2: INSERT the new Type 2 row
INSERT INTO salary_history (emp_id, salary_before, salary_after, effective_date, change_reason, changed_by)
VALUES (9, 120000.00, 128000.00, '2024-07-01', 'Annual review 2024', 2);

-- Verify: full history for emp 9 now shows two rows
SELECT hist_id, emp_id, salary_before, salary_after, effective_date, change_reason
FROM salary_history
WHERE emp_id = 9
ORDER BY effective_date;
-- Expected:
--   Row 1: salary_before=NULL,      salary_after=120000, effective_date=2023-01-01 (initial hire)
--   Row 2: salary_before=120000.00, salary_after=128000, effective_date=2024-07-01 (raise)

-- NOTE on valid_to management:
-- In a schema that stores valid_to as a physical column, you would also run:
--   UPDATE salary_history SET valid_to = '2024-06-30' WHERE emp_id=9 AND valid_to IS NULL;
-- salary_history derives valid_to via LEAD(), so no physical UPDATE is needed here.
-- The prior row's valid_to automatically becomes '2024-07-01' once the new row exists.


-- =============================================================================
-- SECTION 6: Full SCD2 MERGE Simulation (Two-Step Pattern)
-- =============================================================================
-- Incoming event: emp 5 (Emma Davis) gets another raise: 145000 → 155000
-- effective 2024-09-01.

-- Step 1: Check the current salary (should be 145000 after de-duplication)
WITH ranked AS (
    SELECT salary_after, effective_date,
           ROW_NUMBER() OVER (PARTITION BY emp_id ORDER BY effective_date DESC, hist_id DESC) AS rn
    FROM salary_history
    WHERE emp_id = 5
)
SELECT salary_after AS current_salary, effective_date AS current_since
FROM ranked
WHERE rn = 1;
-- Expected: current_salary=145000, current_since=2022-04-01


-- Step 2: INSERT the new Type 2 row (this is the WHEN NOT MATCHED / new-version branch)
INSERT INTO salary_history (emp_id, salary_before, salary_after, effective_date, change_reason, changed_by)
VALUES (5, 145000.00, 155000.00, '2024-09-01', 'Promotion to Principal Engineer', 1);

-- (In a schema with a physical valid_to column, also close the prior open row:)
-- UPDATE salary_history
-- SET valid_to = DATE_SUB('2024-09-01', INTERVAL 1 DAY)
-- WHERE emp_id = 5
--   AND effective_date = '2022-04-01'
--   AND valid_to IS NULL;


-- Step 3: Verify the complete Type 2 history for emp 5
WITH salary_scd2 AS (
    SELECT hist_id, emp_id, salary_before, salary_after, effective_date,
           LEAD(effective_date) OVER (PARTITION BY emp_id ORDER BY effective_date, hist_id) AS valid_to
    FROM salary_history
)
SELECT hist_id, emp_id, salary_before, salary_after,
       effective_date AS valid_from, valid_to,
       CASE WHEN valid_to IS NULL THEN 'CURRENT' ELSE 'HISTORICAL' END AS record_status
FROM salary_scd2
WHERE emp_id = 5
ORDER BY effective_date, hist_id;

-- Expected history chain for emp 5 (Emma Davis):
--   2018-09-10  salary_after=120000  → historical
--   2020-01-01  salary_after=132000  → historical
--   2022-04-01  salary_after=145000  → historical (dup rows, but superseded by new raise)
--   2022-04-01  salary_after=145000  → historical
--   2024-09-01  salary_after=155000  → CURRENT (valid_to=NULL)


-- =============================================================================
-- SECTION 7: Audit Queries on Type 2 Data
-- =============================================================================

-- --- 7a: Number of salary changes per employee ---
SELECT
    sh.emp_id,
    e.first_name,
    e.last_name,
    COUNT(*)                          AS total_history_rows,
    COUNT(*) - 1                      AS number_of_raises,  -- first row = initial hire
    MIN(sh.effective_date)            AS first_salary_date,
    MAX(sh.effective_date)            AS latest_salary_date
FROM salary_history sh
JOIN employees e ON sh.emp_id = e.emp_id
GROUP BY sh.emp_id, e.first_name, e.last_name
ORDER BY total_history_rows DESC;

-- Expected top rows: emp 1 (James Wilson) and emp 2 (Sarah Chen) — 3 rows each.
-- emp 5 (Emma Davis): 4 rows (3 original + 1 dup) before our Section 6 insert, 5 after.


-- --- 7b: Average time between raises per employee ---
WITH raise_gaps AS (
    SELECT
        emp_id,
        effective_date,
        LEAD(effective_date) OVER (PARTITION BY emp_id ORDER BY effective_date) AS next_date
    FROM salary_history
)
SELECT
    rg.emp_id,
    e.first_name,
    e.last_name,
    ROUND(AVG(DATEDIFF(next_date, effective_date)), 0) AS avg_days_between_raises,
    ROUND(AVG(DATEDIFF(next_date, effective_date)) / 365.25, 1) AS avg_years_between_raises
FROM raise_gaps rg
JOIN employees e ON rg.emp_id = e.emp_id
WHERE next_date IS NOT NULL         -- exclude the current (last) row
GROUP BY rg.emp_id, e.first_name, e.last_name
HAVING COUNT(*) > 0
ORDER BY avg_days_between_raises ASC;

-- Expected: employees with frequent raises rise to the top.
-- emp 5 duplicate rows (same date) will show 0-day gap — another signal of bad data.


-- --- 7c: Employees who have never had a raise (initial hire row only) ---
SELECT
    sh.emp_id,
    e.first_name,
    e.last_name,
    sh.salary_after   AS starting_salary,
    sh.effective_date AS hire_date
FROM salary_history sh
JOIN employees e ON sh.emp_id = e.emp_id
WHERE sh.salary_before IS NULL              -- NULL salary_before = initial hire row
GROUP BY sh.emp_id, e.first_name, e.last_name, sh.salary_after, sh.effective_date
HAVING COUNT(*) = (
    SELECT COUNT(*)
    FROM salary_history sh2
    WHERE sh2.emp_id = sh.emp_id
)
-- Simpler rewrite:
-- Employees where total rows in salary_history = 1
ORDER BY sh.hire_date DESC;

-- Cleaner version:
SELECT
    sh.emp_id,
    e.first_name,
    e.last_name,
    sh.salary_after   AS starting_salary,
    sh.effective_date AS hire_date
FROM salary_history sh
JOIN employees e ON sh.emp_id = e.emp_id
WHERE sh.salary_before IS NULL
  AND sh.emp_id IN (
      SELECT emp_id
      FROM salary_history
      GROUP BY emp_id
      HAVING COUNT(*) = 1
  )
ORDER BY sh.hire_date DESC;

-- Expected: employees who were hired but appear in salary_history exactly once (no raises logged).


-- --- 7d: Largest single raise (absolute dollar amount) ---
SELECT
    sh.emp_id,
    e.first_name,
    e.last_name,
    sh.salary_before,
    sh.salary_after,
    (sh.salary_after - sh.salary_before)   AS raise_amount,
    ROUND(
        100.0 * (sh.salary_after - sh.salary_before) / sh.salary_before,
        1
    )                                       AS raise_pct,
    sh.effective_date,
    sh.change_reason
FROM salary_history sh
JOIN employees e ON sh.emp_id = e.emp_id
WHERE sh.salary_before IS NOT NULL          -- exclude initial hire rows
ORDER BY raise_amount DESC
LIMIT 10;

-- Expected top candidates:
--   emp 1 (James Wilson, CEO): 320000→350000 = +30000 raise on 2020-01-01
--   emp 2 (Sarah Chen, CTO):  240000→265000 = +25000 raise on 2019-01-01
-- Check also emp 36 (Jake Evans) if his raise data is present.


-- =============================================================================
-- SECTION 8: SCD2 with Surrogate Keys (Conceptual)
-- =============================================================================
-- In production SCD2, two key concepts govern correct JOINs:
--   Business key  = emp_id  — identifies the real-world entity (the employee)
--   Surrogate key = hist_id — identifies ONE specific version of that entity
--
-- Rule: JOIN to salary_history on hist_id (surrogate) when you need a specific
-- version. Use emp_id (business key) only when you want ALL versions or the current.

-- Correct: get the review that corresponds to the salary version active at review time
WITH salary_scd2 AS (
    SELECT hist_id, emp_id, salary_after, effective_date,
           LEAD(effective_date) OVER (PARTITION BY emp_id ORDER BY effective_date) AS valid_to
    FROM salary_history
)
SELECT
    pr.review_id,
    pr.emp_id,
    e.first_name,
    e.last_name,
    pr.review_date,
    pr.rating,
    s.salary_after   AS salary_at_review_time,
    s.effective_date AS salary_valid_from,
    s.valid_to       AS salary_valid_to
FROM performance_reviews pr
JOIN employees e ON pr.emp_id = e.emp_id
JOIN salary_scd2 s
  ON pr.emp_id = s.emp_id
 AND pr.review_date >= s.effective_date
 AND (s.valid_to IS NULL OR pr.review_date < s.valid_to)
WHERE pr.emp_id IN (1, 2, 5)
ORDER BY pr.emp_id, pr.review_date;

-- This JOIN correctly links each review to the salary that was active on that review date.
-- Using emp_id alone (without the date filter) would produce a cross-join of all
-- reviews × all salary versions — a classic SCD2 JOIN mistake.

-- Summary of surrogate key rules:
--   hist_id  → reference a specific salary version (e.g., FK from another table)
--   emp_id   → find all salary history for a person
--   emp_id + date filter → find the version active on a given date (point-in-time join)
