<!-- Part of sql-patterns: Query Plans — EXPLAIN, EXPLAIN ANALYZE, and Reading Execution Plans -->

# Query Plans Deep Dive — EXPLAIN, EXPLAIN ANALYZE, and Reading Execution Plans

## Why This Matters

Every SQL engine turns your text into an **execution plan** — a tree of physical operations with cost estimates. Reading that tree tells you:

- **Where** time is actually spent (which operator is the bottleneck)
- **Why** the optimizer made each decision (join type, index usage, row estimates)
- **What** to change to make it faster (index, statistics, query rewrite, warehouse size)

When an interviewer asks "how would you optimize this query?" the correct first answer is: *"I'd run EXPLAIN ANALYZE and look at the plan."*

---

## Part 1 — PostgreSQL

### 1.1 EXPLAIN Variants — Which to Use When

```sql
-- 1. Estimated plan only (free — no query execution)
EXPLAIN SELECT * FROM orders WHERE user_id = 42;

-- 2. Estimated + actual stats (executes the query — don't use on DML in prod without transaction)
EXPLAIN ANALYZE SELECT * FROM orders WHERE user_id = 42;

-- 3. Full diagnostics — actual stats + memory/disk I/O breakdown
EXPLAIN (ANALYZE, BUFFERS) SELECT * FROM orders WHERE user_id = 42;

-- 4. Machine-readable JSON — best for tooling and deep inspection
EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) SELECT * FROM orders WHERE user_id = 42;

-- 5. Safe way to run EXPLAIN ANALYZE on a write without committing
BEGIN;
EXPLAIN ANALYZE DELETE FROM orders WHERE user_id = 42;
ROLLBACK;  -- query ran but changes undone
```

### 1.2 Reading a Plain-Text Plan — Field by Field

```
Gather  (cost=1000.00..21341.50 rows=500 width=32)
        (actual time=15.213..122.501 rows=487 loops=1)
  Workers Planned: 2
  ->  Parallel Hash Join  (cost=100.00..21291.50 rows=209 width=32)
                          (actual time=12.011..119.834 rows=162 loops=3)
        Hash Cond: (o.user_id = u.user_id)
        ->  Parallel Seq Scan on orders o  (cost=0.00..20000.00 rows=...) ...
        ->  Hash  (cost=50.00..50.00 rows=4000 width=16) (actual ... rows=4000 loops=1)
              ->  Seq Scan on users u  (cost=0.00..50.00 rows=4000 width=16) ...
Planning Time: 1.234 ms
Execution Time: 125.119 ms
```

| Field | Example | What It Means |
|-------|---------|---------------|
| `cost=X..Y` | `cost=100.00..21291.50` | X = startup cost (to return 1st row), Y = total cost. Units are arbitrary but comparable |
| `rows=N` | `rows=209` | Optimizer's **estimated** output rows for this node |
| `width=W` | `width=32` | Estimated average row size in bytes |
| `actual time=A..B` | `actual time=12.011..119.834` | A = ms to first row, B = ms to last row (only with ANALYZE) |
| `actual rows=R` | `rows=162` | **Actual** rows returned — compare to estimated `rows=` |
| `loops=L` | `loops=3` | Node executed L times (e.g., once per worker, or once per outer row in nested loop). Multiply actual rows × loops for total rows |

**Reading direction:** Plans are read **bottom-up** — leaf nodes (Seq Scan, Index Scan) feed data upward into joins, aggregates, and sorts.

### 1.3 The Most Important Signal — Estimation Error

```
-- Estimation error: actual vs. planned rows diverge
-- Actual rows >> planned rows = UNDERESTIMATE (optimizer thought less data; bad plan)
-- Actual rows << planned rows = OVERESTIMATE (wasted memory, wrong join strategy)

Seq Scan on trades  (cost=0.00..5000.00 rows=100 width=64)
                    (actual time=0.018..340.211 rows=950000 loops=1)
--                                        ^^^                ^^^^^^
-- Planned 100, got 950,000 — 9500× off
-- Optimizer likely chose Nested Loop thinking 100 rows; Hash Join would be 100× faster
```

