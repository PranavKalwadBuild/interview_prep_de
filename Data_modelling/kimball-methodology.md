# Kimball Dimensional Modelling — Complete Methodology Reference

> **What this file covers:** The Kimball methodology concepts NOT covered in the numbered files.
> Cross-references: grain/star schema → `06`, fact types → `07`, dimension types → `08`, SCD types → `09`

---

## 1. Kimball's 4-Step Dimensional Design Process

Kimball mandates four steps in strict sequence. Skipping or reordering produces models with mismatched facts and orphaned dimensions.

### Step 1 — Select the Business Process

A **business process** is a core operational activity that produces measurable events: POS scan, loan disbursement, insurance claim filed, inventory count. Each process eventually becomes one fact table.

**Critical distinction:** business processes are NOT departments or strategic initiatives. Users describe initiatives ("improve retention") — probe for the underlying event: *"What gets recorded as a source system row?"*

**Design rule:** One business process = one fact table. Mixing processes in a single fact table is the primary anti-pattern.

### Step 2 — Declare the Grain

The grain answers: **"What does one row in this fact table represent?"** Must be stated in precise business terms before any schema is drawn.

**Kimball's rule:** Always choose the most atomic grain supported by the source. Atomic grain preserves maximum analytic flexibility. Summarized grain is irreversible — you cannot reconstruct detail from a summary.

```
BAD grain declaration:  "one order"
GOOD grain declaration: "one scanned line item per POS transaction"

Why it matters: a transaction-level grain cannot answer per-product-per-transaction
questions. A line-item grain can always aggregate up to transaction level.
```

**The most common design failure (per Kimball):** failing to declare grain before drawing dimensions and facts. This produces rows that represent different things, making every aggregation suspect.

### Step 3 — Identify the Dimensions

Ask: *"How do business users describe this measurement event?"* Dimensions answer: **who, what, where, when, why, and how** for every fact row.

With grain declared, candidate dimensions become obvious — date of the event, the product scanned, the store location, the customer involved.

**Validation rule:** Each dimension must take a single value per fact row given the declared grain. A multi-valued dimension (customer belongs to multiple segments) signals a bridge table or mini-dimension.

### Step 4 — Identify the Facts

Facts are the numeric measurements produced by the business process event. Must be consistent with the declared grain.

**Validate each candidate fact:**
1. Is it numeric?
2. Does it occur at the declared grain?
3. Is it consistently captured in source systems?
4. Does summing it across all dimensions produce a meaningful result?

**Factless facts** are valid when the business event itself (attendance, coverage, promotion eligibility) is the information — no numeric measure needed.

---

## 2. Enterprise Data Warehouse Bus Architecture

### What It Is

The Bus Architecture is Kimball's blueprint for building an enterprise DW incrementally. Teams implement one business process at a time while guaranteeing integration through **conformed dimensions**. The architecture is technology-independent — relational and OLAP structures both participate.

### The Enterprise Bus Matrix

A planning grid where:
- **Rows** = business processes (each becomes one or more fact tables)
- **Columns** = conformed dimensions
- **Shaded cell** = this dimension applies to this business process

**Retail company example:**

| Business Process | Date | Customer | Product | Store | Employee | Promotion | Vendor |
|---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| POS Transactions | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | |
| Inventory Snapshot | ✓ | | ✓ | ✓ | | | ✓ |
| Customer Returns | ✓ | ✓ | ✓ | ✓ | ✓ | | |
| Procurement Orders | ✓ | | ✓ | ✓ | | | ✓ |
| HR Events | ✓ | | | ✓ | ✓ | | |

**How to use the matrix:**
- **Scan rows** → validate that each dimension is coherently defined for a given process
- **Scan columns** → identify which dimensions must be conformed across multiple processes (shared columns = must agree on keys and attribute labels)
- **Each row** = a sprint/release deliverable — implement incrementally

### Conformed Dimensions and Drill-Across

