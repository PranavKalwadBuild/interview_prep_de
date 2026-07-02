-- =============================================================================
-- FILE: 02-extraction-patterns/01-extraction-patterns.sql
-- PURPOSE: Demonstrate four extraction strategies against dm_oltp.
--
-- PATTERNS COVERED
--   1. Full extract         — simple, safe, expensive at scale
--   2. Watermark / high-watermark — incremental by timestamp column
--   3. CDC simulation       — change log table + trigger approach
--   4. Idempotency          — INSERT IGNORE vs ON DUPLICATE KEY vs REPLACE INTO
--
-- DATABASE: MySQL 8.0+
-- SOURCE  : dm_oltp
-- =============================================================================


-- =============================================================================
-- SECTION 1 — Full Extract
-- =============================================================================
/*
  WHAT IT IS
  ----------
  Read every row from the source table on every pipeline run.
  Nothing is filtered; nothing is remembered between runs.

  WHEN TO USE
  -----------
  - Small tables (< 100k rows) where a full scan is cheap
  - Tables with no reliable change-tracking column (no updated_at, no CDC)
  - Initial / backfill loads
  - Idempotent reloads: if the staging table is truncated before load,
    re-running the job always produces the same result

  WHEN NOT TO USE
  ---------------
  - Large tables (millions of rows) where full scans are slow and I/O-heavy
  - High-frequency pipelines (hourly or sub-hourly) — source DB cannot
    sustain the repeated full scans without degrading OLTP performance
  - Tables with frequent deletes that need to be tracked in the warehouse

  TRADE-OFFS
  ----------
  + Simplest to implement and reason about
  + No state to maintain between runs
  + Handles deletes automatically (missing in source → missing in stage)
  - Slow at scale; wastes I/O on unchanged rows
  - Puts read load on source OLTP during peak hours (schedule in off-peak window)
*/

USE dm_oltp;

-- Drop and recreate the staging table to ensure a clean full load.
-- Using CREATE TABLE ... SELECT is a MySQL convenience; in production you
-- would define the DDL explicitly so you control data types and indexes.
DROP TABLE IF EXISTS stg_employees_full;

CREATE TABLE stg_employees_full
SELECT
    e.*,
    NOW() AS _extracted_at    -- lineage: when was this row captured?
FROM dm_oltp.employees e;

-- Verify: row count in staging should equal row count in source
SELECT
    (SELECT COUNT(*) FROM dm_oltp.employees)       AS source_count,
    (SELECT COUNT(*) FROM stg_employees_full)      AS staging_count,
    (SELECT COUNT(*) FROM dm_oltp.employees)
        = (SELECT COUNT(*) FROM stg_employees_full) AS counts_match;

-- Full extract of related tables for completeness
DROP TABLE IF EXISTS stg_salary_history_full;
CREATE TABLE stg_salary_history_full
SELECT *, NOW() AS _extracted_at FROM dm_oltp.salary_history;

DROP TABLE IF EXISTS stg_departments_full;
CREATE TABLE stg_departments_full
SELECT *, NOW() AS _extracted_at FROM dm_oltp.departments;


-- =============================================================================
-- SECTION 2 — Watermark / High-Watermark Extract
-- =============================================================================
/*
  WHAT IT IS
  ----------
  Instead of reading every row, record the timestamp of the last successful
  extraction ("watermark"). On the next run, only read rows NEWER than the
  watermark.

  HOW IT WORKS
  ------------
  1. Before the pipeline starts, read the last watermark from a control table.
  2. Extract rows from source where (created_at > last_watermark)
     OR (updated_at > last_watermark).
  3. After a successful load, update the watermark to NOW().

  THE CRITICAL FLAW: UPDATES ARE MISSED IF YOU ONLY FILTER ON created_at
  -----------------------------------------------------------------------
  Suppose emp_id=7 was hired on 2023-06-01 (created_at = 2023-06-01).
  The watermark is 2024-01-01. A salary change updates the employees table
  on 2024-03-15, but created_at stays at 2023-06-01.

  Filter: WHERE created_at > '2024-01-01'
  Result: emp_id=7 is NOT extracted → the salary update is silently missed.

  WORKAROUND: filter on GREATEST(created_at, updated_at) OR filter on
  updated_at alone (if the table maintains it reliably).

  OTHER PITFALLS
  --------------
  - Clock skew: source DB and pipeline runner may differ by seconds/minutes.
    Always subtract a safety buffer: @last_watermark - INTERVAL 5 MINUTE.
  - Timezone mismatch: source stores UTC, pipeline runs in local time →
    rows near midnight may be skipped. Standardize to UTC everywhere.
  - Bulk updates without touching updated_at: some ORMs or raw SQL scripts
    forget to update the timestamp column. CDC is the only reliable fix.
  - Late-arriving rows: a transaction committed at 23:59:55 may not be
    visible to a query running at 00:00:00 due to transaction isolation.
    The safety buffer handles this.

  WHEN TO USE
  -----------
  - Medium-to-large tables where full extraction is too slow
  - Tables that have a reliable updated_at column maintained by the ORM/app
  - Batch pipelines (hourly, daily) — not sub-minute
*/

