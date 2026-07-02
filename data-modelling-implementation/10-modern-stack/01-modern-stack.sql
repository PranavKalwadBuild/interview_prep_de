-- =============================================================================
-- FILE: 10-modern-stack/01-modern-stack.sql
-- DATABASE: dm_warehouse (source: dm_oltp)
-- PURPOSE: Demonstrate Medallion Architecture, One Big Table (OBT),
--          and Data Vault 2.0 patterns
-- MySQL 8.0+
-- =============================================================================

USE dm_warehouse;

-- =============================================================================
-- SECTION 1 — MEDALLION ARCHITECTURE (Bronze → Silver → Gold)
-- Philosophy: each layer has a single responsibility.
--   Bronze: raw ingestion — preserve everything, fix nothing
--   Silver: clean, typed, deduplicated — fit for analysis
--   Gold:   business-aggregated — fit for dashboards / BI tools
-- =============================================================================

-- ── BRONZE LAYER ─────────────────────────────────────────────────────────────
-- Rule: land exactly what came from the source. No transformation.
-- Preserves all flaws: NULL salary (emp 10, 15), NULL email (emp 22),
-- salary=0.00 (emp 19), Terminated status (emp 35), future hire_date (emp 41).

DROP TABLE IF EXISTS bronze_employees;
CREATE TABLE bronze_employees
SELECT
    *,
    NOW()           AS _ingested_at,
    'dm_oltp'       AS _source_system,
    'employees'     AS _source_table
FROM dm_oltp.employees;

-- Bronze never gets cleaned; it is append-only in production pipelines.
-- Re-running the pipeline appends a new batch with a new _ingested_at value.
-- This lets you replay transformations from scratch if Silver logic changes.

-- Verify all source flaws are preserved in bronze:
SELECT
    emp_id,
    email,
    salary,
    status,
    hire_date,
    _ingested_at
FROM   bronze_employees
WHERE  emp_id IN (10, 15, 19, 22, 35, 41)
ORDER  BY emp_id;


-- ── SILVER LAYER ─────────────────────────────────────────────────────────────
-- Rules applied in silver:
--   1. Deduplicate: keep latest record per emp_id (by _ingested_at)
--   2. Fill NULLs with safe defaults
--   3. Enforce data types
--   4. Exclude structurally invalid records (e.g., future hire_date in an HR system)
-- Silver still has one row per source entity — it is NOT aggregated.

DROP TABLE IF EXISTS silver_employees;
CREATE TABLE silver_employees AS
WITH ranked AS (
    SELECT
        *,
        ROW_NUMBER() OVER (
            PARTITION BY emp_id
            ORDER BY _ingested_at DESC
        ) AS rn
    FROM bronze_employees
)
SELECT
    emp_id,
    first_name,
    last_name,
    -- SCD1-style correction: back-fill NULL email with a deterministic placeholder
    COALESCE(email, CONCAT('emp', emp_id, '@company.com'))      AS email,
    -- Treat NULL salary as 0.00 (business rule: unset salary = not yet on payroll)
    COALESCE(salary, 0.00)                                       AS salary,
    dept_id,
    job_title,
    UPPER(TRIM(status))                                          AS status,   -- normalise casing
    hire_date,
    termination_date,
    CAST(_ingested_at AS DATE)                                   AS silver_load_date
FROM ranked
WHERE rn = 1                          -- deduplicate: keep freshest row per employee
  AND hire_date <= CURDATE();         -- exclude emp 41 (future hire_date — not yet active)