A **conformed dimension** is defined once and reused identically (same keys, attribute names, labels) across all star schemas that reference it. `dim_product` in POS and `dim_product` in Inventory are the same table or identical views.

**Drill-across** = querying two separate fact tables and combining on a shared conformed dimension. Mechanism:
1. BI tool issues two SQL queries — one against each fact table
2. Results are outer-joined on the shared dimension key
3. Result: combined row showing POS revenue and inventory levels by product, by date

Without conformed dimensions this requires a custom ETL join — fragile, inconsistent, and not self-service.

---

## 3. Additive, Semi-Additive, and Non-Additive Measures

### Decision Rule

```
Can this measure be SUMmed across ALL dimensions?
  YES  → Additive
  NO   → Can it be SUMmed across some dimensions (but not time)?
    YES → Semi-Additive
    NO  → Non-Additive (never store as a raw measure — store the components instead)
```

### Additive

Summed across any dimension. Produced primarily by **transaction fact tables**.

**Examples:** `quantity_sold`, `sales_amount`, `shipping_cost`, `line_item_discount`

```sql
-- All three are valid
SELECT store_id,    SUM(sales_amount) FROM fact_pos GROUP BY store_id;
SELECT date_key,    SUM(sales_amount) FROM fact_pos GROUP BY date_key;
SELECT product_key, SUM(quantity_sold) FROM fact_pos GROUP BY product_key;
```

### Semi-Additive

Summed across **some** dimensions, but NOT across time. Produced primarily by **periodic snapshot fact tables**.

**Examples:** `account_balance`, `inventory_quantity_on_hand`, `headcount`, `subscriber_count`

**Why not across time:** Summing a bank balance across 30 days gives $3,000 when the account has $100 — it's the same $100 counted 30 times.

```sql
-- WRONG: sums balance across time periods
SELECT SUM(account_balance)
FROM fact_account_snapshot
WHERE year = 2024;
-- Returns 365× the actual year-end balance if daily snapshots

-- CORRECT: filter to one period, then sum across entities
SELECT SUM(account_balance)
FROM fact_account_snapshot
WHERE snapshot_date = '2024-12-31';

-- CORRECT: average across time is a valid analysis
SELECT customer_key, AVG(account_balance) AS avg_daily_balance
FROM fact_account_snapshot
WHERE snapshot_date BETWEEN '2024-01-01' AND '2024-12-31'
GROUP BY customer_key;
```

**Common mistake:** `SUM(account_balance)` without a date filter in a periodic snapshot — produces a number nobody asked for and is wrong by a factor equal to the number of snapshot periods.

### Non-Additive

Cannot be meaningfully summed across ANY dimension. Typically ratios, percentages, rates, unit prices.

**Examples:** `profit_margin_pct`, `conversion_rate`, `unit_price`, `average_order_value`

**Kimball's rule:** Do NOT store ratios as fact columns. Store the additive components and compute the ratio in the query or BI layer.

```sql
-- WRONG: store margin% in fact table
SELECT store_id, AVG(profit_margin_pct) FROM fact_sales GROUP BY store_id;
-- Produces a simple average of percentages, not revenue-weighted margin

-- CORRECT: store gross_profit and revenue; compute at query time
SELECT
    store_id,
    SUM(gross_profit) / NULLIF(SUM(revenue), 0) AS blended_margin_pct
FROM fact_sales
GROUP BY store_id;
```

### Summary Table

| Type | Fact Table Type | SQL Aggregation | Example |
|---|---|---|---|
| **Additive** | Transaction | `SUM` across all dims | `sales_amount` |
| **Semi-Additive** | Periodic Snapshot | `SUM` across non-time dims; `AVG` or `LAST` across time | `account_balance` |
| **Non-Additive** | Any | Never `SUM`; compute from components | `profit_margin_pct` |

---

## 4. Mini-Dimensions

### Problem Statement

