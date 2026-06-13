{%- macro drop_pr_schema() -%}
    {%- set schema_lower = target.schema | lower -%}
    {%- if execute -%}
        {%- if not schema_lower.startswith('dbt_cloud_pr') -%}
            {{ exceptions.raise_compiler_error(
                "drop_pr_schema: target.schema '" ~ target.schema ~
                "' does not start with 'dbt_cloud_pr'. " ~
                "Refusing to drop a non-PR schema. Check your target configuration."
            ) }}
        {%- else -%}
            {%- set drop_sql %}
                DROP SCHEMA IF EXISTS {{ target.database }}.{{ target.schema }}
            {%- endset %}
            {{ log("Dropping PR schema: " ~ target.database ~ "." ~ target.schema, info=True) }}
            {%- do run_query(drop_sql) -%}
            {{ log("Schema dropped successfully.", info=True) }}
        {%- endif -%}
    {%- endif -%}
{%- endmacro -%}
