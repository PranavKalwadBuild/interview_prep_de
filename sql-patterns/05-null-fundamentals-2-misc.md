<!-- Part of sql-patterns: NULL Handling Fundamentals Part 2 — NULLIF, IS DISTINCT FROM, ORDER BY, GROUP BY, Engine Differences + String Functions, Constraints, Set Operations -->
<!-- Source: sql_patterns.md lines 915–1187 -->

Standard SQL null-safe equality. Treats NULL as a comparable value: NULL IS DISTINCT FROM NULL → FALSE (they are the same "unknown").


---

#### I-8. NULLS FIRST / NULLS LAST in ORDER BY

When sorting a column that contains NULLs, engines disagree on where NULLs appear:

| Engine | ASC default | DESC default |
|--------|-------------|--------------|
| MySQL / MariaDB | NULLS FIRST (NULL < any value) | NULLS LAST |


---

#### I-9. NULL in GROUP BY

GROUP BY treats all NULL values as a **single group** — multiple rows with NULL in the grouping column collapse into one output row.

```sql
-- Data:
-- region | txn_amount
-- -------|----------
-- North  | 500
-- NULL   | 300
-- NULL   | 200
-- South  | 400

SELECT region, SUM(txn_amount) AS total
FROM transactions
GROUP BY region;

-- Result:
-- region | total
-- -------|------
-- North  | 500
-- NULL   | 500   ← both NULL rows grouped together
-- South  | 400

-- To exclude the NULL group:
WHERE region IS NOT NULL
-- OR in HAVING:
HAVING region IS NOT NULL

-- To explicitly label the NULL group:
SELECT COALESCE(region, 'Unknown Region') AS region, SUM(txn_amount) AS total
FROM transactions
GROUP BY region;
---

#### I-10. Engine-Specific NULL Behaviors

#### I-11. IS DISTINCT FROM (Null-Safe Comparison)

Standard SQL provides `IS DISTINCT FROM` as a null-safe equality operator. Unlike `=`, which returns UNKNOWN when comparing NULLs, `IS DISTINCT FROM` treats NULL as a known value for comparison purposes.

```sql
-- Returns TRUE if values are different, FALSE if they are the same (including both NULL)
SELECT 
    col1 IS DISTINCT FROM col2 AS are_different
FROM table_name;

-- Truth table for IS DISTINCT FROM:
-- col1     | col2     | col1 IS DISTINCT FROM col2
-- -------- | -------- | --------------------------
-- NULL     | NULL     | FALSE      (same "unknown")
-- NULL     | 'value'  | TRUE       (different)
-- 'value'  | NULL     | TRUE       (different)
-- 'value1' | 'value2' | TRUE       (different values)
-- 'value'  | 'value'  | FALSE      (same value)

-- Practical use case: detecting changes in slowly changing dimensions
SELECT 
    customer_id,
    CASE 
        WHEN current_address IS DISTINCT FROM previous_address 
        THEN 'Address Changed'
        ELSE 'Address Unchanged'
    END AS address_status
FROM customer_history;

-- Alternative to complex NULL-handling in WHERE clauses
-- Instead of: WHERE (col1 = col2 OR (col1 IS NULL AND col2 IS NULL))
-- Use:      WHERE NOT (col1 IS DISTINCT FROM col2)
```

> **Why use IS DISTINCT FROM?** It simplifies null-safe comparisons that would otherwise require verbose `IS NULL` checks. Particularly useful in change detection, ETL processes, and when implementing upsert logic where you need to detect actual data changes ignoring NULL equivalency.

> **Engine Support:** Widely supported in PostgreSQL, MySQL 8.0+, SQL Server, Oracle, and SQLite. For older MySQL versions, use `NOT (col1 <=> col2)` where `<=>` is the null-safe equality operator.


> **Gotcha summary:** The #1 NULL mistake is `WHERE col = NULL`. Always use `WHERE col IS NULL`. The #2 mistake is `NOT IN` with a subquery that can return NULLs — use `NOT EXISTS` instead.

---

### J. String Functions


---

### K. Constraints & Indexes

**Constraints** enforce data rules at the database level.

```sql
CREATE TABLE orders (
    order_id    SERIAL          PRIMARY KEY,           -- unique, not null, auto-increment
    customer_id INT             NOT NULL,              -- required field
    email       VARCHAR(255)    UNIQUE,                -- no duplicates
    status      VARCHAR(20)     DEFAULT 'pending',     -- default value
    amount      DECIMAL(12,2)   CHECK (amount > 0),    -- value validation
    created_at  TIMESTAMP       NOT NULL DEFAULT NOW(),
    FOREIGN KEY (customer_id) REFERENCES customers(customer_id)  -- referential integrity
);
```

| Constraint | Purpose |
|---|---|
| `PRIMARY KEY` | Uniquely identifies each row; implies NOT NULL + UNIQUE |
| `FOREIGN KEY` | Links to a primary key in another table; enforces referential integrity |
| `NOT NULL` | Prevents NULL values in that column |
| `UNIQUE` | No two rows can have the same value in this column |
| `CHECK` | Enforces a boolean condition on the column value |
| `DEFAULT` | Provides a fallback value when none is supplied on INSERT |

**Indexes** speed up reads at the cost of slightly slower writes.

```sql
-- Single-column index
CREATE INDEX idx_emp_dept ON employees(dept_id);

-- Composite index (column order matters — most selective column first)
CREATE INDEX idx_emp_dept_salary ON employees(dept_id, salary);

-- Unique index (doubles as a uniqueness constraint)
CREATE UNIQUE INDEX idx_emp_email ON employees(email);

-- Drop index
DROP INDEX idx_emp_dept;
```

> **Index tips:** Index columns used in `WHERE`, `JOIN ON`, and `ORDER BY`. Avoid indexing low-cardinality columns (e.g., boolean flags). Indexes slow down `INSERT/UPDATE/DELETE` because they must be maintained.

---

### L. Set Operations

Set operations combine the results of two queries. Both queries must return the same number of columns with compatible data types.


| Operation | Duplicates | What it returns |
|---|---|---|
| `UNION` | Removed | All rows from both sets, deduplicated |
| `UNION ALL` | Kept | All rows from both sets, including duplicates |
| `INTERSECT` | Removed | Only rows common to both sets |
| `EXCEPT` / `MINUS` | Removed | Rows in first set that don't appear in second |

---


