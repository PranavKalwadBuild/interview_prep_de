## Bullet 1 — TDD / Data Quality Framework (600 Models)

> *"Orchestrated and implemented a comprehensive TDD paradigm for data quality assurance in the data mesh deploying automated checks (count, metadata, data mismatch) across 600 models, ensuring high data integrity and governance."*
>
> **Files:** `macros/count.sql`, `macros/metadata_mismatch.sql`, `macros/data_mismatch_details.sql`

---

### The First Thing to Say in Any Interview

This was **not** dbt's generic tests (`unique`, `not_null`, `accepted_values`). It was **not** Great Expectations. This was a **custom three-tier validation framework** built specifically for a migration scenario — comparing the old SAP BODS architecture against the new Fivetran + dbt + Snowflake architecture. The entire point was to prove that the new architecture produced identical results to what existed before. That framing needs to come out in the first 30 seconds.

---

### The Story Arc (STAR format)

**Situation:**
This was a Data Mesh migration — replacing an old BODS (Business Objects Data Services) ETL pipeline with a new Fivetran + dbt + Snowflake architecture. The business couldn't simply trust that the new architecture was correct just because the code looked right. They needed proof — a systematic, repeatable way to validate that 600+ models in the new architecture produced the same data as the old system.

**Problem:**
Standard dbt tests (`unique`, `not_null`) test internal consistency — they don't tell you whether your new architecture matches the old one. What was needed was a cross-architecture validation: compare row counts, compare column-level schema metadata, compare actual row-level values between BODS output and the new dbt models. No out-of-the-box tool does exactly this for a SAP-to-Snowflake migration context.

**Action — the three-tier framework:**

---

### Tier 1 — Count Test

**What it does:**
A dbt Jinja macro `count(view_name, table_name)` where `view_name` is the new Fivetran/dbt model and `table_name` is the old BODS table. At execution time it fires three `run_query()` calls: one that computes the raw difference as a single SQL expression (`(SELECT COUNT(*) FROM view_name) - (SELECT COUNT(*) FROM table_name)`), and two that fetch each count individually. It calculates a **percentage variation** as `(view_count - table_count) / view_count × 100`, logs the individual counts, the raw difference, and the percentage — then **returns the count difference value** so the calling test can assert whether the gap is within an acceptable threshold.

**The four root causes you learned to diagnose:**

1. **Deleted records in BODS** — BODS had soft-delete logic that physically removed records over time. The new architecture via Fivetran preserves deletes using `_FIVETRAN_DELETED = TRUE`. So the old system shows fewer rows than the new one not because of a bug, but because the new architecture keeps deleted records. You validate this by checking `_FIVETRAN_DELETED` flags.

2. **Scheduling misalignment** — If the dbt job ran before Fivetran had finished syncing the source, the count would be lower on the new side simply because the sync wasn't complete yet. You validate this by checking `_FIVETRAN_SYNCED` — if the max sync timestamp is behind, the dbt job ran too early.

3. **Source table filters not applied in Fivetran** — In BODS, some technical SAP tables had WHERE clause filters applied during extraction (e.g., excluding certain company codes or plants). Fivetran ingests the full table without those filters. So the new architecture had *more* rows than BODS for those tables. You identify this by running a GROUP BY on the filter columns (company code, plant, etc.) and checking which values exist in Fivetran but not in BODS.

4. **Digging into *where* the mismatch is** — When a count mismatch was confirmed as a real issue (not scheduling, not deletes, not filters), you ran GROUP BY queries on date columns (`LOAD_DATE`, `_FIVETRAN_SYNCED`) to find the exact date range where rows diverged. This narrowed the investigation from "something is wrong with this table" to "rows are missing for dates X to Y — which corresponds to this specific BODS job run."

---

### Tier 2 — Metadata Test (Schema Mismatch)

**What it does:**
A dbt Jinja macro `metadata_mismatch(view_name, table_name)` where both arguments are fully qualified `db.schema.table` strings parsed via Jinja string splitting. It queries `INFORMATION_SCHEMA.COLUMNS` for both systems and builds two CTEs: `legacy_details_edw` for the old BODS table — filtering out system columns (`EFF_DATE_TO`, `LOAD_DATE`, `EFF_DATE_FROM`, `SOURCE_SYSTEM`, `FLAG`, `ACTIVE`) and any columns with `PK` or `HK` suffixes — and `core_published_edw` for the new Fivetran view, excluding `PK`/`HK` columns. It then LEFT JOINs old-to-new on column name, with view naming pattern logic to handle four conventions: `V_<table>_CFIN`, `V_<table>_EWM`, `V_<table>_GLOBAL`, and `V_<table>`. The WHERE clause surfaces only rows where at least one of `data_type`, `CHARACTER_MAXIMUM_LENGTH`, `numeric_scale`, or `datetime_precision` diverges between old and new. Separately, it runs two count queries against `INFORMATION_SCHEMA` (using the same exclusion filters) to compute a **percentage variation in column counts** between the two tables, logging both counts and the variation alongside a pass/fail mismatch flag.

