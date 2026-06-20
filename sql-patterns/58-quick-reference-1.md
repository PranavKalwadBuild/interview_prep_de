<!-- Part of sql-patterns: Quick Reference — Interview Questions Q1–Q9 (Pivot, Nth Salary, Duplicates, Manager Comparison) -->
<!-- Source: sql_patterns.md lines 15206–15500 -->

# Part 4 — Quick Reference

---

## Quick Reference — Most Commonly Asked Interview Questions

This section covers the SQL questions that come up most frequently in data engineering and data analyst interviews — from classic puzzles to business-driven scenarios.

---

### Q1. Pivot a Table (Rows to Columns)

**The question:** "Summarise total sales per product for each month, showing months as columns."

This is the most iconic SQL interview question. Two approaches:

```sql
-- Universal approach: CASE WHEN + conditional aggregation
SELECT
    product_name,
    SUM(CASE WHEN EXTRACT(MONTH FROM sale_date) = 1  THEN amount ELSE 0 END) AS Jan,
    SUM(CASE WHEN EXTRACT(MONTH FROM sale_date) = 2  THEN amount ELSE 0 END) AS Feb,
    SUM(CASE WHEN EXTRACT(MONTH FROM sale_date) = 3  THEN amount ELSE 0 END) AS Mar,
    SUM(CASE WHEN EXTRACT(MONTH FROM sale_date) = 4  THEN amount ELSE 0 END) AS Apr,
    SUM(CASE WHEN EXTRACT(MONTH FROM sale_date) = 5  THEN amount ELSE 0 END) AS May,
    SUM(CASE WHEN EXTRACT(MONTH FROM sale_date) = 6  THEN amount ELSE 0 END) AS Jun
FROM sales
GROUP BY product_name
ORDER BY product_name;
```sql


```sql
-- Unpivot: columns back to rows (reverse of pivot)
-- Universal approach: UNION ALL
SELECT product_name, 'Jan' AS month, jan_sales AS amount FROM pivoted_sales
UNION ALL
SELECT product_name, 'Feb',          feb_sales          FROM pivoted_sales
UNION ALL
SELECT product_name, 'Mar',          mar_sales          FROM pivoted_sales;
```


---

### Q2. Nth Highest Salary

**The question:** "Find the 3rd highest salary from the employees table."

```sql
-- Method 1: DENSE_RANK (best — handles ties correctly)
SELECT salary
FROM (
    SELECT salary,
           DENSE_RANK() OVER (ORDER BY salary DESC) AS rnk
    FROM employees
) ranked
WHERE rnk = 3;

-- Method 2: subquery (classic, no window functions)
SELECT MAX(salary) AS third_highest
FROM employees
WHERE salary < (
    SELECT MAX(salary) FROM employees
    WHERE salary < (SELECT MAX(salary) FROM employees)
);

-- Method 3: generalised Nth using LIMIT/OFFSET (PostgreSQL / MySQL)
-- N = 3: OFFSET = N-1 = 2
SELECT DISTINCT salary
FROM employees
ORDER BY salary DESC
LIMIT 1 OFFSET 2;
```

> **Follow-up:** Interviewers often ask you to generalise to "Nth" — use `DENSE_RANK() = N` for that. Also note `RANK()` skips numbers after ties; `DENSE_RANK()` does not.

---

### Q3. Find Duplicate Records

**The question:** "Find all employees where the (name, department) combination appears more than once."

```sql
-- Find duplicates
SELECT full_name, dept_id, COUNT(*) AS occurrences
FROM employees
GROUP BY full_name, dept_id
HAVING COUNT(*) > 1;

-- Return the full rows for each duplicate
SELECT e.*
FROM employees e
JOIN (
    SELECT full_name, dept_id
    FROM employees
    GROUP BY full_name, dept_id
    HAVING COUNT(*) > 1
) dups USING (full_name, dept_id);
---

### Q4. Delete Duplicates — Keep One

**The question:** "Remove duplicate rows from the employees table, keeping only the row with the lowest emp_id."


> **Gotcha:** Some engines (MySQL, older versions) don't allow deleting directly from a CTE. Wrap the CTE output in a subquery for the `IN` clause.
> 
> **Why it happens:** Certain SQL dialects (e.g., MySQL < 8.0, older versions) treat CTEs as read-only for modification statements, preventing DELETE/UPDATE on them.
> 
> **Example:** `WITH cte AS (SELECT id FROM temp) DELETE FROM cte WHERE id = 1;` fails in MySQL 5.7.
> 
> **Fix:** Use a subquery: `DELETE FROM temp WHERE id IN (SELECT id FROM (SELECT id FROM temp) AS cte);` or store the CTE result in a temporary table.

---

### Q5. Employees Earning More Than Their Manager

**The question:** "Write a query to find all employees whose salary is greater than their direct manager's salary."

```sql
SELECT
    e.emp_id,
    e.full_name        AS employee,
    e.salary           AS employee_salary,
    m.full_name        AS manager,
    m.salary           AS manager_salary
