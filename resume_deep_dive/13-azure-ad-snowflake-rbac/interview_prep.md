## Bullet 12 — Insurance: Azure AD → Snowflake RBAC Sync Pipeline

> *"Built a Databricks pipeline that syncs Azure AD group membership to Snowflake roles via MSAL and OAuth, auto-generating and executing CREATE/GRANT/REVOKE SQL with ownership checks and service account guards to prevent unintended deletions."*
>
> **Files:** `Notebooks/Utilities/Dev/EnvironmentVariablesConfig.py`
> **Tech Stack:** Databricks, PySpark, Azure AD (MSAL), Snowflake OAuth, Azure Key Vault, ADLS, Python

---

### The First Thing to Say in Any Interview

> *"This was an identity management automation problem, not a data pipeline problem. The client's IT team managed access via Azure Active Directory groups — you added someone to an AD group to give them access to a dataset. But Snowflake has its own access control system built on roles. Without automation, every time someone joined or left an AD group, a Snowflake admin had to manually run GRANT or REVOKE commands to keep both systems in sync. I built a Databricks pipeline that made those two systems the single source of truth — Azure AD is authoritative for who should have access, Snowflake roles reflect that automatically."*

---

### The Problem (1 minute — make it hard)

**Why this is harder than it sounds:**

There are two completely different authentication systems in play simultaneously. Azure AD speaks OAuth 2.0 via the Microsoft Graph API — you authenticate as a service principal using MSAL and get a bearer token. Snowflake speaks its own OAuth dialect — you authenticate to Snowflake itself with a separate OAuth client ID and secret to get a Snowflake session token. These are **two separate auth flows** that must both succeed before the pipeline can do anything.

Beyond authentication, the safety problem is significant. An automated system executing `REVOKE ROLE` statements can cause serious access outages if it gets it wrong. Two failure modes had to be guarded against:

1. **Revoking a service account's access** — service accounts have UUID-format usernames (e.g. `8dafa542-a29d-4618-ad10-5d6e9f4ee63d`). They're not in AD groups — they're provisioned separately by the infrastructure team. A naive sync that removes anyone "not in AD" would revoke a service account and break an automated pipeline.

2. **Modifying a role owned by a different team** — Snowflake roles can be owned by different roles (the role hierarchy). If the pipeline tries to GRANT or REVOKE on a role it doesn't own, it either fails with a permission error or, worse, causes unauthorized modifications. The fix is an **ownership check**: only touch roles owned by `USERADMIN_AUTOPROVISION`.

---

### The Architecture — What the Config File Reveals

The `EnvironmentVariablesConfig.py` file is the architectural blueprint of this pipeline. Every variable in it maps to a specific component:

**Layer 1 — Azure AD Authentication (MSAL client credentials flow)**

```python
aadTenantID     = 'CORP-OS2-TenantId'       # Key Vault secret name
aadClientID     = 'CORP-OS2-ClientId'       # Key Vault secret name
aadClientSecret = 'CORP-OS2-ClientSecret'   # Key Vault secret name
AD_AUTH_URL     = 'https://login.microsoftonline.com/6cacd170-f897-4b19-ac58-46a23307b80a/oauth2/v2.0/token'
```

These are not the actual credentials — they are **Key Vault secret names**. At runtime, Databricks fetches the real values from Azure Key Vault using the Databricks secret scope (`kvSecretScope = "key-vault-secrets"`). The pipeline calls `dbutils.secrets.get(scope="key-vault-secrets", key="CORP-OS2-ClientId")` — Databricks never touches the credential directly.

The `AD_AUTH_URL` is the Azure OAuth 2.0 token endpoint for the specific tenant (`6cacd170-...`). MSAL posts a client credentials grant to this URL with the client ID and secret, and receives an access token scoped to Microsoft Graph. That token is then used to call the Graph API: `GET /groups/{group_id}/members` — which returns the list of users currently in each AD group.

**Layer 2 — AD Group → Snowflake Role Mapping**

```python
auto_provision_mapping_file_path = '/mnt/config/ADGroupMapping/AD_Group_Mapping.csv'
```

This CSV, stored on ADLS, is the translation table. It maps each Azure AD group ID (or display name) to the corresponding Snowflake role name. Example:

