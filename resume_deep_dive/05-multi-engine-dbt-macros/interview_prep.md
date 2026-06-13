## Bullet 5 — Multi-Engine dbt Macros (HRMS: Snowflake + Redshift)

> *"Engineered multi-engine dbt macros leveraging Snowflake and Redshift adapters. This achieved platform portability, created reusable components, and significantly reduced code duplication across the dual data warehouse environment."*
>
> **Files:** `macros/snowflake_migration/compat/strtol_function.sql`, `macros/dbt/udf_sp_ddl/udf_f_strtol_sf.sql`, `macros/snowflake_migration/compat/json_parse.sql`, `macros/snowflake_migration/compat/json_extract_path_text_single.sql`, `macros/snowflake_migration/compat/semi_struct.sql`, `macros/snowflake_migration/compat/bool_or.sql`, `macros/snowflake_migration/compat/bool_and.sql`, `macros/snowflake_migration/compat/dayofweek.sql`, `macros/snowflake_migration/compat/timestamps.sql`

---

### The Setup — What to Say Before Any Macro

> *"The HRMS project had a dual data warehouse setup — the existing system was on Redshift and we were migrating to Snowflake. During the transition window, models had to run correctly on both engines simultaneously. Redshift and Snowflake look similar — both SQL, both columnar — but they diverge sharply across five categories: DML dialect, missing functions, JSON ecosystem, aggregation naming, and date/time behavior. Writing `IF target == Redshift THEN ... ELSE ...` scattered across hundreds of models is unmaintainable. dbt solves this with `adapter.dispatch()` — a compile-time routing mechanism where you write one macro call in the model and dbt resolves it to the correct engine-specific implementation automatically. I'll walk you through the macros I built, grouped by which category of incompatibility they solve."*

---

### The Mechanism — `adapter.dispatch()` in One Minute

Every `compat_*` macro has this structure:

```sql
{%- macro compat_example(value) -%}
    {{ return(adapter.dispatch('compat_example')(value)) }}
{%- endmacro -%}

{%- macro redshift__compat_example(value) -%}
    -- Redshift SQL here
{%- endmacro -%}

{%- macro snowflake__compat_example(value) -%}
    -- Snowflake SQL here
{%- endmacro -%}
```

The naming convention is the key: `{adapter_name}__{macro_name}`. dbt reads the current adapter from the connection profile and dispatches to the matching implementation at compile time. The model calls `{{ compat_example(my_col) }}` and never knows which engine it's on.

---

### The Story Arc (STAR format)

**Situation:**
The HRMS project was migrating from Redshift to Snowflake. The business requirement was that models had to produce correct output on both platforms during the migration window — Redshift couldn't be shut off on day one.

**Problem:**
As I started working through the models, I hit four distinct categories of incompatibility. It wasn't just "some functions have different names." One function existed in Redshift but literally didn't exist in Snowflake at all. The JSON stack was three layers of incompatibility that had to be solved together. Some had the same name but different behavior depending on session parameters. And some aggregate functions had completely different names on each engine. Writing inline platform conditionals across hundreds of models was not viable.

**Action:**
I built a library of `compat_*` macros — one per incompatibility — using dbt's `adapter.dispatch()` pattern. Each macro is a single call site in the model, backed by engine-specific implementations. I'll group them by category so you can see the range of problems they solved.

**Result:**
The same model files ran correctly on both engines. When Redshift was decommissioned at migration end, removing support was deleting the `redshift__` implementation files — no model code changed.

---

### Category 1 — Missing Function: `compat_strtol_function` (your most unique story)

**Files:** `macros/snowflake_migration/compat/strtol_function.sql`, `macros/dbt/udf_sp_ddl/udf_f_strtol_sf.sql`

**What is `STRTOL` and why does it matter:**
`STRTOL` (string-to-long) converts a string representation of a number from any numeric base to a decimal integer. Examples: `STRTOL('FF', 16)` → 255, `STRTOL('777', 8)` → 511, `STRTOL('1010', 2)` → 10. In the HRMS data, certain identifier columns stored values in hex or octal encoding — a common pattern in legacy HR and payroll systems. Redshift has `STRTOL` as a native built-in. **Snowflake has no equivalent function whatsoever.**

**The Redshift side — one line:**
```sql
{%- macro redshift__compat_strtol_function(value, base) -%}
    strtol({{ value }}, {{ base }})
{%- endmacro -%}
```

**The Snowflake side — a Python UDF:**
```sql
{%- macro snowflake__compat_strtol_function(value, base) -%}
    {{ udf('f_strtol_sf') }}({{ value }}, {{ base }})
{%- endmacro -%}
```

