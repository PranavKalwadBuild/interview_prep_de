# Modern Stack Patterns — Design Rationale

## Overview

Three dominant patterns shape how modern data teams structure their warehouses: **Medallion Architecture** (incremental refinement layers), **One Big Table / OBT** (aggressive denormalisation for a single grain), and **Data Vault 2.0** (audit-first, insert-only modelling). They are not mutually exclusive — many real stacks combine all three at different layers.

---

## Medallion Architecture

### Layer Responsibilities

| Layer | Owns | Never does |
|-------|------|-----------|
| **Bronze** | Exact copy of source data + ingestion metadata (`_ingested_at`, `_source_system`) | Transform, clean, filter, or interpret any value |
| **Silver** | Deduplication, type casting, NULL handling, business-rule filtering | Aggregate or join across unrelated domains |
| **Gold** | Pre-aggregated, purpose-built views for a specific business question | Store row-level detail or serve multiple conflicting grains |

### Why You Never Transform in Bronze

The Bronze layer is the replayability guarantee. If the Silver transformation logic has a bug today, you can fix the logic and re-run the Silver build entirely from Bronze — because Bronze captured the raw source faithfully. If you transform in Bronze (e.g., silently fill NULLs), you destroy the ability to distinguish "this value was NULL in source" from "we filled this value". That distinction matters for data quality investigations and audits.

In practical terms: Bronze is append-only in production pipelines. Each pipeline run inserts a new batch with a fresh `_ingested_at`. Silver reads the latest batch (via `ROW_NUMBER()` deduplicate) and applies transformations.

### What Each Layer Owns — Extended

**Bronze owns:**
- All source flaws (NULL salary for emp 10/15, NULL email for emp 22, salary=0.00 for emp 19)
- Duplicates (if the source emits them)
- All source columns, including ones your warehouse does not need yet
- The ingestion timestamp and source system label

