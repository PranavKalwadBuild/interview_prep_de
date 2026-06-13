{%- macro compat_bool_and(expr) -%}
    {{ return(adapter.dispatch('compat_bool_and')(expr)) }}
{%- endmacro -%}

{%- macro redshift__compat_bool_and(expr) -%}
    BOOL_AND({{ expr }})
{%- endmacro -%}

{%- macro snowflake__compat_bool_and(expr) -%}
    BOOLAND_AGG({{ expr }})
{%- endmacro -%}
