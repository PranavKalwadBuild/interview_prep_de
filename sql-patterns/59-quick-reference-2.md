<!-- Part of sql-patterns: Quick Reference — Interview Questions Q10–Q20 (Top-N, Ranking, Gaps, Retention) -->
<!-- Source: sql_patterns.md lines 15501–15750 -->

    SELECT
        category,
        product_name,
        SUM(quantity_sold)                                    AS total_sold,
        DENSE_RANK() OVER (
            PARTITION BY category
            ORDER BY SUM(quantity_sold) DESC
        )                                                     AS rnk
    FROM sales
    GROUP BY category, product_name
)
SELECT category, product_name, total_sold, rnk
FROM ranked
WHERE rnk <= 3
ORDER BY category, rnk;
```

> Use `DENSE_RANK` if ties should share a rank. Use `ROW_NUMBER` if you want exactly N rows with no ties.

---

### Q11. RANK vs DENSE_RANK vs ROW_NUMBER

**The question:** "What's the difference between RANK, DENSE_RANK, and ROW_NUMBER?"

```sql
-- Given scores: 100, 90, 90, 80
SELECT
    name,
    score,
    ROW_NUMBER()  OVER (ORDER BY score DESC) AS row_num,   -- 1, 2, 3, 4
    RANK()        OVER (ORDER BY score DESC) AS rnk,       -- 1, 2, 2, 4  (gap after tie)
    DENSE_RANK()  OVER (ORDER BY score DESC) AS dense_rnk  -- 1, 2, 2, 3  (no gap)
FROM leaderboard;
```

| Function | Ties get same rank? | Gaps after ties? | Unique rows? |
|---|---|---|---|
| `ROW_NUMBER()` | No — each row unique | N/A | Yes |
| `RANK()` | Yes | Yes — skips numbers | No |
| `DENSE_RANK()` | Yes | No | No |

---

### Q12. WHERE vs HAVING

**The question:** "What's the difference between WHERE and HAVING? When do you use each?"

```sql
-- WHERE filters rows BEFORE grouping (cannot reference aggregates)
-- HAVING filters groups AFTER grouping (can reference aggregates)

SELECT dept_id, AVG(salary) AS avg_salary
FROM employees
WHERE is_active = TRUE          -- filters individual rows first
GROUP BY dept_id
HAVING AVG(salary) > 80000;    -- then filters groups by aggregate result

-- Common mistake: using HAVING instead of WHERE for row-level filter
-- BAD (works but slower — filters after aggregation):
SELECT dept_id, AVG(salary) FROM employees GROUP BY dept_id HAVING is_active = TRUE;

-- GOOD (filter first, then aggregate):
SELECT dept_id, AVG(salary) FROM employees WHERE is_active = TRUE GROUP BY dept_id;
---

### Q13. Find Missing Numbers / Gaps in a Sequence

**The question:** "The orders table has an order_id column that should be sequential. Find all missing IDs."

```sql
-- Method 1: Recursive CTE to generate expected sequence
WITH RECURSIVE seq AS (
    SELECT MIN(order_id) AS id, MAX(order_id) AS max_id FROM orders
    UNION ALL
    SELECT id + 1, max_id FROM seq WHERE id < max_id
)
SELECT id AS missing_order_id
FROM seq
WHERE id NOT IN (SELECT order_id FROM orders)
ORDER BY id;

-- Method 2: generate_series (PostgreSQL)
SELECT gs.id AS missing_order_id
FROM generate_series(
    (SELECT MIN(order_id) FROM orders),
    (SELECT MAX(order_id) FROM orders)
) gs(id)
LEFT JOIN orders o ON gs.id = o.order_id
WHERE o.order_id IS NULL;

-- Method 3: self-join to find gaps > 1
SELECT
    o1.order_id       AS gap_start,
    o2.order_id - 1   AS gap_end
FROM orders o1
JOIN orders o2 ON o2.order_id = (
    SELECT MIN(order_id) FROM orders WHERE order_id > o1.order_id
)
WHERE o2.order_id - o1.order_id > 1;
---

### Q14. Second Most Recent Record per User

**The question:** "For each user, find their second most recent order."

```sql
WITH ranked AS (
    SELECT
        user_id,
        order_id,
        order_date,
        amount,
        ROW_NUMBER() OVER (
            PARTITION BY user_id
            ORDER BY order_date DESC
        ) AS rn
    FROM orders
)
SELECT user_id, order_id, order_date, amount
FROM ranked
WHERE rn = 2;
---

