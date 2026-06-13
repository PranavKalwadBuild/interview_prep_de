-- Snowflake Python UDF: replicates Redshift's STRTOL function
-- Converts a string in any numeric base to a decimal integer
-- Handles: NULL, empty string, null-char prefix, leading whitespace, 0x prefix (base 16), sign chars
CREATE OR REPLACE FUNCTION f_strtol_sf(s VARCHAR, base INT)
RETURNS BIGINT
LANGUAGE PYTHON
RUNTIME_VERSION = '3.8'
HANDLER = 'strtol_impl'
AS $$
def strtol_impl(s, base):
    if s is None:
        return None
    s_stripped = s.lstrip()
    if not s_stripped or s_stripped[0] == '\x00':
        return 0
    if base == 16 and s_stripped.lower().startswith('0x'):
        s_stripped = s_stripped[2:]
    try:
        return int(s_stripped, base)
    except (ValueError, TypeError):
        return None
$$;
