-- ============================================================
-- 00-setup / 02-warehouse-schema.sql
-- Database: dm_warehouse
--
-- Dimensional warehouse schema built on the employee/HR domain.
-- All pattern implementations (06 through 12) USE dm_warehouse.
--
-- Schema overview:
--   dim_date              — calendar dimension (role-playing)
--   dim_department        — SCD0 (departments rarely change fundamentally)
--   dim_job               — job/role hierarchy
--   dim_employee_flags    — junk dimension (boolean flags)
--   dim_employee          — SCD Type 2 (tracks job title + dept changes)
--   fact_salary_payment   — transaction fact (grain: emp × pay month)
--   fact_monthly_headcount— periodic snapshot (grain: dept × calendar month)
--   fact_leave_lifecycle  — accumulating snapshot (grain: leave request)
--   fact_project_coverage — factless fact (grain: emp × project)
--   fact_performance_review — transaction fact (grain: review event)
--   bridge_emp_project    — bridge table for emp ↔ project M:N
--
-- Surrogate key convention: *_sk suffix, INT AUTO_INCREMENT
-- Natural key convention:   *_id suffix, preserved from OLTP
-- ============================================================

DROP DATABASE IF EXISTS dm_warehouse;
CREATE DATABASE dm_warehouse CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
USE dm_warehouse;

-- ─────────────────────────────────────────────────────────────
-- DIMENSION TABLES
-- ─────────────────────────────────────────────────────────────

-- ── dim_date ─────────────────────────────────────────────────
-- Standard calendar dimension covering 2015-01-01 to 2030-12-31.
-- Role-playing: used as hire_date, pay_date, snapshot_date,
-- start_date, end_date across multiple fact tables.
-- One physical table, aliased in queries with different names.
CREATE TABLE dim_date (
    date_sk         INT          NOT NULL PRIMARY KEY,  -- YYYYMMDD integer key
    date_actual     DATE         NOT NULL,
    year            INT          NOT NULL,
    quarter         INT          NOT NULL,
    month           INT          NOT NULL,
    month_name      VARCHAR(10)  NOT NULL,
    week_of_year    INT          NOT NULL,
    day_of_month    INT          NOT NULL,
    day_of_week     INT          NOT NULL,              -- 1=Monday ... 7=Sunday
    day_name        VARCHAR(10)  NOT NULL,
    is_weekend      TINYINT(1)   NOT NULL DEFAULT 0,
    is_month_start  TINYINT(1)   NOT NULL DEFAULT 0,
    is_month_end    TINYINT(1)   NOT NULL DEFAULT 0,
    fiscal_year     INT,                                -- if org uses non-calendar FY
    fiscal_quarter  INT,
    UNIQUE KEY uq_date_actual (date_actual)
);

-- ── dim_department ────────────────────────────────────────────
-- SCD Type 0: static reference — dept names and locations don't
-- change frequently enough to warrant history in this domain.
-- If they did change, this would become SCD Type 1 (overwrite) or
-- SCD Type 2 (history). Design decision documented in 09-scd-types/.
CREATE TABLE dim_department (
    dept_sk         INT          NOT NULL AUTO_INCREMENT PRIMARY KEY,
    dept_id         INT          NOT NULL,              -- natural key from OLTP
    dept_name       VARCHAR(100) NOT NULL,
    location        VARCHAR(100),
    budget          DECIMAL(15,2),                     -- NULL for Executive: preserved flaw
    dw_insert_ts    DATETIME     DEFAULT CURRENT_TIMESTAMP,
    UNIQUE KEY uq_dept_id (dept_id)
);

-- ── dim_job ───────────────────────────────────────────────────
-- Slowly changing role hierarchy. Derived from employees.job_title.
-- Normalised out of dim_employee to avoid update anomalies when
-- a job family is reorganised.
CREATE TABLE dim_job (
    job_sk          INT          NOT NULL AUTO_INCREMENT PRIMARY KEY,
    job_title       VARCHAR(150) NOT NULL,
    job_family      VARCHAR(100),                      -- Engineering, Finance, HR, etc.
    job_level       INT,                               -- 1=IC, 2=Lead, 3=Manager, 4=Director
    job_level_label VARCHAR(30),                       -- Individual Contributor, Lead, ...
    dw_insert_ts    DATETIME     DEFAULT CURRENT_TIMESTAMP,
    UNIQUE KEY uq_job_title (job_title)
);

-- ── dim_employee_flags ────────────────────────────────────────
-- Junk dimension: groups low-cardinality boolean flags that don't
-- belong to any single dimension. Avoids 5 nullable columns in the
-- fact table, reduces fact table width, and enables flag-combination
-- aggregations without EAV-style pivots.
--
-- Intentional flaws from source preserved:
--   has_null_salary  = 1  for emp 10, 15
--   has_null_email   = 1  for emp 22
--   is_terminated    = 1  for emp 35
--   is_future_hire   = 1  for emp 41
CREATE TABLE dim_employee_flags (
    flag_sk             INT          NOT NULL AUTO_INCREMENT PRIMARY KEY,
    is_contractor       TINYINT(1)   NOT NULL DEFAULT 0,
    is_terminated       TINYINT(1)   NOT NULL DEFAULT 0,
    is_future_hire      TINYINT(1)   NOT NULL DEFAULT 0,
    has_null_salary     TINYINT(1)   NOT NULL DEFAULT 0,
    has_null_email      TINYINT(1)   NOT NULL DEFAULT 0,
    flag_description    VARCHAR(200),
    UNIQUE KEY uq_flag_combo (is_contractor, is_terminated, is_future_hire, has_null_salary, has_null_email)
);