**When to suspect estimation error:** any node where `rows=` (planned) and `rows=` (actual) differ by more than 10×.

**Fix:** Run `ANALYZE <tablename>` to refresh statistics. For correlated columns, add extended stats:
```sql
CREATE STATISTICS s_order_user ON user_id, status FROM orders;
ANALYZE orders;
```

### 1.4 BUFFERS Output — Memory and I/O

```sql
EXPLAIN (ANALYZE, BUFFERS) SELECT * FROM orders WHERE user_id = 42;
```

```
Seq Scan on orders  (cost=0.00..5000.00 rows=100 width=64)
                    (actual time=0.018..340.211 rows=950000 loops=1)
  Buffers: shared hit=120 read=880 written=0
           temp read=450 written=450
```

| Buffer Field | Meaning | Red Flag |
|---|---|---|
| `shared hit=N` | Pages served from **buffer cache** (fast, in memory) | Low hits = poor cache utilization |
| `shared read=N` | Pages fetched from **disk** into cache | High reads = repeated disk I/O |
| `shared written=N` | Pages modified and written back | Unexpected writes = DML side effects |
| `temp read=N` / `temp written=N` | Pages written to **temp files** (disk spill) | **Any temp written > 0 = query spilled to disk** — increase `work_mem` |

```sql
-- Increase work_mem to reduce sort/hash spills (session-level — safe)
SET work_mem = '256MB';
EXPLAIN (ANALYZE, BUFFERS) SELECT * FROM orders ORDER BY user_id, created_at;
```

### 1.5 Scan Node Types — When Each Is Chosen

| Node | Optimizer Picks When | Performance Profile |
|------|---------------------|---------------------|
| **Seq Scan** | Full table needed, no useful index, or selectivity > ~5–15% | O(N) reads; sequential I/O is fast; always in the plan as a fallback |
| **Index Scan** | Selective WHERE clause with B-tree index; low-cardinality result | One index lookup + one heap access per row; good for <5% of rows |
| **Bitmap Index Scan + Bitmap Heap Scan** | Medium selectivity, multiple indexes, OR conditions | Batch: collect all matching TIDs from index, sort by heap location, access heap in physical order; fewer random reads |
| **Index Only Scan** | All needed columns are in the index (covering index) | Never touches heap; fastest possible for covered queries |

```sql
-- Create a covering index: user_id (filter) + amount, created_at (output)
-- Enables Index Only Scan — no heap reads at all
CREATE INDEX idx_orders_cover ON orders (user_id) INCLUDE (amount, created_at);
```

### 1.6 Join Node Types — When Each Is Chosen

| Join Type | Optimizer Chooses When | Cost Model | Limitations |
|-----------|----------------------|------------|-------------|
| **Nested Loop** | Small outer set + indexed inner table; non-equality joins | O(outer × inner_lookups) | Catastrophic if outer is large and inner lacks an index |
| **Hash Join** | Both large tables, equi-join, hash table fits in `work_mem` | O(inner build + outer probe); linear | Requires equality; spills to disk if hash > work_mem |
| **Merge Join** | Both inputs already sorted on join key (e.g., from index scans) | O(N + M) pass through both sides | Requires sorted input; expensive if a sort is needed first |

```sql
-- Forcing a join strategy (last resort — fix root cause instead)
SET enable_nestloop = off;    -- disable nested loop globally for session
SET enable_hashjoin = on;
SET enable_mergejoin = off;
```

**Red flag:** Nested Loop with `rows=` in millions in the outer → add an index on the inner join column or check for missing statistics.

### 1.7 Aggregate Node Types

| Node | When Used |
|------|-----------|
| **Aggregate** | Scalar functions (SUM, COUNT, MAX) over entire result |
| **Hash Aggregate** | GROUP BY when input is unsorted; builds hash table |
| **GroupAggregate** | GROUP BY when input is already sorted by group key; streaming |

```
HashAggregate  (cost=... rows=50 width=16)
               (actual time=... rows=50 loops=1)
  Group Key: user_id
  Batches: 1  Memory Usage: 640kB
--         ^^^^
-- "Batches: 1" = fit in memory; "Batches: 8" = spilled to disk 8 times
```

