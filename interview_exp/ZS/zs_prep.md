# ZS — Data Engineer (dbt) Interview Prep
**Interview Date:** 2026-06-15 (2 days away)  
**Role:** BTS Data Engineer — dbt  
**Team:** Business Technology Solutions  
**Domain:** Pharma, Biotech, Medical Devices, Health Plans  
**JD File:** `JD_ZS_DataEngineer_DBT.pdf`

---

## Situation Assessment

This is a **near-perfect resume match.** dbt is ZS's central requirement and it's your primary stack. The gap is not breadth — it's depth on a few specific dbt features and methodologies they call out explicitly. This interview will be technical and detailed. They will go deep on dbt internals.

---

## Your Strengths vs. JD — Quick Map

| JD Requirement | Your Coverage | Confidence |
|---|---|---|
| dbt Core + dbt Cloud | Both used across projects | HIGH |
| Jinja templating + macro development | Generic incremental macros, multi-engine macros | HIGH |
| SQL + data modeling | Complex analytical models, 70% runtime reduction | HIGH |
| dbt materializations | Used strategically (JD wants you to know ALL 5) | HIGH |
| Data quality & testing | TDD for 600 models, count/metadata/mismatch checks | HIGH |
| CI/CD with dbt Slim CI | Explicit on resume | HIGH |
| Airflow integration | Airflow + Trino for model validation | HIGH |
| AWS + Redshift | Redshift ↔ Snowflake sync utility | HIGH |
| Git/GitHub workflows | Explicit across all projects | HIGH |
| Incremental model optimization | Core to your phData work | HIGH |
| Data governance / lineage | Data Mesh context, Alation | MEDIUM |
| **Dimensional Modeling (Kimball)** | Know conceptually — be ready to go deep | MEDIUM |
| **Data Vault** | **Not on resume — study needed** | GAP |
| **dbt-utils, dbt-expectations, Elementary** | Likely used but not called out | GAP |
| **dbt snapshots (SCD Type 2)** | Not explicitly mentioned | GAP |
| **dbt model contracts** | Newer feature — not mentioned | GAP |
| Staging → Intermediate → Mart layers | Implied but not explicitly articulated | MEDIUM |

---

## Critical Focus Areas

### 1. Data Vault (Biggest Conceptual Gap)

ZS explicitly requires knowledge of both Kimball AND Data Vault. You likely haven't used Data Vault — here's what you need to know.

**Core Building Blocks:**
- **Hub** — stores unique business keys (e.g., `hub_customer` with `customer_id`)
- **Link** — stores relationships between hubs (e.g., `link_customer_order` — joins customer + order business keys)
- **Satellite** — stores descriptive/contextual attributes with full history (e.g., `sat_customer_details` with name, address, load_date, hash_diff)

**Key Properties:**
- Insert-only (no updates — history always preserved)
- Hubs and Links use hash keys (MD5/SHA256 of business key) as surrogate keys
- Satellites track changes over time using `load_date` and `hash_diff`
- Highly normalized — good for auditability and flexibility; bad for query simplicity

**Kimball vs Data Vault — When to Use Which:**

| | Kimball (Dimensional) | Data Vault |
|---|---|---|
| Structure | Stars/snowflakes — facts + dims | Hubs + Links + Satellites |
| Use case | Analytical queries, BI | Raw data storage, audit, flexibility |
| Updates | SCD handling | Insert-only, history automatic |
| Best for | Marts layer (reporting) | Raw/staging layer, enterprise DW |
| Query complexity | Low | High (needs views or marts on top) |

**How to talk about it:**
> "I've worked primarily with Kimball dimensional modeling in production — star schema marts, SCD Type 2 via dbt snapshots. I understand Data Vault architecture — the Hub/Link/Satellite pattern, insert-only history, hash key generation. I haven't built a Data Vault system end-to-end, but the architectural reasoning is clear to me and I've seen similar raw-to-refined layering in Data Mesh contexts."

---

### 2. dbt Materializations — Know All 5

The JD lists all 5 by name. Be able to explain each and when to use it.

| Materialization | What it is | Use when |
|---|---|---|
| `view` | SQL view, recomputed every query | Lightweight staging, rarely queried directly |
| `table` | Full table rebuild on each run | Small-medium tables, complete refreshes OK |
| `incremental` | Append/merge only new/changed rows | Large tables, expensive full refreshes |
| `snapshot` | SCD Type 2 tracking — captures row changes over time with `dbt_valid_from/to` | Slowly changing dimensions, audit history |
| `ephemeral` | CTE injected into downstream models — no DB object created | Intermediate logic, avoid polluting schema |

