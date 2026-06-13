<!-- Part of sql-patterns: NULL Handling Fundamentals Part 2 — NULLIF, IS DISTINCT FROM, ORDER BY, GROUP BY, Engine Differences + String Functions, Constraints, Set Operations -->
<!-- Source: sql_patterns.md lines 915–1187 -->

Standard SQL null-safe equality. Treats NULL as a comparable value: NULL IS DISTINCT FROM NULL → FALSE (they are the same "unknown").

```sql
-- Standard = fails for NULLs:
NULL = NULL       → UNKNOWN (not TRUE)
NULL = 'ACTIVE'   → UNKNOWN (not FALSE)

-- IS DISTINCT FROM is NULL-safe:
NULL IS DISTINCT FROM NULL       → FALSE  (they are "same")
NULL IS DISTINCT FROM 'ACTIVE'   → TRUE   (they are "different")
'ACTIVE' IS DISTINCT FROM NULL   → TRUE
'ACTIVE' IS DISTINCT FROM 'ACTIVE' → FALSE

-- Use case 1: filter rows where a value actually changed (SCD2 / CDC):
WHERE old_credit_tier IS DISTINCT FROM new_credit_tier
-- Works even when old or new tier is NULL (new account or closed account)

-- Use case 2: include NULL in NOT EQUAL filter:
WHERE status IS DISTINCT FROM 'FAILED'
-- Returns rows where status is NULL (PENDING) AND rows where status != 'FAILED'

-- Use case 3: reconciliation — find rows that differ between two tables:
SELECT COALESCE(a.id, b.id) AS id
FROM table_a a
FULL OUTER JOIN table_b b ON a.id = b.id
WHERE a.amount IS DISTINCT FROM b.amount;
-- Catches: amount differs, one amount is NULL, both are NULL but that's a special case

-- Engine support: PostgreSQL, BigQuery, DuckDB, Snowflake (use IS DISTINCT FROM)
-- MySQL equivalent: NOT (a <=> b)  where <=> is MySQL's NULL-safe equality operator
-- SQL Server equivalent: NOT EXISTS + complex IS NULL logic (no shorthand)
```sql

---

#### I-8. NULLS FIRST / NULLS LAST in ORDER BY

When sorting a column that contains NULLs, engines disagree on where NULLs appear:

| Engine | ASC default | DESC default |
|--------|-------------|--------------|
| PostgreSQL / Snowflake / Oracle / BigQuery / DuckDB | NULLS LAST | NULLS FIRST |
| MySQL / MariaDB | NULLS FIRST (NULL < any value) | NULLS LAST |
| SQL Server | NULLS FIRST | NULLS LAST |
| Spark SQL | NULLS LAST | NULLS FIRST |

```sql
-- Explicit NULL position control (PostgreSQL, Oracle, Snowflake, BigQuery, DuckDB):
ORDER BY repayment_date ASC  NULLS LAST;   -- paid loans first, outstanding (NULL) last
ORDER BY repayment_date ASC  NULLS FIRST;  -- outstanding (NULL) loans first
ORDER BY repayment_date DESC NULLS LAST;   -- most recently paid first, NULL last

-- MySQL / SQL Server workaround (no NULLS FIRST/LAST syntax):
-- Put NULLs at the bottom:
ORDER BY CASE WHEN repayment_date IS NULL THEN 1 ELSE 0 END ASC, repayment_date ASC;
-- Put NULLs at the top:
ORDER BY CASE WHEN repayment_date IS NULL THEN 0 ELSE 1 END ASC, repayment_date ASC;

-- Real scenario: outstanding loan report — show NULLs first
SELECT loan_id, borrower_id, due_date, repayment_date
FROM loan_repayments
ORDER BY repayment_date ASC NULLS FIRST;
```sql

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
```sql

---

#### I-10. Engine-Specific NULL Behaviors

```sql
-- CONCAT with NULL (varies by engine):
-- PostgreSQL / BigQuery: CONCAT('UPI', NULL) → NULL
-- MySQL 5.x / Spark: CONCAT('UPI', NULL) → 'UPI'  (ignores NULL!)
-- Safe alternative: CONCAT_WS (concat with separator, always skips NULLs):
SELECT CONCAT_WS('-', merchant_id, txn_id, status) AS txn_key
FROM transactions;  -- if status IS NULL → 'M123-T456' (no trailing dash)

-- NULL in IN list:
NULL IN (1, 2, 3)        -- UNKNOWN (not FALSE, not TRUE)
-- So WHERE id IN (1, NULL, 3) does NOT match rows where id = 2 or id IS NULL
-- It only matches id = 1 and id = 3

