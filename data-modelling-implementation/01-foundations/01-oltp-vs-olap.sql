-- =============================================================================
-- FILE: 01-foundations/01-oltp-vs-olap.sql
-- PURPOSE: Side-by-side demonstration of OLTP (dm_oltp) vs OLAP (dm_warehouse)
--          query patterns against the same HR domain.
--
-- KEY CONCEPTS COVERED
--   1. OLTP — normalized 3NF structure, point lookups, join-heavy reads
--   2. OLAP — denormalized star schema, wide rows, aggregation-friendly
--   3. Row count & width comparison
--   4. Write pattern comparison (single INSERT vs batch load)
--   5. ETL vs ELT — transform strategy and cloud implications
--
-- DATABASE VERSIONS: MySQL 8.0+
-- SOURCE OLTP  : dm_oltp   (9 tables, ~200 rows total)
-- TARGET OLAP  : dm_warehouse (star schema, 6 facts + 5 dims)
-- =============================================================================


-- =============================================================================
-- SECTION 1 — OLTP: Normalized 3NF Structure
-- =============================================================================
/*
  WHY 3NF IN OLTP?
  -----------------
  OLTP (Online Transaction Processing) systems are optimised for WRITES.
  The goal is to store each fact exactly once, eliminating update anomalies.

  Example anomaly without normalisation:
    If a department name is stored in every employee row, renaming the
    department requires updating thousands of rows — and a partial failure
    leaves the data inconsistent.

  3NF rules enforced here:
    - Every non-key attribute depends only on the primary key (no partial deps)
    - No transitive dependencies (dept info lives in departments, not employees)

  TRADE-OFF: Reading a full employee picture requires multiple JOIN operations,
  which is expensive for large analytical queries but totally fine for
  looking up one employee at a time.

  TYPICAL OLTP QUERY PATTERN: Point lookup by primary key, < 5 joins,
  returns 1–10 rows, runs in < 10 ms.
*/

USE dm_oltp;

-- Point lookup: retrieve all meaningful attributes for employee 7
-- Notice how many tables must be joined just to answer "who is this person?"
SELECT
    e.emp_id,
    e.first_name,
    e.last_name,
    e.email,
    e.hire_date,
    e.job_title,
    e.employment_status,

    -- Department info lives in its own table (1NF → 3NF)
    d.dept_name,
    d.location,

    -- Latest salary: must filter salary_history for the current record
    sh.salary            AS current_salary,
    sh.effective_date    AS salary_effective_date,

    -- Most recent performance score
    pr.review_score      AS latest_review_score,
    pr.review_period     AS latest_review_period

FROM employees e

-- Join 1: resolve department FK
JOIN departments d
    ON e.dept_id = d.dept_id

-- Join 2: latest salary — correlated subquery to pick most recent row
LEFT JOIN salary_history sh
    ON sh.emp_id = e.emp_id
    AND sh.effective_date = (
        SELECT MAX(sh2.effective_date)
        FROM   salary_history sh2
        WHERE  sh2.emp_id = e.emp_id
    )

-- Join 3: most recent performance review
LEFT JOIN performance_reviews pr
    ON pr.emp_id = e.emp_id
    AND pr.review_date = (
        SELECT MAX(pr2.review_date)
        FROM   performance_reviews pr2
        WHERE  pr2.emp_id = e.emp_id
    )

WHERE e.emp_id = 7;


-- Additional OLTP query: show the normalized salary audit trail for one employee.
-- OLTP excels at this — every row is small and tightly indexed.
SELECT
    sh.history_id,
    sh.emp_id,
    CONCAT(e.first_name, ' ', e.last_name) AS employee_name,
    sh.salary,
    sh.effective_date,
    sh.change_reason
FROM salary_history sh
JOIN employees e ON sh.emp_id = e.emp_id
WHERE sh.emp_id = 7
ORDER BY sh.effective_date DESC;


-- =============================================================================
-- SECTION 2 — OLAP: Star Schema Wide-Row Query
-- =============================================================================
/*
  WHY DENORMALIZE IN OLAP?
  -------------------------
  OLAP (Online Analytical Processing) systems are optimised for READS and
  AGGREGATIONS across millions of rows.

  The star schema trades storage space for query simplicity:
    - Fact tables are narrow (keys + measures)
    - Dimension tables are wide (all descriptive attributes pre-joined)
    - Analysts write simpler SQL — no six-level join chains
    - Columnar engines (Redshift, BigQuery, Snowflake) compress wide tables
      efficiently, so the storage cost is lower than it looks

  TYPICAL OLAP QUERY PATTERN: Full scan of fact table, GROUP BY on dim keys,
  returns 10–10,000 aggregated rows, runs in seconds on large datasets.

  KEY DIFFERENCE FROM OLTP:
    The same "who is this person + what did they earn?" question is answered
    by joining fact → dim tables that are ALREADY denormalized, not by
    chasing FKs through a 3NF graph.
*/

