-- ============================================================
-- sql-implementation/00-setup/01-database-and-schema.sql
-- Creates the sql-patterns database and all tables.
-- Engine : MySQL 8.0+
-- Run    : Run this file FIRST before any other file.
-- ============================================================
--
-- INTENTIONAL DATA FLAWS (by design — for pattern practice):
--   employees.salary       NULL for emp 10, 15 (contractor / pending payroll)
--   employees.email        NULL for emp 22 (data entry gap)
--   employees.salary       0.00 for emp 19 (soft-duplicate of emp 18, entry error)
--   employees.hire_date    future date for emp 41 (2025-08-01)
--   employees.status       'Terminated' + termination_date for emp 35
--   dept distribution      36% of employees are in Engineering (skew)
--   salary_history         one duplicate row (same emp, same date, same values)
--   purchase_orders        one orphaned row with NULL dept_id
--   leave_requests         one pair of overlapping dates for same employee
-- ============================================================

CREATE DATABASE IF NOT EXISTS `sql-patterns`
    CHARACTER SET utf8mb4
    COLLATE utf8mb4_unicode_ci;

USE `sql-patterns`;

-- ── Drop in reverse FK order ──────────────────────────────────
DROP TABLE IF EXISTS project_assignments;
DROP TABLE IF EXISTS performance_reviews;
DROP TABLE IF EXISTS emp_events;
DROP TABLE IF EXISTS leave_requests;
DROP TABLE IF EXISTS salary_history;
DROP TABLE IF EXISTS purchase_orders;
DROP TABLE IF EXISTS projects;
DROP TABLE IF EXISTS employees;
DROP TABLE IF EXISTS departments;

-- ── 1. departments ────────────────────────────────────────────
-- manager_id is a soft reference to employees (no FK — avoids
-- circular dependency). Updated after employee rows are inserted.
-- FLAW: budget is NULL for the Executive dept (unknown spend centre).

CREATE TABLE departments (
    dept_id    INT           NOT NULL,
    dept_name  VARCHAR(100)  NOT NULL,
    location   VARCHAR(100),
    budget     DECIMAL(15,2),
    manager_id INT,
    created_at DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (dept_id)
);

-- ── 2. employees ──────────────────────────────────────────────
-- Self-referencing FK on manager_id (CEO has NULL manager_id).
-- FLAWS: see header comment.

CREATE TABLE employees (
    emp_id           INT            NOT NULL,
    first_name       VARCHAR(50)    NOT NULL,
    last_name        VARCHAR(50)    NOT NULL,
    email            VARCHAR(100),
    phone            VARCHAR(20),
    dept_id          INT,
    manager_id       INT,
    job_title        VARCHAR(100),
    hire_date        DATE           NOT NULL,
    salary           DECIMAL(12,2),
    status           VARCHAR(20)    NOT NULL DEFAULT 'Active',
    termination_date DATE,
    PRIMARY KEY (emp_id),
    FOREIGN KEY (dept_id)    REFERENCES departments(dept_id),
    FOREIGN KEY (manager_id) REFERENCES employees(emp_id)
);

-- ── 3. salary_history ─────────────────────────────────────────
-- Tracks every salary change per employee over time.
-- salary_before is NULL for the initial hire entry.
-- Used for: SCD patterns, running totals, period-over-period.
-- FLAW: one duplicate row (same emp/date/amounts — entered twice).

CREATE TABLE salary_history (
    hist_id        INT            NOT NULL AUTO_INCREMENT,
    emp_id         INT            NOT NULL,
    salary_before  DECIMAL(12,2),
    salary_after   DECIMAL(12,2)  NOT NULL,
    effective_date DATE           NOT NULL,
    change_reason  VARCHAR(200),
    changed_by     INT,
    PRIMARY KEY (hist_id),
    FOREIGN KEY (emp_id)     REFERENCES employees(emp_id),
    FOREIGN KEY (changed_by) REFERENCES employees(emp_id)
);

-- ── 4. projects ───────────────────────────────────────────────
-- FLAW: end_date NULL for ongoing projects.
-- FLAW: one project where start_date > end_date (data entry error).
-- FLAW: budget NULL for one project.