-- NOT IN with NULL in subquery (THE most dangerous SQL trap):
WHERE id NOT IN (SELECT parent_id FROM categories)
-- If ANY parent_id is NULL → NOT IN returns UNKNOWN for EVERY row → zero results

-- TRY_CAST / SAFE_CAST for NULL-safe type conversion:
TRY_CAST('not-a-date' AS DATE)     -- Snowflake/SQL Server → NULL (not an error)
SAFE_CAST('not-a-date' AS DATE64)  -- BigQuery → NULL
TRY_TO_DATE('not-a-date')          -- Snowflake → NULL

-- NULL in string comparison:
WHERE LOWER(name) LIKE '%smith%'    -- rows with NULL name are EXCLUDED silently
-- Fix:
WHERE LOWER(COALESCE(name, '')) LIKE '%smith%'  -- treat NULL as empty string

-- NULL in BETWEEN:
WHERE amount BETWEEN 100 AND NULL   -- UNKNOWN → no rows (even if amount = 150)
WHERE NULL BETWEEN 100 AND 500      -- UNKNOWN → no rows
```

> **Gotcha summary:** The #1 NULL mistake is `WHERE col = NULL`. Always use `WHERE col IS NULL`. The #2 mistake is `NOT IN` with a subquery that can return NULLs — use `NOT EXISTS` instead.

---

### J. String Functions

```sql
-- Length
LENGTH('hello')            -- 5 (PostgreSQL / MySQL / Spark)
LEN('hello')               -- 5 (SQL Server / Snowflake)

-- Case conversion
UPPER('hello')             -- 'HELLO'
LOWER('HELLO')             -- 'hello'

-- Trim whitespace
TRIM('  hello  ')          -- 'hello'
LTRIM('  hello')           -- 'hello'
RTRIM('hello  ')           -- 'hello'

-- Substring
SUBSTRING('abcdef', 2, 3)  -- 'bcd'  (start pos 2, length 3)
LEFT('abcdef', 3)           -- 'abc'
RIGHT('abcdef', 3)          -- 'def'

-- Concatenation
CONCAT('hello', ' ', 'world')       -- 'hello world'
'hello' || ' ' || 'world'           -- PostgreSQL / Snowflake / SQLite

-- Replace
REPLACE('hello world', 'world', 'SQL')  -- 'hello SQL'

-- Pattern matching
name LIKE 'A%'           -- starts with A
name LIKE '%son'         -- ends with son
name LIKE '_a%'          -- second character is a
name NOT LIKE '%test%'   -- does not contain test

-- Position / index of substring
POSITION('lo' IN 'hello')      -- 4 (PostgreSQL)
CHARINDEX('lo', 'hello')       -- 4 (SQL Server / Snowflake)
INSTR('hello', 'lo')           -- 4 (MySQL / Oracle)

-- Split and extract part of a string
SPLIT_PART('a.b.c', '.', 2)    -- 'b' (PostgreSQL / Snowflake)

-- Aggregate strings within a group
STRING_AGG(full_name, ', ' ORDER BY full_name)   -- PostgreSQL / Snowflake / BigQuery
GROUP_CONCAT(full_name ORDER BY full_name SEPARATOR ', ')  -- MySQL / Spark
LISTAGG(full_name, ', ') WITHIN GROUP (ORDER BY full_name) -- Oracle / Snowflake
```sql

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

```sql
-- UNION — combines results, removes duplicates
SELECT emp_id, full_name FROM employees_us
UNION
SELECT emp_id, full_name FROM employees_uk;

-- UNION ALL — combines results, keeps duplicates (faster — no deduplication)
SELECT emp_id, full_name FROM employees_us
UNION ALL
SELECT emp_id, full_name FROM employees_uk;

-- INTERSECT — rows that appear in BOTH result sets
SELECT customer_id FROM orders_2024
INTERSECT
SELECT customer_id FROM orders_2025;
-- → customers who ordered in both years

-- EXCEPT (MINUS in Oracle) — rows in first set but not in second
SELECT customer_id FROM customers
EXCEPT
SELECT customer_id FROM orders;
-- → customers who have never placed an order
```

| Operation | Duplicates | What it returns |
|---|---|---|
| `UNION` | Removed | All rows from both sets, deduplicated |
| `UNION ALL` | Kept | All rows from both sets, including duplicates |
| `INTERSECT` | Removed | Only rows common to both sets |
| `EXCEPT` / `MINUS` | Removed | Rows in first set that don't appear in second |

---

