<!-- Part of data-modelling-patterns: Grain Definition, Star Schema, Snowflake Schema -->

# Part 3 — Dimensional Modelling (Kimball): Grain, Star, and Snowflake

---

## 6. Grain Definition

**What it solves:** Establishes exactly what one row in a fact table represents. The grain is the single most important decision in dimensional modelling — every other decision flows from it.

> **Keywords to spot:** "what does one row represent", "level of detail", "atomic", "granularity", "aggregated fact", "transaction level", "daily summary"

**Business Context:**
- **E-commerce:** Is the grain one order, or one line item per order? (Line item is finer — you can always aggregate up, you can never disaggregate down)
- **Fintech:** Is the grain one transaction, or one daily account balance snapshot?
- **SaaS:** Is the grain one user event, or one daily active user record?
- **HR:** Is the grain one pay period record per employee, or one line-item deduction per employee per pay period?

### How to state grain precisely

A well-stated grain answers: **one row = one [event/entity] per [time period] per [other dimensions if relevant]**

Examples:
- "One row per sales transaction line item" — transaction fact
- "One row per account per calendar month" — periodic snapshot
- "One row per loan application, tracking its lifecycle" — accumulating snapshot
- "One row per student per course enrollment" — factless fact

### Fine vs coarse grain trade-offs

| Fine grain (atomic) | Coarse grain (aggregated) |
|---|---|
| One row per transaction | One row per customer per day |
| More rows, more storage | Fewer rows, cheaper queries |
| Supports any aggregation | Locked into pre-defined aggregation |
| Can answer "what was transaction #1234?" | Cannot drill down to individual events |
| Preferred in Kimball methodology | Acceptable only as a separate summary table |

**The rule: never mix grains in one fact table.**

If you have a fact table at order-line-item grain, do not add a column `order_total` (which is at order grain) alongside `line_revenue` (at line-item grain). The `order_total` will be wrong in every aggregation — it gets counted once per line item instead of once per order.

```sql
-- BAD: mixed grain
create table fact_orders_bad (
    order_sk        bigint,
    line_item_sk    bigint,
    customer_sk     bigint,
    product_sk      bigint,
    line_revenue    decimal(12,2),   -- line-item grain — correct
    order_total     decimal(12,2)    -- order grain — WRONG, will double/triple count
);
```

```sql
-- GOOD: separate the grains
-- Fact at line-item grain
create table fact_order_lines (
    order_line_sk   bigint primary key,
    order_sk        bigint,
    customer_sk     bigint,
    product_sk      bigint,
    order_date_sk   int,
    quantity        int,
    unit_price      decimal(10,2),
    line_revenue    decimal(12,2)
);

-- Separate fact at order grain (if needed)
create table fact_orders (
    order_sk        bigint primary key,
    customer_sk     bigint,
    order_date_sk   int,
    order_total     decimal(12,2),
    line_item_count int
);
```

**Why wrong grain corrupts everything:**

Say an order has 3 line items totaling $300 ($100 each). If `order_total = 300` is stored on each of the 3 line-item rows, then `SUM(order_total)` = $900. Every revenue dashboard is 3x overstated. This is one of the hardest bugs to catch because the data "looks right" row by row.

**Gotchas:**
- Always pick the finest grain you'll ever need. You can always aggregate up; you can never reconstruct detail from a summary.
- The grain determines which dimensions are possible. If your grain is daily snapshots, you cannot add a transaction_id dimension — there is no meaningful transaction_id at daily grain.
- When asked "how would you model X," defining the grain before touching any DDL is the right answer. Interviewers who know Kimball will notice.

---

## 7. Star Schema

**What it solves:** The canonical OLAP schema. One central fact table surrounded by denormalized dimension tables — like a star. Optimized for analytical queries with minimal joins.

> **Keywords to spot:** "star schema", "fact table", "dimension table", "surrogate key", "dimensional model", "Kimball", "single join to dimension"

**Business Context:**
- **Retail:** `fact_sales` surrounded by `dim_date`, `dim_product`, `dim_store`, `dim_customer`
- **SaaS:** `fact_user_events` surrounded by `dim_user`, `dim_date`, `dim_feature`, `dim_plan`
- **Fintech:** `fact_transactions` surrounded by `dim_account`, `dim_date`, `dim_merchant`, `dim_channel`

**Schema diagram:**

```
                    dim_date
                       |
dim_customer ──── fact_sales ──── dim_product
                       |
                    dim_store
```

**DDL:**

