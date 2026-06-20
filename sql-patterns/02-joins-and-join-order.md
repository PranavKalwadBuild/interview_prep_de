<!-- Part of sql-patterns: JOINs — Types, Join Order, and Which Table Goes Left -->
<!-- Source: sql_patterns.md lines 253–545 -->

### E. JOINs

JOINs combine rows from two or more tables based on a related column.

```sql
-- INNER JOIN — only rows that match in BOTH tables
SELECT e.emp_id, e.full_name, d.dept_name
FROM employees e
INNER JOIN departments d ON e.dept_id = d.dept_id;

-- LEFT JOIN — all rows from left table; NULL where no match on right
SELECT e.emp_id, e.full_name, d.dept_name
FROM employees e
LEFT JOIN departments d ON e.dept_id = d.dept_id;
-- employees with no department → dept_name will be NULL

-- RIGHT JOIN — all rows from right table; NULL where no match on left
-- (Less common — usually rewritten as LEFT JOIN by swapping table order)

-- FULL OUTER JOIN — all rows from both tables; NULL where no match either side
SELECT e.emp_id, d.dept_id
FROM employees e
FULL OUTER JOIN departments d ON e.dept_id = d.dept_id;

-- CROSS JOIN — cartesian product (every row × every row); use with care
SELECT a.product, b.region
FROM products a
CROSS JOIN regions b;

-- SELF JOIN — join a table to itself
SELECT
    e.full_name       AS employee,
    m.full_name       AS manager
FROM employees e
LEFT JOIN employees m ON e.manager_id = m.emp_id;
```

**JOIN cheat sheet:**

| Join Type | Returns |
|---|---|
| `INNER JOIN` | Only matching rows from both tables |
| `LEFT JOIN` | All left rows + matching right rows (NULL if no match) |
| `RIGHT JOIN` | All right rows + matching left rows (NULL if no match) |
| `FULL OUTER JOIN` | All rows from both sides (NULL where no match) |
| `CROSS JOIN` | Every combination of rows (m × n rows) |
| `SELF JOIN` | A table joined to itself |

> **Gotcha:** A `LEFT JOIN` becomes an `INNER JOIN` if you add a `WHERE` filter on a right-table column that rejects NULLs. Move the filter into the `ON` clause to keep the LEFT behaviour.
> 
> **Why it happens:** Filtering on a right-table column with WHERE removes rows where the right table is NULL (no match), turning the LEFT JOIN into an inner join.
> 
> **Example:** `SELECT * FROM customers LEFT JOIN orders ON customers.id = orders.customer_id WHERE orders.amount > 100;` returns only customers with orders over 100, losing customers with no orders.
> 
> **Fix:** Move the filter into the ON clause: `SELECT * FROM customers LEFT JOIN orders ON customers.id = orders.customer_id AND orders.amount > 100;` This keeps all customers, with NULL order amount for those without orders.

