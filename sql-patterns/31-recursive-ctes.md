<!-- Part of sql-patterns: Recursive CTEs and Hierarchies -->
<!-- Source: sql_patterns.md lines 8193–8431 -->

## 17. Recursive CTEs (Hierarchies)

### What it solves

Traverse tree or graph structures stored in relational tables — org charts, category trees, bill of materials.

### Keywords to spot

> "hierarchy", "tree", "ancestors", "descendants", "all levels",
> "org chart", "category path", "parent-child-grandchild",
> "all subordinates", "path from root",
> "depth", "graph traversal", "nested", "all nodes below",
> "recursive relationship", "chain", "lineage", "bill of materials",
> "roll up to", "full path", "transitive closure"

### Business Context

- **HR:** Find all employees under a given manager, all levels deep (headcount roll-up); compute total salary budget for an entire subtree of the org; find the shortest reporting path between two employees
- **E-commerce:** Get full category path for a product (Electronics > Phones > Smartphones); find all subcategories under a parent category for breadcrumb navigation
- **Data Engineering:** Find all dependent jobs in a DAG pipeline (impact analysis before changing a table); detect circular dependencies in a transformation graph
- **Finance:** Account hierarchy roll-ups for consolidated P&L (parent company → subsidiary → division → cost centre); identify all entities owned by a holding company for compliance reporting
- **Manufacturing/Supply Chain:** Bill of Materials — find all components (and sub-components) required to build a product; compute total raw material cost bottom-up
- **Retail:** Store hierarchy (region → district → store) for roll-up reporting

### Boilerplate

```

```sql
-- employees(emp_id, emp_name, manager_id)
-- Find all reports under manager_id = 5, all levels deep

WITH RECURSIVE org_tree AS (
    -- Anchor: start with the root manager
    SELECT emp_id, emp_name, manager_id, 0 AS depth
    FROM employees
    WHERE emp_id = 5

    UNION ALL

    -- Recursive: join children to the current level
    SELECT e.emp_id, e.emp_name, e.manager_id, ot.depth + 1
    FROM employees e
    INNER JOIN org_tree ot ON e.manager_id = ot.emp_id
)
SELECT * FROM org_tree
ORDER BY depth, emp_name;

-- Compute full path (e.g., "CEO > VP > Manager > Analyst")
WITH RECURSIVE org_tree AS (
    SELECT emp_id, emp_name, manager_id,
           emp_name::TEXT AS path
    FROM employees
    WHERE manager_id IS NULL   -- root node

    UNION ALL

    SELECT e.emp_id, e.emp_name, e.manager_id,
           ot.path || ' > ' || e.emp_name
    FROM employees e
    JOIN org_tree ot ON e.manager_id = ot.emp_id
)
SELECT emp_id, emp_name, path FROM org_tree;
```

### Gotchas

- Always include a depth counter or row limit to prevent infinite loops from circular references
- The anchor query (before UNION ALL) defines the starting node(s)
- Most databases have a default recursion depth limit (e.g., 100 in MySQL)

### Edge Cases

#### Edge 17-A: Circular reference causes infinite loop

**Problem:**

```sql
-- If the data has a cycle (e.g., A → B → C → A in manager hierarchy due to data bug),
-- the recursive CTE will loop forever until it hits the engine's recursion depth limit

-- PostgreSQL: default max recursion depth = none (loops forever, eventually OOM or timeout)
-- SQL Server: default max recursion = 100 (raises error after 100 iterations)
-- Snowflake: has an internal limit
```

**Fix — add a depth limiter and cycle detection:**

```sql
WITH RECURSIVE org AS (
    SELECT emp_id, manager_id, 0 AS depth, ARRAY[emp_id] AS visited
    FROM employees WHERE manager_id IS NULL

    UNION ALL

    SELECT e.emp_id, e.manager_id, o.depth + 1, o.visited || e.emp_id
    FROM employees e
    JOIN org o ON e.manager_id = o.emp_id
    WHERE e.emp_id != ALL(o.visited)  -- cycle detection: don't revisit a node
      AND o.depth < 20               -- depth limit: fail safely if hierarchy > 20 levels
)
SELECT * FROM org;

-- PostgreSQL 14+ also has built-in CYCLE clause:
WITH RECURSIVE org AS (... CYCLE emp_id SET is_cycle TO TRUE DEFAULT FALSE ...)
SELECT * FROM org WHERE NOT is_cycle;
```

#### Edge 17-B: Recursive CTE performance degrades exponentially with wide trees

**Problem:**

```sql
-- Each recursive step scans the entire base table for matching rows
-- For a balanced binary tree of depth 20: 2^20 = 1M nodes → recursive CTE does 20 passes
-- For an unbalanced tree (linked list): depth 100,000 → 100,000 recursive steps
-- Each step is O(N) scan → total O(N²) for linked lists