| AD_Group | Snowflake_Role |
|----------|----------------|
| `gdp-data-analysts` | `DEV_ANALYST_ROLE` |
| `gdp-data-engineers` | `DEV_ENGINEER_ROLE` |

The pipeline reads this file to know: for each AD group I just queried, which Snowflake role should reflect that membership?

**Layer 3 — Snowflake Authentication (OAuth, not username/password)**

```python
snowUser             = '8dafa542-a29d-4618-ad10-5d6e9f4ee63d'   # service principal UUID
snowPass             = 'Snowflake-Auto-Provision-Service-Pass'   # Key Vault secret name
snowOAuthClientID    = 'Snowflake-OAuth-ClientID'               # Key Vault secret name
snowOAuthClientSecret= 'Snowflake-OAuth-ClientSecret'           # Key Vault secret name
snowAccount          = 'ajg-corpus.privatelink'                  # private link — no public internet
snowRole             = 'USERADMIN_AUTOPROVISION'                 # least-privilege provisioning role
snowDatabase         = 'DEV_OS_DX'
snowSchema           = 'CONFIG'
```

Three things to notice here:

1. **`snowUser` is a UUID** — this is a service principal, not a human. It was registered in Azure AD and granted a Snowflake OAuth client. It cannot log in interactively.
2. **`snowAccount = 'ajg-corpus.privatelink'`** — private link means Snowflake traffic never traverses the public internet. It goes through a private endpoint inside the Azure VNet. This is enterprise-grade network isolation.
3. **`snowRole = 'USERADMIN_AUTOPROVISION'`** — this is a **least-privilege role**. It has exactly the privileges needed to create users and grant/revoke roles — nothing more. If the pipeline were compromised, it could not drop tables, read business data, or modify production schemas.

---

### The Story Arc (STAR format)

**Situation:**
The insurance client managed data access through Azure Active Directory groups. Business users were added to AD groups by IT. But Snowflake access — which roles a user has — was managed separately and manually by the Snowflake admin team. Every onboarding, offboarding, or role change required a manual Snowflake operation.

**Problem:**
With hundreds of users and dozens of AD groups, the manual sync was unsustainable. Access was drifting — people who had left AD groups still had Snowflake roles. Worse, the manual process had no audit trail. The client needed automated, auditable, safe role synchronization — with the specific constraint that service accounts and roles owned by other teams must never be touched.

**Action — the four-step pipeline:**

1. **Fetch AD group membership** — Authenticate to Azure AD using MSAL client credentials (service principal, not user). Call Microsoft Graph API to get current members of each mapped AD group.

2. **Fetch current Snowflake role membership** — Connect to Snowflake via OAuth (service principal auth through the private link endpoint). For each mapped Snowflake role, run `SHOW GRANTS TO ROLE <role>` to get the current list of users who have that role.

3. **Diff and generate SQL** — Compare the two lists:
   - In AD but not in Snowflake → generate `CREATE USER IF NOT EXISTS` + `GRANT ROLE <role> TO USER <user>`
   - In Snowflake but not in AD → generate `REVOKE ROLE <role> FROM USER <user>`

4. **Safety checks before execution:**
   - **Ownership check:** Before modifying any role, query `SHOW ROLES LIKE '<role>'` and verify the `owner` column is `USERADMIN_AUTOPROVISION`. If another role owns it, skip and log — never touch it.
   - **Service account guard:** If the user being REVOKE'd has a UUID-format username (`^[0-9a-f]{8}-[0-9a-f]{4}-...`), skip the REVOKE — it's a service principal. Log it as skipped.
   - Only after both checks pass: execute the SQL against Snowflake.

**Result:**
AD group changes in Azure propagate to Snowflake automatically on each pipeline run. Access is always current. Offboarding removes Snowflake access without a manual ticket. The two safety guards — ownership check and service account guard — ensure the automation never causes unintended access loss.

---

### How to Open (say this first)

> *"This was a classic IAM synchronization problem — Azure AD is the authoritative source for who should have access, but Snowflake has its own role-based access system that was being managed manually. I built a Databricks pipeline that bridges the two: it authenticates to Azure AD via MSAL to read group membership, connects to Snowflake via OAuth through a private link endpoint, diffs the two membership states, and auto-generates and executes the GRANT and REVOKE SQL to bring Snowflake in sync. The interesting engineering is in the safety layer — an ownership check ensures we never modify a Snowflake role we don't own, and a service account guard ensures we never accidentally revoke access from a pipeline service principal just because it's not in an AD group."*

