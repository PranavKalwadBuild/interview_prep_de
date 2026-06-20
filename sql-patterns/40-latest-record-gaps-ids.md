<!-- Part of sql-patterns: Latest Record per Entity (Point-in-Time) and Gaps in Sequential IDs -->
<!-- Source: sql_patterns.md lines 10374–10796 -->

## 28. Latest Record per Entity (Point-in-Time)

### What it solves

A very common real-world pattern: get the current/latest state of each entity (user, account, order).

### Keywords to spot

> "current", "latest", "most recent", "active",
> "last known", "as of now", "current status",
> "point-in-time snapshot", "live state", "current version",
> "what is the user's current", "most recent non-null",
> "last update per", "freshest record"

### Business Context

- **Fintech:** Current KYC/compliance status of each user (onboarding gating); latest price of each asset for portfolio valuation; most recent account balance per user
- **E-commerce:** Most recent order status per order ID (customer service lookup); latest product price for display; most recent address on file per customer for shipping
- **SaaS:** Current subscription plan per account (entitlement check); most recent login per user (active user definition); current feature flag state per account
- **Data Engineering:** Latest ingested record per entity in a CDC pipeline (Golden Record); most recent schema version per table in a schema registry; latest partition metadata per table
- **Healthcare:** Current medication per patient (active prescriptions); most recent lab result per test type per patient

### Four equivalent methods

```sql
-- Method 1: ROW_NUMBER (most flexible)
WITH latest AS (
    SELECT *,
        ROW_NUMBER() OVER (PARTITION BY user_id ORDER BY updated_at DESC) AS rn
    FROM user_kyc_status
)
SELECT * FROM latest WHERE rn = 1;

-- Method 2: Correlated subquery
SELECT *
FROM user_kyc_status u
WHERE updated_at = (
    SELECT MAX(updated_at) FROM user_kyc_status WHERE user_id = u.user_id
);

-- Method 3: Self-join anti-pattern (find rows with no newer sibling)
SELECT u.*
FROM user_kyc_status u
LEFT JOIN user_kyc_status u2
    ON  u.user_id = u2.user_id
    AND u2.updated_at > u.updated_at
WHERE u2.user_id IS NULL;

-- Method 4: is_current / valid_to flag (SCD2)
SELECT * FROM user_kyc_status WHERE is_current = TRUE;
```

### Edge Cases

**Fix:**

```sql
-- NTILE's uneven distribution is expected behaviour. The fix is to document it
-- and consider WIDTH_BUCKET for strict equal-sized buckets when needed:

-- Option 1: Accept NTILE's distribution and document it:
SELECT loan_amount,
    NTILE(3) OVER (ORDER BY loan_amount) AS tertile
    -- NOTE: if total rows not divisible by 3, the first bucket(s) receive the extra rows
FROM loan_applications ORDER BY loan_amount;

-- Option 2: Use PERCENT_RANK + CASE for equal-width percentile bands:
SELECT loan_amount,
    CASE
        WHEN PERCENT_RANK() OVER (ORDER BY loan_amount) < 1.0/3 THEN 1
        WHEN PERCENT_RANK() OVER (ORDER BY loan_amount) < 2.0/3 THEN 2
        ELSE 3
    END AS tertile
FROM loan_applications;
-- PERCENT_RANK produces exactly equal-width percentile ranges (0 to 0.33, 0.33 to 0.67, etc.)
-- Bucket sizes may still differ when values cluster at boundaries due to ties

-- Option 3: WIDTH_BUCKET for equal-width value ranges (not equal row count):
SELECT loan_amount,
    WIDTH_BUCKET(loan_amount, min_amount, max_amount + 1, 3) AS tertile
FROM loan_applications
CROSS JOIN (SELECT MIN(loan_amount) AS min_amount, MAX(loan_amount) AS max_amount FROM loan_applications) bounds;
-- Divides the VALUE range equally; row counts per bucket will vary based on data distribution
```

#### Edge 28-A: Multiple records with identical "latest" timestamp — non-deterministic

This is the same issue as Edge 7-A but worth restating in the latest-record context:

**Problem:**

```sql
-- Two loan records updated at exactly the same time (batch processing)
-- ROW_NUMBER picks one — but which one depends on internal row storage order
```

**Fix — add a business-meaningful tiebreaker:**

```sql
ROW_NUMBER() OVER (
    PARTITION BY loan_id
    ORDER BY
        updated_at DESC,
        CASE source WHEN 'core_banking' THEN 1 WHEN 'crm' THEN 2 ELSE 3 END ASC,
        record_seq DESC  -- internal sequence number from the source
)
-- This makes the dedup deterministic regardless of physical row order
```

#### Edge 28-B: Using MAX(date) + self-join creates fan-out with duplicate max dates

**Problem:**

```sql
-- Method 2 for latest record (from the guide): self-join on MAX(date)
-- BREAKS when multiple rows share the exact max date for an entity

SELECT o.*
FROM orders o
JOIN (
    SELECT customer_id, MAX(order_date) AS latest_date
    FROM orders GROUP BY customer_id
) latest ON o.customer_id = latest.customer_id AND o.order_date = latest.latest_date;
-- Customer C1 has two orders on the same MAX date → BOTH rows returned!
-- Expected: one row per customer. Actual: two rows for customer C1.
```

