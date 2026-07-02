-- ============================================================
-- 04-keys-and-cardinality / 01-keys-and-cardinality.sql
-- Databases: dm_oltp (source), dm_warehouse (target)
--
-- Five sections demonstrating key types, cardinality patterns,
-- referential integrity checks, and the surrogate key pipeline.
-- ============================================================

-- ─────────────────────────────────────────────────────────────
-- SECTION 1 — NATURAL KEY vs SURROGATE KEY
-- ─────────────────────────────────────────────────────────────
/*
  NATURAL KEY
  -----------
  A natural key is a column (or combination) that is meaningful in the
  real world and comes from the source application.

  In dm_oltp.employees, emp_id is a natural key:
    • It is assigned by the HR application.
    • It is human-readable and searchable.
    • Operations teams know employee 22 by their emp_id, not by a
      system-generated number.

  Problem: natural keys are not stable across SCD Type 2 changes.
  When employee 5 is promoted (job_title changes), the warehouse needs
  TWO rows for emp_id = 5 — one for the "before" state and one for the
  "after" state. A natural key cannot uniquely identify a specific
  historical version.

  SURROGATE KEY
  -------------
  A surrogate key is a meaningless, system-generated integer assigned
  by the warehouse. It is stable: once assigned, it never changes.

  In dm_warehouse.dim_employee, employee_sk is a surrogate key:
    • AUTO_INCREMENT — the warehouse assigns it, the source system
      never sees it.
    • One emp_id can have MULTIPLE employee_sk values (one per SCD2
      version). This is the key insight.
    • Fact tables reference employee_sk (not emp_id) so that each
      fact row points to the exact dimensional version that was current
      when the fact occurred.
*/

-- Natural key in the OLTP source: emp_id
SELECT
    emp_id,
    first_name,
    last_name,
    job_title,
    hire_date
FROM dm_oltp.employees
ORDER BY emp_id
LIMIT 5;

-- Surrogate key in the warehouse: employee_sk
-- Note: one emp_id CAN map to multiple employee_sk rows (SCD2 versions)
SELECT
    employee_sk,              -- surrogate — meaningless, system-generated
    emp_id,                   -- natural key — preserved from OLTP
    first_name,
    last_name,
    effective_date,
    expiry_date,
    is_current
FROM dm_warehouse.dim_employee
ORDER BY emp_id, effective_date;

-- Demonstrate: count SCD2 versions per natural key
-- Any emp_id with count > 1 has been through a tracked change
SELECT
    emp_id,
    COUNT(*)          AS version_count,
    MIN(effective_date) AS first_version,
    MAX(effective_date) AS latest_version
FROM dm_warehouse.dim_employee
GROUP BY emp_id
ORDER BY version_count DESC;


-- ─────────────────────────────────────────────────────────────
-- SECTION 2 — COMPOSITE KEY
-- ─────────────────────────────────────────────────────────────
/*
  CONCEPT
  -------
  A composite (compound) key is a business key made up of two or more
  columns. Neither column alone uniquely identifies a row; the
  combination does.

  In dm_oltp.salary_history, the business rule is:
    "An employee can have at most one salary change record per date."

  So the composite business key is (emp_id, effective_date).

  The table uses a surrogate hist_id as its PK, which is correct practice,
  but the uniqueness constraint on (emp_id, effective_date) should be
  enforced as well.

  INTENTIONAL FLAW IN THIS DATASET
  ---------------------------------
  Row 16 in salary_history is an EXACT DUPLICATE of row 15:
    both have emp_id = 5, effective_date = '2022-04-01', same salary.
  This means the UNIQUE KEY below would be violated and could not be
  added without removing the duplicate first. That flaw is intentional —
  it tests whether your ingestion pipeline deduplicates before loading.
*/

-- Show the composite business key (emp_id, effective_date)
SELECT
    hist_id,
    emp_id,
    effective_date,
    old_salary,
    new_salary,
    change_reason
FROM dm_oltp.salary_history
ORDER BY emp_id, effective_date;

-- The UNIQUE constraint that SHOULD exist but is violated by row 16
-- (shown here as a CREATE TABLE excerpt — cannot ADD this constraint
--  while the duplicate rows exist without first removing them)
/*
ALTER TABLE dm_oltp.salary_history
    ADD UNIQUE KEY uq_emp_date (emp_id, effective_date);
*/

-- Detect the duplicate: find (emp_id, effective_date) pairs with > 1 row
SELECT
    emp_id,
    effective_date,
    COUNT(*)      AS occurrences,
    MIN(hist_id)  AS first_hist_id,
    MAX(hist_id)  AS duplicate_hist_id
FROM dm_oltp.salary_history
GROUP BY emp_id, effective_date
HAVING COUNT(*) > 1;
-- Expected: emp_id = 5, effective_date = '2022-04-01', occurrences = 2