Because Snowflake has no native `STRTOL`, I had to write a custom Python UDF called `f_strtol_sf` and register it in Snowflake. The UDF replicates the exact behavior of Redshift's `STRTOL` including all edge cases:

| Edge case | Behavior |
|-----------|----------|
| `NULL` input | Returns `NULL` (Snowflake passes Python `None`) |
| Empty string `''` | Returns `0` |
| String starting with null char `'\0'` | Returns `0` |
| Leading whitespace | Stripped before conversion |
| Leading `+` / `-` sign | Handled correctly |
| `0x` / `0X` prefix when base is 16 | Stripped before conversion |
| Invalid characters for the given base | Returns `NULL` instead of error |

The `udf()` helper macro also handles environment-aware naming: in prod it resolves to `schema.dbt_udf_f_strtol_sf`, in non-prod environments it appends the `DBT_WH_ALIAS` env variable to prevent UDF name collisions across dev environments.

**What to say to the interviewer:**

> *"This was the most interesting macro because the problem wasn't that Snowflake called the function something different — it was that Snowflake didn't have the function at all. Redshift's `STRTOL` converts base-encoded strings to integers — hex, octal, binary. The HRMS data had identifier columns stored in these formats. For Redshift, one line of SQL. For Snowflake, I had to write a Python UDF from scratch that replicated STRTOL's exact behavior — including NULL handling, empty string handling, the null-character edge case, sign handling, and the `0x` prefix for hex. Then I registered that UDF in Snowflake and wired the compat macro to call it. The dispatch pattern made all of this invisible to the model — it called `compat_strtol_function(col, 16)` and dbt injected the right implementation."*

---

### Category 2 — JSON Ecosystem: Three Layers That Must All Work Together

**Files:** `macros/snowflake_migration/compat/json_parse.sql`, `macros/snowflake_migration/compat/json_extract_path_text_single.sql`, `macros/snowflake_migration/compat/semi_struct.sql`

> *"When I worked through the JSON models, I realized the incompatibility wasn't one function — it was the entire JSON stack. Parsing, extraction, and column access all diverge between Redshift and Snowflake. I built three related compat macros that form a pipeline — you can't fix one layer without fixing all three."*

**Layer 1 — Parsing (`compat_json_parse`)**

| Engine | Function | On invalid JSON |
|--------|----------|-----------------|
| Redshift | `JSON_PARSE(str)` | Throws an error |
| Snowflake | `TRY_PARSE_JSON(str)` | Returns `NULL` — no error |

Snowflake's `TRY_PARSE_JSON` is safer for pipelines — a malformed JSON string returns NULL and the row loads. Redshift errors and stops the load. A deliberate tradeoff: Redshift fails loudly, Snowflake fails silently. Both behaviors are intentional for their respective environments.

**Layer 2 — Key extraction (`compat_json_extract_path_text_single`)**

| Engine | Call | Behavior |
|--------|------|----------|
| Redshift | `JSON_EXTRACT_PATH_TEXT(json_str, key, TRUE)` | Accepts raw string. `TRUE` = suppress missing-path errors |
| Snowflake | `JSON_EXTRACT_PATH_TEXT(TRY_PARSE_JSON(json_str), key)` | Input **must** be VARIANT, not a raw string |

This is the most dangerous incompatibility in the JSON stack. On Snowflake, if you pass a raw JSON string to `JSON_EXTRACT_PATH_TEXT` without first calling `TRY_PARSE_JSON`, Snowflake returns `NULL` **silently — no error, no warning**. Your pipeline runs without failing, every JSON column is NULL, and the bug is invisible until someone queries the data. The compat macro forces the pre-parse step on Snowflake.

**Layer 3 — Column access (`compat_semi_struct`)**

| Engine | Syntax | Example |
|--------|--------|---------|
| Snowflake | `column:key` (colon operator) | `payload:user_id` |
| Redshift | `column.key` (dot operator) | `payload.user_id` |

Snowflake uses `:` for VARIANT semi-structured column access. Redshift uses `.` for SUPER type access. A model that uses one syntax won't even parse on the other engine — immediate compile error.

> *"The lesson from the JSON macros is that incompatibilities cluster. You can't fix extraction if parsing is wrong. You can't fix parsing if column access syntax doesn't compile. The three macros have to be used together as a pipeline: parse → extract → access."*

---

### Category 3 — Naming Divergence: `compat_bool_or` and `compat_bool_and`

**Files:** `macros/snowflake_migration/compat/bool_or.sql`, `macros/snowflake_migration/compat/bool_and.sql`

This category is about aggregate functions that do the same thing but have completely different names on each engine.