USE dm_oltp;

-- Control table: stores the last successful watermark per source table.
-- In production this lives in a metadata / orchestration schema.
CREATE TABLE IF NOT EXISTS pipeline_watermarks (
    source_table    VARCHAR(128)  NOT NULL,
    last_watermark  TIMESTAMP     NOT NULL DEFAULT '1970-01-01 00:00:00',
    updated_at      TIMESTAMP     NOT NULL DEFAULT CURRENT_TIMESTAMP
                                           ON UPDATE CURRENT_TIMESTAMP,
    PRIMARY KEY (source_table)
) ENGINE=InnoDB;

-- Initialize watermarks (idempotent — INSERT IGNORE skips if already exists)
INSERT IGNORE INTO pipeline_watermarks (source_table, last_watermark)
VALUES
    ('employees',     '2024-01-01 00:00:00'),
    ('salary_history','2024-01-01 00:00:00');


-- Pipeline run: read the current watermark
SET @last_watermark = (
    SELECT last_watermark
    FROM   pipeline_watermarks
    WHERE  source_table = 'employees'
);

-- Safety buffer: subtract 5 minutes to catch late-arriving rows
SET @safe_watermark = TIMESTAMPADD(MINUTE, -5, @last_watermark);

SELECT @safe_watermark AS watermark_used;


-- FLAWED approach: only filters on created_at — misses UPDATEs
-- Shown here deliberately to illustrate the mistake.
SELECT *
FROM dm_oltp.employees
WHERE created_at > @safe_watermark;   -- PROBLEM: misses rows updated after creation


-- CORRECT approach: filter on updated_at (or GREATEST of both)
-- Assumes employees table has an updated_at column. If it does not,
-- you must use CDC (Section 3) or fall back to a full extract.
SELECT *
FROM dm_oltp.employees
WHERE updated_at > @safe_watermark    -- catches both inserts AND updates
ORDER BY updated_at;


-- Incremental extract of salary_history using its own watermark
SET @sh_watermark = (
    SELECT TIMESTAMPADD(MINUTE, -5, last_watermark)
    FROM   pipeline_watermarks
    WHERE  source_table = 'salary_history'
);

DROP TABLE IF EXISTS stg_salary_history_incremental;

CREATE TABLE stg_salary_history_incremental AS
SELECT
    sh.*,
    NOW() AS _extracted_at
FROM dm_oltp.salary_history sh
WHERE sh.created_at > @sh_watermark   -- salary_history rows are insert-only
ORDER BY sh.created_at;


-- After a SUCCESSFUL load, advance the watermark.
-- This update must happen ONLY after the downstream load confirms success.
UPDATE pipeline_watermarks
SET    last_watermark = NOW()
WHERE  source_table IN ('employees', 'salary_history');


-- =============================================================================
-- SECTION 3 — CDC Simulation (Change Log Table + Triggers)
-- =============================================================================
/*
  WHAT CDC IS
  -----------
  Change Data Capture records every INSERT, UPDATE, and DELETE that happens
  on a source table — as it happens — without polling.

  REAL CDC (production-grade):
    Tools like Debezium read MySQL's binary log (binlog) and emit change
    events to Kafka. The pipeline consumes those events in near-real-time.
    This requires: binlog_format=ROW, a Debezium connector, a Kafka cluster.

  WHY WE SIMULATE WITH TRIGGERS HERE
  ------------------------------------
  MySQL triggers fire after DML statements, giving us the same INSERT /
  UPDATE / DELETE visibility without external tooling.

  TRADE-OFFS OF TRIGGER-BASED CDC:
    + Works in standard MySQL without binlog access
    + Change log is queryable with normal SQL
    - Trigger overhead adds latency to every OLTP write (~1–3 ms)
    - If the application bypasses the ORM and runs bulk SQL directly,
      triggers still fire — but row-level triggers on huge bulk updates
      can lock the table for seconds
    - Trigger-based CDC does NOT capture DDL changes (ALTER TABLE)
    - Does not scale well beyond ~10k writes/second without partitioning
      the change log table

  WHEN TO USE TRIGGER-BASED CDC:
    - Small-to-medium OLTP databases
    - Cannot access binlog (shared hosting, restrictive cloud RDS settings)
    - Prototype / POC before investing in Debezium + Kafka

  THE WATERMARK STILL APPLIES:
    The pipeline queries employee_change_log WHERE changed_at > @last_watermark,
    so all the watermark pitfalls (clock skew, safety buffer) still apply.
    BUT the critical advantage is: DELETEs are captured too — something
    watermark extraction on the source table cannot do (deleted rows are gone).
*/

