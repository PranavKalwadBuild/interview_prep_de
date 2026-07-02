<!-- data-modelling-patterns: Extraction Patterns — Full, Watermark, CDC, Idempotency -->

# Extraction Patterns

---

## Extraction Patterns

> **Keywords to spot:** "how do you get data from the source", "incremental load", "CDC", "change data capture", "watermark", "full pull", "delta load", "out of order data"

---

### Full Extraction

Pull every row from the source table on every run. Simple. Correct. Expensive at scale.

```sql
-- Every pipeline run: SELECT * FROM source table
SELECT * FROM source.orders;
```

**When it's appropriate:** Small tables (< 1M rows), tables with no reliable update timestamp, initial historical loads, or dimension tables that change infrequently.

**Gotcha:** A 500M-row orders table with a full pull on every run will eventually become unaffordable. Design for incremental from day one on large tables.

---

### Incremental Extraction — Watermark / High-Water Mark

Track a marker (timestamp or sequential ID) representing the last successfully processed record. Each run fetches only rows newer than the last marker.

```sql
-- Metadata table tracking the last run watermark
CREATE TABLE pipeline_watermarks (
    pipeline_name   VARCHAR(100) PRIMARY KEY,
    last_loaded_at  TIMESTAMP,
    last_loaded_id  BIGINT
);

-- Extract only new/changed rows
SELECT *
FROM source.orders
WHERE updated_at > (
    SELECT last_loaded_at
    FROM pipeline_watermarks
    WHERE pipeline_name = 'orders_incremental'
);

-- After successful load, advance the watermark
UPDATE pipeline_watermarks
SET last_loaded_at = CURRENT_TIMESTAMP
WHERE pipeline_name = 'orders_incremental';
```

**Requirements:**
- Source table must have a reliable `updated_at` or `created_at` timestamp, or a monotonically increasing integer ID
- The column must be indexed on the source — otherwise each incremental pull becomes a full scan anyway

**Critical limitation:** Watermark-based extraction **cannot detect hard deletes**. If a row is deleted from the source, the watermark query will never see it because it queries for rows where `updated_at > watermark` — deleted rows no longer exist. To detect deletes, you need CDC or a periodic full reconciliation count.

---

### CDC — Change Data Capture

CDC captures every INSERT, UPDATE, and DELETE from the source database as it happens, by reading the database's internal transaction log rather than querying the data itself.

**Three CDC approaches:**

**1. Log-Based CDC (preferred)**

Reads from the database's write-ahead log (WAL in PostgreSQL, redo log in Oracle, binary log in MySQL). Every committed change is captured in the exact order it occurred, including deletes.

```
Source DB → Transaction Log → CDC Tool (Debezium, Fivetran) → Message Queue (Kafka) → Warehouse
```

| Property | Detail |
|---|---|
| Latency | Near real-time (seconds) |
| Source impact | Minimal — reads log, not production tables |
| Captures deletes | Yes |
| Captures column-level changes | Yes (old value + new value) |
| Complexity | High (log access requires elevated privileges, replication slot management) |
| Tools | Debezium, AWS DMS, Fivetran |

**2. Trigger-Based CDC**

Database triggers fire on INSERT/UPDATE/DELETE and write a copy of the changed row to a shadow/audit table.

```sql
-- Trigger writes every change to an audit table
CREATE TRIGGER orders_cdc
AFTER INSERT OR UPDATE OR DELETE ON source.orders
FOR EACH ROW EXECUTE FUNCTION log_order_change();
```

| Property | Detail |
|---|---|
| Latency | Low |
| Source impact | **High** — every write triggers an additional write (write amplification) |
| Captures deletes | Yes |
| Complexity | Medium |
| When to use | When log access is unavailable (managed cloud DBs) |

**Gotcha:** On high-throughput OLTP tables (thousands of writes/second), trigger-based CDC can degrade source database performance significantly. Don't use it on hot tables.

**3. Polling-Based CDC**

Periodically queries the source table for rows where `updated_at > last_poll_time`. The simplest approach — essentially a scheduled watermark query.

| Property | Detail |
|---|---|
| Latency | Depends on poll frequency (minutes to hours) |
| Source impact | Medium — runs a query on each poll cycle |
| Captures deletes | **No** — deleted rows are gone |
| Complexity | Low |
| When to use | Low-change tables, loose freshness requirements, when log/trigger access is impossible |

**CDC comparison:**

| | Log-Based | Trigger-Based | Polling |
|---|---|---|---|
| Captures deletes | ✅ | ✅ | ❌ |
| Source performance impact | ✅ Minimal | ❌ High | Medium |
| Latency | ✅ Seconds | ✅ Seconds | ❌ Minutes–Hours |
| Implementation complexity | ❌ High | Medium | ✅ Low |
| Schema change handling | Complex | Brittle | Simple |

---

### Idempotency

**Definition:** A pipeline is idempotent if running it once or running it ten times produces exactly the same result. No duplicate rows, no phantom deletes, no partial state.

**Why it matters:** Pipelines fail. Networks time out. Clusters crash mid-run. If re-running a failed pipeline inserts rows a second time or corrupts partially loaded state, you have a data integrity problem that is hard to detect and expensive to fix.

**Implementation patterns:**

```sql
-- Pattern 1: MERGE (upsert) — idempotent by definition
-- Running this 3 times produces the same result as running it once
MERGE INTO target.orders AS t
USING staging.orders_delta AS s
    ON t.order_id = s.order_id
WHEN MATCHED AND s.updated_at > t.updated_at THEN
    UPDATE SET
        t.status       = s.status,
        t.total_amount = s.total_amount,
        t.updated_at   = s.updated_at
WHEN NOT MATCHED THEN
    INSERT (order_id, customer_id, status, total_amount, created_at, updated_at)
    VALUES (s.order_id, s.customer_id, s.status, s.total_amount, s.created_at, s.updated_at);

-- Pattern 2: DELETE partition + INSERT (idempotent for partitioned fact tables)
-- Delete yesterday's partition, then reload it cleanly
DELETE FROM fact_orders WHERE order_date = '2024-11-15';
INSERT INTO fact_orders SELECT ... FROM silver.orders WHERE order_date = '2024-11-15';

-- Pattern 3: CREATE OR REPLACE (for full-refresh tables)
CREATE OR REPLACE TABLE gold.dim_product AS
SELECT ... FROM silver.products;
```

**Non-idempotent pattern to avoid:**

```sql
-- BAD: append-only load with no deduplication
-- Running twice loads every row twice
INSERT INTO fact_orders
SELECT * FROM staging.orders_delta;
```

**Gotchas:**
- MERGE is the most robust idempotent pattern but requires a natural key to match on. Without a reliable natural key, MERGE breaks.
- Partition replace (DELETE + INSERT) is faster than MERGE for large fact table partitions and is idempotent as long as you delete before inserting. Inserting before deleting is not idempotent.
- Append-only pipelines (for raw/Bronze tables) are intentionally not idempotent. Bronze is the one layer where duplicates are acceptable — deduplication happens in Silver.
