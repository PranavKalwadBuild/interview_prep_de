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
