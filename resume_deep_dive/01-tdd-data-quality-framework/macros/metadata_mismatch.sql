{%- macro metadata_mismatch(view_name, table_name) -%}
    {%- set view_parts  = view_name.split('.')  %}
    {%- set table_parts = table_name.split('.') %}

    {%- set view_db     = view_parts[0] %}
    {%- set view_schema = view_parts[1] %}
    {%- set view_tbl    = view_parts[2] %}

    {%- set table_db     = table_parts[0] %}
    {%- set table_schema = table_parts[1] %}
    {%- set table_tbl    = table_parts[2] %}

    {%- set system_cols = ['EFF_DATE_TO','LOAD_DATE','EFF_DATE_FROM','SOURCE_SYSTEM','FLAG','ACTIVE'] %}

    {%- set mismatch_query %}
        WITH legacy_details_edw AS (
            SELECT column_name, data_type, CHARACTER_MAXIMUM_LENGTH, NUMERIC_SCALE, DATETIME_PRECISION
            FROM {{ table_db }}.INFORMATION_SCHEMA.COLUMNS
            WHERE table_schema = '{{ table_schema }}'
              AND table_name   = '{{ table_tbl }}'
              AND column_name  NOT IN ({{ system_cols | map('tojson') | join(', ') }})
              AND column_name  NOT ILIKE '%PK'
              AND column_name  NOT ILIKE '%HK'
        ),
        core_published_edw AS (
            SELECT column_name, data_type, CHARACTER_MAXIMUM_LENGTH, NUMERIC_SCALE, DATETIME_PRECISION
            FROM {{ view_db }}.INFORMATION_SCHEMA.COLUMNS
            WHERE table_schema = '{{ view_schema }}'
              AND (
                  table_name = 'V_{{ table_tbl }}_CFIN'
               OR table_name = 'V_{{ table_tbl }}_EWM'
               OR table_name = 'V_{{ table_tbl }}_GLOBAL'
               OR table_name = 'V_{{ table_tbl }}'
              )
              AND column_name NOT ILIKE '%PK'
              AND column_name NOT ILIKE '%HK'
        )
        SELECT
            l.column_name                   AS legacy_column,
            l.data_type                     AS legacy_type,
            c.data_type                     AS new_type,
            l.CHARACTER_MAXIMUM_LENGTH      AS legacy_max_len,
            c.CHARACTER_MAXIMUM_LENGTH      AS new_max_len,
            l.NUMERIC_SCALE                 AS legacy_num_scale,
            c.NUMERIC_SCALE                 AS new_num_scale,
            l.DATETIME_PRECISION            AS legacy_dt_prec,
            c.DATETIME_PRECISION            AS new_dt_prec
        FROM legacy_details_edw l
        LEFT JOIN core_published_edw c ON l.column_name = c.column_name
        WHERE l.data_type                   IS DISTINCT FROM c.data_type
           OR l.CHARACTER_MAXIMUM_LENGTH    IS DISTINCT FROM c.CHARACTER_MAXIMUM_LENGTH
           OR l.NUMERIC_SCALE               IS DISTINCT FROM c.NUMERIC_SCALE
           OR l.DATETIME_PRECISION          IS DISTINCT FROM c.DATETIME_PRECISION
    {%- endset %}

    {%- set results = run_query(mismatch_query) %}
    {%- set mismatch_count = results | length %}

    {{ log("METADATA VALIDATION: " ~ view_name ~ " vs " ~ table_name, info=True) }}
    {{ log("  Column mismatches found: " ~ mismatch_count, info=True) }}

    {{ return(mismatch_count) }}
{%- endmacro -%}
