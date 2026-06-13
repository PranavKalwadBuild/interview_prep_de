{%- macro compat_json_parse(value) -%}
    {{ return(adapter.dispatch('compat_json_parse')(value)) }}
{%- endmacro -%}

{%- macro redshift__compat_json_parse(value) -%}
    JSON_PARSE({{ value }})
{%- endmacro -%}

{%- macro snowflake__compat_json_parse(value) -%}
    TRY_PARSE_JSON({{ value }})
{%- endmacro -%}
