## Bullet 6 — Python Utility: Redshift to Snowflake Self-Service Migration

> *"Designed and implemented a Python utility to automate the loading of source tables from Redshift to Snowflake, reducing dependency on platform teams and enabling swift, self-service data movement for analytics engineering."*
>
> **Files:** `_dbt_helper/clone_redshift_to_snowflake.py`, `util/redshift.py`, `util/snowflake.py`

---

### The Problem First — Why This Tool Had to Exist

Before this utility existed, moving a table from Redshift to Snowflake required opening a ticket with the platform team and waiting. Platform teams have queues. In a migration project where analytics engineers are constantly pulling source data across to validate models, "open a ticket and wait" is a blocker. Every time you needed a new source table in Snowflake to develop or validate a model, you stopped. The team was dependent on an external team for what was, fundamentally, a data movement task that should have been self-service.

---

### The Story Arc (STAR format)

**Situation:**
The HRMS project was a Redshift-to-Snowflake migration. Analytics engineers needed Redshift source tables available in Snowflake to develop dbt models and validate migration output. The existing process to move a table was a manual handoff to the platform team.

**Problem:**
The wait time on platform team tickets was breaking the development flow. Engineers would identify a table they needed, raise a request, and sit idle. Beyond the wait time, there was a secondary problem: even when a table was moved manually, there was no type mapping guarantee — Redshift types like `SUPER`, `UUID`, and `SERIAL` have no direct Snowflake equivalents, and a manual load could silently produce wrong column types in Snowflake.

**Action:**
I built a CLI tool in Python that automates the entire pipeline — Redshift schema introspection → S3 export → Snowflake type mapping → Snowflake table creation → data load → row count validation — in a single command. It's dbt-aware: instead of needing to know the physical schema and table name, an engineer runs it by dbt model name and the tool figures out the rest from the production manifest.

**Result:**
Analytics engineers can move any Redshift source table to Snowflake themselves in one command, no ticket required. The dependency on the platform team for this class of task was eliminated.

---

### The 4-Step Pipeline — What Actually Happens End to End

Say an engineer runs this command:

```bash
python _dbt_helper/clone_redshift_to_snowflake.py migrate-model-to-sf \
  --model cases \
  --s3-bucket my-migration-bucket
```

Here is what the tool executes:

**Step 1 — Schema Introspection (Redshift)**
`RedshiftClient.get_table_definition()` queries `information_schema.columns` and `information_schema.tables` on Redshift to get the full column list, data types, ordinal positions, and whether the object is a TABLE or VIEW. If it's a VIEW, the tool stops immediately with an error — you can't UNLOAD a view, only a table. This is caught early, before any S3 data movement happens.

**Step 2 — UNLOAD to S3 (Redshift → S3)**
`unload_redshift_table()` executes Redshift's `UNLOAD` command:

```sql
UNLOAD ('SELECT * FROM schema.table')
TO 's3://bucket/prefix/schema/table/20240415T143000/'
IAM_ROLE 'arn:aws:iam::226779328744:role/airflow'
FORMAT PARQUET
ALLOWOVERWRITE;
```

Key design decisions:
- **Parquet format** — not CSV. Parquet preserves column types natively during the S3 hop. CSV would lose type information and require re-inference on the Snowflake side.
- **Timestamped S3 path** — each run writes to a unique path (`YYYYMMDDTHHMMSS`), so multiple runs don't overwrite each other's data in flight.
- **IAM role auth** — Redshift uses the Airflow IAM role for S3 write permissions. No static credentials.
- **Optional date filter** — the tool accepts `--date-column`, `--start-date`, `--end-date` to add a WHERE clause to the UNLOAD query. For large tables, you can migrate a date range instead of the full table.

**Step 3 — Type Mapping + Snowflake Table Creation**
`SnowflakeClient.create_table_ddl()` generates the `CREATE TABLE` DDL for Snowflake, running every column through `_map_redshift_to_snowflake_type()`. This is where the important translation happens:

| Redshift Type | Snowflake Type | Why non-obvious |
|---------------|----------------|-----------------|
| `SUPER` / `JSON` / `JSONB` | `VARIANT` | Snowflake's semi-structured type |
| `TIMESTAMP WITHOUT TIME ZONE` | `TIMESTAMP_NTZ` | Snowflake has 3 timestamp types — NTZ is the correct default |
| `TIMESTAMP WITH TIME ZONE` | `TIMESTAMP_TZ` | Separate type in Snowflake |
| `UUID` | `VARCHAR(36)` | Snowflake has no UUID type — 36 chars matches UUID string length exactly |
| `SERIAL` | `INTEGER` | Redshift's auto-increment type; Snowflake uses sequences separately |
| `BIGSERIAL` | `BIGINT` | Same — serial semantics don't exist in Snowflake |

