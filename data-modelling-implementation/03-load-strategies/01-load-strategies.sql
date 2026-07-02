-- ============================================================
-- 03-load-strategies / 01-load-strategies.sql
-- Databases: dm_oltp (source), dm_warehouse (target)
--
-- Five core load strategy patterns, each with a block comment
-- explaining the concept, why you'd use it, and the trade-offs.
-- ============================================================

USE dm_warehouse;

-- ─────────────────────────────────────────────────────────────
-- SECTION 1 — TRUNCATE-AND-RELOAD
-- ─────────────────────────────────────────────────────────────
/*
  CONCEPT
  -------
  Delete every row in the target table and re-insert everything
  from the source in a single batch.

  WHY USE IT
  ----------
  • Simplest possible pipeline to reason about: no change detection,
    no merge logic, no SCD handling — just wipe and reload.
  • Guarantees the target is an exact mirror of the source after
    every run, making it inherently idempotent (safe to re-run).
  • Ideal for small, slowly-changing reference dimensions where the
    full dataset fits in a single transaction (< a few hundred rows).

  TRADE-OFFS
  ----------
  • Requires a full re-extract of the source table on every run —
    expensive if the source is large or the API is rate-limited.
  • Any downstream query running during the truncate window sees
    an empty table (brief outage). Mitigate with a staging swap or
    by wrapping in a transaction (InnoDB only).
  • Loses any locally-added audit columns (dw_insert_ts) because
    all rows are replaced.
  • NOT suitable for SCD Type 2 — history is destroyed on every load.

  WHEN TO PREFER
  --------------
  Table has < ~100K rows, full extract costs < pipeline window,
  and history tracking is not required (SCD0 / SCD1 only).
*/

-- Step 1: Wipe the target (InnoDB resets auto-increment too)
TRUNCATE TABLE dm_warehouse.dim_department;

-- Step 2: Reload all 8 rows from the source
INSERT INTO dm_warehouse.dim_department
    (dept_id, dept_name, location, budget)
SELECT
    d.dept_id,
    d.dept_name,
    d.location,
    d.budget          -- NULL for Executive preserved as-is
FROM dm_oltp.departments AS d
ORDER BY d.dept_id;


-- ─────────────────────────────────────────────────────────────
-- SECTION 2 — UPSERT (INSERT … ON DUPLICATE KEY UPDATE)
-- ─────────────────────────────────────────────────────────────
/*
  CONCEPT
  -------
  Attempt to INSERT; if a unique-key collision occurs, UPDATE the
  existing row instead. MySQL's native UPSERT syntax does this in
  a single statement — no conditional logic required.

  This produces SCD TYPE 1 behaviour: the old value is overwritten;
  no history is preserved.

  WHY USE IT
  ----------
  • One statement handles both new rows (INSERT path) and changed rows
    (UPDATE path) without a separate "did this row exist?" check.
  • Scales well: the engine resolves collisions via index lookup,
    so performance degrades gracefully on large tables.
  • Safe to re-run: running the same INSERT again is a no-op because
    the duplicate key check fires and the SET clause writes the same
    values back.

  TRADE-OFFS
  ----------
  • Does NOT detect hard deletes: rows removed from the source remain
    in the warehouse indefinitely. You need a separate delete-detection
    step (see design-rationale.md).
  • No history: if an employee's job title changes, the old title is
    overwritten. Use SCD Type 2 (staging-table pattern below) when you
    need history.
  • MySQL counts ON DUPLICATE KEY UPDATE as 2 affected rows per update,
    which can confuse row-count checks in pipeline monitoring.

  WHEN TO PREFER
  --------------
  Dimension is large (hundreds of thousands of rows), most rows don't
  change per load, history is not required, and delete detection is
  handled by a separate process.
*/

INSERT INTO dm_warehouse.dim_employee
    (emp_id, first_name, last_name, email,
     job_sk, dept_sk, flag_sk,
     salary, manager_emp_id, hire_date, termination_date,
     effective_date, expiry_date, is_current)