```sql
-- WRONG — turns LEFT JOIN into INNER JOIN
SELECT e.*, d.dept_name
FROM employees e
LEFT JOIN departments d ON e.dept_id = d.dept_id
WHERE d.dept_name = 'Engineering';    -- filters out NULLs → no longer LEFT JOIN

-- CORRECT — filter inside ON clause
SELECT e.*, d.dept_name
FROM employees e
LEFT JOIN departments d ON e.dept_id = d.dept_id AND d.dept_name = 'Engineering';
---

### E-1. Order of Joins — Which Table Goes on the Left?

This is one of the most overlooked concepts. "Left" and "right" in a JOIN are not cosmetic — they determine which table drives the result set and, with outer joins, which rows are guaranteed to survive.

---

#### The Core Mental Model

```
FROM  <left table>
JOIN  <right table>  ON  <condition>
```

- **LEFT JOIN** → every row from the left table is kept; the right table is optional (NULLs where no match).
- **INNER JOIN** → only rows that match in both survive. Table order doesn't change the final result, but it *does* affect the optimizer's cost estimates and the readability of your logic.

---

#### Scenario 1 — You need "all of X, enriched with Y"

**Rule: put the primary / anchor table on the LEFT.**

This is the most common analytics pattern. Start from the entity you care about and LEFT JOIN everything else in.

```sql
-- "I want every customer, even those who never ordered"
SELECT c.customer_id, c.name, o.order_id
FROM   customers c          -- anchor: must preserve all customers
LEFT JOIN orders o ON c.customer_id = o.customer_id;
```

> Putting `orders` on the left would drop customers with no orders — the opposite of the intent.

**Trigger phrases:** "all customers even if no …", "show missing records", "highlight gaps", "find who hasn't …"

---

#### Scenario 2 — INNER JOIN: readability and optimization hints

For INNER JOINs the result is the same regardless of order, but two conventions help the optimizer and future readers:

**2a. Most selective (smallest after filters) table first**

```sql
-- Suppose refunds is tiny (1K rows), transactions is huge (500M rows)
-- Hint to optimizer: start from the small side
SELECT t.txn_id, t.amount, r.refund_amount
FROM   refunds r               -- small, highly selective
INNER JOIN transactions t ON r.txn_id = t.txn_id;
```

This matters most when statistics are stale or you're adding an optimizer hint.

**2b. Logical/narrative order when selectivity is similar**

Put the table that represents the "subject" first so the query reads like a sentence:

```sql
-- Reads: "For each order, what product was it for, and which supplier?"
FROM   orders o
INNER JOIN products p    ON o.product_id = p.product_id
INNER JOIN suppliers s   ON p.supplier_id = s.supplier_id;
```

---

#### Scenario 3 — Chaining multiple JOINs (multi-table queries)

**Rule: join tables in dependency order — each new table must be linkable to something already in the result set.**

```sql
FROM   orders o                                        -- anchor
LEFT  JOIN customers   c ON o.customer_id  = c.customer_id   -- enrichment
LEFT  JOIN products    p ON o.product_id   = p.product_id    -- enrichment
LEFT  JOIN promotions  pr ON o.promo_id   = pr.promo_id;     -- optional attribute
```

An intermediate result that hasn't been joined yet can't be referenced in a later ON clause — SQL will error or produce a cross join.

---

#### Scenario 4 — Avoiding fan-out (one-to-many blowup)

**Rule: join the many-side table LAST, or pre-aggregate it first.**

If you join a table that has multiple rows per key before aggregating, every upstream row gets multiplied.

```sql
-- BAD: tags has 5 rows per transaction → amounts get multiplied 5×
SELECT t.txn_id, SUM(t.amount)
FROM   transactions t
JOIN   txn_tags tag ON t.txn_id = tag.txn_id
GROUP BY t.txn_id;

-- GOOD: aggregate tags first, then join
WITH tag_agg AS (
    SELECT txn_id, COUNT(*) AS tag_count
    FROM   txn_tags
    GROUP BY txn_id
)
SELECT t.txn_id, t.amount, ta.tag_count
FROM   transactions t
LEFT JOIN tag_agg ta ON t.txn_id = ta.txn_id;
```

---

#### Scenario 5 — Date spine / calendar joins

**Rule: always put the spine on the LEFT.**

A date spine is a complete sequence of dates. If you put the fact table on the left, dates with no activity simply disappear from the result.

```sql
-- spine on left → zero-fills missing dates
SELECT s.dt, COALESCE(d.revenue, 0) AS revenue
FROM   date_spine s
LEFT JOIN daily_revenue d ON s.dt = d.txn_date;
```

---

#### Scenario 6 — Anti-join (find rows with NO match)

**Rule: the table you want to screen goes on the LEFT; the exclusion table goes on the RIGHT.**

```sql
-- Customers who have NEVER placed an order
SELECT c.customer_id, c.name
FROM   customers c
LEFT JOIN orders o ON c.customer_id = o.customer_id
WHERE  o.order_id IS NULL;   -- only rows with no match survive
```

Reversing the tables produces the wrong semantic entirely.

---

#### Scenario 7 — RIGHT JOIN (rare; when to use it)

A RIGHT JOIN is a LEFT JOIN with the tables swapped. The only time you'd genuinely choose RIGHT JOIN over rewriting as LEFT JOIN is when you're appending a second join to an already-established LEFT JOIN chain and reversing the whole chain would be more disruptive.

```sql
-- Uncommon but legitimate: you've built a large CTE chain ending in `o`
-- and now need all rows from `promotions` (right side)
FROM   orders o
RIGHT JOIN promotions p ON o.promo_id = p.promo_id;
-- equivalent: FROM promotions p LEFT JOIN orders o ON p.promo_id = o.promo_id
```

In practice: **always prefer rewriting as LEFT JOIN** — it's the convention the entire team expects.

---

#### Scenario 8 — FULL OUTER JOIN (reconciliation / auditing)

**Rule: put the "golden source" table on the left by convention; symmetry means it doesn't change results, but it sets the reading intent.**

```sql
-- Reconcile finance ledger vs. operational DB
SELECT COALESCE(f.txn_id, o.txn_id) AS txn_id,
       f.amount AS finance_amount,
       o.amount AS ops_amount