Two additional safety guards in `_apply_safe_string_length()`:
- Any `VARCHAR` with length < 50 is bumped to `VARCHAR(50)`
- Any `VARCHAR` with length 50–254 is bumped to `VARCHAR(255)`

This matters because Redshift schemas often have tight VARCHAR definitions like `VARCHAR(10)` for a status code column. If source data ever had a longer value written historically, a strict length copy would cause COPY INTO failures on Snowflake. The safe minimum prevents silent truncation bugs.

Before creating the table, the tool also checks whether a VIEW with the same name already exists in the target Snowflake schema and drops it first — because `CREATE OR REPLACE TABLE` in Snowflake doesn't automatically remove a VIEW with the same identifier.

**Step 4 — COPY INTO Snowflake (S3 → Snowflake)**
`create_table_from_s3()` creates a Snowflake external stage pointing at the S3 path, loads the data, then drops the stage:

```sql
-- Create a temporary stage
CREATE OR REPLACE STAGE db.schema.MIGRATION_STAGE_schema_table
    URL = 's3://bucket/prefix/...'
    STORAGE_INTEGRATION = EXT_S3_INTEGRATION
    FILE_FORMAT = EXTERNAL_LAKE.BASE.EXT_PARQUET_FF;

-- Load the data
COPY INTO db.schema.table
FROM @db.schema.MIGRATION_STAGE_schema_table
FILE_FORMAT = (FORMAT_NAME = 'EXTERNAL_LAKE.BASE.EXT_PARQUET_FF')
MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE
ON_ERROR = 'ABORT_STATEMENT';

-- Clean up
DROP STAGE IF EXISTS db.schema.MIGRATION_STAGE_schema_table;
```

`MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE` is critical — it matches Parquet column names to Snowflake table column names by name, not by position. This means column order differences between the Parquet export and the CREATE TABLE don't cause a data misalignment. `ON_ERROR = 'ABORT_STATEMENT'` ensures the entire load rolls back if any row fails — no partial loads.

**Post-load — Row Count Validation**
`validate_migration()` compares `SELECT COUNT(*)` from Redshift against `SELECT COUNT(*)` from Snowflake. If the counts don't match (and a row limit wasn't applied), it logs a warning with the exact source and target counts.

---

### The dbt-Aware Intelligence — What Makes This More Than a Data Move Script

Most data movement scripts work at the `schema.table` level — you pass in a schema name and a table name and the script moves that table. This tool works at the **dbt model level**. You pass a model name, and the tool figures out everything else.

#### What the dbt Manifest Actually Is

`dbt.load_manifest(target="prod")` calls `dbtRunner().invoke(["parse", "-t", "prod"])` — this invokes the dbt CLI **programmatically** (not as a subprocess) using dbt's Python SDK. `dbtRunner` parses the entire dbt project — reads all `.sql` model files, all `sources.yml` definitions, all `schema.yml` configs — and compiles them into a `Manifest` object in memory. The manifest is a structured representation of every node in the dbt DAG: models, sources, snapshots, tests, analyses.

The `Manifest` object has two key dictionaries: `manifest.nodes` (models, snapshots, tests) and `manifest.sources` (raw source table definitions from `sources.yml`). Every entry has a fully qualified key in the format `{node_type}.{project_name}.{node_name}`.

#### Looking Up a Model's Physical Location

```python
node = manifest.nodes.get(f"model.gusto_warehouse.{model_name}")
source_schema = node.schema   # the actual Redshift schema, e.g. "bi"
source_table  = node.alias    # the actual Redshift table name, e.g. "cases_raw"
```

`node.schema` and `node.alias` are the **compiled, production-resolved values** — they reflect any custom schema macros or `alias:` configs defined in the dbt project. A model named `cases` might be materialized as table `cases_raw` in schema `bi` because the project has a naming convention macro. Without the manifest, an engineer would have to know this physical name manually. The manifest lookup removes that dependency entirely.

`node.config.materialized` tells you the materialization type: `table`, `view`, `incremental`, or `ephemeral`. This is what drives the branching logic below.

