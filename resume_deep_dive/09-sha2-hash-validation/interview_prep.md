## Bullet 9 — SHA2 Hash Validation Framework (Redshift → Snowflake)

> *"Engineered SHA2 hash validation using an Agentic framework (Cursor IDE) between Redshift and Snowflake, reducing false data matches by 90% and increasing cross-platform data integrity."*

> **Project Context:** Gusto — Redshift to Snowflake data migration validation
> **Tech:** Python, SHA-256, Polars, psycopg2, snowflake-connector, Cursor AI (agentic `.cursorrules`)
> **Impact:** 90% reduction in false data mismatches, cryptographic row-level integrity validation across millions of records

---

### The First Thing to Say in Any Interview

At Gusto, we were migrating from Redshift to Snowflake — a production data warehouse used by finance, product, and HR analytics teams. The question wasn't just "did the data move?" but "is the data *identical*?" Traditional row-count checks gave us false confidence. We needed byte-level integrity validation across dozens of tables with millions of records. I engineered a cryptographic hash validation framework from scratch, powered by an agentic AI workflow, that reduced false data matches by 90%.

---

### The Problem (1 minute — make it hard)

The naive approach is to count rows in both systems and call it a match. But that misses everything interesting — a record could exist in both systems but have subtly different values: a decimal rounded differently, a boolean serialized as `True` vs `true`, a NULL versus an empty string. These differences are invisible to count checks but catastrophic for downstream analytics.

We also had a structural problem: both databases have **audit columns** — ETL pipeline metadata like `etl_insert_ts`, `dbt_updated_at`, `dbt_valid_from`. If you naively hash every column, these timestamps are always different between Redshift and Snowflake because they reflect *when* the record was processed, not *what* the business data is. That was causing **90% of our "mismatches" to be false positives** — not real data differences, just pipeline noise.

---

### The Architecture (2 minutes — go deep)

The core algorithm: for each table, generate a **SHA-256 hash of every business data column concatenated with a pipe delimiter**, sorted alphabetically for determinism. Exclude audit/ETL columns — `etl_insert_ts`, `etl_update_ts`, `dbt_valid_from`, `dbt_scd_id` — and hash only business data.

**Cross-platform type serialization differences handled:**

- **Booleans:** `IS TRUE` syntax in Redshift vs `= TRUE` in Snowflake
- **Timestamps:** normalized to `YYYY-MM-DD HH24:MI:SS` via `TO_CHAR`
- **Decimals:** rounded to 6 places with format mask `FM999999999999999990.000000`
- **NULLs:** coalesced to empty string `''` consistently across both platforms

**Example generated Redshift query:**
```sql
SELECT
    company_id,
    SHA2(
        COALESCE(CAST(account_name AS VARCHAR),'') || '|' ||
        COALESCE(TO_CHAR(created_date, 'YYYY-MM-DD HH24:MI:SS'),'') || '|' ||
        COALESCE(CASE WHEN is_active IS TRUE THEN 'true'
                      WHEN is_active IS FALSE THEN 'false'
                      WHEN is_active IS NULL THEN 'null'
                      ELSE 'unknown' END,''),
        256
    ) AS row_hash
FROM (
    SELECT *,
           ROW_NUMBER() OVER (PARTITION BY company_id ORDER BY created_date ASC, company_id ASC) AS dedup_row_num
    FROM bi.companies
    WHERE created_date >= '2025-01-01' AND created_date <= '2025-12-31'
) ranked
WHERE dedup_row_num = 1
LIMIT 10000
```

---

### The Deduplication Problem

Some tables had multiple rows with the same business key — SCD tables, event logs. I solved this with **deterministic deduplication**: the `ORDER BY` in the `ROW_NUMBER` window follows a fixed priority:

1. **Business ordering columns** from config (e.g., `effect_start_dt ASC, sfdc_opportunity_id DESC`)
2. **ETL audit timestamps** (`etl_insert_ts DESC` — pick the latest pipeline insertion)
3. **Primary key as final tie-breaker** (ASC — fully deterministic)