A **monster dimension** has millions of rows AND rapidly changing attributes. Applying SCD Type 2 to track every demographic change across 10M customers who each change once per year adds 10M rows annually — the dimension balloons and most SCD rows differ only in `age_band` or `income_level`.

### Solution

Extract the rapidly-changing attributes into a separate **mini-dimension**. Assign a surrogate key to each unique **combination** of attribute values (not per customer). Both the base dimension key and the mini-dimension key become foreign keys on the fact table.

**When to use:**
- Attribute changes frequently relative to the fact load interval
- Attribute combinations are low-cardinality (age bands, income tiers, credit score bands)
- Base dimension has millions of rows

```sql
-- Base Customer Dimension — large, stable attributes only
CREATE TABLE dim_customer (
    customer_key       BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    customer_nk        VARCHAR(20) NOT NULL,
    customer_name      VARCHAR(100),
    customer_address   VARCHAR(200),
    effective_date     DATE,
    expiry_date        DATE,
    is_current         BOOLEAN DEFAULT TRUE,
    current_demo_key   INT   -- Type 1 pointer to current mini-dim row (optional)
);

-- Mini-Dimension — low-cardinality combinations of rapidly-changing attrs
CREATE TABLE dim_customer_demographics (
    demo_key           INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    age_band           VARCHAR(20),     -- '18-24', '25-34', '35-44', '45-54', '55+'
    income_level       VARCHAR(20),     -- 'Low', 'Medium', 'High'
    purchase_frequency VARCHAR(20),     -- 'Frequent', 'Occasional', 'Rare'
    credit_score_band  VARCHAR(20)      -- 'Poor', 'Fair', 'Good', 'Excellent'
    -- Total combinations: 5 × 3 × 3 × 4 = 180 rows max
);

-- Fact Table — FK to BOTH base dimension and mini-dimension
CREATE TABLE fact_sales (
    sales_key          BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    date_key           INT    NOT NULL,
    customer_key       BIGINT NOT NULL REFERENCES dim_customer(customer_key),
    demo_key           INT    NOT NULL REFERENCES dim_customer_demographics(demo_key),
    product_key        BIGINT NOT NULL,
    store_key          INT    NOT NULL,
    audit_key          INT    NOT NULL,
    quantity           INT,
    sales_amount       DECIMAL(15,2)
);
```

**How ETL loads the mini-dimension:**
```sql
-- At fact load time: look up or insert the current demographic combination
INSERT INTO dim_customer_demographics (age_band, income_level, purchase_frequency, credit_score_band)
SELECT DISTINCT age_band, income_level, purchase_frequency, credit_score_band
FROM staging_customer_updates
WHERE (age_band, income_level, purchase_frequency, credit_score_band) NOT IN (
    SELECT age_band, income_level, purchase_frequency, credit_score_band
    FROM dim_customer_demographics
);

-- Then join to get the demo_key for the fact row
SELECT d.demo_key
FROM dim_customer_demographics d
WHERE d.age_band = :customer_age_band
  AND d.income_level = :customer_income_level
  AND d.purchase_frequency = :customer_purchase_freq
  AND d.credit_score_band = :customer_credit_band;
```

### Mini-Dimension vs Junk Dimension vs SCD Type 2

| Concept | Purpose | Keyed by | Grows with |
|---|---|---|---|
| **Mini-dimension** | Split rapidly-changing attrs off large base dimension | Unique attribute combinations | New attribute value combinations |
| **Junk dimension** | Consolidate many low-cardinality flags off fact table | All combinations pre-populated | Never (2^N rows, static) |
| **SCD Type 2** | Track full history of slowly changing attrs in base dim | New row per change per entity | Each entity change |

---

## 5. Outrigger Dimensions

### Definition

An outrigger is a dimension table referenced not by the fact table directly, but by another dimension table. Creates a two-hop path: fact → primary dimension → outrigger dimension.

