{%- macro data_mismatch(source_table, target_table) -%}
    {%- set source_parts = source_table.split('.') %}
    {%- set target_parts = target_table.split('.') %}

    {%- set common_cols_query %}
        SELECT column_name, data_type
        FROM {{ source_parts[0] }}.INFORMATION_SCHEMA.COLUMNS
        WHERE table_schema = '{{ source_parts[1] }}'
          AND table_name   = '{{ source_parts[2] }}'
          AND column_name NOT ILIKE '%PK'
          AND column_name NOT ILIKE '%HK'
          AND column_name NOT IN ('LOAD_DATE','INTIAL_LOAD_DATE')

        INTERSECT

        SELECT column_name, data_type
        FROM {{ target_parts[0] }}.INFORMATION_SCHEMA.COLUMNS
        WHERE table_schema = '{{ target_parts[1] }}'
          AND table_name   = '{{ target_parts[2] }}'
          AND column_name NOT ILIKE '%PK'
          AND column_name NOT ILIKE '%HK'
          AND column_name NOT IN ('LOAD_DATE','INTIAL_LOAD_DATE')

        ORDER BY column_name
    {%- endset %}

    {%- set col_results = run_query(common_cols_query) %}

    {%- set select_exprs = [] %}
    {%- for row in col_results.rows %}
        {%- set col  = row[0] %}
        {%- set dtype = row[1] | upper %}
        {%- if dtype in ('TEXT','VARCHAR','CHAR','STRING') %}
            {%- do select_exprs.append("IFF(" ~ col ~ " = ' ', '', " ~ col ~ ") AS " ~ col) %}
        {%- else %}
            {%- do select_exprs.append(col) %}
        {%- endif %}
    {%- endfor %}

    {%- set except_query %}
        SELECT COUNT(*) AS mismatch_count FROM (
            SELECT {{ select_exprs | join(', ') }}
            FROM {{ target_table }}

            EXCEPT

            SELECT {{ select_exprs | join(', ') }}
            FROM {{ source_table }}
        )
    {%- endset %}

    {%- set mismatch_result = run_query(except_query) %}
    {%- set mismatch_count  = mismatch_result.columns[0].values()[0] %}

    {{ log("DATA MISMATCH: " ~ source_table ~ " vs " ~ target_table, info=True) }}
    {{ log("  Mismatch rows: " ~ mismatch_count, info=True) }}

    {{ return(mismatch_count) }}
{%- endmacro -%}