-- ─────────────────────────────────────────────────────────────
-- SECTION 3 — FOREIGN KEY CARDINALITY
-- ─────────────────────────────────────────────────────────────
/*
  Cardinality describes how many rows on one side of a relationship
  can relate to how many rows on the other side.

  THREE TYPES:
  ─────────────────────────────────────────────
  1:1  (one-to-one)    — each row in A maps to exactly one row in B
  1:M  (one-to-many)   — one row in A maps to many rows in B
  M:N  (many-to-many)  — many rows in A map to many rows in B,
                         requiring a junction/bridge table

  WHY IT MATTERS FOR MODELLING
  ─────────────────────────────────────────────
  • 1:1 → can often be merged into a single table (unless there's a
    performance or access-control reason to separate them).
  • 1:M → the "many" side holds the FK (employees.dept_id references
    departments.dept_id).
  • M:N → requires a bridge/junction table; never store a CSV list of
    IDs in a single column to represent a M:N relationship.
*/

-- ── 1:1 ──────────────────────────────────────────────────────
-- Employees and performance_reviews when exactly one review per period.
-- In practice this is 1:M (an employee can have many reviews over time),
-- but in a given review period it is intended to be 1:1.
-- Show employees with more than one review in the same period (anomaly):
SELECT
    pr.emp_id,
    pr.period,
    COUNT(*)  AS review_count
FROM dm_oltp.performance_reviews AS pr
GROUP BY pr.emp_id, pr.period
HAVING COUNT(*) > 1;
-- 0 rows expected: each employee has at most one review per period

-- Confirm: show all (emp_id, period) pairs — should all be distinct
SELECT
    e.emp_id,
    e.first_name,
    e.last_name,
    pr.period,
    pr.rating
FROM dm_oltp.employees          AS e
LEFT JOIN dm_oltp.performance_reviews AS pr ON pr.emp_id = e.emp_id
ORDER BY e.emp_id, pr.period;

-- ── 1:M ──────────────────────────────────────────────────────
-- departments → employees: one dept has many employees
SELECT
    d.dept_id,
    d.dept_name,
    COUNT(e.emp_id) AS employee_count
FROM dm_oltp.departments AS d
LEFT JOIN dm_oltp.employees AS e ON e.dept_id = d.dept_id
GROUP BY d.dept_id, d.dept_name
ORDER BY employee_count DESC;
-- Expected: Engineering has the most; each dept has >= 0 employees

-- ── M:N ──────────────────────────────────────────────────────
-- employees ↔ projects via project_assignments (junction table)
-- One employee can be on many projects; one project has many employees
SELECT
    e.emp_id,
    CONCAT(e.first_name, ' ', e.last_name) AS employee_name,
    COUNT(DISTINCT pa.project_id)           AS project_count
FROM dm_oltp.employees           AS e
LEFT JOIN dm_oltp.project_assignments AS pa ON pa.emp_id = e.emp_id
GROUP BY e.emp_id, e.first_name, e.last_name
ORDER BY project_count DESC
LIMIT 10;

SELECT
    p.project_id,
    p.project_name,
    COUNT(DISTINCT pa.emp_id) AS employee_count
FROM dm_oltp.projects            AS p
LEFT JOIN dm_oltp.project_assignments AS pa ON pa.project_id = p.project_id
GROUP BY p.project_id, p.project_name
ORDER BY employee_count DESC;


-- ─────────────────────────────────────────────────────────────
-- SECTION 4 — REFERENTIAL INTEGRITY CHECKS
-- ─────────────────────────────────────────────────────────────
/*
  CONCEPT
  -------
  Referential integrity means every FK value in a child table has a
  matching PK value in the parent table. MySQL enforces this with
  FOREIGN KEY constraints on InnoDB tables, but pipelines sometimes
  bypass constraints or load via files that skip FK checks.

  These queries detect orphaned rows — child rows with no parent.
  Run them after every load to validate data quality.

  EXPECTED RESULTS FROM THIS DATASET
  -----------------------------------
  • employees with no matching dept_id          → 0 orphans (FKs enforced)
  • purchase_orders with NULL dept_id           → 1 row: order_id = 25
  • project_assignments with no matching emp_id → 0 orphans (FKs enforced)
*/

-- ── Check 1: employees with no matching department ────────────
-- FK is enforced in DDL, so this should always return 0.
-- Useful as a post-load sanity check after bulk LOAD DATA INFILE
-- (which bypasses FK checks by default).
SELECT
    e.emp_id,
    e.first_name,
    e.last_name,
    e.dept_id       AS orphaned_dept_id
FROM dm_oltp.employees    AS e
LEFT JOIN dm_oltp.departments AS d ON d.dept_id = e.dept_id
WHERE d.dept_id IS NULL;
-- Expected: 0 rows

-- ── Check 2: purchase_orders with NULL dept_id ────────────────
-- dept_id allows NULL in this table (intentional design flaw).
-- A NULL FK means "no parent" — the order is orphaned from any dept.
SELECT
    order_id,
    item_category,
    amount,
    order_date,
    vendor,
    dept_id         -- will be NULL for order 25