-- Rule of thumb: recursive CTEs are fine for depth < 100
-- For deep hierarchies (org charts with 10k+ levels): use path enumeration
-- (store the full path as a VARCHAR during writes, query with LIKE 'prefix%')
```

**Fix — for very deep hierarchies:**

```sql
-- Option 1: Materialize the closure table (all ancestor-descendant pairs) during ETL.
-- Run the recursive query ONCE and store the result; query the stored table thereafter.
CREATE TABLE org_closure AS
WITH RECURSIVE org AS (
    SELECT emp_id, manager_id, emp_id AS ancestor, emp_id AS descendant, 0 AS depth
    FROM employees WHERE manager_id IS NULL
    UNION ALL
    SELECT e.emp_id, e.manager_id, o.ancestor, e.emp_id, o.depth + 1
    FROM employees e JOIN org o ON e.manager_id = o.emp_id
)
SELECT ancestor, descendant, depth FROM org;
-- Query: SELECT descendant FROM org_closure WHERE ancestor = :manager_id
-- O(1) lookup instead of O(N × depth) recursive scan at query time

-- Option 2: Path enumeration — store full ancestor path as a VARCHAR string.
-- Maintain path at write time (on every INSERT/UPDATE to employees):
UPDATE employees
SET path = (
    SELECT path || '/' || emp_id::TEXT
    FROM employees WHERE emp_id = manager_id
)
WHERE manager_id IS NOT NULL;
-- Query all descendants of emp_id 5:
SELECT * FROM employees WHERE path LIKE '%/5/%';
-- Uses LIKE with prefix — efficient with a B-tree index on path
```

---

### At Scale

#### Failure Mechanism

Recursive CTEs are **inherently sequential**: each iteration depends on the previous. In distributed SQL:

- Spark: does not natively support recursive CTEs — simulates them with iterative Dataframe operations (10+ passes over data)
- BigQuery: supports recursive CTEs but limits recursion depth to 500
- Snowflake: supports recursive CTEs; each iteration is a full scan of the previous iteration's result
- For an org chart with 10 levels and 1M employees: 10 recursive iterations × full scan each = 10 full scans of an increasingly large intermediate result

#### Code-Level Fix

```sql

```sql
-- BEFORE: recursive CTE for full org hierarchy
WITH RECURSIVE org AS (
    SELECT emp_id, manager_id, 0 AS depth FROM employees WHERE manager_id IS NULL
    UNION ALL
    SELECT e.emp_id, e.manager_id, o.depth + 1
    FROM employees e JOIN org o ON e.manager_id = o.emp_id
)
SELECT * FROM org;  -- 10 iterations × 1M rows = 10M row-scans

-- FIX 1: Pre-compute the closure table (all ancestor-descendant pairs)
-- Run the recursive query ONCE, store the result; query the result thereafter
CREATE TABLE org_closure AS
WITH RECURSIVE org AS ( ... )
SELECT * FROM org;   -- one-time cost
-- Query "all employees under manager M":
SELECT descendant_emp_id FROM org_closure WHERE ancestor_emp_id = :manager_id;
-- O(1) lookup + O(output) vs O(N × depth) recursive scan

-- FIX 2: Materialise hierarchy with path string (no recursion at query time)
CREATE TABLE employees_with_path (
    emp_id   BIGINT,
    path     VARCHAR(1000),  -- '1/5/23/99' — full ancestor path as string
    depth    INT
);
-- Query "all descendants of emp_id 5":
SELECT * FROM employees_with_path WHERE path LIKE '1/5/%';
-- Uses LIKE with prefix — efficient with a B-tree index on path
-- No recursion at query time; path maintained at write time

-- FIX 3: Spark — use GraphX or GraphFrames for graph traversal at scale
-- Recursive CTE in Spark = multiple iterative DataFrame operations
-- GraphFrames BFS (breadth-first search): optimised for graph traversal
// Scala (Spark):
val paths = graph.bfs.fromExpr("id = 'CEO'").maxPathLength(10).run()
// More efficient than 10 recursive SQL passes
```

#### System-Level Fix

```sql
-- All engines: pre-compute and materialise the closure table
-- The closure table pattern eliminates recursion at query time:

CREATE TABLE org_closure (
    ancestor_id   BIGINT,    -- ancestor employee
    descendant_id BIGINT,    -- descendant employee
    depth         SMALLINT   -- levels between ancestor and descendant
)
-- Redshift: DISTSTYLE KEY DISTKEY(ancestor_id)
--           SORTKEY(ancestor_id, depth)
-- BigQuery: CLUSTER BY ancestor_id
-- Delta Lake: ZORDER BY (ancestor_id)

-- Populate: run the recursive CTE ONCE after any org change
-- Update: on INSERT/UPDATE/DELETE to employees, recompute affected subtrees only
-- (not full recompute — just the changed subtree using iterative updates)

-- For BI queries: "headcount under CTO" = SELECT COUNT(*) FROM org_closure WHERE ancestor_id = :cto_id
-- For hierarchy export: SELECT * FROM org_closure WHERE ancestor_id = :root AND depth <= 3
-- All sub-O(1) to O(output_size) — no recursion at query time
```

```sql

---

---