| Concept | Redshift | Snowflake |
|---------|----------|-----------|
| Boolean OR aggregate | `BOOL_OR(expr)` | `BOOLOR_AGG(expr)` |
| Boolean AND aggregate | `BOOL_AND(expr)` | `BOOLAND_AGG(expr)` |

`BOOL_OR` returns TRUE if any row in the group is TRUE. `BOOL_AND` returns TRUE only if all rows are TRUE. These are standard SQL aggregate functions, and Redshift uses the standard names. Snowflake uses its own naming convention. Neither name compiles on the other engine.

The macros here are simple — one-line dispatches — but they matter because these aggregations appear frequently in data quality and flag-aggregation logic. Without the compat macro, every GROUP BY model that uses a boolean aggregate would have an inline conditional.

> *"BOOL_OR and BOOL_AND are a good example of the naming gap category — same concept, same semantics, completely different function names. The compat macro is five lines. The value isn't the complexity of the macro — it's that the dispatch pattern means the fifty models that use boolean aggregation never need to know which engine they're on."*

---

### Category 4 — Hidden Behavior Gap: `compat_dayofweek`

**File:** `macros/snowflake_migration/compat/dayofweek.sql`

```sql
-- Redshift
date_part('dow', {{ date_expr }})        -- returns 0=Sun, 1=Mon, ..., 6=Sat. Always.

-- Snowflake
DAYOFWEEK({{ date_expr }}) - 1          -- the -1 is not obvious
```

**Why the `- 1` exists — the session parameter trap:**
This is the most deceptive incompatibility in the whole library because both engines have a function called `DAYOFWEEK` — but they don't behave the same way.

Redshift's `date_part('dow', ...)` always returns 0–6 (Sunday = 0) regardless of any session settings. It is deterministic by definition.

Snowflake's `DAYOFWEEK()` output depends on the account-level `WEEK_START` parameter. If `WEEK_START = 1` (Monday, which is the setting in many European or internationally-configured Snowflake accounts), `DAYOFWEEK()` returns 1=Monday through 7=Sunday. The `- 1` in the Snowflake implementation corrects for this: `DAYOFWEEK() - 1` gives 0=Monday through 6=Sunday, aligning the numeric output with what the downstream models expected based on Redshift's behavior.

**What to say:**

> *"DAYOFWEEK looks like a simple rename — both engines have a function called DAYOFWEEK. But Snowflake's output depends on the account-level WEEK_START parameter, which in this environment was set to Monday. That makes DAYOFWEEK return 1–7 instead of 0–6. The `- 1` in the Snowflake implementation is a correction for that account configuration. If you didn't know about WEEK_START, you'd write `DAYOFWEEK(date)` on Snowflake, it would compile with no error, it would return results — just off by one from what Redshift produced. That kind of silent off-by-one in a date column is extremely hard to catch without comparing outputs between both engines."*

---

### How to Open (say this first)

> *"The HRMS project was a live migration from Redshift to Snowflake. During the transition window, both engines had to produce correct results simultaneously. As I worked through the models, I hit four categories of incompatibility — not just function renames. One function existed in Redshift and had no equivalent in Snowflake at all, so I had to write a Python UDF from scratch. JSON was three layers of incompatibility that had to be fixed together as a pipeline. Then there were subtler things — aggregate functions with different names, and date functions that had the same name but different output depending on a session parameter. I solved all of them with dbt's `adapter.dispatch()` pattern — one call site in the model, engine-specific implementation behind it, transparent to whoever writes the model."*

---

### Key Technical Points to Cover

| # | Category | Macro | What to say |
|---|----------|-------|-------------|
| 1 | **Missing function** | `compat_strtol_function` | "Redshift has native STRTOL for base conversion — hex, octal, binary to decimal. Snowflake has nothing. I wrote a Python UDF that replicates STRTOL's exact behavior including NULL, empty string, null-char, sign, and 0x-prefix edge cases. The compat macro calls the native function on Redshift and the UDF on Snowflake." |
| 2 | **JSON ecosystem** | `json_parse` + `json_extract` + `semi_struct` | "Three layers: Redshift accepts raw strings for extraction, Snowflake requires pre-parsing to VARIANT — skip it and you get silent NULLs with no error. Column access uses `:` on Snowflake and `.` on Redshift. All three layers have to be fixed together." |
| 3 | **Naming gap** | `compat_bool_or`, `compat_bool_and` | "`BOOL_OR`/`BOOL_AND` on Redshift (ANSI SQL names), `BOOLOR_AGG`/`BOOLAND_AGG` on Snowflake. Same semantics, neither compiles on the other engine. Simple macros — the value is that fifty models that use boolean aggregation never need an inline conditional." |
| 4 | **Hidden behavior gap** | `compat_dayofweek` | "Both engines have DAYOFWEEK but Snowflake's output depends on the account-level WEEK_START parameter. With WEEK_START=1 (Monday), Snowflake returns 1–7 instead of 0–6. The `- 1` in the macro corrects for that. Same function name, completely different output — no error, just wrong numbers." |
| 5 | **Why not inline conditionals** | — | "With `{% if target.type %}` in every model, every model carries both engines' logic. Adding a third engine means touching every model. With dispatch, you add one new implementation file. The migration boundary is in one place." |

