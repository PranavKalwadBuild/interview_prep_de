<!-- Part of sql-patterns: Silent Errors — Set Operations and Ordering -->

# Silent Errors — Set Operations and Ordering

UNION, INTERSECT, EXCEPT, and ORDER BY all have subtleties that produce wrong results without errors. The most dangerous: column alignment in UNION is positional, not by name. Two queries that look like they combine the same data can silently swap columns. Ordering guarantees are also widely misunderstood.

---

### UNION ALL Column Alignment by Position, Not Name — Silent Column Swap

**What it looks like:**
```sql
-- Combining event data from two sources
SELECT user_id, event_name, event_value FROM source_a
UNION ALL
SELECT user_id, event_value, event_name FROM source_b;  -- columns in wrong order
```

**What actually happens:** SQL matches UNION branches by column position, not column name. The result set uses the column names from the first SELECT. Column 3 from source_b (`event_name`) is silently placed in the `event_value` column. Column 2 from source_b (`event_value`) is silently placed in `event_name`. Every row from source_b has its event name and event value swapped. No error.

**Why it's insidious:** The result set has the correct column names (from the first SELECT). The column values look plausible — event values are often strings, event names are often strings. The swap is only caught if someone spot-checks source_b rows specifically.

**Minimal repro:**
```sql
WITH source_a AS (SELECT 1 AS uid, 'click'::VARCHAR AS ename, '5'::VARCHAR AS eval),
     source_b AS (SELECT 2 AS uid, '3'::VARCHAR AS eval_val, 'view'::VARCHAR AS event_n)
SELECT uid, ename, eval FROM source_a
UNION ALL
SELECT uid, eval_val, event_n FROM source_b;  -- intentional swap to demonstrate
-- Result: uid=2, ename='3', eval='view'  -- swapped silently!
```

**How to catch it:**
```sql
-- Spot-check source_b rows in the combined result:
SELECT * FROM combined_events WHERE source = 'b' LIMIT 10;
-- Manually verify event_name looks like an event name, event_value looks like a value.

-- Better pattern: always use explicit column aliases and verify schema alignment:
SELECT uid,
       event_name  AS event_name,   -- explicit labeling forces review
       event_value AS event_value
FROM source_a
UNION ALL
SELECT uid,
       event_name_col  AS event_name,   -- force matching alias
       event_value_col AS event_value
FROM source_b;
```

**Real-world trigger:** Two data pipelines combined for a unified event model. Source B was built by a different team. Column order in the source B table differed from source A because the schema was designed independently. The combined model silently mixed event names and values for all source B events — approximately 40% of the dataset — for 3 months.

---

### UNION Silently Deduplicates — Legitimately Identical Rows Disappear

**What it looks like:**
```sql
SELECT product_id, price FROM current_prices
UNION
SELECT product_id, price FROM historical_prices;
```

**What actually happens:** `UNION` (without ALL) performs a full deduplication across both result sets. If a product has the same price in both current and historical (e.g., the price never changed), that row appears only once. If the intent was to see all rows from both tables — including identical ones — `UNION ALL` is required.

**Why it's insidious:** `UNION` without ALL is almost always a mistake in data engineering contexts (where you want all rows and will deduplicate separately if needed). The result is smaller than expected but not obviously wrong — it just silently drops the duplicates that the developer didn't realize were "legitimate" identical rows.

**Minimal repro:**
```sql
WITH curr AS (SELECT 1 AS pid, 100 AS price UNION ALL SELECT 2, 200),
     hist AS (SELECT 1 AS pid, 100 AS price UNION ALL SELECT 2, 150)  -- product 1: same price both
SELECT pid, price FROM curr
UNION
SELECT pid, price FROM hist;
-- Returns: (1,100), (2,200), (2,150) -- 3 rows
-- UNION ALL would return: (1,100), (2,200), (1,100), (2,150) -- 4 rows
-- The duplicate (1,100) from hist is silently dropped
```

**How to catch it:**
```sql
-- Invariant: UNION ALL result count = sum of input counts
WITH union_all AS (SELECT COUNT(*) AS n FROM (SELECT ... UNION ALL SELECT ...)),
     union_dedup AS (SELECT COUNT(*) AS n FROM (SELECT ... UNION SELECT ...))
SELECT a.n AS union_all_count, b.n AS union_dedup_count,
       a.n - b.n AS silently_dropped
FROM union_all a, union_dedup b;
```

