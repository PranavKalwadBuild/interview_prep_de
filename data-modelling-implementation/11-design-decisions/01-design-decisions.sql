-- =============================================================================
-- FILE: 11-design-decisions/01-design-decisions.sql
-- PURPOSE: Demonstrate the three biggest dimensional modelling design traps
--          using the dm_oltp / dm_warehouse employee dataset.
-- MySQL 8.0+
-- =============================================================================

USE dm_warehouse;

-- =============================================================================
-- SECTION 1: THE FAN-OUT TRAP (a.k.a. CHASM TRAP)
-- =============================================================================
-- Scenario
-- --------
-- You want to see total payroll per department.  It feels natural to join
-- fact_salary_payment to fact_project_coverage on employee_sk so you can also
-- see project data alongside salary.  However, an employee who works on
-- N projects produces N rows in fact_project_coverage, so every JOIN multiplies
-- the salary fact rows by N before the GROUP BY runs — inflating totals.

-- ❌ WRONG — double/triple-counts salary for multi-project employees
-- -----------------------------------------------------------------------
-- An employee on 3 projects contributes their salary_amount THREE times.
SELECT
    d.dept_name,
    SUM(f.salary_amount)      AS total_payroll   -- INFLATED — fan-out here
FROM  fact_salary_payment  f
JOIN  fact_project_coverage c ON f.employee_sk = c.employee_sk   -- fan-out join
JOIN  dim_department        d ON f.dept_sk      = d.dept_sk
GROUP BY d.dept_name;
-- Why it's wrong:
--   fact_salary_payment grain = employee × pay_month  (1 row per month)
--   fact_project_coverage grain = employee × project  (1 row per assignment)
--   JOIN cardinality = (pay months) × (project count) before aggregation.
--   An employee on 3 projects in Jan 2024 produces 3 salary rows for that month.


-- ✅ CORRECT — Drill-Across Pattern (never join two facts directly)
-- -----------------------------------------------------------------------
-- Step 1: aggregate fact_salary_payment to employee grain
WITH salary_by_emp AS (
    SELECT
        employee_sk,
        SUM(salary_amount) AS total_salary
    FROM  fact_salary_payment
    GROUP BY employee_sk
),

-- Step 2: aggregate fact_project_coverage to employee grain
projects_by_emp AS (
    SELECT
        employee_sk,
        COUNT(DISTINCT project_id) AS project_count
    FROM  fact_project_coverage
    GROUP BY employee_sk
)

-- Step 3: join the two PRE-AGGREGATED sets (now both are 1 row per employee)
SELECT
    e.emp_id,
    e.first_name,
    e.last_name,
    d.dept_name,
    COALESCE(s.total_salary,  0)  AS total_salary,
    COALESCE(p.project_count, 0)  AS project_count
FROM  dim_employee   e
JOIN  dim_department d  ON e.dept_sk      = d.dept_sk
LEFT JOIN salary_by_emp   s ON e.employee_sk = s.employee_sk
LEFT JOIN projects_by_emp p ON e.employee_sk = p.employee_sk
WHERE e.is_current = 1;

-- Key Rule: conformed dimension (employee_sk) is the join key between the two
-- separately-aggregated result sets.  The join happens AFTER aggregation so
-- cardinality is 1:1 and no multiplication occurs.


-- =============================================================================
-- SECTION 2: MANY-TO-MANY RELATIONSHIPS — Bridge Table Solution
-- =============================================================================
-- Problem
-- -------
-- An employee can work on many projects; a project can have many employees.
-- This M:N relationship cannot be represented cleanly as a single FK column
-- in any fact or dimension table without causing redundancy or NULL sprawl.

-- ❌ WRONG — embedding project_id directly in fact_salary_payment
-- -----------------------------------------------------------------------
-- Option A: single column → NULL for employees on no project; wrong grain when
--           the employee joins a project (forces a new salary row).
-- Option B: one row per project → duplicates the salary for every project
--           (exactly the fan-out trap shown above).
--
-- Conceptual bad schema (do not execute):
--   ALTER TABLE fact_salary_payment ADD COLUMN project_id INT;
--   -- emp on 3 projects → 3 rows with identical salary_amount each month


-- ✅ CORRECT — bridge_emp_project with allocation_weight
-- -----------------------------------------------------------------------
-- The bridge table holds one row per (employee, project) pair plus a weight
-- representing what fraction of that employee's capacity goes to the project.
-- Weights must sum to 1.0 per employee.

-- Check weight integrity (should return 0 rows in a clean dataset):
SELECT
    employee_sk,
    ROUND(SUM(allocation_weight), 4) AS total_weight
FROM  bridge_emp_project
GROUP BY employee_sk
HAVING ROUND(SUM(allocation_weight), 4) != 1.0;

-- Weighted payroll attribution per project:
SELECT
    b.project_id,
    SUM(e.salary * b.allocation_weight)  AS attributed_salary
FROM  bridge_emp_project b
JOIN  dim_employee       e ON b.employee_sk = e.employee_sk
WHERE e.is_current = 1
GROUP BY b.project_id
ORDER BY attributed_salary DESC;

