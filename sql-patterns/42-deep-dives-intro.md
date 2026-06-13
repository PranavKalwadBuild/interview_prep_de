<!-- Part of sql-patterns: Deep Dives — Part 3 Introduction and Overview -->
<!-- Source: sql_patterns.md lines 10877–11136 -->

# Part 3 — Deep Dives

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

```sql
-- Always match the literal data type to the column's declared type to enable partition pruning:

-- Partitioned by DATE-typed txn_date:
WHERE txn_date = '2024-01-15'        -- DATE string literal → partition pruning works ✓
-- NOT: WHERE txn_date = 20240115     -- integer literal → implicit cast → full scan ✗

-- Partitioned by DATE(created_at):
WHERE created_at >= '2024-01-01'
  AND created_at <  '2024-02-01'     -- range on the raw column → partition pruning works ✓
-- NOT: WHERE YEAR(created_at) = 2024 AND MONTH(created_at) = 1
--   -- function applied to partition column → full scan ✗

-- To verify pruning is working, check the query plan:
-- Snowflake: EXPLAIN USING TABULAR → look for "partition_filter" step
-- BigQuery: EXPLAIN → look for "partitions_eliminated" in the query plan
-- Spark: check "PartitionFilters" in the physical plan via EXPLAIN FORMATTED
```

#### Edge 30-B: CTE materialisation vs optimisation — engine-specific behaviour

**Problem:**

```sql
-- PostgreSQL < 12: CTEs are always materialised (executed once, result stored)
-- PostgreSQL >= 12: CTEs are "optimisation fences" only when marked WITH MATERIALIZED
-- Snowflake / BigQuery / DuckDB: CTEs are NOT materialised — inlined into the query plan
-- Spark: CTEs are NOT materialised by default — re-executed each time referenced

-- TRAP in Spark: referencing the same CTE twice runs it twice
WITH expensive_agg AS (
    SELECT user_id, SUM(amount) AS total FROM transactions GROUP BY user_id
    -- Imagine this scans 1B rows
)
SELECT a.user_id, a.total, b.total AS total_check
FROM expensive_agg a
JOIN expensive_agg b ON a.user_id = b.user_id;
-- In Spark: expensive_agg is scanned TWICE — 2B row scans!
```

**Fix — in Spark: cache the CTE result explicitly:**

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

```sql
-- Approach 1: Remove unnecessary DISTINCT when the column is already unique:
-- First verify: SELECT COUNT(*), COUNT(DISTINCT user_id) FROM transactions
-- If both are equal, the DISTINCT is redundant — remove it.

-- Approach 2: Use EXISTS instead of DISTINCT for existence checks:
-- WRONG (expensive): SELECT DISTINCT user_id FROM transactions WHERE amount > 1000
-- CORRECT (uses index): SELECT user_id FROM users WHERE EXISTS (
--     SELECT 1 FROM transactions WHERE user_id = users.user_id AND amount > 1000
-- )

-- Approach 3: For COUNT(DISTINCT) on large tables, use approximate counting:
-- Exact (expensive on 500M rows):
SELECT COUNT(DISTINCT user_id) FROM transactions;

-- Approximate (HyperLogLog, ~1% error, 10-100× faster):
SELECT APPROX_COUNT_DISTINCT(user_id) FROM transactions;          -- Snowflake / BigQuery
SELECT COUNT(DISTINCT user_id) AS approx FROM transactions LIMIT 1; -- with HLL sampling

-- Use exact COUNT(DISTINCT) only for billing, compliance, and precision-critical aggregations
```

#### Edge 30-D: CROSS JOIN without a filter condition — accidental cartesian product

**Problem:**

```sql
-- Intended: join every merchant to every loan product to check eligibility
-- WRITTEN: forgot the ON clause or WHERE filter

SELECT m.merchant_id, p.product_id, p.interest_rate
FROM merchants m
JOIN loan_products p;        -- INNER JOIN without ON = CROSS JOIN in some engines (error in others)
-- 100,000 merchants × 50 loan products = 5,000,000 rows

-- In PostgreSQL: JOIN without ON is a syntax error
-- In MySQL/Spark: JOIN without ON treated as CROSS JOIN — executes without error!

-- Detection in EXPLAIN output: look for "Nested Loop" or "BroadcastNestedLoopJoin"
-- without a join condition — these indicate a cartesian product
```

**Fix — always include an ON or USING clause for every JOIN:**

```sql
SELECT m.merchant_id, p.product_id, p.interest_rate
FROM merchants m
JOIN loan_products p ON m.eligible_product_category = p.category;
```

```sql

---

### At Scale

This section gives the storage and infrastructure design decisions for the most common large-scale workloads.

#### Storage Design Decision Matrix

| Engine | Partition Key | Cluster/Sort Key | When to use |
|--------|---------------|------------------|-------------|
| **Delta Lake** | `DATE(event_ts)` or `event_month` | `ZORDER BY (user_id, event_type)` | Default for Databricks; incremental processing |
| **Delta Liquid** | None (mutually exclusive) | `CLUSTER BY (user_id, event_ts)` | Delta 3.0+; replaces partition + ZORDER |
| **Snowflake** | Micro-partitions (automatic) | `CLUSTER BY (user_id, DATE_TRUNC('month', ts))` | Analytics; automatic maintenance |
| **BigQuery** | `PARTITION BY DATE(ts)` | `CLUSTER BY user_id, status` | Serverless; cost charged per bytes scanned |
| **Redshift** | `DISTKEY(join_key)` | `COMPOUND SORTKEY(time_col, join_key)` | Join-heavy workloads; controlled cluster |
| **PostgreSQL** | `PARTITION BY RANGE (date_col)` | B-tree index on `(join_key, date_col)` | OLTP/small DW; pg_partman for automation |

#### Key Rule: Match Your Access Pattern to Your Physical Layout

```