FROM   finance_ledger f
FULL OUTER JOIN ops_transactions o ON f.txn_id = o.txn_id;
-- rows only in finance → ops_amount is NULL (missing from ops)
-- rows only in ops    → finance_amount is NULL (missing from finance)
```

---

#### Scenario 9 — Performance: small table vs. large table (Nested Loop context)

For engines that use **Nested Loop Joins** (common in OLTP, indexed lookups):

| Driving Table | Inner Table | Behaviour |
|---|---|---|
| Small (1 K rows) | Large (10 M rows) | 1 K index lookups into large table — fast |
| Large (10 M rows) | Small (1 K rows) | 10 M index lookups into small table — slow |

**Rule: in a nested loop context, the small/filtered table should drive (go first).** Most optimizers figure this out automatically from statistics, but when stats are stale or you're writing a query hint, keep this in mind.

- The smaller table is used to build the hash table in memory (the "build side").
- The larger table is streamed through (the "probe side").
- Modern optimizers pick the build side regardless of your table order; pre-filtering large tables before the join is the lever you control.

---

#### Decision Checklist

```
1. Do I need ALL rows from one table, even with no match?
   → That table is on the LEFT (LEFT JOIN).

2. Is this an INNER JOIN?
   → Put the most selective / smallest filtered table first as a readability and optimizer hint.
   → Otherwise, follow the narrative / dependency order.

3. Am I joining a one-to-many table?
   → Pre-aggregate the many-side BEFORE joining to avoid fan-out.

4. Am I filling a date spine or any "scaffold" table?
   → Scaffold goes on the LEFT.

5. Am I looking for rows with NO match (anti-join)?
   → The table being screened goes LEFT; the exclusion table goes RIGHT.
```

---

#### Quick Reference — Order of Joins

| Scenario | Left Table | Right Table | Join Type |
|---|---|---|---|
| Primary entity + optional attribute | Anchor (customers, employees) | Attribute (orders, logs) | LEFT JOIN |
| Date/scaffold gap-filling | Spine / scaffold | Fact table | LEFT JOIN |
| Anti-join (find missing) | Table to screen | Exclusion table | LEFT JOIN + IS NULL |
| Reconciliation / audit | Golden source | Secondary source | FULL OUTER JOIN |
| Multi-table chain | Anchor → dependency order | Each enrichment in turn | LEFT / INNER |
| Nested loop OLTP | Small / filtered | Large indexed | INNER JOIN (optimizer hint) |
| One-to-many (fan-out risk) | Pre-aggregated many-side | Fact table | LEFT JOIN |
| RIGHT JOIN | Avoid — rewrite as LEFT JOIN by swapping | — | — |

> **Golden rule:** Ask "which table must I never lose a row from?" — that table goes on the LEFT.

---


