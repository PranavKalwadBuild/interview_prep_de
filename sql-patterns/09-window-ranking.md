<!-- sql-patterns: Window Functions — Ranking: ROW_NUMBER, RANK, DENSE_RANK -->

# Window Functions — Ranking

## What it solves

Assign a rank or position to rows within a group, without collapsing rows (unlike GROUP BY).

## Keywords to spot

> "rank", "top N per", "highest/lowest per group", "position", "nth largest", "leaderboard",
> "for each user find their most recent", "for each category find the best",
> "ranked by", "order within group", "podium", "standings", "best performing",
> "most active", "top earner", "number one in each", "first place per"

## Difference between the three

| Function | Ties | Gaps in rank? |
|---|---|---|
| `ROW_NUMBER()` | Arbitrarily breaks ties | No gaps |
| `RANK()` | Same rank for ties | Yes — skips numbers |
| `DENSE_RANK()` | Same rank for ties | No gaps |

```
Scores: 100, 100, 90

ROW_NUMBER → 1, 2, 3
RANK       → 1, 1, 3   (gap at 2)
DENSE_RANK → 1, 1, 2   (no gap)
```

## Business Context

- **Fintech/Trading:** Rank traders by daily volume; find top wallet by balance; identify the highest-fee transaction per user per month for reconciliation
- **E-commerce:** Rank products by revenue per category; find each customer's most recent order; identify the top-selling SKU per warehouse location
- **SaaS:** Rank feature usage per account; find each tenant's most recently created record; identify the highest-DAU product tier per enterprise account
- **Logistics:** Rank drivers by deliveries per region; find the latest shipment status per order; rank courier partners by on-time delivery rate per city
- **Gaming/Media:** Leaderboard rankings by score per game level; top 3 content creators by watch-time per genre per week
- **Healthcare:** Rank hospitals by patient readmission rate per region; find each patient's most recent diagnostic code
- **Telecom:** Rank plans by revenue per geography; find the most recent usage record per subscriber SIM

## Boilerplate

```sql
-- Pattern: Rank rows within a group
SELECT
    user_id,
    trading_pair,
    trade_amount,
    ROW_NUMBER()  OVER (PARTITION BY user_id ORDER BY trade_amount DESC) AS rn,
    RANK()        OVER (PARTITION BY user_id ORDER BY trade_amount DESC) AS rnk,
    DENSE_RANK()  OVER (PARTITION BY user_id ORDER BY trade_amount DESC) AS dense_rnk
FROM trades;

-- Pattern: Top-1 per group using ROW_NUMBER (most common interview pattern)
WITH ranked AS (
    SELECT
        *,
        ROW_NUMBER() OVER (PARTITION BY user_id ORDER BY executed_at DESC) AS rn
    FROM trades
)
SELECT *
FROM ranked
WHERE rn = 1;

-- Pattern: Top-3 per group
WITH ranked AS (
    SELECT
        *,
        DENSE_RANK() OVER (PARTITION BY trading_pair ORDER BY trade_amount DESC) AS rnk
    FROM trades
)
SELECT *
FROM ranked
WHERE rnk <= 3;
```

## Gotchas

- **ROW_NUMBER non-determinism without ORDER BY**: When `ROW_NUMBER()` is used without an `ORDER BY` clause inside the `OVER()` clause, the assignment of numbers to rows is arbitrary and non-deterministic because the order is not guaranteed. This can lead to inconsistent results across query executions.
  **Fix:** Always specify an `ORDER BY` clause (e.g., `ORDER BY txn_date, txn_id`) to ensure a deterministic sequence.

- **RANK vs DENSE_RANK for top‑N per group**:
  - `RANK()` assigns the same rank to tied rows but leaves gaps in the ranking sequence (e.g., 1, 1, 3). If the interview question asks for "top 3 positions" (meaning rank values 1, 2, 3), use `DENSE_RANK()` because ties share a rank and the sequence is dense (1, 1, 2).
  - If the question asks for "top 3 rows" regardless of ties (i.e., exactly three rows), use `ROW_NUMBER()` with a tiebreaker to guarantee exactly three rows are returned.
  **Example:** To get the top 3 salespeople by quarterly sales, use `DENSE_RANK()` if you want all people at the top three rank levels (could be more than three people if ties). Use `ROW_NUMBER()` if you need exactly three rows.

- **PARTITION BY optional but important**: Omitting `PARTITION BY` treats the entire result set as a single partition, which may be unintentional when you need per‑group calculations (e.g., running total per customer).
  **Fix:** Always include `PARTITION BY` when the calculation should restart at boundaries (e.g., per user, per day). If you truly want a global calculation, you can omit it, but be explicit about intent.

