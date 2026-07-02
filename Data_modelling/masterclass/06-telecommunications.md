<!-- data-modelling-patterns: Telecommunications -->

# Telecommunications

## When to Use This Design

Telecom analytics operates at an intersection of high-volume operational data and complex customer/network relationships. Business questions:

- Which subscribers are showing churn indicators (declining usage, service complaints, plan downgrades)?
- What is the revenue impact of network outages in the Northeast region last quarter?
- Which cell towers are generating the most dropped calls and are they correlated with equipment age?
- What is the average revenue per user (ARPU) by plan type for the last 12 months?

The domain-defining artifact is the **Call Detail Record (CDR)** — a structured log of every call, SMS, and data session. At a carrier with 10M subscribers, CDR volume is 5–20 billion records per month. The modeling decisions made here directly determine whether operational and analytical queries are tenable.

## The Schema

### Call Detail Records (CDRs)

```sql
CREATE TABLE fact_cdr (
    cdr_key                 BIGINT          NOT NULL,
    cdr_id                  VARCHAR(80)     NOT NULL,   -- carrier-assigned unique ID
    event_datetime          TIMESTAMP       NOT NULL,   -- call start time
    event_date_key          INT             NOT NULL,
    event_hour              INT             NOT NULL,   -- 0-23, for sub-daily partitioning
    calling_subscriber_key  BIGINT          NOT NULL,
    called_subscriber_key   BIGINT,                    -- NULL for data sessions
    originating_tower_key   BIGINT          NOT NULL,
    terminating_tower_key   BIGINT,                    -- NULL for data sessions
    call_type               VARCHAR(20)     NOT NULL,  -- 'VOICE_MO','VOICE_MT','SMS_MO','SMS_MT','DATA'
    duration_seconds        INT,                       -- NULL for SMS
    data_volume_mb          NUMERIC(12,4),             -- NULL for voice/SMS
    call_result             VARCHAR(20)     NOT NULL,  -- 'CONNECTED','DROPPED','BUSY','NO_ANSWER','FAILED'
    setup_time_ms           INT,
    roaming_flag            BOOLEAN         NOT NULL   DEFAULT FALSE,
    roaming_network_code    VARCHAR(10),
    rated_amount            NUMERIC(12,6),             -- post-billing application
    rated_currency          CHAR(3),
    plan_key                BIGINT,
    -- Network
    codec_used              VARCHAR(20),
    signal_quality_rssi     INT,
    PRIMARY KEY (cdr_key)
)
PARTITION BY (event_date_key, event_hour)
CLUSTER BY (calling_subscriber_key, call_type, originating_tower_key);
```

**Why partition by both date and hour?** At 5B CDRs/month, daily partitions still contain 160M rows. A single-day query for network performance analysis ("drop rate by tower in the last 4 hours") would scan 160M rows. Hour-level sub-partitioning reduces scan to ~7M rows. The tradeoff is more partition metadata and potentially small files in object storage. In BigQuery, hourly partitioning within date ranges is handled natively. In Snowflake, a clustering key of `(event_date_key, event_hour)` achieves similar pruning via micro-partition metadata.

### Subscriber Lifecycle with SCD Type 2

```sql
CREATE TABLE dim_subscriber (
    subscriber_key          BIGINT          NOT NULL,
    subscriber_id           VARCHAR(50)     NOT NULL,  -- MSISDN (phone number) or account ID
    msisdn                  VARCHAR(20)     NOT NULL,  -- Mobile Station International Subscriber Directory Number
    imsi                    VARCHAR(20),               -- International Mobile Subscriber Identity (SIM)
    account_id              VARCHAR(50)     NOT NULL,
    first_name              VARCHAR(100),
    last_name               VARCHAR(100),
    customer_segment        VARCHAR(30),               -- 'CONSUMER','SMB','ENTERPRISE'
    account_type            VARCHAR(20)     NOT NULL,  -- 'PREPAID','POSTPAID','MVNO'
    current_plan_key        BIGINT,
    activation_date         DATE,
    -- SCD Type 2
    eff_start_date          DATE            NOT NULL,
    eff_end_date            DATE            NOT NULL   DEFAULT '9999-12-31',
    is_current              BOOLEAN         NOT NULL   DEFAULT TRUE,
    dw_inserted_at          TIMESTAMP       NOT NULL,
    PRIMARY KEY (subscriber_key)
)
PARTITION BY (eff_start_date)
CLUSTER BY (account_type, customer_segment);
```

