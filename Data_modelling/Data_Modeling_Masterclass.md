# Data Modeling Masterclass: Deep Technical Reference

> A practitioner's reference covering schema design, scale mechanics, incremental patterns, and failure modes across six industry verticals.

---

## Table of Contents

1. [Retail / E-Commerce](#1-retail--e-commerce)
2. [Healthcare](#2-healthcare)
3. [Manufacturing / Supply Chain](#3-manufacturing--supply-chain)
4. [Financial Services](#4-financial-services)
5. [SaaS / Product Analytics](#5-saas--product-analytics)
6. [Telecommunications](#6-telecommunications)
7. [Dimensional vs Data Vault vs One Big Table](#7-dimensional-vs-data-vault-vs-one-big-table-obt)
8. [SCD Types in Depth](#8-scd-types-in-depth)
9. [Partitioning and Clustering Strategy](#9-partitioning-and-clustering-strategy)
10. [Incremental Patterns](#10-incremental-patterns)
11. [Anti-Patterns with Autopsy](#11-anti-patterns-with-autopsy)
12. [Business Logic: DE Layer vs Reporting Layer](#12-business-logic-de-layer-vs-reporting-layer)

---

## 1. Retail / E-Commerce

### When to Use This Design

The retail domain is driven by a handful of high-stakes business questions:

- What was my gross margin by product category last Black Friday vs this year?
- Which customers bought product X but not product Y in the last 90 days?
- What is the current available-to-promise inventory across all warehouses for SKU ABC?
- Did price changes on the 14th drive the conversion drop?

Each question maps to a specific modeling choice. The margin question requires a clean fact table with order lines joined to a product hierarchy that does not change shape over time. The inventory question needs a current-state model — probably not a star schema at all. The price change question requires slowly changing dimension handling that captures effective dates. Failing to separate these concerns produces a model that answers no question cleanly.

### The Schema

#### Product Catalog with Variants and Hierarchy

A common mistake is collapsing the product hierarchy into a single wide dimension. The hierarchy — department > category > subcategory > product > SKU/variant — has different change rates at each level. Department names almost never change. SKU attributes (color, size) may be updated regularly. A single `dim_product` with all hierarchy columns embedded will have SCD Type 2 row explosions at the SKU level contaminating the parent hierarchy.

The correct design separates the hierarchy node table from the variant leaf table:

```sql
-- Hierarchy nodes: department, category, subcategory
CREATE TABLE dim_product_hierarchy (
    hierarchy_node_key      BIGINT          NOT NULL,  -- surrogate
    node_id                 VARCHAR(50)     NOT NULL,  -- natural key from source
    node_type               VARCHAR(20)     NOT NULL,  -- 'DEPARTMENT','CATEGORY','SUBCATEGORY'
    node_name               VARCHAR(200)    NOT NULL,
    parent_node_id          VARCHAR(50)     NULL,      -- self-referencing for hierarchy
    display_path            VARCHAR(500)    NOT NULL,  -- precomputed: "Electronics > Phones"
    is_active               BOOLEAN         NOT NULL   DEFAULT TRUE,
    dw_created_at           TIMESTAMP       NOT NULL,
    dw_updated_at           TIMESTAMP       NOT NULL,
    PRIMARY KEY (hierarchy_node_key)
)
CLUSTER BY (node_type, parent_node_id);

-- Product master (style-level, above variant)
CREATE TABLE dim_product (
    product_key             BIGINT          NOT NULL,
    product_id              VARCHAR(50)     NOT NULL,
    product_name            VARCHAR(300)    NOT NULL,
    brand                   VARCHAR(100),
    subcategory_node_id     VARCHAR(50)     NOT NULL,
    is_private_label        BOOLEAN         NOT NULL   DEFAULT FALSE,
    launch_date             DATE,
    discontinue_date        DATE,
    dw_eff_start_date       DATE            NOT NULL,
    dw_eff_end_date         DATE            NOT NULL   DEFAULT '9999-12-31',
    dw_is_current           BOOLEAN         NOT NULL   DEFAULT TRUE,
    PRIMARY KEY (product_key)
)
PARTITION BY (dw_eff_start_date);

-- SKU/Variant (leaf — what gets sold)
CREATE TABLE dim_sku (
    sku_key                 BIGINT          NOT NULL,
    sku_id                  VARCHAR(50)     NOT NULL,  -- "SHIRT-RED-M"
    product_id              VARCHAR(50)     NOT NULL,  -- FK to product natural key
    upc                     VARCHAR(20),
    color                   VARCHAR(50),
    size                    VARCHAR(20),
    weight_kg               NUMERIC(8,3),
    unit_cost               NUMERIC(12,4),
    msrp                    NUMERIC(12,4),
    eff_start_date          DATE            NOT NULL,
    eff_end_date            DATE            NOT NULL   DEFAULT '9999-12-31',
    is_current              BOOLEAN         NOT NULL   DEFAULT TRUE,
    PRIMARY KEY (sku_key)
)
PARTITION BY (eff_start_date);
```

Why separate product from SKU? A product (style) may have 30 color/size combinations. If a single color is discontinued, only that SKU row changes — you do not want 29 new SCD Type 2 rows for unchanged variants. The separation also matches how most source systems (SAP, Shopify, Magento) organize their data.

#### Order Management

Order management has two grains that analysts conflate: the order header and the order line. The header captures checkout-level facts (total discount, promo code applied, shipping address). The line captures item-level facts (quantity, unit price, line discount). Combining them into one table is the God Fact anti-pattern applied to transactional data.

```sql
-- Order header fact
CREATE TABLE fact_order_header (
    order_header_key        BIGINT          NOT NULL,
    order_id                VARCHAR(50)     NOT NULL,
    customer_key            BIGINT          NOT NULL,
    order_date_key          INT             NOT NULL,  -- FK to dim_date (YYYYMMDD)
    order_placed_at         TIMESTAMP       NOT NULL,
    channel                 VARCHAR(30)     NOT NULL,  -- 'WEB','APP','STORE','MARKETPLACE'
    store_key               BIGINT,                    -- NULL for online orders
    promo_code              VARCHAR(50),
    promo_key               BIGINT,                    -- FK to dim_promotion
    shipping_address_key    BIGINT          NOT NULL,
    billing_address_key     BIGINT          NOT NULL,
    order_status            VARCHAR(30)     NOT NULL,  -- 'PLACED','CONFIRMED','SHIPPED','DELIVERED','CANCELLED'
    shipping_method         VARCHAR(50),
    shipping_charged_amt    NUMERIC(12,2)   NOT NULL   DEFAULT 0,
    order_subtotal_amt      NUMERIC(12,2)   NOT NULL,
    order_discount_amt      NUMERIC(12,2)   NOT NULL   DEFAULT 0,
    order_tax_amt           NUMERIC(12,2)   NOT NULL   DEFAULT 0,
    order_total_amt         NUMERIC(12,2)   NOT NULL,
    currency_code           CHAR(3)         NOT NULL   DEFAULT 'USD',
    dw_inserted_at          TIMESTAMP       NOT NULL,
    dw_updated_at           TIMESTAMP       NOT NULL,
    PRIMARY KEY (order_header_key)
)
PARTITION BY (order_date_key)
CLUSTER BY (customer_key, channel);

-- Order line fact (grain: one row per SKU per order)
CREATE TABLE fact_order_line (
    order_line_key          BIGINT          NOT NULL,
    order_id                VARCHAR(50)     NOT NULL,
    order_line_id           VARCHAR(80)     NOT NULL,
    order_header_key        BIGINT          NOT NULL,
    order_date_key          INT             NOT NULL,
    sku_key                 BIGINT          NOT NULL,
    product_key             BIGINT          NOT NULL,
    quantity_ordered        INT             NOT NULL,
    quantity_fulfilled      INT             NOT NULL   DEFAULT 0,
    unit_list_price         NUMERIC(12,4)   NOT NULL,
    unit_selling_price      NUMERIC(12,4)   NOT NULL,
    line_discount_amt       NUMERIC(12,4)   NOT NULL   DEFAULT 0,
    line_gross_revenue      NUMERIC(12,4)   NOT NULL,  -- qty * unit_selling_price
    line_cogs               NUMERIC(12,4),             -- populated after COGS allocation
    line_gross_margin       NUMERIC(12,4),             -- derived, populated in transform
    fulfillment_warehouse_key BIGINT,
    PRIMARY KEY (order_line_key)
)
PARTITION BY (order_date_key)
CLUSTER BY (sku_key, product_key);
```

Why `order_date_key` as INT (YYYYMMDD) rather than DATE? In columnar warehouses (Snowflake, BigQuery, Redshift), the date dimension join is typically the most-used filter. Storing as INT avoids implicit casts in the join predicate and enables partition pruning expressions like `WHERE order_date_key BETWEEN 20241129 AND 20241201` to be written without CAST overhead.

#### Pricing Dimension (Slowly Changing)

Prices change frequently — promotional windows, cost-plus recalculations, competitive repricing. If you embed `unit_price` only in the fact, you lose the ability to ask "what was the listed price at the time of this order vs what we charged?" This requires the price history to be a first-class dimension.

```sql
CREATE TABLE dim_price (
    price_key               BIGINT          NOT NULL,
    sku_id                  VARCHAR(50)     NOT NULL,
    price_type              VARCHAR(30)     NOT NULL,  -- 'LIST','SALE','MEMBER','COST'
    price_amount            NUMERIC(12,4)   NOT NULL,
    currency_code           CHAR(3)         NOT NULL,
    eff_start_datetime      TIMESTAMP       NOT NULL,
    eff_end_datetime        TIMESTAMP       NOT NULL   DEFAULT '9999-12-31 23:59:59',
    is_current              BOOLEAN         NOT NULL,
    source_system           VARCHAR(50),
    dw_inserted_at          TIMESTAMP       NOT NULL,
    PRIMARY KEY (price_key)
)
PARTITION BY DATE(eff_start_datetime)
CLUSTER BY (sku_id, price_type);
```

To answer "what was the list price when this order was placed," the join is:

```sql
SELECT
    ol.order_line_id,
    ol.unit_selling_price,
    p.price_amount AS list_price_at_order_time,
    ol.unit_selling_price - p.price_amount AS discount_vs_list
FROM fact_order_line ol
JOIN dim_price p
    ON ol.sku_id = p.sku_id
    AND p.price_type = 'LIST'
    AND ol.order_placed_at >= p.eff_start_datetime
    AND ol.order_placed_at < p.eff_end_datetime;
```

This range join is expensive at scale. The mitigation strategy is to denormalize `list_price_at_order_time` into the fact at load time and only use the range join during the nightly ETL — not at query time.

#### Promotions and Pricing

Promotions are fundamentally multi-dimensional: a promo can apply to a set of SKUs, a customer segment, a date range, a channel, or combinations thereof. The naive design is a single `dim_promotion` table with comma-separated SKU lists or flag columns like `is_electronics_eligible`. This collapses at scale and makes "which promotions could a given SKU qualify for?" an impossible query without full-table scans.

```sql
CREATE TABLE dim_promotion (
    promo_key               BIGINT          NOT NULL,
    promo_id                VARCHAR(50)     NOT NULL,
    promo_name              VARCHAR(200)    NOT NULL,
    promo_type              VARCHAR(30)     NOT NULL,  -- 'PCT_DISCOUNT','FIXED_AMOUNT','BOGO','FREE_SHIP'
    discount_value          NUMERIC(8,4),              -- 0.15 for 15% off
    min_order_value         NUMERIC(12,2),
    start_date              DATE            NOT NULL,
    end_date                DATE            NOT NULL,
    channel_scope           VARCHAR(20)     NOT NULL   DEFAULT 'ALL',
    stackable               BOOLEAN         NOT NULL   DEFAULT FALSE,
    promo_code              VARCHAR(50),
    PRIMARY KEY (promo_key)
);

-- Bridge table: promotion eligibility by SKU
CREATE TABLE bridge_promo_sku (
    promo_key               BIGINT          NOT NULL,
    sku_key                 BIGINT          NOT NULL,
    PRIMARY KEY (promo_key, sku_key)
);

-- Bridge table: promotion eligibility by customer segment
CREATE TABLE bridge_promo_customer_segment (
    promo_key               BIGINT          NOT NULL,
    customer_segment_key    BIGINT          NOT NULL,
    PRIMARY KEY (promo_key, customer_segment_key)
);
```

The bridge tables enable set-intersection queries: "show all SKUs eligible for active promotions in the Electronics category where the customer is a loyalty member." Without the bridges, this is a string-parsing nightmare.

#### Inventory Positions

Inventory is a snapshot fact — it represents a state at a point in time, not an event. The two most common mistakes are: (1) trying to derive current inventory from order transactions alone (ignoring receiving, adjustments, transfers, returns), and (2) storing inventory as a single row updated in place (which destroys history).

```sql
-- Inventory snapshot (grain: one row per SKU per warehouse per snapshot_date)
CREATE TABLE fact_inventory_snapshot (
    snapshot_key            BIGINT          NOT NULL,
    snapshot_date_key       INT             NOT NULL,
    sku_key                 BIGINT          NOT NULL,
    warehouse_key           BIGINT          NOT NULL,
    on_hand_qty             INT             NOT NULL   DEFAULT 0,
    reserved_qty            INT             NOT NULL   DEFAULT 0,  -- pending orders
    in_transit_qty          INT             NOT NULL   DEFAULT 0,  -- POs in transit
    available_qty           INT             NOT NULL,              -- on_hand - reserved
    reorder_point_qty       INT,
    days_of_supply          NUMERIC(6,1),              -- computed from avg daily demand
    snapshot_captured_at    TIMESTAMP       NOT NULL,
    PRIMARY KEY (snapshot_key)
)
PARTITION BY (snapshot_date_key)
CLUSTER BY (warehouse_key, sku_key);

-- Inventory movement events (grain: one row per movement)
CREATE TABLE fact_inventory_movement (
    movement_key            BIGINT          NOT NULL,
    movement_id             VARCHAR(80)     NOT NULL,
    movement_date_key       INT             NOT NULL,
    movement_datetime       TIMESTAMP       NOT NULL,
    sku_key                 BIGINT          NOT NULL,
    warehouse_key           BIGINT          NOT NULL,
    movement_type           VARCHAR(30)     NOT NULL,  -- 'SALE','RETURN','RECEIPT','TRANSFER_IN','TRANSFER_OUT','ADJUSTMENT','DAMAGE'
    quantity_delta          INT             NOT NULL,  -- negative for outbound
    reference_order_id      VARCHAR(50),
    reference_po_id         VARCHAR(50),
    PRIMARY KEY (movement_key)
)
PARTITION BY (movement_date_key)
CLUSTER BY (sku_key, warehouse_key, movement_type);
```

The snapshot fact enables fast "what is inventory right now?" queries with no aggregation. The movement fact enables "how did I get from 500 units to 200 units?" audits. Both are needed. Attempting to use only movements requires summing the entire movement history for every current-inventory question — catastrophically slow at 1B rows.

#### Customer 360

Customer 360 is a misnomer when it becomes a single wide table. At 200+ columns it becomes ungovernable. The correct design is a core identity dimension with satellite tables for specific domains:

```sql
CREATE TABLE dim_customer (
    customer_key            BIGINT          NOT NULL,
    customer_id             VARCHAR(50)     NOT NULL,
    email_address           VARCHAR(200),
    phone_number            VARCHAR(20),
    first_name              VARCHAR(100),
    last_name               VARCHAR(100),
    date_of_birth           DATE,
    gender                  VARCHAR(10),
    acquisition_channel     VARCHAR(50),
    acquisition_date        DATE,
    is_loyalty_member       BOOLEAN         NOT NULL   DEFAULT FALSE,
    loyalty_tier            VARCHAR(20),               -- 'BRONZE','SILVER','GOLD','PLATINUM'
    loyalty_enrolled_date   DATE,
    is_email_subscribed     BOOLEAN         NOT NULL   DEFAULT TRUE,
    is_sms_subscribed       BOOLEAN         NOT NULL   DEFAULT FALSE,
    eff_start_date          DATE            NOT NULL,
    eff_end_date            DATE            NOT NULL   DEFAULT '9999-12-31',
    is_current              BOOLEAN         NOT NULL   DEFAULT TRUE,
    PRIMARY KEY (customer_key)
)
PARTITION BY (eff_start_date)
CLUSTER BY (loyalty_tier, acquisition_channel);
```

### The Hard Problems

**Black Friday Spike Patterns**: Partitioning by `order_date_key` means November 29 becomes a hot partition. In BigQuery, this is handled naturally by partition pruning — queries specifying Black Friday dates only scan that partition. In Snowflake, micro-partition clustering on `channel` within the date partition prevents full-partition scans when analysts filter by `channel = 'WEB'`. The monitoring concern is that large single-day ingestion jobs (ELT pipelines running after midnight) may compete with analyst queries. Solving this requires a processing time watermark: ETL writes to a staging table, then does an atomic swap after validation.

**Late-Arriving Orders**: Orders placed on mobile apps can be buffered offline and arrive in the warehouse hours or days after the order event timestamp. If your partition key is `dw_inserted_at` (load time) rather than `order_placed_at` (event time), late-arriving orders land in the correct partition but the `order_placed_at` value will be in a "past" partition bucket — causing double-counting when analysts filter by `order_placed_at` ranges. The solution is to partition by `DATE(order_placed_at)` and accept that late-arriving data requires `MERGE` or delete+reinsert into past partitions.

### Scale Mechanics

| Volume | Primary Strategy |
|--------|-----------------|
| < 10M rows | Single table, date clustering |
| 10M–100M rows | Date partitioning + SKU/warehouse clustering |
| 100M–1B rows | Date partitioning + multi-column clustering, separate hot/cold tiers |
| > 1B rows | Sharding by region or channel for write parallelism, materialized aggregates for reporting layer |

At 1B order lines, a full table scan to compute YTD GMV takes minutes even in columnar systems. The solution is a pre-aggregated `fact_order_daily_summary` at the (date, SKU, channel, warehouse) grain that is refreshed nightly. Raw order lines are retained for forensic queries but daily reporting goes to the aggregate. This is not premature optimization — it is the deliberate two-tier model where grain is chosen to match query SLA.

---

## 2. Healthcare

### When to Use This Design

Healthcare data modeling is driven by questions that span both clinical and administrative domains:

- What is the total cost of care for patients with Type 2 Diabetes in the past year?
- Which patients had a lab result (HbA1c > 9) recorded after the encounter was finalized?
- Which claims were submitted to payer X but not yet adjudicated?
- Who accessed patient record Y on date Z? (HIPAA audit)

The critical design constraint absent from every other domain here: **healthcare data has legal definitions of "correct" that change over time**. A diagnosis code can be corrected retroactively. A lab result can be amended. The model must represent not only what was true in the clinical world (valid time) but also what the system believed at any given moment (transaction time). This is bi-temporal modeling, and it is not optional in healthcare.

### The Schema

#### Patient Dimension

```sql
CREATE TABLE dim_patient (
    patient_key             BIGINT          NOT NULL,
    patient_id              VARCHAR(50)     NOT NULL,   -- MRN (Medical Record Number)
    mrn_system              VARCHAR(100)    NOT NULL,   -- issuing facility/system
    first_name              VARCHAR(100),
    last_name               VARCHAR(100),
    date_of_birth           DATE,
    sex_at_birth            CHAR(1),                    -- 'M','F','U'
    gender_identity         VARCHAR(30),
    race_code               VARCHAR(10),
    ethnicity_code          VARCHAR(10),
    primary_language        VARCHAR(50),
    address_line1           VARCHAR(200),               -- store only if required for care
    city                    VARCHAR(100),
    state_code              CHAR(2),
    zip_code                VARCHAR(10),
    deceased_flag           BOOLEAN         NOT NULL    DEFAULT FALSE,
    deceased_date           DATE,
    -- SCD Type 2 columns
    valid_from_date         DATE            NOT NULL,
    valid_to_date           DATE            NOT NULL    DEFAULT '9999-12-31',
    is_current              BOOLEAN         NOT NULL    DEFAULT TRUE,
    -- Audit
    dw_inserted_at          TIMESTAMP       NOT NULL,
    dw_updated_at           TIMESTAMP       NOT NULL,
    source_system           VARCHAR(50)     NOT NULL,
    PRIMARY KEY (patient_key)
)
PARTITION BY (valid_from_date)
CLUSTER BY (state_code, zip_code);
```

**Row-Level Security Implication**: In a multi-facility system, analysts at Hospital A should not see patients of Hospital B. In Snowflake, this is implemented via Row Access Policies tied to a policy mapping table. In BigQuery, column-level security combined with row filters on `facility_id` is the pattern. The `dim_patient` table must carry a `facility_id` or `care_network_id` column even if that attribute seems redundant with the encounter data — the security policy must be evaluable on the dimension table itself, not via a join.

```sql
-- Snowflake row access policy
CREATE OR REPLACE ROW ACCESS POLICY patient_row_policy
AS (facility_id VARCHAR) RETURNS BOOLEAN ->
    'DATA_ADMIN' = CURRENT_ROLE()
    OR EXISTS (
        SELECT 1 FROM analyst_facility_access a
        WHERE a.analyst_email = CURRENT_USER()
        AND a.facility_id = facility_id
    );

ALTER TABLE dim_patient ADD ROW ACCESS POLICY patient_row_policy ON (facility_id);
```

#### Encounter Fact (Clinical Events)

An encounter is the fundamental unit of care — an office visit, an ED visit, a hospitalization. Its grain is one row per encounter per patient. The temptation is to denormalize all diagnoses and procedures into the encounter row as arrays. This makes "patients with diagnosis code X" queries require array unnesting, which is a full scan regardless of indexes.

```sql
CREATE TABLE fact_encounter (
    encounter_key           BIGINT          NOT NULL,
    encounter_id            VARCHAR(80)     NOT NULL,
    patient_key             BIGINT          NOT NULL,
    encounter_type          VARCHAR(30)     NOT NULL,   -- 'OUTPATIENT','INPATIENT','ED','TELEHEALTH'
    admit_date_key          INT             NOT NULL,
    discharge_date_key      INT,                        -- NULL for outpatient / ongoing
    admit_datetime          TIMESTAMP       NOT NULL,
    discharge_datetime      TIMESTAMP,
    facility_key            BIGINT          NOT NULL,
    attending_provider_key  BIGINT,
    discharge_disposition   VARCHAR(50),               -- 'HOME','SNF','EXPIRED','TRANSFERRED'
    drg_code                VARCHAR(10),               -- Diagnosis Related Group (inpatient billing)
    los_days                INT,                       -- length of stay
    total_charges_amt       NUMERIC(14,2),
    total_payments_amt      NUMERIC(14,2),
    -- Bi-temporal columns
    valid_from              TIMESTAMP       NOT NULL,   -- when this was true in the real world
    valid_to                TIMESTAMP       NOT NULL    DEFAULT '9999-12-31 23:59:59',
    recorded_at             TIMESTAMP       NOT NULL,   -- when the system first recorded it
    corrected_at            TIMESTAMP,                  -- if this row supersedes a prior row
    is_current_version      BOOLEAN         NOT NULL    DEFAULT TRUE,
    facility_id             VARCHAR(50)     NOT NULL,   -- for RLS policy
    PRIMARY KEY (encounter_key)
)
PARTITION BY (admit_date_key)
CLUSTER BY (patient_key, encounter_type, facility_id);
```

#### Diagnosis, Procedure, Medication — Separate Tables

These are NOT columns on the encounter. They are child facts.

```sql
-- Diagnosis (ICD-10 codes associated with an encounter)
CREATE TABLE fact_diagnosis (
    diagnosis_key           BIGINT          NOT NULL,
    encounter_key           BIGINT          NOT NULL,
    patient_key             BIGINT          NOT NULL,
    diagnosis_date_key      INT             NOT NULL,
    icd10_code              VARCHAR(10)     NOT NULL,
    diagnosis_description   VARCHAR(300),
    diagnosis_type          VARCHAR(20)     NOT NULL,   -- 'PRIMARY','SECONDARY','ADMITTING','POA'
    diagnosis_sequence      INT             NOT NULL    DEFAULT 1,
    chronic_flag            BOOLEAN         NOT NULL    DEFAULT FALSE,
    hcc_category            VARCHAR(20),               -- Hierarchical Condition Category (risk scoring)
    -- Bi-temporal
    valid_from              TIMESTAMP       NOT NULL,
    valid_to                TIMESTAMP       NOT NULL    DEFAULT '9999-12-31 23:59:59',
    recorded_at             TIMESTAMP       NOT NULL,
    is_current_version      BOOLEAN         NOT NULL    DEFAULT TRUE,
    facility_id             VARCHAR(50)     NOT NULL,
    PRIMARY KEY (diagnosis_key)
)
PARTITION BY (diagnosis_date_key)
CLUSTER BY (patient_key, icd10_code);

-- Procedure
CREATE TABLE fact_procedure (
    procedure_key           BIGINT          NOT NULL,
    encounter_key           BIGINT          NOT NULL,
    patient_key             BIGINT          NOT NULL,
    procedure_date_key      INT             NOT NULL,
    cpt_code                VARCHAR(10),               -- Current Procedural Terminology
    icd10_pcs_code          VARCHAR(10),               -- ICD-10 Procedure Coding System (inpatient)
    procedure_description   VARCHAR(300),
    modifier_code           VARCHAR(10),
    units_performed         INT             NOT NULL    DEFAULT 1,
    rendering_provider_key  BIGINT,
    -- Bi-temporal
    valid_from              TIMESTAMP       NOT NULL,
    valid_to                TIMESTAMP       NOT NULL    DEFAULT '9999-12-31 23:59:59',
    recorded_at             TIMESTAMP       NOT NULL,
    is_current_version      BOOLEAN         NOT NULL    DEFAULT TRUE,
    facility_id             VARCHAR(50)     NOT NULL,
    PRIMARY KEY (procedure_key)
)
PARTITION BY (procedure_date_key)
CLUSTER BY (patient_key, cpt_code);

-- Medication order
CREATE TABLE fact_medication_order (
    med_order_key           BIGINT          NOT NULL,
    encounter_key           BIGINT,                    -- NULL for outpatient scripts
    patient_key             BIGINT          NOT NULL,
    order_date_key          INT             NOT NULL,
    ndc_code                VARCHAR(15)     NOT NULL,   -- National Drug Code
    drug_name               VARCHAR(200),
    drug_class              VARCHAR(100),
    dose_amount             NUMERIC(10,3),
    dose_unit               VARCHAR(20),
    route                   VARCHAR(30),               -- 'ORAL','IV','TOPICAL'
    frequency               VARCHAR(30),
    days_supply             INT,
    quantity_dispensed      NUMERIC(10,3),
    prescribing_provider_key BIGINT,
    pharmacy_key            BIGINT,
    order_status            VARCHAR(20)     NOT NULL,  -- 'ORDERED','DISPENSED','CANCELLED'
    is_controlled_substance BOOLEAN         NOT NULL   DEFAULT FALSE,
    valid_from              TIMESTAMP       NOT NULL,
    valid_to                TIMESTAMP       NOT NULL    DEFAULT '9999-12-31 23:59:59',
    recorded_at             TIMESTAMP       NOT NULL,
    is_current_version      BOOLEAN         NOT NULL   DEFAULT TRUE,
    facility_id             VARCHAR(50)     NOT NULL,
    PRIMARY KEY (med_order_key)
)
PARTITION BY (order_date_key)
CLUSTER BY (patient_key, ndc_code);
```

#### Bi-Temporal Modeling: Valid Time vs Transaction Time

This is where healthcare diverges sharply from other domains. Consider this scenario:

- On March 1, a physician documents an encounter, coding the primary diagnosis as J06.9 (acute upper respiratory infection).
- On March 15, a coder reviews the encounter and corrects the diagnosis to J18.9 (pneumonia, unspecified).
- On April 1, an auditor reviews the claim and confirms the correction was appropriate.

A naive SCD Type 2 model records the correction as of March 15 (transaction time) and marks the March 1 version as expired. **This is insufficient.** The question "what was the documented diagnosis as of March 7?" requires knowing both the valid time (March 1 = when the encounter occurred) and the transaction time (March 7 = what the system believed at that point). With SCD Type 2 alone, you cannot reconstruct the March 7 system view after the correction.

The bi-temporal pattern adds a `recorded_at` / `transaction_time` axis:

```sql
-- Reconstructing what the system believed on March 7 about the March 1 encounter
SELECT *
FROM fact_diagnosis
WHERE encounter_key = 12345
  AND valid_from <= '2024-03-01 23:59:59'     -- encounter was valid on this date
  AND valid_to   >= '2024-03-01 00:00:00'
  AND recorded_at <= '2024-03-07 23:59:59'    -- system believed this as of March 7
ORDER BY recorded_at DESC
LIMIT 1;
```

This query returns the March 1 version of the diagnosis — J06.9 — as it was known on March 7, before the correction was entered.

#### HIPAA-Adjacent Audit Trail

Every read and write access to PHI must be auditable. This is not a data model concern for analytics workloads — it is a platform concern (Snowflake access history, BigQuery data access logs, Databricks audit logs). However, the analytics warehouse must carry a separate audit dimension for data changes that are clinically significant:

```sql
CREATE TABLE audit_clinical_change (
    audit_key               BIGINT          NOT NULL,
    table_name              VARCHAR(100)    NOT NULL,
    record_key              BIGINT          NOT NULL,
    change_type             VARCHAR(20)     NOT NULL,   -- 'INSERT','CORRECT','VOID','AMEND'
    changed_by_user         VARCHAR(200)    NOT NULL,
    changed_at              TIMESTAMP       NOT NULL,
    prior_value_json        VARCHAR,                    -- previous state as JSON
    new_value_json          VARCHAR,                    -- new state as JSON
    change_reason           VARCHAR(500),
    facility_id             VARCHAR(50)     NOT NULL,
    PRIMARY KEY (audit_key)
)
PARTITION BY DATE(changed_at)
CLUSTER BY (table_name, record_key);
```

### The Hard Problems

**Sparse Columns Across Specialties**: A cardiology encounter has different clinical attributes than an oncology encounter. If you try to represent all specialty-specific attributes in a single `fact_encounter`, you get a table with 300 columns where any given row has 80% NULLs. The solution is an **entity-attribute-value (EAV) extension table** for specialty-specific clinical observations, combined with a structured `fact_observation` table:

```sql
CREATE TABLE fact_observation (
    observation_key         BIGINT          NOT NULL,
    encounter_key           BIGINT          NOT NULL,
    patient_key             BIGINT          NOT NULL,
    observation_date_key    INT             NOT NULL,
    observation_datetime    TIMESTAMP       NOT NULL,
    loinc_code              VARCHAR(20)     NOT NULL,   -- LOINC standardizes observation types
    observation_description VARCHAR(300),
    value_numeric           NUMERIC(14,4),
    value_text              VARCHAR(500),
    value_code              VARCHAR(50),
    unit_of_measure         VARCHAR(30),
    reference_range_low     NUMERIC(14,4),
    reference_range_high    NUMERIC(14,4),
    abnormal_flag           VARCHAR(5),                 -- 'H','L','A','N'
    result_status           VARCHAR(20),               -- 'FINAL','PRELIMINARY','CORRECTED'
    ordering_provider_key   BIGINT,
    facility_id             VARCHAR(50)     NOT NULL,
    valid_from              TIMESTAMP       NOT NULL,
    recorded_at             TIMESTAMP       NOT NULL,
    is_current_version      BOOLEAN         NOT NULL    DEFAULT TRUE,
    PRIMARY KEY (observation_key)
)
PARTITION BY (observation_date_key)
CLUSTER BY (patient_key, loinc_code);
```

Using `loinc_code` as the observation type identifier means any new lab test or vital sign is a new row, not a new column. This scales indefinitely without schema changes.

**Late-Arriving Lab Results**: A lab specimen collected during an encounter on Monday may not have results finalized until Wednesday. The encounter is closed. The result arrives as a new row in `fact_observation` with `valid_from` = Monday (specimen collection time) and `recorded_at` = Wednesday (when the lab transmitted). Your incremental loads that run nightly will correctly insert Wednesday's new records. The complication is that any pre-computed aggregate that was materialized on Tuesday ("all observations for encounters closed today") will be stale — it will not include Wednesday's lab results that are clinically associated with Tuesday's encounters. The solution is a **watermark-based processing pattern**: never materialize aggregates with a cutoff date of "today." Use a configurable lag (e.g., results are typically final within 72 hours) and set the aggregate materialization cutoff to `today - 3 days`.

### Scale Mechanics

Large healthcare systems (regional networks, national payers) accumulate 100M–500M encounter records over a 10-year retention window. The `fact_observation` table grows faster — a single inpatient stay may generate 500+ observations.

| Table | Partition Key | Clustering | Incremental Strategy |
|-------|--------------|------------|---------------------|
| fact_encounter | admit_date_key | patient_key, encounter_type | MERGE on encounter_id + is_current_version |
| fact_diagnosis | diagnosis_date_key | patient_key, icd10_code | Append new + insert corrections as new rows |
| fact_observation | observation_date_key | patient_key, loinc_code | Append-only (corrections create new rows) |
| audit_clinical_change | DATE(changed_at) | table_name, record_key | Append-only |

The bi-temporal model is append-only by design: corrections never delete old rows, they insert new rows with updated `valid_to` on the old and a fresh `valid_from` on the new. This makes incremental loads simple (no deletes, no MERGE complexity) but makes current-state queries require a `WHERE is_current_version = TRUE` filter on every query. That filter, combined with `patient_key` clustering, enables efficient point-lookups even at 1B rows.

---

## 3. Manufacturing / Supply Chain

### When to Use This Design

Manufacturing analytics is driven by operational efficiency and traceability questions:

- What is the total material cost to produce product X, including all subassemblies?
- Which work orders are behind schedule and what is the downstream impact?
- How much of component Y do I need to order to fulfill 1,000 units of finished good Z?
- Was the quality event on Line 3 caused by a specific batch of raw material?

The domain-specific challenge is **recursive hierarchy**: a finished product is built from subassemblies, which are built from sub-subassemblies, which consume raw materials. The Bill of Materials (BOM) can be 8–12 levels deep. Queries that must traverse this hierarchy (cost rollup, requirements explosion) are fundamentally recursive — and recursive queries have different performance characteristics in different warehouse platforms.

### The Schema

#### Bill of Materials (Recursive Hierarchy)

```sql
-- BOM Item master: every part, whether purchased or manufactured
CREATE TABLE dim_bom_item (
    item_key                BIGINT          NOT NULL,
    item_id                 VARCHAR(50)     NOT NULL,   -- Part Number
    item_description        VARCHAR(300)    NOT NULL,
    item_type               VARCHAR(20)     NOT NULL,   -- 'RAW_MATERIAL','SUBASSEMBLY','FINISHED_GOOD','PHANTOM'
    unit_of_measure         VARCHAR(10)     NOT NULL,
    unit_cost               NUMERIC(14,6),
    lead_time_days          INT,
    make_or_buy             CHAR(3)         NOT NULL,   -- 'MFG' or 'BUY'
    preferred_supplier_key  BIGINT,
    is_active               BOOLEAN         NOT NULL    DEFAULT TRUE,
    PRIMARY KEY (item_key)
);

-- BOM structure: recursive parent-child relationship
CREATE TABLE fact_bom_structure (
    bom_structure_key       BIGINT          NOT NULL,
    parent_item_id          VARCHAR(50)     NOT NULL,
    child_item_id           VARCHAR(50)     NOT NULL,
    bom_level               INT             NOT NULL,   -- depth from root: 1 = top-level component
    quantity_per            NUMERIC(14,6)   NOT NULL,   -- qty of child needed per 1 parent
    scrap_factor            NUMERIC(6,4)    NOT NULL    DEFAULT 0,  -- 0.02 = 2% expected scrap
    eff_start_date          DATE            NOT NULL,
    eff_end_date            DATE            NOT NULL    DEFAULT '9999-12-31',
    is_current              BOOLEAN         NOT NULL    DEFAULT TRUE,
    bom_version             VARCHAR(20),
    PRIMARY KEY (bom_structure_key)
)
CLUSTER BY (parent_item_id, child_item_id);

-- Flattened BOM (materialized for query performance)
CREATE TABLE fact_bom_flattened (
    bom_flat_key            BIGINT          NOT NULL,
    root_item_id            VARCHAR(50)     NOT NULL,   -- finished good
    component_item_id       VARCHAR(50)     NOT NULL,   -- any-level component
    component_level         INT             NOT NULL,
    path_string             VARCHAR(1000),              -- "FG001 > SA010 > RM045"
    extended_quantity       NUMERIC(18,8)   NOT NULL,   -- total qty per 1 root unit
    eff_start_date          DATE            NOT NULL,
    eff_end_date            DATE            NOT NULL    DEFAULT '9999-12-31',
    PRIMARY KEY (bom_flat_key)
)
PARTITION BY (eff_start_date)
CLUSTER BY (root_item_id, component_item_id);
```

#### BOM Explosion: Query-Time vs Materialized

This is the central design tradeoff in manufacturing analytics.

**Query-time recursive CTE** (appropriate for < 500K BOM nodes, OLAP on interactive queries):

```sql
WITH RECURSIVE bom_explosion AS (
    -- Anchor: start from the finished good
    SELECT
        parent_item_id          AS root_item_id,
        child_item_id           AS component_item_id,
        quantity_per            AS extended_qty,
        bom_level,
        CAST(parent_item_id || ' > ' || child_item_id AS VARCHAR(1000)) AS path
    FROM fact_bom_structure
    WHERE parent_item_id = 'FG001'
      AND is_current = TRUE

    UNION ALL

    -- Recursive step: traverse deeper levels
    SELECT
        b.root_item_id,
        s.child_item_id,
        b.extended_qty * s.quantity_per * (1 + s.scrap_factor),
        b.bom_level + 1,
        b.path || ' > ' || s.child_item_id
    FROM bom_explosion b
    JOIN fact_bom_structure s
        ON b.component_item_id = s.parent_item_id
        AND s.is_current = TRUE
)
SELECT
    component_item_id,
    SUM(extended_qty) AS total_qty_needed,
    i.unit_cost,
    SUM(extended_qty) * i.unit_cost AS total_material_cost
FROM bom_explosion be
JOIN dim_bom_item i ON be.component_item_id = i.item_id
GROUP BY component_item_id, i.unit_cost;
```

**Why materialization wins at scale**: At 1M+ BOM nodes (common in aerospace or automotive), the recursive CTE spawns thousands of joins. Query time degrades from seconds to minutes. The `fact_bom_flattened` table is rebuilt nightly by the ELT pipeline running the above CTE — the cost is paid once at load time, not at every analyst query. The tradeoff is that the flattened table is stale relative to BOM changes made today. For most manufacturing analytics workloads, T+1 latency is acceptable. For real-time MRP systems, the recursive query is preferred or the flattened table is invalidated and rebuilt on every BOM change.

#### Work Orders

```sql
CREATE TABLE fact_work_order (
    work_order_key          BIGINT          NOT NULL,
    work_order_id           VARCHAR(50)     NOT NULL,
    finished_item_key       BIGINT          NOT NULL,
    planned_start_date_key  INT             NOT NULL,
    planned_end_date_key    INT             NOT NULL,
    actual_start_datetime   TIMESTAMP,
    actual_end_datetime     TIMESTAMP,
    plant_key               BIGINT          NOT NULL,
    work_center_key         BIGINT,
    planned_quantity        NUMERIC(14,3)   NOT NULL,
    completed_quantity      NUMERIC(14,3)   NOT NULL    DEFAULT 0,
    scrapped_quantity       NUMERIC(14,3)   NOT NULL    DEFAULT 0,
    order_status            VARCHAR(20)     NOT NULL,   -- 'PLANNED','RELEASED','IN_PROGRESS','COMPLETE','CANCELLED'
    priority_level          INT,
    sales_order_id          VARCHAR(50),               -- if MTO (Make-to-Order)
    scheduled_hours         NUMERIC(10,2),
    actual_hours            NUMERIC(10,2),
    PRIMARY KEY (work_order_key)
)
PARTITION BY (planned_start_date_key)
CLUSTER BY (plant_key, order_status, finished_item_key);
```

#### Inventory Movements in Manufacturing

Manufacturing inventory movements are significantly more complex than retail — they include production issues, scrap, rework, quality holds, and WIP transfers that have no retail equivalent.

```sql
CREATE TABLE fact_mfg_inventory_movement (
    movement_key            BIGINT          NOT NULL,
    movement_datetime       TIMESTAMP       NOT NULL,
    movement_date_key       INT             NOT NULL,
    item_key                BIGINT          NOT NULL,
    from_location_key       BIGINT,                    -- NULL for receipts
    to_location_key         BIGINT,                    -- NULL for issues to production
    work_order_key          BIGINT,                    -- NULL for non-production movements
    movement_type           VARCHAR(30)     NOT NULL,  -- 'RECEIPT','ISSUE','RETURN','SCRAP','TRANSFER','QC_HOLD','QC_RELEASE','ADJUSTMENT'
    quantity                NUMERIC(14,4)   NOT NULL,  -- always positive; direction from type
    lot_number              VARCHAR(50),               -- for lot-controlled items
    serial_number           VARCHAR(50),               -- for serialized items
    unit_cost_at_movement   NUMERIC(14,6),
    extended_cost           NUMERIC(18,6),
    PRIMARY KEY (movement_key)
)
PARTITION BY (movement_date_key)
CLUSTER BY (item_key, work_order_key, movement_type);
```

#### Quality Events

Quality event modeling must link to the specific batch, lot, or work order — not just the item. This linkage is what enables root cause analysis: "was the high scrap rate on Work Order 5550 caused by Lot XYZ of raw material RM045?"

```sql
CREATE TABLE fact_quality_event (
    quality_event_key       BIGINT          NOT NULL,
    event_id                VARCHAR(50)     NOT NULL,
    event_datetime          TIMESTAMP       NOT NULL,
    event_date_key          INT             NOT NULL,
    event_type              VARCHAR(30)     NOT NULL,  -- 'NONCONFORMANCE','SCRAP','REWORK','CUSTOMER_COMPLAINT','AUDIT_FINDING'
    item_key                BIGINT          NOT NULL,
    work_order_key          BIGINT,
    lot_number              VARCHAR(50),
    work_center_key         BIGINT,
    plant_key               BIGINT          NOT NULL,
    defect_code             VARCHAR(20)     NOT NULL,
    defect_description      VARCHAR(500),
    quantity_affected       NUMERIC(14,4)   NOT NULL,
    disposition             VARCHAR(20),               -- 'SCRAP','REWORK','USE_AS_IS','RETURN_TO_SUPPLIER'
    cost_of_quality         NUMERIC(14,2),
    root_cause_category     VARCHAR(50),
    corrective_action_id    VARCHAR(50),
    PRIMARY KEY (quality_event_key)
)
PARTITION BY (event_date_key)
CLUSTER BY (plant_key, item_key, defect_code);
```

### The Hard Problems

**Event-Driven Inventory Reconciliation**: At a large manufacturer with 50 plants and 100,000 SKUs, inventory movements arrive from ERP systems, IoT floor sensors, and manual transactions. The aggregate (sum of movements) should equal the physical count snapshot. When they diverge — and they will — the reconciliation query must identify the specific movements that caused the discrepancy. This requires both the movement fact (for aggregation) and the snapshot fact (for comparison). The movement table must support efficient `SUM(quantity) WHERE movement_type != 'ADJUSTMENT'` over arbitrary date ranges by item+location — hence `item_key` as the first clustering column.

**BOM Version Control**: BOMs change over time. When a component is substituted, the old BOM version must be retained for historical work order costing. The `eff_start_date/eff_end_date` pattern on `fact_bom_structure` handles this, but it means cost rollups for historical work orders must join to the BOM version effective at the time of the work order, not the current BOM. This is the same bi-temporal pattern as healthcare, applied to engineering data.

### Scale Mechanics

The BOM flattened table is the primary scale lever. In automotive supply chains, a vehicle BOM can have 30,000+ unique components with up to 12 hierarchy levels. The flattened table for a 10,000-part BOM across 20 finished goods produces ~200,000 rows — trivial. For a 30,000-part BOM across 500 models, the flattened table hits ~15M rows and becomes a first-class partitioned table partitioned by `root_item_id` hash bucket.

The inventory movement table is the high-velocity table in manufacturing analytics. A 50-plant operation running 24/7 generates 500K–2M movement records per day. At 5 years retention, this is 1B–3B rows. Partitioning by `movement_date_key` with clustering on `(item_key, plant_key)` reduces most operational queries (current stock by location) to single-partition scans.

---

## 4. Financial Services

### When to Use This Design

Financial services data modeling is governed by two imperatives that conflict with analytical convenience: **regulatory auditability** (every balance must be reconstructable at any historical date) and **transaction finality** (once settled, a transaction cannot be deleted or modified — only corrected via offsetting entries). The business questions:

- What was the account balance for account 12345 as of the close of business on December 31?
- Which transactions are driving the discrepancy between the general ledger and the sub-ledger?
- What is the total credit exposure to counterparty X across all products as of today?
- Show me the complete audit trail for all changes to the rate on loan 9999.

### The Schema

#### Double-Entry Accounting Ledger

Double-entry is the foundational constraint: every financial transaction must have equal debits and credits. The ledger model enforces this at the data level by storing both legs of every entry.

```sql
-- Journal entry header
CREATE TABLE fact_journal_entry (
    journal_entry_key       BIGINT          NOT NULL,
    journal_entry_id        VARCHAR(80)     NOT NULL,   -- source system JE ID
    entry_date              DATE            NOT NULL,
    entry_date_key          INT             NOT NULL,
    posting_datetime        TIMESTAMP       NOT NULL,   -- when it hit the GL
    effective_date          DATE            NOT NULL,   -- business date it applies to
    journal_type            VARCHAR(30)     NOT NULL,   -- 'STANDARD','REVERSAL','ADJUSTMENT','ACCRUAL'
    source_system           VARCHAR(50)     NOT NULL,
    reference_id            VARCHAR(100),              -- payment ID, trade ID, etc.
    description             VARCHAR(500),
    posted_by_user          VARCHAR(200)    NOT NULL,
    approved_by_user        VARCHAR(200),
    is_reversed             BOOLEAN         NOT NULL    DEFAULT FALSE,
    reversing_entry_id      VARCHAR(80),               -- points to reversal JE if applicable
    -- Validation
    debit_total             NUMERIC(20,4)   NOT NULL,
    credit_total            NUMERIC(20,4)   NOT NULL,
    is_balanced             BOOLEAN         NOT NULL    GENERATED ALWAYS AS (debit_total = credit_total),
    PRIMARY KEY (journal_entry_key)
)
PARTITION BY (entry_date_key)
CLUSTER BY (source_system, journal_type);

-- Journal entry lines (one row per account leg)
CREATE TABLE fact_journal_entry_line (
    je_line_key             BIGINT          NOT NULL,
    journal_entry_key       BIGINT          NOT NULL,
    journal_entry_id        VARCHAR(80)     NOT NULL,
    line_sequence           INT             NOT NULL,
    account_key             BIGINT          NOT NULL,
    cost_center_key         BIGINT,
    entity_key              BIGINT          NOT NULL,   -- legal entity
    debit_credit_flag       CHAR(1)         NOT NULL,   -- 'D' or 'C'
    amount                  NUMERIC(20,4)   NOT NULL,   -- always positive
    currency_code           CHAR(3)         NOT NULL,
    functional_amount       NUMERIC(20,4),             -- converted to functional currency
    exchange_rate           NUMERIC(14,8),
    counterparty_key        BIGINT,
    PRIMARY KEY (je_line_key)
)
PARTITION BY RANGE (journal_entry_key)  -- co-partitioned with header
CLUSTER BY (account_key, entity_key);
```

**Why amount is always positive with a debit_credit_flag**: Signed amounts (negative for credits) seem more intuitive but create aggregation errors. `SUM(amount)` on a signed column gives you zero for a balanced entry — which looks correct but hides all activity. `SUM(CASE WHEN debit_credit_flag = 'D' THEN amount ELSE 0 END)` is unambiguous. Regulatory systems (Basel III reporting, GAAP sub-ledger reconciliation) always use unsigned amounts with explicit sign flags.

#### Account Dimension with SCD Type 2

```sql
CREATE TABLE dim_account (
    account_key             BIGINT          NOT NULL,
    account_id              VARCHAR(30)     NOT NULL,   -- GL account code
    account_name            VARCHAR(200)    NOT NULL,
    account_type            VARCHAR(20)     NOT NULL,  -- 'ASSET','LIABILITY','EQUITY','REVENUE','EXPENSE'
    account_subtype         VARCHAR(50),
    normal_balance          CHAR(1)         NOT NULL,  -- 'D' (asset/expense) or 'C' (liab/equity/rev)
    parent_account_id       VARCHAR(30),               -- for rollup hierarchy
    fs_line_item            VARCHAR(100),              -- financial statement mapping
    is_intercompany         BOOLEAN         NOT NULL   DEFAULT FALSE,
    is_control_account      BOOLEAN         NOT NULL   DEFAULT FALSE,
    -- SCD Type 2
    eff_start_date          DATE            NOT NULL,
    eff_end_date            DATE            NOT NULL   DEFAULT '9999-12-31',
    is_current              BOOLEAN         NOT NULL   DEFAULT TRUE,
    PRIMARY KEY (account_key)
)
CLUSTER BY (account_type, account_id);
```

#### Transaction Fact at Multiple Granularities

The key design decision for financial transactions is whether to store at event grain or daily position grain. The answer is **both** — for different use cases.

```sql
-- Transaction fact (event grain — one row per settled transaction)
CREATE TABLE fact_transaction (
    transaction_key         BIGINT          NOT NULL,
    transaction_id          VARCHAR(80)     NOT NULL,
    transaction_date_key    INT             NOT NULL,
    transaction_datetime    TIMESTAMP       NOT NULL,
    value_date              DATE            NOT NULL,   -- economic settlement date
    account_key             BIGINT          NOT NULL,
    counterparty_key        BIGINT,
    product_key             BIGINT          NOT NULL,
    transaction_type        VARCHAR(30)     NOT NULL,  -- 'PAYMENT','TRANSFER','FEE','INTEREST','CHARGE_OFF'
    debit_credit_flag       CHAR(1)         NOT NULL,
    amount                  NUMERIC(20,4)   NOT NULL,
    currency_code           CHAR(3)         NOT NULL,
    functional_amount       NUMERIC(20,4)   NOT NULL,
    running_balance         NUMERIC(20,4),             -- denormalized for common queries, maintained by load
    channel                 VARCHAR(30),
    reference_number        VARCHAR(100),
    je_line_key             BIGINT,                    -- link to GL entry
    PRIMARY KEY (transaction_key)
)
PARTITION BY (transaction_date_key)
CLUSTER BY (account_key, transaction_type);

-- Daily position / account balance fact (snapshot grain)
CREATE TABLE fact_account_daily_position (
    position_key            BIGINT          NOT NULL,
    position_date_key       INT             NOT NULL,
    account_key             BIGINT          NOT NULL,
    entity_key              BIGINT          NOT NULL,
    product_key             BIGINT          NOT NULL,
    opening_balance         NUMERIC(20,4)   NOT NULL,
    total_debits            NUMERIC(20,4)   NOT NULL   DEFAULT 0,
    total_credits           NUMERIC(20,4)   NOT NULL   DEFAULT 0,
    closing_balance         NUMERIC(20,4)   NOT NULL,
    accrued_interest        NUMERIC(20,4),
    currency_code           CHAR(3)         NOT NULL,
    functional_closing_balance NUMERIC(20,4),
    PRIMARY KEY (position_key)
)
PARTITION BY (position_date_key)
CLUSTER BY (account_key, entity_key);
```

#### Point-in-Time Balance Reconstruction

The canonical financial services hard problem: "What was the balance of account X at close of business on December 31, 2023?" There are three approaches, each with different tradeoffs:

**Option 1: Scan transaction fact and sum from inception**
```sql
SELECT
    SUM(CASE WHEN debit_credit_flag = 'D' THEN amount ELSE -amount END) AS balance
FROM fact_transaction
WHERE account_key = 99999
  AND transaction_date_key <= 20231231;
```
Correct, but at 10 years of transaction history this is a multi-billion row scan for a single account. Unacceptable response time.

**Option 2: Use daily position snapshot**
```sql
SELECT closing_balance
FROM fact_account_daily_position
WHERE account_key = 99999
  AND position_date_key = 20231231;
```
O(1) lookup, millisecond response. But what if December 31 was not loaded (weekend, holiday processing delay)? The query returns NULL instead of the correct balance. You need:

```sql
SELECT closing_balance
FROM fact_account_daily_position
WHERE account_key = 99999
  AND position_date_key = (
      SELECT MAX(position_date_key)
      FROM fact_account_daily_position
      WHERE account_key = 99999
        AND position_date_key <= 20231231
  );
```

**Option 3: Hybrid (production pattern)**
Use daily snapshots for dates where snapshots exist, fall back to transaction summation for gaps. This is encapsulated in a SQL view or a dbt model that generates the correct balance for any arbitrary date.

#### Risk/Exposure Modeling

Credit exposure requires knowing, at any point in time, how much a given counterparty owes across all products and legal entities. This is the "aggregation across grains" problem:

```sql
CREATE TABLE fact_credit_exposure (
    exposure_key            BIGINT          NOT NULL,
    exposure_date_key       INT             NOT NULL,
    counterparty_key        BIGINT          NOT NULL,
    entity_key              BIGINT          NOT NULL,
    product_key             BIGINT          NOT NULL,
    facility_id             VARCHAR(50),               -- credit limit facility
    exposure_type           VARCHAR(30)     NOT NULL,  -- 'DRAWN','UNDRAWN','CONTINGENT','DERIVATIVE_MtM'
    gross_exposure          NUMERIC(20,4)   NOT NULL,
    collateral_value        NUMERIC(20,4)   NOT NULL   DEFAULT 0,
    net_exposure            NUMERIC(20,4)   NOT NULL,  -- gross - collateral
    pd_estimate             NUMERIC(8,6),              -- Probability of Default
    lgd_estimate            NUMERIC(8,6),              -- Loss Given Default
    expected_credit_loss    NUMERIC(20,4),             -- pd * lgd * net_exposure
    currency_code           CHAR(3)         NOT NULL,
    PRIMARY KEY (exposure_key)
)
PARTITION BY (exposure_date_key)
CLUSTER BY (counterparty_key, entity_key, exposure_type);
```

### The Hard Problems

**Audit Trail for Rate Changes**: When a loan's interest rate changes (rate adjustment, renegotiation, error correction), the history of rate changes must be preserved not just as the current rate but with the exact window each rate was effective. This is another bi-temporal requirement. The `dim_account` SCD Type 2 captures when the warehouse learned about the rate change. A separate `fact_account_rate_history` table captures the contractually effective rate windows:

```sql
CREATE TABLE fact_account_rate_history (
    rate_history_key        BIGINT          NOT NULL,
    account_key             BIGINT          NOT NULL,
    account_id              VARCHAR(30)     NOT NULL,
    rate_type               VARCHAR(30)     NOT NULL,  -- 'INTEREST','PENALTY','PROMO'
    rate_value              NUMERIC(10,6)   NOT NULL,
    rate_basis              VARCHAR(20)     NOT NULL,  -- 'ANNUAL','DAILY','MONTHLY'
    contractual_start_date  DATE            NOT NULL,  -- valid time: when rate is effective
    contractual_end_date    DATE            NOT NULL   DEFAULT '9999-12-31',
    recorded_at             TIMESTAMP       NOT NULL,  -- transaction time
    recorded_by             VARCHAR(200)    NOT NULL,
    change_reason           VARCHAR(200),
    PRIMARY KEY (rate_history_key)
)
CLUSTER BY (account_key, rate_type);
```

**Balance Reconciliation at Any Historical Date**: The daily position fact assumes the GL and sub-ledger are always in sync. They are not. Reconciliation breaks require querying `fact_journal_entry_line` summed by account versus `fact_account_daily_position.closing_balance` for the same account and date. Discrepancies are expected during end-of-day processing windows. The correct architecture stores a `reconciliation_status` flag on `fact_account_daily_position` that is updated when the GL sign-off process runs.

### Scale Mechanics

At a major bank, the `fact_transaction` table grows at 100M–500M rows per day across all products. Five years of retention yields 100B+ rows. This is beyond the scale where daily partition scans are acceptable even for a single account. The practical solution used by Citi, JPMorgan, and others in their analytical warehouses:

1. Partition by `transaction_date_key` (daily)
2. Cluster by `(account_key, transaction_type)` within partitions
3. Maintain pre-computed `fact_account_daily_position` as the primary query surface
4. Retain raw transactions in "cold" storage (GCS/S3) beyond 2 years; hot warehouse holds only recent history
5. For point-in-time balance questions on accounts older than 2 years, query the archived daily snapshots in cold storage

---

## 5. SaaS / Product Analytics

### When to Use This Design

SaaS analytics is event-first: the raw material is a stream of user actions. The business questions:

- What is the 30-day retention rate for users who signed up in January?
- What percentage of users complete the onboarding funnel within 7 days of signup?
- What features correlate with customers who expand from Starter to Growth tier?
- Which anonymous sessions from last month can we now match to identified users?

The fundamental modeling tension in SaaS analytics: the raw event stream is the source of truth, but answering funnel, session, and cohort questions from raw events requires expensive aggregations. The model must pre-compute enough to make standard questions fast without discarding the raw grain that enables ad-hoc analysis.

### The Schema

#### Event Stream (Segment-Style)

Segment's track/identify/page model is the de facto standard. The warehouse representation:

```sql
-- Core event table (one row per user action)
CREATE TABLE events (
    event_id                VARCHAR(80)     NOT NULL,   -- UUID from client
    received_at             TIMESTAMP       NOT NULL,   -- when Segment/server received it
    sent_at                 TIMESTAMP,                  -- when client sent it (may differ)
    original_timestamp      TIMESTAMP,                  -- client-side timestamp
    event_name              VARCHAR(200)    NOT NULL,   -- 'Page Viewed','Button Clicked','Form Submitted'
    event_category          VARCHAR(100),
    anonymous_id            VARCHAR(80)     NOT NULL,   -- pre-login identifier (cookie/device)
    user_id                 VARCHAR(80),                -- NULL until identified
    session_id              VARCHAR(80),                -- pre-computed or NULL
    tenant_id               VARCHAR(50)     NOT NULL,   -- for multi-tenant SaaS
    -- Context
    page_url                VARCHAR(2000),
    page_title              VARCHAR(500),
    referrer_url            VARCHAR(2000),
    utm_source              VARCHAR(200),
    utm_medium              VARCHAR(200),
    utm_campaign            VARCHAR(200),
    -- Device context
    device_type             VARCHAR(20),               -- 'desktop','mobile','tablet'
    os_name                 VARCHAR(50),
    browser_name            VARCHAR(50),
    ip_address              VARCHAR(45),               -- IPv4 or IPv6
    -- Properties (event-specific, stored as JSON)
    properties              VARIANT,                   -- Snowflake VARIANT / BQ JSON
    -- Processing metadata
    dw_inserted_at          TIMESTAMP       NOT NULL,
    PRIMARY KEY (event_id)
)
PARTITION BY DATE(received_at)
CLUSTER BY (tenant_id, user_id, event_name);
```

**Why VARIANT/JSON for properties?**: Event-specific properties (a `Button Clicked` event has `button_label`, `button_position`; a `Form Submitted` event has `form_name`, `field_count`, `validation_errors`) vary per event type. Encoding these as top-level columns requires 200+ sparse columns on the events table. VARIANT avoids this at the cost of query-time parsing overhead. The mitigation is to create typed sub-tables for high-cardinality events:

```sql
-- Typed table for Page Viewed events (high volume, structured properties)
CREATE TABLE events_page_viewed (
    event_id                VARCHAR(80)     NOT NULL,
    received_at             TIMESTAMP       NOT NULL,
    user_id                 VARCHAR(80),
    anonymous_id            VARCHAR(80)     NOT NULL,
    tenant_id               VARCHAR(50)     NOT NULL,
    page_url                VARCHAR(2000),
    page_path               VARCHAR(500),
    page_title              VARCHAR(500),
    time_on_page_seconds    INT,
    scroll_depth_pct        INT,
    PRIMARY KEY (event_id)
)
PARTITION BY DATE(received_at)
CLUSTER BY (tenant_id, user_id);
```

#### User Identity Resolution

The hardest problem in product analytics: a user starts as `anonymous_id = anon_abc123`, creates an account, and becomes `user_id = user_456`. Their pre-signup events are associated with the anonymous ID. Post-signup events have both IDs. How do you stitch the journey?

```sql
-- Identity stitching map
CREATE TABLE dim_identity_map (
    identity_map_key        BIGINT          NOT NULL,
    canonical_user_id       VARCHAR(80)     NOT NULL,   -- the "winning" user_id
    anonymous_id            VARCHAR(80)     NOT NULL,
    device_id               VARCHAR(80),
    email_address           VARCHAR(200),
    first_seen_at           TIMESTAMP       NOT NULL,
    identified_at           TIMESTAMP,                  -- when anon -> identified linkage happened
    is_active               BOOLEAN         NOT NULL    DEFAULT TRUE,
    tenant_id               VARCHAR(50)     NOT NULL,
    PRIMARY KEY (identity_map_key)
)
CLUSTER BY (tenant_id, canonical_user_id, anonymous_id);
```

The resolution query pattern — joining events to the identity map to get a canonical user journey — is expensive because it requires non-equi-join logic for pre-identification events. The practical solution is to materialize a `events_resolved` table or view that has `canonical_user_id` populated for all events, including retroactively applying the identity to pre-signup events. This materialization runs on a schedule (nightly or hourly) and is never strictly real-time.

#### Session Modeling

Sessions are a computed concept. The two approaches:

**Pre-computed sessions table** (recommended for volume > 100M events/day):

```sql
CREATE TABLE dim_session (
    session_id              VARCHAR(80)     NOT NULL,
    user_id                 VARCHAR(80),
    anonymous_id            VARCHAR(80)     NOT NULL,
    tenant_id               VARCHAR(50)     NOT NULL,
    session_start_at        TIMESTAMP       NOT NULL,
    session_end_at          TIMESTAMP,
    session_duration_seconds INT,
    page_view_count         INT             NOT NULL    DEFAULT 0,
    event_count             INT             NOT NULL    DEFAULT 0,
    entry_page_url          VARCHAR(2000),
    exit_page_url           VARCHAR(2000),
    utm_source              VARCHAR(200),
    utm_medium              VARCHAR(200),
    utm_campaign            VARCHAR(200),
    device_type             VARCHAR(20),
    is_bounce               BOOLEAN         NOT NULL    DEFAULT FALSE,  -- single page view
    PRIMARY KEY (session_id)
)
PARTITION BY DATE(session_start_at)
CLUSTER BY (tenant_id, user_id);
```

Session boundaries are defined by a configurable inactivity timeout (typically 30 minutes). The sessionization logic runs as a window function in the ELT pipeline:

```sql
-- Sessionization via window function in dbt/ELT
WITH event_gaps AS (
    SELECT
        event_id,
        anonymous_id,
        tenant_id,
        received_at,
        LAG(received_at) OVER (
            PARTITION BY anonymous_id, tenant_id
            ORDER BY received_at
        ) AS prior_event_at,
        DATEDIFF('minute',
            LAG(received_at) OVER (
                PARTITION BY anonymous_id, tenant_id
                ORDER BY received_at
            ),
            received_at
        ) AS minutes_since_last_event
    FROM events
),
session_starts AS (
    SELECT
        *,
        CASE
            WHEN prior_event_at IS NULL THEN 1         -- first event = new session
            WHEN minutes_since_last_event > 30 THEN 1  -- 30-min gap = new session
            ELSE 0
        END AS is_session_start
    FROM event_gaps
),
session_ids AS (
    SELECT
        *,
        SUM(is_session_start) OVER (
            PARTITION BY anonymous_id, tenant_id
            ORDER BY received_at
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) AS session_sequence_num
    FROM session_starts
)
SELECT
    anonymous_id || '-' || tenant_id || '-' || session_sequence_num AS session_id,
    *
FROM session_ids;
```

**Query-time sessionization**: Works for ad-hoc exploration but is catastrophically slow at 100M+ events/day. The window function scan must process the entire event table. Pre-computation is the only production-viable option.

#### Multi-Tenant Isolation Strategies

This is an architectural decision with profound data modeling implications.

| Strategy | Schema Design | Query Isolation | Data Volume | Operational Cost |
|----------|--------------|----------------|-------------|-----------------|
| Row-level (shared tables) | `tenant_id` column on every table | Row Access Policy / WHERE clause | Efficient at scale | Low |
| Schema-per-tenant | Each tenant gets own schema | Schema-level | Moderate per tenant | Medium |
| Database-per-tenant | Each tenant gets own database | Database-level | Max isolation | Very High |

**Row-level** is correct for B2C SaaS with hundreds or thousands of tenants generating relatively small individual volumes. The `tenant_id` column must be on every table and must be the first clustering column. Without it as a cluster key, queries filter by row access policy but still scan the entire partition.

**Schema-per-tenant** is appropriate for B2B enterprise SaaS with 10–100 large customers who have strict data isolation contractual requirements but volume is manageable per schema.

**Database-per-tenant** is appropriate when tenants have dramatically different schemas (extensible platforms) or regulatory requirements mandating physical separation (government SaaS, healthcare).

#### Funnel Modeling

Funnel analysis is the most common SaaS product analytics query. The naive approach is a correlated subquery for each funnel step — which becomes N full table scans for an N-step funnel.

The correct pattern is a single-pass pivoted model:

```sql
-- Funnel completion fact (pre-computed, grain: one row per user per funnel)
CREATE TABLE fact_funnel_completion (
    funnel_completion_key   BIGINT          NOT NULL,
    user_id                 VARCHAR(80),
    anonymous_id            VARCHAR(80)     NOT NULL,
    tenant_id               VARCHAR(50)     NOT NULL,
    funnel_name             VARCHAR(100)    NOT NULL,  -- 'ONBOARDING','CHECKOUT','UPGRADE'
    cohort_date             DATE            NOT NULL,  -- date of funnel entry (step 1)
    step_1_completed_at     TIMESTAMP       NOT NULL,
    step_2_completed_at     TIMESTAMP,
    step_3_completed_at     TIMESTAMP,
    step_4_completed_at     TIMESTAMP,
    step_5_completed_at     TIMESTAMP,
    max_step_reached        INT             NOT NULL   DEFAULT 1,
    converted               BOOLEAN         NOT NULL   DEFAULT FALSE,  -- reached final step
    days_to_convert         INT,
    PRIMARY KEY (funnel_completion_key)
)
PARTITION BY (cohort_date)
CLUSTER BY (tenant_id, funnel_name, converted);
```

With this model, funnel drop-off rates are simple aggregations:

```sql
SELECT
    COUNT(*) AS entered_funnel,
    COUNT(step_2_completed_at) AS reached_step_2,
    COUNT(step_3_completed_at) AS reached_step_3,
    COUNT(step_4_completed_at) AS reached_step_4,
    COUNT(step_5_completed_at) AS converted,
    COUNT(step_5_completed_at)::FLOAT / COUNT(*) AS conversion_rate
FROM fact_funnel_completion
WHERE tenant_id = 'tenant_abc'
  AND funnel_name = 'ONBOARDING'
  AND cohort_date BETWEEN '2024-01-01' AND '2024-01-31';
```

This query runs in milliseconds regardless of event volume because it scans the pre-aggregated funnel fact, not the raw events.

### The Hard Problems

**Event Volume and Sessionization at Scale**: At 500M events/day (realistic for a mid-size SaaS company), sessionizing the full event stream nightly is a 30–60 minute job. The incremental sessionization challenge: sessions can span midnight boundaries, and new events arriving for an in-progress session must update the session's end time and event count without a full recomputation. The solution is a **two-phase approach**: (1) close sessions where the last event was > 30 minutes ago; (2) accumulate active sessions in a staging table updated throughout the day.

**User Merges**: When two user accounts are merged (duplicate accounts), all historical events associated with the merged account must be re-attributed to the canonical account. This retroactively invalidates any pre-computed funnel and session models that used the old user ID. The identity map table handles real-time queries, but pre-computed aggregates require a recomputation trigger on any identity merge event.

### Scale Mechanics

| Event Volume | Sessionization | Funnel | Identity Resolution |
|-------------|---------------|--------|-------------------|
| < 10M/day | Query-time acceptable | Query-time acceptable | Nightly full |
| 10M–100M/day | Nightly incremental | Pre-computed fact | Nightly incremental |
| 100M–1B/day | Real-time stream (Flink/Spark Streaming) | Pre-computed + streaming | Event-time streaming |
| > 1B/day | Purpose-built event store (Kafka + ClickHouse) | ClickHouse materialized views | Streaming identity graph |

---

## 6. Telecommunications

### When to Use This Design

Telecom analytics operates at an intersection of high-volume operational data and complex customer/network relationships. Business questions:

- Which subscribers are showing churn indicators (declining usage, service complaints, plan downgrades)?
- What is the revenue impact of network outages in the Northeast region last quarter?
- Which cell towers are generating the most dropped calls and are they correlated with equipment age?
- What is the average revenue per user (ARPU) by plan type for the last 12 months?

The domain-defining artifact is the **Call Detail Record (CDR)** — a structured log of every call, SMS, and data session. At a carrier with 10M subscribers, CDR volume is 5–20 billion records per month. The modeling decisions made here directly determine whether operational and analytical queries are tenable.

### The Schema

#### Call Detail Records (CDRs)

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

#### Subscriber Lifecycle with SCD Type 2

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

#### Service Plan Modeling

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

#### Network Topology (Graph-Like Hierarchy)

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

#### Churn Prediction Data Structures

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

### The Hard Problems

**Streaming CDR Ingestion**: CDRs arrive from multiple network elements (MSCs, packet gateways, IMS nodes) in near-real-time. The pipeline challenge is that CDRs from different sources arrive with different latencies — a voice CDR from the MSC may arrive in seconds; a roaming data session CDR from an international partner may arrive in hours or days. The warehouse must accommodate late-arriving CDRs without corrupting existing aggregates.

The solution is a **two-layer architecture**:
1. A raw CDR landing table with `received_at` (warehouse arrival time) partition
2. The analytical `fact_cdr` table partitioned by `event_date_key` (call start time)

The ELT job runs hourly: it picks up all CDRs received in the last hour and inserts them into the correct `event_date_key` partition in `fact_cdr`. For late-arriving roaming CDRs, the hourly job handles the retroactive insert. Pre-computed hourly aggregates are never finalized until a configurable lag (72 hours for international roaming) has passed.

**Near-Real-Time Aggregation Patterns**: Network operations centers (NOC) require sub-minute visibility into call drop rates, signal quality, and capacity utilization. These cannot wait for the nightly batch. The pattern is a **dual-path architecture**:

- **Hot path**: CDRs stream to Apache Kafka → ksqlDB or Apache Flink aggregation → time-series database (TimescaleDB, InfluxDB) for NOC dashboards. 1-minute aggregates, 72-hour retention.
- **Cold path**: CDRs batch-load to the analytical warehouse every hour. Full history, slower queries, used by planning and finance.

The NOC dashboard queries the time-series DB. Business analysts query the warehouse. Never ask the analytical warehouse to serve sub-minute operational queries.

### Scale Mechanics

| Table | Rows/Month (10M subscribers) | Partition | Cluster | Incremental Strategy |
|-------|------------------------------|-----------|---------|---------------------|
| fact_cdr | 5B–20B | date + hour | subscriber_key, call_type | Hourly append |
| fact_subscriber_monthly_summary | 10M | summary_month_key | subscriber_key | Monthly full replace for given month |
| dim_subscriber | 10M current + SCD history | eff_start_date | account_type | MERGE on subscriber_id |
| fact_subscriber_plan_history | 50M | — | subscriber_key | Append on plan change events |

At 20B CDRs/month, the fact_cdr table grows at 240B rows/year. Object storage tiering is mandatory: hot tier (Snowflake/BigQuery) covers 3 months (60B rows); warm tier (Iceberg on S3) covers 2 years; cold tier (compressed Parquet on Glacier) covers full regulatory retention (7 years). Query routing (via virtual warehouse size tiers in Snowflake or BI+table function routing in BigQuery) directs NOC queries to the hot tier and historical regulatory queries to the Iceberg layer.

---

## 7. Dimensional vs Data Vault vs One Big Table (OBT)

### When Each Architecture Wins

These three paradigms are not competing alternatives for the same problem — they solve different problems. The confusion arises because all three can technically produce similar analytical outputs.

| Dimension | Dimensional (Kimball) | Data Vault | One Big Table (OBT) |
|-----------|----------------------|------------|---------------------|
| Primary consumer | BI tools, business analysts | Data engineers, integration teams | Data scientists, ML, ad-hoc SQL |
| Schema philosophy | Query-optimized (denormalized dimensions) | Audit-optimized (normalized hubs/links/satellites) | Convenience-optimized (everything in one place) |
| Change handling | SCD types on dimensions | Satellite versioning (all history preserved) | Depends on implementation |
| Query complexity | Low (star schema, 2-3 table joins) | High (hub+link+sat reconstruction) | Minimal (single table filter) |
| Data volume efficiency | Moderate (dimension table replicated per join) | High (no duplication of keys) | Lowest (all denormalized per row) |
| Team size sweet spot | 5–50 analysts | 10–100 engineers across domains | 1–10 data scientists |
| Auditability | Moderate | Maximum | Low |

**Dimensional wins when**: The primary consumers are business analysts using BI tools (Tableau, Looker, Power BI). The query patterns are well-understood, relatively stable, and require < 4 table joins to answer. The team has defined the business processes and grain before building.

**Data Vault wins when**: Multiple heterogeneous source systems feed the same warehouse and must be loaded in parallel without coordination. Auditability of every load (who loaded what, when, from where) is a compliance requirement. The business domain changes frequently — new attributes arrive without requiring schema redesign. The team is large enough to manage the abstraction cost.

**OBT wins when**: The primary consumer is a Python/SQL data scientist building ML features. The wide table eliminates joins that would otherwise be written 50 times across 50 notebooks. The domain is narrow enough that the OBT stays manageable (< 200 columns). At Airbnb and Netflix, OBT patterns are used for ML feature serving — not for BI reporting.

### Same Domain, Three Ways: E-Commerce Order Lines

#### Kimball Dimensional

```sql
-- dim_customer, dim_sku, dim_date → fact_order_line
SELECT
    d.full_date,
    c.loyalty_tier,
    s.category_name,
    SUM(f.line_gross_revenue) AS revenue
FROM fact_order_line f
JOIN dim_date d ON f.order_date_key = d.date_key
JOIN dim_customer c ON f.customer_key = c.customer_key AND c.is_current = TRUE
JOIN dim_sku s ON f.sku_key = s.sku_key AND s.is_current = TRUE
GROUP BY 1, 2, 3;
```

3-join star schema query. Fast on columnar engines with proper clustering. BI tool-friendly.

#### Data Vault

```sql
-- Hub_Customer → Link_Order_Customer → Link_OrderLine → Sat_OrderLine_Details
-- Hub_SKU → Sat_SKU_Category

-- Data Vault reconstruction (simplified — real DV is more joins)
SELECT
    dd.full_date,
    sc.loyalty_tier,
    ss.category_name,
    SUM(sol.line_gross_revenue) AS revenue
FROM link_order_line lol
JOIN hub_order ho ON lol.order_hk = ho.order_hk
JOIN link_order_customer loc ON ho.order_hk = loc.order_hk
JOIN hub_customer hc ON loc.customer_hk = hc.customer_hk
JOIN sat_customer sc ON hc.customer_hk = sc.customer_hk
    AND sc.load_date <= CURRENT_DATE
    AND (sc.load_end_date IS NULL OR sc.load_end_date > CURRENT_DATE)
JOIN hub_sku hs ON lol.sku_hk = hs.sku_hk
JOIN sat_sku ss ON hs.sku_hk = ss.sku_hk
    AND ss.load_date <= CURRENT_DATE
    AND (ss.load_end_date IS NULL OR ss.load_end_date > CURRENT_DATE)
JOIN sat_order_line_details sol ON lol.order_line_hk = sol.order_line_hk
JOIN dim_date dd ON sol.order_date_key = dd.date_key
GROUP BY 1, 2, 3;
```

7+ join query. Not BI-tool friendly. Typically used as the raw layer, with a Business Vault or presentation layer (which looks like Kimball) built on top. The Data Vault is the integration layer, not the reporting layer.

#### One Big Table (OBT)

```sql
-- obt_order_lines: all dimensions denormalized into one table
CREATE TABLE obt_order_lines AS
SELECT
    f.order_line_id,
    f.order_id,
    f.order_placed_at,
    f.line_gross_revenue,
    f.line_cogs,
    -- Customer attributes at time of order (snapshot join in build process)
    c.customer_id,
    c.loyalty_tier,
    c.acquisition_channel,
    -- SKU attributes
    s.sku_id,
    s.product_id,
    s.product_name,
    s.category_name,
    s.brand,
    -- Date attributes
    d.full_date,
    d.day_of_week_name,
    d.is_holiday,
    d.fiscal_week,
    d.fiscal_quarter,
    -- Promotion attributes
    p.promo_name,
    p.promo_type,
    p.discount_value
FROM fact_order_line f
LEFT JOIN dim_customer c ON f.customer_key = c.customer_key AND c.is_current = TRUE
LEFT JOIN dim_sku s ON f.sku_key = s.sku_key AND s.is_current = TRUE
LEFT JOIN dim_date d ON f.order_date_key = d.date_key
LEFT JOIN dim_promotion p ON f.promo_key = p.promo_key;
```

Query is trivial: `SELECT loyalty_tier, category_name, SUM(line_gross_revenue) FROM obt_order_lines GROUP BY 1, 2`. The OBT is a materialized output of the dimensional model — it should be **built from** the dimensional model, not instead of it. The failure mode is building the OBT directly from source systems, which embeds business logic in a monolithic table with no SCD handling.

---

## 8. SCD Types in Depth

### Type 1 — Overwrite

The current value replaces the old value. No history is retained.

```sql
-- Type 1 update: customer email address corrected
UPDATE dim_customer
SET email_address = 'new.email@example.com',
    dw_updated_at = CURRENT_TIMESTAMP
WHERE customer_id = 'CUST-001'
  AND is_current = TRUE;
```

**Can answer**: What is the customer's current email address?
**Cannot answer**: What email did we send to this customer in January 2023?
**Use when**: The attribute correction represents a fix to wrong data (typo, not a change). Business users never ask historical questions about this attribute.

### Type 2 — Add New Row (Full History)

A new row is inserted for every change. Old rows are expired with an `eff_end_date`.

```sql
-- Type 2 change: customer upgrades to Gold loyalty tier
UPDATE dim_customer
SET eff_end_date = '2024-06-14',
    is_current = FALSE,
    dw_updated_at = CURRENT_TIMESTAMP
WHERE customer_id = 'CUST-001'
  AND is_current = TRUE;

INSERT INTO dim_customer (
    customer_key, customer_id, loyalty_tier, eff_start_date, eff_end_date, is_current, dw_inserted_at, ...
) VALUES (
    99999, 'CUST-001', 'GOLD', '2024-06-15', '9999-12-31', TRUE, CURRENT_TIMESTAMP, ...
);
```

**Can answer**: What loyalty tier was the customer when they placed order X on March 10?
**Cannot answer**: What was the customer's loyalty tier corrected to after we discovered a data error (without bi-temporal)? (This requires the bi-temporal extension.)
**The COUNT DISTINCT problem**: If you `COUNT(DISTINCT customer_key)` on a Type 2 dimension joined to a fact, you count surrogate keys — and one logical customer has multiple surrogate keys. A customer who changed tier twice has 3 surrogate keys. `COUNT(DISTINCT customer_key)` returns 3 for what should be 1 distinct customer.

**Fix**: Always `COUNT(DISTINCT customer_id)` (the natural key) or `COUNT(DISTINCT customer_key) OVER (filter to is_current = TRUE)` when counting distinct customers.

```sql
-- WRONG: double-counts customers who changed loyalty tier
SELECT COUNT(DISTINCT customer_key) AS unique_customers
FROM fact_order_line;

-- CORRECT: count logical customers
SELECT COUNT(DISTINCT c.customer_id) AS unique_customers
FROM fact_order_line f
JOIN dim_customer c ON f.customer_key = c.customer_key;
-- The join uses the surrogate key at order time; natural key deduplicates
```

### Type 3 — Add Column for Prior Value

Only the current value and one prior value are stored. History beyond one change is lost.

```sql
ALTER TABLE dim_customer
ADD COLUMN prior_loyalty_tier VARCHAR(20),
ADD COLUMN loyalty_tier_change_date DATE;

-- Update:
UPDATE dim_customer
SET prior_loyalty_tier = loyalty_tier,
    loyalty_tier_change_date = '2024-06-15',
    loyalty_tier = 'GOLD'
WHERE customer_id = 'CUST-001' AND is_current = TRUE;
```

**Can answer**: What was the customer's previous tier before the most recent change?
**Cannot answer**: What was the tier 3 changes ago?
**Use when**: Analysts genuinely only ever need "current vs previous" (A/B test holdout comparison, promotion response analysis for the most recent change only). Rare in practice.

### Type 4 — Mini-Dimension (History Table)

Rapidly changing attributes are split into a separate history table. The main dimension stores only stable attributes.

```sql
-- Main dimension (stable attributes only)
CREATE TABLE dim_customer (
    customer_key     BIGINT  NOT NULL,
    customer_id      VARCHAR(50) NOT NULL,
    first_name       VARCHAR(100),
    last_name        VARCHAR(100),
    acquisition_date DATE,
    PRIMARY KEY (customer_key)
);

-- Mini-dimension for frequently changing profile attributes
CREATE TABLE dim_customer_profile (
    profile_key         BIGINT  NOT NULL,
    customer_id         VARCHAR(50) NOT NULL,
    loyalty_tier        VARCHAR(20),
    email_subscribed    BOOLEAN,
    sms_subscribed      BOOLEAN,
    last_purchase_date  DATE,
    eff_start_date      DATE   NOT NULL,
    eff_end_date        DATE   NOT NULL DEFAULT '9999-12-31',
    is_current          BOOLEAN NOT NULL DEFAULT TRUE,
    PRIMARY KEY (profile_key)
);
```

**Use when**: A small set of attributes changes very frequently (daily or hourly) and tracking them in the main dimension would generate enormous numbers of Type 2 rows — bloating the dimension and degrading join performance on the fact.

### Type 6 — Hybrid (1+2+3)

Type 6 combines Type 1 (overwrite current value), Type 2 (add new row), and Type 3 (add prior value column) into a single row structure:

```sql
CREATE TABLE dim_customer_type6 (
    customer_key         BIGINT   NOT NULL,  -- surrogate key (changes on Type 2 event)
    customer_id          VARCHAR(50) NOT NULL,  -- natural key
    -- Type 2: historical value (value when this row was created)
    loyalty_tier_hist    VARCHAR(20) NOT NULL,
    -- Type 3: previous value (what the value was in the immediately prior row)
    loyalty_tier_prev    VARCHAR(20),
    -- Type 1: current value (always overwritten to show current, regardless of row age)
    loyalty_tier_curr    VARCHAR(20) NOT NULL,
    eff_start_date       DATE     NOT NULL,
    eff_end_date         DATE     NOT NULL DEFAULT '9999-12-31',
    is_current           BOOLEAN  NOT NULL DEFAULT TRUE,
    PRIMARY KEY (customer_key)
);
```

A historical fact row joined to a Type 6 dimension gives three perspectives simultaneously: the tier at the time of the fact (`loyalty_tier_hist`), the tier immediately before the change (`loyalty_tier_prev`), and the current tier (`loyalty_tier_curr`). This enables "what tier are they now vs what tier were they when they ordered?" without any additional join.

**Maintenance complexity**: When a new change creates a new Type 2 row, all prior rows for that customer must have their `loyalty_tier_curr` column updated (Type 1 overwrite across the history). At 100M customer rows, this update operation is expensive. Type 6 is appropriate for dimensions with < 10M rows where the "current value in historical context" query is frequent.

### Bi-Temporal: When Type 2 Is Insufficient

Type 2 records the transaction time: when the warehouse recorded the change. It does not record the valid time: when the change was actually effective in the real world. For most dimensions, these are the same. But when corrections are made retroactively, they diverge.

**Scenario**: A customer's loyalty tier was incorrectly coded as Bronze instead of Gold from January through March (a system error was discovered in April). A Type 2 model creates a new Gold row effective April 1. All January–March orders are still joined to the Bronze surrogate key. Historical revenue reports are wrong for those months — they show the wrong tier context.

The bi-temporal fix:

```sql
CREATE TABLE dim_customer_bitemporal (
    customer_key            BIGINT   NOT NULL,
    customer_id             VARCHAR(50) NOT NULL,
    loyalty_tier            VARCHAR(20),
    -- Valid time (real world)
    valid_from              DATE     NOT NULL,
    valid_to                DATE     NOT NULL DEFAULT '9999-12-31',
    -- Transaction time (warehouse recording)
    recorded_from           TIMESTAMP NOT NULL,
    recorded_to             TIMESTAMP NOT NULL DEFAULT '9999-12-31 23:59:59',
    is_current_valid        BOOLEAN  NOT NULL DEFAULT TRUE,
    PRIMARY KEY (customer_key)
);
```

The correction is modeled as:
1. Expire the incorrect Bronze rows (set `valid_to = '2023-03-31'` AND `recorded_to = CURRENT_TIMESTAMP`)
2. Insert corrected Gold rows with `valid_from = '2023-01-01'`, `valid_to = '2023-03-31'`, `recorded_from = CURRENT_TIMESTAMP`

Queries for the current view of history use `WHERE recorded_to = '9999-12-31 23:59:59'`. Queries for what the system believed before the correction use `WHERE recorded_from <= '<correction_date>'`. This is essential for auditability in regulated industries where "what did you report in Q1" must be answerable independently of subsequent corrections.

---

## 9. Partitioning and Clustering Strategy

### How Query Patterns Drive Partition Key Selection

The partition key should match the most common filter predicate in analytical queries — specifically, the column that, when filtered, eliminates the most data from consideration.

**Rule 1: High-cardinality time columns partition well.** `event_date`, `transaction_date`, `order_date` are the canonical partition keys because nearly all analytical queries have a time range filter. The partition column should be a date (not a timestamp, which creates micro-partitions in Snowflake but the granularity may be too fine).

**Rule 2: Partition cardinality should be bounded and predictable.** A partition key of `customer_id` on a 100M-customer table creates 100M partitions — each holding a handful of rows. This is partition metadata explosion. The warehouse must enumerate partition candidates before pruning, and with 100M partitions the metadata scan overwhelms the actual data scan.

**Rule 3: Hot partitions signal the wrong partition key.** If 80% of queries filter on `status = 'ACTIVE'` and you partition by `status`, all active-record queries hit one partition. You have serialized your I/O into a single partition.

```
Query pattern                     → Partition key
"Give me orders from last week"   → order_date
"Give me all failed transactions" → Do NOT partition by status; use clustering
"Give me inventory for warehouse X" → Do NOT partition by warehouse; volume is even
"Give me CDRs from the last hour" → event_date + event_hour
"Give me lab results for this patient" → partition by date, CLUSTER by patient_key
```

### Cardinality Traps in Clustering

In Snowflake, a clustering key of `(event_date, customer_id)` on a table where `customer_id` has 100M unique values produces poor co-location: rows for the same date/customer combination are spread across many micro-partitions because the customer ID space is too large to cluster effectively. The Snowflake automatic clustering service handles this, but manual clustering keys should observe:

- First clustering column: moderate cardinality (dates, regions, product categories — hundreds to thousands of values)
- Second clustering column: moderate cardinality that is correlated with query filters (status codes, event types)
- Avoid high-cardinality surrogate keys as clustering columns unless the table is queried primarily by individual key lookups (account balance history)

In BigQuery, clustering is column-ordered, with the first column providing the strongest pruning. BigQuery supports up to 4 clustering columns. A common mistake is clustering on a column like `is_active BOOLEAN` — two distinct values means half the table is in each cluster bucket. No pruning occurs.

### Platform-Specific Behavior

| Concept | Snowflake | BigQuery | Redshift |
|---------|-----------|----------|----------|
| Partitioning mechanism | Micro-partitions (automatic, ~16MB compressed) | Explicit partition columns (date/integer/range) | Sort keys + distribution keys |
| Clustering mechanism | Explicit CLUSTER BY keys (automatic clustering service re-sorts) | Explicit CLUSTER BY columns (up to 4) | COMPOUND sort key (ordered) or INTERLEAVED sort key |
| Partition pruning trigger | Metadata scan on micro-partition min/max values | Explicit partition filter in WHERE clause | Zone map on sort key columns |
| Late-arriving data impact | New micro-partitions added; clustering service re-clusters over time | Late data lands in correct partition; no re-clustering needed | Data not in sort order degrades zone map effectiveness; VACUUM REINDEX needed |
| Maximum partitions | Not applicable (micro-partitions are automatic) | 4,000 partitions per table | Not applicable (sort key-based) |
| Optimal partition filter | BETWEEN on clustering key columns | `WHERE _PARTITIONDATE = '...'` or `WHERE date_col = '...'` | `WHERE sort_key_col = '...'` |
| Distribution key (parallel) | Not configurable; Snowflake handles internally | Not configurable; BQ handles internally | DISTKEY column; EVEN or ALL for small dims |

**Redshift Sort Key Specifics**: A compound sort key on `(order_date, customer_id)` means rows are sorted first by date, then by customer_id within a date. Zone maps eliminate blocks where the date range doesn't match. If you filter on `customer_id` alone (without `order_date`), the zone map is useless — the sort key prefix isn't used. For tables with two dominant filter patterns (by date AND by customer), an `INTERLEAVED` sort key distributes equally across all key columns but loses the prefix pruning advantage. This is a no-free-lunch tradeoff.

**BigQuery Partition Expiry**: BigQuery supports automatic partition expiry (`partition_expiration_days`). Setting this to 730 days automatically drops partitions older than 2 years. Combined with Long-Term Storage pricing (data not queried in 90 days gets 50% price reduction), this is a powerful cost control mechanism absent from Snowflake and Redshift.

**Snowflake Micro-Partition Pruning**: Snowflake's automatic clustering service re-sorts micro-partitions over time to maintain clustering quality. The `SYSTEM$CLUSTERING_INFORMATION` function reports the average depth (number of micro-partitions a given value spans) — lower is better. For a well-clustered table, depth < 5 is good. Depth > 20 means queries are scanning too many micro-partitions and re-clustering should be triggered or the clustering key should be reconsidered.

---

## 10. Incremental Patterns

### Append-Only

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

### Upsert (MERGE)

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

### Delete + Reinsert (Partition Replacement)

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

### Full Refresh

The entire target table is dropped and rebuilt from source. Correct only when the source itself is small enough that full reprocessing is tolerable (< 1M rows) or when the transformation logic changes and the output cannot be trusted without full recomputation.

**Never use for tables > 10M rows in production pipelines.** The operational risk (a failed full refresh leaves the target table empty until completion) and cost (full scan of source data every run) make it untenable at scale. Identify the specific partitions affected by a logic change and do a targeted partition replacement instead.

### CDC Modeling — Source Deletes in the Warehouse

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

---

## 11. Anti-Patterns with Autopsy

### Anti-Pattern 1: The God Fact Table

**What it is**: A single fact table that combines multiple business processes at different grains — e.g., a table that has one row per order line but also includes columns for the order header's shipping method, the customer's lifetime order count, the warehouse's current inventory for the ordered SKU, and the marketing campaign that drove the session.

**Why it gets built**: It starts with a legitimate convenience request — "can you just add the customer's total order count to the order line table so I don't have to join?" The data engineer adds the column. Over 18 months, 40 more "just add" requests create a 250-column table.

**How it fails at scale**:

1. **Grain ambiguity**: The `lifetime_order_count` is a customer-level attribute. When you `SUM(lifetime_order_count) GROUP BY product`, you sum the customer's lifetime count for every product they bought — wildly inflated numbers that look like revenue metrics.

2. **Stale denormalized columns**: `warehouse_inventory_qty` was correct when loaded. By the time analysts use it, the inventory has changed. There is no clear owner of this column's refresh SLA.

3. **Storage explosion**: A 1B-row order line fact table where 30 columns are denormalized customer attributes means the customer data is physically replicated 1B times. In columnar storage this is less severe (columns compress independently), but it is still wasteful and creates maintenance burden on every customer attribute change.

4. **SCD confusion**: If `customer_loyalty_tier` is denormalized into the God Fact and the customer's tier changes, what do you do? Update all 500 past rows? That corrupts the historical record. Leave it? Now the column means "current tier" for some rows and "tier at order time" for others — undocumented and inconsistent.

**The autopsy**: The query "revenue by customer segment" starts returning doubled numbers in Q3. Investigation reveals that customers who placed multiple orders have their `customer_segment` value updated by the nightly refresh, but the fact table was loaded with the segment value at order time — inconsistently. Some rows have the order-time segment; others were overwritten by subsequent refreshes. The fix requires rebuilding the entire fact table with a proper SCD Type 2 join to the customer dimension.

**The fix**: Never put dimension attributes into the fact table. Join at query time or build a pre-computed OBT as a separate layer built intentionally from properly governed dimensions.

### Anti-Pattern 2: Over-Normalized Analytics Models (The 12-Table Join Problem)

**What it is**: Applying OLTP normalization principles to analytics models. A query to answer "revenue by product category" requires joining through 12 tables because every attribute is in its own normalized table.

**How it fails**:

```sql
-- This query should be 2 lines. It takes 47 lines because normalization was applied incorrectly.
SELECT
    pc.category_name,
    SUM(oi.quantity * oi.unit_price) AS revenue
FROM order_items oi
JOIN orders o ON oi.order_id = o.id
JOIN customers c ON o.customer_id = c.id
JOIN customer_profiles cp ON c.id = cp.customer_id
JOIN product_variants pv ON oi.variant_id = pv.id
JOIN products p ON pv.product_id = p.id
JOIN product_subcategories psc ON p.subcategory_id = psc.id
JOIN product_categories pc ON psc.category_id = pc.id
JOIN product_category_hierarchies pch ON pc.id = pch.category_id
JOIN category_display_names cdn ON pch.display_id = cdn.id
JOIN ...
```

In a columnar warehouse, each join is a hash join requiring full scans of both sides if proper clustering is absent. 12 joins on large tables means 12 full scans. Query time: minutes to hours.

**The autopsy**: The analytics engineer built the warehouse schema by running `pg_dump` on the production PostgreSQL database and loading it into Snowflake. The OLTP schema had 3NF normalization appropriate for transactional consistency. In the analytics context, the 3NF schema creates a join explosion that makes simple reporting impossible.

**The fix**: Dimension tables in analytics must be intentionally denormalized. The `product_category` hierarchy should be a single row in `dim_product` with `category_name`, `subcategory_name`, `department_name` all present — even if this "violates" normalization. Analytics models are read-many, write-once. Normalization's purpose (update anomaly prevention) does not apply to the analytics layer.

### Anti-Pattern 3: Missing SCD Handling (Silent Data Corruption)

**What it is**: Dimensions that change over time are treated as Type 1 (overwrite) when the business actually needs Type 2 (history). The corruption is silent — queries return wrong answers but no error is thrown.

**Scenario**: The `dim_salesperson` table has a `region` column. Salespeople are reassigned between regions quarterly. The table is loaded with Type 1 (current values overwrite). An analyst queries "revenue by salesperson region for Q1." The query joins to `dim_salesperson` and gets the current region for each salesperson — not the Q1 region. A salesperson who was reassigned from East to West in April now appears to have generated all their Q1 revenue in West. The East region is undercounted; West is overcounted.

**Why it's silent**: The query executes successfully. The numbers sum correctly. The regional totals add up to total revenue. Nothing looks wrong unless you independently validate against a known-correct Q1 regional figure.

**The autopsy**: The corrupted regional report is included in a board presentation. The VP of East Sales disputes the numbers — their region appears far below Q1 actuals. Investigation reveals the SCD issue. Rebuilding requires either (a) sourcing historical region assignments from the CRM's change log (if it exists) or (b) accepting that Q1 historical data is irreparably incorrect.

**The fix**: Before modeling any dimension, answer: "If this attribute changes, do we ever need to know its historical value in the context of a past fact?" If yes, it requires Type 2. The engineering cost of Type 2 is real but recoverable. The cost of discovering missing SCD handling after 18 months of corrupted reports is not.

### Anti-Pattern 4: Sparse Fact Tables

**What it is**: A single fact table that attempts to represent multiple business processes with incompatible grains, resulting in a table where most columns are NULL for most rows.

**Example**: A `fact_financial_events` table with 150 columns that represents loan originations, payments, fee accruals, charge-offs, and rate changes — all as different row types. A loan origination row populates `origination_amount`, `origination_date`, `ltv_ratio`, `fico_score` but has NULLs in `payment_amount`, `accrual_type`, `charge_off_reason`. A payment row populates `payment_amount` but has NULLs in all origination columns.

**How it fails**:

1. **Storage waste**: In columnar storage, NULL columns are compressed very efficiently — but not to zero. At 1B rows with 90% NULL density, you are paying for 100M non-NULL values spread across 150 columns, with encoding overhead for 900M NULLs.

2. **Query errors**: `SUM(payment_amount)` on the table returns the correct sum — but `AVG(payment_amount)` excludes NULLs and returns the correct average only if analysts remember that most rows are not payments. New analysts will write `SELECT AVG(payment_amount) FROM fact_financial_events` and get a result that silently excludes 85% of rows.

3. **Impossible constraints**: You cannot enforce `NOT NULL` on `payment_amount` because origination rows need it to be NULL. You lose the ability to catch data quality issues via database constraints.

**The fix**: One fact table per business process. `fact_loan_origination`, `fact_payment`, `fact_fee_accrual`, `fact_charge_off` — each with the columns appropriate to their grain and process. A unified `fact_financial_events` OBT is acceptable as a final reporting layer built from the properly structured per-process facts, but only if built intentionally with documented NULL semantics.

### Anti-Pattern 5: Premature Aggregation (Losing Grain Before You Need It)

**What it is**: Aggregating data to a summary grain during the ELT process before storing it in the warehouse, discarding the raw grain.

**Scenario**: The data team builds a daily pipeline that loads `total_orders` and `total_revenue` by day and product category into a summary table. Three months later, a product manager asks: "How many distinct customers bought in each category last month?" This question cannot be answered from the summary table — distinct customer count requires the individual order lines to determine uniqueness. The raw order lines were never loaded.

**A more insidious form**: Loading inventory positions as the daily opening balance only, discarding the individual movement records. Six months later: "Why did inventory for SKU XYZ drop by 500 units on March 14th?" No movement detail exists to answer this.

**The fix**: Always store the finest available grain in the warehouse. Pre-aggregated tables are supplemental query acceleration layers — they are never a substitute for the atomic fact. The storage cost of raw grain data in columnar warehouses is dramatically lower than in row-oriented systems (2–5x compression is typical). The cost of not having granular data when a question arrives is unbounded.

---

---

## 12. Business Logic: DE Layer vs Reporting Layer

> The interview question is never "can the BI tool compute this?" Both layers can technically compute almost anything. The real question: **who owns the answer, who else needs it, what breaks if it's wrong, and how often does the definition change?**

---

### The Core Mental Model

Every piece of business logic lives on a spectrum:

```
DE Layer (dbt / Spark / Warehouse)          BI Layer (Tableau / Power BI / Looker DAX)
─────────────────────────────────────────────────────────────────────────────────────────
Shared, governed, auditable, versioned  ←→  Local, flexible, exploratory, session-specific
Runs once at load time                  ←→  Runs at every render / interaction
Tool-agnostic (SQL)                     ←→  Tool-specific (DAX, LookML, Tableau calc fields)
Tested, lineage tracked                 ←→  Hidden inside .pbix or .twb binary files
```

**Neither layer is universally correct.** The failure mode is applying the wrong layer to a given problem — not the layer itself.

---

### Decision Criteria

**Push logic DOWN into DE layer when:**

| Signal | Why it forces DE layer |
|--------|----------------------|
| More than one team or tool needs the same metric | Logic in one BI tool is invisible to all others. Two reimplementations → two definitions → executive confusion |
| Requires joining 3+ tables across domains | Live multi-source joins in a BI tool collapse at scale — Tableau doing a 500M-row join produces Cartesian product risk and query timeouts |
| Requires point-in-time historical accuracy | SCD Type 2 history doesn't exist in a BI tool's semantic model — it reflects current state unless the warehouse provides the history |
| Deduplication required | A BI calculated field operates on rows already in the dataset — if rows are duplicated at the source, the BI tool has no way to know which row is canonical |
| Compliance / regulatory requirement | A DAX measure computing revenue has no audit trail. A dbt model has git history, lineage, test assertions, and a PR review |
| Pre-aggregation over billions of rows | `COUNT(DISTINCT user_id)` over 50B events is not a live BI query — it is a nightly pipeline job |
| ML feature input | Train/test split enforcement and temporal leakage prevention cannot be expressed in a calculated field |
| Shared definition used by multiple teams | One dbt PR changes one file and the change propagates everywhere. One Tableau calculated field change requires opening 50 workbooks |

**Push logic UP into BI layer when:**

| Signal | Why BI layer is correct |
|--------|------------------------|
| Anchored to today's date (YTD, MTD, rolling-N from NOW) | Pre-materializing these would require a daily pipeline run to produce a number that expires in 24 hours. DAX `TOTALYTD` and Tableau `TODAY()` are purpose-built for this |
| User-controlled scenario / what-if | Power BI What-If Parameters with `GENERATESERIES + SELECTEDVALUE` create real-time sliders. Materializing scenarios in the warehouse requires a pipeline run per scenario |
| Exploratory / single-team / not yet stable | If a metric hasn't survived one quarter and isn't shared, a dbt model is premature engineering. Promote it to DE layer when it earns its place |
| Audience-specific display formatting | Currency symbols, date locales, unit conversions (km vs. miles) are presentation concerns. Warehouse stores canonical values; BI applies the display |
| Visualization-specific aggregation | A KPI card needs "total." A bar chart needs "by region." The warehouse provides the fact grain; BI aggregates to whatever the chart requires |

---

### Case 1: Must Be in DE Layer — Multi-Source Customer Health Score

**Context**: A SaaS company computes customer health score from four source systems: Segment (product engagement events), Zendesk (support ticket volume and severity), Salesforce (contract value and renewal date), Stripe (billing payment history).

**Wrong approach** — logic in Tableau:
- Each dashboard load re-executes a four-way join across systems
- If two analysts define the join conditions slightly differently (different date filters, different NULL handling for missing Zendesk accounts), two dashboards show different health scores for the same customer
- Tableau's Live Connection has no join-key safety net — a Cartesian product on a 500M-event engagement table silently inflates the score

**Correct approach** — dbt Gold model:
```sql
-- models/marts/dim_customer_health.sql
WITH engagement AS (
    SELECT
        account_id,
        COUNT(DISTINCT user_id) AS active_users_l30d,
        COUNT(CASE WHEN event_name = 'core_action' THEN 1 END) AS core_actions_l30d
    FROM {{ ref('fct_events') }}
    WHERE event_date >= CURRENT_DATE - 30
    GROUP BY account_id
),
support AS (
    SELECT
        account_id,
        COUNT(*) AS open_ticket_count,
        MAX(CASE WHEN severity = 'P1' THEN 1 ELSE 0 END) AS has_open_p1
    FROM {{ ref('fct_support_tickets') }}
    WHERE status = 'open'
    GROUP BY account_id
),
billing AS (
    SELECT
        account_id,
        MAX(days_past_due) AS max_days_past_due,
        SUM(CASE WHEN payment_status = 'failed' THEN 1 ELSE 0 END) AS failed_payments_l90d
    FROM {{ ref('fct_payments') }}
    WHERE payment_date >= CURRENT_DATE - 90
    GROUP BY account_id
)
SELECT
    a.account_id,
    a.contract_value,
    a.renewal_date,
    COALESCE(e.active_users_l30d, 0) AS active_users_l30d,
    COALESCE(e.core_actions_l30d, 0) AS core_actions_l30d,
    COALESCE(s.open_ticket_count, 0) AS open_ticket_count,
    COALESCE(s.has_open_p1, 0) AS has_open_p1,
    COALESCE(b.max_days_past_due, 0) AS max_days_past_due,
    -- Health score logic: one governed definition, consumed by product, CSM, and ML teams
    CASE
        WHEN COALESCE(b.max_days_past_due, 0) > 30 OR COALESCE(s.has_open_p1, 0) = 1 THEN 'RED'
        WHEN COALESCE(e.active_users_l30d, 0) = 0 THEN 'RED'
        WHEN COALESCE(e.core_actions_l30d, 0) < 10 OR COALESCE(s.open_ticket_count, 0) > 3 THEN 'YELLOW'
        ELSE 'GREEN'
    END AS health_status
FROM {{ ref('dim_accounts') }} a
LEFT JOIN engagement e ON a.account_id = e.account_id
LEFT JOIN support s ON a.account_id = s.account_id
LEFT JOIN billing b ON a.account_id = b.account_id
```

The BI tool reads one row per customer from `dim_customer_health`. The four-way join runs once per pipeline cycle. Every downstream consumer — Tableau dashboards, Power BI, the ML churn model, the CSM platform — reads the same number.

**How this breaks without DE layer**: Marketing shows health = GREEN for Account 7890 (their Zendesk query had a date filter). CS shows health = RED for the same account (their query included P2 tickets). The CSM spends 30 minutes on a call apologizing for a non-existent problem. The customer loses confidence. This is documented as a real organizational failure pattern at companies with ungoverned metric definitions.

---

### Case 2: Must Be in DE Layer — Sessionization from Raw Clickstream

**Context**: 200M events/day. Product manager wants funnel conversion rate: `checkout_start → payment_complete`, restricted to sessions where the user entered via a paid marketing campaign.

**Why BI layer fails**:
- Session assignment requires `LAG(event_timestamp) OVER (PARTITION BY anonymous_id ORDER BY event_timestamp)` and a 30-minute inactivity threshold. Tableau's `WINDOW_` functions operate post-aggregation — they cannot be used to assign session IDs to individual rows.
- Power BI's `EARLIER()` function for row context is architecturally not capable of the sequential event-gap logic required for sessionization.
- Even if a BI tool could approximate it, running this over 200M rows per query would take minutes and saturate the warehouse's compute allocation.

**Correct approach** — Spark/dbt ELT:
```sql
-- models/intermediate/int_sessions.sql
WITH event_gaps AS (
    SELECT
        event_id, anonymous_id, tenant_id,
        event_name, received_at, utm_source,
        LAG(received_at) OVER (
            PARTITION BY anonymous_id, tenant_id
            ORDER BY received_at
        ) AS prior_event_at
    FROM {{ ref('stg_events') }}
),
session_starts AS (
    SELECT *,
        CASE
            WHEN prior_event_at IS NULL THEN 1
            WHEN DATEDIFF('minute', prior_event_at, received_at) > 30 THEN 1
            ELSE 0
        END AS is_session_start
    FROM event_gaps
),
sessions AS (
    SELECT *,
        SUM(is_session_start) OVER (
            PARTITION BY anonymous_id, tenant_id
            ORDER BY received_at
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) AS session_seq
    FROM session_starts
)
SELECT
    anonymous_id || '-' || tenant_id || '-' || CAST(session_seq AS VARCHAR) AS session_id,
    anonymous_id, tenant_id,
    MIN(received_at) AS session_start_at,
    MAX(received_at) AS session_end_at,
    -- Attribute the session to the first UTM source seen in the session
    MIN(CASE WHEN utm_source IS NOT NULL THEN utm_source END) AS utm_source,
    MAX(CASE WHEN event_name = 'checkout_start' THEN 1 ELSE 0 END) AS reached_checkout,
    MAX(CASE WHEN event_name = 'payment_complete' THEN 1 ELSE 0 END) AS converted
FROM sessions
GROUP BY anonymous_id, tenant_id, session_seq
```

The BI tool then runs:
```sql
SELECT
    utm_source,
    COUNT(*) AS sessions,
    SUM(converted) AS conversions,
    SUM(converted)::FLOAT / COUNT(*) AS conversion_rate
FROM dim_session
WHERE session_start_at::DATE >= CURRENT_DATE - 30
GROUP BY utm_source
```

**Critically**: the 30-minute session timeout definition is now in one place. When the product team debates whether it should be 20 or 30 minutes, there is one PR to change and one pipeline run to validate — not 15 BI workbooks to audit.

---

### Case 3: Must Be in DE Layer — SCD Type 2 and Point-in-Time Joins

**Context**: Sales commission calculation. Salespeople move between regions. Commission rate varies by region. The question: "What commission does salesperson Alice owe for her January sales?"

Alice was in the East region in January (10% commission) but moved to the West region in February (8% commission). If `dim_salesperson` is loaded with Type 1 (current values), Alice's January sales appear in West at 8% — underpaying her by 2 points on every January order.

**BI tool cannot fix this** because the BI tool only sees current region. It has no access to the January region unless the warehouse provides that history.

**Correct approach** — dbt snapshot:
```yaml
# snapshots/snap_salesperson.yml
snapshots:
  - name: snap_salesperson
    config:
      target_schema: snapshots
      unique_key: salesperson_id
      strategy: check
      check_cols: ['region', 'commission_tier', 'manager_id']
      # dbt generates dbt_valid_from and dbt_valid_to automatically
```

Then in the commission fact model:
```sql
-- models/marts/fct_sales_commission.sql
SELECT
    o.order_id,
    o.order_date,
    o.revenue,
    sp.salesperson_id,
    sp.region,              -- region AS OF order_date (historical, correct)
    sp.commission_tier,
    cr.commission_rate,
    o.revenue * cr.commission_rate AS commission_owed
FROM {{ ref('fct_orders') }} o
JOIN {{ ref('snap_salesperson') }} sp
    ON o.salesperson_id = sp.salesperson_id
    AND o.order_date >= sp.dbt_valid_from
    AND o.order_date < COALESCE(sp.dbt_valid_to, '9999-12-31')
JOIN {{ ref('dim_commission_rates') }} cr
    ON sp.region = cr.region
    AND sp.commission_tier = cr.tier
```

The BI tool reads `fct_sales_commission` with `commission_owed` pre-computed at the correct historical rate. No BI-layer logic needed.

**Scale implication of getting this wrong**: At $500M revenue with 200 salespeople, a 2% commission miscalculation across one quarter is $2.5M in incorrect payments. The error is silent — summaries look correct because the numbers sum to total revenue. Only per-salesperson comparison against payroll records exposes it.

---

### Case 4: Must Be in DE Layer — GDPR/SOX Compliance Logic

**GDPR data masking — why BI layer is structurally wrong**:

A Tableau calculated field `IF [role] = "analyst" THEN "REDACTED" ELSE [email] END` does **not** mask data. The Tableau query still fetches the unmasked email from the warehouse and then applies a display filter in the visualization layer. Anyone with warehouse credentials — or who intercepts the JDBC connection — sees the plaintext PII.

**Correct approach** — Snowflake Dynamic Data Masking:
```sql
CREATE OR REPLACE MASKING POLICY email_mask AS (val STRING) RETURNS STRING ->
    CASE
        WHEN CURRENT_ROLE() IN ('DATA_ENGINEER', 'COMPLIANCE_ADMIN') THEN val
        WHEN CURRENT_ROLE() = 'ANALYST' THEN SHA2(val)      -- pseudonymized, not plaintext
        ELSE '***REDACTED***'
    END;

ALTER TABLE dim_customer MODIFY COLUMN email_address
    SET MASKING POLICY email_mask;
```

Now the masking is enforced at the storage layer. No BI tool, no Python notebook, no SQL client sees plaintext PII unless the role explicitly permits it. The Tableau calculated field approach is a compliance liability, not a solution.

**SOX revenue recognition — the audit trail argument**:

Under ASC 606, multi-element software arrangements require allocating transaction price across performance obligations (license, support, professional services) using relative standalone selling prices. This allocation involves:
1. Identifying performance obligations per contract
2. Estimating standalone selling price for each obligation
3. Allocating total contract value proportionally
4. Recognizing each obligation's revenue when (or as) the obligation is satisfied

A DAX measure doing this allocation has no git commit history, no test coverage, no documented lineage from the source contract record to the recognized revenue figure. An auditor asking "show me how you computed Q3 license revenue for contract #12345" cannot be answered from a `.pbix` file.

A dbt model doing the same allocation:
- Has a git commit per change with author, timestamp, and PR description
- Has `dbt test` assertions: total allocated revenue = contract value (within rounding tolerance)
- Has documented lineage: `source contract` → `stg_contracts` → `int_performance_obligations` → `fct_recognized_revenue`
- Has a deterministic run log: re-running the model on the same data produces byte-identical output

The SOX auditor signs off on the dbt lineage DAG. There is no equivalent artifact from a BI layer calculation.

---

### Case 5: Must Be in DE Layer — Shared Metric: "Active User" Definition

**The fragmentation failure**: At a growth-stage SaaS company, five teams each define "Monthly Active User" in their own BI workbook:

| Team | Definition | Tool |
|------|-----------|------|
| Product | Triggered `core_action` event in last 28 days, excluding internal users | Tableau calculated field |
| Marketing | Logged in at least once in the calendar month | Looker measure |
| Growth | Completed onboarding AND triggered any event in last 30 days | Power BI DAX measure |
| Finance | Any account with at least one active seat on any day in the month | Spreadsheet formula |
| Customer Success | Has an assigned CSM AND has been active in the last 14 days | Salesforce report |

Each definition is defensible in isolation. Combined, they generate five different MAU numbers presented to the CEO in the same weekly review. The CEO cannot make a resource allocation decision because the growth team shows 12% MAU growth while the marketing team shows 3% growth — for the same month.

**Correct approach** — one dbt model, one PR to change the definition:
```sql
-- models/marts/dim_user_activity.sql
-- Governed definition: active = triggered a 'core_action' event in last 28 days,
-- is not an internal user (email not @company.com),
-- and account is not on a free trial.
SELECT
    u.user_id,
    u.account_id,
    u.email,
    u.account_type,
    MAX(e.event_date) AS last_active_date,
    CASE
        WHEN MAX(e.event_date) >= CURRENT_DATE - 27
             AND u.email NOT LIKE '%@ourcompany.com'
             AND u.account_type != 'TRIAL'
        THEN TRUE
        ELSE FALSE
    END AS is_active_user
FROM {{ ref('dim_users') }} u
LEFT JOIN {{ ref('fct_events') }} e
    ON u.user_id = e.user_id
    AND e.event_name = 'core_action'
    AND e.event_date >= CURRENT_DATE - 27
GROUP BY u.user_id, u.account_id, u.email, u.account_type
```

When the growth team argues that trial users should be included in MAU for their funnel analysis, they open a PR. The PR triggers a discussion about whether the official company definition should change — not whether one team's dashboard should show a different number. When the PR merges, all five teams' dashboards update simultaneously on the next refresh. No team is maintaining a divergent definition in a BI workbook.

---

### Case 6: Belongs in BI Layer — Relative Time Calculations

**Why YTD belongs in DAX/Tableau, not the warehouse**:

If you materialize "YTD revenue as of today" in a dbt model, you must run the pipeline every day to produce a number that expires at midnight. Any report opened before the pipeline finishes shows yesterday's YTD. The materialized YTD for a date in 2023 is now permanently frozen — if a correction is applied to a January transaction in November, the frozen YTD is wrong but there is no automatic mechanism to re-trigger its recalculation.

DAX's time-intelligence pattern:
```dax
YTD Revenue =
CALCULATE(
    SUM(fct_orders[revenue]),
    DATESYTD(dim_date[date])
)
```

This measure recalculates at render time using the current filter context. It is always correct relative to today because it executes at query time, not at load time. The warehouse provides the historical fact grain; the BI tool applies the temporal window.

**The boundary**: Rolling historical windows ("rolling 7-day MAU as of each date, for the last 2 years") belong in the DE layer. These require computing a correct historical series — the definition of "last 7 days" changes at each historical point, and materializing the series once is far cheaper than computing it live for every chart render. YTD/MTD anchored to today belong in the BI layer. Historical rolling windows belong in the DE layer.

---

### Case 7: The Genuinely Grey Area — Conversion Rate

**Symptom of the problem**: `conversion_rate = orders / sessions`. Two numbers divided. Looks simple. You put it in a Tableau calculated field in 15 minutes.

**Why it belongs in the DE layer despite its apparent simplicity**:

Within one quarter, different teams define it differently without realizing it:

| Question | Implicit decision | Each team answers differently |
|----------|------------------|-------------------------------|
| Which sessions? | All sessions, or only paid-acquisition sessions? | Marketing: paid only. Product: all. |
| Which orders? | Completed only, or including pending? | Finance: completed only. Growth: all. |
| Date attribution | Session date, or order date? | Marketing: session date. Finance: order date. |
| Bot filtering | Exclude bot traffic? | Engineering: yes. Everyone else: forgot. |
| Mobile vs desktop | Separate rates or blended? | Product: blended. Channel analytics: separate. |

When the CMO sees 3.2% conversion in the marketing dashboard and the CPO sees 2.8% in the product dashboard, the 0.4-point difference is not analytical noise. It is the aggregated effect of five implicit decisions made independently. At $50M ARR, it is the difference between celebrating a campaign as successful and investigating a product funnel issue.

**The rule**: the arithmetic complexity is irrelevant. The governing question is: **does the metric have edge cases that require a decision, and is more than one team depending on the answer?** If yes, it belongs in a dbt model with those decisions explicitly encoded and documented:

```sql
-- models/marts/fct_conversion.sql
-- Definition: sessions → completed orders. Excludes bots. Attributes to session date.
-- Change history: 2024-03-01 — excluded trial accounts per Finance request (PR #412)
SELECT
    DATE_TRUNC('day', s.session_start_at) AS session_date,
    s.channel,
    s.device_type,
    COUNT(DISTINCT s.session_id) AS sessions,
    COUNT(DISTINCT o.order_id) AS completed_orders,
    COUNT(DISTINCT o.order_id)::FLOAT / NULLIF(COUNT(DISTINCT s.session_id), 0) AS conversion_rate
FROM {{ ref('dim_session') }} s
LEFT JOIN {{ ref('fct_orders') }} o
    ON s.session_id = o.attributed_session_id
    AND o.order_status = 'COMPLETED'
WHERE s.is_bot = FALSE
  AND s.account_type != 'TRIAL'   -- excluded per Finance (PR #412)
GROUP BY 1, 2, 3
```

The PR comment on line 3 is the audit trail. The BI tool reads `fct_conversion` and aggregates to whatever granularity the chart needs. The definition is in one place.

---

### Case 8: Belongs in BI Layer — What-If Scenario Analysis

**Context**: A CFO wants to model three revenue scenarios for the board: base case, bull case (15% above base), bear case (20% below base). The "base" is the historical actuals from the warehouse.

**Why this belongs in Power BI, not the warehouse**:
- Scenarios are session-specific, user-driven parameters. They are not facts.
- Materializing three scenario versions in the warehouse requires three pipeline runs per scenario revision. The CFO will revise the assumptions six times before the board meeting.
- The scenarios are not the company's official record — they are exploratory projections used internally.

```dax
// Power BI What-If Parameter
GrowthMultiplier = GENERATESERIES(-0.30, 0.30, 0.05)
GrowthValue = SELECTEDVALUE(GrowthMultiplier[GrowthMultiplier], 0)

// Measure using the slider
Projected Revenue =
CALCULATE(
    SUM(fct_orders[revenue]),
    DATESYTD(dim_date[date])
) * (1 + [GrowthValue])
```

The slider moves from -30% to +30%. All calculations update in real time. The warehouse never stores any projected values — it holds only historical actuals. The board presentation can show multiple scenarios without triggering a single pipeline run.

---

### Decision Matrix

| Logic Type | DE Layer | BI Layer | Why |
|-----------|----------|----------|-----|
| Multi-source join (CRM + billing + events) | ✓ | | Live join in BI tool collapses at scale, produces inconsistent results across workbooks |
| Sessionization from raw events | ✓ | | Requires sequential window functions over billions of rows; BI tools cannot express this |
| SCD Type 2 / point-in-time attribute | ✓ | | BI tools reflect current state; history must come from the warehouse |
| GDPR/PII masking | ✓ | | BI-layer masking is a display filter; data is still unmasked in the warehouse |
| SOX-auditable revenue recognition | ✓ | | DAX/calculated fields have no audit trail, no lineage, no version history |
| ML feature engineering | ✓ | | Train/test split enforcement, temporal leakage prevention impossible in BI layer |
| Shared metric definition (MAU, conversion rate) | ✓ | | More than one team → each reimplements differently → metric divergence |
| Pre-aggregation over billions of rows | ✓ | | `COUNT(DISTINCT user_id)` over 50B rows is not a live BI query |
| Event stream deduplication | ✓ | | BI tool has no way to identify which duplicate is canonical |
| YTD / MTD / rolling-N from TODAY() | | ✓ | Expires every day; DAX/Tableau time-intelligence functions are purpose-built |
| What-if / scenario modeling | | ✓ | Session-specific, user-driven; pipeline per scenario is operationally absurd |
| Exploratory, single-team, unstable metric | | ✓ | Promote to DE layer when it earns its place after one quarter of stability |
| Audience-specific display formatting | | ✓ | Presentation layer concern; canonical values stored in warehouse |
| Conditional formatting / color thresholds | | ✓ | Purely visual; has no place in a fact table |

---

### The Medallion Architecture Formalization

The Databricks Bronze/Silver/Gold model makes the boundary explicit:

```
Bronze (Raw)   → Exact copy of source. No logic. Ingestion metadata only.
Silver (Clean) → Structural cleanup: dedup, type cast, null handling, schema normalization.
                 No domain business logic.
Gold (Mart)    → ALL business logic lives here: joins, metric definitions, KPIs,
                 compliance transformations, shared definitions.
                 BI tools connect ONLY to Gold.
```

**The diagnostic test**: If you find a SQL join inside a BI tool's data model, that join belongs in Gold. If you find a business definition inside a BI calculated field that is used by more than one consumer, that definition belongs in Gold.

The dbt Semantic Layer (MetricFlow) extends this further: metrics are defined as YAML alongside models and exposed via a query API consumed by Tableau, Power BI, Looker, Python notebooks, and AI agents from a single authoritative definition. When `conversion_rate` is a MetricFlow metric, it is guaranteed to return the same number regardless of which tool queries it. The organizational consequence: the executive review never again devolves into a debate about whose number is right.

---

### Real-World Failure Modes Summary

| Getting it wrong | What breaks | How badly |
|-----------------|-------------|-----------|
| Sessionization in BI tool | 15-minute query renders; wrong session counts when session definition differs by analyst | Data trust collapse within 2 quarters |
| SCD Type 2 skipped; commission calculation in warehouse uses Type 1 | Historical commission reports show wrong territories | Legal liability for underpaid commissions |
| GDPR masking in BI calculated field | Regulation violation; PII still readable via direct warehouse query | Regulatory fine + reputational damage |
| "Simple" conversion rate defined in 50 Tableau workbooks | 0.4-point discrepancy in executive review; 30% of analytics time spent on reconciliation | Metric credibility lost; gut instinct overrides dashboards |
| YTD/MTD materialized in warehouse | Number expires every 24 hours; stale if pipeline delayed; correction to historical data doesn't propagate | Stale KPI cards; stakeholder distrust |
| Customer health score joined in BI tool | Different join conditions in different dashboards produce different scores for same customer | CSM team acts on wrong signals; customer trust damaged |

*End of Document — Data Modeling Masterclass*