---

### Key Technical Points to Cover

| # | Point | What to say |
|---|-------|-------------|
| 1 | **Two separate auth flows — MSAL and Snowflake OAuth** | "The pipeline needs to authenticate to two completely different systems. For Azure AD: MSAL client credentials flow — service principal posts client ID + secret to the Azure OAuth token endpoint and gets a Graph API bearer token. For Snowflake: a separate OAuth client registered in Snowflake — service principal authenticates and gets a Snowflake session token. These are independent auth mechanisms. Both have to succeed or the pipeline can't run." |
| 2 | **Why Key Vault, not hardcoded credentials** | "Every sensitive value in `EnvironmentVariablesConfig.py` is a Key Vault secret *name*, not the actual credential. The real values live in Azure Key Vault. At runtime, Databricks fetches them via `dbutils.secrets.get(scope='key-vault-secrets', key='CORP-OS2-ClientId')`. This means the credentials never appear in code, never in version control, never in Databricks notebook output. Rotation is a Key Vault operation — no code change." |
| 3 | **Private link — `ajg-corpus.privatelink`** | "The Snowflake account endpoint is `ajg-corpus.privatelink` — not the standard public URL. Traffic between Databricks and Snowflake goes through an Azure private endpoint inside the VNet — never over the public internet. For an insurance client with PII and regulatory requirements, this is a hard security requirement. Private link is also how you satisfy compliance requirements like SOC 2 network isolation controls." |
| 4 | **`USERADMIN_AUTOPROVISION` — the least-privilege principle** | "The pipeline runs as a Snowflake role called `USERADMIN_AUTOPROVISION`. This role has exactly two capabilities: create users and grant/revoke roles. It cannot read any business data, cannot drop any tables, cannot modify any schemas. If the service principal credentials were ever compromised, the blast radius is limited to user provisioning — the attacker cannot exfiltrate data or destroy pipelines." |
| 5 | **Ownership check — why it matters** | "In Snowflake's RBAC hierarchy, every role has an owner role. If you try to grant or revoke on a role you don't own, Snowflake may reject the operation or, if your role has MANAGE GRANTS, succeed unexpectedly. Before touching any role, the pipeline runs `SHOW ROLES LIKE '<role>'` and checks that the `owner` column equals `USERADMIN_AUTOPROVISION`. If it doesn't — another team owns this role — the pipeline skips it and logs a warning. This prevents accidental cross-team modifications." |
| 6 | **Service account guard — the UUID pattern** | "Service accounts in Azure AD have UUID-format usernames — `8dafa542-a29d-4618-ad10-5d6e9f4ee63d`. They're not members of any AD group because they're provisioned by the infrastructure team separately. A naive sync that says 'revoke everyone not in AD' would revoke service accounts and break automated pipelines. The guard checks the username format with a regex before any REVOKE — UUID format → skip, log as protected service account." |
| 7 | **The mapping CSV as the contract** | "`AD_Group_Mapping.csv` on ADLS is the translation layer between the two systems. It's a managed file, not hardcoded — IT can add a new AD group → Snowflake role mapping by updating the CSV, and the next pipeline run picks it up automatically. This means the business rule ('members of AD group X get Snowflake role Y') is owned by IT in a file they control, not buried in code that a data engineer has to change." |

---

### Deep Technical Layer — What's Actually Happening Under the Hood

#### MSAL Client Credentials Flow — The Exact Mechanism

The call is `ConfidentialClientApplication(client_id, authority=f"https://login.microsoftonline.com/{tenant_id}", client_credential=client_secret).acquire_token_for_client(scopes=["https://graph.microsoft.com/.default"])`. MSAL posts a `grant_type=client_credentials` request to `https://login.microsoftonline.com/{tenant_id}/oauth2/v2.0/token` with the client ID and secret. Azure AD validates the service principal and returns a JWT bearer token. The scope `https://graph.microsoft.com/.default` means "give me whatever permissions this app registration has been granted in the Azure portal" — in this case, `GroupMember.Read.All`. MSAL caches this token for its lifetime (typically 3600 seconds). All 50+ Graph API calls the pipeline makes for individual AD groups reuse the same cached token — no re-auth per call.

