## Bullet 11 — Agentic AI for MS SQL → Snowflake SP Translation (40% Debugging Reduction)

> *"Engineered Agentic AI with phData toolkit for MS SQL to Snowflake translation, reducing manual debugging by 40% for thousands of Stored Procedures."*
>
> **Files:** `deploy_SP_V2.py`, `deploy_SP_V3.py`, `replace_strings_in_repo.py`
> **Presentation:** *Experimenting AI for Translations using phData Toolkit* (internal phData knowledge share)

---

### The First Thing to Understand About This Bullet

This is **not** "we used ChatGPT to translate SQL." That would be table stakes and worth nothing to an interviewer. The real story is a **systematic agentic feedback loop combined with Python deployment infrastructure** — and the insight that to fix thousands of SPs at scale, you need automation at the *execution*, *failure capture*, and *retry* layers, not just at the translation layer. The AI only becomes useful when you build the scaffolding around it.

---

### The Story Arc (STAR format)

**Situation:**
The client needed to migrate a large MSSQL database to Snowflake. The phData SQL Translation Toolkit does an AI-assisted first-pass translation of MSSQL stored procedures into Snowflake-compatible SQL. The output is hundreds of `.sql` files — tables, views, functions, and stored procedures — ready to be deployed to Snowflake. But a first-pass translation is never perfect.

**Problem:**
A significant portion of the translated stored procedures failed at runtime on Snowflake. T-SQL and Snowflake SQL differ in ways an LLM's initial pass misses: system variables (`@@ROWCOUNT` doesn't exist in Snowflake), procedural constructs, cursor behavior, and temp table handling are all different. With thousands of SPs, manually reading each error and fixing the SQL by hand was completely infeasible. You needed a way to: (1) know exactly which SPs failed and why, (2) feed that error context back into an AI to get a corrected version, and (3) retry at scale — not one SP at a time.

**Action — three layers of engineering:**

**Layer 1: Deployment + structured logging infrastructure (`deploy_SP_V2.py` → `deploy_SP_V3.py`)**

`deploy_SP_V2.py` was the first working version: connect to Snowflake, iterate over all `.sql` files in a directory, execute each one, and log every result — success or failure with the full error message — to a centralized `logs.sp_execution_log` table. Every execution gets a UUID `execution_id` so you can trace a full run. This logging was not cosmetic — it's what made everything else possible.

`deploy_SP_V3.py` added three critical improvements learned from the first run:
- **Dependency-ordered execution**: Database objects have hard dependencies — a stored procedure can't be created before the tables it references, and a view can't reference a function that doesn't exist yet. V2 ran SPs in arbitrary order and failed on dependency errors that weren't real bugs. V3 enforces the execution order: `Tables → Scalar_valued_Functions → Table_valued_Functions → Views → Stored_Procedures`. Each is a subfolder; V3 walks them in that fixed sequence.
- **Retry mechanism**: `retry_failed_executions()` queries the log table for all `FAILED` entries, pulls the `file_path`, and re-executes those specific files. After a round of AI-assisted fixes, you don't rerun everything — you rerun only what failed. This keeps iteration cycles fast.
- **Generalized from SP-only to all DB objects**: V2 was named `SPExecutor` and handled only stored procedures. V3 renamed the class to `DBObjectExecutor` because the scope expanded — tables, functions, and views all needed the same deploy-log-retry workflow.

**Layer 2: Bulk pattern replacement (`replace_strings_in_repo.py`)**

Through the error logs, patterns emerged — the same failure appearing across dozens of SPs. `@@ROWCOUNT` (a T-SQL system variable) was the clearest example: it doesn't exist in Snowflake, but the phData toolkit missed it consistently. Fixing it one SP at a time wastes time. `replace_strings_in_repo.py` walks the entire translated SQL repo, matches any `.sql` file, and applies a configurable replacement dictionary — `{"@@ROWCOUNT": "SQLROWCOUNT"}` — across all files in one pass. The `pull_latest()` call at the top ensures you're always working on the current version of the translated repo before applying fixes.

This was the key insight: **if an error appears more than ~5 times, it's a systematic translation gap, not an individual SP bug. Systematic gaps get systematic fixes.**

**Layer 3: The agentic iteration loop (Cursor IDE + multiple LLMs)**

The team experimented with ChatGPT GPT-4o, Gemini 2.5 Pro, Claude Sonnet 4, and Cursor IDE auto mode. The workflow for each failed SP:
1. Take the original MSSQL SP (pre-translation) and the error message from the log table
2. Feed both into the LLM with a prompt asking for Snowflake-compatible SQL
3. Replace the translated file with the AI's revised version
4. Run `retry_failed_executions()` — which re-executes only the revised SPs
5. If it fails again: capture the new error, feed it back to the LLM, repeat