**Canonical Kimball example:** An `employee` dimension contains `hire_date_key` pointing to a `dim_hire_date` table — a date dimension with hire-specific labels (`hire_fiscal_year`, `hire_cohort`) that would create naming confusion if merged with the standard transaction `dim_date`.

### When Acceptable

- The secondary dimension is genuinely independent with attributes that cannot be absorbed without semantic confusion
- The outrigger is used sparingly and deliberately — one or two instances in the entire model

### When to Avoid

Kimball's guidance is explicit: *"Outriggers should be viewed as the exception rather than the rule. If outriggers are rampant in your dimensional model, it's time to return to the drawing board."*

Rampant outriggers signal:
- Snowflaking crept in through the dimension side door
- Primary dimensions were not denormalized correctly
- Users face complex multi-join queries

**Preferred alternative:** demote the relationship to the fact table — make both the primary and secondary dimensions direct FKs on the fact table instead of chaining through a dimension.

### Outrigger vs Snowflake

| | Outrigger | Snowflake |
|---|---|---|
| Structure | dim → secondary dim (one extra hop) | dim → multiple normalized levels (many hops) |
| Normalization degree | One additional layer | Full 3NF normalization of dimension |
| Kimball stance | Permissible in moderation | Actively discouraged for DW/BI |
| Trigger | Distinct semantic need (different label sets on same date dim) | Normalization reflex from OLTP design habits |

---

## 6. Audit Dimensions (ETL Lineage)

### Purpose

Every fact row should carry an FK to an **audit dimension** that records the ETL environment and data quality state in effect when that row was created. Enables: "What ETL version produced this row? Were any data quality problems flagged?"

This is from Kimball Design Tip #164: *"Have You Built Your Audit Dimension Yet?"*

### What Goes In It

**Environment variables** (the ETL configuration snapshot):
- `etl_master_version` — version identifier for the complete ETL config active at load time
- `currency_conversion_version` — which FX conversion rules applied
- `allocation_version` — which cost allocation business rules applied

**Data quality indicators** (populated from error event tracking during the ETL run):
- `missing_data_flag` — NULL or corrupt source values encountered
- `data_supplied_flag` — estimated or fill/default values substituted
- `unlikely_value_flag` — anomalously high or low values detected

```sql
CREATE TABLE dim_audit (
    audit_key               INT       GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    etl_batch_id            VARCHAR(50)  NOT NULL,
    etl_master_version      VARCHAR(20)  NOT NULL,   -- e.g., '2.4.1'
    currency_convert_ver    VARCHAR(20),
    allocation_version      VARCHAR(20),
    source_system_name      VARCHAR(100),
    load_start_time         TIMESTAMP,
    load_end_time           TIMESTAMP,
    row_count_inserted      INT,
    row_count_updated       INT,
    row_count_rejected      INT,
    missing_data_flag       BOOLEAN DEFAULT FALSE,
    data_supplied_flag      BOOLEAN DEFAULT FALSE,
    unlikely_value_flag     BOOLEAN DEFAULT FALSE
);

-- Every fact table gets an audit_key FK
CREATE TABLE fact_sales (
    sales_key     BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    date_key      INT    NOT NULL,
    customer_key  BIGINT NOT NULL,
    product_key   BIGINT NOT NULL,
    store_key     INT    NOT NULL,
    audit_key     INT    NOT NULL REFERENCES dim_audit(audit_key),  -- lineage
    quantity      INT,
    sales_amount  DECIMAL(15,2)
);
```

**Operational rule:** The audit dimension row is the **last** insert of each ETL run — its final state captures actual counts and quality flags only after all other processing completes. Insert a placeholder row at ETL start, update it at the end.

**Query use:**
```sql
-- Find all fact rows loaded by ETL versions with data quality flags
SELECT f.*, a.etl_master_version, a.missing_data_flag
FROM fact_sales f
JOIN dim_audit a ON f.audit_key = a.audit_key
WHERE a.missing_data_flag = TRUE
  AND a.load_start_time >= '2024-01-01';
```