-- How to read this:
--   emp_sk=5, salary=120,000, allocation_weight=0.6 on project A → $72,000
--   emp_sk=5, salary=120,000, allocation_weight=0.4 on project B → $48,000
--   Total attributed = $120,000  ✓  (salary is not inflated)

-- Design note: bridge_emp_project sits BETWEEN dim_employee and
-- fact_project_coverage.  fact_project_coverage.employee_sk is joined to the
-- bridge; salary comes from dim_employee or fact_salary_payment separately
-- (drill-across, as in Section 1).


-- =============================================================================
-- SECTION 3: HIERARCHIES — Employee Org Chart
-- =============================================================================
-- Challenge
-- ---------
-- dm_oltp.employees.manager_id is a self-referencing FK, forming a tree of
-- arbitrary depth:
--   CEO (level 0) → Director (1) → Manager (2) → Lead (3) → IC (4)
-- Org restructures change depth and shape; a hardcoded approach breaks.

-- ❌ WRONG — hardcoded manager level columns
-- -----------------------------------------------------------------------
-- Conceptual bad schema (do not execute):
--   ALTER TABLE dim_employee
--     ADD COLUMN manager_level_1_emp_id INT,  -- breaks on reorg
--     ADD COLUMN manager_level_2_emp_id INT,  -- depth assumption fails
--     ADD COLUMN manager_level_3_emp_id INT;
-- Problem: if a Director is promoted to VP, all level columns shift;
--          queries like "find all reports under emp 7" require changing
--          the filter column name, not just the value.


-- ✅ Approach 1: Recursive CTE (best for OLTP / ad-hoc queries)
-- -----------------------------------------------------------------------
USE dm_oltp;

WITH RECURSIVE org AS (
    -- Anchor: the root node (CEO has no manager)
    SELECT
        emp_id,
        first_name,
        last_name,
        manager_id,
        0                           AS level,
        CAST(emp_id AS CHAR(200))   AS path
    FROM  dm_oltp.employees
    WHERE manager_id IS NULL        -- CEO / root

    UNION ALL

    -- Recursive: join each employee to their manager already in the CTE
    SELECT
        e.emp_id,
        e.first_name,
        e.last_name,
        e.manager_id,
        o.level + 1,
        CONCAT(o.path, '->', e.emp_id)
    FROM  dm_oltp.employees e
    INNER JOIN org           o ON e.manager_id = o.emp_id
)
SELECT
    level,
    LPAD('', level * 4, ' ') AS indent,   -- visual indent for readability
    emp_id,
    CONCAT(first_name, ' ', last_name)   AS employee_name,
    manager_id,
    path
FROM  org
ORDER BY path;

-- Performance note: the recursive CTE runs top-down and re-scans the base
-- table at each level.  For a 41-row table this is trivial; for 100K+ employees
-- across many levels the DW pre-flattened approach below is necessary.


-- ✅ Approach 2: Pre-flattened bridge_hierarchy (best for Data Warehouse)
-- -----------------------------------------------------------------------
USE dm_warehouse;

-- DDL for the bridge table (created here for illustration; normally in setup):
CREATE TABLE IF NOT EXISTS bridge_hierarchy (
    ancestor_emp_id   INT        NOT NULL COMMENT 'Higher node in the org tree',
    descendant_emp_id INT        NOT NULL COMMENT 'Lower node (any depth)',
    levels_below      INT        NOT NULL COMMENT '0 = self, 1 = direct report, 2 = grandchild ...',
    is_direct_parent  TINYINT(1) NOT NULL DEFAULT 0 COMMENT '1 if levels_below = 1',
    PRIMARY KEY (ancestor_emp_id, descendant_emp_id),
    INDEX idx_descendant (descendant_emp_id)
) COMMENT = 'Pre-flattened ancestor-descendant closure table for org hierarchy';

-- How it is populated (run after the recursive CTE above produces the tree):
-- Every ancestor-descendant pair at every depth is stored as one row.
-- Example rows for a chain CEO(1) → Dir(3) → Mgr(7) → IC(12):
--   (1,  1,  0, 0)  -- self
--   (1,  3,  1, 1)  -- direct report
--   (1,  7,  2, 0)  -- grandchild
--   (1, 12,  3, 0)  -- great-grandchild
--   (3,  3,  0, 0)
--   (3,  7,  1, 1)
--   (3, 12,  2, 0)
--   (7,  7,  0, 0)
--   (7, 12,  1, 1)
--   (12,12,  0, 0)

-- O(1) query: "find all employees under manager emp_id = 3, at any depth"
SELECT
    d.employee_sk,
    d.first_name,
    d.last_name,
    bh.levels_below
FROM  bridge_hierarchy bh
JOIN  dim_employee     d  ON bh.descendant_emp_id = d.emp_id
WHERE bh.ancestor_emp_id = 3
  AND bh.levels_below    > 0   -- exclude self row
  AND d.is_current        = 1
ORDER BY bh.levels_below, d.last_name;

-- Benefit: no recursion at query time.  Single index seek on ancestor_emp_id.
-- Downside: must be rebuilt on every org change (nightly ETL is sufficient
--           for most HR data warehouses).