CREATE TABLE projects (
    project_id   INT            NOT NULL,
    project_name VARCHAR(200)   NOT NULL,
    dept_id      INT,
    start_date   DATE           NOT NULL,
    end_date     DATE,
    budget       DECIMAL(15,2),
    status       VARCHAR(30)    NOT NULL DEFAULT 'Active',
    PRIMARY KEY (project_id),
    FOREIGN KEY (dept_id) REFERENCES departments(dept_id)
);

-- ── 5. project_assignments ────────────────────────────────────
-- FLAW: one duplicate row (same emp_id + project_id entered twice).
-- FLAW: hours_billed NULL for some rows (not yet logged).

CREATE TABLE project_assignments (
    assignment_id INT            NOT NULL AUTO_INCREMENT,
    emp_id        INT            NOT NULL,
    project_id    INT            NOT NULL,
    role          VARCHAR(100),
    start_date    DATE,
    end_date      DATE,
    hours_billed  DECIMAL(8,2),
    PRIMARY KEY (assignment_id),
    FOREIGN KEY (emp_id)     REFERENCES employees(emp_id),
    FOREIGN KEY (project_id) REFERENCES projects(project_id)
);

-- ── 6. performance_reviews ────────────────────────────────────
-- review_period format: 'YYYY-HN' (e.g. '2023-H2').
-- FLAW: some NULL ratings (review started but not submitted).
-- FLAW: some NULL reviewer_id.
-- Used for: ranking, cohort retention, window aggregates.

CREATE TABLE performance_reviews (
    review_id     INT            NOT NULL AUTO_INCREMENT,
    emp_id        INT            NOT NULL,
    reviewer_id   INT,
    review_date   DATE           NOT NULL,
    review_period VARCHAR(20)    NOT NULL,
    rating        INT,
    comments      TEXT,
    PRIMARY KEY (review_id),
    FOREIGN KEY (emp_id)      REFERENCES employees(emp_id),
    FOREIGN KEY (reviewer_id) REFERENCES employees(emp_id)
);

-- ── 7. emp_events ─────────────────────────────────────────────
-- Portal activity log: login, view_payslip, update_profile,
-- submit_leave, approve_leave, logout.
-- Used for: sessionization (30-min idle gap = new session),
--           funnel analysis (ordered step completion).
-- FLAW: missing logout events for some sessions.
-- FLAW: some NULL session_id (untracked events).

CREATE TABLE emp_events (
    event_id   BIGINT         NOT NULL AUTO_INCREMENT,
    emp_id     INT            NOT NULL,
    event_type VARCHAR(50)    NOT NULL,
    event_ts   DATETIME       NOT NULL,
    page       VARCHAR(100),
    session_id VARCHAR(50),
    PRIMARY KEY (event_id),
    FOREIGN KEY (emp_id) REFERENCES employees(emp_id)
);

-- ── 8. purchase_orders ────────────────────────────────────────
-- Departmental procurement records.
-- item_category drives market basket co-occurrence analysis.
-- FLAW: one row with NULL dept_id (orphaned order).
-- FLAW: one duplicate row (same dept/date/category/amount).
-- No FK on dept_id to allow the NULL orphan flaw.

CREATE TABLE purchase_orders (
    order_id      INT            NOT NULL,
    dept_id       INT,
    vendor        VARCHAR(100),
    item_category VARCHAR(100),
    amount        DECIMAL(12,2),
    order_date    DATE           NOT NULL,
    status        VARCHAR(30)    NOT NULL DEFAULT 'Approved',
    PRIMARY KEY (order_id)
);

-- ── 9. leave_requests ─────────────────────────────────────────
-- Individual leave applications.
-- Used for: gap-and-islands (consecutive-day islands).
-- FLAW: two overlapping date ranges for emp 12 (data entry error).
-- FLAW: one row with NULL leave_type.

CREATE TABLE leave_requests (
    request_id INT            NOT NULL,
    emp_id     INT            NOT NULL,
    leave_type VARCHAR(50),
    start_date DATE           NOT NULL,
    end_date   DATE           NOT NULL,
    status     VARCHAR(20)    NOT NULL DEFAULT 'Approved',
    PRIMARY KEY (request_id),
    FOREIGN KEY (emp_id) REFERENCES employees(emp_id)
);