**Fix — use ROW_NUMBER which is immune to this issue:**

```sql
-- FIX — use ROW_NUMBER which is immune to this issue:
WITH ranked AS (
    SELECT *, ROW_NUMBER() OVER (
        PARTITION BY customer_id
        ORDER BY order_date DESC, order_id DESC  -- stable tiebreaker
    ) AS rn FROM orders
)
SELECT * FROM ranked WHERE rn = 1;   -- exactly one row per customer, deterministic
---

### At Scale

#### Failure Mechanism

`ROW_NUMBER() OVER (PARTITION BY entity_id ORDER BY updated_at DESC)` on 1B CDC records:

- Full shuffle by `entity_id` across all nodes: 200GB of network I/O
- Sort by `updated_at` per partition: O(N log N) per entity
- Final filter `WHERE rn = 1`: returns ~entity_count rows but still requires full shuffle+sort

If CDC table has 1B rows for 50M unique entities: average 20 versions per entity — all 1B rows shuffled and sorted.

#### Code-Level Fix

```sql
-- BEFORE: ROW_NUMBER on 1B CDC rows
WITH ranked AS (
    SELECT *, ROW_NUMBER() OVER (PARTITION BY entity_id ORDER BY updated_at DESC) AS rn
    FROM cdc_table   -- 1B rows
)
SELECT * FROM ranked WHERE rn = 1;

-- Target table is always deduplicated; ROW_NUMBER is never needed at query time
-- (see 34-7 for full implementation)

-- FIX 2: Use MAX aggregation + self-join (avoids PARTITION BY sort)
SELECT t.*
FROM cdc_table t
JOIN (
    SELECT entity_id, MAX(updated_at) AS latest_at
    FROM cdc_table
    GROUP BY entity_id   -- GROUP BY: one shuffle, no sort
) l ON t.entity_id = l.entity_id AND t.updated_at = l.latest_at;
-- For 1B rows: GROUP BY is one shuffle (hash aggregate) without per-partition sort
-- Faster than ROW_NUMBER (which requires shuffle + sort)
-- Caveat: multiple rows with identical MAX(updated_at) → fan-out (fix with dedup or tiebreaker)

-- DELETE operations are represented in the transaction log (deletion vectors)
-- "Latest record" = scan only the live files (non-deleted rows)
-- No ROW_NUMBER needed if the table is maintained correctly via MERGE
```

#### System-Level Fix

```sql
CREATE STREAM cdc_stream ON TABLE cdc_source;
-- Process only new CDC events (deltas) → maintain a deduplicated target
-- latest_record table is always current; ROW_NUMBER never needed interactively

CREATE TABLE cdc_table (
    entity_id   STRING,
    updated_at  TIMESTAMP,
    payload     STRING,
    op          CHAR(1)    -- I/U/D
)
PARTITIONED BY (DATE(updated_at))
TBLPROPERTIES (
    'delta.bloomFilter.columns' = 'entity_id',
    'delta.bloomFilter.fpp' = '0.001'
);
-- MERGE: bloom filter finds matching entity_id files instantly
-- Latest record: scan only the most recent partition + bloom filter lookup

-- Latest record via: SELECT * FROM cdc WHERE DATE(updated_at) = (SELECT MAX(DATE(updated_at)) FROM cdc WHERE entity_id = :id)
-- Partition pruning + cluster pruning → reads < 1% of data
---

---

## 29. Gaps in Sequential IDs

### What it solves

Find missing values in a sequence (missing invoice numbers, missing trade IDs, missing dates).

### Keywords to spot

> "missing", "gap in sequence", "skipped IDs", "which numbers are absent",
> "holes in the sequence",
> "incomplete range", "dropped records", "audit trail gap",
> "continuity check", "sequence break", "numbers not present in"

### Business Context

- **Data Engineering:** Missing trade/event IDs in a batch → indicates rows dropped during ingestion (pipeline integrity check); gap in Kafka offset sequence → message loss detection
- **Finance/Compliance:** Gaps in invoice or receipt numbering → audit red flag (revenue recognition risk); missing cheque numbers in a cheque series → potential fraud
- **Logistics:** Missing shipment scan sequence numbers → package tracking gap (SLA at risk); missing delivery stop numbers in a route → driver skipped a stop
- **Healthcare:** Missing encounter IDs in a patient record range → records not transferred during migration; sequence gaps in prescription numbers → dispensing audit issue
- **Any domain:** Verify that a sequence/auto-increment generator hasn't skipped values after a database restart or failover

### Boilerplate

```sql
-- Find gaps in trade_id sequence
-- Method: compare each ID to the next — if gap > 1, there are missing values
WITH ordered AS (
    SELECT
        trade_id,
        LEAD(trade_id) OVER (ORDER BY trade_id) AS next_id
    FROM trades
)
SELECT
    trade_id + 1        AS gap_start,
    next_id - 1         AS gap_end,
    next_id - trade_id - 1 AS missing_count
FROM ordered
WHERE next_id - trade_id > 1;
```

