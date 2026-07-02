<!-- data-modelling-patterns: Modern Stack — Medallion Architecture, OBT, Data Vault 2.0 -->

# Modern Stack Patterns

---

## 13. Medallion Architecture

**What it solves:** Organizes a data lakehouse into three progressive layers of data quality — Bronze (raw), Silver (cleaned), Gold (business-ready). Originally from Databricks; now widely adopted.

> **Keywords to spot:** "bronze silver gold", "medallion", "raw layer", "curated layer", "lakehouse", "progressive refinement", "Delta Lake"

**Business Context:**
- **Any industry:** Separates concerns: ingest (Bronze), clean/conform (Silver), model for business use (Gold)
- **Fintech:** Bronze = raw transactions from payment processor APIs; Silver = deduped, typed, validated; Gold = fact_transactions star schema
- **E-commerce:** Bronze = raw Shopify webhook JSON; Silver = structured orders with FK integrity; Gold = star schema for reporting

**Layer overview:**

```
Source Systems
      │
      ▼
┌─────────────────────────────────┐
│         BRONZE (raw)            │  ← Exact copy of source, append-only
│  • No transformations           │    Land it fast, land it all
│  • Schema-on-read friendly      │
└─────────────────────────────────┘
      │
      ▼
┌─────────────────────────────────┐
│         SILVER (cleaned)        │  ← Conformed, deduplicated, typed
│  • Correct data types           │    One row per entity per version
│  • Removed duplicates           │
│  • Null handling applied        │
│  • Referential integrity        │
└─────────────────────────────────┘
      │
      ▼
┌─────────────────────────────────┐
│          GOLD (business)        │  ← Modelled for consumption
│  • Star schema / OBT / metrics  │    Aggregated, named for business
│  • Pre-joined, pre-aggregated   │
│  • What BI tools query          │
└─────────────────────────────────┘
```

**DDL for each layer — order processing example:**

```sql
-- BRONZE: raw ingest, keep everything
create table bronze.orders_raw (
    _raw_payload        variant,            -- raw JSON from API (Snowflake VARIANT)
    _source_system      varchar(100),
    _ingested_at        timestamp default current_timestamp,
    _file_name          varchar(500),
    _batch_id           varchar(100)
    -- no PK, no constraints, append-only
);

-- SILVER: cleaned, typed, deduplicated
create table silver.orders (
    order_id            varchar(50)   not null,
    customer_id         varchar(50)   not null,
    order_date          date          not null,
    status              varchar(30),
    total_amount        decimal(12,2),
    currency_code       char(3),
    is_deleted          boolean       default false,
    _source_system      varchar(100),
    _created_at         timestamp,
    _updated_at         timestamp,
    _silver_loaded_at   timestamp     default current_timestamp,
    primary key (order_id)
);

-- SILVER: order line items
create table silver.order_items (
    order_id            varchar(50)   not null,
    line_number         int           not null,
    product_id          varchar(50)   not null,
    quantity            int,
    unit_price          decimal(10,2),
    discount_pct        decimal(5,4),
    _silver_loaded_at   timestamp     default current_timestamp,
    primary key (order_id, line_number)
);

-- GOLD: star schema fact table
create table gold.fact_order_lines (
    order_line_sk       bigint primary key,
    order_date_sk       int     references gold.dim_date(date_sk),
    customer_sk         bigint  references gold.dim_customer(customer_sk),
    product_sk          bigint  references gold.dim_product(product_sk),
    order_id            varchar(50),       -- degenerate dimension
    quantity            int,
    unit_price          decimal(10,2),
    discount_amount     decimal(10,2),
    line_revenue        decimal(12,2),
    _gold_loaded_at     timestamp
);
```

**Gotchas:**
- Bronze is append-only. Never delete or modify bronze data — it is your recovery layer. If you have a bug in Silver, you reprocess from Bronze.
- Silver is the hardest layer. Deduplication, schema evolution, late-arriving records, and referential integrity all need to be handled here.
- Gold is not always a star schema. For small teams or simple use cases, Gold can be a set of wide summary tables or even OBT (see Section 14).
- The "medallion" naming is Databricks/Delta Lake specific. In Snowflake shops, you may hear "raw / staging / curated" or "L1 / L2 / L3." Same concept, different names.

