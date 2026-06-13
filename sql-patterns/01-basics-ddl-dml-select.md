<!-- Part of sql-patterns: SQL Basics — Data Types, DDL, DML, SELECT Fundamentals -->
<!-- Source: sql_patterns.md lines 79–252 -->

# Part 1 — Foundations

---

## How to Use This Guide

Every section follows this structure:

1. **Pattern name + what it solves**
2. **Keywords to spot in the question** — trigger phrases that tell you which pattern to apply
3. **Business context** — real-world scenarios where this appears
4. **Boilerplate SQL** — fill-in-the-blank template you can adapt
5. **Gotchas** — things that trip people up

---

## SQL Basics

A quick reference for the foundational building blocks of SQL — the stuff that comes before window functions and advanced patterns.

---

### A. Data Types

| Category | Common Types | Notes |
|---|---|---|
| Integer | `INT`, `BIGINT`, `SMALLINT` | Use `BIGINT` for IDs that might exceed 2B |
| Decimal | `DECIMAL(p,s)`, `NUMERIC(p,s)`, `FLOAT`, `DOUBLE` | `DECIMAL` is exact; `FLOAT` is approximate — never use float for money |
| String | `VARCHAR(n)`, `TEXT`, `CHAR(n)` | `CHAR` is fixed-width; `VARCHAR` is variable |
| Date/Time | `DATE`, `TIME`, `TIMESTAMP`, `TIMESTAMPTZ` | Always store in UTC; convert at display layer |
| Boolean | `BOOLEAN` / `BOOL` | Some engines use `TINYINT(1)` (MySQL) |
| JSON | `JSON`, `JSONB` (PostgreSQL) | `JSONB` is binary-indexed, faster to query |
| Array | `ARRAY` (PostgreSQL, BigQuery, Snowflake) | `ARRAY<STRING>` in BigQuery |
| NULL | Not a type — a marker for unknown/missing | `NULL ≠ ''` and `NULL ≠ 0` |

---

### B. DDL — Create, Alter, Drop

**DDL (Data Definition Language)** defines the structure of the database. Changes are auto-committed in most engines.

```sql
-- Create a table
CREATE TABLE employees (
    emp_id      INT           PRIMARY KEY,
    name        VARCHAR(100)  NOT NULL,
    dept_id     INT           REFERENCES departments(dept_id),
    salary      DECIMAL(12,2) DEFAULT 0,
    hired_at    DATE          NOT NULL,
    is_active   BOOLEAN       DEFAULT TRUE
);

-- Add a column
ALTER TABLE employees ADD COLUMN email VARCHAR(255);

-- Rename a column (PostgreSQL / Snowflake)
ALTER TABLE employees RENAME COLUMN name TO full_name;

-- Change a column type
ALTER TABLE employees ALTER COLUMN salary TYPE BIGINT;  -- PostgreSQL
ALTER TABLE employees MODIFY COLUMN salary BIGINT;      -- MySQL

-- Drop a column
ALTER TABLE employees DROP COLUMN email;

-- Drop a table (irreversible — removes structure AND data)
DROP TABLE employees;

-- Truncate — removes all rows but keeps the structure; much faster than DELETE
TRUNCATE TABLE employees;

-- Create a table from a SELECT (CTAS)
CREATE TABLE high_earners AS
SELECT * FROM employees WHERE salary > 100000;

-- Create a view
CREATE OR REPLACE VIEW active_employees AS
SELECT emp_id, full_name, dept_id FROM employees WHERE is_active = TRUE;
```

**Key DDL commands:**

| Command | What it does |
|---|---|
| `CREATE TABLE` | Defines a new table with columns and constraints |
| `ALTER TABLE` | Modifies columns, constraints, or table properties |
| `DROP TABLE` | Permanently deletes the table and all its data |
| `TRUNCATE TABLE` | Removes all rows but keeps the table structure |
| `CREATE VIEW` | Saves a SELECT query as a named virtual table |
| `CREATE INDEX` | Adds an index to speed up lookups on a column |

---

### C. DML — Insert, Update, Delete

**DML (Data Manipulation Language)** modifies the data inside tables.

```sql
-- INSERT — single row
INSERT INTO employees (emp_id, full_name, dept_id, salary, hired_at)
VALUES (1, 'Alice Smith', 10, 95000.00, '2022-03-15');

-- INSERT — multiple rows
INSERT INTO employees (emp_id, full_name, dept_id, salary, hired_at)
VALUES
    (2, 'Bob Jones',   20, 82000.00, '2021-07-01'),
    (3, 'Carol White', 10, 110000.00,'2020-01-10');

-- INSERT from SELECT (copy rows between tables)
INSERT INTO archived_employees
SELECT * FROM employees WHERE hired_at < '2015-01-01';

-- UPDATE — always pair with WHERE unless you want to update every row
UPDATE employees
SET salary = salary * 1.10
WHERE dept_id = 10 AND is_active = TRUE;

-- DELETE — filters rows to remove
DELETE FROM employees
WHERE is_active = FALSE AND hired_at < '2018-01-01';

-- UPSERT (insert or update if key exists)
-- PostgreSQL
INSERT INTO employees (emp_id, full_name, salary)
VALUES (1, 'Alice Smith', 100000)
ON CONFLICT (emp_id) DO UPDATE SET salary = EXCLUDED.salary;

-- MySQL
INSERT INTO employees (emp_id, full_name, salary)
VALUES (1, 'Alice Smith', 100000)
ON DUPLICATE KEY UPDATE salary = VALUES(salary);
```

> **Gotcha:** `DELETE` without `WHERE` wipes the entire table — same result as `TRUNCATE` but slower and logged row-by-row. Always double-check your `WHERE` clause first.

---

### D. SELECT Fundamentals

```sql
-- Basic SELECT structure
SELECT
    column1,
    column2,
    column1 + column2        AS derived_col,   -- expression
    UPPER(column3)           AS uppercased      -- function
FROM my_table
WHERE condition
GROUP BY grouping_columns
HAVING aggregate_condition
ORDER BY sort_column DESC
LIMIT 100;

-- SELECT DISTINCT — returns unique rows
SELECT DISTINCT dept_id FROM employees;

-- Filtering with WHERE
SELECT * FROM employees
WHERE salary > 80000
  AND dept_id IN (10, 20)
  AND hired_at BETWEEN '2020-01-01' AND '2022-12-31'
  AND full_name LIKE 'A%';      -- names starting with A

-- ORDER BY multiple columns
SELECT emp_id, dept_id, salary
FROM employees
ORDER BY dept_id ASC, salary DESC;

-- LIMIT / OFFSET for pagination
SELECT * FROM employees ORDER BY emp_id LIMIT 10 OFFSET 20;  -- rows 21–30
```sql

---