### Service Plan Modeling

Plans change frequently — promotional pricing, regulatory-mandated changes, new offerings. The plan history must be preserved to correctly rate historical CDRs.

```sql
CREATE TABLE dim_plan (
    plan_key                BIGINT          NOT NULL,
    plan_id                 VARCHAR(50)     NOT NULL,
    plan_name               VARCHAR(200)    NOT NULL,
    plan_type               VARCHAR(30)     NOT NULL,  -- 'VOICE_ONLY','DATA_ONLY','BUNDLE','PREPAID'
    monthly_recurring_charge NUMERIC(10,2)  NOT NULL,
    included_voice_minutes  INT,                       -- NULL = unlimited
    included_sms_count      INT,                       -- NULL = unlimited
    included_data_gb        NUMERIC(8,3),              -- NULL = unlimited
    overage_voice_rate      NUMERIC(10,6),
    overage_sms_rate        NUMERIC(10,6),
    overage_data_rate_per_mb NUMERIC(10,6),
    international_roaming   BOOLEAN         NOT NULL   DEFAULT FALSE,
    eff_start_date          DATE            NOT NULL,
    eff_end_date            DATE            NOT NULL   DEFAULT '9999-12-31',
    is_current              BOOLEAN         NOT NULL   DEFAULT TRUE,
    PRIMARY KEY (plan_key)
);

-- Subscriber plan subscription history
CREATE TABLE fact_subscriber_plan_history (
    sub_plan_key            BIGINT          NOT NULL,
    subscriber_key          BIGINT          NOT NULL,
    plan_key                BIGINT          NOT NULL,
    subscription_start_date DATE            NOT NULL,
    subscription_end_date   DATE            NOT NULL   DEFAULT '9999-12-31',
    change_reason           VARCHAR(100),             -- 'UPGRADE','DOWNGRADE','PROMOTIONAL','RENEWAL'
    is_current              BOOLEAN         NOT NULL   DEFAULT TRUE,
    PRIMARY KEY (sub_plan_key)
)
CLUSTER BY (subscriber_key, plan_key);
```

### Network Topology (Graph-Like Hierarchy)

Network topology is a directed graph: a subscriber connects to a cell sector, which belongs to a cell tower, which belongs to a cluster, which belongs to a market, which belongs to a region. This hierarchy is relatively stable but changes for network expansion events.

```sql
CREATE TABLE dim_network_node (
    network_node_key        BIGINT          NOT NULL,
    node_id                 VARCHAR(50)     NOT NULL,
    node_type               VARCHAR(20)     NOT NULL,  -- 'CELL_SECTOR','TOWER','CLUSTER','MARKET','REGION'
    node_name               VARCHAR(200)    NOT NULL,
    parent_node_id          VARCHAR(50),
    latitude                NUMERIC(9,6),
    longitude               NUMERIC(9,6),
    technology_type         VARCHAR(10),               -- '2G','3G','4G','5G'
    frequency_band          VARCHAR(20),
    antenna_count           INT,
    equipment_vendor        VARCHAR(50),
    installation_date       DATE,
    is_active               BOOLEAN         NOT NULL   DEFAULT TRUE,
    eff_start_date          DATE            NOT NULL,
    eff_end_date            DATE            NOT NULL   DEFAULT '9999-12-31',
    is_current              BOOLEAN         NOT NULL   DEFAULT TRUE,
    PRIMARY KEY (network_node_key)
)
CLUSTER BY (node_type, parent_node_id);
```

### Churn Prediction Data Structures

Churn prediction in telecom requires a feature store that captures behavioral signals over rolling time windows. The model must be designed to support feature engineering at scale:

