<!-- data-modelling-patterns: Silent Errors — Incremental and CDC Silent Bugs -->

<!-- Part of Data_modelling: Silent Errors — Incremental and CDC Silent Bugs -->

# Silent Errors — Incremental and CDC Silent Bugs

Incremental load patterns and Change Data Capture (CDC) are the backbone of modern pipelines.
They also harbour some of the most dangerous silent errors — bugs where no job fails, no alert
fires, and the data looks complete while silently losing or corrupting records. The characteristic
of these errors is that they are stateful: the bug affects not just one run but accumulates over
time, making detection progressively harder.

---

### 1. Watermark on Mutable Timestamp Misses Soft-Deletes

**What it looks like:**
An incremental model uses `updated_at > last_max_updated_at` as its watermark. Source records are
deleted by setting `deleted_at = NOW()` without touching `updated_at`.

**What actually happens:**
The incremental load never sees the deletion. The target table retains rows that were soft-deleted
in the source. Over time, the target accumulates all the soft-deleted records that were never
tombstoned.

**Why it's insidious:**
The incremental job succeeds on every run. Row counts in the target grow — which looks healthy.
The deleted records have valid data. No FK violation, no NULL. The mismatch is only visible when
comparing source active-record count to target count.

**Example:**
```sql
-- Incremental model watermark
WHERE updated_at > (SELECT MAX(updated_at) FROM target_customers)

-- Source system soft-delete (does NOT touch updated_at):
UPDATE source_customers
SET deleted_at = '2024-08-15'
WHERE customer_id = 9901;
-- updated_at remains '2024-01-01' — watermark never picks this up
-- target_customers.customer_id = 9901 persists indefinitely

-- Later query on target:
SELECT COUNT(*) FROM target_customers WHERE deleted_at IS NULL;  -- always includes 9901
```

**Detection query / invariant:**
```sql
-- Compare active record counts between source and target
SELECT
    (SELECT COUNT(*) FROM source_customers WHERE deleted_at IS NULL) AS source_active,
    (SELECT COUNT(*) FROM target_customers WHERE deleted_at IS NULL) AS target_active,
    (SELECT COUNT(*) FROM target_customers WHERE deleted_at IS NULL)
    - (SELECT COUNT(*) FROM source_customers WHERE deleted_at IS NULL) AS ghost_records;

-- Ghost records > 0 = soft-deletes not being propagated
-- Fix: change watermark to MAX(GREATEST(updated_at, COALESCE(deleted_at, '1900-01-01')))
```

**Real-world consequence:**
A GDPR right-to-erasure deletion request marks a user's records as `deleted_at`. The downstream
warehouse still holds all their data 6 months later. A compliance audit finds 40,000 ghost records
that should have been deleted. Legal exposure is significant.

---

### 2. Late-Arriving CDC Events Skipped Permanently

**What it looks like:**
A Kafka-based CDC pipeline processes events with `WHERE event_timestamp > last_processed_watermark`.
The current watermark is advanced after each successful batch.

**What actually happens:**
Kafka consumer lag or an upstream reprocessing event delivers a CDC event with a timestamp older
than the current watermark. The `WHERE event_timestamp > last_processed_watermark` filter silently
skips it. The event is permanently lost — the watermark has advanced past it and will never retreat.

**Why it's insidious:**
The pipeline processes successfully. The skipped event produces no error. The watermark advances
normally. The only evidence is in the Kafka offset lag metrics, which are usually monitored for
performance, not data integrity.

**Example:**
```sql
-- Watermark: last_processed = 2024-10-01 12:00:00

-- Late event arrives: event_timestamp = 2024-09-30 23:55:00
-- (an order status update delayed 12 hours by a network partition)

-- Incremental filter skips it:
SELECT * FROM cdc_stream
WHERE event_timestamp > '2024-10-01 12:00:00';  -- 2024-09-30 event is not read

-- The order remains in 'pending' status in the warehouse indefinitely
-- even though the source system processed it to 'shipped' on Sep 30
```

**Detection query / invariant:**
```sql
-- Compare source system current state vs warehouse state for recently changed records
SELECT
    src.order_id,
    src.status         AS source_status,
    wh.status          AS warehouse_status,
    src.updated_at     AS source_updated_at,
    wh.updated_at      AS warehouse_updated_at
FROM source_orders src
JOIN warehouse_orders wh ON src.order_id = wh.order_id
WHERE src.status <> wh.status
  AND src.updated_at < CURRENT_TIMESTAMP - INTERVAL '1 hour'  -- not genuinely in-flight
ORDER BY src.updated_at;

-- Prevention: use a lookback buffer (e.g., last 72 hours) instead of strict watermark
WHERE event_timestamp > last_processed_watermark - INTERVAL '72 hours'
```