**Red flag:** `Batches > 1` in HashAggregate — the hash table spilled to disk. Fix: increase `work_mem`, pre-filter, or aggregate at coarser granularity first.

---

## Part 2 — Snowflake

### 2.1 EXPLAIN Variants

```sql
-- Text plan (compile-time estimate only — no execution)
EXPLAIN SELECT * FROM orders WHERE user_id = 42;

-- Tabular format — easiest to read as a human
EXPLAIN USING TABULAR SELECT * FROM orders WHERE user_id = 42;

-- JSON — machine-readable; parse with Python/JS for automation
EXPLAIN USING JSON SELECT * FROM orders WHERE user_id = 42;
```

**Key limitation:** Snowflake's EXPLAIN is **compile-time only** — it does not execute the query, so no actual row counts or bytes scanned are shown. For runtime stats, use the **Query Profile**.

### 2.2 Query Profile — Where to Find Real Bottlenecks

Access: Snowflake UI → History tab → click a query → "Query Profile" tab.

**Key metrics in the profile:**

| Metric | What It Means | Red Flag Threshold |
|--------|--------------|-------------------|
| **Partitions Scanned / Total** | Micro-partitions read vs. total | >50% scanned = poor partition pruning |
| **Bytes Scanned** | Data read from storage | Bytes >> result size = missing clustering |
| **Bytes Spilled (Local)** | Operator exceeded memory, wrote to SSD | Any spill = memory contention |
| **Bytes Spilled (Remote)** | Overflow past local SSD; wrote to cloud storage | Very expensive; resize warehouse or rewrite |
| **Bytes Sent Over Network** | Data shuffled between nodes | High shuffle = poor join strategy |
| **Operator Execution Time** | Wall-clock time per operator | Focus on the darkest/tallest operator node |

### 2.3 Reading the Snowflake Operator Tree

Operators from most common to least:

```
TableScan [orders]  →  Filter [user_id = 42]  →  JoinFilter  →  HashJoin  →  Aggregate  →  Result
```

| Operator | Meaning |
|----------|---------|
| `TableScan` | Full micro-partition scan; check "Partitions Scanned" |
| `Filter` | Predicate evaluation; look for "partition_filter" to confirm pruning |
| `HashJoin` | Hash-based equi-join; inner side is hashed |
| `NestedLoopJoin` | Row-by-row join; rare; usually indicates non-equi join or small tables |
| `Sort` | In-memory or spill-to-disk sort |
| `Aggregate` | GROUP BY computation |
| `EXPLODE` | Lateral flatten (for VARIANT/array columns) |

```sql
-- Diagnose partition pruning in EXPLAIN USING TABULAR
-- Look for "partition_filter" column — if it shows a predicate, pruning is active
-- If partition_filter = NULL, your WHERE clause isn't hitting the clustering key

-- Check clustering depth to understand if CLUSTER BY is effective
SELECT SYSTEM$CLUSTERING_INFORMATION('orders', '(DATE_TRUNC(''month'', created_at), user_id)');
-- Returns: average_depth (ideal: 1.0), average_overlaps (lower = better clustered)
```

### 2.4 Snowflake Query History via SQL

```sql
-- Find recent slow queries and their bytes scanned
SELECT 
    query_id,
    query_text,
    total_elapsed_time / 1000 AS elapsed_sec,
    bytes_scanned / 1e9       AS gb_scanned,
    partitions_scanned,
    partitions_total,
    bytes_spilled_to_local_storage / 1e6 AS mb_spilled_local,
    bytes_spilled_to_remote_storage / 1e6 AS mb_spilled_remote
FROM TABLE(INFORMATION_SCHEMA.QUERY_HISTORY_BY_USER(
    USER_NAME => CURRENT_USER(),
    RESULT_LIMIT => 100
))
ORDER BY total_elapsed_time DESC;
```

---

## Part 3 — BigQuery

### 3.1 Plan Access Methods

