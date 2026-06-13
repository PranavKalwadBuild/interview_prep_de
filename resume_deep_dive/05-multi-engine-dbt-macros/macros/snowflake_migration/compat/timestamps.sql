{%- macro compat_current_timestamp() -%}
    {{ return(adapter.dispatch('compat_current_timestamp')()) }}
{%- endmacro -%}

{%- macro redshift__compat_current_timestamp() -%}
    GETDATE()
{%- endmacro -%}

{%- macro snowflake__compat_current_timestamp() -%}
    CURRENT_TIMESTAMP()
{%- endmacro -%}

{%- macro compat_date_diff(datepart, start_date, end_date) -%}
    {{ return(adapter.dispatch('compat_date_diff')(datepart, start_date, end_date)) }}
{%- endmacro -%}

{%- macro redshift__compat_date_diff(datepart, start_date, end_date) -%}
    DATEDIFF({{ datepart }}, {{ start_date }}, {{ end_date }})
{%- endmacro -%}

{%- macro snowflake__compat_date_diff(datepart, start_date, end_date) -%}
    DATEDIFF({{ datepart }}, {{ start_date }}, {{ end_date }})
{%- endmacro -%}
-- NOTE: DATEDIFF syntax is identical; include for completeness and future-proofing
-- CONVERT_TIMEZONE and TIMESTAMP_NTZ vs TIMESTAMP handling differ — extend here as needed