---

### Anticipated Follow-up Questions

**Q: What is `adapter.dispatch()` — how does dbt know which implementation to call?**
> dbt follows the naming convention `{adapter_type}__{macro_name}`. When `adapter.dispatch('compat_strtol_function')` is called, dbt checks the adapter from the connection profile — `snowflake`, `redshift`, etc. — and resolves to `snowflake__compat_strtol_function` or `redshift__compat_strtol_function`. If neither exists, it falls back to `default__` if defined, otherwise raises a compile-time error before any SQL runs.

**Q: Why did you write a Python UDF for STRTOL instead of reimplementing it in SQL?**
> Snowflake SQL doesn't have the primitives to cleanly replicate STRTOL for arbitrary bases in a single expression — especially with all the edge cases (null char, sign handling, 0x prefix). Python's `int(s, base)` handles all of that natively. Snowflake's Python UDF runtime is the right tool: it runs server-side, integrates with the query engine, and handles the `None` → SQL NULL mapping automatically. A SQL-only reimplementation would have been 50+ lines of CASE statements and still missed edge cases.

**Q: What happens if the same input goes into the Python UDF with a base that doesn't make sense?**
> The UDF wraps the `int(s_strip, base)` call in a `try/except ValueError` and returns `NULL` on invalid input rather than erroring. This matches Redshift's `STRTOL` behavior — it returns NULL for invalid characters in the given base rather than stopping the query. Matching the edge case behavior exactly is what makes the migration transparent.

**Q: For DAYOFWEEK, why didn't you just set Snowflake's WEEK_START to match Redshift's?**
> You could, in theory. But changing an account-level parameter affects every query in the entire Snowflake account — not just the migration models. Other teams and other pipelines may rely on the current WEEK_START setting. It's safer to absorb the offset in the compat macro than to change a session parameter that has account-wide scope.

**Q: For the JSON silent NULL — how did you catch that in the first place?**
> The data validation framework (the count and data mismatch tests described in Bullet 4) caught it — row-level hashes between Redshift and Snowflake didn't match on models that had JSON extraction. When I drilled into specific rows, every JSON column was NULL on the Snowflake side even though the raw source had valid JSON. That pointed to the extraction call failing silently, which led to finding the missing `TRY_PARSE_JSON` pre-parse step.

**Q: What was the migration validation strategy — how did you confirm both engines produced the same output?**
> We ran dbt against both profiles and then used audit macros that compared specific tables between the Redshift output and the Snowflake output at the row and column level — checking counts, data types, and actual values. Discrepancies in the compat layer showed up as count mismatches or value mismatches in those audits, which is how issues like the DAYOFWEEK off-by-one and the JSON silent NULL were surfaced systematically.

---

### Pitfalls to Avoid

- **Don't just say "I wrote macros for both engines."** Immediately follow with the four-category framework: missing function, JSON ecosystem, naming gap, hidden behavior gap. That framing shows you understood the problem space, not just the solution.
- **Lead with `compat_strtol_function` if asked for your most unique contribution.** Writing a Python UDF to fill a platform gap is rare — most people just rename functions. The strtol story shows you went beyond what was available.
- **Lead with the JSON trio if asked for your most technically complex macro story.** Three layers of incompatibility that must be fixed together as a pipeline — parsing, extraction, and column access — and a silent NULL failure mode that only surfaces when someone queries the data.
- **The JSON silent NULL is your best "near-production-bug" story.** Use it when the interviewer asks about a mistake you caught, a production risk you avoided, or failure modes in migrations.
- **The DAYOFWEEK `- 1` needs the WEEK_START context.** If you just say "Snowflake uses DAYOFWEEK, Redshift uses date_part," it sounds like a rename. The story is that Snowflake's output is session-parameter-dependent — same function, different numbers — and that's what makes it dangerous.
- **Have the `{% if target.type %}` counter-argument ready.** The dispatch pattern's real value is that it isolates the platform boundary to the macro layer. One new engine = one new file. Inline conditionals = touch every model.

---

---