## Edge Cases

### Edge 1-A: ROW_NUMBER non-determinism with tied ORDER BY

**Problem:**

```sql
-- When two rows have identical ORDER BY values, ROW_NUMBER assigns ranks arbitrarily
-- Running this query twice may return different rows as rn=1!

WITH latest AS (
    SELECT *,
        ROW_NUMBER() OVER (
            PARTITION BY user_id
            ORDER BY txn_date    -- DATE — multiple txns on same day are tied!
        ) AS rn
    FROM transactions
)
SELECT * FROM latest WHERE rn = 1;
-- On a given day, which transaction gets rn=1 is engine-defined (usually physical storage order)
-- In distributed engines (Spark, Presto): result can vary between runs!
```

**Fix — always add a unique tiebreaker:**

```sql
ORDER BY txn_date, txn_id     -- txn_id is unique → deterministic result
-- Or: ORDER BY txn_date, created_at  -- if txn_id isn't monotonic
```

### Edge 1-B: Missing PARTITION BY — entire table treated as one partition

**Problem:**

```sql
-- Appears to rank per user but actually ranks across ALL users globally
WITH ranked AS (
    SELECT *,
        DENSE_RANK() OVER (
            ORDER BY txn_amount DESC  -- no PARTITION BY!
        ) AS rnk
    FROM transactions
)
SELECT * FROM ranked WHERE rnk <= 3;
-- Returns the 3 highest transactions globally, NOT top 3 per user
```

**Fix — add PARTITION BY user_id:**

```sql
-- FIX: add PARTITION BY user_id:
DENSE_RANK() OVER (PARTITION BY user_id ORDER BY txn_amount DESC)
```

### Edge 1-C: RANK() vs DENSE_RANK() — wrong one for the business question

**Problem:**

```sql
-- Scores: 100, 90, 90, 80
-- ROW_NUMBER: 1, 2, 3, 4
-- RANK:       1, 2, 2, 4   ← gap at 3 (skips number after tie)
-- DENSE_RANK: 1, 2, 2, 3   ← no gap

-- BREAKS: "find the 3rd highest salary" using RANK
SELECT salary FROM (
    SELECT salary, RANK() OVER (ORDER BY salary DESC) AS rnk FROM employees
) t WHERE rnk = 3;
-- If two employees share salary rank 2 (tied), rank 3 is SKIPPED → zero rows returned!

-- CORRECT for "3rd distinct salary level":
DENSE_RANK() OVER (ORDER BY salary DESC)

-- CORRECT for "exactly 3rd row regardless of ties":
ROW_NUMBER() OVER (ORDER BY salary DESC, emp_id)  -- tiebreaker makes it deterministic
```

**Fix:**

```sql
-- For "find the 3rd distinct salary level" — use DENSE_RANK (no gaps on ties):
SELECT salary FROM (
    SELECT salary, DENSE_RANK() OVER (ORDER BY salary DESC) AS rnk FROM employees
) t WHERE rnk = 3;
-- DENSE_RANK: 100→1, 90→2, 90→2, 80→3 → correctly returns 80

-- For "find exactly the 3rd row regardless of ties" — use ROW_NUMBER with tiebreaker:
SELECT salary FROM (
    SELECT salary, ROW_NUMBER() OVER (ORDER BY salary DESC, emp_id ASC) AS rn FROM employees
) t WHERE rn = 3;
-- emp_id as tiebreaker makes the result deterministic
```

### Edge 1-D: QUALIFY with subquery injection (Snowflake-specific)

**Problem:**

```sql
-- QUALIFY is evaluated after SELECT — you can reference window function aliases
-- But QUALIFY doesn't exist in PostgreSQL/MySQL — cross-engine portability break

-- Works in Snowflake/BigQuery/DuckDB:
SELECT *, ROW_NUMBER() OVER (PARTITION BY user_id ORDER BY executed_at DESC) AS rn
FROM trades
QUALIFY rn = 1;

-- Breaks in PostgreSQL with: ERROR: syntax error at or near "QUALIFY"
-- Must use CTE approach for portable code
```

**Fix:**

```sql
-- Use a CTE wrapper for cross-engine portability instead of QUALIFY:
WITH ranked AS (
    SELECT *,
        ROW_NUMBER() OVER (PARTITION BY user_id ORDER BY executed_at DESC) AS rn
    FROM trades
)
SELECT * FROM ranked WHERE rn = 1;
-- Works in PostgreSQL, MySQL, SQL Server, Spark SQL, and engines that support QUALIFY
```