```sql
-- Query pattern 1: time-series range scan (most common for analytics)
-- "Give me all UPI transactions from Jan–Mar 2024"
-- Physical layout: PARTITION BY DATE(txn_date) (Delta/BQ/Redshift)
-- Reads: only Jan–Mar partitions (3/36 = 8% of data if 3 years history)

-- Query pattern 2: entity lookup (most common for API / operational queries)
-- "Give me all transactions for user_id = U001"
-- Physical layout: CLUSTER BY user_id (Delta ZORDER) or SEARCH OPTIMIZATION (Snowflake)
-- Reads: only files containing U001's data (< 1% of data with good clustering)

-- Query pattern 3: time-range + entity (most common for analytics + operational hybrid)
-- "Give me all transactions for user_id = U001 in Jan 2024"
-- Physical layout: PARTITION BY DATE(txn_date), ZORDER BY user_id
-- Reads: Jan partition → data-skipped to U001 files: 1/12 × 1/N users = minimal I/O

-- Query pattern 4: multi-tenant (per-merchant, per-bank, per-product analytics)
-- "Give me all transactions for bank_id = HDFC"
-- Physical layout (if low cardinality): PARTITION BY bank_id
-- Physical layout (if high cardinality, 10K banks): CLUSTER BY bank_id (not partition)
--   Partitioning on high-cardinality = file explosion (10K directories × 12 months = 120K partitions)
```

#### Shuffle Reduction Strategies for Distributed SQL

```sql
-- Strategy 1: Broadcast join (small table, large table)
-- Automatically triggered when small table < spark.sql.autoBroadcastJoinThreshold (default 10MB)
SET spark.sql.autoBroadcastJoinThreshold = 104857600;  -- raise to 100MB if small table is larger

-- Strategy 2: Bucket join (two large tables, same bucket count on same key)
-- Pre-bucket at table creation time; joins on the bucket key never shuffle
-- Cost: O(N/buckets) sort within each bucket instead of O(N) global shuffle

-- Strategy 3: AQE (Spark 3.x) — automatic skew split, partition coalescing, join strategy change
SET spark.sql.adaptive.enabled = true;
SET spark.sql.adaptive.coalescePartitions.enabled = true;
SET spark.sql.adaptive.skewJoin.enabled = true;
SET spark.sql.adaptive.skewJoin.skewedPartitionThresholdInBytes = 268435456;  -- 256MB

-- Strategy 4: Pre-shuffle (manually redistribute before the operation that causes the shuffle)
-- If you know a window function will shuffle by user_id, you can sort by user_id first
-- to improve memory locality — rarely needed with AQE

-- Strategy 5: Partition pruning (most impactful, always verify it's active)
EXPLAIN SELECT * FROM transactions WHERE txn_date = '2024-01-15';
-- Look for: "PartitionFilters: [isnotnull(txn_date#0), (txn_date#0 = 2024-01-15)]" in the plan
-- If you see FileScan without PartitionFilters: partition pruning is NOT active
-- Common cause: function on partition column (YEAR(txn_date) instead of txn_date range)
```

#### Approximate Algorithms for Interactive Scale

```sql
-- COUNT(DISTINCT) at scale: HyperLogLog (~1% error, 1000× faster)
-- Snowflake:
SELECT HLL(user_id) AS approx_distinct_users FROM transactions;
-- Or build a sketch and combine:
SELECT HLL_ACCUMULATE(user_id) AS hll_sketch FROM transactions;  -- precompute
SELECT HLL_ESTIMATE(COMBINE(hll_sketch)) FROM hll_sketches;     -- combine shards

-- BigQuery:
SELECT HLL_COUNT.EXTRACT(sketch) AS approx_count
FROM (SELECT HLL_COUNT.INIT(user_id, 14) AS sketch FROM transactions);
-- Accuracy param 14 = 0.625% error; storage: 2^14 = 16KB per sketch vs full dedup

-- Spark:
SELECT APPROX_COUNT_DISTINCT(user_id, 0.01) FROM transactions;  -- 1% relative error

-- PERCENTILE at scale: t-digest (configurable accuracy)
-- Spark:
SELECT PERCENTILE_APPROX(amount, 0.99, 10000) FROM transactions;  -- 10000 = high accuracy
-- BigQuery:
SELECT APPROX_QUANTILES(amount, 100)[OFFSET(99)] FROM transactions;

-- FREQUENT ITEMS (top-K heavy hitters) at scale: Count-Min Sketch
-- For "top 10 merchants by transaction count" without a full GROUP BY + ORDER BY:
SELECT APPROX_TOP_K(merchant_id, 10) FROM transactions;  -- Databricks SQL
-- Count-Min Sketch: O(1) space, O(1) update per row, guaranteed error bound
```

```sql

---
---