Both platforms execute the exact same logic, so they always select the same "winner" record.

---

### The Comparison Engine

CSVs from both systems (ID + hash per row) are loaded into **Polars DataFrames** and joined via **full outer join on ID columns** (not the hash). Four result categories:

| Category | Meaning |
|---|---|
| **MATCHED** | Same ID, same hash — data is identical |
| **HASH_MISMATCH** | Same ID in both, hashes differ — legitimate business data difference |
| **REDSHIFT_ONLY** | Record missing from Snowflake — sync failure |
| **SNOWFLAKE_ONLY** | Record in Snowflake but not Redshift — pipeline routing issue |

For HASH_MISMATCH records, the framework auto-generates a **debug SQL query** showing the raw concatenation string side-by-side from both systems — so you can see exactly which field differs.

---

### The Agentic AI Component

I embedded a `.cursorrules` file — an **AI agent configuration for Cursor IDE** — that codifies the entire validation workflow as a decision-making agent. The agent understands the domain context:

- Audit columns must always be excluded
- Table count comparison is **mandatory before hash validation**
- A count mismatch > 1% means stop and investigate the pipeline
- A count of zero in Snowflake means remove the table from config entirely

```text
[Step 0] Table Count Comparison → evaluate decision matrix
    ↓ MATCH/CLOSE MATCH (≤1%)
[Step 1] SHA2 Hash Generation (validate_sha2.py)
    ↓
[Step 2] Hash Comparison (hash_mismatch_comparision.py)
    ↓
[Step 3] Root Cause Analysis (data_sync_investigation.py)
```

The agent encodes domain expertise into an executable decision tree — reproducible without manual orchestration across dozens of tables.

---

### Results

- **False positives dropped by 90%** — real data discrepancies now clearly separated from pipeline metadata drift
- Validated full Gusto `bi` and `bi_reporting` table inventories — **millions of records with cryptographic precision**
- Auto-generated root cause SQL cut **investigation time from hours to minutes**

---

### Key Technical Terms

- **SHA-256 cryptographic fingerprinting** at the row level
- **Deterministic deduplication** via `ROW_NUMBER() OVER PARTITION BY`
- **Cross-platform type normalization** — boolean, timestamp, decimal serialization
- **Full outer join** on business keys for mismatch classification
- **Audit column exclusion** to eliminate ETL metadata noise
- **Agentic workflow** encoded in `.cursorrules` as a domain-expert decision-making agent
- **Polars DataFrames** for in-memory hash comparison
- **Platform-specific SQL generation** (psycopg2 for Redshift, snowflake-connector for Snowflake)
- **Composite key support** for SCD and multi-dimensional tables

---

### One-Liner Summary

> "I built a cryptographic row-level hash validation system between Redshift and Snowflake, with an agentic AI workflow that orchestrates the validation pipeline end-to-end — reducing false data matches by 90% by eliminating ETL metadata noise through intelligent column filtering and deterministic deduplication."

---

### Anticipated Follow-up Questions

**Q: Why SHA-256 and not MD5 or a simple checksum?**
> SHA-256 is collision-resistant at enterprise scale — with millions of rows, MD5 has a non-trivial collision probability. SHA-256 gives cryptographic confidence that two identical hashes mean identical data.

**Q: How did you handle tables with no natural primary key?**
> The framework prompts interactively for composite key selection when no ID column is configured in `tables.yaml`. Supports multi-column composite keys as a comma-separated string (e.g., `company_id,month`).

**Q: What if the count mismatch is legitimate — e.g., Snowflake has more recent data?**
> The decision matrix allows a "CLOSE MATCH" threshold of ≤1% — proceed and document the delta. The date range filter isolates a stable window where both systems should be fully synced.

**Q: How does the agentic AI actually help versus just documentation?**
> The `.cursorrules` agent is invoked inside Cursor IDE, interprets script outputs, and decides the next step. It encodes branching logic: MISMATCH → stop; ERROR (table not found) → run schema discovery. It's an executable decision tree, not passive docs.

---

---
