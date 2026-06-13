## Bullet 10 — Automated dbt Model Validation with Airflow & Trino

> *"Automated dbt model validation using Airflow and Trino, reducing manual data validation time by 120 hours and allowing the team to refocus on development."*

> **Project Context:** Gusto — Redshift to Snowflake migration, automated readiness gate for dbt models tagged `snowflake-ready`
> **Tech:** Apache Airflow (DAG), Apache Trino (federated SQL), dbt tags, EXCEPT queries, email alerting
> **Impact:** Eliminated 120 hours of manual data validation, unblocking the team to refocus on development

---

### The First Thing to Say in Any Interview

During the Redshift-to-Snowflake migration at Gusto, we had dozens of dbt models being promoted to Snowflake incrementally. Each model was tagged `snowflake-ready` in dbt once it was considered production-eligible. But "ready" was a human judgment call — there was no automated gate verifying the data in Snowflake actually matched Redshift. Engineers were manually running spot checks. That was costing the team over 120 hours of validation work. I automated the entire gate using an Airflow DAG that ran federated EXCEPT queries on Apache Trino, with email alerting on failure.

---

### The Problem (1 minute — make it hard)

The migration wasn't a big-bang cutover. Models were promoted to Snowflake one at a time, tagged `snowflake-ready` in dbt. The question for each model: do the rows in Snowflake exactly match Redshift, on the business keys that matter?

The validation pattern: **if Snowflake is a perfect mirror of Redshift, an EXCEPT query between the two should return zero rows.** If even one row comes back, something is wrong. This is a mathematically clean assertion: empty set = pass, non-empty = fail.

---

### The Architecture (2 minutes — go deep)

**Why Trino?** Trino is a **federated query engine** — it can query Redshift and Snowflake in the same SQL statement using catalog prefixes. Instead of extracting data out of each system and comparing in Python, a single SQL query executes across both catalogs simultaneously. No data movement, no intermediate files.

**The EXCEPT Query Pattern:**

```sql
-- Returns rows in Redshift NOT in Snowflake
SELECT merge_key_1, col_a, col_b
FROM redshift_catalog.bi.model_name

EXCEPT

SELECT merge_key_1, col_a, col_b
FROM snowflake_catalog.bi.model_name
```

Both directions are checked for full symmetry:

```sql
-- Direction 1: In Redshift but NOT in Snowflake (missing records)
SELECT ... FROM redshift.bi.model EXCEPT SELECT ... FROM snowflake.bi.model

-- Direction 2: In Snowflake but NOT in Redshift (extra records or drift)
SELECT ... FROM snowflake.bi.model EXCEPT SELECT ... FROM redshift.bi.model
```

**The dbt Tag Integration:**

The Airflow DAG dynamically discovers models from the dbt manifest tagged `snowflake-ready` — as engineers tag new models, they are automatically picked up in the next DAG run. No config updates needed.

**The Airflow DAG Structure:**

```text
DAG: dbt_snowflake_validation
  ↓
[Task 1] discover_snowflake_ready_models
    → reads dbt manifest, outputs list of (schema, model, merge_keys)
  ↓
[Task 2] run_except_queries  (dynamic mapped task — one per model, parallel)
    → executes both EXCEPT directions on Trino
    → records row count per direction
  ↓
[Task 3] evaluate_results
    → if any model has non-zero EXCEPT count → FAILED
    → if all models have zero EXCEPT count → PASSED
  ↓
[Task 4 — conditional] send_failure_alert
    → triggered only on FAILED
    → sends email listing each failing model, direction, and row count
```

---

### The Merge Key Design

EXCEPT is scoped to **merge keys plus business columns** — audit columns (`etl_insert_ts`, `dbt_updated_at`) are excluded for the same reason as the SHA2 framework. The merge key is the uniqueness anchor: `company_id` for companies, `(company_id, month)` for monthly aggregates.

---

### The Alerting Mechanism

When divergence is detected, Airflow's `EmailOperator` fires with a structured failure report:

```text
Subject: [VALIDATION FAILED] dbt snowflake-ready models

[VALIDATION FAILED] 2 of 14 models failed.

Model : companies
  Redshift → Snowflake (rows missing in SF) : 142
  Snowflake → Redshift (extra rows in SF)   : 0

Model : company_monthly_data
  Redshift → Snowflake (rows missing in SF) : 0
  Snowflake → Redshift (extra rows in SF)   : 891

Action required: investigate pipeline sync before promoting these models.
```

---

### Results

- **120 hours of manual validation eliminated** across the team
- Every `snowflake-ready` model validated on every nightly DAG run — not just spot-checked once at promotion time
- Teams unblocked to focus on development
- The empty-set assertion is a **mathematically provable correctness guarantee** — not a probabilistic sample

