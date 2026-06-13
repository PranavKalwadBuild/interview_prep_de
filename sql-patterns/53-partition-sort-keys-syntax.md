<!-- Part of sql-patterns: Partition/Sort Keys — Anti-Patterns, Platform Syntax Reference, Decision Cheat Sheet -->
<!-- Source: sql_patterns.md lines 13961–14104 -->

### 35-10. Platform Syntax Quick Reference

```sql
-- ─────────────────────────────────────────────────────
-- PARTITION KEY
-- ─────────────────────────────────────────────────────

-- PostgreSQL
PARTITION BY RANGE (event_date)
PARTITION BY LIST  (region)
PARTITION BY HASH  (user_id)

-- MySQL / MariaDB
PARTITION BY RANGE  (YEAR(event_date))
PARTITION BY LIST   (region)
PARTITION BY HASH   (user_id) PARTITIONS 8

-- Hive / Spark SQL
PARTITIONED BY (event_date DATE)

-- Delta Lake (Spark)
PARTITIONED BY (event_date)           -- classic
CLUSTER BY (event_date, user_id)      -- Liquid (Delta 3.0+, replaces PARTITIONED BY)

-- Snowflake  (no PARTITION BY — clustering replaces it)
CLUSTER BY (event_date, user_id)

-- BigQuery
PARTITION BY DATE(event_ts)
PARTITION BY RANGE_BUCKET(credit_score, GENERATE_ARRAY(300,900,50))

-- Redshift  (no native partitioning — sort key serves a similar role)
COMPOUND SORTKEY (event_date, user_id)   -- leading column = "partition-like" pruning

-- ─────────────────────────────────────────────────────
-- SORT / CLUSTER KEY
-- ─────────────────────────────────────────────────────

-- PostgreSQL
CREATE INDEX ON t (col1, col2);         -- B-tree index (not a physical sort)
CLUSTER t USING idx_name;               -- physically reorder once; not maintained

-- Delta Lake
OPTIMIZE t ZORDER BY (col1, col2);     -- multi-dimensional sort (batch)
CLUSTER BY (col1, col2)                -- Liquid: automatic, incremental

-- Snowflake
CLUSTER BY (col1, col2)                -- automatic background reclustering

-- BigQuery
CLUSTER BY col1, col2                  -- up to 4 columns

-- Redshift
COMPOUND SORTKEY (col1, col2, col3)    -- left-prefix rules apply
INTERLEAVED SORTKEY (col1, col2)       -- equal weight; better for ad-hoc; slower VACUUM

-- ─────────────────────────────────────────────────────
-- DISTRIBUTION / BUCKET KEY
-- ─────────────────────────────────────────────────────

-- Hive / Spark (bucketing)
CLUSTERED BY (user_id) INTO 200 BUCKETS SORTED BY (event_date)

-- Delta Lake (bucket join)
CREATE TABLE t USING DELTA
    CLUSTERED BY (user_id) INTO 200 BUCKETS;

-- Redshift
DISTSTYLE KEY   DISTKEY (user_id)
DISTSTYLE ALL                           -- broadcast: copy everywhere
DISTSTYLE EVEN                          -- round-robin: no join benefit

-- BigQuery — no explicit DISTKEY; engine manages shuffle internally
-- Snowflake — no explicit DISTKEY; micro-partition + clustering handles co-location

-- ─────────────────────────────────────────────────────
-- USEFUL DIAGNOSTICS
-- ─────────────────────────────────────────────────────

-- Delta Lake: partition statistics
DESCRIBE DETAIL table_name;
SHOW PARTITIONS table_name;

-- Databricks: data skipping stats
DESCRIBE EXTENDED table_name PARTITION (event_date='2025-01-15');

-- Snowflake: clustering info
SELECT SYSTEM$CLUSTERING_INFORMATION('table_name', '(col1, col2)');

-- BigQuery: partition sizes
SELECT * FROM dataset.INFORMATION_SCHEMA.PARTITIONS WHERE table_name = 'tbl';

-- Redshift: node distribution
SELECT node, COUNT(*) FROM stv_blocklist
WHERE tbl = (SELECT id FROM stv_tbl_perm WHERE name = 'table_name')
GROUP BY node;

-- Redshift: sort key effectiveness (unsorted rows %)
SELECT "table", unsorted, stats_off
FROM svv_table_info
WHERE "table" = 'upi_transactions';
-- unsorted > 20% → run VACUUM SORT ONLY table_name;
```sql

---

### 35-11. The One-Page Decision Cheat Sheet

```

┌─────────────────────────────────────────────────────────────────┐
│              KEY SELECTION DECISION GUIDE                       │
├────────────────────────┬────────────────────────────────────────┤
│ ACCESS PATTERN         │ KEY CHOICE                             │
├────────────────────────┼────────────────────────────────────────┤
│ Always filter by date  │ PARTITION by date (day or month)       │
│ Filter by date + user  │ PARTITION date, SORT/CLUSTER user_id   │
│ JOIN to large table    │ DISTKEY/BUCKET on the join key         │
│ Small lookup table     │ DISTSTYLE ALL (broadcast)              │
│ No good join key       │ DISTSTYLE EVEN / no bucketing          │
│ Point lookups on PK    │ Bloom filter (Delta) / Search Opt (SF) │
│ Skewed distribution    │ AQE (Spark) / salt the key             │
│ Multiple filter cols   │ Z-order / Liquid Clustering (Delta/SF) │
└────────────────────────┴────────────────────────────────────────┘

CARDINALITY RULES:
  date / timestamp       → RANGE partition  ✓
  low-card string (20)   → LIST partition   ✓ (if filtered alone often)
  user_id / txn_id       → BUCKET/DISTKEY   ✓  (never PARTITION)
  status / tier          → CLUSTER/SORT     ✓  (not partition)
  free text              → never key        ✗

ALWAYS VERIFY:

  1. EXPLAIN / QUERY PROFILE shows partition pruning
  2. Bytes scanned / bytes total < 5% = well-partitioned
  3. Node distribution within 20% of average = no skew
  4. Clustering depth < 2.0 (Snowflake) = low overlap

```sql

---