USE dm_warehouse;

-- OLAP equivalent: same employee picture but from the star schema.
-- One JOIN per dimension — no correlated subqueries, no nested selects.
SELECT
    -- Date dimension attributes (pre-computed, no date math needed)
    dd.full_date,
    dd.calendar_year,
    dd.calendar_month,
    dd.month_name,
    dd.quarter,

    -- Employee dimension (all attributes in one wide row)
    de.emp_id,
    de.full_name,
    de.email,
    de.job_title,
    de.hire_date,
    de.employment_status,
    de.tenure_years,

    -- Department dimension
    ddept.dept_name,
    ddept.location,
    ddept.cost_center,

    -- Job dimension
    dj.job_title       AS canonical_job_title,
    dj.job_family,
    dj.job_level,
    dj.salary_band_min,
    dj.salary_band_max,

    -- Fact measures (the actual numbers)
    fsp.gross_salary,
    fsp.net_salary,
    fsp.bonus_amount,
    fsp.total_compensation

FROM fact_salary_payment fsp

-- Each JOIN goes to a pre-built dimension — no correlated subqueries
JOIN dim_date       dd    ON fsp.date_key       = dd.date_key
JOIN dim_employee   de    ON fsp.emp_key         = de.emp_key
JOIN dim_department ddept ON fsp.dept_key        = ddept.dept_key
JOIN dim_job        dj    ON fsp.job_key         = dj.job_key

-- Filter to the same employee, any year — OLAP returns ALL history at once
WHERE de.emp_id = 7
ORDER BY dd.full_date DESC;


-- OLAP aggregation: average salary by department and year — the bread-and-butter
-- query that would be painful in a 3NF OLTP schema.
SELECT
    ddept.dept_name,
    dd.calendar_year,
    COUNT(DISTINCT de.emp_id)     AS headcount,
    AVG(fsp.gross_salary)         AS avg_gross_salary,
    SUM(fsp.total_compensation)   AS total_comp_spend
FROM fact_salary_payment fsp
JOIN dim_date       dd    ON fsp.date_key  = dd.date_key
JOIN dim_employee   de    ON fsp.emp_key   = de.emp_key
JOIN dim_department ddept ON fsp.dept_key  = ddept.dept_key
GROUP BY ddept.dept_name, dd.calendar_year
ORDER BY ddept.dept_name, dd.calendar_year;


-- =============================================================================
-- SECTION 3 — Row Count and Width Comparison
-- =============================================================================
/*
  WHY THIS MATTERS IN INTERVIEWS
  --------------------------------
  A common interview question: "Why not just query the OLTP database for
  analytics?" The answer is partly about width and partly about isolation.

  OLTP row width example (employees table):
    - emp_id, dept_id (FK), first_name, last_name, email, hire_date,
      job_title, employment_status, created_at
    - ~9 columns, ~150 bytes/row, but you need 3+ joins to get context

  OLAP row width example (fact_salary_payment joined to dims):
    - All employee + department + job + date attributes in one row
    - ~40+ columns, ~600 bytes/row, BUT zero joins needed for common queries

  The OLAP row is wider, but the query engine reads it in a single pass.
  Columnar storage (not MySQL, but Redshift/BigQuery/Snowflake) reads ONLY
  the columns referenced in SELECT, making aggregations extremely fast.
*/

-- OLTP: how many tables and how many total rows underlie one salary report?
SELECT 'employees'          AS table_name, COUNT(*) AS row_count FROM dm_oltp.employees
UNION ALL
SELECT 'salary_history',                   COUNT(*) FROM dm_oltp.salary_history
UNION ALL
SELECT 'departments',                      COUNT(*) FROM dm_oltp.departments
UNION ALL
SELECT 'performance_reviews',              COUNT(*) FROM dm_oltp.performance_reviews
UNION ALL
SELECT 'project_assignments',              COUNT(*) FROM dm_oltp.project_assignments;

