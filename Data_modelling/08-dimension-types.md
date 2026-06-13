<!-- Part of data-modelling-patterns: All 6 Dimension Types -->

# Dimension Table Types

---

## 11. Dimension Table Types

---

### 11-A. Conformed Dimensions

**What it solves:** A dimension built once and reused identically across multiple fact tables and subject areas. Enables consistent cross-functional analysis.

> **Keywords to spot:** "shared dimension", "consistent definition", "cross-subject-area", "enterprise dimension", "single version of truth for customers/products/dates"

**Business Context:**
- **Retail:** `dim_date` used by sales, inventory, returns, and promotions fact tables
- **SaaS:** `dim_user` used by events, subscriptions, support tickets, and billing fact tables
- **Fintech:** `dim_account` used by transactions, balances, and loan fact tables

**The test:** A dimension is conformed if two different business users querying two different fact tables using that dimension get consistent, comparable results. If `dim_customer` means different things in the sales schema vs the marketing schema, it is NOT conformed.

**Gotchas:**
- Conforming dimensions is an organizational challenge as much as a technical one. "Customer" in the CRM might not match "Customer" in the billing system. Data stewardship is required.
- The date dimension is always conformed. Build it once, share it everywhere.
- Partially conformed dimensions (shared keys but different attribute sets) can work but must be documented carefully.

---

### 11-B. Junk Dimensions

**What it solves:** Combines multiple low-cardinality flags and indicators from the fact table into a single dimension table, reducing the width of the fact table.

> **Keywords to spot:** "boolean flags", "low cardinality", "status indicators", "yes/no columns on fact table", "transaction flags", "flag consolidation"

**Business Context:**
- **E-commerce:** `is_gift`, `is_subscription`, `is_return_eligible`, `is_online_order` — four boolean columns on fact_orders become one `order_flags_sk` FK
- **Fintech:** `is_international`, `is_recurring`, `is_declined`, `is_reversed` on payment facts
- **Healthcare:** `is_emergency`, `is_inpatient`, `is_insured`, `is_referral` on encounter facts

**Without junk dimension:**

```sql
create table fact_orders_bad (
    order_sk            bigint primary key,
    customer_sk         bigint,
    product_sk          bigint,
    date_sk             int,
    is_gift             boolean,        -- repeated on millions of rows
    is_subscription     boolean,        -- repeated on millions of rows
    is_return_eligible  boolean,        -- repeated on millions of rows
    is_online           boolean,        -- repeated on millions of rows
    revenue             decimal(12,2)
);
```

**With junk dimension:**

```sql
-- All combinations of the flags — typically a small table (2^N rows)
create table dim_order_flags (
    order_flags_sk      int primary key,
    is_gift             boolean,
    is_subscription     boolean,
    is_return_eligible  boolean,
    is_online           boolean
    -- 16 possible combinations (2^4) — tiny table
);

create table fact_orders (
    order_sk            bigint primary key,
    customer_sk         bigint,
    product_sk          bigint,
    date_sk             int,
    order_flags_sk      int  references dim_order_flags(order_flags_sk),  -- single FK
    revenue             decimal(12,2)
);
```

**Gotchas:**
- The junk dimension pre-populates all possible combinations of the flags. Your ETL looks up or inserts the right row for each combination.
- Only use junk dimensions when the flags are truly orthogonal and low-cardinality. Don't force high-cardinality or correlated attributes into a junk dimension — the combination table explodes.
- Junk dimension = "garbage bag dimension" in some literature. Not a pejorative — it's a legitimate and useful pattern.

---

### 11-C. Role-Playing Dimensions

**What it solves:** The same physical dimension table used multiple times in one fact table in different semantic roles.

> **Keywords to spot:** "multiple dates per fact", "order date vs ship date vs delivery date", "source account vs destination account", "different roles for the same dimension"

**Business Context:**
- **Logistics:** `fact_shipments` has `ordered_date_sk`, `shipped_date_sk`, `delivered_date_sk` — all three are date dimension lookups playing different roles
- **Fintech:** `fact_transfers` has `source_account_sk` and `destination_account_sk` — both reference `dim_account`
- **HR:** `fact_headcount_changes` has `effective_date_sk` and `reporting_date_sk`