SELECT
    e.emp_id,
    e.first_name,
    e.last_name,
    e.email,                                    -- NULL for emp 22: preserved
    j.job_sk,
    d.dept_sk,
    f.flag_sk,
    e.salary,                                   -- NULL for emp 10, 15: preserved
    e.manager_id,
    e.hire_date,
    e.termination_date,
    CURDATE()       AS effective_date,
    NULL            AS expiry_date,             -- current record
    1               AS is_current
FROM dm_oltp.employees        AS e
JOIN dm_warehouse.dim_job        AS j ON j.job_title = e.job_title
JOIN dm_warehouse.dim_department AS d ON d.dept_id   = e.dept_id
LEFT JOIN dm_warehouse.dim_employee_flags AS f
    ON  f.has_null_salary = (e.salary IS NULL)
    AND f.has_null_email  = (e.email  IS NULL)
    AND f.is_terminated   = (e.status = 'Terminated')
    AND f.is_future_hire  = (e.hire_date > CURDATE())
    AND f.is_contractor   = 0

-- The UNIQUE KEY on emp_id (when combined with is_current) does not
-- exist in this SCD2 table, so in practice you would need to guard
-- this with a WHERE NOT EXISTS for the SCD2 case.  This example
-- illustrates the SCD1 / flat-dim variant where emp_id IS unique.
ON DUPLICATE KEY UPDATE
    first_name       = VALUES(first_name),
    last_name        = VALUES(last_name),
    email            = VALUES(email),
    job_sk           = VALUES(job_sk),
    dept_sk          = VALUES(dept_sk),
    flag_sk          = VALUES(flag_sk),
    salary           = VALUES(salary),
    manager_emp_id   = VALUES(manager_emp_id),
    hire_date        = VALUES(hire_date),
    termination_date = VALUES(termination_date),
    effective_date   = VALUES(effective_date);


-- ─────────────────────────────────────────────────────────────
-- SECTION 3 — MERGE-STYLE UPSERT VIA STAGING TABLE
-- ─────────────────────────────────────────────────────────────
/*
  CONCEPT
  -------
  MySQL has no native MERGE statement (unlike Oracle / SQL Server).
  The standard workaround is a two-step staging pattern:

    1. Load all incoming rows into a temporary staging table.
    2. UPDATE dim rows that exist in staging (matched → overwrite /
       close out the old SCD2 row).
    3. INSERT staging rows that have no match in dim (unmatched → new
       row / new SCD2 version).

  This is the pattern used in virtually all MySQL-based ETL pipelines
  and dbt-style incremental models.

  WHY USE IT
  ----------
  • Gives full control over the merge logic: you decide exactly which
    columns trigger a "change detected" condition.
  • Supports SCD Type 2: you can UPDATE (expire) the old row in the
    same transaction you INSERT the new version.
  • The staging table is cheap — it exists only for the duration of
    the pipeline run and can be a TEMPORARY TABLE.
  • Scales to large datasets because both steps use indexed joins
    rather than row-by-row cursors.

  TRADE-OFFS
  ----------
  • More complex than a single UPSERT statement — two DML operations
    plus a CREATE TABLE.
  • Requires the staging table and production table to have compatible
    schemas; schema drift breaks the pipeline.
  • Still does not catch hard deletes from source (same problem as
    ON DUPLICATE KEY UPDATE).

  WHEN TO PREFER
  --------------
  You need SCD Type 2 history, or you need fine-grained control over
  which columns trigger an update, or the table is too large for a
  full truncate-and-reload.
*/

-- Step 1: Create a staging table mirroring the source extract
DROP TABLE IF EXISTS stg_employees;

CREATE TABLE stg_employees AS
SELECT
    e.emp_id,
    e.first_name,
    e.last_name,
    e.email,
    e.job_title,
    e.dept_id,
    e.salary,
    e.manager_id        AS manager_emp_id,
    e.hire_date,
    e.termination_date,
    e.status
FROM dm_oltp.employees AS e;