USE dm_oltp;

-- Change log table: one row per DML event on employees
CREATE TABLE IF NOT EXISTS employee_change_log (
    log_id          BIGINT UNSIGNED  NOT NULL AUTO_INCREMENT,
    emp_id          INT UNSIGNED     NOT NULL,
    operation       ENUM('INSERT','UPDATE','DELETE') NOT NULL,
    -- JSON blob of old values (NULL for INSERTs)
    old_values      JSON             NULL,
    -- JSON blob of new values (NULL for DELETEs)
    new_values      JSON             NULL,
    changed_at      TIMESTAMP(6)    NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    changed_by      VARCHAR(128)    NOT NULL DEFAULT (CURRENT_USER()),
    PRIMARY KEY (log_id),
    INDEX idx_ecl_changed_at (changed_at),   -- pipeline queries by timestamp
    INDEX idx_ecl_emp_id     (emp_id)        -- look up history for one employee
) ENGINE=InnoDB;

-- Trigger: capture INSERTs on employees
DROP TRIGGER IF EXISTS trg_employees_after_insert;

DELIMITER $$
CREATE TRIGGER trg_employees_after_insert
AFTER INSERT ON employees
FOR EACH ROW
BEGIN
    INSERT INTO employee_change_log (emp_id, operation, old_values, new_values)
    VALUES (
        NEW.emp_id,
        'INSERT',
        NULL,    -- no old values for a new row
        JSON_OBJECT(
            'emp_id',            NEW.emp_id,
            'first_name',        NEW.first_name,
            'last_name',         NEW.last_name,
            'email',             NEW.email,
            'hire_date',         NEW.hire_date,
            'job_title',         NEW.job_title,
            'dept_id',           NEW.dept_id,
            'employment_status', NEW.employment_status
        )
    );
END$$
DELIMITER ;

-- Trigger: capture UPDATEs — store BOTH old and new values for audit trail
DROP TRIGGER IF EXISTS trg_employees_after_update;

DELIMITER $$
CREATE TRIGGER trg_employees_after_update
AFTER UPDATE ON employees
FOR EACH ROW
BEGIN
    INSERT INTO employee_change_log (emp_id, operation, old_values, new_values)
    VALUES (
        NEW.emp_id,
        'UPDATE',
        JSON_OBJECT(
            'first_name',        OLD.first_name,
            'last_name',         OLD.last_name,
            'email',             OLD.email,
            'hire_date',         OLD.hire_date,
            'job_title',         OLD.job_title,
            'dept_id',           OLD.dept_id,
            'employment_status', OLD.employment_status
        ),
        JSON_OBJECT(
            'first_name',        NEW.first_name,
            'last_name',         NEW.last_name,
            'email',             NEW.email,
            'hire_date',         NEW.hire_date,
            'job_title',         NEW.job_title,
            'dept_id',           NEW.dept_id,
            'employment_status', NEW.employment_status
        )
    );
END$$
DELIMITER ;

-- Trigger: capture DELETEs — this is the key advantage over watermark extraction
DROP TRIGGER IF EXISTS trg_employees_before_delete;

DELIMITER $$
CREATE TRIGGER trg_employees_before_delete
BEFORE DELETE ON employees           -- BEFORE (not AFTER) so OLD.* is still available
FOR EACH ROW
BEGIN
    INSERT INTO employee_change_log (emp_id, operation, old_values, new_values)
    VALUES (
        OLD.emp_id,
        'DELETE',
        JSON_OBJECT(
            'emp_id',            OLD.emp_id,
            'first_name',        OLD.first_name,
            'last_name',         OLD.last_name,
            'email',             OLD.email,
            'hire_date',         OLD.hire_date,
            'job_title',         OLD.job_title,
            'dept_id',           OLD.dept_id,
            'employment_status', OLD.employment_status
        ),
        NULL    -- no new values for a deleted row
    );