### Q15. Cumulative Distribution — Percentile Rank

**The question:** "Show what percentage of employees earn less than or equal to each employee."

```sql
SELECT
    full_name,
    salary,
    PERCENT_RANK() OVER (ORDER BY salary)  AS percent_rank,   -- 0.0 to 1.0
    CUME_DIST()    OVER (ORDER BY salary)  AS cume_dist        -- fraction of rows ≤ current
FROM employees
ORDER BY salary DESC;
---

### Q16. String Aggregation — Concatenate Values within a Group

**The question:** "For each department, list all employee names as a comma-separated string."

```sql
SELECT dept_id,
       STRING_AGG(full_name, ', ' ORDER BY full_name) AS employee_list
FROM employees
GROUP BY dept_id;

SELECT dept_id,
       GROUP_CONCAT(full_name ORDER BY full_name SEPARATOR ', ') AS employee_list
FROM employees
GROUP BY dept_id;
---

### Q17. Median Salary per Department

**The question:** "Find the median salary in each department."

```sql
SELECT
    dept_id,
    PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY salary) AS median_salary
FROM employees
GROUP BY dept_id;

-- Universal fallback using ROW_NUMBER
WITH ranked AS (
    SELECT
        dept_id,
        salary,
        ROW_NUMBER() OVER (PARTITION BY dept_id ORDER BY salary)        AS rn,
        COUNT(*)     OVER (PARTITION BY dept_id)                         AS total
    FROM employees
)
SELECT dept_id, AVG(salary) AS median_salary
FROM ranked
WHERE rn IN (FLOOR((total + 1) / 2.0), CEIL((total + 1) / 2.0))
GROUP BY dept_id;
---

### Q18. INNER JOIN vs LEFT JOIN — Practical Difference

**The question:** "Write a query to show all departments, including those with no employees."

```sql
-- INNER JOIN: only departments that have at least one employee
SELECT d.dept_name, COUNT(e.emp_id) AS headcount
FROM departments d
INNER JOIN employees e ON d.dept_id = e.dept_id
GROUP BY d.dept_name;

-- LEFT JOIN: all departments, even those with zero employees
SELECT d.dept_name, COUNT(e.emp_id) AS headcount   -- COUNT(e.emp_id) returns 0 for NULLs
FROM departments d
LEFT JOIN employees e ON d.dept_id = e.dept_id
GROUP BY d.dept_name
ORDER BY headcount DESC;
---

### Q19. Find the Most Recent Record per Entity

**The question:** "Get the latest order for each customer."

```sql
-- Method 1: ROW_NUMBER (most flexible — can return full row)
WITH ranked AS (
    SELECT *,
           ROW_NUMBER() OVER (
               PARTITION BY customer_id
               ORDER BY order_date DESC, order_id DESC   -- tie-break by ID
           ) AS rn
    FROM orders
)
SELECT * FROM ranked WHERE rn = 1;

-- Method 2: Self-join on MAX (simple but only returns the key)
SELECT o.*
FROM orders o
JOIN (
    SELECT customer_id, MAX(order_date) AS latest_date
    FROM orders
    GROUP BY customer_id
) latest ON o.customer_id = latest.customer_id
        AND o.order_date = latest.latest_date;
---

### Q20. Transactions Above a User's Own Average

**The question:** "Find all transactions where the amount is greater than that user's average transaction."

```sql

