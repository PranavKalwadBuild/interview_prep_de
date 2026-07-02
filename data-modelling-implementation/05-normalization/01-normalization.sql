-- ============================================================
-- 05-normalization / 01-normalization.sql
-- Database context: dm_oltp (for reference); new nf_* tables
-- created here to illustrate each normal form stage.
--
-- This file walks the progression:
--   0NF  → unnormalised (repeating groups, multi-valued columns)
--   1NF  → atomic values, one fact per row
--   2NF  → no partial dependencies (composite-key tables only)
--   3NF  → no transitive dependencies
--   BCNF → every determinant is a candidate key
--   Deliberate denormalisation for the warehouse (OBT pattern)
--
-- Run order: execute top to bottom. All nf_* tables are prefixed
-- so they don't collide with the existing dm_oltp schema.
-- ============================================================

USE dm_oltp;

-- ─────────────────────────────────────────────────────────────
-- SECTION 1 — 0NF: UNNORMALISED FORM
-- ─────────────────────────────────────────────────────────────
/*
  RULE: No constraints on structure — data may contain repeating
  groups (multiple salary columns), multi-valued cells (comma-
  separated project lists), and mixed granularity in a single row.

  VIOLATION PREVENTED BY FIXING THIS: None yet — this is the
  starting point. Repeating groups make column counts variable,
  break relational algebra, and make it impossible to query
  "all projects for employee X" without string manipulation.

  WHAT THIS LOOKS LIKE: imagine an HR spreadsheet export where
  whoever designed it added salary_1, salary_2 for two pay
  periods, and crammed all project names into one CSV column.
*/

DROP TABLE IF EXISTS nf_0nf_employee_raw;

CREATE TABLE nf_0nf_employee_raw (
    emp_id          INT,
    full_name       VARCHAR(100),
    email           VARCHAR(100),
    dept_id         INT,
    dept_name       VARCHAR(100),   -- embedded: violates 3NF too, but we're at 0NF first
    dept_location   VARCHAR(100),   -- embedded: transitive dep on dept_id
    job_title       VARCHAR(150),
    salary_jan      DECIMAL(10,2),  -- REPEATING GROUP: salary by month as columns
    salary_feb      DECIMAL(10,2),
    salary_mar      DECIMAL(10,2),
    projects        VARCHAR(500),   -- MULTI-VALUED: "Phoenix,Apollo,Orion" in one cell
    project_roles   VARCHAR(500)    -- "Lead,Contributor,Reviewer" — positionally paired
);

INSERT INTO nf_0nf_employee_raw VALUES
(1,  'Alice Nguyen',   'alice@corp.com',   2, 'Engineering',  'Austin',
     'Senior Engineer',  9800.00,  9800.00,  9800.00,
     'Phoenix,Apollo',   'Lead,Contributor'),
(2,  'Bob Martinez',   'bob@corp.com',     2, 'Engineering',  'Austin',
     'Data Engineer',    7200.00,  7200.00,  7400.00,
     'Apollo',           'Contributor'),
(10, 'Carol Kim',      NULL,               5, 'Finance',      'New York',
     'Contractor',       NULL,     NULL,     NULL,
     'Orion',            'Reviewer'),
(22, 'Dan Osei',       NULL,               3, 'HR',           'Chicago',   -- NULL email: intentional flaw
     'HR Specialist',    6100.00,  6100.00,  6100.00,
     'Phoenix,Orion',    'Contributor,Lead');

/*
  DATA QUALITY MESS visible above:
  1. Three salary columns needed even for a 3-month view — add a month and
     you ALTER TABLE, breaking every downstream consumer.
  2. "Phoenix,Apollo" in the projects column cannot be JOINed to projects
     table — you need FIND_IN_SET() or a string split UDF.
  3. Project roles are positionally coupled to project names — one
     re-ordering corrupts both columns silently.
  4. dept_name and dept_location repeat identically for every Engineering
     employee — one dept rename means UPDATE across thousands of rows.
*/

