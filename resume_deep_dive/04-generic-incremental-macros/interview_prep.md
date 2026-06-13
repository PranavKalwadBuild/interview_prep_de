## Bullet 4 — Generic Incremental Macros (Data Mesh Migration)

> *"Engineered generic incremental macros to automate ETL logic for three major SAP sources during a Data Mesh migration, reducing the development timeline by 100+ days of manual hours."*
>
> **Files:** `macros/cfin/incremental_merge_cfin.sql`, `macros/ewm/incremental_merge_ewm.sql`, `macros/eagle/incremental_merge_eagle.sql`, `macros/unicorn/incremental_merge_unicorn.sql`

---

### The Story Arc (STAR format)

**Situation:**
We were migrating SAP data from three major source systems — CFIN (Finance), EWM (Extended Warehouse Management), EAGLE, and UNICORN — into a Snowflake-based Data Mesh. Each source had dozens of tables, and the existing approach was to write individual dbt models for every single table — each with its own hand-coded ETL logic.

**Problem:**
Every new table required a developer to manually write the incremental logic from scratch: figure out the unique keys, build the hash key, wire up the watermark filter, handle NULLs in join conditions. For 600+ models across four SAP sources, that was going to take months. The team needed a way to generalize this pattern without sacrificing correctness.

**Action — this is the core of what to explain:**
I designed a set of generic macros — one per SAP source — where each macro accepts just four parameters: `source_table`, `target_schema`, `reference_seed`, and `unique_key_columns`. The macro does everything else automatically:

1. **Dynamic column discovery** — At execution time it queries `information_schema.columns` for that specific source table. This means the macro never needs to be updated when a source table's schema changes. It always reflects the live schema.
2. **SHA2 hash key generation** — It builds a `SHA2(HASH(...), 256)` hash across ALL columns except the unique keys and `_FIVETRAN_SYNCED`. This hash becomes the row's "fingerprint" to detect whether anything actually changed.
3. **The incremental pattern** — Instead of dbt's standard MERGE-based approach, I used a `SELECT + LEFT JOIN` against `{{ this }}` (the already-loaded target table), gated behind `is_incremental()`. This means:
   - On the first run: `is_incremental()` is false, so the full LEFT JOIN block is skipped and ALL rows load.
   - On every subsequent run: only rows that pass BOTH filters are loaded — the watermark filter (`_FIVETRAN_SYNCED > max already loaded`) AND the hash comparison filter (`new hash ≠ existing hash OR row doesn't exist yet`).
4. **NULL-safe join keys** — SAP data frequently has NULL composite keys. Standard `=` comparisons would silently drop those rows. I explicitly handled this with `(tgt.col = src.col OR (tgt.col IS NULL AND src.col IS NULL))` for every key column.
5. **EAGLE and UNICORN added multi-source complexity** — those sources had tables coming from two different schemas (raw tables vs. views), so the join conditions are OR-ed across source types, and the source schema is resolved dynamically from environment variables.

**Result:**
A developer adding a new SAP table now calls the macro with four parameters instead of writing 70+ lines of ETL logic from scratch. Across 600 models, this eliminated 100+ days of repetitive development work and standardized the incremental pattern so data quality issues from one-off mistakes in hand-coded logic were eliminated entirely.

---

### How to Open (say this first — word for word if needed)

> *"The problem we were solving was that we had hundreds of SAP source tables to migrate and every table needed the same incremental ETL logic — but we were writing it by hand each time. I designed a generic macro that takes just the table name and its key columns as input, and handles everything else — schema introspection, hash key generation, watermark filtering, and NULL-safe joins — automatically."*

That one sentence tells the interviewer: you saw a pattern, you abstracted it, and you measured the impact. Everything after that is just answering their follow-up questions.

---

### Key Technical Points to Cover (in order of importance)

