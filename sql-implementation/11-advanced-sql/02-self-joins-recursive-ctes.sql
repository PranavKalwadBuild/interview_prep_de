-- =============================================================================
-- FILE: 02-self-joins-recursive-ctes.sql
-- TOPIC: Self-Joins and Recursive CTEs
-- DB: sql-patterns
-- Covers: self-join patterns (manager lookups, peer comparison, date proximity),
--         recursive CTE org-chart traversal, subtree counts, cycle detection
-- =============================================================================

USE `sql-patterns`;

-- =============================================================================
-- SECTION 1: Employee + their manager name (basic self-join)
-- =============================================================================
-- Alias the same table twice: e = employee, m = manager.
-- LEFT JOIN preserves emp 1 (CEO, manager_id IS NULL) with NULL manager columns.
-- Expected: 41 rows; James Wilson (CEO) shows NULL for manager columns.

SELECT
    e.emp_id,
    CONCAT(e.first_name, ' ', e.last_name)      AS employee_name,
    e.job_title,
    e.salary,
    e.manager_id,
    CONCAT(m.first_name, ' ', m.last_name)      AS manager_name,
    m.job_title                                  AS manager_title
FROM employees e
LEFT JOIN employees m ON e.manager_id = m.emp_id
ORDER BY e.emp_id;

-- CEO row: manager_name IS NULL, manager_title IS NULL.
-- INNER JOIN would exclude the CEO row entirely.


-- =============================================================================
-- SECTION 2: Employees who earn MORE than their direct manager
-- =============================================================================
-- Business use: detects compensation inversion (subordinate outearning manager).
-- INNER JOIN: only employees with a manager AND where salary comparison is valid.
-- NULLs in salary: NULL > X is UNKNOWN in SQL → row is excluded (safe).
-- Expected: 0–few rows; inversion is an anomaly in well-structured orgs.

SELECT
    e.emp_id,
    CONCAT(e.first_name, ' ', e.last_name)      AS employee_name,
    e.salary                                     AS employee_salary,
    e.manager_id,
    CONCAT(m.first_name, ' ', m.last_name)      AS manager_name,
    m.salary                                     AS manager_salary,
    e.salary - m.salary                          AS salary_excess
FROM employees e
JOIN employees m ON e.manager_id = m.emp_id
WHERE e.salary > m.salary
ORDER BY salary_excess DESC;

-- If you want to include cases where manager salary IS NULL (unknown):
-- WHERE e.salary > m.salary OR (e.salary IS NOT NULL AND m.salary IS NULL)


-- =============================================================================
-- SECTION 3: Three-level self-join — employee + manager + skip-level manager
-- =============================================================================
-- e = employee, m = direct manager, gm = grandparent (skip-level manager).
-- Useful for org chart summaries and escalation path reports.
-- Expected: rows where all three levels exist; CEO and C-suite show NULLs upward.

SELECT
    e.emp_id,
    CONCAT(e.first_name, ' ', e.last_name)      AS employee_name,
    e.job_title,
    CONCAT(m.first_name, ' ', m.last_name)      AS manager_name,
    m.job_title                                  AS manager_title,
    CONCAT(gm.first_name, ' ', gm.last_name)    AS skip_level_manager,
    gm.job_title                                 AS skip_level_title
FROM employees e
LEFT JOIN employees m  ON e.manager_id   = m.emp_id
LEFT JOIN employees gm ON m.manager_id   = gm.emp_id
ORDER BY e.emp_id;

-- ICs (level 3 in hierarchy) will have all three columns populated.
-- Level-2 employees will have manager_name but NULL skip_level_manager.
-- CEO has both manager columns NULL.


-- =============================================================================
-- SECTION 4: Peer salary comparison — avg salary of same-manager peers
-- =============================================================================
-- For each employee, what do their peers (same manager_id, different emp_id) earn?
-- Peers share a manager but are NOT the employee themselves.
-- Expected: CEO (no manager) excluded; C-suite peers compare among themselves.

SELECT
    e.emp_id,
    CONCAT(e.first_name, ' ', e.last_name)      AS employee_name,
    e.manager_id,
    e.salary                                     AS own_salary,
    -- Aggregate over peers: exclude self with peer.emp_id != e.emp_id
    ROUND(AVG(peer.salary), 2)                   AS peer_avg_salary,
    COUNT(peer.emp_id)                           AS peer_count,
    ROUND(e.salary - AVG(peer.salary), 2)        AS vs_peer_avg
FROM employees e
JOIN employees peer
    ON  peer.manager_id = e.manager_id
    AND peer.emp_id    != e.emp_id          -- exclude self
WHERE e.manager_id IS NOT NULL              -- exclude CEO (no peers by manager)
GROUP BY e.emp_id, e.first_name, e.last_name, e.manager_id, e.salary
ORDER BY vs_peer_avg DESC;

-- Positive vs_peer_avg = earns above peer average.
-- NULL peer_avg_salary = employee has no peers (only child under that manager).