**Real-world consequence:**
An order status correction (cancelled → refunded) made during a Kafka network event is never
applied to the warehouse. Customer service operates with stale order status for 3 weeks. Refund
is not processed for 47 customers during a high-volume sale period.

---

### 3. Dual-Write CDC Race Condition (DB Write Without Kafka Publish)

**What it looks like:**
A source system writes to its database AND publishes to Kafka. Downstream CDC consumers read
from Kafka. Both paths are assumed to be equivalent.

**What actually happens:**
The database COMMIT succeeds. The Kafka PUBLISH fails (broker timeout, producer buffer overflow).
The source application does not retry the Kafka event. The database has the change; the Kafka
stream does not. The CDC consumer never sees this event. No error is raised in any system.

**Why it's insidious:**
The database is the system of record and it is correct. Kafka is the transport and it silently
dropped the event. The CDC pipeline ran successfully. Row counts look normal. The missing event
is undetectable from the warehouse side without reconciling against the source DB.

**Example:**
```
Source application code:
  1. BEGIN TRANSACTION
  2. UPDATE orders SET status = 'paid' WHERE order_id = 5001
  3. COMMIT                           ← DB has the change
  4. kafka_producer.send(event)       ← Silently fails, no retry
                                      ← Warehouse never sees status='paid'

Result: source DB shows order 5001 as 'paid', warehouse shows 'pending'
No job failure. No alert. No error log in Kafka consumer.
```

**Detection query / invariant:**
```sql
-- Periodic reconciliation: compare source DB state to warehouse state
SELECT
    src.order_id,
    src.status AS source_status,
    wh.status  AS warehouse_status
FROM source_orders src
JOIN warehouse_orders wh ON src.order_id = wh.order_id
WHERE src.status <> wh.status
  AND src.updated_at < CURRENT_TIMESTAMP - INTERVAL '5 minutes'  -- allow CDC propagation delay
LIMIT 100;
-- Persistent mismatches = dual-write failures

-- Preferred architecture: use log-based CDC (Debezium reading WAL/binlog) instead of
-- application-level dual-write. Log-based CDC cannot miss what the DB committed.
```

**Real-world consequence:**
Payment status never reaches the warehouse for ~0.1% of orders during high-traffic periods
(exactly when the Kafka broker is most stressed). Billing reconciliation is off by 0.1% each
month — small enough to be dismissed as "rounding" for years.

---

### 4. Batch CDC Captures Only Final State — Intermediate States Permanently Lost

**What it looks like:**
A batch CDC process runs once per hour. It compares source table snapshots and captures changes.

**What actually happens:**
Two updates to the same row occur within one hour batch window. The CDC batch captures only the
net difference (current state vs. prior snapshot). The intermediate state is permanently lost.
For audit trail requirements or SCD Type 2 dimension builds, this creates an invisible gap.

**Why it's insidious:**
The final state in the warehouse matches the source exactly. Row-by-row data validation passes.
The missing state is only detectable if you have an independent audit log or knew the row had
two updates.

**Example:**
```
Source row at 10:00 AM: customer_tier = 'Silver'
Source row at 10:15 AM: customer_tier updated to 'Gold'  (first update, within batch window)
Source row at 10:45 AM: customer_tier updated to 'Platinum' (second update, within batch window)

Batch CDC runs at 11:00 AM, compares to 10:00 AM snapshot:
Captured: Silver → Platinum  (captures the net change)
Lost: Silver → Gold → Platinum  (intermediate Gold state is invisible)

SCD Type 2 dimension built from this CDC stream:
- Row 1: Silver, 2024-01-01 to 2024-07-15
- Row 2: Platinum, 2024-07-15 onwards
-- The 'Gold' tier period never existed in the dimension history
```

**Detection query / invariant:**
```sql
-- If you have an application-level audit log, compare against CDC captures
SELECT al.entity_id, al.new_value, al.change_timestamp
FROM application_audit_log al
WHERE NOT EXISTS (
    SELECT 1 FROM cdc_captured_changes cc
    WHERE cc.entity_id = al.entity_id
      AND cc.change_value = al.new_value
      AND ABS(DATEDIFF('minute', cc.captured_at, al.change_timestamp)) < 60
);
-- Rows here = intermediate states missed by batch CDC
```

