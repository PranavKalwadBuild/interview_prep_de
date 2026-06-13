<!-- Part of sql-patterns: Partition Keys, Cluster Keys, Sort Keys — Mental Model and Partition Key Deep Dive -->
<!-- Source: sql_patterns.md lines 13164–13441 -->

## 35. Partition Keys, Cluster Keys, and Sort Keys — The Complete Guide

> **Scope:** Platform-independent concepts first. Engine-specific syntax at the end.  
> **Goal:** Understand WHY each mechanism exists, HOW each works physically, when to use which, and how to choose the right columns for any given table.

---

### 35-0. Mental Model — What Problem Each Solves

Before touching syntax, understand the three distinct problems these solve:

| Key Type | Problem it solves | Physical effect |
|---|---|---|
| **Partition Key** | Reading the entire table when you only need a slice | Files/segments for subset X live separately from files for subset Y — the engine skips entire files |
| **Sort / Cluster Key** | Scanning every row within a file to find matching rows | Rows are physically ordered so the engine can skip ranges of rows within a file |
| **Distribution Key** (Redshift DISTKEY / Hive bucketing) | Two large tables shuffling all their data across the network to join | Rows with the same key land on the same node — join becomes local, no shuffle |

These are **orthogonal** — you can (and often should) set all three independently.

```sql
Without ANY key:
  Query: WHERE event_date = '2025-01-15' AND user_id = 42
  → Full table scan: read 500GB, process 2 billion rows

With partition_key = event_date:
  → Partition pruning: read only Jan-15 partition = 1.6GB

With sort/cluster key = user_id within each partition:
  → Row-level skip: within that 1.6GB file, jump to user 42's rows

With dist key = user_id (Redshift) or bucketing on user_id (Hive/Delta):
  → Co-located join: JOIN with users table costs zero network shuffle
```sql

---

### 35-1. Partition Key — Deep Dive

#### What partitioning physically does

Partitioning splits a table's data into separate physical directories or file groups based on a column value. The engine writes a metadata layer that maps "partition X → file paths Y, Z, W". At query time, the planner reads the metadata and skips entire file groups.

```

Table: upi_transactions (500GB)

Without partitioning:
  storage/upi_transactions/
    part-000.parquet  (5GB)
    part-001.parquet  (5GB)
    ...100 files...

With PARTITION BY event_date:
  storage/upi_transactions/
    event_date=2025-01-01/
      part-000.parquet  (1.6GB)
    event_date=2025-01-02/
      part-000.parquet  (1.6GB)
    ...365 directories...

```

A `WHERE event_date = '2025-01-15'` query touches **one directory** instead of 100 files. This is called **partition pruning**.

#### The three types of partition strategies

**Range partitioning** — rows go into buckets based on value ranges. Most common for time-series data.

```sql
-- PostgreSQL
CREATE TABLE upi_transactions (
    txn_id      BIGINT,
    user_id     BIGINT,
    amount      DECIMAL(18,2),
    event_date  DATE,
    status      VARCHAR(20)
) PARTITION BY RANGE (event_date);

CREATE TABLE upi_transactions_2025_q1 PARTITION OF upi_transactions
    FOR VALUES FROM ('2025-01-01') TO ('2025-04-01');

CREATE TABLE upi_transactions_2025_q2 PARTITION OF upi_transactions
    FOR VALUES FROM ('2025-04-01') TO ('2025-07-01');

-- Databricks / Delta Lake
CREATE TABLE upi_transactions
    USING DELTA
    PARTITIONED BY (event_date)
AS SELECT * FROM raw_transactions;
```

**List partitioning** — rows go into buckets based on exact discrete values. Good for region, status, or category.

```sql
-- PostgreSQL
CREATE TABLE loan_applications (
    loan_id   BIGINT,
    user_id   BIGINT,
    amount    DECIMAL(18,2),
    region    VARCHAR(20)
) PARTITION BY LIST (region);

CREATE TABLE loan_applications_north PARTITION OF loan_applications
    FOR VALUES IN ('NORTH', 'NORTHEAST');

CREATE TABLE loan_applications_south PARTITION OF loan_applications
    FOR VALUES IN ('SOUTH', 'SOUTHEAST');

-- Delta Lake / BigQuery equivalent: use a low-cardinality string column
PARTITIONED BY (region)
```

**Hash partitioning** — rows go into N buckets based on a hash of the key. Used when no natural range exists and you want even distribution for parallel writes/reads.

```sql
-- PostgreSQL hash partitioning
CREATE TABLE kyc_documents (
    doc_id    BIGINT,
    user_id   BIGINT,
    doc_type  VARCHAR(50)
) PARTITION BY HASH (user_id);

CREATE TABLE kyc_documents_p0 PARTITION OF kyc_documents
    FOR VALUES WITH (MODULUS 4, REMAINDER 0);
CREATE TABLE kyc_documents_p1 PARTITION OF kyc_documents
    FOR VALUES WITH (MODULUS 4, REMAINDER 1);
CREATE TABLE kyc_documents_p2 PARTITION OF kyc_documents
    FOR VALUES WITH (MODULUS 4, REMAINDER 2);
CREATE TABLE kyc_documents_p3 PARTITION OF kyc_documents
    FOR VALUES WITH (MODULUS 4, REMAINDER 3);

-- Hive/Spark bucketing (covered separately in 35-4)
```

#### Partition pruning — how the engine skips partitions