-- Add an index so the join in steps 2 and 3 uses an index seek
ALTER TABLE stg_employees ADD INDEX idx_stg_emp_id (emp_id);

-- ── Step 2: UPDATE matched rows (SCD1 overwrite of non-tracked cols) ──
-- For SCD2 this would instead set expiry_date = CURDATE() - 1 and
-- is_current = 0 on the OLD row, then let Step 3 insert the new version.
UPDATE dm_warehouse.dim_employee  AS de
INNER JOIN stg_employees          AS s  ON s.emp_id = de.emp_id
                                       AND de.is_current = 1
SET
    de.first_name       = s.first_name,
    de.last_name        = s.last_name,
    de.email            = s.email,
    de.salary           = s.salary,
    de.manager_emp_id   = s.manager_emp_id,
    de.termination_date = s.termination_date;

-- ── Step 3: INSERT unmatched rows (net-new employees) ──────────────
INSERT INTO dm_warehouse.dim_employee
    (emp_id, first_name, last_name, email,
     job_sk, dept_sk, flag_sk,
     salary, manager_emp_id, hire_date, termination_date,
     effective_date, expiry_date, is_current)
SELECT
    s.emp_id,
    s.first_name,
    s.last_name,
    s.email,
    j.job_sk,
    d.dept_sk,
    f.flag_sk,
    s.salary,
    s.manager_emp_id,
    s.hire_date,
    s.termination_date,
    CURDATE()   AS effective_date,
    NULL        AS expiry_date,
    1           AS is_current
FROM stg_employees AS s
JOIN dm_warehouse.dim_job        AS j ON j.job_title = s.job_title
JOIN dm_warehouse.dim_department AS d ON d.dept_id   = s.dept_id
LEFT JOIN dm_warehouse.dim_employee_flags AS f
    ON  f.has_null_salary = (s.salary IS NULL)
    AND f.has_null_email  = (s.email  IS NULL)
    AND f.is_terminated   = (s.status = 'Terminated')
    AND f.is_future_hire  = (s.hire_date > CURDATE())
    AND f.is_contractor   = 0
-- LEFT JOIN to target: keep only rows with NO existing current record
LEFT JOIN dm_warehouse.dim_employee AS de
    ON  de.emp_id     = s.emp_id
    AND de.is_current = 1
WHERE de.employee_sk IS NULL;   -- unmatched = new employee

-- Cleanup
DROP TABLE IF EXISTS stg_employees;


-- ─────────────────────────────────────────────────────────────
-- SECTION 4 — APPEND-ONLY LOAD
-- ─────────────────────────────────────────────────────────────
/*
  CONCEPT
  -------
  Add new rows to a fact table without touching existing rows.
  Fact tables almost never need updates — once a payment occurred,
  its amount does not change. Appending is therefore both correct
  and the most efficient strategy for transaction facts.

  WHY USE IT
  ----------
  • Maximum write throughput: no index lookups for collision detection,
    no update lock contention.
  • Easy to parallelise: multiple partition windows can be appended
    concurrently without risk of overwriting each other.
  • Natural audit trail: every prior fact row is untouched, making
    debugging simple.

  TRADE-OFFS
  ----------
  • Re-running the same pipeline period appends DUPLICATE rows.
    Protect with a WHERE NOT EXISTS guard or a partitioned
    delete-then-insert (Section 5) if the pipeline must be idempotent.
  • Late-arriving facts (corrections, reversals) require an explicit
    correction row or a separate update step — not handled here.

  WHEN TO PREFER
  --------------
  Transaction fact tables where each run loads a new, non-overlapping
  time window (e.g., "load December 2024 payroll that has never been
  loaded before").
*/

-- Load December 2024 salary payments — first-time, no-overlap append.
-- The WHERE clause on pay_year / pay_month acts as the partition key;
-- it prevents a full-table scan on fact_salary_payment.
INSERT INTO dm_warehouse.fact_salary_payment
    (employee_sk, dept_sk, job_sk, flag_sk,
     pay_date_sk, salary_amount, bonus_amount,
     pay_year, pay_month)