---

### Key Technical Terms

- **Apache Trino** as a federated query engine — cross-catalog SQL without data movement
- **EXCEPT operator** as a mathematical set-difference assertion
- **dbt manifest** for dynamic model discovery via `snowflake-ready` tag
- **Airflow dynamic mapped tasks** for parallel per-model validation
- **Bidirectional EXCEPT** — both directions checked for completeness
- **Empty-set assertion** — provable correctness guarantee, not probabilistic sampling
- **EmailOperator** with structured failure payload
- **Merge key scoping** — validate on business identity columns, exclude audit metadata

---

### One-Liner Summary

> "I automated dbt model validation for the Redshift-to-Snowflake migration using an Airflow DAG that dynamically discovers `snowflake-ready` models, runs bidirectional EXCEPT queries on Apache Trino across both catalogs, and fires a failure email with actionable details when any divergence is detected — eliminating 120 hours of manual validation work."

---

### Anticipated Follow-up Questions

**Q: Why EXCEPT instead of COUNT(*) comparison?**
> COUNT tells you quantities are the same, not values. Two tables can have 100,000 rows each where every row is different — COUNT passes, EXCEPT catches all 100,000 mismatches. EXCEPT is a stricter, semantically richer assertion.

**Q: Why Trino instead of running queries in each system separately?**
> Trino's federated execution means a single SQL statement touches both catalogs — no Python orchestration of two separate connections, no intermediate CSV files, no memory constraints. The comparison happens inside the query engine.

**Q: What happens if a model doesn't have a defined merge key?**
> The model is flagged as `VALIDATION_SKIPPED` and added to a separate alert so it doesn't silently pass without being checked.

**Q: How do you handle the audit column problem?**
> Same philosophy as SHA2: exclude `etl_insert_ts`, `dbt_updated_at`, and all pipeline metadata columns from the EXCEPT SELECT list. We're asserting business data equality, not infrastructure timestamp equality.

**Q: What does the DAG schedule look like?**
> Nightly at 06:00 UTC — after the overnight ETL pipeline has completed both Redshift and Snowflake loads, giving the pipeline time to sync before asserting equality.

---

### Sample Code — Full Implementation

#### 1. dbt `schema.yml` — tagging models as `snowflake-ready`

```yaml
models:
  - name: companies
    description: "Core company dimension"
    config:
      tags: ["snowflake-ready"]
    meta:
      merge_keys: ["company_id"]
      date_filter_column: created_date
      date_filter_start: "2025-01-01"
      date_filter_end: "2025-12-31"
      exclude_columns:
        - etl_insert_ts
        - etl_update_ts
        - dbt_updated_at
        - dbt_valid_from
        - dbt_valid_to
        - dbt_scd_id

  - name: company_monthly_data
    description: "Monthly aggregates per company"
    config:
      tags: ["snowflake-ready"]
    meta:
      merge_keys: ["company_id", "month"]
      date_filter_column: month
      date_filter_start: "2025-01-01"
      date_filter_end: "2025-12-31"
      exclude_columns:
        - etl_insert_ts
        - etl_update_ts
```

#### 2. Trino EXCEPT Query Builder (`trino_except_queries.py`)