-- What silver documents vs bronze:
--   emp 22: email filled from NULL → emp22@company.com
--   emp 10, 15: salary filled from NULL → 0.00
--   emp 41: excluded (hire_date in the future)
--   emp 35: kept (Terminated is a valid status; filtering is consumer's choice)

-- Verification: check silver has one row per emp_id and no NULL emails
SELECT
    COUNT(*)                         AS total_rows,
    COUNT(DISTINCT emp_id)           AS distinct_employees,
    SUM(email IS NULL)               AS null_emails,
    SUM(salary IS NULL)              AS null_salaries,
    SUM(hire_date > CURDATE())       AS future_hires
FROM silver_employees;


-- ── GOLD LAYER ───────────────────────────────────────────────────────────────
-- Gold is purpose-built for a specific business question.
-- It is pre-aggregated — no joins needed by the consumer.
-- Example: monthly payroll summary by department.

DROP TABLE IF EXISTS gold_dept_monthly_payroll;
CREATE TABLE gold_dept_monthly_payroll AS
SELECT
    se.dept_id,
    d.dept_name,
    d.location,
    YEAR(CURDATE())                                AS report_year,
    MONTH(CURDATE())                               AS report_month,
    COUNT(*)                                       AS employee_count,
    SUM(se.salary)                                 AS total_payroll,
    ROUND(AVG(se.salary), 2)                       AS avg_salary,
    MAX(se.salary)                                 AS max_salary,
    MIN(CASE WHEN se.salary > 0 THEN se.salary END) AS min_salary_excl_zero
FROM   silver_employees se
JOIN   dm_oltp.departments d ON se.dept_id = d.dept_id
WHERE  se.status = 'ACTIVE'
GROUP  BY se.dept_id, d.dept_name, d.location;

-- Gold query: no joins, no WHERE complexity — one table scan
SELECT
    dept_name,
    location,
    employee_count,
    total_payroll,
    avg_salary
FROM   gold_dept_monthly_payroll
ORDER  BY total_payroll DESC;

-- When NOT to use the gold aggregation layer:
-- If a BI tool needs employee-level detail (individual names, salaries, job titles),
-- the gold table cannot provide it — query silver directly.
-- Gold tables are narrow-purpose; one gold table per reporting use-case is normal.
-- Creating a gold table for every possible question leads to maintenance sprawl.


-- =============================================================================
-- SECTION 2 — ONE BIG TABLE (OBT)
-- Philosophy: denormalise everything into a single wide table.
--   Consumers write: SELECT col FROM obt WHERE condition
--   No joins, no schema knowledge required.
-- Best suited for: columnar/Parquet storage (BigQuery, Snowflake, Databricks),
--                  read-heavy analytics, single-grain reporting.
-- =============================================================================

DROP TABLE IF EXISTS obt_employee_full;
CREATE TABLE obt_employee_full AS
SELECT
    -- employee attributes
    e.emp_id,
    e.first_name,
    e.last_name,
    COALESCE(e.email, CONCAT('emp', e.emp_id, '@company.com')) AS email,
    e.salary,
    e.job_title,
    e.status,
    e.hire_date,
    e.termination_date,
    DATEDIFF(COALESCE(e.termination_date, CURDATE()), e.hire_date) AS tenure_days,

    -- department attributes (denormalised in)
    d.dept_name,
    d.location,
    d.budget       AS dept_budget,

    -- derived: salary as % of dept budget
    CASE
        WHEN d.budget > 0 THEN ROUND(e.salary / d.budget * 100, 4)
        ELSE NULL
    END AS salary_pct_of_budget,

    -- correlated subquery: project count per employee
    -- (assumes dm_oltp.project_assignments exists; safe to 0 if not)
    COALESCE(
        (SELECT COUNT(*)
         FROM   dm_oltp.project_assignments pa
         WHERE  pa.emp_id = e.emp_id), 0
    ) AS project_count,

    -- correlated subquery: most recent performance rating
    (SELECT MAX(pr.rating)
     FROM   dm_oltp.performance_reviews pr
     WHERE  pr.emp_id = e.emp_id
     AND    pr.review_date = (
         SELECT MAX(pr2.review_date)
         FROM   dm_oltp.performance_reviews pr2
         WHERE  pr2.emp_id = e.emp_id
     )
    ) AS latest_perf_rating,

    NOW() AS _obt_built_at

FROM  dm_oltp.employees    e
JOIN  dm_oltp.departments  d ON e.dept_id = d.dept_id;

-- ── OBT consumer queries — no joins needed ───────────────────────────────────

-- Simple filter: all Engineering employees
SELECT
    emp_id, first_name, last_name, job_title, salary, tenure_days
FROM   obt_employee_full
WHERE  dept_name = 'Engineering'
ORDER  BY salary DESC;

-- Aggregation: average salary and project count by department
SELECT
    dept_name,
    location,
    COUNT(*)              AS headcount,
    AVG(salary)           AS avg_salary,
    AVG(project_count)    AS avg_projects_per_employee
FROM   obt_employee_full
WHERE  status = 'Active'
GROUP  BY dept_name, location
ORDER  BY avg_salary DESC;

-- ── OBT trade-offs ────────────────────────────────────────────────────────────
-- ADVANTAGE: zero-join query surface; BI tools / ad-hoc analysts love it.
-- DISADVANTAGE 1: updating a single source attribute requires rebuilding the entire table.
--   e.g., dept_name change in dm_oltp.departments → full OBT rebuild.
-- DISADVANTAGE 2: does not support multiple grains.
--   If one analyst needs employee-level and another needs dept-level,
--   two separate OBT tables are required (or they use different layers).
-- DISADVANTAGE 3: correlated subqueries (project_count, latest_perf_rating) make
--   the build expensive at scale. In a columnar warehouse, these become window functions.

-- In dbt, an OBT is simply a model with materialization = 'table'.
-- Incremental materialisation on OBTs is complex due to denormalisation.


-- =============================================================================
-- SECTION 3 — DATA VAULT 2.0
-- Philosophy: insert-only, source-agnostic, auditable.
--   Hub:       business keys — one row per unique real-world entity
--   Satellite: attributes of a hub — one row per load batch (change-tracked by hash_diff)
--   Link:      relationships between hubs
-- =============================================================================

-- ── HUB: Employee ─────────────────────────────────────────────────────────────
-- Hubs contain ONLY the business key + metadata. No descriptive attributes.
CREATE TABLE IF NOT EXISTS hub_employee (
    hub_emp_sk    BIGINT       NOT NULL AUTO_INCREMENT,
    emp_id        INT          NOT NULL    COMMENT 'Business key from source system',
    load_dts      DATETIME     NOT NULL    COMMENT 'When this row was first loaded',
    record_source VARCHAR(50)  NOT NULL    COMMENT 'Source system identifier',
    PRIMARY KEY (hub_emp_sk),
    UNIQUE KEY uq_emp_id (emp_id)
);

-- ── HUB: Department ──────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS hub_department (
    hub_dept_sk   BIGINT       NOT NULL AUTO_INCREMENT,
    dept_id       INT          NOT NULL    COMMENT 'Business key',
    load_dts      DATETIME     NOT NULL,
    record_source VARCHAR(50)  NOT NULL,
    PRIMARY KEY (hub_dept_sk),
    UNIQUE KEY uq_dept_id (dept_id)
);

-- ── SATELLITE: Employee attributes ───────────────────────────────────────────
-- Satellites are append-only. Each load that detects a change inserts a new row.
-- hash_diff: MD5/SHA of all descriptive columns — used to detect changes cheaply.
CREATE TABLE IF NOT EXISTS sat_employee (
    sat_emp_sk    BIGINT       NOT NULL AUTO_INCREMENT,
    hub_emp_sk    BIGINT       NOT NULL,
    first_name    VARCHAR(100),
    last_name     VARCHAR(100),
    email         VARCHAR(255)           COMMENT 'NULL preserved — no transformation in vault',
    salary        DECIMAL(15,2),
    job_title     VARCHAR(200),
    status        VARCHAR(50),
    hire_date     DATE,
    termination_date DATE,
    load_dts      DATETIME     NOT NULL,
    hash_diff     CHAR(32)     NOT NULL  COMMENT 'MD5 of all descriptive columns — change detection',
    record_source VARCHAR(50)  NOT NULL,
    PRIMARY KEY (sat_emp_sk),
    INDEX idx_hub_load (hub_emp_sk, load_dts),
    CONSTRAINT fk_sat_hub_emp FOREIGN KEY (hub_emp_sk) REFERENCES hub_employee (hub_emp_sk)
);

-- ── LINK: Employee ↔ Department relationship ─────────────────────────────────
CREATE TABLE IF NOT EXISTS lnk_emp_dept (
    lnk_sk        BIGINT       NOT NULL AUTO_INCREMENT,
    hub_emp_sk    BIGINT       NOT NULL,
    hub_dept_sk   BIGINT       NOT NULL,
    load_dts      DATETIME     NOT NULL,
    record_source VARCHAR(50)  NOT NULL,
    PRIMARY KEY (lnk_sk),
    UNIQUE KEY uq_emp_dept (hub_emp_sk, hub_dept_sk),
    CONSTRAINT fk_lnk_emp  FOREIGN KEY (hub_emp_sk)  REFERENCES hub_employee  (hub_emp_sk),
    CONSTRAINT fk_lnk_dept FOREIGN KEY (hub_dept_sk) REFERENCES hub_department (hub_dept_sk)
);

-- ── LOAD: Hubs first (always idempotent with INSERT IGNORE) ──────────────────
INSERT IGNORE INTO hub_employee (emp_id, load_dts, record_source)
SELECT emp_id, NOW(), 'dm_oltp.employees'
FROM   dm_oltp.employees;

INSERT IGNORE INTO hub_department (dept_id, load_dts, record_source)
SELECT dept_id, NOW(), 'dm_oltp.departments'
FROM   dm_oltp.departments;

-- ── LOAD: Satellite — detect changes via hash_diff ───────────────────────────
-- Only insert rows where hash_diff differs from the most recent satellite row.
INSERT INTO sat_employee
    (hub_emp_sk, first_name, last_name, email, salary, job_title,
     status, hire_date, termination_date, load_dts, hash_diff, record_source)
SELECT
    he.hub_emp_sk,
    e.first_name,
    e.last_name,
    e.email,            -- NULL preserved for emp 22 — vault does NOT clean
    e.salary,           -- NULL preserved for emp 10, 15
    e.job_title,
    e.status,
    e.hire_date,
    e.termination_date,
    NOW()               AS load_dts,
    MD5(CONCAT_WS('|',
        COALESCE(e.first_name, ''),
        COALESCE(e.last_name, ''),
        COALESCE(e.email, ''),
        COALESCE(e.salary, ''),
        COALESCE(e.job_title, ''),
        COALESCE(e.status, ''),
        COALESCE(e.hire_date, ''),
        COALESCE(e.termination_date, '')
    ))                  AS hash_diff,
    'dm_oltp.employees' AS record_source
FROM dm_oltp.employees e
JOIN hub_employee      he ON e.emp_id = he.emp_id
WHERE NOT EXISTS (
    -- skip if hash_diff matches the most recent satellite row (no change detected)
    SELECT 1
    FROM   sat_employee se
    WHERE  se.hub_emp_sk = he.hub_emp_sk
      AND  se.hash_diff  = MD5(CONCAT_WS('|',
               COALESCE(e.first_name, ''),
               COALESCE(e.last_name, ''),
               COALESCE(e.email, ''),
               COALESCE(e.salary, ''),
               COALESCE(e.job_title, ''),
               COALESCE(e.status, ''),
               COALESCE(e.hire_date, ''),
               COALESCE(e.termination_date, '')
           ))
);

-- ── LOAD: Link — employee to department relationship ─────────────────────────
INSERT IGNORE INTO lnk_emp_dept (hub_emp_sk, hub_dept_sk, load_dts, record_source)
SELECT
    he.hub_emp_sk,
    hd.hub_dept_sk,
    NOW(),
    'dm_oltp.employees'
FROM   dm_oltp.employees e
JOIN   hub_employee      he ON e.emp_id  = he.emp_id
JOIN   hub_department    hd ON e.dept_id = hd.dept_id;

-- ── QUERY: Reconstitute current employee state ────────────────────────────────
-- "Current" in Data Vault = the most recent satellite row per hub entity.
SELECT
    he.emp_id,
    se.first_name,
    se.last_name,
    se.email,              -- NULL visible here for emp 22 — transformation happens in Info Mart layer
    se.salary,
    se.job_title,
    se.status,
    se.hire_date,
    se.load_dts            AS last_seen_dts
FROM   hub_employee he
JOIN   sat_employee se
    ON se.hub_emp_sk = he.hub_emp_sk
    AND se.load_dts  = (
        SELECT MAX(load_dts)
        FROM   sat_employee se2
        WHERE  se2.hub_emp_sk = he.hub_emp_sk
    )
ORDER  BY he.emp_id;

-- emp 22: email = NULL in vault (correct — source had NULL; vault preserves reality)
-- emp 7 and emp 22 spot-check
SELECT he.emp_id, se.email, se.salary, se.load_dts
FROM   hub_employee he
JOIN   sat_employee se ON se.hub_emp_sk = he.hub_emp_sk
WHERE  he.emp_id IN (7, 22)
ORDER  BY he.emp_id, se.load_dts;

-- ── QUERY: Employee with their current department (via link) ──────────────────
SELECT
    he.emp_id,
    se.first_name,
    se.last_name,
    hd.dept_id
FROM   hub_employee   he
JOIN   lnk_emp_dept   lnk ON lnk.hub_emp_sk  = he.hub_emp_sk
JOIN   hub_department hd  ON hd.hub_dept_sk  = lnk.hub_dept_sk
JOIN   sat_employee   se
    ON se.hub_emp_sk = he.hub_emp_sk
    AND se.load_dts  = (
        SELECT MAX(load_dts)
        FROM   sat_employee se2
        WHERE  se2.hub_emp_sk = he.hub_emp_sk
    )
ORDER  BY he.emp_id;

-- ── Satellite history: full change log for emp 7 ─────────────────────────────
SELECT
    se.hub_emp_sk,
    se.first_name,
    se.last_name,
    se.job_title,
    se.salary,
    se.load_dts,
    se.hash_diff
FROM   hub_employee he
JOIN   sat_employee se ON se.hub_emp_sk = he.hub_emp_sk
WHERE  he.emp_id = 7
ORDER  BY se.load_dts;

-- =============================================================================
-- END OF FILE
-- =============================================================================