#### The View Auto-Resolution — Walking the Dependency Graph

If `node.config.materialized == "view"`, Redshift's `UNLOAD` command cannot export it directly — `UNLOAD` only works on physical tables. Instead of failing, the tool walks the dependency graph:

```python
for dep in node.depends_on.nodes:          # e.g. ["source.gusto_warehouse.bi.cases_raw"]
    if dep.startswith("source."):
        parts = dep.split(".")             # ["source", "gusto_warehouse", "bi", "cases_raw"]
        source_name  = parts[2]            # "bi"
        table_name   = parts[3]            # "cases_raw"

        source_key  = f"source.gusto_warehouse.{source_name}.{table_name}"
        source_node = manifest.sources.get(source_key)

        actual_schema     = source_node.schema
        actual_identifier = source_node.identifier or table_name  # handles identifier: overrides
```

`node.depends_on.nodes` is the list of upstream dependencies for this model — other models and raw sources it references. The tool filters for `source.*` entries only (raw Redshift tables, not intermediate models). For each source dependency, it looks up the source node in `manifest.sources` and gets the **actual physical table identifier** — because a source defined as `cases_raw` in `sources.yml` might have `identifier: raw_cases_v2` pointing at a differently named table in Redshift. `source_node.identifier` resolves that.

The end result: you ask for model `cases` (a view), the tool discovers it depends on source `bi.cases_raw`, and migrates `bi.cases_raw` from Redshift to Snowflake automatically. The engineer never knew the model was a view or that the underlying source had a different physical name.

#### Snapshot Support — A Different Node Namespace

The `--snapshot` flag handles dbt snapshots, which are stored in `manifest.nodes` under a different key namespace: `snapshot.gusto_warehouse.{snapshot_name}` instead of `model.gusto_warehouse.{model_name}`. Snapshots also have their own schema and alias conventions — by default, dbt materializes snapshots in a dedicated `snapshots` schema. `source_node.schema` and `source_node.alias` resolve those correctly from the manifest, the same way they do for models.

#### Why This Matters in Practice

Without manifest awareness, the workflow is:
1. Engineer wants to migrate model `cases`
2. Engineer opens dbt, finds the model file, traces back which schema it uses, checks for alias overrides, checks if it's a view
3. If it's a view, repeats the process for each upstream source
4. Runs the migration script with the physical schema and table name

With manifest awareness:
1. Engineer runs `python clone_redshift_to_snowflake.py migrate-model-to-sf --model cases --s3-bucket my-bucket`
2. Done

The manifest is the single source of truth for the physical layout of the dbt project. Using it programmatically means the tool is always correct — it reads the same metadata that dbt itself uses.

---

### How to Open (say this first)

> *"During the Redshift-to-Snowflake migration, analytics engineers were blocked every time they needed a source table in Snowflake for model development — it required a platform team ticket and a wait. I built a CLI tool in Python that automates the full pipeline: it introspects the Redshift schema, UNLOADs the data to S3 as Parquet, maps Redshift types to Snowflake equivalents — including non-obvious ones like SUPER to VARIANT and UUID to VARCHAR — creates the Snowflake table, does a COPY INTO using a storage integration, and validates the row count. The tool is also dbt-aware: you give it a model name, and it looks up the physical schema and table from the dbt production manifest, so engineers don't need to know the underlying physical location."*

---

### Key Technical Points to Cover