**Deep dive — incremental models (you've used these — go deep):**
```sql
-- incremental model config
{{ config(
    materialized='incremental',
    unique_key='order_id',
    incremental_strategy='merge'  -- or 'insert_overwrite', 'delete+insert'
) }}

SELECT * FROM {{ ref('stg_orders') }}
{% if is_incremental() %}
  WHERE updated_at > (SELECT MAX(updated_at) FROM {{ this }})
{% endif %}
```

**Snapshot — know the syntax:**
```sql
{% snapshot customer_snapshot %}
{{ config(
    target_schema='snapshots',
    unique_key='customer_id',
    strategy='timestamp',       -- or 'check'
    updated_at='updated_at'
) }}
SELECT * FROM {{ source('raw', 'customers') }}
{% endsnapshot %}
```

---

### 3. dbt Ecosystem Packages

JD specifically calls out `dbt-utils`, `dbt-expectations`, `Elementary`. Know what each does.

**dbt-utils:**
- `generate_surrogate_key()` — MD5 hash of multiple columns for surrogate key
- `surrogate_key()` — same
- `get_column_values()` — macro to dynamically get distinct values
- `pivot()` / `unpivot()` — column transforms
- `date_spine()` — generate continuous date series
- `union_relations()` — union multiple tables dynamically
- `expression_is_true` — generic test for custom boolean expressions

**dbt-expectations:**
- Port of Great Expectations to dbt
- `expect_column_values_to_be_between` — range check
- `expect_column_values_to_match_regex` — pattern check
- `expect_table_row_count_to_be_between` — row count thresholds
- `expect_column_pair_values_A_to_be_greater_than_B` — cross-column logic

**Elementary:**
- dbt package + dashboard for data observability
- Runs dbt tests + tracks results over time
- Anomaly detection on volume, freshness, schema changes
- Generates an observability report/dashboard automatically
- You run it as: `dbt run --select elementary` then `edr report`

**How to talk about it if you haven't used them:**
> "I've used dbt-utils extensively — generate_surrogate_key, date_spine, union_relations in macro logic. I'm familiar with dbt-expectations as a testing layer and Elementary for observability — my data quality work used custom generic tests for count/metadata/mismatch patterns that cover similar ground to what Elementary automates."

---

### 4. dbt Model Contracts

Newer dbt feature (v1.5+) — enforces column names, data types, and constraints at the model level.

```yaml
models:
  - name: dim_customers
    config:
      contract:
        enforced: true
    columns:
      - name: customer_id
        data_type: integer
        constraints:
          - type: not_null
          - type: primary_key
      - name: customer_name
        data_type: varchar
```

**Why it matters:** Guarantees downstream consumers that the model's interface won't change unexpectedly — like an API contract for data. ZS cares about governance; this is the governance answer for dbt.

---

### 5. Staging → Intermediate → Mart Layer Convention

ZS explicitly requires knowledge of this pattern. Know it cold.

```
sources/          ← raw source definitions (schema.yml)
staging/          ← 1:1 with source tables, light cleaning, renaming, casting
  stg_orders.sql
  stg_customers.sql
intermediate/     ← business logic, joins, transformations (not exposed to BI)
  int_order_items_joined.sql
marts/            ← final analytical models, dimensional/fact tables
  core/
    fct_orders.sql
    dim_customers.sql
  finance/
    fct_revenue.sql
```

**Rules:**
- Staging: rename cols to snake_case, cast types, no business logic, prefix `stg_`
- Intermediate: prefix `int_`, not materialized as tables (ephemeral or view), combine/transform
- Marts: fact/dim naming, fully materialized, business-facing

---

### 6. dbt Singular vs Generic Tests

**Generic tests** (schema.yml) — reusable, apply to any column:
```yaml
columns:
  - name: order_id
    tests:
      - unique
      - not_null
      - relationships:
          to: ref('stg_orders')
          field: order_id
```

**Singular tests** — custom SQL in `tests/` folder, one-off assertions:
```sql
-- tests/assert_total_revenue_positive.sql
SELECT order_id
FROM {{ ref('fct_orders') }}
WHERE total_revenue < 0
-- test passes if this returns 0 rows
```

**When to use each:** Generic for standard column-level rules; singular for complex business logic (e.g., revenue can't exceed contract value, refund date must be after order date).

---

## Key Stories — Map to ZS JD

| Your Work | ZS JD Angle |
|---|---|
| Generic incremental macros → 100+ days saved | Jinja macro development, reusable transformation logic |
| 70% runtime reduction via materialization configs | Materialization strategy, query optimization |
| TDD for 600 models (count/metadata/mismatch) | Data quality framework, generic + singular tests |
| Multi-engine dbt macros (Snowflake + Redshift) | Reusable transformation logic, cross-platform |
| dbt Slim CI implementation | CI/CD for dbt, automated testing on PRs |
| Airflow + Trino for model validation | Orchestration integration |
| Data Mesh with Alation | Data governance, lineage tracking, documentation |
| Snowflake ↔ Redshift 1M+ row sync | Enterprise data environments, performance at scale |

---

## Day 1 Plan: Fill the Gaps

1. **Data Vault** (45 min) — Hub/Link/Sat concepts, hash keys, insert-only model, when to use vs Kimball. Write a simple example schema.
2. **dbt Snapshots** (30 min) — Write a snapshot config, understand `dbt_valid_from`, `dbt_valid_to`, `dbt_scd_id`. Know `timestamp` vs `check` strategy.
3. **dbt-utils + dbt-expectations** (30 min) — Skim both package READMEs. Know 3–4 functions from each.
4. **Elementary** (20 min) — Know what it does conceptually, how it integrates.
5. **Model contracts** (20 min) — Know the YAML syntax, why it matters for governance.

---

## Day 2 Plan: Technical Depth + Behavioral Prep

### SQL Window Functions — Know Cold
ZS will test SQL. Be ready for:
```sql
ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY order_date DESC)
RANK() / DENSE_RANK()
LAG(revenue, 1) OVER (PARTITION BY region ORDER BY month)
LEAD(revenue, 1) OVER (...)
SUM(revenue) OVER (PARTITION BY customer_id ORDER BY order_date ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
NTILE(4) OVER (ORDER BY revenue)  -- quartiles
```

### Incremental Model Strategies — Go Deep
```
append         → just INSERT new rows (no dedup)
merge          → UPSERT by unique_key (most common)
insert_overwrite → overwrite partitions (BigQuery/Spark pattern)
delete+insert  → delete matching rows then insert (Snowflake alternative)
```

### Behavioral Questions
1. Walk me through a dbt project you built from scratch or significantly improved.
   → 600-model TDD paradigm, Data Mesh migration
2. How do you handle data quality failures in a production pipeline?
   → Slim CI blocking PRs, automated test gates, generic macros
3. Describe a time you optimized a slow transformation.
   → 70% runtime reduction — which materialization, why, what you measured
4. How do you approach mentoring junior engineers?
   → Generic macro documentation, reusable framework they could build on

---

## Experience Years Gap — 3+ Years Required, You Have ~2

> "I have roughly 2 years of experience but I've built production dbt pipelines that most engineers encounter 4–5 years in — 600-model TDD frameworks, multi-engine macro libraries, Slim CI pipelines. dbt has been my primary stack since day one, and the depth of my work at phData goes significantly beyond typical junior scope. I hold Databricks, AWS, and Snowflake certifications. I'm confident in meeting the technical bar for this role."

---

## Questions to Ask ZS

1. What does the data stack look like end-to-end — what feeds into dbt and what consumes the marts?
2. Are you using dbt Core or dbt Cloud, and what's the orchestration layer?
3. How mature is the testing and observability framework today?
4. What does a typical client engagement look like for the BTS team — do you build greenfield or modernize existing platforms?
5. What are the biggest dbt-related challenges on current engagements?

---

## Quick Reference Cheat Sheet

**Data Vault at a glance:**
```
Hub:  hash_key (PK), business_key, load_date, record_source
Link: hash_key (PK), hub_hash_key_1, hub_hash_key_2, load_date, record_source
Sat:  hub/link_hash_key (FK), load_date (PK), hash_diff, attributes...
```

**All 5 materializations:**
```
view → ephemeral → table → incremental → snapshot
```

**Staging rules:**
```
stg_ → rename/cast only, no logic
int_ → logic/joins, ephemeral/view
fct_/dim_ → final, materialized as table/incremental
```

**Slim CI (what you've built):**
```
dbt build --select state:modified+  # run changed models + downstream
dbt test --select state:modified+   # test only what changed
```