This loop continued until the SP compiled and executed successfully on Snowflake.

**Key finding from the LLM comparison** (from the internal presentation): Token limits are the core constraint. Large SPs hit context window limits and LLM output quality degrades — hallucinations appear, code gets truncated mid-procedure, or the LLM starts changing logic it shouldn't touch. GitHub Copilot was disqualified because it abruptly ended stored procedures mid-way, which is functionally wrong code. Claude Sonnet 4 and Gemini 2.5 Pro handled the largest SPs best due to their larger context windows.

**Result:**
40% reduction in manual debugging for the SP migration. The SPs that required human attention dropped significantly because the agentic loop handled a large portion automatically. The ones that remained required genuine human judgment — either because the MSSQL logic had no clean Snowflake equivalent, or because the SP was too large for any LLM to handle correctly in one pass.

---

### How to Open (say this first)

> *"The phData toolkit gives you a first-pass AI translation of MS SQL stored procedures to Snowflake — but many fail at runtime. The challenge is fixing thousands of failures without manually debugging each one. I built the deployment and retry infrastructure around the AI: a Python executor that deploys all translated objects in dependency order, logs every failure with the error message to a Snowflake table, and retries only the fixed files. The AI loop feeds each failed SP plus its error back into an LLM, gets a revision, and the retry infrastructure validates it. For errors appearing across dozens of SPs — like `@@ROWCOUNT` not existing in Snowflake — I built a bulk string replacement utility to fix the pattern across the entire repo in one pass."*

---

### Key Technical Points to Cover

| # | Point | What to say |
|---|-------|-------------|
| 1 | **Why logging to Snowflake, not just printing to console** | "Console output disappears after the run. A Snowflake log table persists — you can query it: `WHERE status = 'FAILED'` to see what broke, `GROUP BY error_message` to find patterns, join it to the retry run to see what got fixed. The log table is what makes the retry mechanism possible and what surfaces systematic gaps like `@@ROWCOUNT`." |
| 2 | **Why dependency ordering matters** | "Snowflake CREATE statements fail immediately if they reference objects that don't exist yet. A stored procedure calling a function that hasn't been created yet is a dependency error — not a translation bug. V2 ran in arbitrary order and produced fake failures. V3 fixes this with a hardcoded execution sequence: Tables → Scalar Functions → Table Functions → Views → Stored Procedures. That order reflects the actual dependency graph of database objects." |
| 3 | **Why V2 → V3 was a real architectural change, not cosmetic** | "V2 treated the problem as SP-only. After the first run, it was clear that tables, views, and functions also failed translation — and they all needed the same deploy-log-retry loop. V3 generalized the class from `SPExecutor` to `DBObjectExecutor`, added the subfolder walk, and added retry. The retry method specifically queries `WHERE status = 'FAILED'` — so after AI fixes a set of SPs, you run retry instead of rerunning everything from scratch." |
| 4 | **The `replace_strings_in_repo.py` insight** | "`@@ROWCOUNT` appeared in maybe 50–60 SPs. Fixing it 50 times is 50 wasted AI calls and 50 manual copy-pastes. The right move is: when you see a pattern, fix it at the repo level. `replace_strings_in_repo.py` does a git pull first, then walks all `.sql` files and applies a replacement dict. Adding a new systematic fix is one line in the `REPLACEMENTS` dict. It's the difference between local fixes and systematic fixes." |
| 5 | **The LLM comparison findings** | "We ran the same failed SPs through ChatGPT GPT-4o, Gemini 2.5 Pro, Claude Sonnet 4, and Cursor IDE auto mode. The key differentiator wasn't prompt quality — it was token capacity. The largest SPs are 500–1000 lines. LLMs with smaller context windows either truncate the output or start hallucinating near the token limit. GitHub Copilot was eliminated early because it literally stopped generating mid-procedure — producing syntactically incomplete SQL. Claude and Gemini handled large SPs most reliably." |
| 6 | **The `MULTI_STATEMENT_COUNT: 0` session parameter** | "Snowflake by default only allows one SQL statement per execute call. A stored procedure `.sql` file might have a `CREATE OR REPLACE PROCEDURE` block that internally contains multiple statements. Setting `MULTI_STATEMENT_COUNT: 0` disables the limit and allows the entire file to execute as a single batch — without it, multi-statement SPs would fail with a 'multiple statements not allowed' error." |
| 7 | **What '40% reduction in manual debugging' actually means** | "Manual debugging means: human reads error, understands the T-SQL construct, figures out the Snowflake equivalent, rewrites the SP, re-deploys. The agentic loop replaced that for 40% of the failures — the ones where the error was clear enough for the LLM to correct without human interpretation. The remaining 60% had errors requiring judgment: business logic that had no direct Snowflake analog, or SPs too large for any LLM to handle without hallucinating." |