| # | Point | What to say |
|---|-------|-------------|
| 1 | **Why Parquet and not CSV** | "Parquet preserves column type metadata during the S3 hop. If you UNLOAD to CSV, every column becomes a string and you lose all type information — you'd have to re-infer or re-cast every column on the Snowflake side. Parquet carries the schema with it, so the COPY INTO in Snowflake can load columns with the correct types." |
| 2 | **Type mapping — the non-obvious cases** | "Straightforward types like INTEGER and VARCHAR map directly. The interesting ones: Redshift's SUPER (semi-structured JSON) maps to Snowflake's VARIANT. UUID maps to VARCHAR(36) because Snowflake has no UUID type. SERIAL and BIGSERIAL are Redshift auto-increment types — those become INTEGER and BIGINT because Snowflake handles sequences differently." |
| 3 | **Safe VARCHAR minimum** | "Redshift schemas often define tight VARCHAR lengths like VARCHAR(10) for a status code. If historical data ever had a longer value that Redshift truncated silently, the COPY INTO on Snowflake would fail because the Snowflake column would be too narrow. I built a safe minimum: any VARCHAR under 50 gets bumped to 50, anything under 255 gets bumped to 255. It prevents silent truncation failures without blowing up storage." |
| 4 | **MATCH_BY_COLUMN_NAME** | "The COPY INTO uses `MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE`. This matches Parquet column names to Snowflake column names by name, not position. If the column order in the Parquet file differs from the CREATE TABLE order — which can happen if Redshift's information_schema returns columns in a different order — positional matching would silently put the wrong data in the wrong column. Name matching prevents that." |
| 5 | **dbt manifest integration** | "The tool loads the production dbt manifest JSON and looks up the model by name to find its physical schema and alias. This means engineers use the dbt name they already know, not the physical database object name. For view models, the tool traces upstream to the source tables from the manifest's dependency graph and migrates those instead — automatically, without the engineer needing to know the underlying tables." |
| 6 | **The 4-step result tracking** | "Each migration result object tracks success/failure for each step independently: table_analysis, unload, create_table, load_data. If unload fails, the tool returns immediately without trying to create a table in Snowflake. This makes failure diagnosis fast — you know exactly which step failed and why from the result object and logs." |
| 7 | **Ephemeral stage lifecycle** | "The Snowflake external stage is created, used for the COPY INTO, and then immediately dropped. It doesn't persist after the migration run. This keeps the Snowflake environment clean — no accumulation of stale stages from old migration runs." |

---

### Anticipated Follow-up Questions

**Q: Why use S3 as the intermediate — why not direct Redshift-to-Snowflake transfer?**
> There's no direct Redshift-to-Snowflake wire protocol. Both systems have efficient S3 integration — Redshift's UNLOAD and Snowflake's COPY INTO are both designed to work through S3 at high throughput. S3 as the staging layer is the standard pattern for this use case. It also gives you an auditable intermediate state — if the Snowflake load fails, the data is still in S3 and you can retry the load without re-running the UNLOAD from Redshift.

**Q: What is a Snowflake storage integration, and why use it instead of passing credentials directly?**
> A storage integration is a Snowflake account-level object that holds the trust relationship between Snowflake and an S3 bucket via IAM. Instead of embedding AWS access keys in the COPY INTO command, the storage integration uses an IAM role that grants Snowflake access to the bucket. It's more secure — no static credentials in SQL, and access can be revoked at the IAM level without changing any Snowflake code.

**Q: What happens if the Snowflake table already exists at the target location?**
> `CREATE OR REPLACE TABLE` handles that — it drops and recreates the table. The migration tool is designed for loading source tables that are either new to Snowflake or need to be refreshed. If the target already has a VIEW with the same name (a common case in the migration project where views existed before the underlying tables were moved), the tool explicitly detects the view with `view_exists()` and drops it before creating the table, because `CREATE OR REPLACE TABLE` doesn't remove a VIEW with the same identifier.

**Q: How does the row count validation work if a date filter was applied?**
> The same date filter applied to the UNLOAD is also applied to the Redshift COUNT query in `validate_migration()`. So the validation compares the count of rows in the filtered date range on Redshift against the full Snowflake table count. If you loaded rows for a specific date range, validation checks that date range specifically. If no filter was applied, it compares full table counts.

**Q: What prevents someone from accidentally loading to production Snowflake?**
> Two guards. First, the tool warns if the `--target-database` doesn't start with `DEV_` — it logs a visible warning: "Loading data to non-development database. Ensure this is intended for production use." Second, the tool authenticates to Snowflake using the engineer's own credentials via external browser auth or private key — if the engineer's Snowflake role doesn't have write access to the production database, the CREATE TABLE will fail at the permissions level.

**Q: Why does the tool need to handle the VIEW case separately for dbt models?**
> dbt views are SQL SELECT statements stored in Snowflake — they have no physical data. You can't UNLOAD a view from Redshift because there's nothing to export. The dbt manifest tells the tool whether a model is a view or an incremental table. If it's a view, the tool reads the model's `depends_on` list from the manifest — those are the upstream source models or raw tables that the view selects from. The tool migrates those source tables instead, which is what the analyst actually needed — the data that the view reads.

---

### Code-Level Deep Dive — Specifics to Quote in Interviews

This section gives you the exact implementation details to answer "can you walk me through the code?" questions confidently.

---

#### Detail 1 — Schema Introspection: `svv_columns`, not `information_schema`