---

## 14. One Big Table (OBT)

**What it solves:** A single denormalized table that joins all relevant dimensions into one wide table. Optimized for self-service analytics and BI tools that don't perform well with multi-table star schemas.


> **Keywords to spot:** "one wide table", "self-service analytics", "flattened", "pre-joined", "single table for dashboard", "no joins needed", "OBT"

**Business Context:**
- **SaaS:** One row per user per day with all account, plan, and activity attributes pre-joined — analysts never need to know the underlying schema
- **E-commerce:** One row per order line item with customer, product, store, and campaign attributes flattened in — Tableau/Looker query performance is fast
- **Fintech:** One row per transaction with full account and customer context — risk analysts can slice any way without learning the data model

**DDL — OBT for e-commerce order analysis:**

```sql
create table gold.obt_order_lines (
    -- Identifiers
    order_line_sk           bigint primary key,
    order_id                varchar(50),
    order_date              date,

    -- Order-level attributes
    order_status            varchar(30),
    order_channel           varchar(50),    -- 'web', 'mobile', 'in-store'
    is_gift                 boolean,

    -- Customer attributes
    customer_id             varchar(50),
    customer_name           varchar(200),
    customer_email          varchar(255),
    customer_city           varchar(100),
    customer_country        varchar(100),
    customer_segment        varchar(50),
    customer_signup_date    date,
    customer_lifetime_orders int,           -- pre-computed

    -- Product attributes
    product_id              varchar(50),
    product_name            varchar(200),
    product_category        varchar(100),
    product_subcategory     varchar(100),
    product_brand           varchar(100),

    -- Line item measures
    quantity                int,
    unit_price              decimal(10,2),
    discount_pct            decimal(5,4),
    line_revenue            decimal(12,2),
    line_cost               decimal(12,2),
    line_profit             decimal(12,2),

    -- Date attributes (from dim_date, pre-joined)
    order_day_of_week       varchar(10),
    order_month_num         int,
    order_quarter           int,
    order_year              int,
    order_fiscal_period     int,
    is_weekend_order        boolean,

    -- Metadata
    _gold_loaded_at         timestamp
);
```

**When OBT makes sense vs when it doesn't:**

| Situation | OBT | Star Schema |
|---|---|---|
| Small team, self-service analytics | Better | Overkill |
| BI tool struggles with multi-table joins | Better | Problematic |
| Multiple subject areas sharing dimensions | Problematic | Better |
| Need to track SCD history | Hard | Natural |
| Very wide tables (100+ columns) | Storage-heavy | Efficient |
| Data freshness is critical | Expensive to recompute | Incremental is easier |
| Advanced users who can write SQL | Either | Better for reuse |

**Gotchas:**
- OBT grain must still be precise and consistent. Don't add both line-level and order-level measures to the same OBT — you'll get fan-out.
- OBT is not a replacement for a Silver layer. It lives in Gold, built from well-modelled Silver tables.
- OBT updates are expensive. When a customer changes their segment, every row for that customer in the OBT needs to be recomputed. With a star schema, you update one dimension row.
- OBT columns often exceed 50-100+. Without clear documentation, this becomes unmaintainable. Column naming convention is critical.
- Popular in modern stacks (dbt + Snowflake/BigQuery) because storage is cheap and compute can handle wide scans efficiently.

---

## 15. Data Vault 2.0

**What it solves:** A modelling methodology built for auditability, scalability, and handling multiple source systems with conflicting data. Separates business keys (Hubs), relationships (Links), and descriptive attributes (Satellites).

> **Keywords to spot:** "data vault", "hub", "link", "satellite", "auditable", "multiple source systems", "insert-only", "hash key", "business key integration"

**Business Context:**
- **Large enterprise:** Multiple ERP systems (SAP + Oracle) feeding one warehouse — each has its own customer ID format; Data Vault integrates without forcing a single master
- **Fintech:** Regulatory requirement for full audit trail — every record insert is immutable, changes tracked via satellites
- **Healthcare:** Multiple hospital systems with conflicting patient records — Data Vault keeps source fidelity while linking records

**The three entity types:**