**Real-world consequence:**
A financial services customer was briefly classified as 'Gold' tier for 30 minutes — qualifying
for a Gold-tier fee waiver on a transaction that occurred in that window. The warehouse never
saw the Gold state, so the fee waiver is not applied. Customer disputes the charge. The evidence
that the Gold state existed is in application logs but not in the warehouse.

---

### 5. CDC Delete/Insert Out-of-Order Processing (Kafka Partition Rebalance)

**What it looks like:**
A Kafka CDC stream processes events in order within a partition. Consumer reads events and
applies them to the warehouse with MERGE logic.

**What actually happens:**
A Kafka partition rebalance occurs mid-stream. Some events are re-delivered from an earlier
offset. If the re-delivery order is DELETE → INSERT (instead of INSERT → DELETE), the INSERT
creates a record that should have been deleted. The row now exists in the warehouse but not in
the source.

**Why it's insidious:**
Each individual event (DELETE, INSERT) is valid. The MERGE applies them without error. The
resulting state is a ghost record that matches no source row. No FK violation, no NULL, no
schema error.

**Example:**
```
Original event order: INSERT (order_id=8000), DELETE (order_id=8000)
After partition rebalance, re-delivered in wrong order:
  1. DELETE order_id=8000 → MERGE: row doesn't exist, DELETE is no-op (no error)
  2. INSERT order_id=8000 → MERGE: row inserted (now exists in warehouse)

Source database: order 8000 was created and cancelled (hard delete)
Warehouse: order 8000 exists as an active record
```

**Detection query / invariant:**
```sql
-- Reconcile warehouse against source for recently modified records
-- (requires a source snapshot or API query)
SELECT wh.order_id
FROM warehouse_orders wh
WHERE NOT EXISTS (
    SELECT 1 FROM source_orders src WHERE src.order_id = wh.order_id
)
AND wh.created_at > CURRENT_DATE - INTERVAL '7 days';  -- narrow to recent to keep fast

-- Production safeguard: use idempotent sequencing
-- Include a sequence number or LSN in each CDC event
-- MERGE only applies an event if its sequence > the last applied sequence for that record
```

**Real-world consequence:**
A fraud detection model trained on warehouse order data learns from ghost records — orders that
were created and immediately cancelled (typical fraud pattern). Ghost records (phantom completed
orders) contaminate the training set, reducing model precision on the cancellation signal.

---

### 6. Idempotency Key Collision Across Multiple Source Systems

**What it looks like:**
Two source systems are merged into a unified warehouse. Both use a numeric `customer_id` as
natural key. The incremental MERGE uses `customer_id` as the unique key for upsert logic.

**What actually happens:**
Both systems have independently assigned `customer_id = 1001` to completely different customers.
The MERGE upserts the second system's `customer_id = 1001` on top of the first system's row.
One customer's entire record is silently overwritten with another customer's data.

**Why it's insidious:**
The MERGE executes without error. The resulting row is internally consistent. The overwritten
customer simply "disappears" from the warehouse while the surviving record has a hybrid of data
from two different people.

**Example:**
```sql
-- System A: customer_id=1001, name='Alice Johnson', revenue=50000
-- System B: customer_id=1001, name='Bob Martinez', revenue=12000
-- Both loaded to same warehouse table using customer_id as unique key:

MERGE INTO warehouse_customers USING staging ON staging.customer_id = warehouse_customers.customer_id
WHEN MATCHED THEN UPDATE SET name=staging.name, revenue=staging.revenue
WHEN NOT MATCHED THEN INSERT ...;

-- After System B load: customer_id=1001, name='Bob Martinez', revenue=12000
-- Alice Johnson (System A) is gone. Her revenue is attributed to Bob's record.
```

**Detection query / invariant:**
```sql
-- After multi-source load, check whether any natural key appears in both sources
SELECT customer_id, COUNT(DISTINCT source_system) AS source_count
FROM staging_all_sources
GROUP BY customer_id
HAVING COUNT(DISTINCT source_system) > 1;

-- Fix: compound natural key = customer_id + source_system
-- Or: generate a warehouse-internal surrogate key independent of source natural keys
SELECT MD5(CONCAT(source_system, '|', customer_id)) AS warehouse_customer_sk, ...
```

**Real-world consequence:**
A customer loyalty programme migration merges two regional systems. High-value customers from
System A are overwritten by lower-value customers from System B with the same ID. The loyalty
tier analysis ranks the wrong customers for VIP invitations. The actual VIP customers have
mysteriously disappeared from the programme.

---

### 7. dbt `is_incremental()` First-Run vs. Incremental Path Divergence

**What it looks like:**
A dbt incremental model has different logic in the `is_incremental()` branch versus the initial
full-load path. The comment says "dedup handled in incremental branch."

