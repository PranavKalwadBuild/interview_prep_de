{%- macro compat_bool_or(expr) -%}
    {{ return(adapter.dispatch('compat_bool_or')(expr)) }}
{%- endmacro -%}

{%- macro redshift__compat_bool_or(expr) -%}
    BOOL_OR({{ expr }})
{%- endmacro -%}

{%- macro snowflake__compat_bool_or(expr) -%}
    BOOLOR_AGG({{ expr }})
{%- endmacro -%}