-- ── dim_employee ──────────────────────────────────────────────
-- SCD Type 2: tracks job_title and dept_id changes over time.
-- Each change produces a new row; the old row gets expiry_date set.
-- is_current = 1 on the active row; is_current = 0 on history rows.
--
-- manager_emp_id: degenerate dimension — the manager's natural key
-- stored directly in the dimension rather than as an FK to a separate
-- dim_manager table, because manager-as-dimension adds no new attrs
-- beyond what dim_employee already holds. Queries use a self-join.
CREATE TABLE dim_employee (
    employee_sk         INT          NOT NULL AUTO_INCREMENT PRIMARY KEY,
    emp_id              INT          NOT NULL,          -- natural key
    first_name          VARCHAR(50),
    last_name           VARCHAR(50),
    email               VARCHAR(100),
    job_sk              INT          NOT NULL,          -- FK to dim_job
    dept_sk             INT          NOT NULL,          -- FK to dim_department
    flag_sk             INT,                            -- FK to dim_employee_flags
    salary              DECIMAL(10,2),
    manager_emp_id      INT,                            -- degenerate: manager natural key
    hire_date           DATE,
    termination_date    DATE,
    -- SCD Type 2 tracking columns
    effective_date      DATE         NOT NULL,
    expiry_date         DATE,                           -- NULL = current record
    is_current          TINYINT(1)   NOT NULL DEFAULT 1,
    dw_insert_ts        DATETIME     DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (dept_sk) REFERENCES dim_department(dept_sk),
    FOREIGN KEY (job_sk)  REFERENCES dim_job(job_sk),
    INDEX idx_emp_id (emp_id),
    INDEX idx_is_current (is_current)
);

-- ─────────────────────────────────────────────────────────────
-- FACT TABLES
-- ─────────────────────────────────────────────────────────────

-- ── fact_salary_payment ───────────────────────────────────────
-- TRANSACTION FACT
-- Grain: one row per employee per monthly pay period.
-- Measures: salary_amount, bonus_amount (both additive).
-- The employee_sk here points to the SCD2 row that was current
-- during the pay period — critical for correct historical reporting.
CREATE TABLE fact_salary_payment (
    payment_sk      BIGINT       NOT NULL AUTO_INCREMENT PRIMARY KEY,
    employee_sk     INT          NOT NULL,
    dept_sk         INT          NOT NULL,
    job_sk          INT          NOT NULL,
    flag_sk         INT,
    pay_date_sk     INT          NOT NULL,             -- FK dim_date (month end)
    salary_amount   DECIMAL(10,2),                    -- NULL for contractors
    bonus_amount    DECIMAL(10,2)          DEFAULT 0,
    pay_year        INT          NOT NULL,
    pay_month       INT          NOT NULL,
    FOREIGN KEY (employee_sk) REFERENCES dim_employee(employee_sk),
    FOREIGN KEY (dept_sk)     REFERENCES dim_department(dept_sk),
    FOREIGN KEY (job_sk)      REFERENCES dim_job(job_sk),
    FOREIGN KEY (pay_date_sk) REFERENCES dim_date(date_sk),
    INDEX idx_pay_date_sk (pay_date_sk),
    INDEX idx_emp_sk (employee_sk)
);

-- ── fact_monthly_headcount ────────────────────────────────────
-- PERIODIC SNAPSHOT FACT
-- Grain: one row per department per calendar month.
-- Captures the state at month-end; rows are never deleted — if a
-- department disappears, its row at that month still exists with
-- headcount=0.
-- Measures: headcount (semi-additive across departments, NOT across time),
--            total_payroll (additive across departments, NOT across time),
--            avg_salary (non-additive — never SUM this).
CREATE TABLE fact_monthly_headcount (
    snapshot_sk         BIGINT       NOT NULL AUTO_INCREMENT PRIMARY KEY,
    dept_sk             INT          NOT NULL,
    snapshot_date_sk    INT          NOT NULL,          -- month-end date
    snapshot_year       INT          NOT NULL,
    snapshot_month      INT          NOT NULL,
    headcount           INT                   DEFAULT 0,
    active_count        INT                   DEFAULT 0,
    terminated_count    INT                   DEFAULT 0,
    total_payroll       DECIMAL(15,2)         DEFAULT 0,
    avg_salary          DECIMAL(10,2),                 -- non-additive
    FOREIGN KEY (dept_sk)          REFERENCES dim_department(dept_sk),
    FOREIGN KEY (snapshot_date_sk) REFERENCES dim_date(date_sk),
    UNIQUE KEY uq_dept_month (dept_sk, snapshot_date_sk)
);