**What actually happens:**
On first run, `is_incremental()` is False — the full dataset loads through the non-incremental
path, which may have different dedup logic, different joins, or different transformations. All
historical records are built with first-run logic. Subsequent incremental runs use different
logic. The historical records are permanently different from what the incremental path would have
produced — and a `--full-refresh` to "fix" it would re-run the divergent first-run logic again.

**Why it's insidious:**
Both paths produce valid data. No dbt test fails. The divergence is invisible unless you compare
outputs of both paths on the same data.

**Example:**
```sql
-- models/orders_deduped.sql
{{
    config(
        materialized='incremental',
        unique_key='order_id'
    )
}}

SELECT
    order_id,
    customer_id,
{% if is_incremental() %}
    -- Incremental path: uses row_number for dedup
    ROW_NUMBER() OVER (PARTITION BY order_id ORDER BY updated_at DESC) AS rn
{% else %}
    -- Full-load path: simply takes first occurrence (different dedup logic!)
    1 AS rn
{% endif %}
FROM source_orders
{% if is_incremental() %}
WHERE updated_at > (SELECT MAX(updated_at) FROM {{ this }})
{% endif %}
QUALIFY rn = 1;

-- First run: historical records use "first occurrence" dedup
-- Subsequent runs: new records use "most recent update" dedup
-- Historical and incremental records are deduped differently forever
```

**Detection query / invariant:**
```sql
-- Run the model in full-refresh mode to a shadow table, then compare
-- dbt run --full-refresh --select orders_deduped --target shadow

SELECT
    inc.order_id,
    inc.customer_id AS incremental_customer,
    fr.customer_id  AS full_refresh_customer
FROM orders_deduped inc
JOIN orders_deduped_shadow fr ON inc.order_id = fr.order_id
WHERE inc.customer_id <> fr.customer_id;
-- Any mismatch = first-run vs incremental logic divergence

-- Best practice: write identical dedup logic for both paths
-- Use is_incremental() ONLY for the WHERE filter, not for transformation logic
```

**Real-world consequence:**
Historical order attribution data is built with one dedup rule. New orders use another. A
year-end cohort analysis joins historical and recent orders, comparing attribution across the
cohort split — but the two halves of the dataset used different attribution logic. The cohort
comparison is invalid and produces wrong conclusions about customer behaviour changes.

---

### 8. Incremental Lookback Window Too Narrow — Systematic Late Data Loss

**What it looks like:**
A dbt incremental model uses a 1-hour lookback buffer:
`WHERE updated_at > (SELECT MAX(updated_at) FROM {{ this }}) - INTERVAL '1 hour'`

**What actually happens:**
Upstream data sources have variable latency. Some events (mobile SDK offline events, delayed
webhook retries, partner system batch loads) arrive 4–24 hours late. The 1-hour buffer covers
only 60% of late arrivals. The remaining 40% arrive after the lookback window has already passed
and are permanently missed.

**Why it's insidious:**
The model runs successfully. Most data is correct. The missing 40% of late events is small
relative to total volume (perhaps 2% of daily records) but is systematically biased toward
specific event types (offline activity, partner-sourced events). The bias only becomes visible
in segment analyses where those events are important.

**Example:**
```sql
-- Incremental filter
WHERE updated_at > (SELECT MAX(updated_at) FROM {{ this }}) - INTERVAL '1 hour'

-- Mobile offline events: created on device at 9 PM, synced when reconnected at 2 AM (+5 hours)
-- Partner batch events: processed every 6 hours, may arrive +6 hours late
-- Both types consistently miss the 1-hour lookback window
-- Result: mobile activity and partner transactions are systematically undercounted
```

**Detection query / invariant:**
```sql
-- Analyze late arrival distribution for your specific source
SELECT
    DATEDIFF('hour', event_created_at, event_received_at) AS arrival_lag_hours,
    COUNT(*) AS event_count,
    SUM(COUNT(*)) OVER (ORDER BY arrival_lag_hours ROWS UNBOUNDED PRECEDING)
        / SUM(COUNT(*)) OVER () AS cumulative_pct
FROM source_events_raw
WHERE event_received_at >= CURRENT_DATE - INTERVAL '30 days'
GROUP BY 1
ORDER BY 1;
-- Use p99 of arrival_lag_hours as your lookback buffer, not p50
```

**Real-world consequence:**
Mobile app engagement metrics consistently undercount by 8% because offline events have a typical
5-6 hour lag. Product team concludes mobile engagement is declining and launches an urgent
redesign. The actual decline is 2% — the additional 6% gap was always there, caused by the
narrow lookback window.