```
        Hub_Customer
             │
          Link_Order
         /          \
Hub_Customer      Hub_Product
    │                  │
Sat_Customer    Sat_Product
  (details)      (details)
```

### Hub — one per business key

A Hub contains a business key and metadata. No descriptive attributes. One Hub per business concept.

```sql
create table hub_customer (
    customer_hk         char(32)    primary key,   -- MD5 hash of business key
    customer_bk         varchar(50) not null,      -- business key (natural key)
    load_date           timestamp   not null,
    record_source       varchar(200) not null       -- which system provided this
    -- No attributes! Attributes go in Satellites
);
```

### Link — represents a relationship between Hubs

Links record that two (or more) business entities were related. Insert-only — relationships are never updated.

```sql
create table link_order (
    order_hk            char(32)    primary key,   -- hash of all component business keys
    customer_hk         char(32)    references hub_customer(customer_hk),
    product_hk          char(32)    references hub_product(product_hk),
    order_bk            varchar(50) not null,       -- order natural key
    load_date           timestamp   not null,
    record_source       varchar(200) not null
);

-- For a three-way link (order + customer + store)
create table link_order_placement (
    order_placement_hk  char(32)    primary key,
    order_hk            char(32)    references hub_order(order_hk),
    customer_hk         char(32)    references hub_customer(customer_hk),
    store_hk            char(32)    references hub_store(store_hk),
    load_date           timestamp   not null,
    record_source       varchar(200) not null
);
```

### Satellite — descriptive attributes with change tracking

Satellites store descriptive attributes for a Hub or Link. New rows are inserted when attributes change (never updated). `hash_diff` enables efficient change detection.

```sql
-- Satellite on Hub_Customer
create table sat_customer_details (
    customer_hk         char(32)    not null references hub_customer(customer_hk),
    load_date           timestamp   not null,
    load_end_date       timestamp,              -- NULL = current row
    record_source       varchar(200) not null,
    hash_diff           char(32)    not null,   -- MD5 of all attribute values
    -- Descriptive attributes
    full_name           varchar(200),
    email               varchar(255),
    city                varchar(100),
    country             varchar(100),
    segment             varchar(50),
    primary key (customer_hk, load_date)
);

-- Satellite on Link_Order (order attributes / measures)
create table sat_order_details (
    order_hk            char(32)    not null references link_order(order_hk),
    load_date           timestamp   not null,
    load_end_date       timestamp,
    record_source       varchar(200) not null,
    hash_diff           char(32)    not null,
    order_date          date,
    total_amount        decimal(12,2),
    currency_code       char(3),
    status              varchar(30),
    primary key (order_hk, load_date)
);
```

**Special columns and their purpose:**

| Column | Purpose |
|---|---|
| `*_hk` (hash key) | Surrogate key derived deterministically from business key via MD5/SHA1. Enables parallel loading without sequence generators. |
| `load_date` | When this record was loaded into the vault. Never the business date — that goes in the satellite. |
| `load_end_date` | When this satellite row was superseded. NULL = current. Populated by the next load when a new row arrives. |
| `record_source` | Which source system produced this record — critical for auditability and conflict resolution. |
| `hash_diff` | MD5 hash of all satellite attribute values. Compare this instead of individual columns to detect changes — much faster on wide satellites. |

**When Data Vault is appropriate vs overkill:**

| Appropriate | Overkill |
|---|---|
| 5+ source systems with conflicting keys | Single source system |
| Regulatory/audit requirements (GDPR, SOX) | Small team / startup |
| Large enterprise, multiple teams loading | Fast delivery is the priority |
| Schema evolution is frequent | Well-understood, stable domain |
| Insert-only audit trail is required | Normal SCD 2 history is sufficient |

**Gotchas:**
- Data Vault is complex to query directly. You typically build "Information Marts" (star schemas or OBTs) on top of the vault for end-user consumption.
- The hash key approach means you don't need a sequence generator, enabling parallel inserts across systems. But MD5 collisions exist (rare) — some shops use SHA-256.
- Loading order matters for Links: Hubs must be loaded before Links. Satellites can load in parallel with their parent Hub/Link.
- Data Vault is a methodology, not just a schema pattern. It includes rules for how source systems integrate, how deletions are tracked (end-dated satellites), and how business rules are separated from raw data.
