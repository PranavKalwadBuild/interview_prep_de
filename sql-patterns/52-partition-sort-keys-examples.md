<!-- Part of sql-patterns: Partition/Sort Keys — Platform Code Examples and Skew -->
<!-- Source: sql_patterns.md lines 13693–13960 -->

### 35-7. Solid Code Examples — End-to-End by Platform

#### Example A — Delta Lake (Databricks): UPI Transactions Table

```sql
-- OPTION 1: Classic PARTITION BY + ZORDER (Delta < 3.0)
CREATE OR REPLACE TABLE upi_transactions (
    txn_id      BIGINT         NOT NULL,
    user_id     BIGINT         NOT NULL,
    amount      DECIMAL(18,2)  NOT NULL,
    merchant_id BIGINT,
    event_date  DATE           NOT NULL,
    event_ts    TIMESTAMP      NOT NULL,
    status      STRING,
    channel     STRING
)
USING DELTA
PARTITIONED BY (event_date)
TBLPROPERTIES (
    'delta.autoOptimize.optimizeWrite' = 'true',   -- coalesce small files on write
    'delta.autoOptimize.autoCompact'   = 'true',   -- background compaction
    'delta.bloomFilter.columns'        = 'txn_id', -- fast MERGE lookups
    'delta.bloomFilter.fpp'            = '0.001'
);

-- After initial load, Z-order within each partition:
OPTIMIZE upi_transactions
ZORDER BY (user_id, merchant_id);
-- Now: WHERE event_date = '2025-01-15' AND user_id = 42
-- → prune to Jan-15 partition (partition key)
-- → Z-order skips 95% of files within that partition (cluster key)

-- OPTION 2: Liquid Clustering (Delta 3.0+ / DBR 13.3+) — simpler
CREATE OR REPLACE TABLE upi_transactions (
    txn_id      BIGINT         NOT NULL,
    user_id     BIGINT         NOT NULL,
    amount      DECIMAL(18,2)  NOT NULL,
    merchant_id BIGINT,
    event_date  DATE           NOT NULL,
    event_ts    TIMESTAMP      NOT NULL,
    status      STRING,
    channel     STRING
)
USING DELTA
CLUSTER BY (event_date, user_id);  -- replaces PARTITION BY + ZORDER
-- Engine manages file layout automatically; no manual OPTIMIZE needed
```

#### Example B — Snowflake: Multi-Region Transaction Analytics

```sql
CREATE OR REPLACE TABLE upi_transactions (
    txn_id       NUMBER(18,0)   NOT NULL,
    user_id      NUMBER(18,0)   NOT NULL,
    amount       NUMBER(18,2)   NOT NULL,
    merchant_id  NUMBER(18,0),
    event_date   DATE           NOT NULL,
    event_ts     TIMESTAMP_NTZ  NOT NULL,
    status       VARCHAR(20),
    region       VARCHAR(20)
)
CLUSTER BY (event_date, user_id)
DATA_RETENTION_TIME_IN_DAYS = 90
COMMENT = 'Partitioned by clustering key event_date; secondary cluster on user_id';

-- Verify clustering depth (lower = better, target < 2.0)
SELECT SYSTEM$CLUSTERING_INFORMATION(
    'upi_transactions',
    '(event_date, user_id)'
);
-- Output: {"total_partition_count": 10000, "overlap_depth": 1.2, ...}

-- Force manual recluster if overlap_depth > 4:
ALTER TABLE upi_transactions RECLUSTER;

-- Search Optimization for point lookups on user_id (non-cluster column)
ALTER TABLE upi_transactions ADD SEARCH OPTIMIZATION ON EQUALITY(user_id);
-- Adds a secondary access path for exact user_id lookups without full scan
```

#### Example C — BigQuery: Event Clickstream Table