**Why this was needed:**
Fivetran ingests SAP tables and infers data types automatically. But SAP's data model uses types that don't map cleanly to Snowflake defaults — dates arrive as `VARCHAR(8)` in `YYYYMMDD` format, numeric codes arrive as strings. The metadata test made these discrepancies visible by directly comparing the INFORMATION_SCHEMA of the old table and the new view side by side, rather than waiting for downstream models to silently produce wrong results on date arithmetic or numeric casts.

**The two root causes for metadata mismatches:**

1. **Tables from shared DB, not Fivetran** — Some reference tables were not loaded through Fivetran. They came from a shared Snowflake database directly. These tables had different type handling because the shared DB didn't go through the same Fivetran inference pipeline and landed with different column types, surfacing as metadata mismatches even when the data itself was correct.

2. **Technical table name differences** — In some cases, the technical table name in the old BODS architecture didn't match the table name in the new architecture. When none of the four view-naming patterns (`V_<table>_CFIN`, `V_<table>_EWM`, `V_<table>_GLOBAL`, `V_<table>`) matched the actual view name, the LEFT JOIN returned NULLs for the new-side columns — producing false mismatches. The fix was ensuring the correct naming convention was captured in the macro's ON clause conditions.

---

### Tier 3 — Data Mismatch Test

**What it does:**
A dbt Jinja macro `data_mismatch(source_table, target_table)` where `source_table` is the new Fivetran-ingested table and `target_table` is the old BODS table — both as fully qualified `db.schema.table` strings parsed via Jinja. It first runs an INTERSECT on `INFORMATION_SCHEMA.COLUMNS` for both tables to identify **common columns only**, excluding columns with `PK` or `HK` suffixes and `LOAD_DATE`/`INTIAL_LOAD_DATE`. For each common column it checks the data type: `TEXT`/`VARCHAR` columns get a whitespace normalization expression — `IFF(col = ' ', '', col)` — baking in the fix for single-space padding differences between BODS and Fivetran at query-build time. It then constructs and runs an EXCEPT query: rows from the target (BODS) that are not present in the source (Fivetran) after normalization, labeled `'Missing in BODS'`. In parallel, it computes a **column-count percentage variation** between both tables via INFORMATION_SCHEMA. The macro logs individual column counts, the percentage variation, and whether any mismatch exists — then **returns a list of the mismatch row indicators** for the calling test to evaluate. This is the deepest tier of validation, and the hardest to debug.

**The three root causes you found:**

1. **Whitespace in column values** — The most subtle bug: a column value in the old BODS output had single-space padding (e.g., `' '`), while the new Fivetran-ingested value was an empty string `''`. The EXCEPT comparison would flag these as mismatches even though the data was semantically identical. The macro handles this at build time: for every `TEXT`/`VARCHAR` column it wraps the value in `IFF(col = ' ', '', col)` — converting single-space strings to empty strings before the EXCEPT runs.

2. **Fivetran value differences vs BODS** — BODS applied transformation logic during extraction (e.g., uppercase conversion, special character handling, code mappings). Fivetran ingests raw values from SAP with no transformation. So values that BODS "cleaned up" during extraction appeared different in the new architecture. Each case had to be investigated and a corresponding transformation added in dbt.

3. **UNION ALL column name mismatches in global models** — The global models combine EAGLE (US SAP system) and UNICORN (EU SAP system) via `UNION ALL`. If a column was named `WERKS` in one SAP system and `PLANT` in the other, the `UNION ALL` would silently align the wrong columns — no SQL error, just wrong data. The data mismatch test caught these because the EXCEPT comparison surfaced rows with transposed values that didn't match the BODS output. The fix was explicitly aliasing every column in both sides of the `UNION ALL` to a consistent name before combining.

---

### How to Open (say this first)

> *"This wasn't dbt generic tests — not unique or not_null. This was a custom validation framework built specifically for the migration context: we had an old BODS architecture and a new Fivetran-plus-dbt architecture, and we needed to prove they were producing the same data. I built three tiers of checks — count comparison via parameterized macros, column-level schema comparison against INFORMATION_SCHEMA, and row-level data comparison using SQL EXCEPT — and deployed them across all 600 models. When something failed, each tier had a specific set of root causes we knew to investigate."*

---

### Key Technical Points to Cover

