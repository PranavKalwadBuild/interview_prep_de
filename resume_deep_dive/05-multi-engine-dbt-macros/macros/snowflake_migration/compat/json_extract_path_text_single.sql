{%- macro compat_json_extract_path_text_single(json_str, key) -%}
    {{ return(adapter.dispatch('compat_json_extract_path_text_single')(json_str, key)) }}
{%- endmacro -%}

{%- macro redshift__compat_json_extract_path_text_single(json_str, key) -%}
    JSON_EXTRACT_PATH_TEXT({{ json_str }}, {{ key }}, TRUE)
{%- endmacro -%}

{%- macro snowflake__compat_json_extract_path_text_single(json_str, key) -%}
    JSON_EXTRACT_PATH_TEXT(TRY_PARSE_JSON({{ json_str }}), {{ key }})
{%- endmacro -%}