-- ─────────────────────────────────────────────────────────────
-- SECTION 2 — 1NF: FIRST NORMAL FORM
-- ─────────────────────────────────────────────────────────────
/*
  RULE: Every column holds only ATOMIC (indivisible) values; there
  are no repeating groups. Each row must be uniquely identifiable
  (the table has a primary key). A repeating group of columns
  (salary_jan, salary_feb…) must become additional rows.

  VIOLATION PREVENTED: Queries that depend on the position of a
  value in a string ("the second comma-delimited project") become
  ordinary WHERE clauses. Reporting "total salary paid Jan–Mar"
  becomes SUM(salary_amount) rather than
  salary_jan + COALESCE(salary_feb,0) + COALESCE(salary_mar,0).

  WHAT CHANGED from 0NF:
  - projects and project_roles columns split into one row per
    employee × project combination.
  - salary_jan/feb/mar columns replaced with pay_month + salary_amount.
  - Composite PK: (emp_id, project_id, pay_month).
  NOTE: dept_name and dept_location are still embedded — that
  violation is addressed in 3NF.
*/

DROP TABLE IF EXISTS nf_1nf_employee;

CREATE TABLE nf_1nf_employee (
    emp_id          INT           NOT NULL,
    project_id      INT           NOT NULL,
    pay_month       VARCHAR(7)    NOT NULL,  -- 'YYYY-MM'
    full_name       VARCHAR(100),
    email           VARCHAR(100),
    dept_id         INT,
    dept_name       VARCHAR(100),            -- still embedded (transitive dep)
    dept_location   VARCHAR(100),            -- still embedded (transitive dep)
    job_title       VARCHAR(150),
    salary_amount   DECIMAL(10,2),
    project_name    VARCHAR(100),
    project_role    VARCHAR(100),
    PRIMARY KEY (emp_id, project_id, pay_month)
);

INSERT INTO nf_1nf_employee VALUES
-- Alice × Phoenix, 3 months
(1, 101, '2024-01', 'Alice Nguyen', 'alice@corp.com', 2, 'Engineering', 'Austin', 'Senior Engineer', 9800.00, 'Phoenix', 'Lead'),
(1, 101, '2024-02', 'Alice Nguyen', 'alice@corp.com', 2, 'Engineering', 'Austin', 'Senior Engineer', 9800.00, 'Phoenix', 'Lead'),
(1, 101, '2024-03', 'Alice Nguyen', 'alice@corp.com', 2, 'Engineering', 'Austin', 'Senior Engineer', 9800.00, 'Phoenix', 'Lead'),
-- Alice × Apollo, 3 months
(1, 102, '2024-01', 'Alice Nguyen', 'alice@corp.com', 2, 'Engineering', 'Austin', 'Senior Engineer', 9800.00, 'Apollo', 'Contributor'),
(1, 102, '2024-02', 'Alice Nguyen', 'alice@corp.com', 2, 'Engineering', 'Austin', 'Senior Engineer', 9800.00, 'Apollo', 'Contributor'),
(1, 102, '2024-03', 'Alice Nguyen', 'alice@corp.com', 2, 'Engineering', 'Austin', 'Senior Engineer', 9800.00, 'Apollo', 'Contributor'),
-- Bob × Apollo, 3 months (salary changes in March)
(2, 102, '2024-01', 'Bob Martinez',  'bob@corp.com', 2, 'Engineering', 'Austin', 'Data Engineer', 7200.00, 'Apollo', 'Contributor'),
(2, 102, '2024-02', 'Bob Martinez',  'bob@corp.com', 2, 'Engineering', 'Austin', 'Data Engineer', 7200.00, 'Apollo', 'Contributor'),
(2, 102, '2024-03', 'Bob Martinez',  'bob@corp.com', 2, 'Engineering', 'Austin', 'Data Engineer', 7400.00, 'Apollo', 'Contributor');

/*
  Now we can write:
    SELECT SUM(salary_amount) FROM nf_1nf_employee WHERE pay_month = '2024-01';
    SELECT * FROM nf_1nf_employee WHERE project_name = 'Apollo';
  — both are simple relational queries with no string parsing.

  REMAINING PROBLEM: project_name depends only on project_id, not
  on the full composite key (emp_id, project_id, pay_month).
  That is a PARTIAL DEPENDENCY — addressed in 2NF.
*/

