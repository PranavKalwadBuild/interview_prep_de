<!-- Part of sql-patterns: Silent Errors — Incremental and CDC Patterns -->

# Silent Errors — Incremental and CDC Patterns

Incremental pipelines trade correctness guarantees for performance. Every incremental model makes an assumption about data arrival order, update semantics, or key uniqueness — and every one of those assumptions can be violated in production. When they are, the pipeline continues running, producing results, and nobody knows the results are wrong until an audit compares to a full-refresh baseline.

---

### Watermark on Mutable updated_at — Backdated Corrections Never Captured

**What it looks like:**
```sql
-- dbt incremental model filter
{% if is_incremental() %}
WHERE updated_at > (SELECT MAX(updated_at) FROM {{ this }})
{% endif %}
```

**What actually happens:** The watermark is the maximum `updated_at` seen so far. Any row that exists in the source with `updated_at` older than the watermark is silently skipped — forever. This is intentional for new rows that arrive late. But it also silently misses *corrections* where the source system backdated the `updated_at` field to when the event actually occurred rather than when it was corrected.

**Why it's insidious:** The pipeline runs successfully on every schedule. The incremental filter is working as designed. The missed rows are rows the pipeline has already "seen" (by watermark logic), so they are never re-ingested. There is no error, no gap in the output, just wrong values for the corrected rows — which continue to carry their pre-correction values in the warehouse.

**Minimal repro:**
```sql
-- Day 1: watermark set to 2024-01-10 12:00:00
-- Day 2: source corrects a row, setting updated_at = 2024-01-09 08:00:00
--         (backdated to when the event actually occurred)
-- Incremental filter: WHERE updated_at > '2024-01-10 12:00:00'
-- The corrected row has updated_at = 2024-01-09 08:00:00
-- 2024-01-09 < 2024-01-10 → row NEVER picked up → silent wrong value in warehouse

-- Detection:
SELECT s.id, s.value AS source_value, t.value AS target_value
FROM source_table s
JOIN target_table t ON s.id = t.id
WHERE s.value != t.value;  -- finds rows where source was corrected but target wasn't
```

**How to catch it:**
```sql
-- Add a lookback window to the watermark filter:
{% if is_incremental() %}
WHERE updated_at > (SELECT MAX(updated_at) FROM {{ this }}) - INTERVAL '3 days'
{% endif %}
-- The 3-day window catches late corrections that were backdated up to 3 days ago.
-- Cost: 3 extra days of data re-processed on every run.
-- Benefit: corrections within the lookback window are captured.

-- Also: use loaded_at (when the row arrived in the staging layer) as watermark,
-- not updated_at (when the event happened), to avoid this class of bug.
```

**Real-world trigger:** Customer address correction in a CRM. The CRM backdates the `updated_at` to the date the customer originally reported the wrong address. The warehouse continues to show the wrong address for 6 months. A mailing campaign sends physical mail to wrong addresses using the warehouse data.

---

### MAX(updated_at) Watermark with Late-Arriving Data — Silent Permanent Miss

**What it looks like:**
```sql
-- Kafka consumer lag: events from 2 hours ago arrive now
-- Incremental model ran 1 hour ago, set watermark = NOW() - 1 hour
-- Late events: updated_at = 2 hours ago (before the watermark)
```

**What actually happens:** Events that arrive at the warehouse *after* the incremental model runs but have timestamps *before* the watermark are permanently skipped. The pipeline has "moved past" those events' timestamps. The data exists in the source, exists in the raw/staging layer, but is never picked up by the incremental model. No error. No warning. Just a hole in the data.

**Why it's insidious:** The staging/raw layer is complete. The incremental model is the point of permanent loss. Any monitoring of the raw layer shows healthy data. Only monitoring of the final model vs the source shows the gap — and most teams monitor the pipeline health (did it run? did it error?) not the data completeness.

