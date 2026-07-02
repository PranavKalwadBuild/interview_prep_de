<!-- sql-patterns: Query Plans and EXPLAIN -->

# Query Plans and EXPLAIN

`EXPLAIN` is the bridge between SQL text and execution behavior. ANSI SQL does not standardize a full plan format, so this file teaches the portable concepts first and uses PostgreSQL/MySQL only for concrete syntax.

---

## 1. What a Query Plan Answers

A plan explains:

- Which table is read first.
- Whether the database scans a table or uses an index.
- Which join algorithm is chosen.
- Where filters are applied.
- Where sorting, grouping, and windowing happen.
- How many rows the optimizer expects at each step.
- Whether estimates are likely to be wrong.

The exact labels vary, but the mental model is stable.

---

## 2. Core Operators

| Operator idea | What it means | Common risk |
|---|---|---|
| Sequential/table scan | Read many or all rows from a table | Expensive if the predicate is selective |
| Index lookup/range scan | Use an access path to find matching rows | Bad if the index is unselective |
| Nested loop join | For each outer row, look up matching inner rows | Explodes if outer input is large |
| Hash join | Build hash table on one side, probe with the other | Spills if build side is too large |
| Merge join | Join two sorted inputs | Requires sorted inputs |
| Sort | Order rows for `ORDER BY`, merge join, or windows | Memory spill on large inputs |
| Aggregate | Collapse rows into groups | Hash/table memory pressure or expensive sort |
| Window | Compute across partitions without collapsing rows | Large partitions require sorting and memory |

---

## 3. PostgreSQL EXPLAIN

```sql
EXPLAIN
SELECT
    c.customer_id,
    SUM(o.amount) AS total_amount
FROM customers c
JOIN orders o
    ON o.customer_id = c.customer_id
WHERE o.order_date >= DATE '2025-01-01'
GROUP BY c.customer_id;
```

Use runtime details when you can safely execute the query:

```sql
EXPLAIN (ANALYZE, BUFFERS)
SELECT
    c.customer_id,
    SUM(o.amount) AS total_amount
FROM customers c
JOIN orders o
    ON o.customer_id = c.customer_id
WHERE o.order_date >= DATE '2025-01-01'
GROUP BY c.customer_id;
```

**How to read it**

- `cost` is the optimizer's internal estimate, not wall-clock time.
- `rows` is estimated cardinality. Compare estimated rows to actual rows when using `ANALYZE`.
- `actual time` shows runtime per operator.
- `loops` shows how many times an operator ran. A small inner lookup repeated millions of times is a red flag.
- `Buffers` shows read/cache behavior when enabled.

**PostgreSQL gotchas**

- `EXPLAIN ANALYZE` executes the query. Do not run it on writes unless wrapped safely.
- Stale statistics can make the optimizer choose the wrong join order.
- A sequential scan is not automatically bad. It can be correct when most rows are needed.

---

## 4. MySQL EXPLAIN

```sql
EXPLAIN
SELECT
    c.customer_id,
    SUM(o.amount) AS total_amount
FROM customers c
JOIN orders o
    ON o.customer_id = c.customer_id
WHERE o.order_date >= DATE '2025-01-01'
GROUP BY c.customer_id;
```

For more detail:

```sql
EXPLAIN FORMAT=JSON
SELECT
    c.customer_id,
    SUM(o.amount) AS total_amount
FROM customers c
JOIN orders o
    ON o.customer_id = c.customer_id
WHERE o.order_date >= DATE '2025-01-01'
GROUP BY c.customer_id;
```

**How to read common columns**

| Column | Meaning |
|---|---|
| `type` | Access method; `ALL` is a full scan, `range` and `ref` are usually better |
| `possible_keys` | Indexes the optimizer could use |
| `key` | Index actually chosen |
| `rows` | Estimated rows examined |
| `filtered` | Estimated percent of rows that survive predicates |
| `Extra` | Notes such as temporary table, filesort, or index condition |

**MySQL gotchas**

- `Using filesort` does not always mean disk sort, but it means the requested order is not naturally satisfied by the chosen access path.
- `Using temporary` can be fine for small grouped results and painful for large ones.
- If `possible_keys` is populated but `key` is `NULL`, the optimizer judged the index not worth using.

---

## 5. Join Algorithm Diagnostics

### Nested loop risk

```sql
SELECT *
FROM orders o
JOIN order_items i
    ON i.order_id = o.order_id
WHERE o.order_date >= DATE '2025-01-01';
```