-- ─────────────────────────────────────────────────────────────
-- SECTION 3 — 2NF: SECOND NORMAL FORM
-- ─────────────────────────────────────────────────────────────
/*
  RULE: Must be in 1NF AND every non-key attribute must depend on
  the WHOLE primary key, not just part of it (no partial deps).
  Partial dependencies only occur when the primary key is composite.

  VIOLATION PREVENTED: Update anomalies. If project 101 is renamed
  from "Phoenix" to "Phoenix-v2" in 1NF, every row with project_id=101
  must be updated. Miss one row and the table is inconsistent.
  With 2NF, change the project name in ONE row of nf_2nf_projects.

  WHAT CHANGED from 1NF:
  - project_name and project_role are split out of the employee
    table because project_name depends only on project_id (partial dep).
  - nf_2nf_employees still has a partial dep on dept (dept_name,
    dept_location) — that is addressed in 3NF.
  - The assignment table retains emp_id + project_id + pay_month
    as its composite key, but only stores the role (which genuinely
    depends on the full composite key — an employee's role on a
    project can change between pay periods).
*/

DROP TABLE IF EXISTS nf_2nf_projects;
DROP TABLE IF EXISTS nf_2nf_employees;
DROP TABLE IF EXISTS nf_2nf_assignments;

-- Projects — project attributes depend only on project_id
CREATE TABLE nf_2nf_projects (
    project_id      INT           NOT NULL PRIMARY KEY,
    project_name    VARCHAR(100)  NOT NULL
);

INSERT INTO nf_2nf_projects VALUES
(101, 'Phoenix'),
(102, 'Apollo'),
(103, 'Orion');

-- Employees — personal and job attributes depend only on emp_id.
-- dept_name and dept_location still embedded — partial dep on dept_id
-- remains (this is what 3NF will fix).
CREATE TABLE nf_2nf_employees (
    emp_id          INT           NOT NULL PRIMARY KEY,
    full_name       VARCHAR(100),
    email           VARCHAR(100),
    dept_id         INT,
    dept_name       VARCHAR(100),   -- will be removed in 3NF
    dept_location   VARCHAR(100),   -- will be removed in 3NF
    job_title       VARCHAR(150),
    salary_amount   DECIMAL(10,2)
);

INSERT INTO nf_2nf_employees VALUES
(1,  'Alice Nguyen',  'alice@corp.com', 2, 'Engineering', 'Austin', 'Senior Engineer', 9800.00),
(2,  'Bob Martinez',  'bob@corp.com',   2, 'Engineering', 'Austin', 'Data Engineer',   7400.00),
(10, 'Carol Kim',     NULL,             5, 'Finance',     'New York','Contractor',      NULL),
(22, 'Dan Osei',      NULL,             3, 'HR',          'Chicago', 'HR Specialist',   6100.00);

-- Assignments — the role genuinely depends on (emp_id, project_id, pay_month)
-- An employee's role on a project may change month over month.
CREATE TABLE nf_2nf_assignments (
    emp_id          INT           NOT NULL,
    project_id      INT           NOT NULL,
    pay_month       VARCHAR(7)    NOT NULL,
    project_role    VARCHAR(100),
    salary_amount   DECIMAL(10,2),
    PRIMARY KEY (emp_id, project_id, pay_month),
    FOREIGN KEY (emp_id)      REFERENCES nf_2nf_employees(emp_id),
    FOREIGN KEY (project_id)  REFERENCES nf_2nf_projects(project_id)
);

INSERT INTO nf_2nf_assignments VALUES
(1, 101, '2024-01', 'Lead',        9800.00),
(1, 101, '2024-02', 'Lead',        9800.00),
(1, 101, '2024-03', 'Lead',        9800.00),
(1, 102, '2024-01', 'Contributor', 9800.00),
(2, 102, '2024-01', 'Contributor', 7200.00),
(2, 102, '2024-02', 'Contributor', 7200.00),
(2, 102, '2024-03', 'Contributor', 7400.00);

/*
  Rename project 101: UPDATE nf_2nf_projects SET project_name='Phoenix-v2' WHERE project_id=101;
  One row changed. nf_2nf_assignments rows are untouched. Consistent.
*/