**DDL — the physical dimension is reused, views give it a role:**

```sql
-- Physical date dimension (defined once)
create table dim_date (
    date_sk         int primary key,
    full_date       date,
    day_of_week     varchar(10),
    month_num       int,
    year            int
    -- ... other date attributes
);

-- Views for each role (optional but useful for clarity in BI tools)
create view dim_order_date     as select * from dim_date;
create view dim_ship_date      as select * from dim_date;
create view dim_delivery_date  as select * from dim_date;

-- Fact table uses the same dim_date via multiple FK columns
create table fact_shipments (
    shipment_sk         bigint primary key,
    order_date_sk       int  references dim_date(date_sk),
    ship_date_sk        int  references dim_date(date_sk),
    delivery_date_sk    int  references dim_date(date_sk),   -- nullable
    customer_sk         bigint references dim_customer(customer_sk),
    product_sk          bigint references dim_product(product_sk),
    shipment_id         varchar(50),
    quantity_shipped    int,
    freight_cost        decimal(10,2)
);
```

**Query — using role-playing dates:**

```sql
-- Average days from order to delivery by product category
select
    p.category,
    avg(dd.full_date - od.full_date) as avg_order_to_delivery_days
from fact_shipments fs
join dim_date od on fs.order_date_sk    = od.date_sk
join dim_date dd on fs.delivery_date_sk = dd.date_sk
join dim_product p on fs.product_sk     = p.product_sk
where fs.delivery_date_sk is not null
group by 1;
```

**Gotchas:**
- Some BI tools (older Tableau, some SSAS setups) get confused when the same physical table appears multiple times in a schema with different aliases. Creating views per role solves this.
- Role-playing is a fact table design choice, not a dimension table change. The dimension itself doesn't change.

---

### 11-D. Degenerate Dimensions

**What it solves:** Stores a dimension attribute directly on the fact table when there is no other meaningful information to put in a dimension table for it.

> **Keywords to spot:** "order number on fact table", "ticket number", "invoice number", "no attributes beyond the ID", "control number"

**Business Context:**
- **E-commerce:** `order_id` on `fact_order_lines` — the order is the grouping key but there's nothing else to say about it beyond what's on the line items
- **Fintech:** `transaction_id` on `fact_payments` — useful for tracing back to source, no extra attributes
- **Logistics:** `bill_of_lading_number` on `fact_shipment_lines`

```sql
create table fact_order_lines (
    order_line_sk   bigint primary key,
    order_date_sk   int     references dim_date(date_sk),
    customer_sk     bigint  references dim_customer(customer_sk),
    product_sk      bigint  references dim_product(product_sk),
    order_id        varchar(50),    -- degenerate dimension — no dim_order table needed
    line_number     int,
    quantity        int,
    line_revenue    decimal(12,2)
);
```

**Gotchas:**
- Don't create a `dim_order` table just to hold `order_id` and nothing else. That's a 1:1 table with the fact, wastes a join, and adds no value.
- Degenerate dimensions are still useful for grouping: `GROUP BY order_id` gives you order-level totals from a line-item grain fact.
- The line between "degenerate dimension" and "just a field on the fact table" is semantic. Degenerate dimension implies it could have been a dimension but doesn't need its own table.

---

### 11-E. Bridge Tables (Many-to-Many)

**What it solves:** Resolves M:N relationships between facts and dimensions where a single fact row legitimately belongs to multiple dimension members.

> **Keywords to spot:** "multiple categories per product", "shared account", "joint account", "multi-label", "patient has multiple diagnoses", "weighting", "weighted bridge"

**Business Context:**
- **Banking:** A joint bank account is owned by 2+ customers — a single account balance fact belongs to multiple customers
- **Healthcare:** One patient encounter has multiple diagnosis codes (ICD codes)
- **E-commerce:** A product belongs to multiple categories simultaneously
- **HR:** An employee assigned to multiple cost centers with percentage allocation

**Simple bridge (unweighted):**

