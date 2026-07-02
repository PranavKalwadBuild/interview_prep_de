<!-- sql-patterns: Recursive CTEs and Hierarchies -->

# Recursive CTEs (Hierarchies)

## What it solves

Recursive CTEs traverse tree-like relationships stored in ordinary relational tables: org charts, category trees, bill of materials, ownership chains, and dependency graphs.

## Keywords to spot

> "hierarchy", "tree", "ancestors", "descendants", "all levels",
> "org chart", "category path", "all subordinates", "path from root",
> "depth", "lineage", "bill of materials", "roll up to",
> "recursive relationship", "transitive closure"

## Business Context

- **HR:** Find every employee under a manager; compute salary budget for an org subtree.
- **E-commerce:** Build category breadcrumbs and retrieve all subcategories below a node.
- **Data Engineering:** Identify downstream jobs or tables affected by changing one asset.
- **Finance:** Roll accounts up through legal-entity or cost-centre hierarchies.
- **Manufacturing:** Expand a bill of materials into all required components.

## ANSI-first boilerplate

```sql
-- employees(emp_id, emp_name, manager_id)
-- Find all reports under manager 5.

WITH RECURSIVE org_tree (emp_id, emp_name, manager_id, depth) AS (
    SELECT
        emp_id,
        emp_name,
        manager_id,
        0 AS depth
    FROM employees
    WHERE emp_id = 5

    UNION ALL

    SELECT
        e.emp_id,
        e.emp_name,
        e.manager_id,
        ot.depth + 1
    FROM employees e
    INNER JOIN org_tree ot
        ON e.manager_id = ot.emp_id
    WHERE ot.depth < 20
)
SELECT *
FROM org_tree
ORDER BY depth, emp_name;
```

## Building a readable path

ANSI SQL supports string concatenation with `||`, though implementations vary. Use `CAST` rather than PostgreSQL's `::` shorthand in portable examples.

```sql
WITH RECURSIVE org_tree (emp_id, emp_name, manager_id, path, depth) AS (
    SELECT
        emp_id,
        emp_name,
        manager_id,
        CAST(emp_name AS VARCHAR(1000)) AS path,
        0 AS depth
    FROM employees
    WHERE manager_id IS NULL

    UNION ALL

    SELECT
        e.emp_id,
        e.emp_name,
        e.manager_id,
        CAST(ot.path || ' > ' || e.emp_name AS VARCHAR(1000)) AS path,
        ot.depth + 1
    FROM employees e
    INNER JOIN org_tree ot
        ON e.manager_id = ot.emp_id
    WHERE ot.depth < 20
)
SELECT emp_id, emp_name, path, depth
FROM org_tree;
```

**MySQL path concatenation**

```sql
CONCAT(ot.path, ' > ', e.emp_name)
```

## Gotchas

- The anchor query defines the starting node set. If it is too broad, recursion multiplies quickly.
- `UNION ALL` is usually correct. `UNION` can hide duplicate paths and adds expensive duplicate elimination at every step.
- Always include a depth limit, even if the data "should never" contain cycles.
- Recursive CTEs are iterative by nature. Each level depends on the previous level, so very deep trees can be slow.
- A tree has one parent per child. If a node can have multiple parents, you are traversing a graph and must expect duplicate paths.

## Edge Cases

### Edge 17-A: Circular references cause infinite recursion

**Problem:** Bad hierarchy data can contain a cycle such as `A -> B -> C -> A`. Without a guard, recursion continues until the database stops it or the query exhausts resources.

**Portable guard using a delimited visited path**

```sql
WITH RECURSIVE org (emp_id, manager_id, visited_path, depth) AS (
    SELECT
        emp_id,
        manager_id,
        CAST('/' || CAST(emp_id AS VARCHAR(40)) || '/' AS VARCHAR(4000)) AS visited_path,
        0 AS depth
    FROM employees
    WHERE manager_id IS NULL

    UNION ALL

    SELECT
        e.emp_id,
        e.manager_id,
        CAST(o.visited_path || CAST(e.emp_id AS VARCHAR(40)) || '/' AS VARCHAR(4000)),
        o.depth + 1
    FROM employees e
    INNER JOIN org o
        ON e.manager_id = o.emp_id
    WHERE o.depth < 20
      AND POSITION('/' || CAST(e.emp_id AS VARCHAR(40)) || '/' IN o.visited_path) = 0
)
SELECT *
FROM org;
```

**PostgreSQL array-based fallback**

```sql
WITH RECURSIVE org AS (
    SELECT emp_id, manager_id, ARRAY[emp_id] AS visited, 0 AS depth
    FROM employees
    WHERE manager_id IS NULL

    UNION ALL

    SELECT e.emp_id, e.manager_id, o.visited || e.emp_id, o.depth + 1
    FROM employees e
    INNER JOIN org o
        ON e.manager_id = o.emp_id
    WHERE NOT e.emp_id = ANY(o.visited)
      AND o.depth < 20
)
SELECT *
FROM org;
```

**MySQL fallback**

```sql
WITH RECURSIVE org AS (
    SELECT
        emp_id,
        manager_id,
        CAST(CONCAT('/', emp_id, '/') AS CHAR(4000)) AS visited_path,
        0 AS depth
    FROM employees
    WHERE manager_id IS NULL

    UNION ALL

    SELECT
        e.emp_id,
        e.manager_id,
        CONCAT(o.visited_path, e.emp_id, '/'),
        o.depth + 1
    FROM employees e
    INNER JOIN org o
        ON e.manager_id = o.emp_id
    WHERE o.depth < 20
      AND INSTR(o.visited_path, CONCAT('/', e.emp_id, '/')) = 0
)
SELECT *
FROM org;
```

### Edge 17-B: Wide or deep trees degrade quickly

**Problem:** Each recursive step joins the current frontier back to the base table. A balanced tree with depth 20 still needs 20 iterations. A linked-list-shaped hierarchy with 100,000 levels is usually the wrong shape for recursive querying.

**Fix 1: materialize a closure table**

```sql
CREATE TABLE org_closure AS
WITH RECURSIVE org (ancestor_id, descendant_id, depth) AS (
    SELECT emp_id, emp_id, 0
    FROM employees

    UNION ALL

    SELECT org.ancestor_id, e.emp_id, org.depth + 1
    FROM org
    INNER JOIN employees e
        ON e.manager_id = org.descendant_id
    WHERE org.depth < 20
)
SELECT ancestor_id, descendant_id, depth
FROM org;
```

Querying becomes simple:

```sql
SELECT descendant_id
FROM org_closure
WHERE ancestor_id = 5;
```

**Fix 2: maintain a path column**

```sql
CREATE TABLE employees_with_path (
    emp_id      BIGINT,
    manager_id  BIGINT,
    path        VARCHAR(4000),
    depth       INTEGER
);

SELECT *
FROM employees_with_path
WHERE path LIKE '/1/5/%';
```

## At Scale

Recursive CTEs are excellent for small to moderate hierarchies. For frequently queried or very large hierarchies, treat recursion as an ETL step and store the result.

**Readiness checklist**

- Is the maximum depth known and enforced?
- Can the hierarchy contain cycles?
- Can one node have multiple parents?
- Do you need all descendants often enough to justify a closure table?
- Are inserts and parent changes rare enough that path maintenance is manageable?
- Are you validating row counts by level to catch explosive graph traversal early?