```sql
-- Dry-run: shows plan + bytes to be billed without running
-- Not via SQL — use bq CLI or console
bq query --dry_run 'SELECT * FROM project.dataset.orders WHERE DATE(created_at) = "2024-01-01"'

-- EXPLAIN in SQL (available in BigQuery since 2023)
EXPLAIN SELECT user_id, SUM(amount) FROM orders GROUP BY user_id;

-- After execution: check INFORMATION_SCHEMA
SELECT
    job_id,
    total_slot_ms,
    bytes_processed / 1e9  AS gb_processed,
    bytes_billed / 1e9     AS gb_billed,
    total_bytes_processed / bytes_billed AS compression_ratio
FROM `project.region-us.INFORMATION_SCHEMA.JOBS_BY_PROJECT`
WHERE creation_time > TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 1 DAY)
ORDER BY total_slot_ms DESC
LIMIT 20;
```

### 3.2 Stage-Based Plan Structure

BigQuery executes in **stages** (parallel workers) and **steps** (operations within a stage):

```
Stage S01: READ table, FILTER predicate, WRITE shuffle
Stage S02: READ shuffle, JOIN, WRITE shuffle
Stage S03: READ shuffle, AGGREGATE, WRITE result
```

**Key stage metrics:**

| Metric | Meaning | Red Flag |
|--------|---------|---------|
| **Records Read / Written** | Row counts per stage | Big drop in output rows = good filter; no drop = missing predicate |
| **Shuffle Bytes** | Data moving between stages | High shuffle = wide joins or inefficient aggregation |
| **Slot Time (ms)** | Compute cost; billable for reservations | Highest-slot-time stage is your bottleneck |
| **Wait Ratio** | Time waiting for slots | High wait = slot quota exhaustion |

**Partition pruning signal:**
```sql
-- Good: only 3 of 365 partitions scanned
-- Bad: all 365 partitions scanned despite a date filter

-- Confirm by checking console Execution Details:
-- "Input: 3 partitions" vs "Input: 365 partitions"
```

### 3.3 BigQuery Optimization via Plan Signals

```sql
-- 1. Check if partition column is actually used
-- BAD (function prevents pruning):
WHERE EXTRACT(YEAR FROM created_at) = 2024
-- GOOD (range on partition column):
WHERE created_at BETWEEN '2024-01-01' AND '2024-12-31'

-- 2. Clustering key effectiveness
-- If slot-time is high but bytes low: compute-bound (complex expressions)
-- If bytes-processed is high but slot-time is proportionate: scan-bound (missing clustering)
CREATE TABLE orders
PARTITION BY DATE(created_at)
CLUSTER BY user_id, status;

-- 3. Approximate counting to reduce slot time
-- Exact (expensive on 1B+ rows):
SELECT COUNT(DISTINCT user_id) FROM orders;
-- Approximate (HyperLogLog, ~1% error, 10–100× faster):
SELECT HLL_COUNT.EXTRACT(HLL_COUNT.INIT(user_id, 14)) FROM orders;
```

---

## Part 4 — Databricks / Apache Spark

### 4.1 EXPLAIN Modes

```python
# Python / PySpark
df.explain(mode="simple")      # Physical plan only
df.explain(mode="extended")    # Logical plan + analyzed plan + physical plan
df.explain(mode="formatted")   # Physical plan with operator details (best for debugging)
df.explain(mode="cost")        # Logical plan with cost estimates
df.explain(mode="codegen")     # Generated JVM bytecode per operator
```

```sql
-- SQL equivalent in Databricks / Spark SQL
EXPLAIN SELECT * FROM orders WHERE user_id = 42;
EXPLAIN FORMATTED SELECT * FROM orders WHERE user_id = 42;
```

### 4.2 Reading a Spark Physical Plan (Formatted)