SELECT
    de.employee_sk,
    de.dept_sk,
    de.job_sk,
    de.flag_sk,
    dd.date_sk          AS pay_date_sk,
    e.salary            AS salary_amount,
    0.00                AS bonus_amount,
    2024                AS pay_year,
    12                  AS pay_month
FROM dm_oltp.employees        AS e
JOIN dm_warehouse.dim_employee   AS de ON de.emp_id     = e.emp_id
                                      AND de.is_current = 1
JOIN dm_warehouse.dim_date       AS dd ON dd.date_actual = '2024-12-31'
WHERE e.salary IS NOT NULL          -- exclude contractors (emp 10, 15)
  AND e.status  = 'Active'
  AND e.hire_date <= '2024-12-31';  -- exclude future hire emp 41


-- ─────────────────────────────────────────────────────────────
-- SECTION 5 — PARTITION-BASED LOAD (DELETE-THEN-INSERT)
-- ─────────────────────────────────────────────────────────────
/*
  CONCEPT
  -------
  Delete all rows for a specific time partition (year + month) and
  immediately re-insert the full, freshly-computed result for that
  partition. The two steps together are atomic within a transaction.

  This is the standard pattern for PERIODIC SNAPSHOT FACT tables,
  where the entire state of a period can be recomputed from scratch.

  WHY USE IT
  ----------
  • IDEMPOTENT: running the pipeline twice for December 2024 produces
    exactly the same final state — the delete clears any prior load
    before the insert runs.
  • Simpler than UPSERT for aggregate rows: headcount is recomputed
    from the OLTP source, so "update only changed rows" would require
    comparing every aggregate column — delete-then-insert is cheaper.
  • Limits write I/O: only the target partition is touched, not the
    entire table.

  TRADE-OFFS
  ----------
  • Brief window between DELETE and INSERT where the partition has
    zero rows. Wrap in a transaction to hide this from readers:
      START TRANSACTION; DELETE ...; INSERT ...; COMMIT;
  • If the INSERT fails mid-way, a ROLLBACK leaves the partition
    empty until the next successful run — monitor for empty partitions.
  • Not suitable for transaction facts where historical rows should be
    immutable (use append-only there).

  WHEN TO PREFER
  --------------
  Periodic snapshot facts (monthly headcount, daily balances) where
  the full computation for a period is cheap and the pipeline must be
  safely re-runnable.
*/

START TRANSACTION;

-- Step 1: Delete the partition to be reloaded
DELETE FROM dm_warehouse.fact_monthly_headcount
WHERE snapshot_year  = 2024
  AND snapshot_month = 12;

-- Step 2: Re-insert freshly computed snapshot for Dec 2024
INSERT INTO dm_warehouse.fact_monthly_headcount
    (dept_sk, snapshot_date_sk,
     snapshot_year, snapshot_month,
     headcount, active_count, terminated_count,
     total_payroll, avg_salary)
SELECT
    d.dept_sk,
    dd.date_sk              AS snapshot_date_sk,
    2024                    AS snapshot_year,
    12                      AS snapshot_month,
    COUNT(*)                AS headcount,
    SUM(e.status = 'Active')       AS active_count,
    SUM(e.status = 'Terminated')   AS terminated_count,
    SUM(COALESCE(e.salary, 0))     AS total_payroll,
    AVG(e.salary)                  AS avg_salary        -- NULL-aware; non-additive
FROM dm_oltp.employees        AS e
JOIN dm_warehouse.dim_department AS d  ON d.dept_id   = e.dept_id
JOIN dm_warehouse.dim_date       AS dd ON dd.date_actual = '2024-12-31'
-- Include employees who were active at any point in Dec 2024
WHERE e.hire_date <= '2024-12-31'
  AND (e.termination_date IS NULL OR e.termination_date >= '2024-12-01')
GROUP BY d.dept_sk, dd.date_sk;

COMMIT;
