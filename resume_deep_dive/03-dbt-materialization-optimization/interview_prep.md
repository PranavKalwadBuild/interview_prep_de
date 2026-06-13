## Bullet 3 — dbt Materialization Optimization (70% Runtime Reduction)

> *"Optimized complex analytical models by strategically leveraging dbt materialization configurations, achieving a 70% reduction in model runtime and significantly decreasing compute costs."*
>
> **Files:** `models/transform/global/tables/` (e.g. `customer_enrich.sql`, `product_enrich.sql`), `models/transform/global/views/` (e.g. `v_gir_fact_global_inventory_total_int.sql`), `dbt_project.yml`

---

### Why the Current Framing Is Weak — and How to Fix It

The problem with saying "I changed views to incremental and got 70% improvement" is that it sounds like one config change produced a magical result. No interviewer believes that. The 70% is real — but it came from **three compounding performance problems**, and you need to be able to name all three and explain how each one contributed. When you can break it down that way, the number becomes completely credible.

---

### The Three Compounding Problems (memorise this structure)

```
Problem 1 — View chain re-execution       → same expensive SQL re-runs on every dbt execution
Problem 2 — Fan-out multiplication         → that same expensive SQL runs N times per execution
Problem 3 — Full dataset on every run      → processing 1TB daily even when only 1% of data changed
```

Fixing Problem 1 alone would give you maybe 20–25%. Problems 2 and 3 are why you got to 70%. Here is each one explained properly.

---

### Problem 1 — View Chain Re-execution

**What a view actually is in Snowflake:**
A view is a saved SQL statement. It has zero physical storage. Every time anything references it, Snowflake executes that SQL fresh from the underlying tables. If that view itself references other views, those execute too — it compounds.

**The DAG structure that caused the problem:**
```
raw SAP table (1TB)
  └── _int view (filter + rename)
        └── _int view (currency join)
              └── _int view (material master join)
                    └── customer_enrich VIEW  ← expensive: ROW_NUMBER(), SHA2 on 100+ cols
                          └── published model A
```

Every time `published model A` ran, Snowflake did not read from a pre-built `customer_enrich` table. It re-executed the entire chain above — ROW_NUMBER(), SHA2 hash across 100+ columns, multi-table JOINs — all the way back to the raw 1TB SAP table. From scratch. Every single dbt run.

**How to say this:**
> *"The transform layer was entirely views. In Snowflake that means no physical storage — so every time a downstream model ran, Snowflake re-executed the entire upstream chain from raw source. A model like `customer_enrich` had a ROW_NUMBER window function, a SHA2 hash across 100+ columns, and JOINs across four intermediate tables — all running against 1TB of raw SAP data on every execution."*

---

### Problem 2 — Fan-out Multiplication (the hidden multiplier)

This is the part most people miss, and it's what makes 70% believable.

**What fan-out means:**
`customer_enrich` was not referenced by just one downstream model. It was referenced by **3 to 4 different published models** — the Global Inventory Report, the Customer Hierarchy model, the Product Enrichment model. In dbt, each published model is a separate query execution. Snowflake does not cache view results between model executions in the same run.

**What this means in practice:**
```
dbt run executes:
  - published_model_A  → triggers customer_enrich view → executes full 1TB chain  (run #1)
  - published_model_B  → triggers customer_enrich view → executes full 1TB chain  (run #2)
  - published_model_C  → triggers customer_enrich view → executes full 1TB chain  (run #3)

Also make sure to talk about --defer command of dbt

Same expensive SQL. Same 1TB scan. Three times. In one dbt run.
```

So the real cost wasn't "one slow query per run." It was "one slow query × number of downstream consumers per run." The fan-out is what explains why the improvement was as large as 70% and not just 20%.

**After materialising `customer_enrich` as a table:**
```
dbt run executes:
  - customer_enrich    → builds physical table once  (executes once)
  - published_model_A  → reads from pre-built table  (near-zero compute)
  - published_model_B  → reads from pre-built table  (near-zero compute)
  - published_model_C  → reads from pre-built table  (near-zero compute)
```

**How to say this:**
> *"The deeper issue was fan-out. `customer_enrich` was referenced by three or four downstream published models. Because it was a view — no physical storage — Snowflake re-executed the entire expensive chain every time each of those models ran. So in a single dbt run, that ROW_NUMBER + SHA2 + multi-table JOIN against 1TB was running three or four times, not once. Materialising it as a table eliminated all of that — one execution, and every downstream model reads from the already-built result."*

