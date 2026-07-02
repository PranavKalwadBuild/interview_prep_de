<!-- data-modelling-patterns: Quick Reference — Decision Trees, Cheat Sheets, Keywords→Pattern Map -->

# Quick Reference

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