-- =============================================================================
-- SECTION 5: Same last name — soft duplicate / family member check
-- =============================================================================
-- Self-join on last_name to find pairs sharing a surname.
-- e1.emp_id < e2.emp_id avoids duplicate pairs (A,B) and (B,A).
-- Expected: 0–few rows depending on data; last names are generally unique.

SELECT
    e1.emp_id                                    AS emp1_id,
    CONCAT(e1.first_name, ' ', e1.last_name)     AS emp1_name,
    e1.dept_id                                   AS emp1_dept,
    e2.emp_id                                    AS emp2_id,
    CONCAT(e2.first_name, ' ', e2.last_name)     AS emp2_name,
    e2.dept_id                                   AS emp2_dept,
    e1.last_name                                 AS shared_last_name
FROM employees e1
JOIN employees e2
    ON  e1.last_name = e2.last_name
    AND e1.emp_id    < e2.emp_id            -- deduplicate pairs; exclude self-match
ORDER BY shared_last_name, e1.emp_id;

-- Extension: fuzzy match with SOUNDEX for phonetically similar names:
-- ON SOUNDEX(e1.last_name) = SOUNDEX(e2.last_name) AND e1.emp_id < e2.emp_id


-- =============================================================================
-- SECTION 6: Employees hired within 30 days of each other in the same dept
-- =============================================================================
-- Classic date-range self-join. e1.emp_id < e2.emp_id prevents double-counting.
-- ABS(DATEDIFF) handles either hire order; swap to directional if needed.
-- Expected: several pairs in Engineering (14 employees, denser hiring).

SELECT
    e1.dept_id,
    d.dept_name,
    e1.emp_id                                    AS emp1_id,
    CONCAT(e1.first_name, ' ', e1.last_name)     AS emp1_name,
    e1.hire_date                                 AS emp1_hire_date,
    e2.emp_id                                    AS emp2_id,
    CONCAT(e2.first_name, ' ', e2.last_name)     AS emp2_name,
    e2.hire_date                                 AS emp2_hire_date,
    ABS(DATEDIFF(e1.hire_date, e2.hire_date))    AS days_apart
FROM employees e1
JOIN employees e2
    ON  e1.dept_id   = e2.dept_id
    AND e1.emp_id    < e2.emp_id
    AND ABS(DATEDIFF(e1.hire_date, e2.hire_date)) <= 30
JOIN departments d ON e1.dept_id = d.dept_id
ORDER BY e1.dept_id, days_apart;

-- Performance note: this is an O(n²) join. On large tables, add an index on
-- (dept_id, hire_date) and bound the date range with BETWEEN to use it.


-- =============================================================================
-- SECTION 7: Recursive CTE — full org chart traversal (all levels)
-- =============================================================================
-- Anchor: CEO (manager_id IS NULL). Recursive step: add direct reports each pass.
-- level = depth from CEO (0=CEO, 1=C-suite, 2=managers, 3=ICs).
-- path = lineage string for sorting the tree visually by hierarchy.
-- Expected: 41 rows total; 4 levels (0–3) based on the known hierarchy.

WITH RECURSIVE orgchart AS (
    -- Anchor: root node (CEO has no manager)
    SELECT
        emp_id,
        first_name,
        last_name,
        job_title,
        salary,
        manager_id,
        0                               AS level,
        CAST(emp_id AS CHAR(200))       AS path
    FROM employees
    WHERE manager_id IS NULL

    UNION ALL

    -- Recursive step: join children to already-discovered nodes
    SELECT
        e.emp_id,
        e.first_name,
        e.last_name,
        e.job_title,
        e.salary,
        e.manager_id,
        o.level + 1,
        CONCAT(o.path, '->', e.emp_id)
    FROM employees e
    JOIN orgchart o ON e.manager_id = o.emp_id
)
SELECT
    emp_id,
    CONCAT(REPEAT('  ', level), first_name, ' ', last_name)  AS indented_name,
    job_title,
    salary,
    level,
    path
FROM orgchart
ORDER BY path;

-- REPEAT('  ', level) creates visual indentation for the tree.
-- ORDER BY path sorts nodes so children always appear after their parent.
-- Default recursion depth in MySQL: 1000 (@@cte_max_recursion_depth).


-- =============================================================================
-- SECTION 8: Count of direct AND indirect reports per manager
-- =============================================================================
-- The recursive CTE builds the full subtree; joining back collapses counts.
-- "indirect" = everyone below, not just direct reports.
-- Expected: James Wilson (CEO) = 40 total reports (all other employees).