```sql
-- An account can have multiple owners; a customer can have multiple accounts
create table bridge_account_customer (
    account_sk      bigint  references dim_account(account_sk),
    customer_sk     bigint  references dim_customer(customer_sk),
    relationship_type varchar(50),   -- 'primary', 'joint', 'beneficiary'
    primary key (account_sk, customer_sk)
);

create table fact_account_balance (
    balance_sk          bigint primary key,
    account_sk          bigint  references dim_account(account_sk),
    snapshot_date_sk    int     references dim_date(date_sk),
    closing_balance     decimal(15,2)
);
```

**Weighted bridge (for M:N with allocation):**

```sql
-- Employee allocated across multiple cost centers with weights summing to 1.0
create table bridge_employee_cost_center (
    employee_sk         bigint  references dim_employee(employee_sk),
    cost_center_sk      bigint  references dim_cost_center(cost_center_sk),
    allocation_weight   decimal(5,4)   not null,  -- e.g., 0.60 and 0.40
    effective_from      date,
    effective_to        date,
    primary key (employee_sk, cost_center_sk, effective_from)
);
```

**Query — distribute salary across cost centers using weights:**

```sql
select
    cc.cost_center_name,
    sum(e.salary * b.allocation_weight) as allocated_salary_cost
from dim_employee e
join bridge_employee_cost_center b on e.employee_sk = b.employee_sk
join dim_cost_center cc on b.cost_center_sk = cc.cost_center_sk
where b.effective_to is null  -- current allocations
group by 1;
```

**Gotchas:**
- When using a bridge table, queries that don't join through the bridge will double/triple count. Every query against the fact must be aware of the bridge.
- Weighted bridges require weights to sum to 1.0 per entity. Add a data quality check for this.
- Bridge tables make sense when M:N is genuine (many-to-many from the business). If a product always has exactly one category, don't add a bridge — a FK on the dimension is enough.

---

### 11-F. Date / Calendar Dimension

**What it solves:** Provides a rich set of date attributes (fiscal periods, holidays, weekday flags) that are pre-computed and reusable across all fact tables. Replaces date functions in SQL with simple WHERE/GROUP BY on attributes.

> **Keywords to spot:** "date dimension", "calendar table", "fiscal year", "business days", "is_holiday", "day of week filtering"

**Full DDL:**

```sql
create table dim_date (
    date_sk             int          primary key,    -- YYYYMMDD as integer, e.g. 20240315
    full_date           date         not null unique,
    day_of_week_num     int,                         -- 1=Monday ... 7=Sunday
    day_of_week_name    varchar(10),                 -- 'Monday'
    day_of_month        int,
    day_of_year         int,
    week_of_year        int,
    month_num           int,
    month_name          varchar(10),
    month_name_short    char(3),
    quarter_num         int,
    quarter_name        char(2),                     -- 'Q1'
    year_num            int,
    year_month          char(7),                     -- 'YYYY-MM'
    year_quarter        char(7),                     -- 'YYYY-Q1'
    is_weekend          boolean      default false,
    is_weekday          boolean      default true,
    is_holiday          boolean      default false,
    holiday_name        varchar(100),
    -- fiscal calendar (company-specific — often offset by some months)
    fiscal_year         int,
    fiscal_quarter      int,
    fiscal_period       int,                         -- fiscal month
    fiscal_week         int,
    fiscal_year_start   date,
    -- useful anchors
    first_day_of_month  date,
    last_day_of_month   date,
    first_day_of_quarter date,
    last_day_of_quarter  date,
    first_day_of_year   date,
    last_day_of_year    date
);

-- The "Unknown" row for NULLs
insert into dim_date (date_sk, full_date, day_of_week_name, month_name)
values (-1, '1900-01-01', 'Unknown', 'Unknown');
```

**Gotchas:**
- Use `int` for `date_sk` in the format YYYYMMDD (e.g., 20240315). It's human-readable, sortable, and lightweight. Avoid using the raw date as the PK — it causes implicit type conversion in some engines.
- Pre-populate the date dimension for at least 20 years forward. Running out of dates mid-year is embarrassing.
- Fiscal calendar logic is company-specific. Build it by parameterizing the fiscal year start month, not by hardcoding.
- The `-1` / "Unknown" row handles NULL date FKs in fact tables gracefully. See Section 21.
