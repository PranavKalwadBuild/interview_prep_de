## Bullet 2 — CI/CD with dbt Cloud Slim CI

> *"Optimized the data delivery lifecycle by implementing a CI/CD process in dbt Cloud, leveraging Slim CI to automate testing and validation on PRs."*
>
> **Files:** `macros/get_custom_schema.sql`, `macros/drop_pr_schema.sql`, `dbt_project.yml`

---

### The Story Arc (STAR format)

**Situation:**
The Data Mesh project had four environments: feature branch (local dev) → dev → QA → prod. Before CI/CD was in place, developers would merge code without any automated validation. A broken model could make it to QA or prod before anyone noticed. There was no gate.

**Problem:**
Manual PR reviews catch logic issues, but they can't catch runtime failures — a model that compiles fine but fails when Snowflake actually executes it. We needed automated execution on every PR, isolated from every other developer's work, with the ability to block merges when something breaks. The challenge was doing this efficiently — running all 600+ models on every PR would be expensive and slow.

**Action — the three things you actually built:**

1. **Slim CI job in dbt Cloud** — configured a CI job that triggers automatically via GitHub webhook whenever a PR is opened or a new commit is pushed to a feature branch. The job uses `--select state:modified+` which compares the current code's `manifest.json` against the production environment's manifest and only builds models that changed plus their downstream dependents. A 2-model change in a 600-model project might run 15-20 models instead of all 600.

2. **PR schema isolation** — dbt Cloud automatically creates a temporary schema named `dbt_cloud_pr_<job_id>_<pr_number>` for each CI run. This schema is completely isolated — two developers can have PRs open simultaneously and their CI runs don't interfere with each other. After the run completes, a cleanup job invokes the `drop_pr_schema()` macro which drops the schema. Crucially, that macro has a safety guard: it raises a compiler error if the schema name doesn't start with `dbt_cloud_pr` — so it's impossible to accidentally drop a dev, QA, or prod schema.

3. **`generate_schema_name` macro override** — The macro lives in `get_custom_schema.sql` and overrides dbt's built-in `generate_schema_name`. It takes two arguments: `custom_schema_name` (the value of `+schema:` in the model's config — e.g., `PUBLISHED` or `TRANSFORM`) and `node` (the model being built). The logic has four branches keyed on `target.name`:

   - **`deploy`, `dev`, `qa`, `prd`**: if the model has a `custom_schema_name` set, use that exact value (`PUBLISHED`, `TRANSFORM`, etc.). If none is set, fall back to `target.schema`. This is what makes named schemas work cleanly in real environments — no username prefix, no concatenation.
   - **Any other target name (PR/CI runs)**: regardless of whether a `custom_schema_name` is set, always return `target.schema`. This means every model — whether it normally lives in `PUBLISHED` or `TRANSFORM` — lands in the single `dbt_cloud_pr_<job_id>_<pr_number>` schema during CI. One schema to isolate, one schema to drop after.

   The critical difference from dbt's default: dbt's built-in `generate_schema_name` concatenates `target.schema + '_' + custom_schema_name` when a custom schema is provided, producing something like `dbt_cloud_pr_123_456_PUBLISHED`. This override eliminates that concatenation for non-named targets, keeping CI schemas clean and predictable.

**Result:**
Merges to dev, QA, and prod are blocked if the CI run fails. The entire pipeline from feature branch to prod has an automated gate. Slim CI keeps the CI run time proportional to the change size — small PRs are fast, and the team isn't waiting on full project rebuilds for every minor fix.

---

### How to Open (say this first)

> *"Before this was set up, there was no automated gate on merges — a model that broke at runtime could make it all the way to prod before anyone noticed. I set up Slim CI in dbt Cloud, which triggers on every PR, runs only the models that changed plus their downstream dependencies — not the full project — and blocks the merge if anything fails. I also built the schema isolation and cleanup pieces so CI runs are fully sandboxed and don't leave orphaned objects behind."*

---

### Key Technical Points to Cover