---

### Problem 3 — Full Dataset Processed on Every Daily Run

Even after solving Problems 1 and 2 (eliminate re-execution and fan-out), there was still a third inefficiency: if `customer_enrich` was materialised as a plain `table`, dbt would rebuild it **from scratch on every run** — processing the full 1TB SAP source table daily even though only a small fraction of rows actually changed.

**Why `incremental` instead of just `table`:**

| Materialization | What happens on each dbt run | Data processed |
|---|---|---|
| `view` | Re-executes full chain from raw source | 1TB every time |
| `table` | Drops and rebuilds entire table | 1TB every time |
| `incremental` | Processes only new/changed rows since last run | ~10GB (daily delta) |

The watermark filter (`_FIVETRAN_SYNCED > max already loaded`) combined with the SHA2 hash check means Snowflake only touches rows that are genuinely new or changed. For a 1TB table where the daily delta is roughly 1% of the data, that's ~10GB instead of 1TB — a 100× reduction in data processed on every daily run.

**How to say this:**
> *"Even with the fan-out problem solved, if I had used a plain `table` materialization, dbt would still rebuild the entire table from scratch every day — scanning the full 1TB every time. I used `incremental` specifically to avoid that. The incremental logic uses a watermark on `_FIVETRAN_SYNCED` and a SHA2 hash comparison so only genuinely new or changed rows are processed. Daily runs went from scanning 1TB to scanning the day's delta — roughly 10GB. That's the third layer of the improvement."*

---

### How the 70% Breaks Down

| Source of improvement | Mechanism | Approximate contribution |
|---|---|---|
| Eliminating view chain re-execution | Views → incremental tables: downstream reads from pre-built table | ~30–35% |
| Eliminating fan-out multiplication | Same expensive view was running 3–4× per dbt run; now runs once | ~20–25% |
| Incremental processing (delta only) | Daily run processes 10GB delta instead of 1TB full scan | ~15–20% |
| **Total** | | **~70%** |

> You don't have to give exact percentages. But being able to name the three sources and say "each contributed meaningfully" is what makes the number credible. "One config change = 70%" is not believable. "Three compounding inefficiencies, each addressed separately" — is.

---

### How to Open (revised)

> *"The 70% came from three separate performance problems that were all compounding each other. First: the transform layer was entirely views — no physical storage — so every downstream model was re-executing the full SQL chain from raw SAP data on every run. Second: the expensive enrichment views were referenced by multiple downstream models, so that same expensive chain was running three or four times per dbt execution, not once. Third: even if you fix the first two problems with a plain table materialization, dbt would still rebuild the full 1TB table from scratch on every daily run. I used incremental materialization specifically to address that — daily runs only process the delta, not the full dataset. The combination of all three fixes is where the 70% comes from."*

---

### The Investigation — How You Found This (say this when asked "how did you diagnose it?")

> *"I started in dbt Cloud's run history — it shows execution time per model. I could see certain models taking 25–35 minutes each while others finished in seconds. That gap told me the problem was specific models, not infrastructure. I then opened the Snowflake Query Profile for the slow models and saw two things: first, massive bytes spilled to remote storage — meaning the warehouse didn't have enough memory to run the window functions and joins without writing intermediate data to S3. Second, I looked at how many times those models appeared in the query history per dbt run and saw them executing three or four times. That's when I understood the fan-out — multiple downstream models all pulling from the same view, each triggering a separate full execution."*

---

### Key Technical Points to Cover