The Redshift query in `util/queries.py` hits `svv_columns`, not `information_schema.columns`. This is significant:

```sql
SELECT
    ordinal_position,
    column_name,
    CASE data_type
        WHEN 'character varying' THEN 'varchar'
        WHEN 'timestamp without time zone' THEN 'timestamp'
        WHEN 'double precision' THEN 'float'
        ELSE data_type
    END AS ddl_type,
    CASE ddl_type
        WHEN 'varchar' THEN CAST(character_maximum_length AS varchar)
        WHEN 'numeric' THEN CAST(numeric_precision || ',' || numeric_scale AS varchar)
    END AS ddl_options,
    remarks AS description
FROM svv_columns
```

`svv_columns` is a Redshift-specific system view that includes columns from external schemas (Spectrum, data sharing) that `information_schema.columns` doesn't always expose. It also returns `remarks` — the column description if one was set. The CASE block normalizes verbose Redshift type names (`character varying`, `timestamp without time zone`, `double precision`) to their short forms before the type mapper processes them.

**What to say:** *"The schema introspection queries `svv_columns` rather than `information_schema.columns` — it's a Redshift-specific view that includes external and shared schema columns, and it also carries column descriptions through the `remarks` column. The query also normalizes Redshift's verbose type names before they hit the type mapper — `character varying` becomes `varchar`, `timestamp without time zone` becomes `timestamp` — so the mapper has consistent input to work with."*

---

#### Detail 2 — Single-Quote Escaping in UNLOAD

The UNLOAD command takes the query as a string literal wrapped in single quotes:

```python
unload_query = f"""
    UNLOAD ('{base_query.replace("'", "''")}')
    TO '{s3_path}'
    ...
"""
```

The `.replace("'", "''")` is SQL string escaping — any single quote inside `base_query` (which could appear in a WHERE clause like `WHERE status = 'ACTIVE'`) must be doubled inside the UNLOAD string literal. Without this, the SQL parser would see the inner quote as the end of the UNLOAD string and throw a syntax error.

**What to say:** *"The base query gets single-quote escaped before it goes into the UNLOAD string. UNLOAD takes the query as a string literal in single quotes — any single quote inside the query, like a WHERE clause filter value, has to be doubled so the SQL parser doesn't treat it as the closing quote of the string. This is standard SQL string escaping, but it's easy to miss."*

---

#### Detail 3 — LIMIT Wrapping in UNLOAD

Redshift's UNLOAD syntax doesn't support LIMIT directly in the top-level SELECT. To support the `--limit` flag, the query is wrapped in a subquery:

```python
if self.limit is not None:
    base_query = f"SELECT * FROM ({base_query} LIMIT {self.limit})"
```

Without the subquery wrapper, Redshift throws a syntax error. This is a Redshift-specific constraint — its UNLOAD parser doesn't accept LIMIT at the outer query level.

**What to say:** *"Redshift's UNLOAD doesn't allow LIMIT in the outer SELECT — it's a parser constraint. To support row limiting for testing migrations on a subset before running the full load, I wrap the base query in a subquery: `SELECT * FROM (SELECT * FROM schema.table LIMIT N)`. That gives UNLOAD a valid SELECT without a LIMIT at the top level."*

---

#### Detail 4 — Type Mapping: `startswith` Matching, Not Exact Match

The type mapper in `util/snowflake.py` uses `startswith`, not equality:

```python
for redshift_key, snowflake_type in type_mapping.items():
    if redshift_type.lower().startswith(redshift_key):
        ...
```

This handles parametrized types automatically. `VARCHAR(255)` starts with `varchar` so it matches the `varchar` key. `NUMERIC(18,2)` starts with `numeric` so it matches. After matching, the code checks if `(` is in the original type string to preserve the length or precision parameters:

```python
elif '(' in redshift_type:
    params = redshift_type[redshift_type.find('('):]  # extracts "(255)" or "(18,2)"
    return snowflake_type + params
```

The exception is VARIANT — for `SUPER`, `JSON`, `JSONB`, the params are dropped entirely because Snowflake's VARIANT has no length parameter. `JSON(255)` on Redshift becomes just `VARIANT` on Snowflake.

