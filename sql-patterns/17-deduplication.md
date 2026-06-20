<!-- Part of sql-patterns: Deduplication Patterns -->
<!-- Source: sql_patterns.md lines 4384–4676 -->

## 7. Deduplication Patterns

### What it solves

Remove duplicate rows, keeping one record per entity based on a rule (e.g., latest, highest, first).

### Keywords to spot

> "deduplicate", "remove duplicates", "latest record", "keep only one",
> "same X appeared multiple times", "most recent version",
> "idempotent ingestion", "upsert logic",
> "exactly-once", "canonical record", "master record", "single source of truth",
> "redundant rows", "at-least-once delivery", "dedup key", "primary version"

### Business Context

- **Fintech:** Deduplicate trade records from multiple exchange partners sending the same trade; remove double-counted fee events caused by retry logic in payment APIs
- **E-commerce:** Remove duplicate order events from a payment gateway webhook that fires multiple times on network timeout; dedup product catalogue feed rows synced from multiple suppliers
- **Data Ingestion / Streaming:** Keep the latest version of a record from CDC streams; handle Kafka at-least-once delivery creating duplicate messages in the landing table
- **Healthcare:** Retain only the most recent patient record per encounter ID from multiple source systems (EMR + billing + lab); deduplicate lab results sent twice due to HL7 retries
- **Marketing:** Remove duplicate click-stream events from ad networks that report the same click across two attribution windows; deduplicate email open events fired by email preview bots

### Boilerplate — ROW_NUMBER method (most versatile)

```sql
-- Keep latest record per trade_id
WITH deduped AS (
    SELECT
        *,
        ROW_NUMBER() OVER (
            PARTITION BY trade_id
            ORDER BY ingested_at DESC   -- latest ingestion wins
        ) AS rn
    FROM raw_trades
)
SELECT * FROM deduped WHERE rn = 1;
```

### Boilerplate — GROUP BY + JOIN method

```sql
-- Keep the row with the max timestamp per trade_id
WITH latest AS (
    SELECT trade_id, MAX(ingested_at) AS latest_ingested_at
    FROM raw_trades
    GROUP BY trade_id
)
SELECT r.*
FROM raw_trades r
INNER JOIN latest l
    ON r.trade_id = l.trade_id
    AND r.ingested_at = l.latest_ingested_at;
```

#### Edge 7-A: Tied timestamps make dedup non-deterministic

**Problem:**

```sql
-- Two updates arrive at the exact same microsecond (batch import, parallel writes)
-- ROW_NUMBER picks one arbitrarily — different runs may return different rows

WITH ranked AS (
    SELECT *,
        ROW_NUMBER() OVER (
            PARTITION BY txn_id
            ORDER BY updated_at DESC   -- two rows have same updated_at → tie!
        ) AS rn
    FROM raw_transactions
)
SELECT * FROM ranked WHERE rn = 1;  -- which row wins is undefined
```

**Fix A — add a tiebreaker that represents source authority:**

```sql
ORDER BY updated_at DESC, source_priority ASC  -- lower priority number = more authoritative
-- e.g. source_priority: 1=core_banking, 2=kafka_stream, 3=manual_correction
```

**Fix B — if no reliable tiebreaker exists, surface both rows for investigation:**

```sql
WITH ranked AS (
    SELECT *,
        COUNT(*) OVER (PARTITION BY txn_id, updated_at) AS tie_count,
        ROW_NUMBER() OVER (PARTITION BY txn_id ORDER BY updated_at DESC) AS rn
    FROM raw_transactions
)
SELECT * FROM ranked WHERE rn = 1 AND tie_count > 1;  -- report ties for manual review
```

#### Edge 7-B: Dedup after a JOIN that fans out

**Problem:**