#### Graph API Pagination — The Silent Truncation Bug

`GET https://graph.microsoft.com/v1.0/groups/{group_id}/members` returns at most 100 members per response by default. If a group has 101+ members, the response body contains `"@odata.nextLink": "https://graph.microsoft.com/v1.0/groups/{id}/members?$skiptoken=..."` alongside the first 100 results. A correct implementation must follow the `nextLink` chain — make a new GET request to that URL, collect the next page, check for another `nextLink`, repeat until the response has no `nextLink` field. Failing to implement pagination silently truncates membership for large groups. The consequence is not a data quality bug — it's a security bug: users at positions 101+ would appear "not in AD" on every pipeline run and have their Snowflake access repeatedly revoked. This is the most dangerous failure mode in this type of IAM sync pipeline.

#### `SHOW GRANTS TO ROLE` — What the Output Actually Looks Like

`SHOW GRANTS TO ROLE DEV_ANALYST_ROLE` returns rows with columns: `created_on`, `privilege`, `granted_on`, `name`, `granted_to`, `grantee_name`, `grant_option`. For user grants, the relevant rows have `granted_to = 'USER'` and `granted_on = 'ROLE'` — meaning "the role DEV_ANALYST_ROLE was granted to user X". `grantee_name` is the Snowflake username. The pipeline must filter specifically on `granted_to = 'USER'` because `SHOW GRANTS TO ROLE` also returns rows for child roles granted to this role (role hierarchy): those rows have `granted_to = 'ROLE'`. Without the filter, child roles would appear in `sf_set` and the diff logic would generate `REVOKE ROLE DEV_ANALYST_ROLE FROM ROLE CHILD_ROLE` — which would silently break the entire role hierarchy.

#### `SHOW ROLES LIKE` — The Ownership Check in Detail

`SHOW ROLES LIKE 'DEV_ANALYST_ROLE'` returns a row with an `owner` column. This is the **role that owns** `DEV_ANALYST_ROLE` in Snowflake's role hierarchy. The pipeline checks `row['owner'] == 'USERADMIN_AUTOPROVISION'`. If `owner` is `SYSADMIN`, `SECURITYADMIN`, or any other role, the pipeline skips this role entirely and logs a warning. Why this matters: in Snowflake, only the owner of a role (or a role with MANAGE GRANTS privilege) can grant or revoke that role to/from users. If the pipeline tries to `GRANT DEV_ANALYST_ROLE TO USER john.doe` but `USERADMIN_AUTOPROVISION` doesn't own `DEV_ANALYST_ROLE`, Snowflake will throw a permission error at runtime. The ownership check surfaces this at the diff/validation step rather than at SQL execution time — fail fast and loudly, not mid-batch.

#### Service Account UUID Regex — Why This Pattern

The exact regex is `^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$` (case-insensitive). Azure AD service principals registered as Snowflake users carry their Azure Object ID as the Snowflake `LOGIN_NAME`. The Object ID is a UUID v4 — 128 bits rendered as 8-4-4-4-12 hex groups. This is how Snowflake's External OAuth maps incoming tokens to Snowflake users: the JWT's `oid` claim (the Azure Object ID) must match a Snowflake user's `LOGIN_NAME`. A human user's Snowflake username is typically an email address (`john.doe@company.com`) — it will never match the UUID regex. The guard runs before any REVOKE: for every username in `to_revoke`, check if it matches the UUID pattern. If yes, pop it from the revoke set, log it as `[GUARD] Skipping service account: {username}`, and move on.

#### Snowflake External OAuth — How the Auth Flow Actually Works