```
== Physical Plan ==
AdaptiveSparkPlan isFinalPlan=true
+- == Final Plan ==
   HashAggregate(keys=[user_id#10], functions=[sum(amount#11)])  ← aggregate
   +- ShuffleQueryStage                                           ← shuffle boundary
      +- Exchange hashpartitioning(user_id#10, 200)              ← repartition for agg
         +- HashAggregate(keys=[user_id#10], functions=[partial_sum(amount#11)])
            +- Project [user_id#10, amount#11]
               +- Filter (isnotnull(status#12) AND (status#12 = active))  ← filter pushed down
                  +- FileScan parquet [user_id#10, amount#11, status#12]
                     Location: ...
                     PartitionFilters: [isnotnull(date_col#13), (date_col#13 = 2024-01-01)]  ← pruning active
                     PushedFilters: [IsNotNull(status), EqualTo(status,active)]             ← predicate pushed to storage
                     ReadSchema: struct<user_id:int,amount:double,status:string>
```

**Critical nodes to check:**

| Node | What to Check |
|------|--------------|
| `FileScan` | `PartitionFilters` — empty = no pruning; `PushedFilters` — pushed = efficient |
| `Exchange` | If present and large = shuffle happening; check for unnecessary shuffles |
| `BroadcastHashJoin` | Small table broadcast to all workers — optimal for small:large joins |
| `SortMergeJoin` | Both sides shuffled + sorted — used for large:large equi-joins |
| `BroadcastNestedLoopJoin` | No equi-join condition — often signals a missing or wrong join key (accidental cross join) |
| `Sort` | Sorting in memory; check for spills in Spark UI |

### 4.3 Broadcast vs SortMerge Join — The Key Decision

```python
# Default threshold: auto-broadcast tables < 10MB
spark.conf.set("spark.sql.autoBroadcastJoinThreshold", 104857600)  # raise to 100MB

# Force broadcast manually when optimizer misses it
from pyspark.sql.functions import broadcast
result = large_df.join(broadcast(small_df), "user_id")
```

```
-- In the physical plan:
BroadcastHashJoin [user_id], [user_id], Inner, BuildRight   ← BuildRight = right table broadcast
vs.
SortMergeJoin [user_id], [user_id], Inner                    ← both sides shuffled (expensive)
```

**Rule:** SortMergeJoin is fine for large:large joins. The issue is when an optimizer picks SortMergeJoin for a table that should have been broadcast — stale statistics cause this.

### 4.4 Data Skew Detection

```
-- Signs of skew in Spark UI:
-- Task Duration: most tasks finish in 2s, one task takes 300s
-- Partition Size: most partitions 50MB, one partition 5GB

-- In the physical plan (AQE enabled):
AdaptiveSparkPlan isFinalPlan=true
+- == Final Plan ==
   CustomShuffleReader task count: 50 (after skew handling)   ← AQE split skewed partitions
```

```python
# Enable AQE to automatically detect and handle skew
spark.conf.set("spark.sql.adaptive.enabled", "true")
spark.conf.set("spark.sql.adaptive.skewJoin.enabled", "true")
spark.conf.set("spark.sql.adaptive.skewJoin.skewedPartitionThresholdInBytes", "256m")

# Manual fix for known skew: salting (add random suffix before join, strip after)
from pyspark.sql.functions import concat, lit, col, rand, floor
large_df_salted = large_df.withColumn(
    "user_id_salted", concat(col("user_id"), lit("_"), (floor(rand() * 10)).cast("string"))
)
# Join on salted key, then aggregate to remove the salt
```

### 4.5 CTE Re-execution in Spark — Critical Trap

```sql
-- Spark CTEs are NOT materialised by default; each reference re-executes the CTE
WITH expensive_agg AS (
    SELECT user_id, SUM(amount) AS total FROM transactions GROUP BY user_id
    -- scans 1B rows
)
SELECT a.user_id, a.total, b.total AS prev_total
FROM expensive_agg a
JOIN expensive_agg b ON a.user_id = b.user_id AND ...;
-- Spark scans 1B rows TWICE

-- Fix: use a temp view or cache the result
CREATE OR REPLACE TEMP VIEW expensive_agg AS
    SELECT user_id, SUM(amount) AS total FROM transactions GROUP BY user_id;
-- Now reference the view twice — executed once, cached in memory
```

---

## Part 5 — Redshift

### 5.1 EXPLAIN Output Structure

