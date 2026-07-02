<!-- data-modelling-patterns: SCD Types 0 through 6 -->

# Slowly Changing Dimensions (SCD Types 0–6)

---

## 12. Slowly Changing Dimensions

**What it solves:** Handles the reality that dimension attributes change over time — and decides how much history (if any) to preserve.

> **Keywords to spot:** "dimension attribute changes", "track history", "customer moved cities", "product price changed", "preserve historical accuracy", "current vs historical"

---

### SCD Type 0 — Immutable

The attribute never changes. If the source value changes, you ignore the update. Used for attributes that should reflect the original value forever.

**Examples:** `date_of_birth`, `original_signup_date`, `account_open_date`, `country_of_origin_at_signup`

```sql
create table dim_customer (
    customer_sk         bigint primary key,
    customer_id         varchar(50)   not null,
    date_of_birth       date          not null,  -- SCD 0: never update this
    original_signup_date date         not null,  -- SCD 0: immutable
    current_email       varchar(255),            -- SCD 1: overwrite
    current_city        varchar(100)             -- SCD 1 or 2 depending on need
);
```

**Gotchas:** SCD 0 requires pipeline discipline — the ETL must explicitly skip updates to these columns. Easy to accidentally overwrite with a blanket `UPDATE SET *`.

---

### SCD Type 1 — Overwrite

The new value overwrites the old. No history is preserved. Use when the old value is simply wrong (a typo corrected) or when history is irrelevant.

**Full logic is covered in `sql_patterns.md` section 13-A.** Summary of the design:

```sql
-- SCD 1 column: just overwrite on change
create table dim_customer (
    customer_sk     bigint primary key,
    customer_id     varchar(50)  not null,
    full_name       varchar(200),
    email           varchar(255),   -- SCD 1: overwrite when changed
    phone           varchar(30)     -- SCD 1: overwrite when changed
);
```

**Gotchas:** Any fact that was loaded while the old value was active will now appear to have been associated with the new value. Historical accuracy is destroyed — intentionally.

---

### SCD Type 2 — Full History (add new row)

A new row is inserted for each change, with effective date range columns and an `is_current` flag. The most important and most commonly asked SCD type.

**Full logic is covered in `sql_patterns.md` section 14.** Summary of the design:

```sql
create table dim_customer (
    customer_sk     bigint primary key,      -- new SK per version
    customer_id     varchar(50) not null,    -- natural key (same across versions)
    full_name       varchar(200),
    city            varchar(100),            -- SCD 2: new row when city changes
    segment         varchar(50),             -- SCD 2: new row when segment changes
    effective_from  date        not null,
    effective_to    date,                    -- NULL means current
    is_current      boolean     default true
);
```

**Key query pattern — join fact to dimension at the right point in time:**

```sql
select
    fs.order_date_sk,
    dc.city,       -- city at the time of the order, not the current city
    sum(fs.revenue)
from fact_sales fs
join dim_customer dc
    on  fs.customer_sk     = dc.customer_sk
    -- No: don't join on is_current = true — that gives current city, not historical
    -- The ETL already wrote the correct customer_sk for the version active at order time
group by 1, 2;
```

**Gotchas:** The ETL that loads fact tables must look up the SK of the dimension version that was current at the time of the event — not the current version. This is the most common SCD 2 implementation bug.

---

### SCD Type 3 — Add Previous Value Column

Adds a `previous_value` column alongside the current value column. Tracks exactly one prior value — no more.

> **Keywords to spot:** "one prior value", "where did the customer move from", "previous segment", "before and after"

```sql
create table dim_customer_scd3 (
    customer_sk             bigint primary key,
    customer_id             varchar(50) not null,
    current_city            varchar(100),
    previous_city           varchar(100),   -- SCD 3: tracks one prior value
    city_changed_at         date,
    current_segment         varchar(50),
    previous_segment        varchar(50),    -- SCD 3
    segment_changed_at      date
);
```

**ETL logic on change:**