-- OLAP: same analytical answer from fewer (but wider) tables
SELECT 'fact_salary_payment' AS table_name, COUNT(*) AS row_count FROM dm_warehouse.fact_salary_payment
UNION ALL
SELECT 'dim_employee',                      COUNT(*) FROM dm_warehouse.dim_employee
UNION ALL
SELECT 'dim_department',                    COUNT(*) FROM dm_warehouse.dim_department
UNION ALL
SELECT 'dim_date',                          COUNT(*) FROM dm_warehouse.dim_date;

/*
  COLUMN WIDTH COMPARISON (approximate, for discussion):

  OLTP — employees row:     ~9  columns,  ~150 bytes
  OLTP — to answer salary question: join 3 tables, touch ~4 indexes

  OLAP — fact + dims row:  ~45  columns,  ~600 bytes
  OLAP — to answer salary question: 1 table scan + 4 small dim lookups
                                     (dims often fit in memory / cache)

  Conclusion: OLAP trades storage for query simplicity and speed at scale.
*/


-- =============================================================================
-- SECTION 4 — Write Pattern Comparison
-- =============================================================================
/*
  OLTP WRITE PATTERN: Single-row transactional INSERT
  ----------------------------------------------------
  OLTP applications write one row at a time, inside a transaction.
  If any part fails, the whole transaction rolls back — guaranteeing
  ACID consistency.

  OLAP WRITE PATTERN: Batch / bulk INSERT ... SELECT
  ---------------------------------------------------
  Warehouse loads happen in bulk, typically nightly or hourly.
  They are not real-time. The goal is throughput, not latency.
  A single batch INSERT might load 100,000 rows at once.

  WHY THE DIFFERENCE MATTERS:
  - OLTP: optimise for low-latency single-row writes (indexes on every FK)
  - OLAP: optimise for bulk scans and aggregations
          (indexes minimal or absent; partitioning + clustering instead)
*/

-- OLTP write pattern: a new employee starts today (one transaction, one row)
USE dm_oltp;

START TRANSACTION;

INSERT INTO employees (
    first_name, last_name, email,
    hire_date, job_title, dept_id, employment_status
)
VALUES (
    'Taylor', 'Nguyen', 'tnguyen@company.com',
    CURDATE(), 'Data Engineer', 3, 'Active'
);

-- Their starting salary is also written in a separate, normalized table
INSERT INTO salary_history (emp_id, salary, effective_date, change_reason)
VALUES (LAST_INSERT_ID(), 95000.00, CURDATE(), 'New hire');

COMMIT;
-- If either INSERT fails, ROLLBACK ensures no partial state.


-- OLAP write pattern: nightly batch load of salary facts
-- This runs OUTSIDE a user-facing transaction; it is an ETL job.
USE dm_warehouse;

INSERT INTO fact_salary_payment (
    date_key,
    emp_key,
    dept_key,
    job_key,
    gross_salary,
    net_salary,
    bonus_amount,
    total_compensation
)
SELECT
    -- Resolve surrogate key from dim_date using the natural key
    dd.date_key,
    de.emp_key,
    ddept.dept_key,
    dj.job_key,

    sh.salary                                       AS gross_salary,
    sh.salary * 0.72                                AS net_salary,   -- stub: 28% deduction
    COALESCE(sh.bonus_amount, 0)                    AS bonus_amount,
    sh.salary * 0.72 + COALESCE(sh.bonus_amount, 0) AS total_compensation

FROM dm_oltp.salary_history sh
JOIN dm_oltp.employees      e     ON sh.emp_id   = e.emp_id
JOIN dm_oltp.departments    dept  ON e.dept_id   = dept.dept_id

-- Look up surrogate keys from dimension tables
JOIN dm_warehouse.dim_date       dd    ON dd.full_date   = sh.effective_date
JOIN dm_warehouse.dim_employee   de    ON de.emp_id      = e.emp_id
    AND de.is_current = TRUE            -- SCD Type 2: get the current version
JOIN dm_warehouse.dim_department ddept ON ddept.dept_id  = dept.dept_id
    AND ddept.is_current = TRUE
JOIN dm_warehouse.dim_job        dj    ON dj.job_title   = e.job_title
    AND dj.is_current = TRUE

