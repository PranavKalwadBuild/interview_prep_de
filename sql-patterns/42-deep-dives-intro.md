<!-- sql-patterns: Deep Dives — Part 3 Introduction and Overview -->

# Deep Dives

### Edge Cases

#### Edge 30-A: Implicit type conversion in WHERE defeats partition pruning

**Problem:**

```sql
-- Partitioned table: transactions partitioned by CAST(txn_date AS VARCHAR) — a VARCHAR partition key
-- WRONG: numeric comparison on a VARCHAR partition key
WHERE txn_date = 20240115     -- numeric 20240115 compared to VARCHAR '2024-01-15'
-- Engine implicitly casts ALL partition keys to numeric to evaluate → full table scan
-- No partition pruning → scans ALL partitions

-- CORRECT: match the data type of the partition key exactly
WHERE txn_date = '2024-01-15'   -- VARCHAR compared to VARCHAR → partition pruning works

-- Another common form:
-- Partitioned by DATE(created_at) where the partition key is a DATE
-- WRONG:
WHERE YEAR(created_at) = 2024 AND MONTH(created_at) = 1
-- This applies a function to created_at → partition key not directly comparable → full scan
-- CORRECT:
WHERE created_at >= '2024-01-01' AND created_at < '2024-02-01'
-- No function on the partition column → partition pruning works
```

**Fix:**


#### Edge 30-B: CTE materialisation vs optimisation — engine-specific behaviour

**Problem:**



```sql
-- CREATE OR REPLACE TEMP VIEW expensive_agg AS SELECT ... ;  -- then reference the view twice

-- In PostgreSQL 12+: add WITH MATERIALIZED to force single evaluation:
WITH MATERIALIZED expensive_agg AS (...)
SELECT ... FROM expensive_agg a JOIN expensive_agg b ...;
```

#### Edge 30-C: DISTINCT on a subquery with millions of rows — hidden sort

**Problem:**

```sql
-- DISTINCT requires either a hash dedup or a sort — both are expensive
SELECT DISTINCT user_id FROM transactions;  -- 500M row table → materialise + dedup all rows

-- If you know the column is already unique (e.g., it's a primary key in another table):
-- DISTINCT is wasted work → remove it
-- If duplicates exist: investigate root cause rather than patching with DISTINCT

-- Common trap: DISTINCT inside a COUNT to handle a known fanout:
SELECT COUNT(DISTINCT user_id) FROM transactions;  -- correct but expensive
-- Faster alternative for approximate results:
SELECT APPROX_COUNT_DISTINCT(user_id) FROM transactions;  -- HyperLogLog, ~1% error, 10× faster
-- Use exact COUNT(DISTINCT) only when precision is required (billing, compliance)
```

**Fix:**


#### Edge 30-D: CROSS JOIN without a filter condition — accidental cartesian product

**Problem:**


**Fix — always include an ON or USING clause for every JOIN:**

```sql
SELECT m.merchant_id, p.product_id, p.interest_rate
FROM merchants m
JOIN loan_products p ON m.eligible_product_category = p.category;
```


#### Shuffle Reduction Strategies for Distributed SQL


#### Approximate Algorithms for Interactive Scale


---
---