```sql
EXPLAIN SELECT o.user_id, SUM(o.amount) 
FROM orders o JOIN users u ON o.user_id = u.user_id
WHERE o.order_date >= '2024-01-01'
GROUP BY o.user_id;
```

```
XN HashAggregate  (cost=500000.00..500000.50 rows=100 width=12)
  ->  XN Hash Join DS_DIST_NONE  (cost=50.00..499000.00 rows=400000 width=12)
        Hash Cond: (o.user_id = u.user_id)
        ->  XN Seq Scan on orders o  (cost=0.00..400000.00 rows=400000 width=12)
              Filter: (order_date >= '2024-01-01'::date)
        ->  XN Hash  (cost=30.00..30.00 rows=3000 width=4)
              ->  XN Seq Scan on users u  (cost=0.00..30.00 rows=3000 width=4)
```

**Distribution codes in the plan:**

| Code | Meaning | Performance Impact |
|------|---------|-------------------|
| `DS_DIST_NONE` | Collocated join — no data movement | Best; both tables distributed by join key |
| `DS_BCAST_INNER` | Inner table broadcast to all nodes | Good for small inner table |
| `DS_DIST_INNER` | Inner table redistributed | Moderate; only inner moves |
| `DS_DIST_OUTER` | Outer table redistributed | Moderate; only outer moves |
| `DS_DIST_BOTH` | Both tables redistributed | **Worst**; two full shuffles |
| `DS_DIST_ALL_NONE` | Inner uses DISTSTYLE ALL; no movement needed | Good for small dimension tables |

### 5.2 SVL_QUERY_SUMMARY — Runtime Analysis

```sql
-- Find disk spills and expensive steps
SELECT
    query,
    seg,
    step,
    label,
    maxtime,
    rows,
    bytes / 1e6 AS mb_processed,
    is_diskbased,  -- 't' = spilled to disk
    workmem / 1e6 AS mb_workmem
FROM svl_query_summary
WHERE query = 12345
ORDER BY maxtime DESC;

-- Find all queries that spilled to disk recently
SELECT DISTINCT query
FROM svl_query_summary
WHERE is_diskbased = 't'
  AND query IN (
    SELECT query FROM stl_query 
    WHERE starttime > DATEADD(hour, -1, CURRENT_TIMESTAMP)
  );
```

**Red flags in SVL_QUERY_SUMMARY:**
- `is_diskbased = 't'` for sort/hash/aggregate → increase `wlm_query_slot_count` or fix query
- `DS_DIST_BOTH` in EXPLAIN → add DISTKEY on join column
- High `maxtime` on a Broadcast step with large inner table → set DISTSTYLE ALL on dimension table if <100MB

---

## Part 6 — Universal Red Flags Reference

| Red Flag | Signal in Plan | Root Cause | Fix |
|----------|---------------|-----------|-----|
| **Row estimation error** | Actual rows >> estimated rows | Stale statistics; correlated columns | `ANALYZE`; extended statistics (PG); update table stats (Redshift) |
| **Sort spill** | `temp written > 0` (PG); `is_diskbased=t` on Sort (Redshift); spill in Snowflake profile | `work_mem` / sort buffer too small | Increase `work_mem`; add index on sort column; pre-sort in CTE |
| **Hash spill** | `Batches > 1` in HashAggregate (PG); bytes spilled (Snowflake/BQ) | Hash table > available memory | Increase memory; filter before hash; pre-aggregate |
| **Nested Loop on large table** | Nested Loop with outer rows in millions | No index on inner join column; bad join order | Add index on inner join col; fix statistics; force hash join |
| **Seq Scan on large table** | Seq Scan on >500MB table with selective WHERE | Missing index; function on indexed col; poor stats | Add index; remove function wrap; `ANALYZE` |
| **Partition pruning failure** | All partitions scanned despite date filter | WHERE on function of partition col; type mismatch | Use range predicate directly on partition col; match data types |
| **Full table shuffle** | `DS_DIST_BOTH` (Redshift); Exchange on all rows (Spark) | Join key ≠ distribution key | Add DISTKEY/SORTKEY on join column; enable AQE |
| **Cartesian product** | Nested Loop / BroadcastNestedLoop with no join cond | Missing ON clause; typo in join key | Add proper ON condition; check for implicit cross joins |
| **Correlated subquery** | Subquery runs once per row of outer | Subquery references outer column | Rewrite as window function or CTE with join |
| **CTE double-execution (Spark)** | Same CTE scan appears twice in plan | Spark inlines CTEs; no implicit materialisation | Convert to TEMP VIEW or cache DataFrame |