END$$
DELIMITER ;


-- PIPELINE: Extract from the change log since the last watermark
SET @cdc_watermark = (
    SELECT TIMESTAMPADD(MINUTE, -5, last_watermark)
    FROM   dm_oltp.pipeline_watermarks
    WHERE  source_table = 'employees'
);

-- Pull all changes since last run — ordered so that for the same emp_id,
-- we process INSERT → UPDATE → DELETE in the correct sequence
SELECT
    log_id,
    emp_id,
    operation,
    old_values,
    new_values,
    changed_at
FROM dm_oltp.employee_change_log
WHERE changed_at > @cdc_watermark
ORDER BY changed_at ASC, log_id ASC;  -- log_id breaks ties within same microsecond


-- Query to extract ONLY the net current state of each employee
-- (collapse all events for an emp_id into one row — useful for upsert into dim)
SELECT
    emp_id,
    operation,
    new_values,
    changed_at
FROM (
    SELECT
        emp_id,
        operation,
        new_values,
        changed_at,
        ROW_NUMBER() OVER (
            PARTITION BY emp_id
            ORDER BY changed_at DESC, log_id DESC
        ) AS rn
    FROM dm_oltp.employee_change_log
    WHERE changed_at > @cdc_watermark
) ranked
WHERE rn = 1;   -- keep only the latest event per employee


-- =============================================================================
-- SECTION 4 — Idempotency: Safe Re-runs of Staging Loads
-- =============================================================================
/*
  WHAT IDEMPOTENCY MEANS
  ----------------------
  A pipeline step is idempotent if running it multiple times produces the
  same result as running it once. This is essential because:

  - Network failures, out-of-memory errors, and timeouts cause partial runs
  - Orchestrators (Airflow, dbt, Prefect) automatically retry failed tasks
  - Manual reruns for debugging must not double-count data

  THREE PATTERNS IN MYSQL
  -----------------------

  1. INSERT IGNORE
     Skip the INSERT if a row with the same PK / unique key already exists.
     Use when: a duplicate means "already loaded" and you want to silently skip.
     Risk: also silently ignores OTHER errors (type mismatch, FK violations).
     Mitigation: check ROW_COUNT() after the statement; alert if 0 on first run.

  2. INSERT ... ON DUPLICATE KEY UPDATE (UPSERT)
     If the PK / unique key exists, update the specified columns instead.
     Use when: source data may have changed since the last load and you want
     to overwrite staging with the freshest values.
     Risk: concurrent INSERT + UPDATE race condition in high-throughput tables.
     Note: counts as 2 affected rows in MySQL for an UPDATE, 1 for an INSERT.

  3. REPLACE INTO
     DELETE the existing row, then INSERT the new row.
     Use when: you want all columns refreshed and AUTO_INCREMENT gaps are acceptable.
     Risk: DELETE + INSERT resets AUTO_INCREMENT counters and can break FK refs
     pointing to the deleted row. Generally avoid in production; prefer UPSERT.

  RECOMMENDED PATTERN FOR ETL STAGING TABLES
  -------------------------------------------
  Truncate the staging table at the START of each run, then INSERT fresh data.
  This is the simplest and most predictable idempotency strategy:
    - No duplicate key conflicts
    - No partial-update edge cases
    - Full reload of the extraction window every run

  Use UPSERT only when the staging table is large and truncate + reload
  is too expensive (i.e., the staging table accumulates history).
*/

USE dm_oltp;

-- Setup: staging table with a unique constraint to demonstrate all three patterns
DROP TABLE IF EXISTS stg_employees_upsert;

CREATE TABLE stg_employees_upsert (
    emp_id          INT UNSIGNED   NOT NULL,
    first_name      VARCHAR(80)    NOT NULL,
    last_name       VARCHAR(80)    NOT NULL,
    email           VARCHAR(255)   NULL,
    hire_date       DATE           NOT NULL,
    job_title       VARCHAR(120)   NOT NULL,
    dept_id         TINYINT UNSIGNED NOT NULL,
    employment_status VARCHAR(20)  NOT NULL,
    _extracted_at   TIMESTAMP      NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (emp_id)           -- PK is the idempotency key
) ENGINE=InnoDB;