```sql
CREATE OR REPLACE TABLE `myproject.analytics.events`
(
    event_id     STRING        NOT NULL,
    user_id      INT64         NOT NULL,
    event_type   STRING        NOT NULL,
    event_ts     TIMESTAMP     NOT NULL,
    session_id   STRING,
    properties   JSON
)
PARTITION BY DATE(event_ts)
CLUSTER BY user_id, event_type
OPTIONS (
    partition_expiration_days = 365,     -- auto-expire old data
    require_partition_filter  = TRUE,    -- force callers to filter on event_ts
    description = 'Partitioned daily on event_ts; clustered by user_id + event_type'
);

-- Verify partition usage before queries:
SELECT
    partition_id,
    total_rows,
    ROUND(total_logical_bytes / POW(1024,3), 2) AS size_gb
FROM `myproject.analytics.INFORMATION_SCHEMA.PARTITIONS`
WHERE table_name = 'events'
  AND partition_id >= FORMAT_DATE('%Y%m%d', DATE_SUB(CURRENT_DATE(), INTERVAL 30 DAY))
ORDER BY partition_id DESC;
```

#### Example D — Redshift: Loan Repayment Fact Table

```sql
CREATE TABLE loan_repayments (
    payment_id      BIGINT         ENCODE AZ64  NOT NULL,
    loan_id         BIGINT         ENCODE AZ64  NOT NULL,
    borrower_id     BIGINT         ENCODE AZ64  NOT NULL,
    payment_date    DATE           ENCODE AZ64  NOT NULL,
    amount_paid     DECIMAL(18,2)  ENCODE AZ64,
    status          VARCHAR(20)    ENCODE ZSTD,
    payment_method  VARCHAR(30)    ENCODE ZSTD
)
DISTSTYLE KEY
DISTKEY (borrower_id)                        -- co-locate with dim_users on borrower_id
COMPOUND SORTKEY (payment_date, borrower_id) -- leading: time filter; secondary: join
ENCODE AUTO;

-- Co-located dimension:
CREATE TABLE dim_users (
    user_id         BIGINT         ENCODE AZ64  NOT NULL,
    kyc_tier        VARCHAR(10)    ENCODE ZSTD,
    credit_score    SMALLINT       ENCODE AZ64,
    registration_dt DATE           ENCODE AZ64
)
DISTSTYLE KEY
DISTKEY (user_id)              -- same key as loan_repayments.borrower_id
COMPOUND SORTKEY (user_id);    -- point lookups on user_id

-- Check skew — if max_rows >> avg_rows, distribution key is wrong:
SELECT
    node,
    COUNT(*) AS row_count
FROM (
    SELECT FLOOR(borrower_id::FLOAT / 1000000) AS node, 1
    FROM loan_repayments
)
GROUP BY 1
ORDER BY 2 DESC;
-- Healthy: all nodes within 20% of average
-- Skewed: one node has 10× the average → change DISTKEY or add salt
```

#### Example E — PostgreSQL: Declarative Partitioning for KYC Documents

```sql
-- Parent table
CREATE TABLE kyc_documents (
    doc_id       BIGSERIAL,
    user_id      BIGINT       NOT NULL,
    doc_type     VARCHAR(50)  NOT NULL,
    status       VARCHAR(20)  NOT NULL,
    submitted_at TIMESTAMP    NOT NULL,
    expires_at   TIMESTAMP
) PARTITION BY RANGE (submitted_at);

-- Monthly partitions (automate in prod with pg_partman):
CREATE TABLE kyc_documents_2025_01 PARTITION OF kyc_documents
    FOR VALUES FROM ('2025-01-01') TO ('2025-02-01');
CREATE TABLE kyc_documents_2025_02 PARTITION OF kyc_documents
    FOR VALUES FROM ('2025-02-01') TO ('2025-03-01');
-- etc.

-- Index on each partition (applies to all partitions when created on parent):
CREATE INDEX idx_kyc_user_id ON kyc_documents (user_id);
CREATE INDEX idx_kyc_status  ON kyc_documents (status, submitted_at);

-- BRIN index for the time column (very cheap, effective on append-only data):
CREATE INDEX idx_kyc_submitted_brin ON kyc_documents
    USING BRIN (submitted_at) WITH (pages_per_range = 128);

-- Enable constraint exclusion so planner can prune partitions:
SET constraint_exclusion = partition;

-- Verify partition pruning is working:
EXPLAIN (ANALYZE, BUFFERS)
SELECT COUNT(*)
FROM kyc_documents
WHERE submitted_at >= '2025-01-01' AND submitted_at < '2025-02-01';
-- Should show: "Partitions selected: 1 of N"
```sql