**Real-world trigger:** Price history reconstruction model uses UNION to combine current and historical price snapshots. Products that never changed price appear exactly once (correct count by accident). Products that changed price appear multiple times (correct). The model is used for period-average pricing and the single-price-forever products silently have their history collapsed.

---

### EXCEPT / MINUS with NULLs — NULL Equality in Set Operations

**What it looks like:**
```sql
-- "Find users in table A not present in table B"
SELECT user_id FROM table_a
EXCEPT
SELECT user_id FROM table_b;
```

**What actually happens:** In set operations (UNION, INTERSECT, EXCEPT), NULLs are treated as equal to each other. `NULL EXCEPT NULL` removes the NULL row from the result. This contrasts with `WHERE user_id = NULL` (which is always UNKNOWN). The NULL in table_a is considered "present" in table_b and is correctly excluded.

The insidious case: you want to find rows that are *genuinely different*, and some rows have NULL in one table but a value in another. A NULL user_id in A and a NULL user_id in B are treated as the "same" by EXCEPT, so neither appears in the result. If a NULL in one table represents "unknown" and a NULL in the other represents "deleted," they are semantically different but set-operation-equal.

**Minimal repro:**
```sql
WITH a AS (SELECT * FROM (VALUES (1),(NULL),(3)) t(id)),
     b AS (SELECT * FROM (VALUES (1),(NULL)) t(id))
SELECT id FROM a EXCEPT SELECT id FROM b;
-- Returns: 3 only. NULL from A is "removed" because NULL exists in B.
-- If NULL in A means "pending" and NULL in B means "archived", they are different records
-- but EXCEPT silently treats them as matches.
```

**How to catch it:**
```sql
-- For semantic EXCEPT that treats NULLs as distinct, use:
SELECT id FROM a WHERE id IS NOT NULL
  AND id NOT IN (SELECT id FROM b WHERE id IS NOT NULL)
UNION ALL
SELECT id FROM a WHERE id IS NULL
  AND NOT EXISTS (SELECT 1 FROM b WHERE id IS NULL);
-- Or more simply: use NOT EXISTS with IS DISTINCT FROM
```

**Real-world trigger:** Reconciliation pipeline uses EXCEPT to find records in source that are missing from target. NULLs in the key column (orphaned records) silently match each other and are excluded from the reconciliation result. Orphaned records are never investigated.

---

### ORDER BY in Subquery or CTE Is Not Guaranteed

**What it looks like:**
```sql
WITH ranked AS (
    SELECT user_id, score,
           ROW_NUMBER() OVER (ORDER BY score DESC) AS rn
    FROM scores
    ORDER BY score DESC   -- this ORDER BY has no effect in a CTE
)
SELECT *
FROM ranked
WHERE rn <= 10;
```

**What actually happens:** An `ORDER BY` clause inside a CTE or subquery is not guaranteed to be preserved in the output. The SQL standard does not require that ordering be maintained through a derived table. Most engines ignore or strip the ORDER BY from inner queries. The outer query's row order is determined by its own execution, not the inner ORDER BY.

**Why it's insidious:** The CTE looks sorted. The inner ORDER BY gives the impression that the output is ordered. In practice, the only ORDER BY that guarantees ordered output is on the outermost SELECT statement. The ROW_NUMBER in the example is correct (it's a window function with its own ORDER BY), but any logic that *relies* on the CTE rows being physically ordered will silently fail.

**Minimal repro:**
```sql
WITH ordered AS (
    SELECT generate_series AS n FROM generate_series(1, 5)
    ORDER BY n DESC  -- no effect
)
SELECT * FROM ordered;
-- May return rows in any order: 1,2,3,4,5 or 5,4,3,2,1 or random
-- Only ORDER BY on the final SELECT is guaranteed.
```

**How to catch it:**
```sql
-- Rule: every query that requires ordered output must have ORDER BY on the final SELECT.
-- Never rely on inner-query ORDER BY for outer-query row order.
-- Any application logic that processes SQL result rows in order must ensure the final SELECT has ORDER BY.
```