---

## Part 7 — Interview Framework — "How Would You Optimize This Query?"

Use this 5-step framework when asked to optimize a slow query:

### Step 1 — Run the Plan First

```sql
-- PostgreSQL
EXPLAIN (ANALYZE, BUFFERS) <query>;

-- Snowflake
-- Execute query → History tab → Query Profile

-- Databricks
EXPLAIN FORMATTED <query>;   -- or df.explain("formatted")

-- BigQuery
-- Check Execution Details in console; or query INFORMATION_SCHEMA.JOBS
```

> *"Before changing anything, I'd run EXPLAIN ANALYZE to see where time is actually spent. Guessing is expensive — I want data first."*

### Step 2 — Identify the Bottleneck Node

Look for:
- **Highest actual time** (PostgreSQL)
- **Highest slot-time operator** (BigQuery — darkest node in execution graph)
- **Largest "Bytes Scanned"** (Snowflake)
- **Longest task** (Spark UI)

### Step 3 — Diagnose Root Cause

| Observation | Root Cause |
|-------------|-----------|
| Estimated rows << actual rows | Stale statistics → run ANALYZE |
| All partitions scanned | WHERE clause not on partition key, or type mismatch |
| Sort/hash spill to disk | Insufficient memory → increase work_mem or warehouse size |
| SortMergeJoin on large:small tables | Optimizer doesn't know table is small → update stats or hint broadcast |
| Correlated subquery executing 1M times | Subquery not decorrelated → rewrite as window function |

### Step 4 — Propose Specific Fixes

```sql
-- Fix 1: Add index on selective WHERE column
CREATE INDEX idx_orders_user_date ON orders (user_id, order_date);

-- Fix 2: Refresh statistics (PostgreSQL)
ANALYZE orders;
-- Fix 2b: Snowflake — statistics are automatic; check if clustering is fresh
ALTER TABLE orders RESUME RECLUSTER;

-- Fix 3: Force partition pruning — remove functions from partition col
-- BAD:
WHERE YEAR(order_date) = 2024
-- GOOD:
WHERE order_date >= '2024-01-01' AND order_date < '2025-01-01'

-- Fix 4: Replace correlated subquery with window function
-- BAD (N subquery executions):
SELECT user_id, 
       (SELECT MAX(amount) FROM orders o2 WHERE o2.user_id = o1.user_id)
FROM orders o1;
-- GOOD (single pass):
SELECT user_id, MAX(amount) OVER (PARTITION BY user_id) FROM orders;

-- Fix 5: Replace NOT IN with anti-join pattern (avoids NULL trap + enables hash join)
-- BAD:
WHERE user_id NOT IN (SELECT user_id FROM blocked_users)
-- GOOD:
WHERE NOT EXISTS (SELECT 1 FROM blocked_users b WHERE b.user_id = orders.user_id)
```

### Step 5 — Explain Trade-Offs

> *"Adding an index speeds reads but slows writes. I'd check the write volume first — if it's a reporting table with rare inserts, an index is clearly worth it. If it's a high-throughput OLTP table, I'd consider a covering index on a replica instead."*

---

## Part 8 — Quick Reference Cheat Sheet

### PostgreSQL EXPLAIN Cheat Sheet

```sql
-- Minimal (estimate only)
EXPLAIN SELECT ...;

-- Full diagnostics
EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) SELECT ...;

-- Key signals:
-- actual rows >> planned rows = stale stats → ANALYZE tablename
-- temp written > 0 = disk spill → SET work_mem = '256MB'
-- Nested Loop with large outer = missing index on inner join col
-- Seq Scan on large table = check if index exists and predicate is SARGable
```

### Snowflake Cheat Sheet

