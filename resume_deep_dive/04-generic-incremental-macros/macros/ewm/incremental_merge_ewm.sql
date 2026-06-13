{%- macro incremental_merge_ewm(source_table, target_schema, reference_seed, unique_key_columns) -%}
    -- EWM (Extended Warehouse Management) source
    -- Same pattern as CFIN; EWM tables use LGNUM (warehouse number) as an additional key dimension

    {%- set cols_query %}
        SELECT column_name, ordinal_position
        FROM information_schema.columns
        WHERE table_schema = '{{ source_table.split('.')[1] }}'
          AND table_name   = '{{ source_table.split('.')[2] }}'
        ORDER BY ordinal_position
    {%- endset %}

    {%- set col_results = run_query(cols_query) %}

    {%- set hash_cols = [] %}
    {%- for row in col_results.rows %}
        {%- set col = row[0] %}
        {%- if col not in unique_key_columns and col != '_FIVETRAN_SYNCED' %}
            {%- do hash_cols.append("COALESCE(CAST(" ~ col ~ " AS VARCHAR), '')") %}
        {%- endif %}
    {%- endfor %}

    {%- set hash_expr = hash_cols | join(" || '|' || ") %}

    WITH source_cte AS (
        SELECT
            *,
            SHA2(HASH({{ hash_expr }}), 256) AS _hash_key
        FROM {{ source_table }}
        WHERE _FIVETRAN_SYNCED > COALESCE(
            (SELECT MAX(_FIVETRAN_SYNCED) FROM {{ this }}),
            '1900-01-01'::TIMESTAMP
        )
    )

    {%- if is_incremental() %}
    SELECT s.*
    FROM source_cte s
    LEFT JOIN {{ this }} tgt
        ON {% for key in unique_key_columns -%}
            (tgt.{{ key }} = s.{{ key }} OR (tgt.{{ key }} IS NULL AND s.{{ key }} IS NULL))
            {%- if not loop.last %} AND {% endif %}
        {%- endfor %}
    WHERE tgt.{{ unique_key_columns[0] }} IS NULL
       OR s._hash_key != tgt._hash_key
    {%- else %}
    SELECT * FROM source_cte
    {%- endif %}

{%- endmacro -%}
