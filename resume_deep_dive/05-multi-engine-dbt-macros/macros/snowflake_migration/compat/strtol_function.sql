{%- macro compat_strtol_function(value, base) -%}
    {{ return(adapter.dispatch('compat_strtol_function')(value, base)) }}
{%- endmacro -%}

{%- macro redshift__compat_strtol_function(value, base) -%}
    strtol({{ value }}, {{ base }})
{%- endmacro -%}

{%- macro snowflake__compat_strtol_function(value, base) -%}
    {{ udf('f_strtol_sf') }}({{ value }}, {{ base }})
{%- endmacro -%}