---

## At Scale

### Failure Mechanism

`ROW_NUMBER() OVER (PARTITION BY user_id ORDER BY executed_at DESC)` on 800M rows:

1. **Full shuffle** by `user_id` — all 800M rows hashed and redistributed across nodes
2. **Sort within each partition** — each node sorts its received rows: O(N log N) per partition
3. **Skew**: if 1% of users (power users) have 50% of transactions → 1 executor processes 400M rows while others idle

```sql

```sql
-- Reality check: 800M rows × 200 bytes = 160GB of data shuffled
-- Sort-merge within executor: 400M rows × log(400M) ≈ 400M × 29 = 11.6B comparisons
-- Wall time: 2+ hours on a 10-node cluster without fixes
```

#### Code-Level Fix

```sql
-- BEFORE: rank all 800M rows
WITH ranked AS (
    SELECT *,
        ROW_NUMBER() OVER (PARTITION BY user_id ORDER BY executed_at DESC) AS rn
    FROM transactions   -- 800M rows
)
SELECT * FROM ranked WHERE rn = 1;

-- FIX 1: Pre-filter to reduce data before windowing
WITH recent AS (
    SELECT * FROM transactions
    WHERE txn_date >= CURRENT_DATE - 90   -- 90-day window → 60M rows if uniform distribution
),
ranked AS (
    SELECT *, ROW_NUMBER() OVER (PARTITION BY user_id ORDER BY executed_at DESC) AS rn
    FROM recent
)
SELECT * FROM ranked WHERE rn = 1;
-- Shuffle volume: 60M instead of 800M → 13× faster

-- FIX 2: For "latest record per entity" — use aggregation + join instead of window function
-- Aggregation only requires a GROUP BY (cheaper than PARTITION BY + ORDER BY + sort)
SELECT t.*
FROM transactions t
JOIN (
    SELECT user_id, MAX(executed_at) AS latest_at
    FROM transactions
    WHERE txn_date >= CURRENT_DATE - 90
    GROUP BY user_id               -- GROUP BY is cheaper than PARTITION BY + ORDER BY
) latest ON t.user_id = latest.user_id AND t.executed_at = latest.latest_at;
-- Spark cost: GROUP BY requires ONE shuffle; window function requires ONE shuffle + sort
-- For "latest record" (no need to rank deeper): GROUP BY + join is typically 30-50% faster

-- FIX 3: Spark — handle skew explicitly
-- If user_id=U001 has 100M rows, that executor is the bottleneck
-- Use AQE skew join hint:
SET spark.sql.adaptive.skewJoin.enabled=true;
SET spark.sql.adaptive.skewJoin.skewedPartitionThresholdInBytes=256m;
-- AQE automatically splits skewed partitions
```

#### System-Level Fix

**Delta Lake (Databricks):**

```sql
-- Partition by date first to enable partition pruning:
CREATE TABLE transactions (
    txn_id      BIGINT,
    user_id     STRING,
    executed_at TIMESTAMP,
    amount      DECIMAL(15,2),
    txn_date    DATE GENERATED ALWAYS AS (CAST(executed_at AS DATE))
)
USING DELTA
PARTITIONED BY (txn_date)   -- prune to date range before windowing
TBLPROPERTIES (
    'delta.autoOptimize.optimizeWrite' = 'true',  -- merge small files on write
    'delta.autoOptimize.autoCompact'   = 'true'   -- background compaction
);

-- Z-order to co-locate by user_id within each date partition:
OPTIMIZE transactions ZORDER BY (user_id);
-- Within each daily partition: rows with same user_id are in contiguous files
-- ROW_NUMBER(PARTITION BY user_id): reads fewer files per user → less I/O per shuffle

-- Bloom filter for point lookups:
ALTER TABLE transactions SET TBLPROPERTIES (
    'delta.bloomFilter.columns' = 'user_id',
    'delta.bloomFilter.fpp' = '0.01'
);
```

**Pre-aggregation pattern (removes window function entirely at query time):**

```sql
-- Materialize a "latest transaction per user" table, updated incrementally:
CREATE OR REPLACE TABLE latest_txn_per_user
USING DELTA AS
SELECT t.*
FROM transactions t
JOIN (
    SELECT user_id, MAX(executed_at) AS latest_at
    FROM transactions GROUP BY user_id
) l ON t.user_id = l.user_id AND t.executed_at = l.latest_at;

-- Refresh incrementally (dbt incremental model):
-- strategy: merge on (user_id)
-- The full ROW_NUMBER scan never runs at query time — only at ETL time
```

```sql

---

---