| # | Point | What to say |
|---|-------|------------|
| 1 | **The LEFT JOIN + `is_incremental()` pattern** | "On the first run, `is_incremental()` returns false, so the whole join block is skipped — it's a full load. On incremental runs, we LEFT JOIN the source CTE against the existing target table. The WHERE clause then does two things: first, a watermark check using `_FIVETRAN_SYNCED > max(_FIVETRAN_SYNCED)` to only consider recently synced rows. Second, a hash comparison to ensure we only insert rows where the content actually changed OR the row is brand new (tgt key is NULL)." |
| 2 | **Why LEFT JOIN instead of dbt's built-in `unique_key` MERGE** | "dbt's native incremental MERGE does an upsert — it updates existing rows in place. We wanted an **append-only** pattern to preserve history. The LEFT JOIN approach inserts changed rows as new records rather than overwriting the old ones. This is a deliberate data vault / audit-trail decision." |
| 3 | **SHA2 hash key as a change detector** | "Instead of comparing individual columns — which would mean rewriting the WHERE clause for every table — I compute a SHA2 hash across all non-key, non-watermark columns. If the hash changes between source and target, the row has changed. One comparison instead of N comparisons, and it's automatically updated when new columns are added to the source." |
| 4 | **Dynamic schema introspection** | "The macro queries `information_schema.columns` at compile time to discover which columns exist. This makes the macro schema-agnostic — if a new column is added upstream in Fivetran, the macro picks it up on the next run without any code changes." |
| 5 | **NULL-safe composite keys** | "SAP tables often have composite primary keys that can contain NULLs. A standard `ON tgt.col = src.col` join silently fails for NULL values — the join just doesn't match. I replaced every key comparison with the pattern `(tgt.col = src.col OR (tgt.col IS NULL AND src.col IS NULL))` which correctly handles NULL equality." |
| 6 | **Generic across sources** | "The same pattern is replicated for CFIN, EWM, EAGLE, and UNICORN. EAGLE and UNICORN were more complex because some tables come from raw schemas and others from view schemas, so the join condition OR's across source types and the source schema is resolved from environment variables." |

---

### Anticipated Follow-up Questions

**Q: What is `is_incremental()` — how does dbt know when to use it?**
> dbt sets `is_incremental()` to `true` when three conditions are met: (1) the target table already exists, (2) the model is configured as `incremental` materialization, and (3) it's not a `--full-refresh` run. On `--full-refresh`, it drops and recreates the table, and `is_incremental()` returns false.

**Q: Why use `_FIVETRAN_SYNCED` as the watermark column?**
> Fivetran automatically adds `_FIVETRAN_SYNCED` to every synced table — it's the timestamp of when Fivetran last touched that row. We use it as the watermark because it's reliable, always present, and Fivetran maintains it. Using a business timestamp would be riskier since SAP business dates can be backdated.

**Q: What happens if `_FIVETRAN_SYNCED` has never been populated — i.e., the target table is empty?**
> The `COALESCE(max(_FIVETRAN_SYNCED), '1900-01-01')` handles that. If the target is empty, max returns NULL, coalesce substitutes `'1900-01-01'`, and the watermark filter passes every source row — effectively behaving like a full load.

**Q: Could two rows produce the same SHA2 hash? What about hash collisions?**
> SHA2-256 has a collision resistance of 2^128 — it's practically zero risk for a business dataset. We accepted that tradeoff. The hash is used as a change detector, not a cryptographic security mechanism.

**Q: Why `random()` on the unique key column for the null check?**
> For tables with composite keys, we just need to check if the row exists in the target at all. We pick one of the key columns at random and check `tgt.that_column IS NULL` — if it's null, the LEFT JOIN found no match, meaning it's a brand new row. Any key column would work for this check; `random()` was used to avoid hardcoding a specific column name.

**Q: How did this save 100+ days?**
> Each SAP source table previously required manually writing a dbt model with: the column list, the hash expression, the watermark filter, the join condition, NULL handling. Average time per table was roughly 1-2 hours. We had ~600 models across four sources. With the macro, a new table model is 5-10 lines calling the macro — maybe 15 minutes including testing. The delta multiplied across 600 models is where the 100+ days comes from.

---

### Pitfalls to Avoid

- **Don't say "I used dbt incremental models"** and stop there. Every dbt engineer uses incremental models. The interesting part is the LEFT JOIN pattern, the hash key, and the NULL-safe joins — go there.
- **Don't confuse `is_incremental()` with `incremental_strategy`**. If they ask about merge vs append vs insert_overwrite, be clear: this is an append-only pattern using `unique_key`-less incremental materialization. You're doing the "upsert" logic yourself via the LEFT JOIN filter.
- **Don't undersell the NULL handling**. This is a detail that separates someone who's thought about data quality from someone who just writes happy-path code. Lead with it if the conversation goes to data quality.
- **Don't say "it was a generic macro for three sources"** — it was four (CFIN, EWM, EAGLE, UNICORN), and EAGLE/UNICORN were more complex because they handled multi-schema sources with OR'd join conditions.

---

---
