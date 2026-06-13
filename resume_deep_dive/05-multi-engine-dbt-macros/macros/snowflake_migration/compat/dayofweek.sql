{%- macro compat_dayofweek(date_expr) -%}
    {{ return(adapter.dispatch('compat_dayofweek')(date_expr)) }}
{%- endmacro -%}

{%- macro redshift__compat_dayofweek(date_expr) -%}
    date_part('dow', {{ date_expr }})
{%- endmacro -%}

{%- macro snowflake__compat_dayofweek(date_expr) -%}
    DAYOFWEEK({{ date_expr }}) - 1
{%- endmacro -%}
-- NOTE: -1 corrects for Snowflake WEEK_START=1 (Monday) account setting
-- Redshift always returns 0=Sun..6=Sat; Snowflake with WEEK_START=1 returns 1=Mon..7=Sun
-- Subtracting 1 aligns to 0=Mon..6=Sun, matching Redshift numeric output