Nested loops are good when the outer side is small and the inner lookup is indexed. They are bad when both sides are large and the inner side is scanned repeatedly.

**Fixes**

- Add or correct an index on the join key.
- Filter the outer side earlier.
- Pre-aggregate before joining when detail rows are not needed.

### Hash join risk

A hash join is often strong for large equality joins, but it needs memory for the build side.

**Fixes**

- Build on the smaller input.
- Filter and project before the join.
- Pre-aggregate many-to-one detail tables.

### Merge join risk

Merge joins can be efficient when both inputs are already ordered by the join key. If the plan sorts both large inputs first, the sort cost may dominate.

---

## 6. Cardinality Estimation Problems

The optimizer chooses plans based on estimated row counts. When estimates are wrong, the plan can be wrong.

Common causes:

- Stale statistics.
- Correlated columns treated as independent.
- Skewed values such as one customer owning most rows.
- Predicates using functions, casts, or expressions.
- `NULL` distributions not represented well.

Detection pattern:

```sql
-- PostgreSQL: compare estimated rows to actual rows
EXPLAIN (ANALYZE)
SELECT *
FROM transactions
WHERE merchant_id = 101
  AND event_date >= DATE '2025-01-01';
```

If estimated rows are 100 but actual rows are 10,000,000, the optimizer may choose a plan that is structurally wrong for the real data.

---

## 7. Sort, Group, and Window Hotspots

```sql
SELECT
    account_id,
    posted_at,
    SUM(amount) OVER (
        PARTITION BY account_id
        ORDER BY posted_at
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ) AS running_balance
FROM ledger_entries;
```

This query may require sorting by `(account_id, posted_at)`. It becomes cheaper when the table has a matching access path or when a preceding filter reduces the input.

**Gotchas**

- Window functions do not reduce rows, so they can be more memory-intensive than grouped aggregates.
- `ORDER BY` inside a window is separate from final result ordering.
- Large single partitions, such as one account with millions of rows, can dominate runtime.

---

## 8. CTEs, Subqueries, and Materialization

```sql
WITH filtered_orders AS (
    SELECT *
    FROM orders
    WHERE order_date >= DATE '2025-01-01'
)
SELECT COUNT(*)
FROM filtered_orders
WHERE amount > 100;
```

The key question is whether the optimizer inlines the CTE or materializes it. ANSI SQL does not require one behavior.

**Portable guidance**

- Use CTEs for readability when they are referenced once.
- If a CTE is referenced multiple times and expensive, consider persisting the intermediate result intentionally.
- Check the plan instead of assuming the CTE is cached.

---

## 9. Rewrite Patterns

### Function-wrapped predicate

Risky:

```sql
WHERE CAST(event_ts AS DATE) = DATE '2025-01-15'
```

Better:

```sql
WHERE event_ts >= TIMESTAMP '2025-01-15 00:00:00'
  AND event_ts <  TIMESTAMP '2025-01-16 00:00:00'
```

### Join before aggregation

Risky:

```sql
SELECT c.customer_id, SUM(i.item_amount)
FROM customers c
JOIN orders o ON o.customer_id = c.customer_id
JOIN order_items i ON i.order_id = o.order_id
GROUP BY c.customer_id;
```

Often better:

```sql
WITH order_totals AS (
    SELECT order_id, SUM(item_amount) AS order_amount
    FROM order_items
    GROUP BY order_id
)
SELECT c.customer_id, SUM(ot.order_amount)
FROM customers c
JOIN orders o ON o.customer_id = c.customer_id
JOIN order_totals ot ON ot.order_id = o.order_id
GROUP BY c.customer_id;
```

### Missing deterministic order

Risky:

```sql
ROW_NUMBER() OVER (PARTITION BY user_id ORDER BY updated_at) AS rn
```

Better:

```sql
ROW_NUMBER() OVER (
    PARTITION BY user_id
    ORDER BY updated_at, event_id
) AS rn
```

---

## 10. Review Checklist

- Does the plan read fewer rows after each filter?
- Are join keys indexed or physically organized where appropriate?
- Are estimated rows close to actual rows?
- Is the largest table filtered before joining?
- Are expensive sorts required for `ORDER BY`, `GROUP BY`, or windows?
- Are function-wrapped predicates preventing access-path usage?
- Are CTEs referenced multiple times and recomputed or materialized unexpectedly?
- Is a full scan actually acceptable because the query needs most rows?

Plans are not about memorizing operator names. They are about explaining where rows grow, where rows shrink, and where the database spends work.

