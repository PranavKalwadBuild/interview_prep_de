<!-- Part of sql-patterns: Performance and Query Optimisation Patterns -->
<!-- Source: sql_patterns.md lines 10797–10876 -->

## 30. Performance & Query Optimisation Patterns

### What it solves

Write queries that run faster and cheaper — critical in DE interviews when asked "how would you optimise this?"

### Keywords to spot

> "optimise", "slow query", "reduce cost", "partition pruning",
> "avoid full scan", "index", "skew", "large table join",
> "query is too slow", "expensive scan", "full table scan",
> "data skew", "hot partition", "broadcast join", "execution plan",
> "query cost", "FinOps", "bytes scanned", "improve performance"

### Key Principles & Patterns

```sql
-- 1. FILTER EARLY: push WHERE conditions to CTEs/subqueries before joining
-- BAD:
SELECT * FROM trades t JOIN users u ON t.user_id = u.user_id WHERE t.trade_date = '2024-01-01';

-- GOOD: filter before joining
WITH jan_trades AS (
    SELECT * FROM trades WHERE trade_date = '2024-01-01'  -- partition prune here
)
SELECT * FROM jan_trades t JOIN users u ON t.user_id = u.user_id;

-- 2. AVOID SELECT * — always specify columns
SELECT trade_id, user_id, trade_amount FROM trades;  -- not SELECT *

-- 3. AVOID FUNCTIONS ON INDEXED/PARTITION COLUMNS IN WHERE
-- BAD (prevents partition pruning):
WHERE YEAR(executed_at) = 2024

-- GOOD:
WHERE executed_at >= '2024-01-01' AND executed_at < '2025-01-01'

-- 4. AVOID NOT IN ON NULLABLE COLUMNS — use NOT EXISTS instead
-- BAD:
WHERE user_id NOT IN (SELECT user_id FROM blocked_users)  -- breaks if NULLs present

-- GOOD:
WHERE NOT EXISTS (SELECT 1 FROM blocked_users b WHERE b.user_id = t.user_id)

-- 5. AVOID CORRELATED SUBQUERIES IN SELECT — use window functions
-- BAD (runs subquery for every row):
SELECT user_id, (SELECT MAX(trade_amount) FROM trades t2 WHERE t2.user_id = t1.user_id)
FROM trades t1;

-- GOOD:
SELECT user_id, MAX(trade_amount) OVER (PARTITION BY user_id)
FROM trades;

-- 6. APPROXIMATE COUNTS for large-scale analytics

-- 7. USE UNION ALL NOT UNION unless dedup is needed
-- UNION runs a DISTINCT operation — expensive for large sets

-- 8. AVOID CROSS JOINS unless intentional
-- Accidentally omitting a JOIN condition creates a cartesian product