### Edge Cases

#### Edge 29-A: Gap detection with generate_series assumes contiguous range

**Problem:**

```sql
-- Method: generate_series(min_id, max_id) then LEFT JOIN to find missing IDs
-- BREAKS if the min_id is not 1 and the range is huge

SELECT gs.id AS missing_id
FROM generate_series(
    (SELECT MIN(order_id) FROM orders),   -- e.g., 100000
    (SELECT MAX(order_id) FROM orders)    -- e.g., 900000000
) gs(id)
LEFT JOIN orders o ON gs.id = o.order_id
WHERE o.order_id IS NULL;
-- generate_series(100000, 900000000) produces 900 MILLION rows → OOM / very slow!
```

**Fix — use the LAG-based approach for large ranges:**

```sql
SELECT
    order_id AS after_id,
    prev_id + 1 AS gap_start,
    order_id - 1 AS gap_end,
    order_id - prev_id - 1 AS gap_size
FROM (
    SELECT order_id,
           LAG(order_id) OVER (ORDER BY order_id) AS prev_id
    FROM orders
) t
WHERE order_id - prev_id > 1
ORDER BY gap_start;
-- Returns ONLY the gap ranges — no generation of billions of rows
```

#### Edge 29-B: Gaps in a non-integer or non-contiguous sequence

**Problem:**

```sql
-- If order_ids are assigned from a sequence that deliberately skips values
-- (e.g., sequence cache = 100: IDs assigned in blocks of 100)
-- Gaps of 1-99 are EXPECTED, not missing orders

-- If the question is "find true missing orders" not "find gaps in sequence":
-- Need business context — is every sequence value expected to have a corresponding row?
-- Gap in a cached sequence ≠ missing order

-- Better approach: use a completeness check against the source system:
-- Compare count of orders in source vs DWH for the time period
-- Rather than assuming sequence continuity
```

**Fix:**

```sql
-- Don't assume sequence continuity — use a business-level completeness check instead:

-- Option 1: Count-based reconciliation against the source system:
SELECT
    s.load_date,
    s.expected_count,
    COUNT(o.order_id) AS actual_count,
    s.expected_count - COUNT(o.order_id) AS missing_count
FROM source_count_by_date s
LEFT JOIN orders o ON DATE(o.created_at) = s.load_date
GROUP BY s.load_date, s.expected_count
HAVING COUNT(o.order_id) < s.expected_count;   -- days with missing records

-- Option 2: If you know the sequence is intended to be gapless,
-- flag only gaps larger than the expected cache size:
WITH gaps AS (
    SELECT order_id,
           LAG(order_id) OVER (ORDER BY order_id) AS prev_id,
           order_id - LAG(order_id) OVER (ORDER BY order_id) - 1 AS gap_size
    FROM orders
)
SELECT prev_id + 1 AS gap_start, order_id - 1 AS gap_end, gap_size
FROM gaps
WHERE gap_size > 100;   -- only flag gaps larger than expected sequence cache size (e.g., 100)

```sql
-- BEFORE: generate_series on 900M range → OOM
SELECT gs.id AS missing_id
FROM generate_series(
    (SELECT MIN(order_id) FROM orders),   -- 100,000
    (SELECT MAX(order_id) FROM orders)    -- 900,100,000
) gs(id)
LEFT JOIN orders o ON gs.id = o.order_id
WHERE o.order_id IS NULL;  -- generates 900M rows just to find a handful of gaps

-- FIX: LAG-based gap detection — O(N) not O(range_size)
SELECT
    prev_id + 1 AS gap_start,
    order_id - 1 AS gap_end,
    order_id - prev_id - 1 AS gap_size
FROM (
    SELECT order_id,
        LAG(order_id) OVER (ORDER BY order_id) AS prev_id
    FROM orders   -- scan N existing rows (not range_size rows!)
) t
WHERE order_id - prev_id > 1   -- gap detected
ORDER BY gap_start;
-- For 50M existing orders: scans exactly 50M rows (not 900M)
-- Returns only the gap ranges (usually a small set) — memory-efficient
```

#### System-Level Fix

```sql
-- Prevent gaps in the first place: use database sequences correctly
-- Gap in sequence ≠ missing order (sequences skip on rollback, restart, batch allocation)
-- If you need GAPLESS IDs for regulatory sequential numbering:
-- Use a separate counter table with pessimistic locking:
CREATE TABLE sequence_counters (seq_name VARCHAR(50) PRIMARY KEY, next_val BIGINT);
-- On each order: UPDATE sequence_counters SET next_val = next_val + 1 WHERE seq_name = 'order'
--                RETURNING next_val AS order_id
-- This is serialised (not scalable past ~1000 TPS) — use only for regulatory compliance

-- For gap detection in large tables: maintain a gap_registry table
-- On every INSERT to orders: check if the new ID has a gap from the previous MAX
-- Store gaps immediately as they're detected, not by scanning the whole table:
CREATE TABLE order_id_gaps (gap_start BIGINT, gap_end BIGINT, detected_at TIMESTAMP);
-- Gap query: SELECT * FROM order_id_gaps — trivially fast
---

---


