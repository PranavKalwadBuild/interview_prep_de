<!-- Part of sql-patterns: Partition/Sort Keys — Sort Key, Distribution Key, Snowflake Micro-Partitions, BigQuery, Decision Framework -->
<!-- Source: sql_patterns.md lines 13442–13692 -->

### 35-3. Distribution Key (Bucketing / DISTKEY) — Deep Dive

#### What distribution does

In distributed systems (Redshift, Hive, Spark), data lives across multiple nodes. A JOIN between two large tables requires both tables to co-locate matching rows on the same node. Without a distribution key, the engine **shuffles** the entire table across the network:

```

Node 1 has: txn rows for users 1–250K
Node 2 has: txn rows for users 250K–500K
Node 3 has: users table rows for users 1–250K
Node 4 has: users table rows for users 250K–500K

JOIN txn ON users.user_id = txn.user_id:
  → ALL txn rows reshuffled to nodes based on user_id hash
  → ALL user rows reshuffled to same nodes
  → 400GB network transfer

With DISTKEY(user_id) on BOTH tables:
  → txn rows for user 42 live on Node 2
  → user row for user 42 ALSO lives on Node 2
  → JOIN is local: zero shuffle

```sql

```sql
-- Redshift co-located join setup
CREATE TABLE upi_transactions (
    txn_id     BIGINT ENCODE AZ64,
    user_id    BIGINT ENCODE AZ64,
    amount     DECIMAL(18,2) ENCODE AZ64,
    event_date DATE ENCODE AZ64,
    status     VARCHAR(20) ENCODE ZSTD
)
DISTSTYLE KEY
DISTKEY (user_id)
COMPOUND SORTKEY (event_date, user_id);

CREATE TABLE users (
    user_id    BIGINT ENCODE AZ64,
    kyc_tier   VARCHAR(10) ENCODE ZSTD,
    created_at DATE ENCODE AZ64
)
DISTSTYLE KEY
DISTKEY (user_id);
-- Same DISTKEY → join between these two tables = zero shuffle

-- Hive / Spark bucketing equivalent
CREATE TABLE upi_transactions (
    txn_id     BIGINT,
    user_id    BIGINT,
    amount     DECIMAL(18,2),
    event_date DATE,
    status     STRING
)
USING DELTA
PARTITIONED BY (event_date)
CLUSTERED BY (user_id) INTO 200 BUCKETS
SORTED BY (event_date);

CREATE TABLE users (
    user_id    BIGINT,
    kyc_tier   STRING
)
USING DELTA
CLUSTERED BY (user_id) INTO 200 BUCKETS;
-- SAME bucket count and key → bucket join: no shuffle at all
```

#### DISTSTYLE ALL — broadcast small tables

```sql
-- For a small lookup table (< 100MB), copy it to EVERY node
CREATE TABLE credit_tiers (
    tier_code   VARCHAR(10),
    min_score   INT,
    max_score   INT,
    interest_rate DECIMAL(5,2)
)
DISTSTYLE ALL;
-- No DISTKEY needed — every node has all rows → JOINs are always local
```

#### DISTSTYLE EVEN — when there's no good join key

```sql
-- Table is never joined to a large table; just queried in isolation
CREATE TABLE daily_aggregated_metrics (
    metric_date DATE,
    metric_name VARCHAR(100),
    value       DECIMAL(18,4)
)
DISTSTYLE EVEN;
-- Round-robin distribution → perfectly even load across nodes
```sql

---

### 35-4. Snowflake Micro-Partitions and CLUSTER BY

Snowflake doesn't expose traditional partitioning. Instead it automatically splits data into **micro-partitions** (16MB compressed columnar chunks). `CLUSTER BY` tells Snowflake to keep rows with similar key values in the same micro-partitions, reducing **overlap** (the number of micro-partitions that must be scanned for a given filter value).

```sql
-- Without CLUSTER BY:
-- user_id = 42 might appear in 8,000 of 10,000 micro-partitions
-- → 80% of table scanned

-- With CLUSTER BY (event_date):
-- All Jan-15 rows land in a small number of micro-partitions
-- → filter event_date = '2025-01-15' → 0.3% of table scanned

CREATE OR REPLACE TABLE upi_transactions (
    txn_id     NUMBER(18,0),
    user_id    NUMBER(18,0),
    amount     NUMBER(18,2),
    event_date DATE,
    status     VARCHAR(20)
)
CLUSTER BY (event_date, user_id)
DATA_RETENTION_TIME_IN_DAYS = 90
COMMENT = 'Partitioned by clustering key event_date; secondary cluster on user_id';

-- Check clustering quality
SELECT SYSTEM$CLUSTERING_INFORMATION('upi_transactions', '(event_date, user_id)');
-- Returns overlap_depth: 1.0 = perfectly clustered, >4 = needs reclustering

-- Force manual recluster if overlap_depth > 4:
ALTER TABLE upi_transactions RECLUSTER;

-- Search Optimization for point lookups on user_id (non-cluster column)
ALTER TABLE upi_transactions ADD SEARCH OPTIMIZATION ON EQUALITY(user_id);
-- Adds a secondary access path for exact user_id lookups without full scan
```sql

