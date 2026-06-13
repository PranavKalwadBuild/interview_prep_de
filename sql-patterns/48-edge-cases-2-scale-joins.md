<!-- Part of sql-patterns: Edge Case Detection (Part 2) + Breaking at Scale — JOINs -->
<!-- Source: sql_patterns.md lines 12601–12929 -->


### 33-21. Set Operations Edge Cases

> Full detail in [Pattern 21 — Set Operations → Edge Cases](#21-set-operations-union--intersect--except).
> Critical: `UNION ALL` retains duplicates; `NOT IN` with NULLs in `EXCEPT` returns no rows.

---

### 33-22. Anti-Join Edge Cases

> Full detail in [Pattern 22 — Anti-Join → Edge Cases](#22-anti-join-pattern).
> Critical: `NOT IN` with NULLs in subquery returns no rows — always use `NOT EXISTS` or `LEFT JOIN ... IS NULL`.

---

### 33-23. Percentile and Histogram Edge Cases

> Full detail in [Pattern 23 — Percentiles → Edge Cases](#23-percentiles--histograms).
> Critical: `PERCENTILE_CONT` interpolates; `PERCENTILE_DISC` picks actual value — different results.

---

### 33-24. Running Totals Edge Cases

> Full detail in [Pattern 24 — Running Totals → Edge Cases](#24-running-totals--cumulative-metrics).
> Critical: running total resets at partition boundary; `RANGE` frame sums all ties, inflating cumulative values.

---

### 33-25. Market Basket / Co-occurrence Edge Cases

> Full detail in [Pattern 25 — Market Basket → Edge Cases](#25-market-basket--co-occurrence).
> Critical: self-join produces `(A,B)` and `(B,A)` — use `t1.item < t2.item` to deduplicate pairs.

---

### 33-26. Median and Mode Edge Cases

> Full detail in [Pattern 26 — Median & Mode → Edge Cases](#26-median--mode).
> Critical: even-count median averages two middle values; mode returns multiple rows on tie.

---

### 33-27. NTILE Edge Cases

> Full detail in [Pattern 27 — NTILE → Edge Cases](#27-ntile--bucketing).
> Critical: `NTILE` distributes remainder rows to earlier buckets — bucket sizes not equal with indivisible N.

---

### 33-28. Latest Record per Entity Edge Cases

> Full detail in [Pattern 28 — Latest Record per Entity → Edge Cases](#28-latest-record-per-entity-point-in-time).
> Critical: `MAX(timestamp)` + rejoin loses columns if multiple rows share max timestamp.

---

### 33-29. Gaps in Sequential IDs Edge Cases

> Full detail in [Pattern 29 — Gaps in Sequential IDs → Edge Cases](#29-gaps-in-sequential-ids).
> Critical: `NOT IN` gap detection is O(N²) — use LAG window approach instead.

---

### 33-30. Query Performance Edge Cases

> Full detail in [Pattern 30 — Performance → Edge Cases](#30-performance--query-optimisation-patterns).
> Critical: N+1 query pattern from SELECT in loop; missing index forces full scan.

---

### 33-31. Date Function Edge Cases

> Full detail in [Pattern 31 — Date Functions → Edge Cases] (see Section M: Date Functions).
> Critical: `DATE_TRUNC` timezone mismatch; `DATEDIFF` ignores time component; `ADD_MONTHS` month-end edge cases.

---

### 33-99. Edge Case Master Diagnostic Checklist

Use this checklist before declaring any SQL query production-ready:

```sql
JOIN SAFETY
□ Does every JOIN have an ON/USING clause? (prevent accidental CROSS JOIN)
□ Are there any LEFT JOINs with WHERE filters on the right table? (silently becomes INNER JOIN)
□ Could any JOIN key column be NULL? (NULL keys never match — is that intended?)
□ Could the right table in the JOIN have duplicates on the join key? (fanout risk)
□ Is the fact-to-dimension join potentially a many-to-many? (SCD2 overlap, multi-version)

NULL SAFETY
□ Does any WHERE/HAVING condition use = NULL or != NULL? (must be IS NULL / IS NOT NULL)
□ Does any NOT IN subquery use a column that can contain NULL? (poison — use NOT EXISTS)
□ Are all arithmetic expressions that include NULLable columns protected with COALESCE?
□ Does any CASE WHEN condition use = NULL? (must be IS NULL)
□ Is IS DISTINCT FROM used for NULL-safe change detection in SCD2 / CDC logic?

WINDOW FUNCTION SAFETY
□ Does every window function have an explicit ORDER BY? (without it, result is non-deterministic)
□ Does every ROW_NUMBER / RANK have a tiebreaker in ORDER BY? (prevent non-deterministic dedup)
□ Is the frame clause explicit for all SUM/AVG/MIN/MAX window functions? (avoid default RANGE trap)
□ Does LAST_VALUE have ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING? (default frame cuts early)

AGGREGATION SAFETY
□ Are all COUNT() conditional aggregations using ELSE NULL (not ELSE 0)? (ELSE 0 counts all rows)
□ Is AVG() denominator behaviour understood? (excludes NULLs — may not equal SUM/COUNT(*))
□ Is every divide-by-zero protected with NULLIF or CASE WHEN denominator = 0?
□ Are non-additive measures (rates, averages of averages) computed correctly (SUM/SUM not AVG)?

DATE SAFETY
□ Are all timestamp comparisons using half-open intervals (>= start AND < end) not BETWEEN?
□ Are date spines complete (include leap days, no gaps)?
□ Is DATEDIFF argument order correct for the target engine?
□ Are all timestamps stored in UTC and converted at display layer only?
□ Is timezone conversion applied BEFORE DATE_TRUNC for user-timezone reporting?

DEDUPLICATION SAFETY
□ Does every dedup ROW_NUMBER have a tiebreaker that makes it deterministic?
□ Are the dedup key columns free of NULLs? (NULLs never match each other in PARTITION BY)
□ Is the hash key including all business-meaningful columns (not audit columns)?

SCD2 SAFETY
□ Is valid_to IS NULL used for current records (not valid_to >= CURRENT_DATE)?
□ Could a fact record fall in a gap between two SCD2 versions? (point-in-time coverage check)
□ Is IS DISTINCT FROM used to detect changes (handles NULL old/new values correctly)?
□ Could same-day changes cause multiple versions with identical valid_from? (fan-out risk)

ANTI-JOIN SAFETY
□ Is NOT IN used with a subquery? → Add WHERE col IS NOT NULL to the subquery
□ Is NOT EXISTS correlated to the outer query? → Verify the WHERE clause links inner to outer

SET OPERATION SAFETY
□ Is UNION or UNION ALL the correct choice for this query? (accidental dedup or double-count)
□ Do both sides of UNION have the same number of columns and compatible types?

PERFORMANCE SAFETY
□ Is there any function applied to a partition column in WHERE? (prevents partition pruning)
□ Is a CTE referenced multiple times in Spark? (may be re-executed multiple times)
□ Is COUNT(DISTINCT) on a very large column? (consider APPROX_COUNT_DISTINCT for exploration)
□ Is there a CROSS JOIN anywhere? (verify row count = expected N × M, not N × 1)
```sql

---

## 34. Breaking at Scale — System-Level and Code-Level Fixes per Pattern

Every SQL pattern that works on 10,000 rows breaks differently at 500M rows. This section covers the *exact* failure mechanism for each pattern, the code fix, and the storage/infrastructure changes that prevent the problem from ever materialising. All examples target Slice-style fintech workloads: UPI transactions, loan disbursements, KYC events, settlement records.

Scale tiers referenced:

- **Medium:** 10M–100M rows — single-node engines start straining
- **Large:** 100M–1B rows — distributed engines required
- **XL:** 1B+ rows — partitioning and pre-aggregation mandatory

---

### Scale Vocabulary

| Term | What it means |
|------|---------------|
| **Shuffle** | Redistributing rows across all nodes by a key (GROUP BY, JOIN, PARTITION BY) — the #1 bottleneck in distributed SQL |
| **Data skew** | One partition holds 90% of rows (e.g., all UPI transactions in `state = 'MH'`) — one executor does all the work |
| **Partition pruning** | Engine reads only the partitions that satisfy a WHERE filter — avoids reading the rest |
| **Micro-partition** | Snowflake's 16MB column-store file unit — CLUSTER BY aligns data so fewer micro-partitions are scanned |
| **File explosion** | Thousands of tiny Parquet/Delta files from streaming or over-partitioning — each file has per-file overhead |
| **Broadcast join** | Copy the smaller table to every node — eliminates shuffle for the large table |
| **AQE** | Adaptive Query Execution (Spark 3.x) — runtime re-optimisation of join strategy, skew handling, partition coalescing |
| **Z-order** | Multi-dimensional data-skipping in Delta Lake — co-locates correlated columns within Parquet files |
| **Liquid Clustering** | Delta Lake 3.0 successor to PARTITION BY + ZORDER — incremental, mutually exclusive with partitioning |

---

### 34-0. JOINs at Scale

#### Failure Mechanism

A large-to-large JOIN (both tables >100M rows) triggers a **shuffle join**: every row from both tables must be hashed and sent to the correct executor node. With 500M transactions joined to 50M users, that's 550M rows moving across the network.

**Additional failure modes:**

- Fan-out: dimension table has duplicate keys → fact table multiplied
- Cartesian explosion: missing ON clause in Spark → N × M rows
- Broadcast threshold: small table is 500MB — above the auto-broadcast limit, triggers expensive sort-merge join

```sql
-- Scale trigger: transactions (800M rows) × users (50M rows) = shuffle of 850M rows
-- At 200 bytes/row: 170GB of network I/O just for the shuffle
-- Time: 45+ minutes without optimisation
```

#### Code-Level Fix

```sql
-- BEFORE: naive join — full shuffle
SELECT t.txn_id, t.amount, u.kyc_tier
FROM transactions t
JOIN users u ON t.user_id = u.user_id
WHERE t.txn_date >= '2024-01-01';

-- FIX 1: Filter BEFORE the join (push predicates — reduce shuffle volume)
WITH recent_txns AS (
    SELECT txn_id, user_id, amount, txn_date
    FROM transactions
    WHERE txn_date >= '2024-01-01'   -- partition-pruned first: 30M rows, not 800M
),
active_users AS (
    SELECT user_id, kyc_tier
    FROM users
    WHERE is_active = TRUE            -- 20M rows, not 50M
)
SELECT t.txn_id, t.amount, u.kyc_tier
FROM recent_txns t
JOIN active_users u ON t.user_id = u.user_id;
-- Shuffle volume: 30M + 20M = 50M rows instead of 850M

-- FIX 2: Broadcast the small dimension (Spark / Hive hint)
SELECT /*+ BROADCAST(u) */
    t.txn_id, t.amount, u.kyc_tier
FROM transactions t
JOIN users u ON t.user_id = u.user_id;
-- users table (50M × 50 bytes = ~2.5GB) is broadcast to all executors
-- transactions table: zero shuffle, local lookup only
-- Only use if users fits in executor memory

-- FIX 3: Snowflake — no hint needed; uses automatic join optimization
-- Snowflake automatically uses broadcast for smaller tables (configurable threshold)

-- FIX 4: Detect fan-out before joining
SELECT user_id, COUNT(*) AS cnt FROM users GROUP BY user_id HAVING cnt > 1;
-- If this returns rows: join will fan out — dedup users table first
WITH deduped_users AS (
    SELECT DISTINCT ON (user_id) * FROM users ORDER BY user_id, updated_at DESC
)
SELECT t.*, u.kyc_tier FROM transactions t JOIN deduped_users u ON t.user_id = u.user_id;
```

#### System-Level Fix

**Delta Lake / Databricks:**

```sql
-- Co-locate transactions and users on user_id using bucketing (Hive/Spark)
-- Bucketed tables: rows with same user_id go to the same bucket file → no shuffle on join
CREATE TABLE transactions
USING DELTA
PARTITIONED BY (txn_date)    -- date partition for time-range pruning
CLUSTERED BY (user_id) INTO 200 BUCKETS  -- bucket join eliminates shuffle
LOCATION 's3://data/transactions';

CREATE TABLE users
USING DELTA
CLUSTERED BY (user_id) INTO 200 BUCKETS  -- same number of buckets → bucket join!
LOCATION 's3://data/users';

-- After bucketing: transactions JOIN users on user_id → NO shuffle
-- Each executor reads its matching bucket from both tables locally

-- Z-ORDER for multi-column access patterns:
OPTIMIZE transactions ZORDER BY (user_id, txn_date);
-- Rows with same user_id + nearby txn_date land in the same Parquet file
-- Query: WHERE user_id = 'U001' AND txn_date >= '2024-01-01' → reads ~2 files instead of 200
```

**Snowflake:**

```sql
-- Cluster transactions table on (user_id, txn_date) for join + time-range queries
ALTER TABLE transactions CLUSTER BY (user_id, DATE_TRUNC('month', txn_date));
-- Snowflake automatically maintains micro-partition overlap metric
-- When overlap > 0.5, trigger: ALTER TABLE transactions RECLUSTER;

-- Search Optimization: for point lookups (WHERE user_id = :id)
ALTER TABLE users ADD SEARCH OPTIMIZATION ON EQUALITY(user_id);
-- Sub-second lookup instead of scanning all micro-partitions

-- Materialized view: pre-join user dimension to transaction facts
CREATE OR REPLACE MATERIALIZED VIEW mv_txn_with_tier AS
SELECT t.txn_id, t.user_id, t.amount, t.txn_date, u.kyc_tier, u.risk_band
FROM transactions t
JOIN users u ON t.user_id = u.user_id;
-- Snowflake automatically refreshes this when either base table changes
-- Queries hitting this MV: zero join cost, pre-computed
```

**BigQuery:**

```sql
-- Partition transactions by DATE, cluster by user_id:
CREATE OR REPLACE TABLE transactions
PARTITION BY DATE(txn_date)
CLUSTER BY user_id, merchant_id
AS SELECT * FROM raw_transactions;

-- BigQuery billing: partitioned + clustered table scan = 95% less data billed
-- vs. unpartitioned full scan

-- For the dimension join: denormalize into the fact table at ingestion time
-- (BigQuery is a columnar MPP — denormalization is preferred over joining at query time)
-- Store kyc_tier in the transactions table directly, update via merge when it changes
```

**Redshift:**

```sql
-- Distribution key: use user_id to co-locate transactions with users on same node
CREATE TABLE transactions (
    txn_id      BIGINT,
    user_id     BIGINT,
    amount      DECIMAL(15,2),
    txn_date    DATE,
    status      VARCHAR(20)
)
DISTSTYLE KEY
DISTKEY (user_id)           -- all rows with same user_id go to same node
COMPOUND SORTKEY (txn_date, user_id);  -- prune by date first, then by user within date
-- transactions × users JOIN: data already co-located by user_id → zero redistribution

CREATE TABLE users (
    user_id     BIGINT,
    kyc_tier    VARCHAR(10)
)
DISTSTYLE KEY
DISTKEY (user_id);          -- same distkey = co-located join: zero network traffic
-- OR for small dimensions:
DISTSTYLE ALL;              -- full copy to every node → broadcast join always available
```sql

---

