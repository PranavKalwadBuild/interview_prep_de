<!-- sql-patterns: Subqueries, CTEs, Aggregate Functions, and CASE WHEN -->

# F. Subqueries & CTEs

**Subquery** — a query nested inside another query.

```sql
-- Scalar subquery (returns a single value)
SELECT full_name, salary,
    salary - (SELECT AVG(salary) FROM employees) AS diff_from_avg
FROM employees;

-- Subquery in WHERE
SELECT * FROM employees
WHERE dept_id IN (
    SELECT dept_id FROM departments WHERE location = 'New York'
);

-- Correlated subquery — references outer query; re-executes for each outer row
SELECT e.full_name, e.salary
FROM employees e
WHERE e.salary > (
    SELECT AVG(e2.salary)
    FROM employees e2
    WHERE e2.dept_id = e.dept_id   -- references outer row's dept_id
);
```

**CTE (Common Table Expression)** — a named temporary result set defined with `WITH`.

```sql
-- Single CTE
WITH high_earners AS (
    SELECT emp_id, full_name, salary
    FROM employees
    WHERE salary > 100000
)
SELECT h.full_name, d.dept_name
FROM high_earners h
JOIN departments d USING (dept_id);

-- Multiple CTEs (chain with commas)
WITH
dept_avg AS (
    SELECT dept_id, AVG(salary) AS avg_salary
    FROM employees
    GROUP BY dept_id
),
above_avg AS (
    SELECT e.emp_id, e.full_name, e.salary, d.avg_salary
    FROM employees e
    JOIN dept_avg d USING (dept_id)
    WHERE e.salary > d.avg_salary
)
SELECT * FROM above_avg ORDER BY salary DESC;

-- Recursive CTE — for hierarchies / trees
WITH RECURSIVE org AS (
    SELECT emp_id, full_name, manager_id, 0 AS depth
    FROM employees
    WHERE manager_id IS NULL        -- root node (CEO)

    UNION ALL

    SELECT e.emp_id, e.full_name, e.manager_id, o.depth + 1
    FROM employees e
    JOIN org o ON e.manager_id = o.emp_id
)
SELECT * FROM org ORDER BY depth;
```

> **CTE vs Subquery:** CTEs are more readable for multi-step logic and can be referenced multiple times. Subqueries are fine for simple one-off filters.

---

# G. Aggregate Functions

Aggregate functions collapse multiple rows into a single value. Always used with `GROUP BY` (unless aggregating the entire table).

```sql
SELECT
    dept_id,
    COUNT(*)              AS total_employees,    -- counts all rows
    COUNT(salary)         AS employees_with_pay, -- excludes NULLs
    COUNT(DISTINCT title) AS unique_titles,
    SUM(salary)           AS total_payroll,
    AVG(salary)           AS avg_salary,
    MIN(salary)           AS min_salary,
    MAX(salary)           AS max_salary,
    MAX(hired_at)         AS most_recent_hire
FROM employees
GROUP BY dept_id
HAVING COUNT(*) > 5          -- filter AFTER grouping
ORDER BY total_payroll DESC;
```

| Function | What it does | NULL behaviour |
|---|---|---|
| `COUNT(*)` | Counts all rows | Includes NULLs |
| `COUNT(col)` | Counts non-NULL values | Excludes NULLs |
| `COUNT(DISTINCT col)` | Counts unique non-NULL values | Excludes NULLs |
| `SUM(col)` | Sum of non-NULL values | Ignores NULLs |
| `AVG(col)` | Mean of non-NULL values | Ignores NULLs (denominator = non-NULL count) |
| `MIN(col)` | Smallest value | Ignores NULLs |
| `MAX(col)` | Largest value | Ignores NULLs |

> **Gotcha:** `AVG` ignores NULLs in its denominator — `AVG(col)` ≠ `SUM(col) / COUNT(*)` if there are NULLs. Use `SUM(col) / NULLIF(COUNT(*), 0)` when you want the total-row average.
> 
> **Why it happens:** AVG computes the sum of non-NULL values divided by the count of non-NULL values, not the total number of rows. NULLs are excluded from both numerator and denominator.
> 
> **Example:** With values (10, NULL, 30), AVG = (10+30)/2 = 20, whereas SUM/COUNT(*) = 40/3 ≈ 13.33 (average across all rows, treating NULL as 0).
> 
> **Fix:** Use `SUM(col) / NULLIF(COUNT(*), 0)` to get the average across all rows (NULL treated as 0). Alternatively, use `AVG(COALESCE(col, 0))` if you want to treat NULL as zero.

---

# H. CASE WHEN

`CASE WHEN` is SQL's if-else. It can appear in `SELECT`, `WHERE`, `GROUP BY`, `ORDER BY`, and inside aggregate functions.

```sql
-- Simple classification
SELECT
    full_name,
    salary,
    CASE
        WHEN salary >= 120000 THEN 'Senior'
        WHEN salary >= 80000  THEN 'Mid'
        ELSE 'Junior'
    END AS pay_band
FROM employees;

-- Conditional aggregation — pivot-style counts in one pass
SELECT
    dept_id,
    COUNT(*)                                            AS total,
    COUNT(CASE WHEN is_active = TRUE THEN 1 END)        AS active,
    COUNT(CASE WHEN is_active = FALSE THEN 1 END)       AS inactive,
    SUM(CASE WHEN salary > 100000 THEN 1 ELSE 0 END)    AS high_earners
FROM employees
GROUP BY dept_id;

-- CASE inside ORDER BY (custom sort order)
SELECT full_name, dept_id
FROM employees
ORDER BY
    CASE dept_id
        WHEN 10 THEN 1
        WHEN 20 THEN 2
        ELSE 3
    END;
---