| # | Point | What to say |
|---|-------|-------------|
| 1 | **What Slim CI actually is** | "Slim CI is dbt's state-aware CI mechanism. Instead of running every model on every PR, it compares your current code's `manifest.json` against the production environment's manifest and selects only what changed. The flag is `--select state:modified+` — the `+` means modified models plus everything downstream of them in the DAG, so you catch cascading failures too." |
| 2 | **What `manifest.json` is and why it matters** | "Every dbt run produces a `manifest.json` — it's a complete snapshot of every model, its compiled SQL, its dependencies, its config. Slim CI diffs your PR's manifest against the production manifest to know exactly what changed. If you don't have a prior production run with a manifest, Slim CI has nothing to compare against — the first run is always a full run." |
| 3 | **The `dbt_cloud_pr_` schema** | "dbt Cloud creates a temporary schema per PR called `dbt_cloud_pr_<job_id>_<pr_number>`. Every object built during CI lands in that schema. Multiple PRs run concurrently, each isolated in their own schema. After the run, a cleanup step calls `drop_pr_schema()` which drops it — but only after checking that the schema name actually starts with `dbt_cloud_pr` to prevent accidental drops." |
| 4 | **The `generate_schema_name` override** | "The macro in `get_custom_schema.sql` branches on `target.name`. For `deploy`, `dev`, `qa`, and `prd` targets: if a model has `+schema: PUBLISHED` in its config, the macro returns `PUBLISHED` exactly — no prefix, no concatenation. If no custom schema is set, it falls back to `target.schema`. For any other target name — which is what a PR/CI run gets — it always returns `target.schema` regardless of what `+schema:` is set to. That means every model, whether it normally lives in `PUBLISHED` or `TRANSFORM`, lands in the single `dbt_cloud_pr_<job_id>_<pr_number>` schema during CI. dbt's default behavior would concatenate those, producing `dbt_cloud_pr_123_456_PUBLISHED` — which is messy and requires extra permissions to manage." |
| 5 | **Branch protection** | "The CI job reports its pass/fail status back to GitHub via webhook. Branch protection rules on the dev, QA, and prod branches require that status check to pass before a merge is allowed. So if a model fails during CI, the PR literally cannot be merged until it's fixed." |
| 6 | **The 4-environment pipeline** | "The flow was feature branch → dev → QA → prod. CI runs on every PR at every promotion step. dbt Cloud's built-in scheduler handled the prod deployment runs — simple daily schedules, no need for Airflow for this use case since there were no complex dependencies across pipelines." |
| 7 | **Deferral to production** | "The `--defer` flag is what makes Slim CI work cleanly. If your modified model references an upstream model you didn't change, dbt doesn't build that upstream model in the CI schema — it defers to the production version of it. So the CI run builds only what changed, but still tests it against real production-scale data." |

---

### Anticipated Follow-up Questions

**Q: What is `state:modified` vs `state:modified+`? Why use `+`?**
> `state:modified` selects only the models whose SQL or config actually changed. `state:modified+` adds all models that are downstream of those changes — meaning any model that references a changed model is also included. The `+` is critical because a change upstream could break downstream models even if those downstream models didn't change themselves. You want to catch that in CI, not in prod.

**Q: What is `--defer` and why is it paired with Slim CI?**
> Without `--defer`, if you run only `state:modified` models, any `{{ ref() }}` calls to upstream unmodified models would fail because those models don't exist in the CI schema. `--defer` tells dbt: "for any model I'm NOT building, resolve its `{{ ref() }}` to wherever it exists in the production environment." So your modified model gets built fresh, but all its upstream dependencies are satisfied by the already-existing production objects.

**Q: What happens on the very first CI run when there's no prior manifest?**
> The first CI run has nothing to compare against — there's no production manifest yet. dbt will fall back to running all selected models. Once the first production run completes and generates a manifest, subsequent CI runs can use state comparison. This is a known bootstrapping requirement.

**Q: Why didn't you use Airflow for scheduling instead of dbt Cloud?**
> For this project the scheduling requirement was simple — daily runs at set times, no cross-pipeline dependencies, no complex DAG orchestration. dbt Cloud's built-in scheduler handled that perfectly without adding operational overhead of managing Airflow. Airflow makes sense when you have external dependencies — like "run dbt only after the Fivetran sync completes" — but we didn't have that complexity here.