---

### 35-8. Skew — The Most Common Partition Key Mistake

Skew happens when one partition key value has dramatically more rows than others. This defeats both partition pruning (one partition is huge) and distribution (one node does all the work).

#### Detecting skew

```sql
-- Check partition size distribution (Delta Lake)
SELECT
    event_date,
    COUNT(*)                    AS row_count,
    SUM(amount)                 AS total_volume
FROM upi_transactions
GROUP BY event_date
ORDER BY row_count DESC
LIMIT 20;
-- If one date has 100M rows and others have 1M → skewed on date (e.g. payday)

-- Check data distribution quality (Databricks)
DESCRIBE DETAIL upi_transactions;
-- numFiles, sizeInBytes per partition visible via SHOW PARTITIONS

-- BigQuery: check byte distribution per partition
SELECT
    partition_id,
    total_rows,
    total_logical_bytes
FROM `project.dataset.INFORMATION_SCHEMA.PARTITIONS`
WHERE table_name = 'upi_transactions'
ORDER BY total_logical_bytes DESC;
```

#### Fixing skew — salting technique

```sql
-- Problem: status = 'SUCCESS' has 95% of rows, 'FAILED' has 5%
-- PARTITIONED BY (status) is terrible: one partition is 19× larger

-- Fix A: Don't partition by status — use it as a CLUSTER/SORT key instead
CLUSTER BY (event_date, status)   -- cluster, not partition

-- Fix B: Sub-partition with salt for hotspot date (e.g., month-end payday)
-- Add a salt column: txn_id % 8 → 0..7
ALTER TABLE upi_transactions ADD COLUMN shard TINYINT
    GENERATED ALWAYS AS (txn_id % 8) STORED;
-- Then partition by (event_date, shard) → 8× more partitions, even distribution
-- Queries must ignore shard or use: WHERE event_date = ? (shard is transparent)

-- Fix C: Spark AQE — runtime skew handling (Spark 3.x)
SET spark.sql.adaptive.enabled = true;
SET spark.sql.adaptive.skewJoin.enabled = true;
SET spark.sql.adaptive.skewJoin.skewedPartitionFactor = 5;  -- > 5× median → split
SET spark.sql.adaptive.skewJoin.skewedPartitionThresholdInBytes = '256MB';
-- AQE automatically splits skewed partitions at runtime without DDL changes
```sql

---

### 35-9. Common Anti-Patterns and How to Fix Them

| Anti-Pattern | What goes wrong | Fix |
|---|---|---|
| Partition by high-cardinality column (user_id) | Millions of tiny files; metadata OOM | Use bucketing/DISTKEY instead; partition by date |
| No partition at all on a 500GB time-series table | Full table scan for every query | Add daily or monthly partition on the time column |
| Sort key column not in WHERE or JOIN | Zero data skipping benefit | Choose a column that appears in filters or join predicates |
| DISTKEY on a skewed column (e.g., status='SUCCESS' = 95%) | One node holds 95% of data; others idle | Use DISTSTYLE EVEN or salt the key |
| Compound sort key: rarely-queried column first | Leading column doesn't match access pattern | Re-order: most selective/most-filtered column first |
| Partition by month but query daily | Jan 2025 partition is 50GB; query reads all 31 days | Switch to daily partitions if most queries filter to < 7 days |
| Function on partition column in WHERE | Defeats partition pruning (full scan) | Rewrite filter to a direct range comparison on the column |
| CLUSTER BY columns with too many NULL values | NULLs group together → one massive chunk | Filter NULLs at write time or use a sentinel value |
| Bucketing with mismatched bucket count | Two tables bucketed on user_id but N≠M → shuffle | Always use the same bucket count for co-located join partners |

---

