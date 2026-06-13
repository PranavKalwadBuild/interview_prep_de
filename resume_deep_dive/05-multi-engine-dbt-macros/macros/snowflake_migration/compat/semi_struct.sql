{%- macro compat_semi_struct(column, key) -%}
    {{ return(adapter.dispatch('compat_semi_struct')(column, key)) }}
{%- endmacro -%}

{%- macro redshift__compat_semi_struct(column, key) -%}
    {{ column }}.{{ key }}
{%- endmacro -%}

{%- macro snowflake__compat_semi_struct(column, key) -%}
    {{ column }}:{{ key }}
{%- endmacro -%}