```sql
-- Plan (compile-time)
EXPLAIN USING TABULAR SELECT ...;

-- Runtime: History → Query Profile → look for:
-- Partitions Scanned/Total > 50% = missing partition pruning
-- Bytes Spilled (any) = memory pressure → upsize warehouse or rewrite
-- Long operator bar = bottleneck → optimize that node first

-- Post-execution history
SELECT query_id, total_elapsed_time, bytes_scanned, partitions_scanned, partitions_total
FROM TABLE(INFORMATION_SCHEMA.QUERY_HISTORY_BY_USER()) ORDER BY total_elapsed_time DESC;
```

### Databricks/Spark Cheat Sheet

```python
# Best mode for debugging
df.explain("formatted")

# Key signals:
# FileScan with empty PartitionFilters = no pruning → add WHERE on partition col
# SortMergeJoin where one table is small = missing broadcast → hint or raise threshold
# Exchange with large rows = unnecessary shuffle → check join key distribution
# BroadcastNestedLoopJoin = accidental cross join → add join condition

# Settings
spark.conf.set("spark.sql.adaptive.enabled", "true")          # enable AQE
spark.conf.set("spark.sql.autoBroadcastJoinThreshold", 1e8)   # broadcast up to 100MB
```

### BigQuery Cheat Sheet

```sql
-- Plan estimate
EXPLAIN SELECT ...;

-- Post-execution: INFORMATION_SCHEMA
SELECT job_id, total_slot_ms, bytes_processed / 1e9 AS gb, bytes_billed / 1e9 AS gb_billed
FROM `region-us.INFORMATION_SCHEMA.JOBS_BY_PROJECT`
ORDER BY total_slot_ms DESC;

-- Key signals:
-- GB billed >> GB in result = poor partitioning/clustering
-- High shuffle bytes between stages = join on non-partitioned columns
-- High slot-time in one stage = compute bottleneck → check for missing filter pushdown
```

### Redshift Cheat Sheet

```sql
-- Compile-time plan
EXPLAIN SELECT ...;

-- Runtime analysis
SELECT query, step, label, maxtime, bytes, is_diskbased
FROM svl_query_summary WHERE query = <id> ORDER BY maxtime DESC;

-- Key signals:
-- DS_DIST_BOTH = both tables redistributed → add DISTKEY on join col
-- is_diskbased = 't' = spill → increase WLM memory or fix query
-- DS_BCAST_INNER on large table = wrong strategy → set DISTSTYLE on that table
```

---

## Part 9 — Engine-Specific Tools Summary

| Tool | Engine | What It Does |
|------|--------|-------------|
| `EXPLAIN (ANALYZE, BUFFERS)` | PostgreSQL | Full query plan with actual timing and I/O |
| `pg_stat_statements` | PostgreSQL | Query-level aggregates: calls, total time, mean time |
| `auto_explain` | PostgreSQL | Auto-logs slow query plans to PostgreSQL log |
| pgBadger | PostgreSQL | Parses log files into HTML report of slow queries |
| Query Profile | Snowflake | UI operator tree with bytes, spills, partition stats |
| `INFORMATION_SCHEMA.QUERY_HISTORY` | Snowflake | Historical query metrics via SQL |
| Execution Details / Graph | BigQuery | Visual DAG of stages with slot-time heatmap |
| `INFORMATION_SCHEMA.JOBS` | BigQuery | Historical job metrics: slots, bytes, duration |
| Spark UI / Query Profile | Databricks | Task-level timing, shuffle metrics, AQE decisions |
| `df.explain("formatted")` | Spark | Physical plan with filter pushdown and join strategy |
| `SVL_QUERY_SUMMARY` | Redshift | Per-step runtime stats: rows, bytes, spills |
| `STL_EXPLAIN` | Redshift | Stored historical EXPLAIN output per query ID |

---

*See also: [41-performance-optimisation.md](41-performance-optimisation.md) for query writing rules | [49-at-scale-patterns.md](49-at-scale-patterns.md) for distributed scale patterns | [50-partition-sort-keys-1.md](50-partition-sort-keys-1.md) for physical layout design*