**Real-world trigger:** ETL job loads data from a CTE that has `ORDER BY created_at` in the inner query. The loading logic uses Python's `enumerate()` to assign sequence numbers based on row arrival order. Different query executions produce different sequences. Data loaded on Monday has different sequence assignments than data loaded on Tuesday for the same records.

---

### INTERSECT Removing NULLs — NULL Set Equality vs NULL Comparison Equality

**What it looks like:**
```sql
-- "Find users present in both cohorts"
SELECT user_id FROM cohort_a
INTERSECT
SELECT user_id FROM cohort_b;
```

**What actually happens:** `INTERSECT` uses set semantics where `NULL = NULL` (unlike the standard `=` operator). If `user_id` is NULL in both tables, the NULL row is retained in the INTERSECT result (one row, not two). This is different from `JOIN ON a.user_id = b.user_id` where NULL keys never match.

The trap: replacing an INTERSECT with a JOIN produces different NULL behavior. Switching from INTERSECT to JOIN silently excludes NULL-key rows. Switching from JOIN to INTERSECT silently includes them.

**Minimal repro:**
```sql
WITH a AS (SELECT * FROM (VALUES (1),(NULL),(3)) t(id)),
     b AS (SELECT * FROM (VALUES (1),(NULL),(2)) t(id))

-- INTERSECT: NULL = NULL, so NULL row is included
SELECT id FROM a INTERSECT SELECT id FROM b;
-- Returns: 1, NULL (two rows)

-- JOIN: NULL != NULL, so NULL rows are excluded
SELECT a.id FROM a JOIN b ON a.id = b.id;
-- Returns: 1 only (NULL rows silently excluded)
```

**How to catch it:** Whenever converting between JOIN and INTERSECT, explicitly test the behavior on NULL-key rows. If the JOIN is the intended semantic (only match on actual values), wrap both sides in `WHERE id IS NOT NULL`.

**Real-world trigger:** Audience overlap analysis originally written with INTERSECT is rewritten as a JOIN for performance. The audience that contained anonymous users (NULL IDs) silently shrinks. Overlap metrics change by 5–15% depending on anonymous user proportion.

---

### ORDER BY on Column Not in SELECT DISTINCT — Engine-Specific Behavior

**What it looks like:**
```sql
SELECT DISTINCT user_id, segment
FROM user_events
ORDER BY event_timestamp;  -- event_timestamp not in SELECT list
```



**Minimal repro:**

**How to catch it:** Add a CI test that runs the query on the target warehouse engine specifically. Never assume a query that works in one SQL dialect is portable to another for DISTINCT + ORDER BY combinations.


---

### EXCEPT Ordering — Result Order Is Not Guaranteed

**What it looks like:**
```sql
SELECT user_id FROM active_users
EXCEPT
SELECT user_id FROM churned_users
ORDER BY user_id;
```

**What actually happens:** This is actually correct — `ORDER BY` applies to the result of the EXCEPT. But a common mistake is:

```sql
SELECT user_id FROM active_users ORDER BY user_id  -- ORDER BY inside branch
EXCEPT
SELECT user_id FROM churned_users;
```

The `ORDER BY` on the first branch of a set operation is either an error (PostgreSQL) or silently ignored (MySQL). The result ordering of the EXCEPT is not determined by the inner ORDER BY. No error in MySQL — just undefined output ordering.

**Minimal repro:**
```sql
-- PostgreSQL: syntax error - ORDER BY must be on the combined result, not on individual branches
-- MySQL/older SQL: silently ignores the inner ORDER BY, applies EXCEPT first
-- Correct pattern: apply ORDER BY after the full set operation
SELECT user_id FROM active_users
EXCEPT
SELECT user_id FROM churned_users
ORDER BY user_id;  -- at the end, applies to the full EXCEPT result
```

**How to catch it:** Treat any `ORDER BY` inside a UNION/INTERSECT/EXCEPT branch as a portability hazard. Always move ORDER BY to after the final set operation.

**Real-world trigger:** Data pipeline exports a ranked list of exclusion users via EXCEPT with an inner ORDER BY for "auditing." The export appears ordered on some environments, random on others. Downstream system processes the list sequentially and first-N behavior differs between environments.