```sql
update dim_customer_scd3
set
    previous_city     = current_city,
    current_city      = 'New York',
    city_changed_at   = current_date
where customer_id = 'C-001';
```

**Limitation:** When a second change occurs, the previous value is overwritten — only one level of history is preserved. This pattern supports exactly two states: current and one prior. If a customer moves three times, you only know the current city and the immediately prior city.

**Gotchas:**
- SCD 3 is rarely the right answer. You choose it consciously when: (a) you only ever need one prior value, (b) storage is extremely constrained, (c) the attribute rarely changes. In practice, SCD 2 covers more cases.
- The `*_changed_at` columns are necessary for any temporal analysis. Without them, SCD 3 is just "I added a previous column."

---

### SCD Type 4 — Split into Current + History Table

**What it solves:** Keeps a "hot" current table small and fast, and offloads all history to a separate history table.

> **Keywords to spot:** "separate history table", "audit table", "current plus history", "operational current dimension"

```sql
-- Current table — one row per entity, always the latest version
create table dim_customer_current (
    customer_sk     bigint primary key,
    customer_id     varchar(50)  not null unique,
    full_name       varchar(200),
    city            varchar(100),
    segment         varchar(50),
    updated_at      timestamp
);

-- History table — full audit trail of every version
create table dim_customer_history (
    history_sk      bigint primary key,
    customer_id     varchar(50)  not null,
    full_name       varchar(200),
    city            varchar(100),
    segment         varchar(50),
    effective_from  timestamp    not null,
    effective_to    timestamp,
    change_type     varchar(20)  -- 'insert', 'update', 'delete'
);
```

**Gotchas:**
- SCD 4 is useful when the current table is queried heavily in real-time (OLTP-style reads) and the history table is queried rarely (audits, compliance, analytics).
- The current table has only one row per entity — no `is_current` flag needed.
- Most warehouse implementations skip SCD 4 in favor of SCD 2. SCD 4 shines in hybrid OLTP+OLAP setups.

---

### SCD Type 6 — Hybrid (Type 1 + 2 + 3)

**What it solves:** Combines SCD 2 (full row history via `is_current` flag and date range) with SCD 3 (current value column on every historical row), so you can filter to current-only easily AND see what the current value is even on historical rows.

> **Keywords to spot:** "hybrid SCD", "current value on historical row", "fast current lookup", "SCD 1+2+3 combined"

```sql
create table dim_customer_scd6 (
    customer_sk             bigint primary key,
    customer_id             varchar(50) not null,    -- natural key
    -- SCD 2 columns (full row history)
    city                    varchar(100),            -- value at time of this row's validity
    segment                 varchar(50),             -- value at time of this row's validity
    effective_from          date        not null,
    effective_to            date,
    is_current              boolean     default true,
    -- SCD 3 / Type 1 columns (current value stamped on ALL rows)
    current_city            varchar(100),            -- always = current row's city
    current_segment         varchar(50)              -- always = current row's segment
);
```

**How it looks with 3 versions:**

| customer_sk | customer_id | city       | effective_from | effective_to | is_current | current_city |
|---|---|---|---|---|---|---|
| 101 | C-001 | Chicago    | 2022-01-01 | 2023-05-14 | false | Boston |
| 102 | C-001 | New York   | 2023-05-15 | 2024-08-20 | false | Boston |
| 103 | C-001 | Boston     | 2024-08-21 | NULL | true | Boston |

Historical rows still carry `current_city = 'Boston'`. You can ask: "What is every customer's current city, but show me all their historical transactions?" — just join on `customer_id` and use `current_city`.

**Gotchas:**
- SCD 6 doubles the maintenance cost: when a change happens, you insert a new row AND update `current_*` columns on ALL prior rows for that entity. ETL must do a bulk update on history rows.
- The name "Type 6" comes from 1 + 2 + 3 = 6. It's a memorable convention, not an official standard.
- SCD 6 is the right answer when both questions need to be answered efficiently: "what was the value then?" AND "what is the current value?"