---

### Anticipated Follow-up Questions

**Q: What is the phData SQL Translation Toolkit?**
> It's an internal tool at phData that uses AI to convert T-SQL (MS SQL Server's dialect) into Snowflake-compatible SQL. You give it a set of MSSQL database object scripts and it produces translated Snowflake versions. It's a first-pass tool — accurate for standard SQL constructs, but it misses MSSQL-specific system variables, procedural patterns, and dialect quirks. Our job was to handle the SPs it couldn't translate cleanly.

**Q: Why not just re-run the phData toolkit on the failed SPs?**
> The toolkit does a static translation — it doesn't know that the translated SP failed at runtime or what the error was. The agentic loop adds the missing piece: runtime feedback. You feed the error message back to an LLM so it understands *why* the translation failed, not just what the SP looks like syntactically. That feedback loop is what the toolkit doesn't have natively.

**Q: How did you avoid the LLM changing business logic it shouldn't touch?**
> This was a real risk. The prompt was explicit: fix only the syntax and dialect differences causing the error, don't restructure the procedure's logic. We also validated outputs by comparing the structure of the revised SP against the original — if the LLM removed a JOIN or changed a calculation, that was flagged for human review. Cursor IDE's auto mode was good at this because it shows diffs, making it easy to spot unintended changes.

**Q: What's `num_statements=0` in `cur.execute(sql, num_statements=0)`?**
> It's the Snowflake Python connector's way of telling Snowflake to run the file as a multi-statement batch. The session parameter `MULTI_STATEMENT_COUNT: 0` at connection time disables the global limit, and `num_statements=0` on the execute call tells the connector not to split the SQL at semicolons. Without both, Snowflake would try to run only the first statement and ignore the rest, or throw an error on seeing multiple statements.

**Q: What happens if the same SP fails after 5 retry cycles?**
> It stays in the log table with `status = 'FAILED'` and accumulates error history from each retry. In practice, if 2–3 iterations of AI feedback didn't fix a SP, it meant either: (a) the SP was too large for the LLM's context window, causing hallucination, or (b) the logic had no Snowflake equivalent and needed a human rewrite. The log table made it easy to identify these chronic failures — they had the highest retry count — and prioritize them for manual review.

**Q: Why did you use `uuid.uuid4()` for `execution_id`?**
> The log table accumulates entries across multiple runs — retry runs, full runs, partial runs. Without an `execution_id`, you can't tell which entries came from a specific run. With a UUID per run, you can query `WHERE execution_id = '<uuid>'` to see exactly what happened in one specific execution. It also lets you compare: run A had 200 failures, run B (after AI fixes) had 120 failures — so the loop fixed 80 SPs in that cycle.

---

### Pitfalls to Avoid

- **Don't lead with "we used AI."** That sounds like you prompted ChatGPT manually and copy-pasted. Lead with the *infrastructure* — deployment automation, structured logging, retry mechanism — and position the AI as what operates *within* that infrastructure.
- **Don't skip the V2 → V3 evolution.** The jump from a flat SP executor to a dependency-ordered, retry-capable, multi-object executor is where the real engineering thinking shows. It's the difference between "I ran a script" and "I iterated on a system."
- **The `replace_strings_in_repo.py` is underrated — don't skip it.** It demonstrates a systematic mindset: when you see a recurring failure pattern, you don't fix instances, you fix the pattern. That's a senior engineering instinct on a junior timeline.
- **The LLM comparison is a credibility booster.** You didn't just pick one LLM arbitrarily — you ran experiments, compared outputs, and identified the failure mode (token limits → hallucinations → truncated SPs). That's a rigorous approach most people skip.
- **Be ready to explain the 40% number.** If you say "reduced manual debugging by 40%" and an interviewer asks how you measured that, the answer is: the log table. Before the agentic loop, X SPs had `status = 'FAILED'`. After a complete loop cycle, Y SPs were `status = 'SUCCESS'`. `(X - Y) / X` is the percentage of failures the loop resolved without human intervention.

---

---