---

## 7. Late Arriving Dimensions (Early Arriving Facts)

### Terminology

- **Late arriving dimension / early arriving fact:** A fact record arrives but its corresponding dimension member does not yet exist. The fact must load now; dimension data comes later.
- **Late arriving fact:** A fact arrives after its dimension data is present — less disruptive, handled by standard SCD logic.

### The Inferred Member Pattern (Kimball Standard)

When a fact references a dimension natural key with no matching row:

1. **Insert a placeholder row** immediately with the known business key and NULL/default attribute values. Set `inferred_flag = TRUE`.
2. Assign a **new surrogate key** to the placeholder.
3. **Load the fact** using the placeholder's surrogate key — referential integrity preserved.
4. When real dimension data arrives, **resolve the inferred member**: overwrite attributes and set `inferred_flag = FALSE`.

```sql
-- Step 1: insert placeholder when dimension data is missing
INSERT INTO dim_customer (
    customer_nk, customer_name, customer_address,
    effective_date, is_current, inferred_flag
)
VALUES (
    'C-9999',        -- natural key known from fact
    'Unknown',       -- placeholder attributes
    'Unknown',
    CURRENT_DATE,
    TRUE,
    TRUE             -- mark as inferred
);

-- Step 3: load the fact normally (references placeholder surrogate)
INSERT INTO fact_sales (date_key, customer_key, product_key, ...)
SELECT ..., sk.customer_key, ...
FROM staging s
JOIN sk_lookup_customer sk ON s.customer_nk = sk.customer_nk;

-- Step 4: when real data arrives, resolve the inferred member
UPDATE dim_customer
SET customer_name   = 'Acme Corp',
    customer_address = '123 Main St',
    inferred_flag   = FALSE
WHERE customer_nk = 'C-9999'
  AND inferred_flag = TRUE;
```

### SCD 1 vs SCD 2 Resolution of Inferred Members

- **SCD Type 1 dimension:** Overwrite placeholder attributes in-place. Simple.
- **SCD Type 2 dimension:** Either (a) overwrite the placeholder in-place (treating it as if the real data was always there — no history created for the inferred period), or (b) expire the inferred row and insert a new row with real attributes — producing proper SCD 2 history.

### Alternative Handling Strategies

| Strategy | When to Use | Risk |
|---|---|---|
| **Inferred member (placeholder row)** | Finance — numbers must balance | Requires reconciliation job to detect unresolved inferred members |
| **Map to -2 "Unknown" member** | Operational metrics where late correction is not critical | Creates super-rows; corrections messy |
| **Error table + reprocess** | Most common alternative | Fact absent until resolved; problems if dimension never arrives |
| **Discard the row** | Rarely acceptable | Distorts totals |

---

## 8. Surrogate Key Pipeline Patterns

### What It Is

The surrogate key pipeline is **ETL subsystem #14** in Kimball's 34-subsystem framework. Its job: swap every natural key in incoming staging data for the current warehouse surrogate key before inserting into the fact table.

### The SK Lookup Table

Direct lookups against full dimension tables are slow at scale. Maintain a dedicated **SK lookup table** per dimension:

```sql
-- Maintained alongside dim_customer by dimension ETL
CREATE TABLE sk_lookup_customer (
    customer_nk   VARCHAR(20) PRIMARY KEY,  -- natural key from source
    customer_key  BIGINT      NOT NULL       -- current active surrogate key
);
-- Always points to the is_current=TRUE row in dim_customer
-- Updated atomically when SCD Type 2 inserts a new current row
```

**Rule:** Dimension ETL must complete before fact ETL begins for the same batch.

### The Lookup-Override-Insert Pattern