-- ── fact_leave_lifecycle ──────────────────────────────────────
-- ACCUMULATING SNAPSHOT FACT
-- Grain: one row per leave request.
-- The row is UPDATED (not inserted) as the request moves through stages:
--   submitted → approved/rejected → leave taken
-- Multiple date FKs track when each milestone occurred.
-- days_to_decision is a derived measure (approve_date - submit_date).
-- leave_request_id is a DEGENERATE DIMENSION: the source system's PK
-- stored directly in the fact (no separate dim table needed since the
-- only attribute is the ID itself).
CREATE TABLE fact_leave_lifecycle (
    leave_sk            BIGINT       NOT NULL AUTO_INCREMENT PRIMARY KEY,
    employee_sk         INT          NOT NULL,
    leave_request_id    INT          NOT NULL,          -- degenerate dimension
    dept_sk             INT          NOT NULL,
    submit_date_sk      INT,                            -- always set at creation
    approve_date_sk     INT,                            -- set when approved
    reject_date_sk      INT,                            -- set when rejected
    start_date_sk       INT,                            -- leave period start
    end_date_sk         INT,                            -- leave period end
    leave_type          VARCHAR(50),                   -- NULL for req 11: preserved flaw
    duration_days       INT,
    current_status      VARCHAR(20)           DEFAULT 'Pending',
    days_to_decision    INT,                           -- NULL until decided
    FOREIGN KEY (employee_sk)   REFERENCES dim_employee(employee_sk),
    FOREIGN KEY (dept_sk)       REFERENCES dim_department(dept_sk),
    UNIQUE KEY uq_leave_request (leave_request_id)
);

-- ── fact_project_coverage ─────────────────────────────────────
-- FACTLESS FACT
-- Grain: one row per employee per project assignment.
-- No numeric measures — the fact of the relationship itself is the
-- measure (count of assignments, coverage rate, staffing overlap).
-- Used to answer: "Which projects are understaffed?",
-- "Which employees are on multiple projects simultaneously?"
CREATE TABLE fact_project_coverage (
    coverage_sk         BIGINT       NOT NULL AUTO_INCREMENT PRIMARY KEY,
    employee_sk         INT          NOT NULL,
    dept_sk             INT          NOT NULL,
    project_id          INT          NOT NULL,          -- natural key (no dim_project)
    project_name        VARCHAR(200),                  -- denorm for convenience
    start_date_sk       INT          NOT NULL,
    end_date_sk         INT,                            -- NULL if ongoing
    role                VARCHAR(100),
    FOREIGN KEY (employee_sk) REFERENCES dim_employee(employee_sk),
    FOREIGN KEY (dept_sk)     REFERENCES dim_department(dept_sk),
    FOREIGN KEY (start_date_sk) REFERENCES dim_date(date_sk)
);

-- ── fact_performance_review ───────────────────────────────────
-- TRANSACTION FACT
-- Grain: one row per performance review event.
-- reviewer_sk uses dim_employee as a ROLE-PLAYING DIMENSION:
-- the same dim_employee table aliased as dim_reviewer in queries.
-- This avoids creating a separate dim_reviewer table with identical
-- structure. The FK points to dim_employee.employee_sk.
CREATE TABLE fact_performance_review (
    review_sk           BIGINT       NOT NULL AUTO_INCREMENT PRIMARY KEY,
    employee_sk         INT          NOT NULL,
    reviewer_sk         INT,                            -- role-playing: FK to dim_employee
    dept_sk             INT          NOT NULL,
    review_date_sk      INT          NOT NULL,
    review_period       VARCHAR(20),
    rating              DECIMAL(3,1),                  -- NULL for some reviews: preserved flaw
    review_id           INT,                           -- degenerate dimension
    FOREIGN KEY (employee_sk)    REFERENCES dim_employee(employee_sk),
    FOREIGN KEY (dept_sk)        REFERENCES dim_department(dept_sk),
    FOREIGN KEY (review_date_sk) REFERENCES dim_date(date_sk)
);

-- ── bridge_emp_project ────────────────────────────────────────
-- BRIDGE TABLE for many-to-many between employees and projects.
-- Includes allocation_weight: what fraction of an employee's time
-- goes to this project. When querying semi-additive measures across
-- M:N relationships, multiply by weight to avoid double-counting.
-- Bridge tables are required whenever a dimension member can belong
-- to multiple groups simultaneously (multi-valued dimensions).
CREATE TABLE bridge_emp_project (
    bridge_sk           BIGINT       NOT NULL AUTO_INCREMENT PRIMARY KEY,
    employee_sk         INT          NOT NULL,
    project_id          INT          NOT NULL,
    project_name        VARCHAR(200),
    allocation_weight   DECIMAL(5,2)          DEFAULT 1.00,
    effective_date      DATE,
    expiry_date         DATE,
    FOREIGN KEY (employee_sk) REFERENCES dim_employee(employee_sk),
    INDEX idx_project_id (project_id)
);