| # | Point | What to say |
|---|-------|-------------|
| 1 | **View = zero physical storage** | "A view is just a saved SQL statement. Every reference to it triggers a fresh execution from the underlying tables. Chain them five levels deep and a single downstream query re-runs everything from raw source." |
| 2 | **Fan-out — the hidden multiplier** | "The enrichment views were referenced by 3–4 published models. No caching between model executions in dbt. So the same expensive computation ran once per downstream consumer per dbt run — that's what made the improvement as large as 70%." |
| 3 | **Why `incremental` not just `table`** | "A plain `table` rebuilds from scratch every run — still scans 1TB daily. `incremental` uses a watermark and hash comparison so only new or changed rows are processed. Daily delta on a 1TB table is maybe 10GB. That's 100× less data on every daily run." |
| 4 | **Why some models stayed as views** | "I didn't flip everything. Lightweight `_int` models — simple filters and renames — are cheap to re-execute. Turning those into tables adds build time and storage cost with no meaningful gain. The change was targeted at the `_enrich` models: window functions, 100+ column SHA2, multi-table JOINs." |
| 5 | **How you measured it** | "dbt Cloud run history shows execution time per model per run. I compared the same set of models before and after the change. Total DAG execution time dropped 70%." |
| 6 | **The warehouse dimension** | "Fixing the materialization also changed the warehouse sizing requirement. The initial full load of `customer_enrich` needed a Large warehouse — window functions on 1TB spill to remote storage on a Medium. But daily incremental runs on 10GB of delta run comfortably on a Medium. So the architectural fix also unlocked a cheaper warehouse tier for ongoing runs." |

---

### Anticipated Follow-up Questions

**Q: What's the difference between `table`, `view`, `incremental`, and `ephemeral` in dbt?**
> - `view`: Saved SQL, no storage, re-executed on every query
> - `table`: Full rebuild on every dbt run, physically stored
> - `incremental`: Built once, subsequent runs only process new/changed data using a watermark and/or hash comparison
> - `ephemeral`: Not a database object at all — injected as a CTE into the model that references it, exists only at compile time

**Q: Does Snowflake not cache view results?**
> Snowflake has a result cache — but it only reuses a cached result if the exact same query is re-executed within 24 hours and the underlying data hasn't changed. In our case, each downstream model generated a slightly different final query (different SELECT columns, different filters) even though they shared the same upstream view. Different query text = no cache hit. So yes, each downstream model triggered a fresh execution of the expensive view.

**Q: Why didn't you just use Snowflake's materialized views?**
> Snowflake materialized views have meaningful constraints: they don't support window functions like ROW_NUMBER(), they have limited JOIN support, and they don't support non-deterministic functions. `customer_enrich` uses ROW_NUMBER() for deduplication — that alone disqualifies it from being a Snowflake materialized view. dbt incremental tables give you full SQL flexibility without those restrictions.

**Q: How did you decide which models to make incremental vs just `table`?**
> Two criteria: does the model have a natural watermark column (something like `_FIVETRAN_SYNCED` or `LOAD_DATE`) that reliably identifies new/changed rows? And does it have a stable unique key for the merge? Models that had both were strong incremental candidates. Static reference tables with no meaningful change pattern stayed as plain tables.

**Q: What is `on_schema_change='sync_all_columns'` doing?**
> By default, if a new column appears in your SELECT that doesn't exist in the target incremental table, dbt throws an error. `sync_all_columns` tells dbt to automatically add the new column to the target table's schema instead. Important here because SAP upstream schemas can add columns, and a pipeline failure over a new field is avoidable.

**Q: What is `merge_exclude_columns`?**
> For incremental merge, dbt's default updates ALL columns on a matched row. `merge_exclude_columns = ['customer_pk']` tells dbt to skip the surrogate key column during updates — you never want to overwrite a surrogate key that was assigned on initial insert, even if the row's data changes later.

**Q: What's the tradeoff of incremental models?**
> Data staleness. If a historical row had a bug and needs correction, an incremental model won't pick it up — the watermark filter will skip it because `_FIVETRAN_SYNCED` for that row is older than the last run's max. The fix is `--full-refresh`, which drops and rebuilds the entire table. We accepted this tradeoff because corrections to historical SAP data were rare and we had the three-tier validation framework to catch data issues before go-live.

---

### Pitfalls to Avoid

- **Don't say "I changed views to incremental and got 70%."** Name all three problems — view chain, fan-out, full-dataset daily rebuild. The three-problem structure is what makes 70% believable.
- **Don't skip the fan-out.** This is the part interviewers don't expect you to know, and it's the detail that separates "I know how dbt works" from "I actually diagnosed a production performance problem."
- **Don't confuse `table` and `incremental`.** If they ask "so you changed them all to tables?" — correct it: "incremental tables, not full-rebuild tables. The distinction matters — a plain table materialization would still scan 1TB on every daily run."
- **Don't say Snowflake cached the views.** It didn't, and knowing why (query text differences between downstream models) is a strong technical signal.
- **Be ready for the materialized view question.** Knowing why Snowflake's native materialized views didn't work here (no window function support) shows you evaluated the alternatives before choosing dbt incremental.