The `snowOAuthClientID` and `snowOAuthClientSecret` in the config are **not** Azure AD credentials — they are the credentials for a **Snowflake OAuth security integration**. The Snowflake admin configured an `EXTERNAL OAUTH` security integration that trusts Azure AD as the identity provider (using Azure AD's public JWKS endpoint to validate JWT signatures). At runtime: the pipeline first gets an Azure AD access token via MSAL (scoped to the Snowflake resource URI registered in Azure). Then it connects to Snowflake using `authenticator='oauth'` and `token=<azure_ad_token>` in the Snowflake connector config. Snowflake receives the JWT, validates the signature against Azure AD's public keys, checks the `oid` claim, maps it to a Snowflake user, and opens the session. The `snowPass` in the config is a fallback password for the service principal, but with OAuth configured it's not used for this pipeline — the OAuth token is the credential. The `snowOAuthClientID`/`snowOAuthClientSecret` are used to register this pipeline as an authorized OAuth client in the Snowflake security integration.

#### The Diff Logic as Set Operations

```python
ad_set    = {member['userPrincipalName'] for member in ad_group_members}
sf_set    = {row['GRANTEE_NAME'] for row in sf_role_grants if row['GRANTED_TO'] == 'USER'}

to_grant  = ad_set - sf_set   # in AD, not in Snowflake → CREATE USER IF NOT EXISTS + GRANT ROLE
to_revoke = sf_set - ad_set   # in Snowflake, not in AD → REVOKE ROLE (after safety guards)

# Apply guards
safe_revoke = {u for u in to_revoke if not UUID_PATTERN.match(u)}
```

`CREATE USER IF NOT EXISTS` is used (not `CREATE USER`) because the user may already exist in Snowflake from a previous partial run or a manually created account. `IF NOT EXISTS` is idempotent — it's safe to run on every sync regardless of prior state. The GRANT is also idempotent in Snowflake: granting a role to a user who already has it produces a no-op, not an error.

#### Why `privatelink` Matters for Compliance

`snowAccount = 'ajg-corpus.privatelink'` resolves to a private endpoint inside the client's Azure VNet — it does not route through the public internet. The Databricks cluster and the Snowflake private endpoint are in the same VNet (or peered VNets). This satisfies two compliance requirements simultaneously: (1) PII data flowing through the OAuth token exchange never traverses the public internet — the connection is entirely within Azure's network fabric; (2) Snowflake can be configured with a network policy that rejects all connections except from the private endpoint IP range, meaning this pipeline's service principal cannot be used from outside the VNet even if the credentials were stolen.

---

### Anticipated Follow-up Questions

**Q: What is MSAL and how does it differ from just calling the Azure AD REST endpoint directly?**
> MSAL (Microsoft Authentication Library) is Microsoft's official SDK for OAuth 2.0 / OpenID Connect flows against Azure AD. It handles token caching (so you don't re-authenticate on every API call), token refresh when a token expires, and the specific client credentials grant format Azure AD expects. You could call the REST endpoint directly — `POST` to `https://login.microsoftonline.com/{tenant}/oauth2/v2.0/token` — and MSAL is ultimately doing the same thing. The reason to use MSAL is reliability: it handles the edge cases like clock skew, token expiry, and retry on transient auth failures. The `AD_AUTH_URL` in the config is exactly that endpoint.

**Q: How does Snowflake OAuth work — why not just use a username and password?**
> Snowflake OAuth with a service principal means the pipeline authenticates as an Azure AD application registration, not as a named Snowflake user with a password. The benefits: (1) the credential is managed in Azure AD and Key Vault — not a Snowflake password that expires; (2) it integrates with Azure's identity governance — the service principal can be audited, its access can be revoked in Azure without touching Snowflake config; (3) it supports the private link auth flow cleanly. Username/password would also work technically, but it's a weaker security model for an automated system.

**Q: What happens if Azure AD is unavailable during a pipeline run?**
> The MSAL call fails and the pipeline should exit immediately without making any Snowflake changes. A half-completed sync — where some roles were updated based on the last known AD state and others weren't — is worse than no sync at all. The correct behavior is: if the AD membership fetch fails, abort. The existing Snowflake state is preserved unchanged. This is a design principle: the sync is all-or-nothing per run, never partial.

**Q: Why is the mapping file on ADLS instead of in the Snowflake CONFIG schema?**
> Both would work. ADLS was chosen because the `AD_Group_Mapping.csv` is managed by the IT team, not the data engineering team. IT has access to ADLS via the Azure portal and can update the CSV without needing Snowflake credentials or going through the data engineering team. Putting it in Snowflake's CONFIG schema would require IT to have a Snowflake login and know how to update a table — unnecessary friction for a non-technical operation.