**What to say:** *"The type mapper uses `startswith` rather than exact matching. This is important for parametrized types — `VARCHAR(255)` needs to match the `varchar` key, `NUMERIC(18,2)` needs to match `numeric`. After matching, the code extracts whatever is inside the parentheses and appends it to the Snowflake type. The only exception is VARIANT — `SUPER`, `JSON`, `JSONB` all map to plain `VARIANT` and the length parameter is dropped, because VARIANT in Snowflake is a schema-less type that doesn't take a size parameter."*

---

#### Detail 5 — Safe VARCHAR Minimum: The Two Thresholds

```python
def _apply_safe_string_length(self, snowflake_type, params, column_name=None):
    length = int(length_str)
    if length < 50:
        return f"{snowflake_type}(50)"      # e.g. VARCHAR(10) → VARCHAR(50)
    elif length < 255:
        return f"{snowflake_type}(255)"     # e.g. VARCHAR(100) → VARCHAR(255)
    else:
        return snowflake_type + params      # VARCHAR(500) → VARCHAR(500), no change
```

Two thresholds, not one. The reasoning:
- **Under 50:** Very tight definitions like `VARCHAR(1)` (used for Y/N flags), `VARCHAR(8)` (date codes), `VARCHAR(10)` (status codes). These are at high risk of containing wider values in practice that Redshift silently truncated on write. Bumped to 50.
- **50–254:** Moderately tight definitions. Safe minimum is 255 because that's the conventional "short string" size and avoids truncation on anything under a typical description field. Bumped to 255.
- **255+:** Already wide enough — left unchanged.

**What to say:** *"There are two thresholds in the safe length function. Anything under 50 gets bumped to 50 — these are the tight definitions like `VARCHAR(1)` for boolean flags or `VARCHAR(8)` for date codes, where historical data could easily be wider than the schema says. Anything between 50 and 254 gets bumped to 255 — the conventional safe minimum for a short string field. Anything 255 or wider is left alone. This prevents `COPY INTO` from failing on narrow columns without over-allocating storage."*

---

#### Detail 6 — Column Name Quoting for Numeric-Starting Names

```python
col_name_fix = col_name if re.match("^[0-9]", col_name) is None else f'"{col_name.upper()}"'
```

Snowflake requires column names that begin with a digit to be double-quoted in DDL. Unquoted, they cause a syntax error. The fix checks with a regex (`^[0-9]` — starts with any digit), and if matched, wraps the name in double quotes and uppercases it (Snowflake stores unquoted identifiers in uppercase, so quoted ones should match that convention).

**What to say:** *"Snowflake doesn't allow column names that start with a digit unless they're double-quoted. Redshift allows them. The DDL generator checks every column name with a regex — if it starts with a number, it wraps the name in double quotes and uppercases it for Snowflake. Without this, the `CREATE TABLE` would fail with a syntax error on any column like `1st_purchase_date` or `2024_revenue`."*

---

#### Detail 7 — The Snowflake Stage: Deterministic Name, Not UUID

```python
stage_name = f"MIGRATION_STAGE_{schema}_{table}".upper()
```

The stage name is deterministic — based on schema and table name, not a UUID. This means:
- If the same table is migrated twice concurrently, the second run's `CREATE OR REPLACE STAGE` overwrites the first run's stage, potentially corrupting the first run's COPY INTO.
- However, in practice this was a developer tool, not a concurrent batch system — single-user use where this race condition was acceptable.

The stage is always dropped after use: `DROP STAGE IF EXISTS`. No accumulation of stale stages.

**What to say:** *"The external stage is named deterministically — `MIGRATION_STAGE_{schema}_{table}` — not with a UUID. That means two concurrent migrations of the same table would conflict on the stage name. For a developer self-service tool used one table at a time, this was an acceptable tradeoff — it keeps the stage lifecycle simple. The stage is always dropped after the COPY INTO completes, so there's no accumulation of stale stages in the environment."*

---

#### Detail 8 — dbt Manifest Loading: Live Parse, Not Static JSON

```python
def load_manifest(target: str = "dev") -> Manifest:
    res = dbtRunner().invoke(["parse", "-t", target], quiet=True)
    return res.result
```

This is not reading `target/manifest.json` from disk. It's invoking the dbt Python SDK's `dbtRunner` to run `dbt parse` programmatically, which parses the entire dbt project in memory and returns a live `Manifest` object. This means:
- The manifest always reflects the current state of the project files, not a potentially stale artifact.
- It requires a valid dbt environment (profiles, env vars, package dependencies) to be configured.
- The `Manifest` object returned is a fully typed Python dataclass — you access `node.schema`, `node.alias`, `node.config.materialized`, `node.depends_on.nodes` directly as attributes, not by parsing JSON strings.