```python
import trino
from dataclasses import dataclass
from typing import Optional

AUDIT_COLUMNS = {
    "etl_insert_ts", "etl_update_ts", "dbt_updated_at",
    "dbt_valid_from", "dbt_valid_to", "dbt_scd_id",
    "dbt_incremental_ts", "etl_comments", "last_modified"
}

REDSHIFT_CATALOG = "redshift"
SNOWFLAKE_CATALOG = "snowflake"
SCHEMA = "bi"


@dataclass
class ModelConfig:
    model_name: str
    merge_keys: list[str]
    date_filter_column: Optional[str] = None
    date_filter_start: Optional[str] = None
    date_filter_end: Optional[str] = None
    exclude_columns: list[str] = None


def get_trino_connection():
    return trino.dbapi.connect(
        host="trino.internal.gusto.com",
        port=443,
        user="airflow-svc",
        http_scheme="https",
        auth=trino.auth.OAuth2Authentication(),
    )


def get_business_columns(conn, catalog: str, schema: str, table: str, extra_excludes: list[str]) -> list[str]:
    """Fetch column list from Trino information_schema, strip audit cols."""
    query = f"""
        SELECT column_name
        FROM {catalog}.information_schema.columns
        WHERE table_schema = '{schema}'
          AND table_name   = '{table}'
        ORDER BY ordinal_position
    """
    cursor = conn.cursor()
    cursor.execute(query)
    all_columns = [row[0] for row in cursor.fetchall()]

    excluded = AUDIT_COLUMNS | set(extra_excludes or [])
    return [col for col in all_columns if col not in excluded]


def build_except_query(
    catalog_a: str,
    catalog_b: str,
    schema: str,
    table: str,
    columns: list[str],
    date_filter_column: Optional[str],
    date_filter_start: Optional[str],
    date_filter_end: Optional[str],
) -> str:
    """
    Returns SQL that counts rows in catalog_a NOT present in catalog_b.
    Result > 0 means divergence in that direction.
    """
    col_list = ",\n        ".join(
        f"CAST({col} AS VARCHAR) AS {col}" for col in columns
    )

    date_clause = ""
    if date_filter_column and date_filter_start and date_filter_end:
        date_clause = f"WHERE {date_filter_column} BETWEEN DATE '{date_filter_start}' AND DATE '{date_filter_end}'"

    return f"""
SELECT COUNT(*) AS divergent_rows FROM (
    SELECT
        {col_list}
    FROM {catalog_a}.{schema}.{table}
    {date_clause}

    EXCEPT

    SELECT
        {col_list}
    FROM {catalog_b}.{schema}.{table}
    {date_clause}
)""".strip()


def run_except_validation(model: ModelConfig) -> dict:
    """Runs bidirectional EXCEPT for one model. Returns pass/fail result dict."""
    conn = get_trino_connection()

    columns = get_business_columns(
        conn, REDSHIFT_CATALOG, SCHEMA, model.model_name,
        model.exclude_columns or []
    )

    rs_not_sf_sql = build_except_query(
        REDSHIFT_CATALOG, SNOWFLAKE_CATALOG, SCHEMA, model.model_name,
        columns, model.date_filter_column, model.date_filter_start, model.date_filter_end
    )
    sf_not_rs_sql = build_except_query(
        SNOWFLAKE_CATALOG, REDSHIFT_CATALOG, SCHEMA, model.model_name,
        columns, model.date_filter_column, model.date_filter_start, model.date_filter_end
    )

    cursor = conn.cursor()

    cursor.execute(rs_not_sf_sql)
    rs_not_sf_count = cursor.fetchone()[0]

    cursor.execute(sf_not_rs_sql)
    sf_not_rs_count = cursor.fetchone()[0]

    conn.close()

    return {
        "model": model.model_name,
        "rs_not_sf": rs_not_sf_count,
        "sf_not_rs": sf_not_rs_count,
        "status": "PASS" if (rs_not_sf_count == 0 and sf_not_rs_count == 0) else "FAIL",
    }
```

#### 3. Airflow DAG (`dbt_snowflake_validation_dag.py`)