-- ─────────────────────────────────────────────────────────────
-- SECTION 4 — 3NF: THIRD NORMAL FORM
-- ─────────────────────────────────────────────────────────────
/*
  RULE: Must be in 2NF AND no non-key attribute may depend on
  another non-key attribute (no transitive dependencies).
  Equivalently: every non-key attribute depends on the key,
  the whole key, and nothing but the key (the "Codd mantra").

  IDENTIFYING THE TRANSITIVE DEPENDENCY in nf_2nf_employees:
    emp_id → dept_id          (direct: an employee belongs to a dept)
    dept_id → dept_name       (indirect: dept name determined by dept_id)
    dept_id → dept_location   (indirect: location determined by dept_id)
  Therefore: emp_id → dept_name via the non-key column dept_id.
  dept_name and dept_location are transitively dependent on emp_id
  through dept_id — that is the violation.

  VIOLATION PREVENTED: If Engineering moves from Austin to Seattle,
  update ONE row in nf_3nf_departments instead of updating every
  Engineering employee row in nf_2nf_employees.

  WHAT CHANGED from 2NF:
  - dept_name and dept_location extracted into nf_3nf_departments.
  - nf_3nf_employees retains only dept_id (the FK) — not dept attributes.

  THE dm_oltp SCHEMA IS ALREADY IN 3NF — compare:
    dm_oltp.employees: emp_id PK, dept_id FK (no dept_name column)
    dm_oltp.departments: dept_id PK, dept_name, location (no emp attrs)
  The original designers already performed this split. The nf_0nf_
  tables above reconstructed the pre-normalised form for illustration.
*/

DROP TABLE IF EXISTS nf_3nf_departments;
DROP TABLE IF EXISTS nf_3nf_employees;

CREATE TABLE nf_3nf_departments (
    dept_id         INT           NOT NULL PRIMARY KEY,
    dept_name       VARCHAR(100)  NOT NULL,
    dept_location   VARCHAR(100)
);

INSERT INTO nf_3nf_departments VALUES
(2, 'Engineering', 'Austin'),
(3, 'HR',          'Chicago'),
(5, 'Finance',     'New York');

CREATE TABLE nf_3nf_employees (
    emp_id          INT           NOT NULL PRIMARY KEY,
    full_name       VARCHAR(100),
    email           VARCHAR(100),
    dept_id         INT           NOT NULL,      -- FK only — no dept_name here
    job_title       VARCHAR(150),
    salary_amount   DECIMAL(10,2),
    FOREIGN KEY (dept_id) REFERENCES nf_3nf_departments(dept_id)
);

INSERT INTO nf_3nf_employees VALUES
(1,  'Alice Nguyen', 'alice@corp.com', 2, 'Senior Engineer', 9800.00),
(2,  'Bob Martinez', 'bob@corp.com',   2, 'Data Engineer',   7400.00),
(10, 'Carol Kim',    NULL,             5, 'Contractor',      NULL),
(22, 'Dan Osei',     NULL,             3, 'HR Specialist',   6100.00);

/*
  COMPARISON — dm_oltp matches this structure exactly:

    dm_oltp.employees  ≈  nf_3nf_employees
      emp_id PRIMARY KEY
      dept_id FOREIGN KEY → departments(dept_id)
      NO dept_name column in employees table

    dm_oltp.departments  ≈  nf_3nf_departments
      dept_id PRIMARY KEY
      dept_name, location

  The dm_oltp source schema is in 3NF. The "deliberate OLTP shortcut"
  is employees.salary being a copy of the latest salary_history row —
  that is an intentional denormalisation documented separately below.
*/

-- ─────────────────────────────────────────────────────────────
-- SECTION 5 — BCNF AND DELIBERATE DENORMALISATION
-- ─────────────────────────────────────────────────────────────
/*
  BCNF (BOYCE-CODD NORMAL FORM):
  A stricter version of 3NF. A table is in BCNF if and only if
  for every non-trivial functional dependency X → Y, X is a
  superkey (a set of attributes that uniquely identifies a row).

  Difference from 3NF: 3NF allows a non-key attribute to be a
  determinant IF the dependent attribute is part of a candidate
  key. BCNF forbids this entirely.

  WHEN BCNF MATTERS IN PRACTICE:
  Consider a table: (student, course, teacher) where:
    - Each teacher teaches exactly one course.
    - A student can have multiple teachers (if the course has sections).
  Functional dependencies:
    (student, course) → teacher   [composite key]
    teacher → course              [teacher determines course]
  The table is in 3NF (teacher is part of the candidate key path)
  but NOT in BCNF (teacher → course and teacher is not a superkey).

  For the HR/employee domain this situation rarely arises. dm_oltp
  is already in BCNF. BCNF becomes relevant in scheduling or
  many-to-many intersection tables with additional constraints.
  OLTP systems are typically designed to 3NF; BCNF is a refinement
  applied when specific anomaly patterns are discovered.
*/