**Silver owns:**
- The business decision about what to do with NULLs (fill, flag, or exclude)
- Deduplication strategy (last-write-wins, primary-key dedup, or business-rule dedup)
- Type enforcement (VARCHAR → DATE, STRING → DECIMAL)
- Row validity filtering (emp 41's future hire_date excluded from active payroll silver)
- One row per source entity (not aggregated)

**Gold owns:**
- Exactly one use case per table
- Pre-joined, pre-aggregated results
- Renamed columns that match BI tool / business terminology
- Schema that is stable for downstream consumers (column renames happen here, not in Silver)

---

## One Big Table (OBT)

### When OBT Works Well

- **Single grain:** the table answers one question at one level of detail (one row = one employee)
- **Columnar / Parquet storage:** BigQuery, Snowflake, Databricks, and DuckDB all scan only the columns referenced in a query. A 200-column OBT with 10 columns queried is still fast — columnar storage makes wide tables cheap
- **Read-heavy workloads:** the table is rebuilt periodically (daily or hourly) and then read thousands of times. The rebuild cost is amortised
- **dbt materialisation as `table`:** dbt's `SELECT` model compiles to a CREATE TABLE AS SELECT — OBT is the natural shape for this pattern
- **Small-to-medium cardinality:** employee analytics at 10k employees is trivial; billions of events at one-row-per-event requires partitioning strategies

### When OBT Fails

- **Multiple consumers with different grains:** an OBT at employee grain cannot serve a query that needs dept-level payroll without re-aggregating. A second OBT at dept grain is then needed. Now you have two tables with overlapping logic that can drift.
- **Large M:N relationships:** `project_count` in the OBT requires a correlated subquery or pre-join. If one employee has thousands of project rows, this does not scale without a pre-aggregation step — which defeats the simplicity of OBT.
- **Frequent source updates:** if `dept_name` changes in the source, the entire OBT must be rebuilt. Incremental maintenance of a denormalised table is complex and error-prone.
- **Regulated data with access control at column level:** a single wide table makes column-level security harder. Row-level or attribute-level access control is easier on narrower, normalised tables.

---

## Data Vault 2.0

### Hub / Satellite / Link — What Each Component Does

**Hub:** The registry of real-world entities, identified by their business key.
- `hub_employee` stores only `emp_id` (business key) + load metadata
- Contains zero descriptive attributes — that belongs in the satellite
- Insert-only: once a business key is recorded, it is never deleted or updated
- UNIQUE constraint on the business key ensures idempotency

**Satellite:** The attributes of a hub entity, versioned by load batch.
- A new row is inserted only when `hash_diff` (MD5 of all descriptive columns) changes
- `load_dts` determines "current": the row with the MAX `load_dts` per `hub_sk` is current
- Source flaws are preserved here (emp 22 NULL email, emp 10/15 NULL salary) — because the vault is a raw layer; cleaning happens in the Information Mart layer on top
- Multiple satellites can exist per hub: `sat_employee_hr` (name, job), `sat_employee_payroll` (salary, benefits) — loaded from different source systems independently

**Link:** The relationship between two or more hubs.
- `lnk_emp_dept` captures the fact that emp 7 worked in dept 1
- Insert-only: when emp 3 moves from Finance to Engineering, a NEW link row is inserted — the old one remains (audit trail)
- Links enable M:N relationships across any number of hubs without schema changes

### Why Insert-Only = Audit Trail

Data Vault's core design principle is that **no row is ever updated or deleted**. This means:

- The full history of every change is automatically preserved at the satellite level
- You can always answer "what did we load on date X?" by filtering on `load_dts`
- Regulatory audits can trace every value back to its source batch and timestamp
- ETL bugs do not destroy history — you add corrective rows, not overwrite existing ones

This property is what makes Data Vault attractive for financial services, healthcare, and any domain where "prove your numbers" is a compliance requirement.

### When Data Vault Complexity Is Justified

Data Vault adds significant structural complexity (at minimum three table types per entity; queries require multi-join reconstruction). Accept that cost when:

1. **Regulatory audit trail is mandatory:** every row must be traceable to a load batch and source system
2. **Multi-source integration:** the same entity (an employee) arrives from HR, Payroll, and Active Directory independently. Each source loads into the same hub (idempotent on business key) and its own satellite — no source-merge logic required at load time
3. **Frequently changing source schemas:** because descriptive attributes live in satellites, adding a new column from a new source is a new satellite column — it does not change the hub or link structure
4. **Long-horizon warehousing:** teams that have been running the same warehouse for 10+ years find that Data Vault's insert-only pattern makes schema evolution tractable

Do NOT use Data Vault for:
- Small teams with a single source system (Kimball star schema is faster to build and easier to query)
- Latency-sensitive use cases (vault reconstruction queries require multi-hop joins)
- Proof-of-concept or short-lived analytical projects

---

## Kimball vs Inmon vs Data Vault — Comparison

| Dimension | Kimball (Star Schema) | Inmon (3NF Enterprise DW) | Data Vault 2.0 |
|-----------|----------------------|--------------------------|----------------|
| **Shape** | Fact + dimension tables | Fully normalised 3NF tables | Hub + satellite + link |
| **Transformation point** | At load time (ETL cleans before loading dim/fact) | At load time (into 3NF) | Deferred — vault layer is raw; Info Mart layer transforms |
| **History** | SCD types on dimensions | Separate history tables | Satellite append-only history by default |
| **Query complexity** | Low — 1-3 joins for most analytics | High — many joins through 3NF | High — hub → sat → link reconstruction |
| **Agility** | Medium — schema changes require dim/fact rebuild | Low — 3NF changes ripple widely | High — new source = new satellite; no hub/link change |
| **Best for** | Departmental analytics, BI dashboards, single-subject area | Enterprise-wide atomic data layer feeding downstream marts | Multi-source audit-grade warehousing, regulated industries |
| **Main weakness** | Fan-out problems with multiple large facts; M:N relationships complex | Slow to query; ETL-heavy; not analyst-friendly | Steep learning curve; verbose DDL; query reconstruction overhead |

---

## Interview: Medallion vs Kimball Star Schema

**Question:** "What's the difference between a Bronze/Silver/Gold architecture and a traditional Kimball star schema?"

**Answer:**

They solve related but different problems and operate at different levels of abstraction.

**Grain and transformation point:**
- In Kimball, the transformation happens at ETL load time: source data is cleaned, keys are assigned, and data lands directly into star-schema-shaped dimension and fact tables. There is no "raw" layer; the warehouse IS the presentation layer.
- In Medallion, transformation is staged: Bronze preserves the raw source exactly. Silver cleans and types. Gold aggregates. The star schema (dim/fact structure) typically lives at the Gold layer or as a separate consumption layer built from Silver.

**Consumer type:**
- Kimball's star schema is optimised for a known set of analytical queries — the grain, dimensions, and facts are designed around specific business processes (payroll, headcount, project delivery).
- Medallion's Bronze and Silver layers serve a much broader consumer set: data scientists who want row-level Silver data, ML engineers who want Bronze for training data provenance, and BI analysts who want Gold aggregates — all from the same pipeline.

**Replayability:**
- Kimball warehouses typically do not retain the raw source after loading (data lands in dim/fact and source files are archived). If the transformation logic was wrong, reloading requires re-extracting from source.
- Medallion's Bronze-first approach means Silver and Gold can always be rebuilt from Bronze without re-extraction from the source system. This is a significant operational advantage for iterative modelling.

**When to use which:**
- Use Kimball when you have stable, well-understood business processes and a primary audience of BI/reporting consumers.
- Use Medallion when you have multiple consumer types (analytics + data science + ML), when source schemas evolve frequently, or when your team needs the ability to re-derive outputs from raw data on demand.
- In practice, the two are complementary: a modern Lakehouse often has Medallion layers (Bronze/Silver/Gold) where Gold is structured as a Kimball star schema.