---

### Warehouse Sizing — The Missing Layer of the Story

> **Interview context:** The source table is ~1TB. The 70% runtime reduction is real — but the interviewer may push on *how* you actually ran these models at that scale without hitting timeouts. This section gives you the complete answer.

---

#### Why Warehouse Size and Materialization Are Two Separate Problems

Most people conflate them. They're not the same problem:

| Problem | Root cause | Fix |
|---|---|---|
| **Timeout / very slow run** | Query asks Snowflake to do too much work in one shot (view chain on 1TB) | Materialization change (views → incremental) |
| **Spilling to disk / OOM** | The warehouse doesn't have enough memory for the operations in flight | Warehouse sizing |

The materialization change gave the 70% reduction. The warehouse sizing is what made the initial full load *possible at all* without timing out. You need to be able to tell both halves of that story.

---

#### How Snowflake Warehouse Sizing Actually Works

Each size doubles the compute, memory, and credit consumption of the one below it:

| Size | Credits/hr | Rough memory | Use case |
|---|---|---|---|
| XS | 1 | ~4 GB per node | Dev/test, simple queries |
| S | 2 | ~16 GB | Light analytical queries |
| M | 4 | ~32 GB | Standard analytical workloads |
| L | 8 | ~64 GB | Heavy JOINs, window functions on large tables |
| XL | 16 | ~128 GB | Very large aggregations, full-refresh on TB-scale tables |
| 2XL+ | 32+ | ~256 GB+ | Extreme data volumes, rarely needed for dbt |

> Snowflake doesn't publish exact memory specs — but the doubling relationship is accurate and is what you should say in an interview.

**What happens when a warehouse is too small:**
Snowflake tries to fit the operation in memory. When it can't, it spills data — first to local SSD (slow), then to remote S3-backed storage (very slow). A query that runs in 10 minutes on an L warehouse might take 90 minutes on an M warehouse because 80% of the execution time is reading/writing spill files. That's not a linear degradation — it's catastrophic at 1TB scale.

---

#### Diagnosing the Problem: Query Profile + Spill Metrics

The way to know your warehouse is too small — before guessing — is the Snowflake Query Profile.

```
Snowflake UI → Query History → click a query → Query Profile tab
```

Look for two nodes in the profile:
- **`Bytes spilled to local storage`** → warehouse memory is full, spilling to local disk. Bad but recoverable with a size-up.
- **`Bytes spilled to remote storage`** → much worse. Spilling to S3. This is what causes timeouts and 10× slower runs. If you see this, size up immediately.

```sql
-- Also queryable via SQL (useful for monitoring in dbt post-hooks):
SELECT
    query_id,
    query_text,
    execution_time / 1000                          AS execution_seconds,
    bytes_spilled_to_local_storage  / POW(1024,3)  AS spill_local_gb,
    bytes_spilled_to_remote_storage / POW(1024,3)  AS spill_remote_gb,
    credits_used_cloud_services
FROM snowflake.account_usage.query_history
WHERE schema_name    = 'TRANSFORM'
  AND start_time     > DATEADD('day', -1, CURRENT_TIMESTAMP)
  AND bytes_spilled_to_remote_storage > 0
ORDER BY spill_remote_gb DESC;
```

If `spill_remote_gb` is non-zero, you need a larger warehouse. Period.

---

#### The Actual Recommendation for 1TB + These Models

The models in question (`customer_enrich`, `v_gir_fact_global_inventory_total_int`) have:
- `ROW_NUMBER()` window function partitioned by composite keys
- SHA2 hash across 100+ columns per row
- LEFT JOINs across valuation, currency exchange, and material master tables
- UNION ALL across EAGLE (US) and UNICORN (EU) SAP systems

Window functions and multi-table JOINs on 1TB are extremely memory-intensive because Snowflake must sort and buffer large intermediate result sets. This is the worst-case scenario for memory pressure.

**Recommendation:**

| Run type | Warehouse size | Reasoning |
|---|---|---|
| Initial full load / `--full-refresh` | **Large (L)** | 1TB source + window functions + JOINs will spill to remote on M. L gives enough memory headroom to execute without spilling. |
| Daily incremental run | **Medium (M)** | Daily delta is ~0.1–1% of 1TB = 1–10GB of new rows. M handles that comfortably. |
| Dev / testing single models | **Small (S)** | Running one model against a date-filtered dev dataset. No need for L in dev. |