-- Avoid reloading rows that already exist (idempotency guard)
WHERE NOT EXISTS (
    SELECT 1
    FROM dm_warehouse.fact_salary_payment fsp_chk
    WHERE fsp_chk.date_key = dd.date_key
      AND fsp_chk.emp_key  = de.emp_key
);
-- A real pipeline would also truncate a staging table first, deduplicate,
-- then swap into the fact table — but the pattern above is illustrative.


-- =============================================================================
-- SECTION 5 — ETL vs ELT: Bronze Layer / Raw Staging Pattern
-- =============================================================================
/*
  ETL (Extract → Transform → Load)
  ----------------------------------
  The classical approach: data is cleaned and transformed BEFORE it enters
  the warehouse. Transformations happen in an intermediate server (e.g.,
  Informatica, SSIS, a Python script).

  PROS:
    - Only clean data enters the warehouse (smaller storage)
    - Sensitive fields can be masked/dropped before landing
  CONS:
    - If transform logic changes, you cannot reprocess history (raw data is gone)
    - Slower time-to-warehouse (transform must finish before load)

  ELT (Extract → Load → Transform)
  ----------------------------------
  Modern cloud data warehouses (Snowflake, BigQuery, Redshift) are so fast
  at SQL transformations that it is cheaper to load raw data first ("bronze"
  layer) and transform inside the warehouse ("silver" / "gold" layers).

  PROS:
    - Raw data is always preserved — replay any transformation
    - Transformations written in SQL, version-controlled with dbt
    - Warehouse compute is elastic — scale up for transforms, scale down after
  CONS:
    - Raw/sensitive data lands in the warehouse (needs column masking / RLS)
    - Storage costs more (raw + transformed copies)

  MEDALLION ARCHITECTURE (Bronze → Silver → Gold):
    Bronze  = raw, unmodified copy of source data
    Silver  = cleaned, deduplicated, type-cast
    Gold    = business-level aggregations / star schema facts and dims

  IN MYSQL CONTEXT:
    MySQL is not a cloud data warehouse, so ELT is unusual here.
    But the PATTERN is taught because it maps directly to what you do in
    Snowflake, BigQuery, or Databricks — and interviewers ask about it.
*/

-- ELT STUB: Step 1 — Load raw (bronze) — no transformation at all
USE dm_warehouse;

-- Bronze table mirrors source exactly; load_ts added for lineage tracking
CREATE TABLE IF NOT EXISTS bronze_employees LIKE dm_oltp.employees;

ALTER TABLE bronze_employees
    ADD COLUMN IF NOT EXISTS _load_ts   TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    ADD COLUMN IF NOT EXISTS _batch_id  VARCHAR(64);

-- Load raw, unmodified rows — intentional flaws included (NULL salary, emp 41
-- future hire_date, etc.). We preserve them for downstream audit.
INSERT INTO bronze_employees
SELECT
    e.*,
    CURRENT_TIMESTAMP  AS _load_ts,
    'batch_2024_01_01' AS _batch_id
FROM dm_oltp.employees e;

-- ELT STUB: Step 2 — Silver: clean and deduplicate inside the warehouse
-- (This would normally be a dbt model or a stored procedure.)
CREATE TABLE IF NOT EXISTS silver_employees AS
SELECT
    emp_id,
    first_name,
    last_name,
    -- Flag NULL email rather than silently dropping (emp 22 has NULL email)
    COALESCE(email, CONCAT('no-email-', emp_id, '@unknown.internal')) AS email,
    hire_date,
    job_title,
    dept_id,
    employment_status,
    _load_ts,
    _batch_id,
    -- Data quality flags for downstream consumers
    CASE WHEN email IS NULL THEN 1 ELSE 0 END         AS flag_null_email,
    CASE WHEN hire_date > CURDATE() THEN 1 ELSE 0 END AS flag_future_hire_date
FROM (
    -- Deduplicate: keep the first occurrence of each emp_id per batch
    SELECT *,
           ROW_NUMBER() OVER (PARTITION BY emp_id ORDER BY _load_ts) AS rn
    FROM bronze_employees
) deduped
WHERE rn = 1;

-- ELT STUB: Step 3 — Gold / star schema population happens from silver,
-- not directly from bronze. This is where dim_employee and fact tables are
-- populated (covered in later modules).

/*
  INTERVIEW TALKING POINT:
  "In our ELT pipeline we load raw data into a bronze layer first — this means
   we can always replay a failed or changed transformation without going back
   to the source system. The bronze layer is append-only with a _load_ts and
   _batch_id so we have full lineage. Transformations live in dbt models that
   are version-controlled and testable."
*/
