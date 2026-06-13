# EnvironmentVariablesConfig.py
# Databricks notebook: all secrets fetched from Azure Key Vault via Databricks secret scope.
# NEVER hardcode credentials here — these are Key Vault secret *names*, not values.

# ── Azure Key Vault secret scope ────────────────────────────────────────────────
kvSecretScope = "key-vault-secrets"

# ── Azure AD / MSAL authentication ──────────────────────────────────────────────
aadTenantID     = 'CORP-OS2-TenantId'       # Key Vault secret name
aadClientID     = 'CORP-OS2-ClientId'       # Key Vault secret name
aadClientSecret = 'CORP-OS2-ClientSecret'   # Key Vault secret name

# Azure OAuth 2.0 token endpoint (specific to the AJG tenant)
AD_AUTH_URL = 'https://login.microsoftonline.com/6cacd170-f897-4b19-ac58-46a23307b80a/oauth2/v2.0/token'

# Microsoft Graph API base (used to call /groups/{id}/members)
GRAPH_API_BASE = 'https://graph.microsoft.com/v1.0'

# ── AD Group → Snowflake Role mapping file ──────────────────────────────────────
# CSV on ADLS: columns [AD_Group, Snowflake_Role]
# Managed by IT — updates picked up automatically on next pipeline run
auto_provision_mapping_file_path = '/mnt/config/ADGroupMapping/AD_Group_Mapping.csv'

# ── Snowflake OAuth authentication ──────────────────────────────────────────────
# Service principal UUID — registered in Azure AD, maps to Snowflake via External OAuth
snowUser              = '8dafa542-a29d-4618-ad10-5d6e9f4ee63d'

# Key Vault secret names (not values)
snowPass              = 'Snowflake-Auto-Provision-Service-Pass'
snowOAuthClientID     = 'Snowflake-OAuth-ClientID'
snowOAuthClientSecret = 'Snowflake-OAuth-ClientSecret'

# Private link endpoint — traffic stays inside Azure VNet, never public internet
snowAccount           = 'ajg-corpus.privatelink'

# Least-privilege provisioning role — can only CREATE USER and GRANT/REVOKE ROLE
snowRole              = 'USERADMIN_AUTOPROVISION'

# Target database and schema for any config tables (e.g. audit log)
snowDatabase          = 'DEV_OS_DX'
snowSchema            = 'CONFIG'

# ── Service account guard ────────────────────────────────────────────────────────
# Regex pattern for Azure AD service principal UUIDs (Object ID format)
# Matches: 8dafa542-a29d-4618-ad10-5d6e9f4ee63d
UUID_PATTERN_STR = r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'

# ── Ownership check ──────────────────────────────────────────────────────────────
# Only modify Snowflake roles owned by this role — skip anything owned by another team
PROVISIONING_OWNER_ROLE = 'USERADMIN_AUTOPROVISION'