```
For each staging row:

1. LOOKUP: check sk_lookup_customer for the incoming customer_nk
   Found    → retrieve customer_key → go to step 3
   Not found → go to step 2

2. INSERT: create new dim_customer row (or inferred placeholder)
   - Generate surrogate key via sequence
   - Update sk_lookup_customer

3. OVERRIDE: replace customer_nk in staging row with customer_key

4. INSERT: load the staging row into fact_sales
```

For SCD Type 2 changes: dimension ETL inserts a new row (new surrogate), expires the old row, and updates `sk_lookup_customer.customer_key` to the new surrogate. Subsequent fact loads automatically reference the current version.

### Sequence Generator vs Hash-Based Surrogate Keys

| Method | How | Pros | Cons |
|---|---|---|---|
| **DB sequence / identity** | `GENERATED ALWAYS AS IDENTITY`, `NEXTVAL` | Compact integer, guaranteed unique | Single write point; not deterministic across environments |
| **Hash-based** | `MD5(natural_key)` truncated to BIGINT | Deterministic — same natural key → same SK always; enables parallel ETL | Collision risk; larger storage; confusing to debug |
| **UUID** | `UUID()` / `NEWID()` | No coordination needed | Very wide; poor index locality; almost never used for dimensional SKs |

**Production choice:** sequence/identity for compactness and join efficiency. Hash-based for streaming ETL where sequence service is a bottleneck.

### Fact Table Surrogate Keys