FROM dm_oltp.purchase_orders
WHERE dept_id IS NULL;
-- Expected: 1 row — order_id = 25

-- ── Check 3: project_assignments with no matching employee ────
SELECT
    pa.assignment_id,
    pa.emp_id       AS orphaned_emp_id,
    pa.project_id
FROM dm_oltp.project_assignments AS pa
LEFT JOIN dm_oltp.employees      AS e  ON e.emp_id = pa.emp_id
WHERE e.emp_id IS NULL;
-- Expected: 0 rows (FK enforced in DDL)

-- ── Check 4: dim_employee fact-side SK orphan check ───────────
-- After loading fact_salary_payment, verify every employee_sk in the
-- fact table has a matching row in dim_employee.
-- This catches pipeline bugs where a fact row was loaded with a
-- stale or incorrect surrogate key.
SELECT
    f.payment_sk,
    f.employee_sk,
    f.pay_year,
    f.pay_month
FROM dm_warehouse.fact_salary_payment AS f
LEFT JOIN dm_warehouse.dim_employee   AS de ON de.employee_sk = f.employee_sk
WHERE de.employee_sk IS NULL;
-- Expected: 0 rows — every fact SK must resolve to a dim row


-- ─────────────────────────────────────────────────────────────
-- SECTION 5 — SURROGATE KEY PIPELINE
-- ─────────────────────────────────────────────────────────────
/*
  CONCEPT
  -------
  The surrogate key pipeline is the standard sequence a fact table
  load uses to translate natural keys (from the OLTP) into surrogate
  keys (for the warehouse) before writing the fact row.

  The pipeline has three steps:
    1. Read the natural keys from the OLTP fact source.
    2. Look up the CURRENT surrogate key for each dimension member.
    3. Write the fact row with surrogate keys instead of natural keys.

  WHY SURROGATE KEYS IN THE FACT TABLE
  -------------------------------------
  • Surrogate keys are integers → smaller join columns, faster lookups.
  • For SCD2 dimensions, the surrogate key identifies a specific
    HISTORICAL VERSION of the dimension, not just the entity. This
    means fact queries automatically see the right attribute values
    for the period in question — no date-range join needed.

  KEY LOOKUP PATTERN
  ------------------
  Always filter on is_current = 1 to get the active surrogate key.
  If you forget the is_current filter you may join to a historical row
  and get stale attributes in your report.
*/

-- Step 1: Confirm dim_department.dept_sk is AUTO_INCREMENT (surrogate)
-- The warehouse assigned these — the source system never sees them.
SELECT
    dept_sk,   -- surrogate key: system-generated, meaningless
    dept_id,   -- natural key: from dm_oltp.departments
    dept_name,
    location
FROM dm_warehouse.dim_department
ORDER BY dept_sk;

-- Step 2: Standard SK lookup — get the current employee_sk for a
-- given natural key emp_id.  Use this pattern inside every fact load.
SELECT
    employee_sk,
    emp_id,
    first_name,
    last_name,
    effective_date,
    is_current
FROM dm_warehouse.dim_employee
WHERE emp_id    = 5        -- natural key from the OLTP fact source
  AND is_current = 1;      -- current version only

-- Step 3: Full surrogate key resolution — look up all three dimension
-- SKs needed to build a single fact_salary_payment row.
-- This is the inner SELECT that drives a fact table load.
SELECT
    de.employee_sk,             -- resolved surrogate
    dd.dept_sk,                 -- resolved surrogate
    dj.job_sk,                  -- resolved surrogate
    e.salary     AS salary_amount,
    e.emp_id,
    e.dept_id,
    e.job_title
FROM dm_oltp.employees           AS e
-- resolve employee surrogate
JOIN dm_warehouse.dim_employee   AS de
    ON  de.emp_id     = e.emp_id
    AND de.is_current = 1
-- resolve department surrogate
JOIN dm_warehouse.dim_department AS dd
    ON  dd.dept_id = e.dept_id
-- resolve job surrogate
JOIN dm_warehouse.dim_job        AS dj
    ON  dj.job_title = e.job_title
ORDER BY e.emp_id;

-- Step 4: Illustrate the SCD2 version-lookup for a historical fact.
-- A fact row for December 2022 should reference the dimension version
-- that was current in December 2022, not today's current version.
-- Use BETWEEN effective_date AND COALESCE(expiry_date, '9999-12-31').
SELECT
    de.employee_sk,             -- the historical version SK
    de.emp_id,
    de.first_name,
    de.last_name,
    de.effective_date,
    de.expiry_date,
    de.is_current
FROM dm_warehouse.dim_employee AS de
WHERE de.emp_id = 5
  AND '2022-12-31' BETWEEN de.effective_date
                       AND COALESCE(de.expiry_date, '9999-12-31');
-- Returns the SCD2 row that was active on 2022-12-31 for emp_id = 5.
-- This may be a different employee_sk than the one returned by
-- the is_current = 1 filter above — that difference is the whole point
-- of SCD Type 2 surrogate keys in fact tables.