**Minimal repro:**
```sql
-- Simulate: watermark is T-60min, late event has updated_at = T-120min
-- Pipeline runs at T=0, sets watermark to T-60min
-- At T=5min, Kafka delivers event with event_time = T-120min
-- Next pipeline run at T=60min: WHERE updated_at > T-60min skips this event
-- The event at T-120min is now permanently lost from the incremental model.

-- Detection query (run on schedule):
SELECT COUNT(*) AS missed_late_events
FROM raw_events r
WHERE r.updated_at < (SELECT MAX(updated_at) - INTERVAL '5 minutes' FROM target_model)
  AND NOT EXISTS (SELECT 1 FROM target_model t WHERE t.id = r.id AND t.updated_at = r.updated_at);
```

**How to catch it:**
```sql
-- Strategy 1: Always use loaded_at (ingestion timestamp) as watermark, not event timestamp.
-- loaded_at is monotonically increasing; event timestamps can arrive out of order.
WHERE _loaded_at > (SELECT MAX(_loaded_at) FROM {{ this }})

-- Strategy 2: Use a lookback window sized to your p99 late-arrival latency.
-- If p99 Kafka lag is 4 hours, use a 4-hour lookback:
WHERE updated_at > (SELECT MAX(updated_at) FROM {{ this }}) - INTERVAL '4 hours'

-- Strategy 3: Schedule periodic full refreshes to clear accumulated drift.
```

**Real-world trigger:** Payment events stream via Kafka. Kafka consumer group experiences a 2-hour lag during a cluster rebalance. By the time the lagged events reach the warehouse staging layer, the incremental model's watermark has moved past them. $12M in payment events is permanently missing from the fact table. Discovered during month-end reconciliation.

---

### SCD Type 2 Batch CDC — Two Updates in Same Batch Window Collapse to One

**What it looks like:**
```sql
-- SCD Type 2 pipeline processes changes once per hour
-- Source system updates customer status: 'active' → 'suspended' → 'active' (within 1 hour)
-- Pipeline sees: old state = 'active', new state = 'active' → no change detected
```

**What actually happens:** The pipeline compares the previous batch snapshot to the current snapshot. If a record changes and changes back within a single batch window, the pipeline sees no net change. The intermediate state (`'suspended'`) is permanently lost from SCD history. A compliance report asking "was this customer ever suspended?" returns FALSE when the answer is TRUE.

**Why it's insidious:** The SCD logic is correct — it correctly detects that the state at the end of the batch matches the state at the beginning. The problem is the batch granularity is too coarse to capture all transitions. No error, no failed assertion. The history table is internally consistent; it just doesn't have complete coverage of state transitions.

**Minimal repro:**
```sql
-- Batch 1 (T=0): status = 'active'
-- Source changes at T=10min: status = 'suspended'
-- Source changes at T=50min: status = 'active'
-- Batch 2 (T=60min): pipeline reads status = 'active'
-- SCD change detection: 'active' == 'active' → no new SCD row created
-- Intermediate 'suspended' state is permanently lost

-- Detection: compare SCD transition count to source audit log count:
SELECT COUNT(*) AS scd_transitions FROM scd_customer WHERE customer_id = 123;
SELECT COUNT(*) AS audit_transitions FROM customer_audit_log WHERE customer_id = 123;
-- If audit > scd, transitions within batch windows were collapsed.
```

**How to catch it:**

**Real-world trigger:** Financial regulatory audit requires complete account status history. A customer's account was briefly suspended for fraud review and reinstated within 45 minutes — within a single hourly batch window. The SCD table shows continuous "active" status. Regulatory report shows no suspension history. Compliance failure discovered during audit.

---

### dbt Incremental with on_schema_change='append_new_columns' — Historical NULLs Corrupt Metrics

**What it looks like:**
```sql
-- dbt_project.yml:
-- on_schema_change: append_new_columns

-- Month 1: model has columns (user_id, revenue)
-- Month 2: new column added (subscription_tier)
-- All historical rows: subscription_tier = NULL
```

**What actually happens:** When a new column is added to an incremental model with `append_new_columns`, dbt adds the column to the existing table and populates it as NULL for all historical rows. Any downstream metric that uses `COALESCE(subscription_tier, 'free')` treats all historical rows as `'free'` tier — even if those users were paying customers before the column existed.