Kimball recommends a single-column surrogate key on the fact table itself (Design Tip #81):
- Enables single-column identification for ETL recovery
- Supports **insert-then-delete** correction pattern: insert corrected rows as new rows, delete originals atomically — avoids partial updates on wide fact tables

---

## 9. Kimball vs Inmon

### Core Philosophical Divide

| Dimension | Kimball (Bottom-Up) | Inmon (Top-Down) |
|---|---|---|
| **Starting point** | One business process data mart | Enterprise-wide EDW |
| **Data model** | Dimensional star/snowflake | 3NF normalized relational |
| **First deliverable** | Working data mart in weeks | Normalized EDW (months to years) |
| **Integration mechanism** | Conformed dimensions | 3NF normalization (one authoritative entity model) |
| **User queries** | Query the dimensional mart directly | Query downstream data marts fed from 3NF EDW |
| **Redundancy** | Higher — denormalized by design | Lower — normalized |
| **BI query performance** | Optimized (few joins, columnar-friendly) | More joins required |
| **Single source of truth** | Approximate via conformed dims | Strict via one 3NF model |

### Inmon's Hub-and-Spoke (Corporate Information Factory)

Inmon's CIF has three tiers:
1. **ETL/acquisition layer** — source systems are cleaned and integrated
2. **Atomic EDW (3NF)** — normalized, subject-oriented, non-volatile, time-variant; NOT designed for direct user queries
3. **Dependent data marts** — dimensional (star schema) marts built FROM the EDW for specific departments

The EDW is the "hub"; data marts are the "spokes." No mart is built directly from source systems.

### When Each Wins

**Kimball wins when:**
- Tactical per-process analytics needed quickly
- Business users query data directly
- Smaller team; iterative delivery required
- Modern cloud columnar DW (Snowflake, BigQuery, Redshift) — star schema aggregation is highly optimized

**Inmon wins when:**
- Enterprise-wide regulatory reporting requiring strict single source of truth
- Cross-process queries that conformed dimensions cannot satisfy
- Large organization with overlapping subject areas and complex governance
- Long-term investment in data quality justified by compliance

### The Modern Reality

The Kimball/Inmon divide has largely dissolved. The **medallion architecture** (Bronze/Silver/Gold) mirrors the Inmon pattern structurally — staged integration → clean integrated layer → consumption layer — but uses dimensional models at Gold. **Data Vault 2.0** (Dan Linstedt) explicitly combines both: Hubs/Links/Satellites for integration (Inmon-inspired), dimensional marts on top for consumption (Kimball). In practice most teams use a hybrid.

---

## 10. Anti-Patterns and Key Tenets

### The 7 Key Tenets of Kimball Method (Design Tip #179)

1. **Dimensional model is the key asset** — get the model right first; everything else follows
2. **Dimensional modeling is a group activity** — requires 50–60 hours over 4–6 weeks with business users; solo modeling always produces inferior results
3. **The model is the best system specification** — both business and IT validate the same artifact
4. **The model must add value beyond restructuring source data** — add enhanced descriptors, pre-computed bands, alternative hierarchies; a policy of "add nothing beyond source" is a mistake
5. **MDM integration for master data** — ETL should not solve de-duplication; MDM systems with human review handle entity resolution
6. **Don't skip the relational data warehouse** — separation of concerns: ETL tools transform, relational DBs store, BI tools visualize
7. **It's all about the business** — every architectural decision is justified by business user needs, not technical preference

### Critical Anti-Patterns

**Anti-pattern 1 — Wrong grain declaration**

Declaring grain as "one order" when source captures "one order line item." Produces inflated revenue totals when products are counted at order level.

**Anti-pattern 2 — Header/Line fact tables (Design Tip #95)**

Replicating OLTP parent-child structure as two fact tables (header fact + line item fact) instead of flattening header attributes into the line item fact. Forces a massive join between two large fact tables on every BI query. Fix: denormalize header attributes into the line item fact row.

**Anti-pattern 3 — Snowflaking dimensions**

Normalizing dimension attributes into linked lookup tables to "save space." A standard DW has 10–20 denormalized dimension tables; the snowflake equivalent requires 100+ linked tables. Adds join complexity, hurts optimizer, confuses BI tools. Storage is cheap in cloud DWs — denormalize.

**Anti-pattern 4 — Mixing multiple business processes in one fact table**

Combining sales and returns in one fact table with indicator flags. Produces incorrect aggregations, complicates grain declarations, makes the fact table impossible to query correctly without constant filter conditions.

**Anti-pattern 5 — Non-additive facts stored as measures**

Storing `profit_margin_pct` as a fact column and computing `AVG(profit_margin_pct)` across stores — this is a simple average of percentages, not a revenue-weighted margin. Store `gross_profit` and `revenue` instead.

**Anti-pattern 6 — No durable key on SCD Type 2 dimensions**

If every SCD Type 2 insert creates a new surrogate key but there is no stable `customer_durable_key` column, queries grouping all history for one customer require a sub-select on the natural key — defeating the surrogate key pipeline.

```sql
-- CORRECT: include a durable key that never changes across SCD2 versions
CREATE TABLE dim_customer (
    customer_key         BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    customer_durable_key BIGINT NOT NULL,   -- same value across all versions of same customer
    customer_nk          VARCHAR(20) NOT NULL,
    ...
    effective_date       DATE NOT NULL,
    expiry_date          DATE,
    is_current           BOOLEAN DEFAULT TRUE
);
```

**Anti-pattern 7 — Rampant outriggers**

When dimension tables chain three or more levels deep, the model has become a de facto snowflake. Refactor by flattening the outrigger attributes into the primary dimension.

---

## Quick Reference DDL Templates

```sql
-- Conformed Date Dimension
CREATE TABLE dim_date (
    date_key          INT PRIMARY KEY,      -- YYYYMMDD
    full_date         DATE NOT NULL UNIQUE,
    year              INT,
    quarter           INT,
    month             INT,
    month_name        VARCHAR(20),
    week_of_year      INT,
    day_of_week       INT,
    day_name          VARCHAR(20),
    is_weekend        BOOLEAN,
    is_holiday        BOOLEAN,
    fiscal_year       INT,
    fiscal_quarter    INT,
    first_day_month   DATE,
    last_day_month    DATE
);

-- SCD Type 2 Dimension with durable key
CREATE TABLE dim_customer (
    customer_key         BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    customer_durable_key BIGINT      NOT NULL,  -- stable across SCD2 inserts
    customer_nk          VARCHAR(20) NOT NULL,
    customer_name        VARCHAR(100),
    city                 VARCHAR(100),
    segment              VARCHAR(50),
    effective_date       DATE        NOT NULL,
    expiry_date          DATE,
    is_current           BOOLEAN     DEFAULT TRUE,
    inferred_flag        BOOLEAN     DEFAULT FALSE  -- for late-arriving dimension pattern
);

-- SK Lookup Table
CREATE TABLE sk_lookup_customer (
    customer_nk   VARCHAR(20) PRIMARY KEY,
    customer_key  BIGINT NOT NULL   -- always points to is_current=TRUE row
);

-- Audit Dimension
CREATE TABLE dim_audit (
    audit_key               INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    etl_batch_id            VARCHAR(50) NOT NULL,
    etl_master_version      VARCHAR(20) NOT NULL,
    source_system_name      VARCHAR(100),
    load_start_time         TIMESTAMP,
    load_end_time           TIMESTAMP,
    row_count_inserted      INT,
    row_count_rejected      INT,
    missing_data_flag       BOOLEAN DEFAULT FALSE,
    data_supplied_flag      BOOLEAN DEFAULT FALSE,
    unlikely_value_flag     BOOLEAN DEFAULT FALSE
);

-- Fact Table with all pattern pieces
CREATE TABLE fact_sales (
    sales_key            BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,  -- Design Tip #81
    date_key             INT    NOT NULL REFERENCES dim_date(date_key),
    customer_key         BIGINT NOT NULL REFERENCES dim_customer(customer_key),
    product_key          BIGINT NOT NULL,
    store_key            INT    NOT NULL,
    demo_key             INT    REFERENCES dim_customer_demographics(demo_key),  -- mini-dim
    audit_key            INT    NOT NULL REFERENCES dim_audit(audit_key),        -- lineage
    order_id             VARCHAR(50),          -- degenerate dimension
    quantity             INT,
    unit_price           DECIMAL(10,2),        -- non-additive: store component, not ratio
    sales_amount         DECIMAL(15,2),        -- additive
    cost_amount          DECIMAL(15,2),        -- additive
    gross_profit         DECIMAL(15,2)         -- additive (compute margin% in query layer)
);
```

---

## Interview Signal Map

| Topic | Basic answer | Senior answer |
|---|---|---|
| What is Kimball? | "Star schema with fact and dimension tables" | Explain 4-step process + bus architecture + conformed dimensions |
| Star vs Snowflake | "Star is denormalized, snowflake is normalized" | Star wins in cloud DW because storage is cheap; snowflake adds joins; Kimball defaults to star |
| SCD Type 2 bug | "Use is_current flag" | Surrogate key pipeline: ETL must look up the SK active AT THE TIME of the event, not current SK |
| Semi-additive fact | "Can't SUM across all dims" | Name the fact table type (periodic snapshot), which dims are OK to sum across, and what to use for time (AVG/LAST) |
| Mini-dimension | (often unknown) | Split rapidly-changing low-cardinality attrs off monster dims; keyed by combination not entity |
| Late-arriving dimension | "Mark as unknown" | Inferred member pattern: placeholder row with inferred_flag, resolve when data arrives |
| Kimball vs Inmon | "Kimball = dimensional, Inmon = 3NF" | Delivery speed, integration mechanism, modern equivalents (medallion ≈ Inmon structure with Kimball Gold layer) |

---

*Related files:*
- *[06-grain-and-star-schema.md](06-grain-and-star-schema.md) — grain declaration, star vs snowflake DDL*
- *[07-galaxy-and-fact-types.md](07-galaxy-and-fact-types.md) — all 4 fact table types*
- *[08-dimension-types.md](08-dimension-types.md) — conformed, junk, role-playing, bridge, date dimensions*
- *[09-scd-types.md](09-scd-types.md) — SCD 0 through 6*