**Q: What does `on_schema_change` have to do with CI?**
> If a column is added to a model in a PR, and the CI run tries to do an incremental merge into the existing CI schema table, it would fail by default because the target table's schema doesn't have that new column. `on_schema_change='sync_all_columns'` in the model config tells dbt to automatically add the new column during the merge rather than error out. This is important for CI stability.

**Q: What's the safety guard in `drop_pr_schema()`?**
> The macro lowercases `target.schema`, then checks if it starts with `dbt_cloud_pr`. If it doesn't, it calls `exceptions.raise_compiler_error()` with a message telling you that you might be dropping a non-PR schema — this stops execution immediately. If the check passes, it builds the fully qualified `database.schema` string and runs `DROP SCHEMA IF EXISTS` via `run_query()`. The whole thing is wrapped in `{% if execute %}` so it doesn't fire during dbt's parse/compile phase. The guard is what makes the cleanup job safe to automate — you cannot accidentally target a dev or prod schema.

**Q: If all CI models land in a single `dbt_cloud_pr_*` schema, how does `generate_schema_name` know a run is a PR run vs a named environment run?**
> It keys on `target.name`. In dbt Cloud, each job is configured with an environment that has a named target — `dev`, `qa`, `prd`, or `deploy`. A CI/PR job doesn't match any of those names, so it falls into the else branch and returns `target.schema` unconditionally. That's the signal — not a flag, not a special variable, just the absence of a recognized target name. So adding a new environment to the project is as simple as adding its `target.name` to the elif chain in the macro.

---

### Points You Had Right That Are Worth Emphasizing

- **`state:modified`** — you knew this. The additional layer is explaining that the manifest comparison is what makes it work, and `--defer` is what makes upstream refs resolve correctly.
- **Schema isolation per PR** — you knew this. Add the detail that multiple PRs can run *concurrently* in separate schemas — that's the real value of isolation, not just cleanliness.
- **Schema dropped immediately** — correct, and the `drop_pr_schema` macro with its safety guard is a concrete piece of code you can point to.
- **`generate_schema_name` macro (in `get_custom_schema.sql`)** — you knew this was relevant. The key points to add: (1) it branches on `target.name`, not on some CI flag; (2) for named targets (`deploy`/`dev`/`qa`/`prd`) it returns `custom_schema_name` directly, giving you clean schema names like `PUBLISHED` with no prefix; (3) for PR/CI runs it always returns `target.schema` regardless of the model's `+schema:` config, collapsing all models into one schema for clean isolation and easy cleanup.
- **Feature → dev → QA → prod** — correct pipeline. Mention branch protection rules block each merge.

### One Point You Missed (from research)

**The manifest overwrite problem** — This is a non-obvious gotcha that experienced interviewers may ask about. dbt overwrites `target/manifest.json` during *parsing*, before the run completes. If you point `--state` and `--target-path` to the same directory, the state comparison uses the freshly overwritten manifest (current run) instead of the previous run's manifest — and nothing looks modified. The fix is to keep the reference manifest in a separate folder (e.g. `state/manifest.json`) and only copy the production manifest there, never the current run's output. In dbt Cloud this is handled automatically — it fetches the production manifest from cloud artifact storage and uses a separate path.

---

### Pitfalls to Avoid

- **Don't say "I just enabled Slim CI in dbt Cloud."** That's a checkbox. The story is about the three things you built: the CI job config, the schema isolation + cleanup macro with the safety guard, and the `generate_schema_name` override that makes schemas resolve correctly.
- **Don't skip `--defer`.** Interviewers who know dbt will immediately ask "how did upstream refs work if you only built modified models?" Have the defer answer ready.
- **Don't say "it runs only changed models"** without explaining *how* it knows what changed — the manifest diff. That's the mechanism.
- **If asked about branch protection** — be clear that the rule is configured in GitHub/GitLab, not in dbt Cloud. dbt Cloud reports status back to GitHub; GitHub enforces the block.

---

---