```python
from __future__ import annotations

import json
from datetime import datetime, timedelta

from airflow.decorators import dag, task
from airflow.operators.email import EmailOperator
from airflow.utils.trigger_rule import TriggerRule

from trino_except_queries import ModelConfig, run_except_validation

DBT_MANIFEST_PATH = "/opt/airflow/dbt/manifest.json"
ALERT_EMAIL = "data-engineering@gusto.com"


def _load_snowflake_ready_models() -> list[ModelConfig]:
    """Parse dbt manifest.json and extract all models tagged snowflake-ready."""
    with open(DBT_MANIFEST_PATH) as f:
        manifest = json.load(f)

    models = []
    for node_id, node in manifest["nodes"].items():
        if node.get("resource_type") != "model":
            continue
        if "snowflake-ready" not in node.get("tags", []):
            continue

        meta = node.get("meta", {})
        merge_keys = meta.get("merge_keys")
        if not merge_keys:
            continue  # Skip models without declared merge keys

        models.append(ModelConfig(
            model_name=node["name"],
            merge_keys=merge_keys,
            date_filter_column=meta.get("date_filter_column"),
            date_filter_start=meta.get("date_filter_start"),
            date_filter_end=meta.get("date_filter_end"),
            exclude_columns=meta.get("exclude_columns", []),
        ))

    return models


@dag(
    dag_id="dbt_snowflake_validation",
    schedule_interval="0 6 * * *",        # 06:00 UTC daily — after overnight ETL
    start_date=datetime(2025, 1, 1),
    catchup=False,
    default_args={
        "retries": 1,
        "retry_delay": timedelta(minutes=5),
        "owner": "data-engineering",
    },
    tags=["validation", "snowflake-migration"],
)
def dbt_snowflake_validation():

    @task
    def discover_models() -> list[dict]:
        """Return serializable list of model configs from dbt manifest."""
        return [
            {
                "model_name": m.model_name,
                "merge_keys": m.merge_keys,
                "date_filter_column": m.date_filter_column,
                "date_filter_start": m.date_filter_start,
                "date_filter_end": m.date_filter_end,
                "exclude_columns": m.exclude_columns,
            }
            for m in _load_snowflake_ready_models()
        ]

    @task
    def validate_model(model_cfg: dict) -> dict:
        """Run bidirectional EXCEPT on Trino for one model."""
        return run_except_validation(ModelConfig(**model_cfg))

    @task
    def evaluate_results(results: list[dict]) -> dict:
        failures = [r for r in results if r["status"] == "FAIL"]
        return {
            "total_models": len(results),
            "passed": len(results) - len(failures),
            "failed": len(failures),
            "failures": failures,
        }

    @task.branch
    def check_failures(summary: dict) -> str:
        return "send_failure_alert" if summary["failed"] > 0 else "validation_passed"

    @task
    def validation_passed():
        print("All snowflake-ready models passed validation.")

    @task(trigger_rule=TriggerRule.NONE_FAILED_MIN_ONE_SUCCESS)
    def build_alert_body(summary: dict) -> str:
        lines = [f"[VALIDATION FAILED] {summary['failed']} of {summary['total_models']} models failed.\n"]
        for f in summary["failures"]:
            lines.append(
                f"Model : {f['model']}\n"
                f"  Redshift → Snowflake (rows missing in SF) : {f['rs_not_sf']}\n"
                f"  Snowflake → Redshift (extra rows in SF)   : {f['sf_not_rs']}\n"
            )
        lines.append("\nAction required: investigate pipeline sync before promoting these models.")
        return "\n".join(lines)

    model_cfgs = discover_models()
    results = validate_model.expand(model_cfg=model_cfgs)   # parallel fan-out
    summary = evaluate_results(results)
    branch = check_failures(summary)
    alert_body = build_alert_body(summary)

    send_alert = EmailOperator(
        task_id="send_failure_alert",
        to=ALERT_EMAIL,
        subject="[VALIDATION FAILED] dbt snowflake-ready models",
        html_content="{{ task_instance.xcom_pull(task_ids='build_alert_body') | replace('\n', '<br>') }}",
    )

    branch >> [send_alert, validation_passed()]
    alert_body >> send_alert


dbt_snowflake_validation()
```

#### 4. End-to-End Generated Trino EXCEPT Query

For `companies`, `company_id` merge key, date-filtered to 2025:

```sql
-- Direction 1: Rows in Redshift NOT in Snowflake
SELECT COUNT(*) AS divergent_rows FROM (
    SELECT
        CAST(company_id AS VARCHAR) AS company_id,
        CAST(company_name AS VARCHAR) AS company_name,
        CAST(created_date AS VARCHAR) AS created_date,
        CAST(industry AS VARCHAR) AS industry,
        CAST(is_active AS VARCHAR) AS is_active,
        CAST(plan_type AS VARCHAR) AS plan_type
    FROM redshift.bi.companies
    WHERE created_date BETWEEN DATE '2025-01-01' AND DATE '2025-12-31'

    EXCEPT

    SELECT
        CAST(company_id AS VARCHAR) AS company_id,
        CAST(company_name AS VARCHAR) AS company_name,
        CAST(created_date AS VARCHAR) AS created_date,
        CAST(industry AS VARCHAR) AS industry,
        CAST(is_active AS VARCHAR) AS is_active,
        CAST(plan_type AS VARCHAR) AS plan_type
    FROM snowflake.bi.companies
    WHERE created_date BETWEEN DATE '2025-01-01' AND DATE '2025-12-31'
)
-- Expected: 0 rows → PASS
-- Any non-zero count → FAIL → email alert fires
```

---

### Pitfalls to Avoid

- **Don't say "I ran SQL queries to compare data."** Be specific: bidirectional EXCEPT on a federated Trino engine, not two separate database connections. The federated part is what makes this architecturally interesting.
- **Don't forget to mention both directions.** One-directional EXCEPT misses extra records in Snowflake. Bidirectionality is what makes it a complete assertion.
- **Don't undersell the dynamic discovery.** The DAG auto-discovers `snowflake-ready` models from the dbt manifest — engineers don't have to update any validation config when they tag a new model. That's the operationalization win.
- **Don't conflate this with the SHA2 framework.** SHA2 is row-level cryptographic hashing for deep field-level comparison. EXCEPT is a set-difference gate for go/no-go readiness. They solve different problems at different granularities — be ready to explain when you'd use each.
- **Connect the 120 hours to scale.** That number only makes sense if you explain *how many models* and *how often* validation was needed. The more models tagged `snowflake-ready`, the more manual work the DAG displaces on every run.

---

---