> Why not XL for the full load? XL costs twice as much as L per hour. The query profile should guide you — start with L, check for remote spill, only go to XL if spilling persists. Throwing XL at everything is the lazy answer; knowing when L is sufficient is the mature answer.

---

#### How to Configure This in dbt + Snowflake

**Option 1 — Separate warehouses per job in dbt Cloud (recommended)**

```yaml
# profiles.yml (dbt Core) or dbt Cloud environment settings
prod_full_refresh:
  type: snowflake
  warehouse: TRANSFORM_WH_LARGE    # L warehouse — for --full-refresh runs
  ...

prod_incremental:
  type: snowflake
  warehouse: TRANSFORM_WH_MEDIUM   # M warehouse — for daily incremental runs
  ...
```

In dbt Cloud, you create two jobs:
- **Full refresh job** (weekly or on-demand): uses `TRANSFORM_WH_LARGE`, runs `--full-refresh`
- **Daily incremental job**: uses `TRANSFORM_WH_MEDIUM`, runs standard incremental

**Option 2 — Model-level warehouse override (Snowflake-specific)**

```sql
-- in customer_enrich.sql
{{
  config(
    materialized = 'incremental',
    unique_key   = ['customer_pk'],
    snowflake_warehouse = 'TRANSFORM_WH_LARGE'  -- override at model level
  )
}}
```

This tells dbt to switch to the L warehouse just for this model's execution, then switch back. Useful if only one or two models are truly heavy and the rest can run on M.

**Option 3 — Timeout safety net at the Snowflake level**

```sql
-- Set on the warehouse itself (prevents runaway queries)
ALTER WAREHOUSE TRANSFORM_WH_MEDIUM SET
    STATEMENT_TIMEOUT_IN_SECONDS    = 3600    -- 1 hour hard limit
    STATEMENT_QUEUED_TIMEOUT_IN_SECONDS = 600; -- fail if queued > 10 min

-- Or set at the session level via dbt profile:
# profiles.yml
session_parameters:
  STATEMENT_TIMEOUT_IN_SECONDS: 3600
```

> The default Snowflake `STATEMENT_TIMEOUT_IN_SECONDS` is 172800 (48 hours). That means a runaway query on XS will just sit there burning credits for two days. Setting a 1-hour timeout on the warehouse is a cheap safeguard — if a query genuinely needs more than an hour, it's a signal to investigate, not just wait it out.

---

#### The Full Interview Story (how to tell both halves together)

> *"The source table was about 1TB. Before the optimization, the transform layer was entirely views — so every dbt run was re-executing the full join chain from raw SAP data. On an M warehouse, that was spilling to remote storage, which I could see in the Query Profile — `bytes_spilled_to_remote_storage` was non-zero, meaning Snowflake was running out of memory mid-query and writing intermediate data to S3. That's what was causing the slow runs and eventual timeouts.*
>
> *I addressed this at two levels. At the infrastructure level: I used a Large warehouse for the initial full load and `--full-refresh` runs — L gives enough memory for window functions and multi-table JOINs on that data volume without spilling. At the architecture level: I changed the heavy transform models from views to incremental tables. After the initial load, daily incremental runs only process new or changed rows — typically 1–10GB of delta — which fits comfortably on a Medium warehouse.*
>
> *The 70% runtime reduction came from the materialization change. The warehouse sizing change made the initial load possible and eliminated the spill. The combination is what gave us a stable, cost-efficient pipeline: Large for full refreshes, Medium for daily runs, and a 1-hour timeout on both warehouses so nothing runs away unchecked."*

---

#### Key Numbers to Have Ready

| Metric | Value |
|---|---|
| Source table size | ~1TB |
| Warehouse for initial full load | Large (L) — 8 credits/hr |
| Warehouse for daily incremental | Medium (M) — 4 credits/hr |
| Runtime reduction after optimization | 70% |
| Diagnostic signal for wrong warehouse size | `bytes_spilled_to_remote_storage > 0` in Query Profile |
| Snowflake default timeout (dangerous) | 48 hours — always override this |
| Recommended timeout setting | 1 hour (`STATEMENT_TIMEOUT_IN_SECONDS = 3600`) |

---

---