---

### 35-5. BigQuery Partitioning and Clustering

BigQuery partitions and clustering are distinct from each other and from Snowflake/Delta:

```sql
-- Partition by DATE column (most common)
CREATE OR REPLACE TABLE `project.dataset.upi_transactions`
PARTITION BY DATE(event_ts)           -- creates one partition per day
CLUSTER BY user_id, status            -- up to 4 cluster columns
OPTIONS (
    require_partition_filter = TRUE   -- prevent accidental full scans
)
AS SELECT * FROM raw_transactions;

-- Partition by INTEGER RANGE (for non-time data)
CREATE TABLE kyc_scores
PARTITION BY RANGE_BUCKET(credit_score, GENERATE_ARRAY(300, 900, 50))
-- buckets: 300-350, 350-400, ..., 850-900
CLUSTER BY user_id;

-- BigQuery INFORMATION_SCHEMA to check partition sizes
SELECT
    table_name,
    partition_id,
    total_rows,
    total_logical_bytes / POW(1024,3) AS size_gb
FROM `project.dataset.INFORMATION_SCHEMA.PARTITIONS`
WHERE table_name = 'upi_transactions'
ORDER BY partition_id DESC
LIMIT 30;
```sql

---

### 35-6. The Decision Framework — Choosing the Right Keys

#### Step 1 — Identify your access patterns first

Before choosing any key, answer these four questions:

```

Q1. What column(s) appear in WHERE filters in > 60% of queries?
    → Primary partition key candidate

Q2. What column is almost always combined with Q1 in filters?
    → Sort/cluster key candidate (secondary dimension)

Q3. What large tables does this table JOIN to?
    → Distribution key candidate (must match the join partner's key)

Q4. What is the cardinality of my candidates?
    → Drives whether to use range partition, hash bucket, or skip entirely

```

#### Step 2 — Cardinality routing table

```

High cardinality + time-based (date/timestamp):
  → RANGE PARTITION on the time column
  → Optionally: Z-order / CLUSTER BY the join key as secondary

High cardinality + non-time (user_id, txn_id):
  → Do NOT partition (file explosion)
  → Use DISTKEY/bucketing for join co-location
  → Use ZORDER / Liquid Clustering for data skipping

Low cardinality (status, region, tier — 2-100 unique values):
  → LIST partition ONLY if queries frequently filter by this column alone
  → Otherwise use as a CLUSTER BY secondary column, not partition key

Mixed (partition on date + cluster on user_id):
  → Most common pattern for transactional tables

```

#### Step 3 — Decision tree

```

Is the table queried with time-range filters (daily/weekly/monthly)?
  YES → PARTITION BY time column (day or month granularity)
        └─ Is user_id / entity_id also commonly filtered?
              YES → Add as sort/cluster key (ZORDER, CLUSTER BY, SORTKEY)
              NO  → Sort key = same time column (to skip within partition)
  NO  → Is the table joined to a larger table on a common key?
          YES → DISTKEY / Bucket on the join key
                └─ Is it a small lookup table (< 100MB)?
                      YES → DISTSTYLE ALL / Broadcast
          NO  → DISTSTYLE EVEN / no bucketing; use sort key on filter column

Is data skew expected on the partition/distribution key?
  YES → Do NOT use the skewed column as the distribution key
        → Use a surrogate (hash mod) or composite key
        → Enable AQE skew hints (Spark 3.x) or salting

```

#### Step 4 — Use case → key mapping table

| Use Case | Table | Partition Key | Sort / Cluster Key | Distribution / Bucket Key |
|---|---|---|---|---|
| UPI transactions (time-series) | `upi_transactions` | `event_date` (daily) | `user_id, status` | `user_id` |
| Loan disbursements | `loan_disbursements` | `disbursement_date` (monthly) | `borrower_id, product_type` | `borrower_id` |
| KYC documents | `kyc_documents` | `created_date` (monthly) | `user_id, doc_type` | `user_id` |
| User dimension (SCD2) | `dim_users` | None (small table) | `user_id, valid_from` | `user_id` |
| Daily aggregated metrics | `daily_metrics` | `metric_date` (daily) | `metric_name` | EVEN |
| Product catalog | `products` | None | `category, product_id` | ALL (broadcast) |
| Event clickstream (high volume) | `events` | `event_date` (daily or hourly) | `user_id, event_type` | `user_id` |
| Repayment schedule | `repayment_schedule` | `due_date` (monthly) | `loan_id, status` | `loan_id` |

---

