<!-- data-modelling-patterns: Foundations — What is Data Modelling, OLTP vs OLAP, ETL vs ELT -->

# Foundations

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