```sql
-- Subscriber activity summary (pre-aggregated features for ML)
CREATE TABLE fact_subscriber_monthly_summary (
    summary_key             BIGINT          NOT NULL,
    summary_month_key       INT             NOT NULL,  -- YYYYMM
    subscriber_key          BIGINT          NOT NULL,
    plan_key                BIGINT          NOT NULL,
    -- Usage features
    total_voice_minutes     NUMERIC(10,2)   NOT NULL   DEFAULT 0,
    total_sms_count         INT             NOT NULL   DEFAULT 0,
    total_data_gb           NUMERIC(12,4)   NOT NULL   DEFAULT 0,
    distinct_called_numbers INT             NOT NULL   DEFAULT 0,
    roaming_days            INT             NOT NULL   DEFAULT 0,
    -- Quality features
    dropped_call_count      INT             NOT NULL   DEFAULT 0,
    failed_call_count       INT             NOT NULL   DEFAULT 0,
    -- Financial features
    monthly_bill_amount     NUMERIC(10,2),
    overage_charges_amount  NUMERIC(10,2)   NOT NULL   DEFAULT 0,
    -- Service interaction features
    complaint_count         INT             NOT NULL   DEFAULT 0,
    ivr_contact_count       INT             NOT NULL   DEFAULT 0,
    -- Derived features
    avg_daily_data_gb       NUMERIC(10,6),
    pct_plan_data_used      NUMERIC(6,4),
    months_since_last_upgrade INT,
    -- Churn label (for training)
    churned_next_month      BOOLEAN,                   -- NULL if label not yet available
    PRIMARY KEY (summary_key)
)
PARTITION BY (summary_month_key)
CLUSTER BY (subscriber_key, plan_key);
```

## The Hard Problems

**Streaming CDR Ingestion**: CDRs arrive from multiple network elements (MSCs, packet gateways, IMS nodes) in near-real-time. The pipeline challenge is that CDRs from different sources arrive with different latencies — a voice CDR from the MSC may arrive in seconds; a roaming data session CDR from an international partner may arrive in hours or days. The warehouse must accommodate late-arriving CDRs without corrupting existing aggregates.

The solution is a **two-layer architecture**:
1. A raw CDR landing table with `received_at` (warehouse arrival time) partition
2. The analytical `fact_cdr` table partitioned by `event_date_key` (call start time)

The ELT job runs hourly: it picks up all CDRs received in the last hour and inserts them into the correct `event_date_key` partition in `fact_cdr`. For late-arriving roaming CDRs, the hourly job handles the retroactive insert. Pre-computed hourly aggregates are never finalized until a configurable lag (72 hours for international roaming) has passed.

**Near-Real-Time Aggregation Patterns**: Network operations centers (NOC) require sub-minute visibility into call drop rates, signal quality, and capacity utilization. These cannot wait for the nightly batch. The pattern is a **dual-path architecture**:

- **Hot path**: CDRs stream to Apache Kafka → ksqlDB or Apache Flink aggregation → time-series database (TimescaleDB, InfluxDB) for NOC dashboards. 1-minute aggregates, 72-hour retention.
- **Cold path**: CDRs batch-load to the analytical warehouse every hour. Full history, slower queries, used by planning and finance.

The NOC dashboard queries the time-series DB. Business analysts query the warehouse. Never ask the analytical warehouse to serve sub-minute operational queries.

## Scale Mechanics

| Table | Rows/Month (10M subscribers) | Partition | Cluster | Incremental Strategy |
|-------|------------------------------|-----------|---------|---------------------|
| fact_cdr | 5B–20B | date + hour | subscriber_key, call_type | Hourly append |
| fact_subscriber_monthly_summary | 10M | summary_month_key | subscriber_key | Monthly full replace for given month |
| dim_subscriber | 10M current + SCD history | eff_start_date | account_type | MERGE on subscriber_id |
| fact_subscriber_plan_history | 50M | — | subscriber_key | Append on plan change events |

At 20B CDRs/month, the fact_cdr table grows at 240B rows/year. Object storage tiering is mandatory: hot tier (Snowflake/BigQuery) covers 3 months (60B rows); warm tier (Iceberg on S3) covers 2 years; cold tier (compressed Parquet on Glacier) covers full regulatory retention (7 years). Query routing (via virtual warehouse size tiers in Snowflake or BI+table function routing in BigQuery) directs NOC queries to the hot tier and historical regulatory queries to the Iceberg layer.