```sql
create table dim_date (
    date_sk         int primary key,
    full_date       date        not null,
    day_of_week     varchar(10),
    day_of_month    int,
    month_num       int,
    month_name      varchar(10),
    quarter         int,
    year            int,
    is_weekend      boolean,
    is_holiday      boolean,
    fiscal_period   varchar(20)
);

create table dim_product (
    product_sk      bigint primary key,
    product_id      varchar(50)  not null,  -- natural key
    product_name    varchar(200),
    category        varchar(100),
    subcategory     varchar(100),
    brand           varchar(100),
    unit_cost       decimal(10,2),
    effective_from  date,
    effective_to    date,
    is_current      boolean
);

create table dim_customer (
    customer_sk     bigint primary key,
    customer_id     varchar(50)  not null,
    full_name       varchar(200),
    email           varchar(255),
    city            varchar(100),
    country         varchar(100),
    segment         varchar(50),
    effective_from  date,
    effective_to    date,
    is_current      boolean
);

create table dim_store (
    store_sk        bigint primary key,
    store_id        varchar(50)  not null,
    store_name      varchar(200),
    city            varchar(100),
    region          varchar(100),
    country         varchar(100),
    store_type      varchar(50)
);

create table fact_sales (
    sales_sk        bigint primary key,
    order_date_sk   int          references dim_date(date_sk),
    customer_sk     bigint       references dim_customer(customer_sk),
    product_sk      bigint       references dim_product(product_sk),
    store_sk        bigint       references dim_store(store_sk),
    -- grain: one row per order line item
    order_id        varchar(50),  -- degenerate dimension
    quantity        int,
    unit_price      decimal(10,2),
    discount_amount decimal(10,2),
    revenue         decimal(12,2),
    cost            decimal(12,2),
    profit          decimal(12,2)
);
```

**Gotchas:**
- Dimension tables are denormalized by design. A product dimension flattens category → subcategory → brand into one row. This is correct for a star schema — don't normalize it back out.
- All foreign keys in the fact table point to dimension surrogate keys (integers), not natural keys. This is both a performance optimization and an SCD enabler.
- `order_id` stored directly on the fact table is a degenerate dimension (no corresponding dimension table). This is normal — see Section 11-D.
- Star schemas are fast because BI tools generate single-hop joins: fact → dim. No chaining through multiple levels of lookup tables.

---

## 8. Snowflake Schema

**What it solves:** A star schema where dimension tables are normalized — sub-dimensions are split out into their own tables. Reduces storage redundancy at the cost of additional joins.

> **Keywords to spot:** "snowflake schema", "normalized dimensions", "sub-dimension", "hierarchy in dimensions", "product → category → department"

**Business Context:**
- **Retail:** `dim_product` split into `dim_product` → `dim_subcategory` → `dim_category` → `dim_department`
- **HR:** `dim_employee` → `dim_department` → `dim_division` → `dim_business_unit`
- **Healthcare:** `dim_provider` → `dim_clinic` → `dim_health_system`

**Schema diagram:**

```
dim_department
      |
dim_category
      |
dim_subcategory
      |
dim_product ──── fact_sales ──── dim_customer ──── dim_region
                     |
                  dim_date
```

**DDL — snowflaked product hierarchy:**

```sql
create table dim_department (
    department_sk   int primary key,
    department_id   varchar(50) not null,
    department_name varchar(100)
);

create table dim_category (
    category_sk     int primary key,
    category_id     varchar(50) not null,
    category_name   varchar(100),
    department_sk   int  references dim_department(department_sk)
);

create table dim_subcategory (
    subcategory_sk  int primary key,
    subcategory_id  varchar(50) not null,
    subcategory_name varchar(100),
    category_sk     int  references dim_category(category_sk)
);

create table dim_product (
    product_sk      bigint primary key,
    product_id      varchar(50) not null,
    product_name    varchar(200),
    subcategory_sk  int  references dim_subcategory(subcategory_sk),
    unit_cost       decimal(10,2)
);
```

**Star vs Snowflake — when to use which:**

| Factor | Star | Snowflake |
|---|---|---|
| Query speed | Faster (fewer joins) | Slower (more joins) |
| Storage | More redundancy | Less redundancy |
| ETL complexity | Simpler to load | More tables to maintain |
| Hierarchy changes | Update all product rows | Update one category row |
| BI tool compatibility | Better (most tools optimize for star) | Can cause issues with some tools |

**Gotchas:**
- In cloud warehouses (Snowflake, BigQuery), storage is cheap and compute is the bottleneck. Star schema wins almost every time for query performance.
- Snowflake schema makes more sense when hierarchies have many levels (5+) and the dimension is large (millions of rows) — rare in practice.
- Don't confuse Snowflake (the database product) with snowflake schema (the modelling pattern). They are completely unrelated.
- Most Kimball practitioners default to star schema. Snowflake schema is a legitimate choice but requires a strong reason.
