<!-- data-modelling-patterns: Data Modelling Patterns for Data Engineer Interviews -->

# Data Modelling Patterns for Data Engineer Interviews
**Your go-to revision guide — patterns, schema design, and business context**
**Applicable for any data engineering interview — fintech, e-commerce, SaaS, logistics, healthcare**

---

## Table of Contents

### Part 1 — Foundations
- [How to Use This Guide](#how-to-use-this-guide)
- [What is Data Modelling?](#what-is-data-modelling)
- [OLTP vs OLAP](#oltp-vs-olap)
- [ETL vs ELT](#etl-vs-elt)
- [Extraction Patterns](#extraction-patterns)
- [Load Strategies](#load-strategies)
- [Batch vs Micro-Batch vs Streaming](#batch-vs-micro-batch-vs-streaming)
- [Keys: Natural, Surrogate, Composite, Foreign](#keys)
- [Cardinality and Relationships](#cardinality-and-relationships)

### Part 2 — Normalization (OLTP)
1. [First Normal Form (1NF)](#1-first-normal-form-1nf)
2. [Second Normal Form (2NF)](#2-second-normal-form-2nf)
3. [Third Normal Form (3NF)](#3-third-normal-form-3nf)
4. [Boyce-Codd Normal Form (BCNF)](#4-boyce-codd-normal-form-bcnf)
5. [Denormalization](#5-denormalization)

### Part 3 — Dimensional Modelling (Kimball)
6. [Grain Definition](#6-grain-definition)
7. [Star Schema](#7-star-schema)
8. [Snowflake Schema](#8-snowflake-schema)
9. [Galaxy Schema (Constellation)](#9-galaxy-schema-constellation)
10. [Fact Table Types](#10-fact-table-types)
    - [10-A. Transaction Fact](#10-a-transaction-fact)
    - [10-B. Periodic Snapshot Fact](#10-b-periodic-snapshot-fact)
    - [10-C. Accumulating Snapshot Fact](#10-c-accumulating-snapshot-fact)
    - [10-D. Factless Fact](#10-d-factless-fact)
11. [Dimension Table Types](#11-dimension-table-types)
    - [11-A. Conformed Dimensions](#11-a-conformed-dimensions)
    - [11-B. Junk Dimensions](#11-b-junk-dimensions)
    - [11-C. Role-Playing Dimensions](#11-c-role-playing-dimensions)
    - [11-D. Degenerate Dimensions](#11-d-degenerate-dimensions)
    - [11-E. Bridge Tables](#11-e-bridge-tables-many-to-many)
    - [11-F. Date / Calendar Dimension](#11-f-date--calendar-dimension)
12. [Slowly Changing Dimensions (SCD 0/1/2/3/4/6)](#12-slowly-changing-dimensions)

### Part 4 — Modern Stack Patterns
13. [Medallion Architecture](#13-medallion-architecture)
14. [One Big Table (OBT)](#14-one-big-table-obt)
15. [Data Vault 2.0](#15-data-vault-20)

### Part 5 — Design Decisions and Edge Cases
16. [Choosing the Right Model](#16-choosing-the-right-model)
17. [Fan-out Trap (Chasm Trap)](#17-fan-out-trap-chasm-trap)
18. [Many-to-Many Relationships](#18-many-to-many-relationships)
19. [Hierarchies](#19-hierarchies)
20. [Late Arriving Facts](#20-late-arriving-facts)
21. [NULL Handling in Dimensional Models](#21-null-handling-in-dimensional-models)
22. [Performance Considerations](#22-performance-considerations)

### Part 6 — Quick Reference
- [Model Selection Decision Tree](#model-selection-decision-tree)
- [Fact Table Type Cheat Sheet](#fact-table-type-cheat-sheet)
- [Dimension Type Cheat Sheet](#dimension-type-cheat-sheet)
- [SCD Type Comparison Table](#scd-type-comparison-table)
- [Interview Keywords → Pattern Mapping](#interview-keywords--pattern-mapping)

---

# Part 1 — Foundations

---

## How to Use This Guide

Every section follows this structure:
1. **What it solves** — the problem this pattern addresses
2. **Keywords to spot** — trigger phrases in interview questions that tell you which pattern applies
3. **Business context** — real-world scenarios per industry
4. **Schema/DDL** — `CREATE TABLE` statements showing the physical design
5. **Gotchas** — opinionated, experience-based traps to avoid

SCD Type 1 and Type 2 SQL logic (merge statements, incremental loading) are covered in `sql_patterns.md` sections 13-A and 14. This guide focuses on the modelling design decisions, DDL structure, and when to apply each pattern.

---

## What is Data Modelling?

Data modelling is the process of defining the structure, relationships, and constraints of data — before you write a single pipeline. A model is a contract between the data producer and the data consumer.

There are three levels:

| Level | Question it answers | Who owns it |
|---|---|---|
| **Conceptual** | What entities exist and how do they relate? | Business analyst / architect |
| **Logical** | What attributes does each entity have? What are the relationships (PK/FK)? | Data engineer / architect |
| **Physical** | Which table names, data types, indexes, partitions? Which engine? | Data engineer |

A conceptual model is an entity-relationship diagram (ERD) with no data types. A logical model adds attributes and keys but no engine-specific syntax. A physical model is the actual DDL you run.

**Interview trap:** Interviewers often ask "walk me through how you'd model X." Start at conceptual (what are the entities?), move to logical (what are the grain, relationships, facts, dims?), then physical (DDL, partitioning). Skipping to DDL immediately signals you don't think about design.

---

## OLTP vs OLAP

> **Keywords to spot:** "transactional system", "operational database", "reporting database", "write-heavy", "read-heavy", "real-time vs analytical"

| Dimension | OLTP | OLAP |
|---|---|---|
| Purpose | Record business transactions | Analyse business data |
| Query type | Short reads/writes, point lookups | Long scans, aggregations |
| Data volume per query | Few rows | Millions–billions of rows |
| Schema style | Normalized (3NF) | Denormalized (star/snowflake) |
| Update frequency | Constant (inserts/updates/deletes) | Batch loads or micro-batch |
| Users | Application code, APIs | Analysts, BI tools, notebooks |
| Optimized for | Write throughput, data integrity | Read throughput, query speed |
| Example systems | PostgreSQL, MySQL, Oracle | Snowflake, BigQuery, Redshift, Databricks |
| Joins | Many, small | Few, wide |
| Indexes | Many narrow indexes | Clustered on partition/sort keys |

**Key insight:** You don't replace OLTP with OLAP — you replicate data from OLTP into OLAP. The source of truth for a transaction is still the OLTP system. The warehouse is a read-optimized copy.

---

## ETL vs ELT

> **Keywords to spot:** "ETL pipeline", "ELT", "transform before load", "dbt", "raw layer", "staging", "why not ETL", "transform inside the warehouse"

**ETL — Extract, Transform, Load**

Data is extracted from sources, transformed on a separate processing server (Spark cluster, dedicated ETL tool), and only the clean output is loaded into the warehouse. The warehouse never sees raw data.

```
Source Systems → [Extract] → [Transform on external compute] → [Load clean data] → Warehouse
```

**ELT — Extract, Load, Transform**

Raw data is loaded directly into the warehouse first. Transformations run inside the warehouse using its own compute engine (SQL, dbt models, Snowflake tasks).

```
Source Systems → [Extract] → [Load raw data] → Warehouse → [Transform using warehouse SQL]
```

**Why ELT dominates modern cloud stacks:**

| Factor | ETL | ELT |
|---|---|---|
| Transformation location | External compute (Spark, SSIS, Informatica) | Inside the warehouse (SQL) |
| Raw data visibility | Never stored — transformation is a black box | Always available in Bronze/raw layer |
| Reprocessing | Must re-run external jobs | Just re-run the SQL from raw |
| Scaling | Must provision separate transformation cluster | Warehouse scales elastically on demand |
| Tooling | Talend, Informatica, SSIS, Pentaho | dbt + Snowflake/BigQuery/Redshift |
| Schema changes | Pipeline redesign required | Run new SQL against existing raw data |
| Debugging | Hard — data is transformed before you can inspect it | Easy — raw data is always there |

The shift to ELT happened because cloud warehouses (Snowflake, BigQuery, Redshift) made compute elastic and cheap. There's no longer a reason to pre-transform on a separate server — the warehouse can do it faster and more flexibly. dbt is the dominant ELT transformation framework: it's pure SQL, version-controlled, tested, and runs entirely inside the warehouse.

**When ETL is still the right choice:**
- Strict compliance requirements where PII must be masked or hashed **before** it touches any storage (e.g., HIPAA — raw records can never be stored unmasked)
- Source systems with extreme data volumes that would overwhelm even a warehouse's raw layer
- Proprietary transformation logic that cannot be expressed in SQL

**Gotchas:**
- ELT requires a raw/Bronze layer that holds untransformed data. Without it, you lose the ability to reprocess when a transformation bug is found.
- "ETL" is still used loosely in conversation to mean any data pipeline. When an interviewer says "our ETL," they may mean ELT. Don't correct them — understand the context.
- dbt is a transformation tool, not an extraction tool. Fivetran, Airbyte, and Stitch handle the Extract+Load part; dbt handles the Transform.

---

## Extraction Patterns

> **Keywords to spot:** "how do you get data from the source", "incremental load", "CDC", "change data capture", "watermark", "full pull", "delta load", "out of order data"

### Full Extraction

Pull every row from the source table on every run. Simple. Correct. Expensive at scale.

```sql
-- Every pipeline run: SELECT * FROM source table
SELECT * FROM source.orders;
```

**When it's appropriate:** Small tables (< 1M rows), tables with no reliable update timestamp, initial historical loads, or dimension tables that change infrequently.

**Gotcha:** A 500M-row orders table with a full pull on every run will eventually become unaffordable. Design for incremental from day one on large tables.

---

### Incremental Extraction — Watermark / High-Water Mark

Track a marker (timestamp or sequential ID) representing the last successfully processed record. Each run fetches only rows newer than the last marker.

```sql
-- Metadata table tracking the last run watermark
CREATE TABLE pipeline_watermarks (
    pipeline_name   VARCHAR(100) PRIMARY KEY,
    last_loaded_at  TIMESTAMP,
    last_loaded_id  BIGINT
);

-- Extract only new/changed rows
SELECT *
FROM source.orders
WHERE updated_at > (
    SELECT last_loaded_at
    FROM pipeline_watermarks
    WHERE pipeline_name = 'orders_incremental'
);

-- After successful load, advance the watermark
UPDATE pipeline_watermarks
SET last_loaded_at = CURRENT_TIMESTAMP
WHERE pipeline_name = 'orders_incremental';
```

**Requirements:**
- Source table must have a reliable `updated_at` or `created_at` timestamp, or a monotonically increasing integer ID
- The column must be indexed on the source — otherwise each incremental pull becomes a full scan anyway

**Critical limitation:** Watermark-based extraction **cannot detect hard deletes**. If a row is deleted from the source, the watermark query will never see it because it queries for rows where `updated_at > watermark` — deleted rows no longer exist. To detect deletes, you need CDC or a periodic full reconciliation count.

---

### CDC — Change Data Capture

CDC captures every INSERT, UPDATE, and DELETE from the source database as it happens, by reading the database's internal transaction log rather than querying the data itself.

**Three CDC approaches:**

**1. Log-Based CDC (preferred)**

Reads from the database's write-ahead log (WAL in PostgreSQL, redo log in Oracle, binary log in MySQL). Every committed change is captured in the exact order it occurred, including deletes.

```
Source DB → Transaction Log → CDC Tool (Debezium, Fivetran) → Message Queue (Kafka) → Warehouse
```

| Property | Detail |
|---|---|
| Latency | Near real-time (seconds) |
| Source impact | Minimal — reads log, not production tables |
| Captures deletes | Yes |
| Captures column-level changes | Yes (old value + new value) |
| Complexity | High (log access requires elevated privileges, replication slot management) |
| Tools | Debezium, AWS DMS, Fivetran |

**2. Trigger-Based CDC**

Database triggers fire on INSERT/UPDATE/DELETE and write a copy of the changed row to a shadow/audit table.

```sql
-- Trigger writes every change to an audit table
CREATE TRIGGER orders_cdc
AFTER INSERT OR UPDATE OR DELETE ON source.orders
FOR EACH ROW EXECUTE FUNCTION log_order_change();
```

| Property | Detail |
|---|---|
| Latency | Low |
| Source impact | **High** — every write triggers an additional write (write amplification) |
| Captures deletes | Yes |
| Complexity | Medium |
| When to use | When log access is unavailable (managed cloud DBs) |

**Gotcha:** On high-throughput OLTP tables (thousands of writes/second), trigger-based CDC can degrade source database performance significantly. Don't use it on hot tables.

**3. Polling-Based CDC**

Periodically queries the source table for rows where `updated_at > last_poll_time`. The simplest approach — essentially a scheduled watermark query.

| Property | Detail |
|---|---|
| Latency | Depends on poll frequency (minutes to hours) |
| Source impact | Medium — runs a query on each poll cycle |
| Captures deletes | **No** — deleted rows are gone |
| Complexity | Low |
| When to use | Low-change tables, loose freshness requirements, when log/trigger access is impossible |

**CDC comparison:**

| | Log-Based | Trigger-Based | Polling |
|---|---|---|---|
| Captures deletes | ✅ | ✅ | ❌ |
| Source performance impact | ✅ Minimal | ❌ High | Medium |
| Latency | ✅ Seconds | ✅ Seconds | ❌ Minutes–Hours |
| Implementation complexity | ❌ High | Medium | ✅ Low |
| Schema change handling | Complex | Brittle | Simple |

---

### Idempotency

**Definition:** A pipeline is idempotent if running it once or running it ten times produces exactly the same result. No duplicate rows, no phantom deletes, no partial state.

**Why it matters:** Pipelines fail. Networks time out. Clusters crash mid-run. If re-running a failed pipeline inserts rows a second time or corrupts partially loaded state, you have a data integrity problem that is hard to detect and expensive to fix.

**Implementation patterns:**

```sql
-- Pattern 1: MERGE (upsert) — idempotent by definition
-- Running this 3 times produces the same result as running it once
MERGE INTO target.orders AS t
USING staging.orders_delta AS s
    ON t.order_id = s.order_id
WHEN MATCHED AND s.updated_at > t.updated_at THEN
    UPDATE SET
        t.status       = s.status,
        t.total_amount = s.total_amount,
        t.updated_at   = s.updated_at
WHEN NOT MATCHED THEN
    INSERT (order_id, customer_id, status, total_amount, created_at, updated_at)
    VALUES (s.order_id, s.customer_id, s.status, s.total_amount, s.created_at, s.updated_at);

-- Pattern 2: DELETE partition + INSERT (idempotent for partitioned fact tables)
-- Delete yesterday's partition, then reload it cleanly
DELETE FROM fact_orders WHERE order_date = '2024-11-15';
INSERT INTO fact_orders SELECT ... FROM silver.orders WHERE order_date = '2024-11-15';

-- Pattern 3: CREATE OR REPLACE (for full-refresh tables)
CREATE OR REPLACE TABLE gold.dim_product AS
SELECT ... FROM silver.products;
```

**Non-idempotent pattern to avoid:**

```sql
-- BAD: append-only load with no deduplication
-- Running twice loads every row twice
INSERT INTO fact_orders
SELECT * FROM staging.orders_delta;
```

**Gotchas:**
- MERGE is the most robust idempotent pattern but requires a natural key to match on. Without a reliable natural key, MERGE breaks.
- Partition replace (DELETE + INSERT) is faster than MERGE for large fact table partitions and is idempotent as long as you delete before inserting. Inserting before deleting is not idempotent.
- Append-only pipelines (for raw/Bronze tables) are intentionally not idempotent. Bronze is the one layer where duplicates are acceptable — deduplication happens in Silver.

---

## Load Strategies

> **Keywords to spot:** "full refresh", "incremental", "upsert", "append", "truncate and reload", "how often does the pipeline run", "how do you handle updates"

| Strategy | How it works | When to use | Risk |
|---|---|---|---|
| **Full refresh** | Truncate target, reload everything | Small/medium tables, dim tables, when source has no timestamp | Expensive at scale, window of empty table during load |
| **Append-only** | INSERT new rows, never update/delete | Immutable event logs, Bronze/raw layer, transaction facts | Duplicates if pipeline re-runs without deduplication |
| **Incremental (watermark)** | Load rows where `updated_at > last_run` | Large tables with reliable timestamps | Misses hard deletes |
| **Upsert / MERGE** | Update matching rows, insert new rows | Dimension tables, SCD 1, any table with natural key and updates | Requires a join key; slower than append on large tables |
| **Partition replace** | Delete a partition, insert fresh data for that partition | Large partitioned fact tables (e.g., yesterday's data) | Must delete before insert; wrong partition filter = data loss |

**dbt materializations map directly to these strategies:**

| dbt materialization | Load strategy equivalent |
|---|---|
| `table` | Full refresh — recreates the table on every run |
| `view` | No load — queries run through on demand |
| `incremental` | Incremental (watermark or partition replace) |
| `snapshot` | SCD Type 2 — tracks changes using `updated_at` and `strategy: timestamp` or `strategy: check` |

**Gotchas:**
- Full refresh on a 10B-row fact table is not viable. Design incremental from the start for large tables.
- `CREATE OR REPLACE` (full refresh) leaves the table momentarily empty during the build. For production-critical tables, use `CREATE TABLE ... AS SELECT` into a new name then `SWAP` — Snowflake's zero-downtime swap. BigQuery has the same pattern.
- dbt incremental models append new rows by default. To handle updates to existing rows, add a `unique_key` config so dbt generates a MERGE instead.

---

## Batch vs Micro-Batch vs Streaming

> **Keywords to spot:** "real-time", "near real-time", "latency requirements", "Kafka", "Spark Streaming", "Flink", "how fresh is the data", "T+1", "event-driven"

| | Batch | Micro-Batch | Streaming |
|---|---|---|---|
| **Processing interval** | Hours / daily | Seconds to minutes | Milliseconds to seconds |
| **Latency** | T+1 or longer | Near real-time | Real-time |
| **Frameworks** | Spark, dbt, SQL jobs | Spark Structured Streaming, Databricks Auto Loader | Apache Flink, Kafka Streams, Kinesis |
| **Complexity** | Low | Medium | High |
| **State management** | None needed | Managed by framework | Complex (exactly-once, windowing) |
| **Use cases** | Nightly ETL, financial reports, dimensional models | Near-real-time dashboards, fraud scoring with minutes of tolerance | Real-time fraud detection, live dashboards, event-driven pipelines |
| **Cost** | Low (runs once) | Medium (continuous cluster) | High (always-on infrastructure) |

**The nuance with Spark Streaming:** Despite the name, Spark Structured Streaming processes data in micro-batches under the hood — it does not process events one-at-a-time. True event-by-event streaming requires Flink or Kafka Streams. For most analytics use cases, the difference doesn't matter (both feel "near real-time"). It matters for ordering guarantees and exactly-once semantics.

**Data freshness SLAs:**

| Term | What it means |
|---|---|
| **T+1** | Data from today is available by tomorrow morning — batch, nightly run |
| **T+4H** | Data is available within 4 hours of the event — micro-batch |
| **Near real-time** | Data available within minutes — micro-batch or fast batch |
| **Real-time** | Data available within seconds — streaming |

**Gotchas:**
- Don't default to streaming because it sounds impressive. If the business question is answered with yesterday's data, batch is cheaper, simpler, and more reliable. Match the architecture to the SLA.
- Streaming pipelines require handling late-arriving events (watermarks in Flink/Spark), out-of-order events, and exactly-once delivery guarantees. Each adds complexity. Batch has none of these concerns.
- Most data warehouses (Snowflake, BigQuery) are optimized for batch or micro-batch loads, not continuous streaming inserts. Streaming into a warehouse typically goes through a buffer (Kafka → Snowpipe or BigQuery Streaming API) that batches internally anyway.

---

## Keys

> **Keywords to spot:** "unique identifier", "business key", "natural key", "surrogate key", "composite key", "foreign key", "referential integrity"

### Natural Key
A key that exists in the real world and already uniquely identifies an entity. Examples: SSN, email address, ISBN, IATA airport code, VIN.

**Gotcha:** Natural keys change. Customers change email. Companies change legal name. If you use a natural key as a PK, every FK referencing it must be updated too. This is why warehouses use surrogate keys.

### Surrogate Key
A system-generated integer (or hash) with no business meaning. Used as the PK in dimensional models.

```sql
create table dim_customer (
    customer_sk     bigint        primary key,   -- surrogate key
    customer_id     varchar(50)   not null,      -- natural/business key
    full_name       varchar(200),
    email           varchar(255)
);
```

The surrogate key (`customer_sk`) is what fact tables reference. The natural key (`customer_id`) is preserved for traceability but is not the join key.

**Gotcha:** In SCD Type 2, a single customer_id maps to multiple `customer_sk` values (one per version). This is intentional — it's how you join a fact to the right version of the dimension that was active at the time of the event.

### Composite Key
A primary key made up of two or more columns. Common in junction/bridge tables and normalized OLTP schemas.

```sql
create table order_product (
    order_id    int  not null,
    product_id  int  not null,
    quantity    int  not null,
    primary key (order_id, product_id)
);
```

**Gotcha:** Composite PKs are fine in OLTP. In dimensional models, avoid them on fact tables — use a surrogate PK instead, and define uniqueness via unique constraints or documentation. Composite PKs on large fact tables complicate incremental loading.

### Foreign Key
A column (or set of columns) that references the PK of another table, enforcing referential integrity.

```sql
create table fact_order (
    order_sk        bigint  primary key,
    customer_sk     bigint  references dim_customer(customer_sk),
    product_sk      bigint  references dim_product(product_sk),
    order_date_sk   int     references dim_date(date_sk),
    revenue         decimal(12,2)
);
```

**Gotcha:** Most cloud warehouses (Snowflake, BigQuery, Redshift) don't enforce FK constraints at insert time — they are "informational only." Your pipeline must guarantee referential integrity. Don't rely on the database to catch orphaned FK values.

---

## Cardinality and Relationships

> **Keywords to spot:** "one-to-many", "many-to-many", "parent-child", "junction table", "bridge table", "M:N relationship"

### One-to-One (1:1)
Rare. One row in table A maps to exactly one row in table B. Example: employee and their assigned laptop (if every employee has exactly one, and every laptop is assigned to one).

Use case: Split a wide table into two for security (PII separation) or performance.

```
employee ──── employee_pii
  (1)             (1)
```

### One-to-Many (1:N)
The most common relationship. One row in table A maps to many rows in table B. Example: one customer → many orders.

```
customer ────< order
  (1)            (N)
```

In SQL: the FK lives on the "many" side.

```sql
create table orders (
    order_id    int primary key,
    customer_id int references customers(customer_id),  -- FK on the N side
    order_date  date
);
```

### Many-to-Many (M:N)
One row in A maps to many rows in B, and one row in B maps to many rows in A. Example: students enroll in many courses; courses have many students.

Implemented via a **bridge/junction table**:

```
student ────< enrollment >──── course
  (1)            (M:N)           (1)
```

```sql
create table enrollment (
    student_id  int  references students(student_id),
    course_id   int  references courses(course_id),
    enrolled_at date,
    primary key (student_id, course_id)
);
```

**Gotcha:** M:N relationships are the #1 source of fan-out (row multiplication) bugs in dimensional models. See Section 17.

---

# Part 2 — Normalization (OLTP)

---

## 1. First Normal Form (1NF)

**What it solves:** Eliminates repeating groups and non-atomic values. Ensures every cell holds a single value, and every row is uniquely identifiable.

> **Keywords to spot:** "repeating groups", "comma-separated values in a column", "array in a cell", "multi-valued attribute", "flatten", "atomicity"

**Business Context:**
- **E-commerce:** An `orders` table storing `product_ids = "101,102,103"` in one column
- **HR:** An `employees` table with `phone1`, `phone2`, `phone3` columns instead of a separate `employee_phones` table
- **Healthcare:** A `patient` table storing `allergies = "penicillin, latex, ibuprofen"` in one varchar field

**Violation — before 1NF:**

```sql
-- BAD: storing multiple products in one column
create table orders_bad (
    order_id    int primary key,
    customer_id int,
    product_ids varchar(200),   -- "101,102,103" — NOT atomic
    order_date  date
);
```

**Fixed — 1NF:**

```sql
-- Parent order table
create table orders (
    order_id    int primary key,
    customer_id int,
    order_date  date
);

-- Child line items — each row is one product on one order
create table order_line_items (
    order_id    int  references orders(order_id),
    product_id  int,
    quantity    int,
    unit_price  decimal(10,2),
    primary key (order_id, product_id)
);
```

**Gotchas:**
- JSON/ARRAY columns in modern databases (Snowflake VARIANT, BigQuery ARRAY, Postgres JSONB) technically violate 1NF, but are acceptable in OLAP schemas where you control the querying layer. In OLTP, avoid them as primary storage.
- "Repeating groups" means both comma-separated values AND multiple numbered columns (`tag1`, `tag2`, `tag3`). Both violate 1NF.
- A table with no PK or a PK that is ambiguous also violates 1NF — you need a way to uniquely identify every row.

---

## 2. Second Normal Form (2NF)

**What it solves:** Eliminates partial dependencies. Every non-key attribute must depend on the **whole** primary key, not just part of it. Only applies to tables with composite primary keys.

> **Keywords to spot:** "partial dependency", "composite key", "attribute depends on part of the key", "redundant data in junction table"

**Business Context:**
- **E-commerce:** Order-product junction table storing `product_name` — product name depends only on `product_id`, not on `(order_id, product_id)`
- **SaaS:** User-role table storing `role_description` — description depends only on `role_id`
- **Logistics:** Shipment-item table storing `warehouse_address` — address depends on `warehouse_id`, not the composite key

**Violation — 1NF but not 2NF:**

```sql
-- Composite PK is (order_id, product_id)
-- product_name depends ONLY on product_id — partial dependency!
create table order_items_bad (
    order_id        int,
    product_id      int,
    product_name    varchar(200),   -- depends only on product_id — VIOLATION
    quantity        int,
    unit_price      decimal(10,2),
    primary key (order_id, product_id)
);
```

**Fixed — 2NF:**

```sql
-- product_name belongs in the products table
create table products (
    product_id      int primary key,
    product_name    varchar(200),
    category        varchar(100)
);

-- order_items only stores what depends on the full composite key
create table order_items (
    order_id    int,
    product_id  int  references products(product_id),
    quantity    int,
    unit_price  decimal(10,2),
    primary key (order_id, product_id)
);
```

**Gotchas:**
- 2NF violations only occur with composite PKs. A table with a single-column PK that satisfies 1NF automatically satisfies 2NF.
- Interviewers test this by asking: "If the product name changes, how many rows need updating?" The answer should always be one row in one table, not N rows scattered across a junction table.
- `unit_price` stays in `order_items` even though `product` has a price — the price at time of order is a fact about the order-product relationship, not just the product. This is a deliberate 2NF-compliant design choice.

---

## 3. Third Normal Form (3NF)

**What it solves:** Eliminates transitive dependencies. Every non-key attribute must depend directly on the PK — not on another non-key attribute.

> **Keywords to spot:** "transitive dependency", "attribute depends on another non-key column", "redundant lookup data embedded in table", "department name stored on employee row"

**Business Context:**
- **HR:** `employees` table storing both `dept_id` and `dept_name` — `dept_name` depends on `dept_id`, not on `emp_id`
- **E-commerce:** `orders` table storing `customer_city` and `customer_zip` — city depends on zip, not on order_id
- **SaaS:** `subscriptions` table storing `plan_id` and `plan_monthly_cost` — cost depends on plan, not on subscription

**Violation — 2NF but not 3NF:**

```sql
-- dept_name depends on dept_id, which depends on emp_id
-- dept_name -> dept_id -> emp_id: that's a transitive dependency
create table employees_bad (
    emp_id      int primary key,
    emp_name    varchar(100),
    dept_id     int,
    dept_name   varchar(100),   -- VIOLATION: depends on dept_id, not emp_id
    salary      decimal(10,2)
);
```

**Fixed — 3NF:**

```sql
create table departments (
    dept_id     int primary key,
    dept_name   varchar(100) not null
);

create table employees (
    emp_id      int primary key,
    emp_name    varchar(100),
    dept_id     int  references departments(dept_id),
    salary      decimal(10,2)
);
```

**Iterative build — adding more depth:**

A 3NF schema naturally grows into a web of normalized tables. Here's what a 3NF HR schema looks like:

```
departments ────< employees >──── employee_roles
     |                                   |
     |                               role_types
     |
  locations
```

```sql
create table locations (
    location_id int primary key,
    city        varchar(100),
    country     varchar(100)
);

create table departments (
    dept_id     int primary key,
    dept_name   varchar(100),
    location_id int  references locations(location_id)
);

create table role_types (
    role_type_id    int primary key,
    role_name       varchar(100),
    grade_band      varchar(20)
);

create table employees (
    emp_id          int primary key,
    emp_name        varchar(100),
    dept_id         int  references departments(dept_id),
    role_type_id    int  references role_types(role_type_id),
    hire_date       date,
    salary          decimal(10,2)
);
```

**Gotchas:**
- 3NF is the target for OLTP. It minimizes update anomalies — when a department name changes, you update one row in `departments`, not thousands of employee rows.
- In analytical models, you deliberately denormalize back (see Section 5 and Section 8). The normalization journey exists so you understand what you're trading away.
- "3NF" is often used loosely to mean "well-normalized." In interviews, saying "I'd normalize this to 3NF for the operational layer, then denormalize into a star schema for analytics" is the right frame.

---

## 4. Boyce-Codd Normal Form (BCNF)

**What it solves:** A stricter version of 3NF. Eliminates anomalies that 3NF misses when a table has multiple overlapping candidate keys.

> **Keywords to spot:** "overlapping candidate keys", "functional dependency from non-prime attribute", "BCNF violation", "stricter than 3NF"

**The rule:** For every functional dependency X → Y, X must be a superkey. In 3NF you allowed non-superkey determinants as long as Y is a prime attribute. BCNF removes that exception.

**When does this come up?**

Rare in practice. The classic example: a table where an instructor can teach only one subject, but a subject can have multiple instructors, and a student can be in only one section per subject.

```sql
-- Candidate keys: (student, subject) and (student, instructor)
-- instructor -> subject is a functional dependency where instructor is NOT a superkey
-- This violates BCNF even though it may satisfy 3NF
create table enrollment_bad (
    student_id      int,
    instructor_id   int,
    subject         varchar(100),
    primary key (student_id, subject)  -- one of the candidate keys
    -- instructor -> subject dependency violates BCNF
);
```

**Fixed — BCNF:**

```sql
-- Split into two tables: instructor-subject assignment + student-instructor enrollment
create table instructor_subjects (
    instructor_id   int primary key,
    subject         varchar(100)
);

create table student_instructors (
    student_id      int,
    instructor_id   int  references instructor_subjects(instructor_id),
    primary key (student_id, instructor_id)
);
```

**Gotchas:**
- BCNF decomposition can lose some functional dependencies — you sometimes can't enforce a constraint without a multi-table check. This is the known trade-off.
- In data warehouse interviews, BCNF rarely comes up. It matters more in OLTP / database theory interviews. Know the concept, know the classic example, don't over-engineer.
- Most practical 3NF schemas are already BCNF compliant. BCNF violations only appear when you have multiple overlapping candidate keys.

---

## 5. Denormalization

**What it solves:** Deliberately reintroduces redundancy to improve read performance. Used when normalized schemas are too slow to query at scale.

> **Keywords to spot:** "read performance", "too many joins", "flatten", "pre-join", "analytical workload", "reporting table", "wide table", "materialized"

**Business Context:**
- **E-commerce:** Flatten order + customer + product into a single `orders_enriched` table so BI tools don't need 5-way joins
- **SaaS:** Pre-join subscription + plan + account into one table for dashboard queries
- **Fintech:** Combine transaction + account + customer into a reporting table refreshed nightly
- **Healthcare:** Pre-aggregate patient encounter data with demographics for population health dashboards

**Base — normalized (3NF):**

```sql
create table orders (order_id int primary key, customer_id int, order_date date, total decimal(12,2));
create table customers (customer_id int primary key, name varchar(200), city varchar(100), segment varchar(50));
create table order_items (order_id int, product_id int, qty int, unit_price decimal(10,2));
create table products (product_id int primary key, name varchar(200), category varchar(100));
```

**Denormalized — analytical reporting table:**

```sql
create table orders_enriched (
    order_id            int,
    order_date          date,
    order_total         decimal(12,2),
    customer_id         int,
    customer_name       varchar(200),
    customer_city       varchar(100),
    customer_segment    varchar(50),
    product_id          int,
    product_name        varchar(200),
    product_category    varchar(100),
    line_qty            int,
    line_revenue        decimal(12,2)
    -- grain: one row per order line item
);
```

**Gotchas:**
- Denormalization is a deliberate, documented choice — not a mistake. Always note the grain and which source tables it's derived from.
- Update anomalies return. If a customer's segment changes, every row for that customer in the denormalized table is stale until the next load. Your pipeline must handle this.
- Don't denormalize prematurely. Normalize first, measure query performance, then denormalize the specific joins that are bottlenecks.
- Denormalization ≠ the same as OBT. OBT (Section 14) is an extreme form — one row per entity with all attributes. Denormalization is a spectrum.

---

# Part 3 — Dimensional Modelling (Kimball)

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

---

## 9. Galaxy Schema (Constellation)

**What it solves:** Multiple fact tables sharing conformed dimension tables. The natural shape of a mature data warehouse.

> **Keywords to spot:** "multiple fact tables", "shared dimensions", "enterprise data warehouse", "conformed dimensions", "cross-subject-area analysis"

**Business Context:**
- **Retail:** `fact_sales` and `fact_inventory` both reference `dim_product`, `dim_store`, `dim_date`
- **Fintech:** `fact_transactions` and `fact_account_balances` both reference `dim_account`, `dim_date`
- **SaaS:** `fact_user_events` and `fact_subscriptions` both reference `dim_user`, `dim_date`, `dim_plan`

**Schema diagram:**

```
dim_date ────< fact_sales >──── dim_product ────< fact_inventory
                  |                                      |
              dim_store ─────────────────────────────────┘
              dim_customer
```

**DDL — two fact tables sharing conformed dimensions:**

```sql
-- Shared dimensions (already defined in Section 7)
-- dim_date, dim_product, dim_store

create table fact_sales (
    sales_sk        bigint primary key,
    order_date_sk   int     references dim_date(date_sk),
    product_sk      bigint  references dim_product(product_sk),
    store_sk        bigint  references dim_store(store_sk),
    customer_sk     bigint  references dim_customer(customer_sk),
    quantity_sold   int,
    revenue         decimal(12,2)
);

create table fact_inventory (
    inventory_sk    bigint primary key,
    snapshot_date_sk int    references dim_date(date_sk),
    product_sk      bigint  references dim_product(product_sk),
    store_sk        bigint  references dim_store(store_sk),
    -- grain: one row per product per store per day
    units_on_hand   int,
    units_on_order  int,
    reorder_flag    boolean
);
```

**Cross-fact analysis:**

The power of conformed dimensions is that you can join across fact tables:

```sql
-- Sell-through rate: how much of inventory was sold?
select
    d.full_date,
    p.product_name,
    s.store_name,
    sum(fs.quantity_sold)           as units_sold,
    avg(fi.units_on_hand)           as avg_inventory,
    sum(fs.quantity_sold) * 1.0
        / nullif(avg(fi.units_on_hand), 0) as sell_through_rate
from fact_sales fs
join fact_inventory fi
    on  fs.product_sk      = fi.product_sk
    and fs.store_sk        = fi.store_sk
    and fs.order_date_sk   = fi.snapshot_date_sk
join dim_date d    on fs.order_date_sk = d.date_sk
join dim_product p on fs.product_sk    = p.product_sk
join dim_store s   on fs.store_sk      = s.store_sk
group by 1, 2, 3;
```

**Gotchas:**
- Cross-fact joins are only safe when the grains are compatible (or you aggregate the finer grain first). Joining `fact_sales` at line-item grain directly to `fact_inventory` at daily-product-store grain without aggregation will inflate counts. See Section 17 on fan-out.
- "Galaxy schema" is just a name for the natural end-state of a data warehouse. You don't design for galaxy from day one — you design each subject area as a star, and the galaxy emerges.

---

## 10. Fact Table Types

---

### 10-A. Transaction Fact

**What it solves:** Records a discrete business event at the moment it happens. The most common fact table type.

> **Keywords to spot:** "each transaction", "event log", "append-only", "point in time", "never updated after load"

**When to use:** When the business process produces discrete events — purchases, clicks, payments, logins, shipments.

**Business scenario:** Each row is one payment processed. A payment is an event that happens once and doesn't change (you can void it, but voiding is a new event).

```sql
create table fact_payments (
    payment_sk          bigint primary key,
    payment_date_sk     int     references dim_date(date_sk),
    account_sk          bigint  references dim_account(account_sk),
    merchant_sk         bigint  references dim_merchant(merchant_sk),
    channel_sk          bigint  references dim_channel(channel_sk),
    -- grain: one row per payment transaction
    payment_id          varchar(50),   -- degenerate dimension
    payment_amount      decimal(12,2),
    currency_code       char(3),
    is_declined         boolean,
    processing_fee      decimal(8,4)
);
```

**What breaks if you use the wrong type:**
- Using a periodic snapshot here would require a row per account per day even on days with no activity — expensive and misleading.
- Using an accumulating snapshot here doesn't make sense — payments don't have a lifecycle with multiple milestone dates.

**Gotchas:**
- Transaction facts are append-only. Once loaded, rows are never updated (corrections come in as new offsetting rows or a separate corrections table).
- The `payment_id` stored directly on the row is a degenerate dimension. Don't create a `dim_payment` with nothing but the ID — that's wasteful.

---

### 10-B. Periodic Snapshot Fact

**What it solves:** Records the state of something at regular, predictable intervals — regardless of whether anything happened in that period.

> **Keywords to spot:** "daily balance", "end-of-month", "weekly inventory", "point-in-time status", "snapshot", "every period has a row"

**When to use:** When you need to track cumulative or status metrics over time — balances, inventory levels, headcount, subscriber counts.

**Business scenario:** Each row is the state of a bank account at end of day. If there were no transactions, a row is still created with the current balance (which equals the prior day balance).

```sql
create table fact_account_daily_snapshot (
    snapshot_sk         bigint primary key,
    snapshot_date_sk    int    references dim_date(date_sk),
    account_sk          bigint references dim_account(account_sk),
    -- grain: one row per account per calendar day
    closing_balance     decimal(15,2),
    available_balance   decimal(15,2),
    transaction_count   int,
    total_credits       decimal(12,2),
    total_debits        decimal(12,2),
    days_since_activity int
);
```

**What breaks if you use the wrong type:**
- Using a transaction fact here means days with no activity have no row. Queries for "what was the balance on 2024-03-15?" need complex last-value logic instead of a simple lookup. Dashboards show gaps instead of flat lines.

**Gotchas:**
- Periodic snapshots are expensive to store — one row per entity per period adds up fast at scale. Partition on the snapshot date and cluster on the entity key.
- Semi-additive measures (like `closing_balance`) cannot be summed across time periods — only across other dimensions. Summing balances across 30 days gives you a meaningless number. Sum across accounts on one day — valid. Average across time periods — valid.
- The "semi-additive" label is important in interviews: know which measures in a periodic snapshot are additive vs semi-additive vs non-additive.

---

### 10-C. Accumulating Snapshot Fact

**What it solves:** Tracks the lifecycle of a long-running business process through multiple milestones. Each row represents one instance of the process, updated as it progresses through stages.

> **Keywords to spot:** "pipeline stages", "lifecycle", "application process", "order fulfillment", "loan process", "end-to-end tracking", "milestone dates", "elapsed time between stages"

**When to use:** When a business process has a defined sequence of steps and you need to measure cycle times, bottlenecks, and completion rates across the entire pipeline.

**Business scenario:** A loan application progresses through: submitted → credit check → approved/rejected → disbursed → closed. Each application gets one row, with date columns for each milestone.

```sql
create table fact_loan_lifecycle (
    loan_sk                 bigint primary key,
    applicant_sk            bigint  references dim_customer(customer_sk),
    product_sk              bigint  references dim_loan_product(product_sk),
    submitted_date_sk       int     references dim_date(date_sk),
    credit_check_date_sk    int     references dim_date(date_sk),   -- nullable
    decision_date_sk        int     references dim_date(date_sk),   -- nullable
    disbursement_date_sk    int     references dim_date(date_sk),   -- nullable
    closed_date_sk          int     references dim_date(date_sk),   -- nullable
    -- grain: one row per loan application
    loan_id                 varchar(50),  -- degenerate dimension
    loan_amount             decimal(15,2),
    current_status          varchar(50),
    days_submitted_to_decision  int,      -- calculated, updated when decision is made
    days_decision_to_disburse   int,      -- calculated, updated when disbursed
    is_approved             boolean,
    rejection_reason        varchar(100)
);
```

**The defining characteristic:** Unlike transaction facts (append-only), accumulating snapshot rows are **updated** as milestones complete. The ETL for this table runs `UPDATE` statements, not just `INSERT`.

**What breaks if you use the wrong type:**
- Using a transaction fact would require multiple rows per loan (one per status change), making cycle time calculations complex and requiring session-like logic to reconstruct the timeline.
- Using a periodic snapshot would create a row per loan per day — most of which are identical. Extremely wasteful and still hard to calculate stage durations.

**Gotchas:**
- The nullable date_sk columns are essential — not every loan reaches every milestone (rejected loans never get a disbursement date). Use -1 to reference the `dim_date` "Unknown" row rather than NULL, if your tool doesn't handle NULL FK gracefully.
- When a milestone date is filled in, **both** the date_sk column and the derived duration column update atomically. Your pipeline logic must handle this correctly.
- This is the least common fact type but the most distinctive in interviews. Mentioning it when discussing pipeline/lifecycle modeling signals strong Kimball knowledge.

---

### 10-D. Factless Fact

**What it solves:** Records that an event occurred, or that a relationship exists, without any numeric measures. Answers "did X happen?" and "what is eligible/enrolled?"

> **Keywords to spot:** "coverage", "eligibility", "enrollment", "attendance", "event occurred", "did the promotion apply", "no measures just participation"

**When to use:** When the event itself is the information — no amount, count, or dollar value is attached.

**Business scenario 1 (event occurred):** Student attendance. Was student X present in class Y on date Z? The fact is the attendance event — there's nothing to measure.

```sql
create table fact_student_attendance (
    attendance_sk   bigint primary key,
    student_sk      bigint  references dim_student(student_sk),
    course_sk       bigint  references dim_course(course_sk),
    date_sk         int     references dim_date(date_sk),
    -- grain: one row per student per class session attended
    -- no measures — presence is the fact
    attendance_status varchar(20)  -- 'present', 'excused', 'unexcused'
);
```

**Business scenario 2 (coverage/eligibility):** What products are eligible for a promotion?

```sql
create table fact_promotion_coverage (
    coverage_sk     bigint primary key,
    promotion_sk    bigint  references dim_promotion(promotion_sk),
    product_sk      bigint  references dim_product(product_sk),
    store_sk        bigint  references dim_store(store_sk),
    effective_date_sk int   references dim_date(date_sk),
    expiry_date_sk    int   references dim_date(date_sk)
    -- grain: one row per promotion-product-store combination during coverage window
    -- no measures — eligibility is the fact
);
```

**How to use it in queries:**

```sql
-- Which promotions had eligible products but no actual sales?
select
    p.promotion_name,
    count(distinct fpc.product_sk) as eligible_products,
    count(distinct fs.product_sk)  as products_sold
from fact_promotion_coverage fpc
join dim_promotion p on fpc.promotion_sk = p.promotion_sk
left join fact_sales fs
    on  fpc.product_sk      = fs.product_sk
    and fpc.store_sk        = fs.store_sk
    and fs.order_date_sk between fpc.effective_date_sk and fpc.expiry_date_sk
group by 1
having count(distinct fs.product_sk) = 0;
```

**What breaks if you use the wrong type:**
- Storing eligibility in a dimension attribute works for simple cases but makes it impossible to answer "which products were eligible on which dates" without complex logic.

**Gotchas:**
- Factless facts often have the same row count as their grain — many rows, no aggregatable numbers. COUNT() is usually the only meaningful aggregation.
- The most common interview mistake is adding a dummy measure column (`event_count int default 1`). This works but is not truly factless. Interviewers who are strict will note the distinction.

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

---

# Part 4 — Modern Stack Patterns

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

---

# Part 5 — Design Decisions and Edge Cases

---

## 16. Choosing the Right Model

**What it solves:** Selecting the modelling approach that fits the use case, team size, and technical constraints.

> **Keywords to spot:** "which model would you use", "how would you design this", "trade-offs", "why star schema over snowflake"

**Decision Matrix:**

| Factor | Normalized (3NF) | Star Schema | Snowflake Schema | Data Vault | Medallion / OBT |
|---|---|---|---|---|---|
| Primary use | OLTP, transactional | OLAP, BI reporting | OLAP, storage-sensitive | Enterprise, multi-source | Lakehouse, self-service |
| Team size | Any | Small–Large | Medium–Large | Large | Small–Medium |
| Schema changes | Easier to adapt | Requires dim changes | Requires dim changes | Most flexible | Moderate |
| Query complexity | High (many joins) | Low (1-hop joins) | Medium | Very high (vault → mart) | Very low (OBT) |
| Auditability | Low | Medium | Medium | Very high | Low–Medium |
| Multiple source systems | Difficult | Difficult | Difficult | Designed for this | Moderate |
| BI tool performance | Poor | Excellent | Good | Poor (needs mart) | Excellent |
| History tracking | Limited | SCD 2 on dims | SCD 2 on dims | Built-in (satellites) | Complex |
| Storage efficiency | High | Medium | High | Low (many tables) | Low (wide tables) |

**Decision flowchart (simplified):**

```
Is this OLTP / transactional? ──Yes──> Normalize to 3NF
         │
         No
         │
Multiple conflicting source systems? ──Yes──> Data Vault 2.0
         │
         No
         │
Single team, self-service analytics? ──Yes──> Medallion + OBT (Gold layer)
         │
         No
         │
Standard BI reporting? ──Yes──> Star Schema (default choice)
         │
         No
         │
Storage-constrained + many hierarchy levels? ──Yes──> Snowflake Schema
```

---

## 17. Fan-out Trap (Chasm Trap)

**What it solves:** Prevents row multiplication that occurs when joining two fact tables through a shared dimension, or when joining a fact table to a dimension that has a 1:N relationship at the wrong level.

> **Keywords to spot:** "double counting", "inflated totals", "row multiplication", "joining two fact tables", "different grains", "sales total is wrong"

**The problem — numerical example:**

You have:
- `fact_sales` at order-line grain: customer C-001 has 3 orders, each $100 = $300 total
- `fact_support_tickets` at ticket grain: customer C-001 has 2 tickets

Both tables share `dim_customer`. You want: "for each customer, show total revenue and total tickets."

**Wrong approach — direct join:**

```sql
-- BAD: this will multiply rows
select
    c.customer_id,
    sum(s.revenue)          as total_revenue,
    count(t.ticket_sk)      as ticket_count
from dim_customer c
left join fact_sales s          on c.customer_sk = s.customer_sk
left join fact_support_tickets t on c.customer_sk = t.customer_sk
group by c.customer_id;
```

**What actually happens:**

For customer C-001:
- 3 sales rows × 2 ticket rows = 6 joined rows
- `sum(revenue)` = $100 × 6 rows where revenue appears = $600 (should be $300)
- `count(tickets)` = 6 (should be 2)

Every metric is wrong. The revenue is doubled because each sale row is joined to each ticket row.

**Correct approach — aggregate each fact independently first, then join:**

```sql
-- GOOD: aggregate each fact to the shared dimension grain first
with customer_sales as (
    select
        customer_sk,
        sum(revenue)        as total_revenue,
        count(*)            as order_count
    from fact_sales
    group by customer_sk
),
customer_tickets as (
    select
        customer_sk,
        count(*)            as ticket_count
    from fact_support_tickets
    group by customer_sk
)
select
    c.customer_id,
    coalesce(s.total_revenue, 0)    as total_revenue,
    coalesce(s.order_count, 0)      as order_count,
    coalesce(t.ticket_count, 0)     as ticket_count
from dim_customer c
left join customer_sales s   on c.customer_sk = s.customer_sk
left join customer_tickets t on c.customer_sk = t.customer_sk;
```

**Now the math works:**
- `customer_sales` has 1 row for C-001: total_revenue = $300
- `customer_tickets` has 1 row for C-001: ticket_count = 2
- Join 1 × 1 = 1 row. Both numbers correct.

**Detecting fan-out:**

```sql
-- Check row counts before and after a suspicious join
select count(*) from fact_sales;                -- N rows
select count(*) from fact_sales
join dim_customer on ...;                       -- should still be ~N rows
-- If count inflates significantly, you have a fan-out
```

**Gotchas:**
- Fan-out is the most dangerous silent bug in data warehousing. The query runs, returns results, and looks plausible. Nobody notices until someone checks the numbers against a source system.
- Whenever joining two fact tables, always aggregate both to the shared dimension grain in CTEs first. No exceptions.
- The problem is worse with outer joins — NULLs from one side get multiplied, distorting COUNT and SUM.

---

## 18. Many-to-Many Relationships

**What it solves:** Handles genuine M:N relationships in dimensional models without fan-out.

> **Keywords to spot:** "product in multiple categories", "patient has multiple diagnoses", "employee in multiple cost centers", "multi-label", "multiple values per entity"

**The bridge table approach (covered in Section 11-E) is the standard solution.** Here's the full pattern with a concrete example:

**Scenario:** A healthcare encounter can have multiple ICD-10 diagnosis codes. Each ICD code appears on multiple encounters.

```sql
create table dim_diagnosis (
    diagnosis_sk        int primary key,
    icd10_code          varchar(10) not null,
    diagnosis_name      varchar(300),
    diagnosis_category  varchar(100),
    is_chronic          boolean
);

create table fact_encounters (
    encounter_sk        bigint primary key,
    patient_sk          bigint  references dim_patient(patient_sk),
    provider_sk         bigint  references dim_provider(provider_sk),
    admit_date_sk       int     references dim_date(date_sk),
    discharge_date_sk   int     references dim_date(date_sk),
    -- grain: one row per patient encounter
    encounter_id        varchar(50),
    los_days            int,            -- length of stay
    total_charges       decimal(12,2)
);

-- Bridge table: one row per encounter-diagnosis pair
create table bridge_encounter_diagnosis (
    encounter_sk        bigint  references fact_encounters(encounter_sk),
    diagnosis_sk        int     references dim_diagnosis(diagnosis_sk),
    diagnosis_sequence  int,            -- 1 = primary diagnosis, 2+ = secondary
    primary key (encounter_sk, diagnosis_sk)
);
```

**Query — total charges by diagnosis category:**

```sql
select
    d.diagnosis_category,
    count(distinct fe.encounter_sk)     as encounter_count,
    sum(fe.total_charges)               as total_charges
from fact_encounters fe
join bridge_encounter_diagnosis bed on fe.encounter_sk    = bed.encounter_sk
join dim_diagnosis d                on bed.diagnosis_sk   = d.diagnosis_sk
group by 1
order by 3 desc;
```

**Warning:** This query will correctly count an encounter once per diagnosis category. But if one encounter has 2 diagnoses in the same category, the encounter is counted twice in that category and `total_charges` is doubled for that category. This is often the desired behavior (the encounter is "attributed" to that category). Document which interpretation you're using.

**Gotchas:**
- Bridge tables shift the complexity from the schema to the query. Every downstream analyst must know the bridge exists.
- If you need charges attributed only to the primary diagnosis, filter `WHERE bed.diagnosis_sequence = 1`.
- Weighted bridges (Section 11-E) are needed when the attribution should be split proportionally, not duplicated.

---

## 19. Hierarchies

**What it solves:** Represents parent-child structures (org charts, product trees, geographic rollups) in SQL tables.

> **Keywords to spot:** "hierarchy", "org chart", "parent-child", "recursive", "rollup", "drill-down", "tree structure", "manager reports"

### Fixed-depth hierarchy

When you know the hierarchy has a fixed number of levels (e.g., always: Company → Division → Department → Team), flatten it into one table.

```sql
-- 4-level org hierarchy, fixed depth
create table dim_org_hierarchy (
    org_node_sk         bigint primary key,
    team_id             varchar(50),
    team_name           varchar(100),
    department_id       varchar(50),
    department_name     varchar(100),
    division_id         varchar(50),
    division_name       varchar(100),
    company_id          varchar(50),
    company_name        varchar(100)
);

-- Every employee row can join directly to this for any level of rollup
create table dim_employee (
    employee_sk         bigint primary key,
    employee_id         varchar(50) not null,
    full_name           varchar(200),
    org_node_sk         bigint  references dim_org_hierarchy(org_node_sk),
    hire_date           date,
    salary              decimal(12,2)
);
```

**Query — headcount by division:**

```sql
select
    h.division_name,
    count(e.employee_sk) as headcount
from dim_employee e
join dim_org_hierarchy h on e.org_node_sk = h.org_node_sk
group by 1;
```

### Variable-depth hierarchy — adjacency list

When depth is unknown (org charts, category trees), store parent-child pairs.

```sql
create table dim_category_tree (
    category_id     varchar(50) primary key,
    category_name   varchar(100),
    parent_id       varchar(50)  references dim_category_tree(category_id),
    depth           int         -- 0 = root
);
```

Querying requires recursive CTEs (covered in `sql_patterns.md` section 17). The adjacency list is simple to maintain but slow to query at arbitrary depths.

### Variable-depth hierarchy — closure table

Pre-computes all ancestor-descendant pairs. Fastest for querying but more complex to maintain.

```sql
-- Stores every ancestor-descendant pair for every node
create table category_closure (
    ancestor_id     varchar(50)  references dim_category_tree(category_id),
    descendant_id   varchar(50)  references dim_category_tree(category_id),
    depth           int,         -- 0 = self-reference, 1 = direct parent, etc.
    primary key (ancestor_id, descendant_id)
);
```

**Query — all products under "Electronics" at any depth:**

```sql
select p.*
from dim_product p
join category_closure cc
    on p.category_id = cc.descendant_id
where cc.ancestor_id = 'CAT-ELECTRONICS'
  and cc.depth > 0;   -- exclude self
```

**Gotchas:**
- Closure tables are the right answer for large hierarchies with frequent "get all descendants" queries. The table size is O(N²) in the worst case (fully nested), but in practice most hierarchies are sparse.
- Fixed-depth flattening is the right answer for BI tools — analysts can simply filter on `division_name` without needing recursive logic.
- Adjacency lists are fine for small hierarchies or when recursive CTE support is robust (Snowflake, BigQuery, Postgres all support it).

---

## 20. Late Arriving Facts

**What it solves:** Handles fact records that arrive after their associated dimension records have already moved forward in time (SCD 2 changes), or fact records that arrive after the period they belong to has already been closed.

> **Keywords to spot:** "late arriving data", "backfill", "out of order", "event arrived late", "dimension already changed", "historical fact load"

**Problem 1: Fact arrives after the dimension version has expired**

Customer C-001 moved from Chicago to New York on 2024-06-01. An order placed on 2024-05-20 arrives in the warehouse on 2024-07-15 (late). At load time, the current `customer_sk` for C-001 points to the New York version.

```sql
-- Wrong: using current customer_sk
insert into fact_sales (customer_sk, ...)
select
    c.customer_sk,   -- this is the New York version (wrong!)
    ...
from staging_late_orders o
join dim_customer c on c.customer_id = o.customer_id and c.is_current = true;

-- Correct: look up the customer version that was active at event time
insert into fact_sales (customer_sk, ...)
select
    c.customer_sk,   -- this finds the Chicago version (correct!)
    ...
from staging_late_orders o
join dim_customer c
    on  c.customer_id      = o.customer_id
    and o.order_date between c.effective_from and coalesce(c.effective_to, '9999-12-31');
```

**Problem 2: Late-arriving dimension (dimension arrives after the fact)**

A product is loaded into the warehouse on day 1. The product's dimension attributes (name, category) arrive on day 3. Facts loaded on day 1 and 2 have a FK to a placeholder "Unknown" dimension row.

**Solution — Unknown dimension row + backfill:**

```sql
-- Step 1: On first encounter of an unknown product, insert a placeholder
insert into dim_product (product_sk, product_id, product_name, category)
values (nextval('dim_product_sk_seq'), 'P-999', 'Unknown Product', 'Unknown');

-- Facts load with this placeholder SK

-- Step 2: When the real attributes arrive, update the placeholder (SCD 1 on Unknown rows)
update dim_product
set
    product_name = 'Wireless Headphones',
    category     = 'Electronics'
where product_id = 'P-999'
  and product_name = 'Unknown Product';
-- The fact table FKs don't need to change — they already point to the right SK
```

**Problem 3: Late-arriving facts for periodic snapshots (closed periods)**

A transaction from November arrives in December after the November snapshot has been finalized.

**Options:**

```sql
-- Option A: Restate the November snapshot (most accurate, most expensive)
-- Re-run the entire November snapshot job with the late record included

-- Option B: Apply the late fact to the earliest open period (pragmatic)
-- Add the transaction to December's snapshot instead

-- Option C: Create a "correction" or "adjustment" row
insert into fact_account_daily_snapshot (
    snapshot_sk, snapshot_date_sk, account_sk,
    closing_balance, transaction_count, is_correction, correction_reason
)
values (
    nextval('snapshot_sk_seq'),
    20241201,       -- correction applied to current period
    ...,
    ...,
    1,
    true,
    'Late-arriving November transaction'
);
```

**Gotchas:**
- Late-arriving facts are the rule, not the exception, in production systems. Design for them from day one.
- Document your late-arrival policy (how many days late you accept, what happens after that cutoff).
- Accumulating snapshot facts (Section 10-C) are particularly vulnerable: when a milestone date arrives late, you need to UPDATE the existing row, not insert a new one.

---

## 21. NULL Handling in Dimensional Models

**What it solves:** Prevents NULLs in fact table FK columns from breaking joins and aggregations, and establishes a consistent vocabulary for missing/unknown/not-applicable data.

> **Keywords to spot:** "null foreign key", "missing dimension", "unknown customer", "not applicable", "null in fact table", "surrogate key for nulls"

### Why NULLs in FK columns are dangerous

```sql
-- fact table has NULLs in product_sk for transactions with no product
select
    p.category,
    sum(f.revenue)
from fact_transactions f
left join dim_product p on f.product_sk = p.product_sk
group by p.category;
-- Rows where product_sk IS NULL will have category = NULL
-- They get lumped under NULL in GROUP BY — often lost in reports or charts
```

### The -1 surrogate key pattern

Insert a special "Unknown" or "Not Applicable" row in every dimension with `_sk = -1` (or another sentinel value). Fact table FKs that would otherwise be NULL point to this row instead.

```sql
-- Insert unknown rows in every dimension
insert into dim_customer (customer_sk, customer_id, full_name, city, segment)
values (-1, 'UNKNOWN', 'Unknown Customer', 'Unknown', 'Unknown');

insert into dim_product (product_sk, product_id, product_name, category)
values (-1, 'UNKNOWN', 'Unknown Product', 'Unknown');

insert into dim_date (date_sk, full_date, day_of_week_name, month_name)
values (-1, '1900-01-01', 'Unknown', 'Unknown');
```

**In the ETL — replace NULL FKs with -1:**

```sql
insert into fact_transactions (transaction_sk, customer_sk, product_sk, ...)
select
    nextval('transaction_sk_seq'),
    coalesce(c.customer_sk, -1),   -- -1 if customer not found
    coalesce(p.product_sk, -1),    -- -1 if product not found
    ...
from staging_transactions st
left join dim_customer c on st.customer_id = c.customer_id and c.is_current = true
left join dim_product  p on st.product_id  = p.product_id  and p.is_current = true;
```

Now `GROUP BY p.category` will show "Unknown" as a visible category instead of NULL getting silently dropped.

### NULL vs "N/A" vs "Unknown" in dimension tables

Use these three values consistently and never interchangeably:

| Value | Meaning | Example |
|---|---|---|
| `NULL` | The attribute is not applicable to this row — there is no value and there never will be | `middle_name` on a customer with no middle name |
| `'N/A'` | Not applicable in context — the attribute exists but doesn't apply | `spouse_name` for a single person |
| `'Unknown'` | The attribute is applicable but the value hasn't been collected or couldn't be found | `city` for a customer who skipped that field |

**Gotchas:**
- The -1 SK pattern works only if every dimension has the -1 row pre-populated. If it's missing, the FK lookup will fail and you're back to NULLs.
- Some tools display `NULL` and `'Unknown'` identically. Using a consistent string value ensures `GROUP BY` always groups unknowns together.
- In SCD 2 dimensions, the Unknown row (`SK = -1`) should never have `effective_from` and `effective_to` logic applied — it's a static placeholder.
- NULL measures in fact tables follow different rules. `SUM(revenue)` ignores NULLs — which is usually correct. But `COUNT(revenue)` vs `COUNT(*)` will differ if revenue is sometimes NULL. Be explicit.

---

## 22. Performance Considerations

**What it solves:** Ensures your data model performs at scale by choosing the right physical design options — partitioning, clustering, and materialization.

> **Keywords to spot:** "query is slow", "scan cost", "partition pruning", "clustering key", "materialized view", "incremental load", "full table scan"

### Partitioning

Divide a large table into smaller physical segments based on a column value. Queries that filter on the partition key only scan matching partitions — dramatic cost reduction.

```sql
-- Snowflake: cluster by date (partitioning equivalent)
create table fact_transactions (
    transaction_sk      bigint,
    transaction_date    date,
    customer_sk         bigint,
    amount              decimal(12,2)
)
cluster by (transaction_date);

-- BigQuery: partition by ingestion date or date column
create table `project.dataset.fact_transactions`
(
    transaction_sk      int64,
    transaction_date    date,
    customer_sk         int64,
    amount              numeric
)
partition by transaction_date;

-- PostgreSQL: declarative table partitioning
create table fact_transactions (
    transaction_sk      bigint,
    transaction_date    date,
    customer_sk         bigint,
    amount              decimal(12,2)
) partition by range (transaction_date);

create table fact_transactions_2024
    partition of fact_transactions
    for values from ('2024-01-01') to ('2025-01-01');
```

**Best partition keys:** Date columns (most queries filter on date). Avoid high-cardinality natural keys — too many partitions defeats the purpose.

### Clustering / Sort Keys

Within a partition, physically sort rows by a column to make range scans fast.

```sql
-- Snowflake: multi-column cluster key
create table fact_sales (
    ...
)
cluster by (order_date, customer_sk);

-- Redshift: sort key + dist key
create table fact_sales (
    ...
)
distkey(customer_sk)
sortkey(order_date, customer_sk);
```

**Best cluster keys:** After the partition key, cluster on the most commonly filtered or joined column — usually `customer_sk` or `product_sk` depending on the use case.

### Materialization choices

| Strategy | When to use | Trade-off |
|---|---|---|
| **Table** (physical) | Queried frequently, expensive to recompute | Uses storage, must be refreshed |
| **View** (virtual) | Simple transformations, underlying table changes frequently | Recomputes every query — expensive for complex logic |
| **Materialized View** | Expensive aggregations queried often, acceptable staleness | Storage + refresh cost, but much faster than view |
| **Incremental table** | Large fact tables, only new rows added daily | Complex to implement, risk of missing updates |

**Incremental load pattern — only process new rows:**

```sql
-- Load only transactions from the last partition/date
insert into fact_transactions
select
    ...
from silver.transactions_clean
where transaction_date = current_date - 1
  and transaction_sk not in (select transaction_sk from fact_transactions);
-- Better with a watermark: load rows with load_date > last_run_watermark
```

### General guidelines

- **Fact tables:** Always partition on the primary date column. Cluster on the most commonly joined dimension SK.
- **Dimension tables:** Small enough that full scans are fine. No partitioning needed unless the dimension has millions of rows (like `dim_user` at large scale).
- **Avoid SELECT \*:** In columnar warehouses, scanning unused columns wastes money. Select only what you need.
- **Filter early:** Push WHERE clauses to CTEs, not outer queries. In columnar engines, predicate pushdown is critical.

**Gotchas:**
- Over-partitioning is as bad as no partitioning. Snowflake recommends clustering keys only when tables exceed 1TB. BigQuery charges for metadata operations on over-partitioned tables.
- Materialized views become stale. Know your refresh schedule and whether your BI users understand the staleness.
- In Snowflake, `CLUSTER BY` is not free — automatic clustering consumes credits. Measure before enabling.

---

# Part 6 — Quick Reference

---

## Model Selection Decision Tree

```
Start: What is the primary purpose of this data store?
│
├─ Record business transactions in real time
│   └─> OLTP / Normalized (3NF)
│
├─ Analytics and reporting
│   │
│   ├─ Multiple conflicting source systems / audit requirements?
│   │   └─> Data Vault 2.0 (with Information Mart on top)
│   │
│   ├─ Single source or well-integrated sources?
│   │   │
│   │   ├─ Self-service analytics, small team, BI tool query is the end goal?
│   │   │   └─> Medallion + Gold OBT
│   │   │
│   │   ├─ Multiple subject areas sharing dimensions, complex reporting?
│   │   │   └─> Star Schema (Kimball)
│   │   │
│   │   └─ Deep hierarchies, storage-constrained dimensions?
│   │       └─> Snowflake Schema
│   │
│   └─ Mixed: some real-time, some analytical?
│       └─> OLTP for transactional + Medallion/Star for analytical
│
└─ Unclear / greenfield?
    └─> Start with Medallion Architecture (Bronze/Silver/Gold)
        Gold layer: start with OBT, evolve to star schema as complexity grows
```

---

## Fact Table Type Cheat Sheet

| Type | Grain | Rows updated? | Best for | Classic example |
|---|---|---|---|---|
| **Transaction** | One row per discrete event | Never (append-only) | Events, payments, clicks, orders | `fact_payments`: one row per payment |
| **Periodic Snapshot** | One row per entity per period | Never (new rows each period) | Balances, inventory, headcount | `fact_account_balance`: one row per account per day |
| **Accumulating Snapshot** | One row per business process instance | Yes (updated at milestones) | Pipelines, lifecycles, applications | `fact_loan_lifecycle`: one row per loan application |
| **Factless** | One row per event or relationship | Never | Attendance, eligibility, coverage | `fact_student_attendance`: one row per attendance event |

---

## Dimension Type Cheat Sheet

| Type | What makes it special | When to use |
|---|---|---|
| **Conformed** | Shared identically across multiple fact tables | Date, customer, product — any enterprise-wide concept |
| **Junk** | Combines low-cardinality flags into one dimension | Boolean flags, status indicators cluttering the fact table |
| **Role-playing** | Same physical table used in multiple FK roles on one fact | Multiple date columns, source/destination accounts |
| **Degenerate** | Dimension attribute stored on fact table (no dim table) | Order ID, invoice number — identifier with no other attributes |
| **Bridge** | Resolves M:N between fact and dimension | Multiple diagnoses per encounter, multiple owners per account |
| **Date/Calendar** | Pre-computed temporal attributes | Every fact table needs one — build once, use everywhere |

---

## SCD Type Comparison Table

| Type | History | Storage | ETL complexity | Best for |
|---|---|---|---|---|
| **SCD 0** | None (immutable) | Minimal | None | DOB, original signup date — never changes |
| **SCD 1** | None (overwrites) | Minimal | Simple | Typo corrections, irrelevant history |
| **SCD 2** | Full (new row per change) | High | Medium | When historical accuracy matters — the default choice |
| **SCD 3** | One prior value only | Low | Simple | When "current vs previous" is all you need |
| **SCD 4** | Full (separate history table) | High | Medium | Hot current table + cold history table |
| **SCD 6** | Full (row history + current value on all rows) | Very high | High | When you need "what was it then" AND "what is it now" in one query |

---

## Interview Keywords → Pattern Mapping

| If you hear... | Think... |
|---|---|
| "track customer history", "what was the city at time of order" | SCD Type 2 |
| "just fix the wrong value", "typo in customer name" | SCD Type 1 |
| "never changes", "immutable", "date of birth" | SCD Type 0 |
| "current vs previous value" | SCD Type 3 |
| "only one prior value isn't enough", "full audit trail" | SCD Type 2 or SCD Type 6 |
| "what does one row represent", "level of detail" | Grain definition |
| "revenue is double-counted", "inflated totals" | Fan-out trap — aggregate before joining |
| "joining two fact tables" | Aggregate both to shared dimension grain first |
| "boolean flags", "low cardinality indicators on fact" | Junk dimension |
| "same date dimension used three times" | Role-playing dimension |
| "order number on the fact table" | Degenerate dimension |
| "shared across all subject areas", "enterprise customer dimension" | Conformed dimension |
| "product in multiple categories", "joint account" | Bridge table (M:N) |
| "account balance", "daily inventory", "end of period" | Periodic snapshot fact |
| "loan pipeline", "application stages", "time between stages" | Accumulating snapshot fact |
| "did the promotion cover this product", "attendance" | Factless fact |
| "raw data → cleaned → reporting" | Medallion architecture |
| "no joins needed", "wide table for self-service" | One Big Table (OBT) |
| "multiple source systems", "audit trail", "insert-only" | Data Vault 2.0 |
| "organize hierarchy", "drill-down", "org chart" | Fixed-depth flatten or closure table |
| "atomic values", "comma-separated in one column" | 1NF violation |
| "attribute depends on part of composite key" | 2NF violation |
| "department name on employee table" | 3NF violation |
| "late data", "backfill", "event arrived out of order" | Late-arriving facts pattern |
| "null foreign key", "missing dimension member" | -1 surrogate / Unknown dimension row |
| "partition", "query is slow", "full table scan" | Partitioning + clustering strategy |
| "what model would you choose" | Use the decision matrix — start with use case, team size, source systems |
| "ETL vs ELT", "why dbt", "transform in the warehouse" | ELT — raw layer + warehouse-native SQL transforms |
| "how do you get incremental data", "delta load", "watermark" | Incremental extraction with high-water mark |
| "how do you capture deletes", "missed deletions" | CDC — log-based is the correct answer |
| "log-based vs polling CDC", "change data capture" | Log-based CDC (WAL) preferred; polling misses deletes |
| "pipeline ran twice", "duplicate rows", "safe to retry" | Idempotency — MERGE or partition replace pattern |
| "truncate and reload", "full refresh vs incremental" | Load strategy decision — full refresh for small/dim, incremental for large fact |
| "real-time data", "how fresh", "latency SLA" | Batch vs micro-batch vs streaming — match architecture to SLA |
| "Spark Streaming", "Flink", "Kafka", "near real-time" | Micro-batch (Spark) vs true streaming (Flink/Kafka Streams) |
| "dbt table vs incremental", "materialization" | dbt materializations map to load strategies: table=full refresh, incremental=watermark/merge |
