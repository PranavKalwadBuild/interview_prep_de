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