FROM employees e
JOIN employees m ON e.manager_id = m.emp_id
WHERE e.salary > m.salary;
```

> This is a classic **self join** — joining the employees table to itself to compare a row to its related row.

---

### Q6. Users Who Never Did Something (Anti-Join)

**The question:** "Find all customers who have never placed an order."

Three equivalent approaches — know all three:

```sql
-- Method 1: LEFT JOIN + IS NULL (most readable)
SELECT c.customer_id, c.name
FROM customers c
LEFT JOIN orders o ON c.customer_id = o.customer_id
WHERE o.customer_id IS NULL;

-- Method 2: NOT EXISTS (best performance on large tables)
SELECT customer_id, name
FROM customers c
WHERE NOT EXISTS (
    SELECT 1 FROM orders o WHERE o.customer_id = c.customer_id
);

-- Method 3: NOT IN (watch out — fails silently if subquery returns any NULL)
SELECT customer_id, name
FROM customers
WHERE customer_id NOT IN (
    SELECT customer_id FROM orders WHERE customer_id IS NOT NULL  -- NULL guard required
);
```

> **Gotcha:** `NOT IN` with a subquery that can return NULL values will return zero rows. Always use `NOT EXISTS` or `LEFT JOIN IS NULL` for anti-joins.
> 
> **Why it happens:** NOT IN (list) evaluates to UNKNOWN if any element in the list is NULL, making the overall predicate UNKNOWN (treated as false) for all rows.
> 
> **Example:** `SELECT * FROM users WHERE id NOT IN (SELECT manager_id FROM depts WHERE manager_id IS NULL);` returns no rows even if some ids are not in the list, because the subquery returns a NULL.
> 
> **Fix:** Use NOT EXISTS: `SELECT * FROM users u WHERE NOT EXISTS (SELECT 1 FROM depts d WHERE d.manager_id = u.id);` or use LEFT JOIN … IS NULL: `SELECT * FROM users u LEFT JOIN depts d ON u.id = d.manager_id WHERE d.manager_id IS NULL;`

---

### Q7. Consecutive Login Streaks

**The question:** "Find the longest streak of consecutive days each user logged in."

```sql
WITH daily_logins AS (
    -- Deduplicate to one row per user per day
    SELECT DISTINCT user_id, DATE(login_at) AS login_date
    FROM login_events
),
grouped AS (
    -- Subtract a row number from the date; same streak = same group_date
    SELECT
        user_id,
        login_date,
        login_date - CAST(ROW_NUMBER() OVER (
            PARTITION BY user_id ORDER BY login_date
        ) AS INT) AS streak_group
    FROM daily_logins
),
streaks AS (
    SELECT
        user_id,
        MIN(login_date)  AS streak_start,
        MAX(login_date)  AS streak_end,
        COUNT(*)         AS streak_length
    FROM grouped
    GROUP BY user_id, streak_group
)
SELECT user_id, streak_start, streak_end, streak_length
FROM streaks
ORDER BY streak_length DESC;
```

> **The trick:** Subtracting a sequential row number from a date produces the same constant for consecutive dates. This is the "date minus row number" grouping trick.

---

### Q8. Running Total / Cumulative Sum

**The question:** "Show each transaction alongside the running total of revenue."

```sql
SELECT
    transaction_id,
    customer_id,
    transaction_date,
    amount,
    SUM(amount) OVER (
        ORDER BY transaction_date, transaction_id
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ) AS running_total
FROM transactions
ORDER BY transaction_date, transaction_id;

-- Per-customer running total (reset for each customer)
SELECT
    transaction_id,
    customer_id,
    transaction_date,
    amount,
    SUM(amount) OVER (
        PARTITION BY customer_id
        ORDER BY transaction_date
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ) AS customer_running_total
FROM transactions;
---

### Q9. Month-over-Month Growth Rate

**The question:** "Calculate the month-over-month revenue growth percentage."

```sql
WITH monthly_revenue AS (
    SELECT
        DATE_TRUNC('month', order_date) AS month,
        SUM(amount)                     AS revenue
    FROM orders
    GROUP BY 1
)
SELECT
    month,
    revenue,
    LAG(revenue) OVER (ORDER BY month)                           AS prev_month_revenue,
    ROUND(
        (revenue - LAG(revenue) OVER (ORDER BY month))
        / NULLIF(LAG(revenue) OVER (ORDER BY month), 0) * 100,
    2)                                                           AS mom_growth_pct
FROM monthly_revenue
ORDER BY month;
---

### Q10. Top N per Group

**The question:** "Find the top 3 best-selling products per category."

```sql
WITH ranked AS (