**What to say:** *"The manifest loading doesn't read `manifest.json` from disk. It uses dbt's Python SDK — `dbtRunner().invoke(['parse', '-t', 'prod'])` — which runs `dbt parse` in-process and returns a live typed `Manifest` object. This means you always get the current state of the project, not a stale artifact. And because it's a typed Python object, you access model properties like `node.schema`, `node.alias`, `node.config.materialized` directly as attributes — no JSON parsing."*

---

#### Detail 9 — Model Node Key Format in the Manifest

```python
node = manifest.nodes.get(f"model.gusto_warehouse.{model_name}")
```

The manifest node key format is `{resource_type}.{project_name}.{model_name}`. The project name `gusto_warehouse` is the dbt project name defined in `dbt_project.yml`. For snapshots it's `snapshot.gusto_warehouse.{name}`. For sources it's `source.gusto_warehouse.{source_name}.{table_name}` — four parts, not three.

**What to say:** *"The manifest stores nodes with a compound key: `{resource_type}.{project_name}.{model_name}`. For models it's `model.gusto_warehouse.cases`. For snapshots, `snapshot.gusto_warehouse.snap_cases`. For sources, it's four parts — `source.gusto_warehouse.{source_name}.{table_name}`. The tool constructs these keys explicitly. If you get the format wrong, `manifest.nodes.get()` returns None and the tool raises a clear error: 'Model X not found in dbt manifest.'"*

---

#### Detail 10 — View Dependency Resolution: Tracing the Source DAG

```python
for dep in model_info["depends_on"]:
    if dep.startswith("source."):
        parts = dep.split(".")          # ["source", "gusto_warehouse", "raw_bi", "cases"]
        source_name = parts[2]          # "raw_bi"
        table_name  = parts[3]          # "cases"
        source_key = f"source.gusto_warehouse.{source_name}.{table_name}"
        source_node = manifest.sources.get(source_key)
        source_schema = source_node.schema
        source_identifier = source_node.identifier or table_name
```

When a dbt model is a VIEW, its `depends_on.nodes` list contains the upstream dependencies. The code filters for entries starting with `source.` (as opposed to `model.` — upstream model dependencies). For each source dependency, it looks up the source node in `manifest.sources` to get the **physical** schema and identifier (which may differ from the source name in `sources.yml` due to `identifier:` overrides).

**What to say:** *"For view models, I read `node.depends_on.nodes` from the manifest — the list of upstream dependencies. I filter for entries starting with `source.` to get the raw source tables. Each source entry is a four-part key: resource type, project, source name, table name. I look that up in `manifest.sources` to get the physical schema and table identifier — because dbt's `sources.yml` can have an `identifier:` override where the logical name in dbt doesn't match the physical table name in the database. The tool uses the physical identifier for the UNLOAD, not the logical name."*

---

### Pitfalls to Avoid

- **Don't describe this as "a script that copies tables."** That's the mechanism, not the story. The story is self-service data movement: analytics engineers were blocked on platform team tickets for something they should be able to do themselves. The tool removed that dependency.
- **Lead with the type mapping when interviewers ask about complexity.** SUPER → VARIANT, UUID → VARCHAR(36), SERIAL → INTEGER — these aren't obvious. They show you understood that a migration tool can't just move bytes; it has to understand what the data means on each platform.
- **The safe VARCHAR minimum is a great answer to "what edge cases did you handle?"** It's concrete, it has a real failure mode (COPY INTO fails on a too-narrow column), and the two-threshold logic shows systematic thinking.
- **The dbt manifest integration separates this from a generic migration script.** Every migration project has a data copy script. A script that invokes `dbt parse` programmatically and resolves model names through the live manifest — and handles views by tracing upstream through the DAG — is purpose-built for the project. Lead with that when asked "what makes this different from AWS DMS or Fivetran?"
- **`MATCH_BY_COLUMN_NAME` is your answer if asked "how did you prevent column misalignment?"** Don't say "I made sure the columns were in the right order." Say "I used name-based matching in COPY INTO so column order doesn't matter."
- **The single-quote escaping in UNLOAD is a good "gotcha" story.** If the interviewer asks about a bug you found during development, the UNLOAD string escaping is concrete — the query fails with a cryptic parser error if you don't double the quotes, and the fix is a single `.replace("'", "''")`.

---

---