```sql
-- This triggers partition pruning (reads 1 of 365 partitions):
SELECT SUM(amount)
FROM upi_transactions
WHERE event_date = '2025-01-15';

-- This ALSO triggers partition pruning (range = multiple consecutive partitions):
SELECT SUM(amount)
FROM upi_transactions
WHERE event_date BETWEEN '2025-01-01' AND '2025-01-31';

-- This DEFEATS partition pruning — function call prevents static evaluation:
SELECT SUM(amount)
FROM upi_transactions
WHERE YEAR(event_date) = 2025;          -- Databricks
-- OR:
WHERE DATE_TRUNC('year', event_date) = '2025-01-01';  -- full scan!

-- CORRECT form for yearly filter:
WHERE event_date >= '2025-01-01' AND event_date < '2026-01-01';
```

**Why functions defeat pruning:** The planner evaluates partition eligibility at compile time. `YEAR(event_date) = 2025` requires applying the function to every partition's column value — the planner can't know which partitions satisfy it without reading them.

#### Partition granularity — too coarse vs too fine

```
Too coarse (monthly for 5-year table):
  60 partitions, each 8GB
  → Jan 2025 query reads 8GB, processes entire month's files
  → Acceptable if you always query full months

Too fine (hourly for high-volume table):
  43,800 partitions over 5 years
  → "Small file problem": each partition has 20MB files
  → Metadata overhead kills planning time
  → Compaction required (OPTIMIZE / VACUUM)

Sweet spot for UPI transactions at 1M txn/day:
  Daily partitions: 365 × ~1.6GB = manageable
  Monthly partitions: 60 × ~50GB = coarser but faster for MoM queries
  → Choose daily if most queries filter to 1-7 days
  → Choose monthly if most queries aggregate over months
```

#### Partition column cardinality rule of thumb

| Cardinality | Use partitioning? | Notes |
|---|---|---|
| 10–100K unique values (dates over years) | Yes — ideal | Each partition is a meaningful data slice |
| 100K–10M unique values (user_id) | No — use bucketing instead | Too many tiny files; metadata explosion |
| 2–50 values (region, status, tier) | Yes with caution | Only if queries filter by this column |
| Unbounded string (free text) | Never | Non-deterministic, infinite partitions |

---

### 35-2. Sort Key / Order Key — Deep Dive

#### What sorting physically does

Within each file (or within each partition), rows are written in sorted order by the sort key. The engine stores **min/max statistics** (called zone maps, small file stats, or column statistics) for each file chunk. At query time, a range predicate like `WHERE amount > 10000` can skip entire file chunks whose max value is below 10000.

```
File chunk A:  amount min=100,    max=9000   → SKIP (max < 10000)
File chunk B:  amount min=5000,   max=25000  → READ (range overlaps)
File chunk C:  amount min=10001,  max=80000  → READ (range overlaps)
File chunk D:  amount min=90000,  max=500000 → READ (range overlaps)

Without sort key: 4 chunks read (all)
With sort key on amount: 3 chunks read (chunk A skipped)

At real scale: 500 chunks, only 20 overlap → 96% skip rate
```

#### Compound sort keys — column order matters critically

```sql
-- Compound sort key on (event_date, user_id, status)
-- Sorted order in file:
-- 2025-01-01 | user 1  | FAILED
-- 2025-01-01 | user 1  | SUCCESS
-- 2025-01-01 | user 2  | SUCCESS
-- 2025-01-01 | user 42 | SUCCESS
-- 2025-01-02 | user 1  | FAILED
-- ...

-- Query A: WHERE event_date = '2025-01-01'
--   → Excellent skip: first column = leading key → almost all chunks skippable

-- Query B: WHERE user_id = 42
--   → Poor skip: user_id is the 2nd column, not leading
--   → user 42 rows are scattered across all date ranges
--   → Must scan all chunks to find user 42

-- Query C: WHERE event_date = '2025-01-01' AND user_id = 42
--   → Good skip: date narrows to Jan-01 range, THEN user_id skips within it
```

**Rule:** The first column in the sort key is the one that produces the most skipping. Only add subsequent columns if queries commonly filter on them **together with** the leading columns.

#### Single sort key vs compound

```sql
-- Scenario: 90% of queries filter by event_date. 60% also filter by user_id.
-- GOOD compound key:
CLUSTER BY (event_date, user_id)         -- Delta Liquid
ZORDER BY (event_date, user_id)          -- Delta ZORDER
COMPOUND SORTKEY (event_date, user_id)   -- Redshift

-- Scenario: queries filter by event_date OR user_id (not always together)
-- Z-order / Liquid clustering handles this better than compound sort
-- because it uses a space-filling curve that preserves locality in both dimensions
```

#### Z-order / Multi-dimensional clustering (Delta Lake)

Z-order encodes multiple columns into a single key using a Z-curve (Morton code), preserving locality in multiple dimensions simultaneously. Rows with similar (event_date, user_id) both end up near each other in the file, even when querying on just one dimension.

```sql
-- Delta Lake OPTIMIZE with ZORDER
OPTIMIZE upi_transactions
ZORDER BY (user_id, event_date);

-- After this: a query on user_id = 42 touches far fewer files
-- even though user_id is NOT the leading sort dimension
-- because Z-ordering clusters multi-dimensionally

-- Liquid Clustering (Delta 3.0+) — same concept, incremental not batch
CREATE TABLE upi_transactions (
    txn_id     BIGINT,
    user_id    BIGINT,
    amount     DECIMAL(18,2),
    event_date DATE,
    status     STRING
) USING DELTA
CLUSTER BY (user_id, event_date);
-- No PARTITION BY needed — Liquid replaces both partitioning + ZORDER
-- Engine manages clustering automatically on write
```sql

---