```sql
-- Join transactions to a many-to-many mapping table (e.g., txn_id can have multiple tags)
-- Then try to dedup on txn_id — the dedup doesn't undo the fanout, it just picks one row

SELECT DISTINCT t.txn_id, t.amount, tag.tag_name
FROM transactions t
JOIN txn_tags tag ON t.txn_id = tag.txn_id;
-- DISTINCT doesn't help here — (txn_id, amount, tag_name) is different for each tag
-- If you want one row per txn_id: decide WHICH tag to keep (latest? first? all as array?)
```

**Fix — aggregate the tags first, then join:**

```sql
-- FIX — aggregate the tags first, then join:
SELECT t.txn_id, t.amount,
       STRING_AGG(tag.tag_name, ', ' ORDER BY tag.tag_name) AS tags
FROM transactions t
LEFT JOIN txn_tags tag ON t.txn_id = tag.txn_id
GROUP BY t.txn_id, t.amount;
```

#### Edge 7-C: Dedup using a hash key that doesn't capture all meaningful columns

**Problem:**

```sql
-- Hash-based dedup: two rows are "duplicates" if their hash matches
-- TRAP: if you hash only (txn_id, amount) but not (status), a status update creates a new hash
-- → the updated row is NOT deduped against the original → both rows survive!

-- Always hash every column that should determine uniqueness:
MD5(CONCAT_WS('|',
    CAST(txn_id AS VARCHAR),
    CAST(amount AS VARCHAR),
    status,            -- include status!
    merchant_id,       -- include merchant!
    CAST(txn_date AS VARCHAR)
)) AS row_hash

-- Opposite trap: hashing too many columns (including audit columns like created_at)
-- means every insert looks like a new unique row even if the business key is the same
-- Rule: hash only BUSINESS key columns + business value columns; exclude audit/system columns
```

**Fix:**

```sql
-- Hash only the columns that define business uniqueness; exclude audit/system columns:
WITH deduped AS (
    SELECT *,
        MD5(CONCAT_WS('|',
            CAST(txn_id   AS VARCHAR),
            CAST(amount   AS VARCHAR),
            status,
            merchant_id,
            CAST(txn_date AS VARCHAR)
            -- exclude: created_at, updated_at, load_ts (audit columns)
        )) AS row_hash,
        ROW_NUMBER() OVER (
            PARTITION BY txn_id   -- business key
            ORDER BY updated_at DESC  -- keep the most recent version
        ) AS rn
    FROM raw_transactions
)
SELECT * FROM deduped WHERE rn = 1;
-- Rule: if two rows have the same txn_id, keep the latest updated_at regardless of hash
-- Use row_hash only to detect EXACT content duplicates across systems, not for dedup ordering
```

---

### At Scale

#### Failure Mechanism

`ROW_NUMBER() OVER (PARTITION BY txn_id ORDER BY updated_at DESC)` on 1B rows:

- Every row for the same `txn_id` must be compared inside one logical partition.
- Hot keys create skew: one transaction or account with many versions can dominate runtime.
- Deleting duplicates after ranking usually causes a second full-table write path.

#### Code-Level Fix

```sql
-- Keep the source bounded before ranking.
WITH recent_versions AS (
    SELECT *
    FROM raw_transactions
    WHERE ingested_at >= CURRENT_DATE - INTERVAL '30' DAY
),
ranked AS (
    SELECT *,
        ROW_NUMBER() OVER (
            PARTITION BY txn_id
            ORDER BY updated_at DESC, source_priority ASC, ingested_at DESC
        ) AS rn
    FROM recent_versions
)
SELECT *
FROM ranked
WHERE rn = 1;
```

#### System-Level Fix

```sql
-- Maintain a current-state table instead of ranking the full history for every query.
MERGE INTO current_transactions AS target
USING staged_transactions AS source
    ON target.txn_id = source.txn_id
WHEN MATCHED AND source.updated_at > target.updated_at THEN
    UPDATE SET
        amount = source.amount,
        status = source.status,
        updated_at = source.updated_at
WHEN NOT MATCHED THEN
    INSERT (txn_id, amount, status, updated_at)
    VALUES (source.txn_id, source.amount, source.status, source.updated_at);
```

---

---