**Why it's insidious:** The new column has NULL for historical data by design. `COALESCE` with a default looks like defensive coding. The result is that every historical analysis of `subscription_tier` gives the wrong breakdown, attributing historical revenue to the wrong tier. The error is systematic and undetectable without a full-refresh comparison.

**Minimal repro:**
```sql
-- After adding subscription_tier column:
SELECT
    subscription_tier,
    SUM(revenue) AS tier_revenue
FROM user_activity
GROUP BY 1;

-- Returns: free=100% (all historical), premium=0%
-- Reality: premium tier existed for 6 months before the column was added.
-- COALESCE made NULL → 'free' for all of history.
```

**How to catch it:**
```sql
-- Check for suspicious NULL rates in newly added columns:
SELECT
    COUNT(*) AS total,
    COUNT(subscription_tier) AS non_null,
    100.0 * COUNT(subscription_tier) / COUNT(*) AS pct_non_null
FROM user_activity;
-- If pct_non_null < 50% and the model has been running for a long time,
-- you likely have historical NULL pollution.

-- Always treat newly added columns with NULL-inclusive analysis until
-- they are backfilled or the historical period is explicitly excluded:
WHERE created_at >= '2024-02-01'  -- only after the column started being populated
```

**Real-world trigger:** Product analytics team adds `plan_type` column to user activity model. Six months of history have NULL plan_type. MoM comparison of "Enterprise plan revenue" shows 0% for all pre-column months vs realistic numbers for post-column months. Trend chart shows a hockey stick that looks like explosive growth — actually just the point where NULLs stopped.

---

### Idempotency Violation — Wrong Merge Key Inserts Duplicates on Re-run

**What it looks like:**
```sql
-- dbt incremental with unique_key
{{ config(
    materialized='incremental',
    unique_key='order_id'
) }}

SELECT order_id, user_id, amount, updated_at
FROM source_orders
```

**What actually happens:** If `order_id` is not actually unique in the source (e.g., an order can have multiple line items that were joined incorrectly), the MERGE/INSERT operation will insert multiple rows per `order_id`. On subsequent runs, the rows with the same `order_id` but different other values will conflict, and the behavior depends on the merge strategy. With INSERT (no MERGE), duplicates accumulate. With MERGE and a non-unique key, only one row survives — potentially the wrong one.

**Why it's insidious:** The model runs successfully every time. The `unique_key` in dbt's configuration is a *hint* for merge behavior, not a validated constraint. If the source violates uniqueness, the model silently accepts duplicates or silently drops data during merge reconciliation.

**Minimal repro:**
```sql
-- Source has two rows for the same order_id (join fanout):
-- (order_id=1, user_id=A, amount=100)
-- (order_id=1, user_id=A, amount=100)  -- duplicate from fanout

-- dbt MERGE on unique_key='order_id' will MERGE one row and INSERT the other
-- OR silently drop one row depending on order of operations.
-- Result: one row in the target, but which one depends on execution order.

-- Detection:
SELECT unique_key_col, COUNT(*) FROM {{ source_model }} GROUP BY 1 HAVING COUNT(*) > 1;
```

**How to catch it:**
```sql
-- Before building an incremental model, validate uniqueness of the unique_key:
SELECT order_id, COUNT(*) AS cnt
FROM source_orders
GROUP BY order_id
HAVING COUNT(*) > 1;
-- If any rows returned, the unique_key will not work correctly.

-- In dbt: add a test:
-- tests:
--   - unique:
--       column_name: order_id
```

**Real-world trigger:** Orders model uses `order_id` as unique_key, but a recent join to a promotions table introduced fanout (orders with multiple promotions = multiple rows). Incremental model silently drops 30% of order rows (the "losing" row in each MERGE conflict). Revenue metrics drop by 30% overnight, triggering a P0 incident.

---

### IS DISTINCT FROM Missing in CDC Change Detection — Missed and False Changes

**What it looks like:**
```sql
-- Change detection in SCD pipeline
SELECT s.*
FROM source s
JOIN target t ON s.id = t.id
WHERE s.email != t.email        -- wrong: misses NULL→NULL (no change treated as change on some engines)
   OR s.phone != t.phone        -- wrong: misses value→NULL and NULL→value transitions
```

