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