**Q: What does the Databricks secret scope actually do — how does Key Vault integration work?**
> A Databricks secret scope backed by Azure Key Vault creates a read-only bridge. You point the scope at a Key Vault URL and configure a managed identity or service principal with `Key Vault Secrets User` permissions. When a notebook calls `dbutils.secrets.get(scope="key-vault-secrets", key="CORP-OS2-ClientId")`, Databricks makes an authenticated call to the Key Vault API and returns the secret value. The value is **never** printed in notebook output — Databricks redacts it automatically, replacing it with `[REDACTED]` if it appears in a display. The credentials exist in memory for the duration of the session only.

**Q: How does the pipeline handle a user who exists in Snowflake but was never in AD — e.g., a manually created user?**
> Manually created Snowflake users who aren't in any mapped AD group appear in `SHOW GRANTS TO ROLE <role>` but not in the AD member list. The pipeline would normally flag them for REVOKE. To handle this correctly, there should be an explicit allowlist — a column in the mapping CSV or a separate config — for usernames that are managed outside AD. In the current implementation, the service account UUID guard catches machine accounts. Human accounts manually created in Snowflake would need to be added to an exclusion list to avoid being revoked. This is a known gap that would be the next improvement.

---

### The Config File as Your Interview Prop

When an interviewer asks "walk me through your architecture," you can literally trace the `EnvironmentVariablesConfig.py` file top-to-bottom:

> *"Starting from the config — `aadTenantID`, `aadClientID`, `aadClientSecret` are Key Vault secret names, not values. At runtime we fetch them via `dbutils.secrets.get()` and use MSAL to authenticate to Azure AD. `AD_AUTH_URL` is the OAuth token endpoint for this specific tenant. Once we have the Graph API token, we hit the `/groups/{id}/members` endpoint for each group in `AD_Group_Mapping.csv`. That file lives on ADLS at `auto_provision_mapping_file_path` and maps AD groups to Snowflake roles. Then `snowOAuthClientID` and `snowOAuthClientSecret` — again Key Vault names — are used to authenticate to Snowflake at `snowAccount = 'ajg-corpus.privatelink'` — that's a private link endpoint, so no public internet. We connect as `snowRole = 'USERADMIN_AUTOPROVISION'` — least privilege, provisioning only. Then we diff, generate SQL, run ownership check, run service account guard, and execute."*

That walkthrough takes 60 seconds and shows you understand every line of the config — not just that it exists.

---

### Pitfalls to Avoid

- **Don't say "I connected Databricks to Snowflake."** That's the simplest part. The story is the dual auth (MSAL for Azure AD, OAuth for Snowflake), the safety guards (ownership check + service account guard), and the Key Vault integration. Lead with those.
- **Don't conflate MSAL and Snowflake OAuth.** They are separate, independent auth flows against completely different systems. Be clear: MSAL → Azure AD → Graph API token. Snowflake OAuth → Snowflake auth server → Snowflake session. Two flows, one pipeline.
- **The ownership check is your best answer to "how did you prevent unintended deletions?"** Don't just say "we had safety guards" — say: before touching any Snowflake role, the pipeline queries `SHOW ROLES LIKE '<role>'` and verifies the `owner` column matches the provisioning role. If it doesn't, skip and log. That's a concrete, testable guard.
- **The service account UUID guard is your best answer to "what edge cases did you handle?"** The UUID regex pattern check before any REVOKE is a real operational insight — if you haven't thought about service accounts in an IAM sync, you'll revoke a pipeline credential and create an incident.
- **Private link is worth mentioning to senior interviewers.** `ajg-corpus.privatelink` as the account endpoint shows the client had enterprise-grade network security requirements, and you understood what that means. It's a one-sentence detail that signals seriousness: "the Snowflake traffic went through a private endpoint in the Azure VNet — never the public internet."
- **Don't overclaim on the PySpark angle.** This was a Databricks notebook pipeline — it ran on Databricks infrastructure — but the core logic was Python (MSAL, Snowflake connector, pandas/CSV). The Databricks environment provided secret scopes, ADLS mounts, and scheduling, not necessarily Spark computation. Be accurate about what Spark was doing versus what Python was doing.