| # | Point | What to say |
|---|-------|-------------|
| 1 | **Why custom and not Great Expectations or dbt generic tests** | "dbt generic tests validate internal data quality — uniqueness, nulls, referential integrity. Great Expectations does the same. Neither is designed for cross-architecture migration validation — comparing a BODS output table against a Fivetran-ingested dbt model row by row. We needed something purpose-built for that context." |
| 2 | **How the metadata test detects schema drift** | "The metadata_mismatch macro queries INFORMATION_SCHEMA.COLUMNS for both the old BODS table and the new Fivetran view, builds two CTEs, and LEFT JOINs them on column name — with four OR conditions to handle naming conventions like V_TABLE_CFIN or V_TABLE_GLOBAL. The WHERE clause surfaces only rows where data_type, character length, numeric scale, or datetime precision differs. It also computes percentage variation in column counts, so you can detect columns that exist in one system but not the other." |
| 3 | **How the data mismatch test handles whitespace without breaking the comparison** | "The data_mismatch macro uses Jinja to dynamically build the SELECT at query time. For every TEXT or VARCHAR column, it wraps the value in IFF(col = ' ', '', col) before the EXCEPT — so single-space padding from BODS is normalized to an empty string before comparison. This happens at macro compile time, not as a post-filter, so it's baked into the query itself." |
| 4 | **UNION ALL + EAGLE/UNICORN column name mismatch** | "Global models combine EAGLE (US) and UNICORN (EU) SAP systems via UNION ALL. SQL doesn't validate that column names align across UNION branches — it just aligns by position. If EAGLE has columns in order A, B, C and UNICORN has them in order A, C, B, Snowflake silently puts B's data in C's column. The EXCEPT-based data mismatch test surfaced this because the transposed values no longer matched the BODS output. The fix was explicit column aliases on both sides of every UNION ALL." |
| 5 | **The GROUP BY + date column debugging technique** | "When a count mismatch passed the basic checks (not deletes, not scheduling), I ran a GROUP BY on date columns to find exactly which date range had missing rows. If rows were missing only for dates in a specific 2-week window, that pointed to a specific BODS job failure or a Fivetran backfill gap — it narrowed the investigation dramatically." |
| 6 | **Scale — 600 models** | "All three macros are fully parameterized — you call count(), metadata_mismatch(), or data_mismatch() with a source and target table name. Deploying a new table to the framework was a matter of adding one macro call per tier. That's what made 600-model coverage achievable — the validation logic scaled with the macro infrastructure, not with per-table test code." |

---

### Anticipated Follow-up Questions

**Q: How is this different from dbt's `unique` and `not_null` tests?**
> dbt generic tests are intra-model — they validate that a single model's data meets a constraint. They have no concept of comparing against another system's output. Our count macro is cross-system: fire a `run_query()` against the BODS table, fire another against the dbt model, compute the difference and percentage variation. That's fundamentally different from anything dbt's built-in test framework does.

**Q: Why use SQL EXCEPT instead of a JOIN for the data mismatch test?**
> A JOIN-based comparison requires a reliable key. In a migration context, you often can't guarantee that key structure is identical between old and new — especially for tables that went through BODS transformation logic. EXCEPT compares full rows after column normalization, so you don't need a pre-agreed key. Any row that exists in BODS but not in the new architecture surfaces automatically, regardless of what caused the difference.

**Q: How does the metadata test handle the fact that view names in the new system differ from table names in the old system?**
> The LEFT JOIN in the metadata_mismatch macro has four OR conditions in the ON clause to account for naming conventions: it checks if the new-side table is `V_<table>_CFIN`, `V_<table>_EWM`, `V_<table>_GLOBAL`, or simply `V_<table>`. If none of those match, the LEFT JOIN returns NULLs on the new side — which is how unmapped tables surface and flag themselves for investigation.

**Q: What does the percentage variation metric in the count and metadata macros actually tell you?**
> It's a signal for triage, not a hard pass/fail on its own. A 0.1% count variation on a 10M-row table might be acceptable scheduling lag. A 5% variation on a 100-row reference table is a real problem. The metadata percentage variation tells you whether columns are being added or dropped between systems — a structural concern separate from individual type mismatches.

**Q: What does "TDD paradigm" mean in a data context?**
> In software TDD, you write tests first and code second. Here, before implementing each model in the new architecture, we defined what "correct" looked like — the count, the schema, the row values — based on the BODS output. The model was only considered done when all three tiers of checks passed. The tests drove the implementation rather than being added after the fact.

---

### Pitfalls to Avoid

- **Don't just say "I wrote data quality tests."** That sounds like `not_null` and `unique`. Immediately clarify this was a **cross-architecture migration validation framework** — it only makes sense in the context of an old system vs new system comparison.
- **Don't skip the root cause investigation angle.** The value isn't just that tests existed — it's that when they failed, you had a systematic checklist of causes to investigate. That's the difference between a test suite and a debugging framework.
- **The UNION ALL bug is your strongest concrete story.** It's a real bug, it was silent (no SQL error), and the EXCEPT-based data mismatch test was the only way to catch it. Use it whenever the interviewer asks "can you give me a specific example of a bug you caught?"
- **Don't describe these as dbt tests.** They are dbt Jinja macros that call `run_query()` at execution time and return results. They're not schema tests declared in YAML — that distinction matters if the interviewer knows dbt internals.

---

---