**What actually happens:**
- `s.email != t.email` when both are NULL: evaluates to UNKNOWN → row not included as "changed" (correct by accident, but unreliable)
- `s.email != t.email` when one is NULL and one is not: evaluates to UNKNOWN → row NOT included as "changed" (WRONG — this IS a real change)
- `s.email != t.email` when both are the same non-NULL value: evaluates to FALSE → not a change (correct)

The result: real changes that involve a NULL transition are silently missed. New change records are not created in the SCD table. Historical accuracy is compromised.

**Minimal repro:**
```sql
WITH changes AS (
    SELECT * FROM (VALUES
        ('a@b.com', 'a@b.com', 'same, no change'),
        ('a@b.com', 'c@d.com', 'value changed'),
        ('a@b.com', NULL,      'deleted to NULL'),  -- real change, != misses it
        (NULL,      'a@b.com', 'added from NULL'),  -- real change, != misses it
        (NULL,      NULL,      'both NULL, no change')
    ) t(old_email, new_email, scenario)
)
SELECT scenario,
       old_email != new_email                          AS wrong_neq_detects_change,
       old_email IS DISTINCT FROM new_email            AS correct_isdf_detects_change
FROM changes;
```

**How to catch it:**
```sql
-- Always use IS DISTINCT FROM for change detection:
WHERE s.email IS DISTINCT FROM t.email
   OR s.phone IS DISTINCT FROM t.phone
-- IS DISTINCT FROM treats NULL as a value: NULL IS DISTINCT FROM 'x' = TRUE
-- NULL IS DISTINCT FROM NULL = FALSE (correct: no change)
```

**Real-world trigger:** Customer contact info SCD. Customers who delete their phone number (setting it to NULL) don't trigger an SCD update because `old_phone != NULL` is UNKNOWN. The SCD table retains the old phone number indefinitely. GDPR erasure requests that null out PII fields are silently not captured in the SCD history.

---

### Dedup by Column Hash — Partial-Column Hashing Drops Legitimate Distinct Rows

**What it looks like:**

**What actually happens:** If `CONCAT` is used without NULL handling, `CONCAT(user_id, '|', NULL, '|', event_date)` may return NULL or the NULL may be coerced to an empty string, making `event_type = NULL` and `event_type = ''` hash to the same value. Two genuinely different rows (one with event_type NULL, one with event_type='') are treated as duplicates and one is silently dropped.

**Why it's insidious:** The hashing logic looks defensive. The deduplication looks thorough. The bug only fires when NULLable columns are present in the hash key — which is common for optional fields. The dropped row is a real event.

**Minimal repro:**
```sql
WITH events AS (
    SELECT * FROM (VALUES
        (1, NULL,    '2024-01-01'),
        (1, '',      '2024-01-01'),   -- different from NULL, but may hash same
        (1, 'click', '2024-01-01')
    ) t(user_id, etype, edate)
)
SELECT
    MD5(CONCAT(user_id::TEXT, '|', etype, '|', edate)) AS hash_val,
    *
FROM events;
-- NULL and '' produce different hashes in most engines
-- But CONCAT(1, '|', NULL, '|', '2024-01-01') may return NULL (not a hash collision)
-- The NULL hash itself causes both rows to be assigned hash=NULL and treated as same group

-- Fix: use COALESCE in hash to make NULLs explicit:
MD5(CONCAT(
    COALESCE(user_id::TEXT, '\x00'), '|',
    COALESCE(etype, '\x00'), '|',
    COALESCE(edate::TEXT, '\x00')
))
```

**How to catch it:**
```sql
-- Before dedup: count rows where any hash component is NULL:
SELECT COUNT(*) FROM events WHERE user_id IS NULL OR etype IS NULL OR edate IS NULL;
-- If > 0, the CONCAT-based hash may produce NULL or collapse distinct rows.
```

**Real-world trigger:** Event pipeline deduplicates using MD5 hash of event fields. A new event type has optional metadata that is sometimes NULL. All events with NULL metadata hash to NULL, causing `ROW_NUMBER() OVER (PARTITION BY NULL)` to group all NULL-hash events together — and keep only one. A large batch of legitimate distinct events is collapsed to a single row.
