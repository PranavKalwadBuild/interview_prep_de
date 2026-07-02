<!-- data-modelling-patterns: Incremental Patterns -->

# Incremental Patterns

## Append-Only

New rows are inserted; existing rows are never modified. The source system guarantees that every event is immutable once written.

```sql
-- Snowflake dbt incremental model (append-only)
{{ config(
    materialized='incremental',
    incremental_strategy='append',
    partition_by={'field': 'event_date', 'data_type': 'date'},
    on_schema_change='append_new_columns'
) }}

SELECT *
FROM {{ source('raw', 'events') }}
{% if is_incremental() %}
WHERE received_at > (SELECT MAX(received_at) FROM {{ this }})
{% endif %}
```

**When correct**: Immutable event logs (CDRs, product analytics events, audit trails). Events are never retroactively corrected at the source. The source guarantees at-least-once or exactly-once delivery.

**How late-arriving data breaks it**: If events arrive with `event_timestamp` older than the incremental watermark, they are inserted as new rows (correct behavior if the filter is on `received_at`). But if the incremental filter is on `event_timestamp`, late-arriving events are silently dropped — they pre-date the watermark and the incremental model ignores them. The fix is to always use `received_at` (load time) as the incremental filter, and carry `event_timestamp` as a separate payload column.

## Upsert (MERGE)

Rows are inserted if new; updated if the key already exists. This is the correct pattern for slowly changing source tables where rows represent current state.

```sql
-- Snowflake MERGE for SCD Type 1
MERGE INTO dim_customer AS target
USING (
    SELECT
        customer_id,
        email_address,
        loyalty_tier,
        CURRENT_TIMESTAMP AS updated_at
    FROM raw.customer_updates
    WHERE processed_at > $WATERMARK
) AS source
ON target.customer_id = source.customer_id AND target.is_current = TRUE
WHEN MATCHED AND (
    target.email_address != source.email_address
    OR target.loyalty_tier != source.loyalty_tier
) THEN UPDATE SET
    target.email_address = source.email_address,
    target.loyalty_tier = source.loyalty_tier,
    target.dw_updated_at = source.updated_at
WHEN NOT MATCHED THEN INSERT (
    customer_id, email_address, loyalty_tier, dw_inserted_at, dw_updated_at, ...
) VALUES (
    source.customer_id, source.email_address, source.loyalty_tier,
    source.updated_at, source.updated_at, ...
);
```

**How late-arriving data breaks it**: If a MERGE processes records out of order — update A arrives, then update B (older than A) arrives — the MERGE will overwrite the correct A values with the older B values. The fix is an `AND source.updated_at >= target.dw_updated_at` guard in the WHEN MATCHED condition, rejecting out-of-order updates.

## Delete + Reinsert (Partition Replacement)

The target partition(s) are dropped and replaced atomically. This is the most reliable pattern for partitioned tables where the source of truth is a full extract by partition key.

```sql
-- BigQuery partition replacement
MERGE `project.dataset.fact_order_line` T
USING (SELECT * FROM `project.dataset.staging_fact_order_line`
       WHERE order_date_key = 20240615) S
ON T.order_line_id = S.order_line_id
    AND T.order_date_key = 20240615
WHEN MATCHED THEN UPDATE SET ...
WHEN NOT MATCHED THEN INSERT ...
WHEN NOT MATCHED BY SOURCE AND T.order_date_key = 20240615 THEN DELETE;
```

Or in Snowflake, using dynamic table replacement:

```sql
-- Snowflake: delete and reinsert for a given partition
DELETE FROM fact_order_line
WHERE order_date_key = 20240615;

INSERT INTO fact_order_line
SELECT * FROM staging_fact_order_line
WHERE order_date_key = 20240615;
```

**When correct**: When the source system provides full, authoritative extracts by date. When corrections to past records arrive as full re-extracts of the affected date. When late-arriving data must be accurately reflected without a complex MERGE logic.

**How late-arriving data breaks it**: If a correction arrives for order lines from 5 days ago, the pipeline must re-process the affected historical partition. This requires knowing which partitions are affected — either by tracking a `last_modified_at` column in the source or by re-processing a fixed rolling window (e.g., last 7 days of partitions on every run). The fixed rolling window approach is simple but expensive; it reprocesses data that hasn't changed.

## Full Refresh

The entire target table is dropped and rebuilt from source. Correct only when the source itself is small enough that full reprocessing is tolerable (< 1M rows) or when the transformation logic changes and the output cannot be trusted without full recomputation.

**Never use for tables > 10M rows in production pipelines.** The operational risk (a failed full refresh leaves the target table empty until completion) and cost (full scan of source data every run) make it untenable at scale. Identify the specific partitions affected by a logic change and do a targeted partition replacement instead.

## CDC Modeling — Source Deletes in the Warehouse

Change Data Capture captures inserts, updates, and deletes from the source system's transaction log. The warehouse must represent deletes without physically deleting rows (which would destroy audit history).

The CDC record from Debezium/Kafka Connect carries an `op` field:
- `c` = create (insert)
- `u` = update
- `d` = delete
- `r` = read (initial snapshot)

The warehouse table extends every source table with CDC metadata:

```sql
CREATE TABLE raw_cdc_customer (
    customer_id         VARCHAR(50)     NOT NULL,
    -- All source columns
    email_address       VARCHAR(200),
    loyalty_tier        VARCHAR(20),
    -- CDC metadata
    cdc_operation       CHAR(1)         NOT NULL,   -- 'c','u','d','r'
    cdc_timestamp       TIMESTAMP       NOT NULL,
    cdc_lsn             VARCHAR(50),                -- Log Sequence Number for ordering
    is_deleted          BOOLEAN         NOT NULL    DEFAULT FALSE,
    dw_inserted_at      TIMESTAMP       NOT NULL
);
```

When `cdc_operation = 'd'`, a new row is inserted into the warehouse table with `is_deleted = TRUE` and NULL values for all payload columns. Downstream models use `WHERE is_deleted = FALSE` to represent current-state, and the full history (including deletes) is available for audit and recovery:

```sql
-- Current state of customers (excluding deleted)
CREATE VIEW v_customer_current AS
SELECT *
FROM (
    SELECT *,
           ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY cdc_timestamp DESC) AS rn
    FROM raw_cdc_customer
) t
WHERE rn = 1 AND is_deleted = FALSE;
```