-- ---- Pattern A: INSERT IGNORE ------------------------------------------------
-- First run: all rows inserted (ROW_COUNT() = number of employees)
INSERT IGNORE INTO stg_employees_upsert (
    emp_id, first_name, last_name, email,
    hire_date, job_title, dept_id, employment_status
)
SELECT
    emp_id, first_name, last_name, email,
    hire_date, job_title, dept_id, employment_status
FROM dm_oltp.employees;

SELECT ROW_COUNT() AS rows_affected_first_run;   -- should equal COUNT(*) of employees

-- Second run (re-run): duplicate PKs are silently skipped
INSERT IGNORE INTO stg_employees_upsert (
    emp_id, first_name, last_name, email,
    hire_date, job_title, dept_id, employment_status
)
SELECT
    emp_id, first_name, last_name, email,
    hire_date, job_title, dept_id, employment_status
FROM dm_oltp.employees;

SELECT ROW_COUNT() AS rows_affected_rerun;   -- should be 0 (all duplicates skipped)
-- RISK: if a real insert fails due to a different error, ROW_COUNT() is also 0
-- and you cannot tell the difference. Always validate total row counts separately.


-- ---- Pattern B: INSERT ... ON DUPLICATE KEY UPDATE (preferred for upserts) ---
-- Overwrites changed columns if the PK already exists; inserts if it does not.
INSERT INTO stg_employees_upsert (
    emp_id, first_name, last_name, email,
    hire_date, job_title, dept_id, employment_status, _extracted_at
)
SELECT
    emp_id, first_name, last_name, email,
    hire_date, job_title, dept_id, employment_status,
    NOW()
FROM dm_oltp.employees
ON DUPLICATE KEY UPDATE
    first_name        = VALUES(first_name),
    last_name         = VALUES(last_name),
    email             = VALUES(email),
    job_title         = VALUES(job_title),
    dept_id           = VALUES(dept_id),
    employment_status = VALUES(employment_status),
    _extracted_at     = VALUES(_extracted_at);
-- After this, the staging table always reflects the latest source values.
-- MySQL reports affected rows as: 1 for INSERT, 2 for UPDATE (even if no change),
-- 0 only if the row exists and nothing changed.


-- ---- Pattern C: REPLACE INTO (shown for completeness; avoid in production) ---
-- Equivalent to DELETE + INSERT. Dangerous if other tables FK to emp_id.
-- Shown here only to illustrate the syntax and explain WHY to avoid it.

/*
REPLACE INTO stg_employees_upsert (
    emp_id, first_name, last_name, email,
    hire_date, job_title, dept_id, employment_status
)
SELECT
    emp_id, first_name, last_name, email,
    hire_date, job_title, dept_id, employment_status
FROM dm_oltp.employees;

WHY TO AVOID:
- REPLACE = DELETE existing row + INSERT new row
- Triggers the BEFORE DELETE and AFTER DELETE triggers (unintended side effects)
- AUTO_INCREMENT does not reuse freed IDs → gaps accumulate
- Any child table with FK → emp_id raises a FK violation on the DELETE phase
  unless FK checks are disabled (which breaks referential integrity)
*/


-- ---- Recommended pattern: TRUNCATE + INSERT (simplest, most predictable) -----
-- For staging tables that do NOT accumulate history, this is the gold standard.
TRUNCATE TABLE stg_employees_upsert;

INSERT INTO stg_employees_upsert (
    emp_id, first_name, last_name, email,
    hire_date, job_title, dept_id, employment_status
)
SELECT
    emp_id, first_name, last_name, email,
    hire_date, job_title, dept_id, employment_status
FROM dm_oltp.employees;

-- Idempotency check: verify staging count matches source
SELECT
    (SELECT COUNT(*) FROM dm_oltp.employees)      AS source_count,
    (SELECT COUNT(*) FROM stg_employees_upsert)   AS staging_count;

/*
  INTERVIEW TALKING POINT:
  "Every step in our pipeline is idempotent — if it fails mid-run and we
   retry, we get the same result without double-counting. For staging tables
   we use TRUNCATE + INSERT. For dimension tables we use INSERT ... ON
   DUPLICATE KEY UPDATE (upsert on the natural key). For fact tables we
   check for existing (date_key, emp_key) pairs before inserting to avoid
   duplicate measures."
*/
