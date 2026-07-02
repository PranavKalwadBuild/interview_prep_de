-- ============================================================
-- 00-setup / 01-source-oltp-schema.sql
-- Database: dm_oltp
--
-- The OLTP source system — a normalised HR application.
-- Same 9-table employee/department schema as sql-implementation,
-- reproduced here so data-modelling-implementation is self-contained.
--
-- Design decisions documented:
--   • 3NF throughout: no repeating groups, no partial/transitive deps
--   • Natural keys from the source application (emp_id, dept_id)
--   • departments.manager_id is a soft reference (no FK) to avoid
--     circular dependency at creation time
--   • salary_history tracks every change; employees.salary is the
--     current denormalized copy (deliberate OLTP shortcut)
--   • Intentional flaws carried over from sql-implementation:
--       emp 10, 15 — NULL salary
--       emp 19     — salary = 0.00 (soft duplicate of emp 18)
--       emp 22     — NULL email
--       emp 35     — Terminated
--       emp 41     — future hire_date
--       salary_history row 16 — exact duplicate of row 15
--       purchase_orders rows 19-20 — exact duplicate
--       project_assignments rows 25-26 — exact duplicate
-- ============================================================

DROP DATABASE IF EXISTS dm_oltp;
CREATE DATABASE dm_oltp CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
USE dm_oltp;

-- ── departments ───────────────────────────────────────────────
CREATE TABLE departments (
    dept_id      INT          NOT NULL AUTO_INCREMENT PRIMARY KEY,
    dept_name    VARCHAR(100) NOT NULL,
    location     VARCHAR(100),
    budget       DECIMAL(15,2),               -- NULL for Executive: intentional flaw
    manager_id   INT,                         -- soft ref to employees.emp_id
    created_at   DATETIME     DEFAULT CURRENT_TIMESTAMP
);

-- ── employees ─────────────────────────────────────────────────
CREATE TABLE employees (
    emp_id           INT          NOT NULL AUTO_INCREMENT PRIMARY KEY,
    first_name       VARCHAR(50)  NOT NULL,
    last_name        VARCHAR(50)  NOT NULL,
    email            VARCHAR(100),            -- NULL for emp 22: intentional flaw
    phone            VARCHAR(20),
    hire_date        DATE         NOT NULL,
    termination_date DATE,
    job_title        VARCHAR(150) NOT NULL,
    dept_id          INT          NOT NULL,
    manager_id       INT,                     -- self-referencing FK for org hierarchy
    salary           DECIMAL(10,2),           -- NULL for contractors (emp 10, 15)
    status           VARCHAR(20)  DEFAULT 'Active',
    created_at       DATETIME     DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (dept_id)    REFERENCES departments(dept_id),
    FOREIGN KEY (manager_id) REFERENCES employees(emp_id)
);

-- ── salary_history ────────────────────────────────────────────
CREATE TABLE salary_history (
    hist_id        INT            NOT NULL AUTO_INCREMENT PRIMARY KEY,
    emp_id         INT            NOT NULL,
    old_salary     DECIMAL(10,2),
    new_salary     DECIMAL(10,2)  NOT NULL,
    change_reason  VARCHAR(200),
    effective_date DATE           NOT NULL,
    changed_by     INT,
    created_at     DATETIME       DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (emp_id) REFERENCES employees(emp_id)
);

-- ── projects ──────────────────────────────────────────────────
CREATE TABLE projects (
    project_id   INT          NOT NULL AUTO_INCREMENT PRIMARY KEY,
    project_name VARCHAR(200) NOT NULL,
    dept_id      INT,
    budget       DECIMAL(15,2),               -- NULL for proj 7: intentional flaw
    start_date   DATE,
    end_date     DATE,                         -- < start_date for proj 11: intentional flaw
    status       VARCHAR(20)  DEFAULT 'Active',
    FOREIGN KEY (dept_id) REFERENCES departments(dept_id)
);

-- ── project_assignments ───────────────────────────────────────
CREATE TABLE project_assignments (
    assignment_id INT           NOT NULL AUTO_INCREMENT PRIMARY KEY,
    emp_id        INT           NOT NULL,
    project_id    INT           NOT NULL,
    role          VARCHAR(100),
    start_date    DATE,
    end_date      DATE,
    hours_billed  DECIMAL(8,2),               -- NULL for some rows: intentional flaw
    FOREIGN KEY (emp_id)       REFERENCES employees(emp_id),
    FOREIGN KEY (project_id)   REFERENCES projects(project_id)
);

-- ── performance_reviews ───────────────────────────────────────
CREATE TABLE performance_reviews (
    review_id   INT           NOT NULL AUTO_INCREMENT PRIMARY KEY,
    emp_id      INT           NOT NULL,
    reviewer_id INT,                          -- NULL for some reviews: intentional flaw
    period      VARCHAR(20)   NOT NULL,
    rating      DECIMAL(3,1),                 -- NULL if reviewer skipped: intentional flaw
    comments    TEXT,
    review_date DATE,
    FOREIGN KEY (emp_id) REFERENCES employees(emp_id)
);

-- ── emp_events ────────────────────────────────────────────────
-- Web/app activity events for sessionization and funnel analysis
CREATE TABLE emp_events (
    event_id   INT          NOT NULL AUTO_INCREMENT PRIMARY KEY,
    emp_id     INT          NOT NULL,
    session_id VARCHAR(36),                   -- NULL for emp 14: intentional flaw
    event_type VARCHAR(50)  NOT NULL,
    event_ts   DATETIME     NOT NULL,
    page_url   VARCHAR(300),
    FOREIGN KEY (emp_id) REFERENCES employees(emp_id)
);

-- ── purchase_orders ───────────────────────────────────────────
CREATE TABLE purchase_orders (
    order_id      INT           NOT NULL AUTO_INCREMENT PRIMARY KEY,
    dept_id       INT,                        -- NULL for order 25: orphan flaw
    item_category VARCHAR(100)  NOT NULL,
    amount        DECIMAL(10,2) NOT NULL,
    order_date    DATE          NOT NULL,
    vendor        VARCHAR(200),
    FOREIGN KEY (dept_id) REFERENCES departments(dept_id)
);

-- ── leave_requests ────────────────────────────────────────────
CREATE TABLE leave_requests (
    request_id  INT          NOT NULL AUTO_INCREMENT PRIMARY KEY,
    emp_id      INT          NOT NULL,
    leave_type  VARCHAR(50),                  -- NULL for req 11: intentional flaw
    start_date  DATE         NOT NULL,
    end_date    DATE         NOT NULL,
    status      VARCHAR(20)  DEFAULT 'Pending',
    approved_by INT,
    created_at  DATETIME     DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (emp_id) REFERENCES employees(emp_id)
);