-- ── Deliberate denormalisation for the warehouse ──────────────
/*
  WHY DENORMALISE?
  The warehouse is optimised for READ throughput, not update safety.
  Analytics tools (Tableau, Looker, Power BI) perform best when a
  single table contains all the columns a query needs — no JOINs,
  no FK lookups, simple GROUP BY and aggregation.

  This is sometimes called the "One Big Table" (OBT) pattern, and
  is common in Parquet/columnar stores (Redshift, BigQuery, Snowflake)
  where column pruning makes wide tables cheap to scan.

  TRADE-OFF: if Engineering moves from Austin to Seattle, every
  denormalised row for every Engineering employee in every month
  must be updated (or the table regenerated from source). This is
  acceptable in a warehouse where the ETL pipeline rebuilds
  historical snapshots from dm_oltp anyway.

  EXAMPLE: wide employee table for a BI flat extract.
  Note: in production this would be a VIEW or a CTAS in the ETL;
  creating it as a real table here only for illustration.
*/

DROP TABLE IF EXISTS denorm_employee_wide;

CREATE TABLE denorm_employee_wide AS
SELECT
    emp.emp_id,
    emp.first_name,
    emp.last_name,
    emp.email,
    emp.job_title,
    emp.salary,
    emp.status,
    emp.hire_date,
    emp.termination_date,
    d.dept_id,
    d.dept_name,
    d.location        AS dept_location,
    d.budget          AS dept_budget,
    -- Derived flags (mimicking what dm_warehouse.dim_employee_flags captures)
    CASE WHEN emp.salary IS NULL        THEN 1 ELSE 0 END AS has_null_salary,
    CASE WHEN emp.email  IS NULL        THEN 1 ELSE 0 END AS has_null_email,
    CASE WHEN emp.status = 'Terminated' THEN 1 ELSE 0 END AS is_terminated,
    CASE WHEN emp.hire_date > CURDATE() THEN 1 ELSE 0 END AS is_future_hire,
    CASE WHEN emp.salary = 0.00         THEN 1 ELSE 0 END AS has_zero_salary
FROM dm_oltp.employees  emp
JOIN dm_oltp.departments d ON emp.dept_id = d.dept_id;

/*
  QUERY SIMPLICITY (no JOINs needed for a BI consumer):
*/
SELECT
    dept_name,
    dept_location,
    COUNT(*)                             AS employee_count,
    AVG(salary)                          AS avg_salary,
    SUM(CASE WHEN is_terminated = 1 THEN 1 ELSE 0 END) AS terminated_count
FROM denorm_employee_wide
GROUP BY dept_name, dept_location
ORDER BY dept_name;

/*
  vs. the normalised equivalent (JOIN required):

    SELECT d.dept_name, d.location, COUNT(*) AS employee_count, AVG(e.salary)
    FROM dm_oltp.employees e
    JOIN dm_oltp.departments d ON e.dept_id = d.dept_id
    GROUP BY d.dept_name, d.location;

  UPDATE ANOMALY RISK (the cost of denormalisation):
  If the Engineering dept moves to Seattle:
    -- Normalised (3NF): 1 row updated, immediately consistent
    UPDATE dm_oltp.departments SET location = 'Seattle' WHERE dept_id = 2;

    -- Denormalised: must rebuild the entire table or run a bulk update
    UPDATE denorm_employee_wide SET dept_location = 'Seattle' WHERE dept_id = 2;
    -- If the ETL runs nightly, data is stale for up to 24 hours.

  DELIBERATE OLTP SHORTCUT — employees.salary:
  dm_oltp.employees.salary is a denormalised copy of the most recent
  row in dm_oltp.salary_history. This is acceptable because:
    1. salary_history is the authoritative source of truth.
    2. The application always writes to salary_history first, then
       updates employees.salary in the same transaction.
    3. This shortcut avoids a correlated subquery on every employee
       lookup (SELECT MAX(effective_date) FROM salary_history WHERE emp_id=?).
  In a warehouse context, the ETL reads salary_history to reconstruct
  point-in-time salary values, ignoring employees.salary entirely.
*/

-- ─────────────────────────────────────────────────────────────
-- CLEANUP NOTE
-- ─────────────────────────────────────────────────────────────
-- The nf_* and denorm_* tables are educational scaffolding.
-- They are not part of the dm_oltp operational schema.
-- To remove them: DROP TABLE IF EXISTS nf_0nf_employee_raw,
-- nf_1nf_employee, nf_2nf_projects, nf_2nf_employees,
-- nf_2nf_assignments, nf_3nf_departments, nf_3nf_employees,
-- denorm_employee_wide;
-- ─────────────────────────────────────────────────────────────