WITH RECURSIVE orgchart AS (
    SELECT emp_id, manager_id, emp_id AS root_manager_id
    FROM employees
    WHERE manager_id IS NULL

    UNION ALL

    SELECT e.emp_id, e.manager_id, o.root_manager_id
    FROM employees e
    JOIN orgchart o ON e.manager_id = o.emp_id
),
-- Ancestor mapping: for each employee, all of their ancestors are managers
ancestor_map AS (
    SELECT
        emp_id,
        manager_id                              AS ancestor_id
    FROM employees
    WHERE manager_id IS NOT NULL

    UNION ALL

    SELECT
        a.emp_id,
        e.manager_id                            AS ancestor_id
    FROM ancestor_map a
    JOIN employees e ON a.ancestor_id = e.emp_id
    WHERE e.manager_id IS NOT NULL
)
SELECT
    mgr.emp_id                                  AS manager_id,
    CONCAT(mgr.first_name, ' ', mgr.last_name)  AS manager_name,
    mgr.job_title,
    -- Direct reports only
    COUNT(DISTINCT dr.emp_id)                   AS direct_reports,
    -- All reports (direct + indirect) via ancestor_map
    COUNT(DISTINCT am.emp_id)                   AS total_reports
FROM employees mgr
LEFT JOIN employees dr  ON dr.manager_id = mgr.emp_id
LEFT JOIN ancestor_map am ON am.ancestor_id = mgr.emp_id
GROUP BY mgr.emp_id, mgr.first_name, mgr.last_name, mgr.job_title
HAVING COUNT(DISTINCT dr.emp_id) > 0            -- only actual managers
ORDER BY total_reports DESC;

-- Expected: CEO has direct_reports=8 (known direct reports), total_reports=40.
-- Leaf employees (ICs with no reports) are excluded by HAVING.


-- =============================================================================
-- SECTION 9: Find employees N levels below a specific manager
-- =============================================================================
-- Use level=2 in recursive CTE to get employees exactly 2 hops from CEO.
-- Parameterise by changing WHERE level = N.
-- Expected: level=1 → 8 employees (C-suite); level=2 → managers under C-suite.

WITH RECURSIVE orgchart AS (
    SELECT
        emp_id,
        first_name,
        last_name,
        job_title,
        manager_id,
        0 AS level
    FROM employees
    WHERE manager_id IS NULL       -- anchor at CEO

    UNION ALL

    SELECT
        e.emp_id,
        e.first_name,
        e.last_name,
        e.job_title,
        e.manager_id,
        o.level + 1
    FROM employees e
    JOIN orgchart o ON e.manager_id = o.emp_id
)
-- Change level value to explore different depths:
-- level = 0 → CEO only
-- level = 1 → direct reports of CEO (C-suite, VPs)
-- level = 2 → L2 managers
-- level = 3 → individual contributors
SELECT
    emp_id,
    CONCAT(first_name, ' ', last_name)  AS employee_name,
    job_title,
    manager_id,
    level
FROM orgchart
WHERE level = 2                         -- 2 levels below CEO
ORDER BY emp_id;

-- To get everyone AT OR BELOW level N: WHERE level <= N
-- To get everyone BELOW a specific manager (not CEO):
--   Change anchor to WHERE emp_id = <target_manager_id>
--   Then the root of the tree is that manager at level=0.


-- =============================================================================
-- SECTION 10: Cycle detection guard in recursive CTE
-- =============================================================================
-- In a well-structured org chart, cycles (A→B→A) should not exist.
-- However, data corruption or misconfiguration can create them.
-- MySQL will hit @@cte_max_recursion_depth (default 1000) and error.
-- Guard: stop recursion if level > 10 (our real tree is ≤4 levels deep).
-- LOCATE checks the path string to detect if this emp_id already appeared.

WITH RECURSIVE orgchart AS (
    SELECT
        emp_id,
        first_name,
        last_name,
        manager_id,
        0                               AS level,
        CAST(emp_id AS CHAR(1000))      AS path,
        0                               AS is_cycle
    FROM employees
    WHERE manager_id IS NULL

    UNION ALL

    SELECT
        e.emp_id,
        e.first_name,
        e.last_name,
        e.manager_id,
        o.level + 1,
        CONCAT(o.path, '->', e.emp_id),
        -- Cycle detected if this emp_id already appears in the path string
        CASE
            WHEN LOCATE(CONCAT('->', e.emp_id, '->'), CONCAT(o.path, '->')) > 0
            THEN 1
            ELSE 0
        END
    FROM employees e
    JOIN orgchart o ON e.manager_id = o.emp_id
    WHERE o.is_cycle = 0               -- stop expanding a known-cycle branch
      AND o.level    < 10              -- hard depth limit: safety backstop
)
SELECT
    emp_id,
    CONCAT(first_name, ' ', last_name)  AS employee_name,
    level,
    path,
    is_cycle                            -- 1 = cycle detected at this node
FROM orgchart
ORDER BY path;

-- In our clean dataset: is_cycle should always be 0.
-- To TEST cycle detection: temporarily set emp 2's manager_id = an employee
-- that reports up through emp 2 — the recursive step will flag is_cycle=1
-- and stop expanding that branch, preventing an infinite loop.

-- Alternative (simpler but less informative): just add WHERE level < 10.
-- For production use on untrusted data: SET @@cte_max_recursion_depth = 15
-- before running so MySQL errors fast rather than consuming memory.
