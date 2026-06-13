{%- macro count(view_name, table_name) -%}
    {%- set view_count_query %}
        SELECT COUNT(*) FROM {{ view_name }}
    {%- endset %}
    {%- set table_count_query %}
        SELECT COUNT(*) FROM {{ table_name }}
    {%- endset %}
    {%- set diff_query %}
        SELECT (SELECT COUNT(*) FROM {{ view_name }}) - (SELECT COUNT(*) FROM {{ table_name }}) AS count_diff
    {%- endset %}

    {%- set view_result   = run_query(view_count_query) %}
    {%- set table_result  = run_query(table_count_query) %}
    {%- set diff_result   = run_query(diff_query) %}

    {%- set view_count  = view_result.columns[0].values()[0]  %}
    {%- set table_count = table_result.columns[0].values()[0] %}
    {%- set count_diff  = diff_result.columns[0].values()[0]  %}

    {%- if view_count != 0 %}
        {%- set pct_variation = ((view_count - table_count) / view_count * 100) | round(2) %}
    {%- else %}
        {%- set pct_variation = 0 %}
    {%- endif %}

    {{ log("COUNT VALIDATION: " ~ view_name ~ " vs " ~ table_name, info=True) }}
    {{ log("  view_count  : " ~ view_count,   info=True) }}
    {{ log("  table_count : " ~ table_count,  info=True) }}
    {{ log("  count_diff  : " ~ count_diff,   info=True) }}
    {{ log("  pct_variation: " ~ pct_variation ~ "%", info=True) }}

    {{ return(count_diff) }}
{%- endmacro -%}
