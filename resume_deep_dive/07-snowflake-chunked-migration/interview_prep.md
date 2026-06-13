## Bullet 7 — Snowflake-to-Snowflake Chunked Migration Utility (1M+ rows)

> *"Developed a Python-based synchronization utility to automate the migration of 1M+ row tables between Snowflake accounts, ensuring data integrity through structured, chunked execution."*
>
> **Files:** `chunk_transfer.py` (v1), `chunk_transfer_v2.py`, `chunk_transfer_v3.py`, `chunk_transfer_v4.py`, `chunk_transfer_v5.py`

---

### The Problem First — Why This Tool Had to Exist

Two separate Snowflake accounts. A table with 1M+ rows that needed to move between them. There is no direct Snowflake-to-Snowflake wire transfer. The naive approach — a single `SELECT *` dump — runs into Snowflake memory limits and gives you zero visibility into progress or failure. If it fails halfway, you know nothing. You can't resume. You start over.

The answer was a chunked pipeline: break the table into deterministic, ordered slices, move each slice independently through a local Parquet hop, and load each slice into the target. If a chunk fails, you know exactly which one and can resume. Data integrity is enforced at every step.

---

### The Story Arc (STAR format)

**Situation:**
An account-to-account Snowflake migration was needed for large tables — 1M+ rows. No shared S3 bucket, no external stage linking both accounts. The only path was through a local intermediary.

**Problem:**
A single-shot export of a million-row table wasn't viable — Snowflake's query memory limits, zero progress visibility, no resume capability on failure, and no way to validate partial progress. It had to be chunked.

**Action:**
I built a Python utility using the Snowflake Snowpark SDK that automates the full pipeline: connect to both accounts simultaneously, auto-generate the target table DDL from source schema, split the source table into ordered Parquet chunks, move each chunk through a local directory hop, load it into the target via COPY INTO, and clean up all transient resources. The tool went through five iterations as real problems surfaced during development.

**Result:**
Tables with 1M+ rows migrated reliably with full progress visibility, deterministic ordering, and post-load row count validation. The tool was re-runnable — it checked for existing target tables and stages before creating them, so a failed mid-run could be restarted safely.

---

### The Evolution — The Story That Shows You Actually Built This

This is where the interview gets interesting. The five versions aren't just different files — each one was a direct response to a concrete problem discovered during testing. Say it this way:

> *"I didn't write this once and call it done. There were five iterations, and each one fixed a real problem. Let me walk you through what broke and what I changed."*

---

#### V1 → V2: The ORDER BY was Hardcoded. The Target Table Didn't Exist Automatically.

**V1 problem 1 — hardcoded key:** The first version had `ORDER BY C_CUSTKEY` hardcoded directly in the SQL. That's fine for the CUSTOMER table, but the moment you want to migrate any other table you have to go into the code and change it. Not a tool — a one-off script.

**Fix:** Added `get_order_by_key()`. It first checks if the caller passed explicit key columns. If not, it queries `INFORMATION_SCHEMA.COLUMNS` ordered by `ordinal_position` and picks the first column as the ORDER BY key. The tool now works on any table without code changes.

**V1 problem 2 — no DDL generation:** V1 assumed the target table already existed. Every migration required someone to manually create the table in the target account first — a manual step that could introduce schema drift (wrong column types, missing columns, wrong nullability).

**Fix:** Added `generate_and_create_table()`. It queries `INFORMATION_SCHEMA.COLUMNS` on the source, builds a `CREATE TABLE` DDL string dynamically — preserving VARCHAR lengths, NUMBER precision/scale, and NOT NULL constraints — and executes it on the target. The target table is always an exact replica of the source schema.

---

#### V2 → V3: `CREATE OR REPLACE TABLE` Was Dangerous. No Cleanup at the End.

**V2 problem 1 — destructive DDL:** V2 used `CREATE OR REPLACE TABLE` — meaning if you ran the tool twice (e.g., a failed run followed by a retry), it would silently drop and recreate the target table, destroying any data already loaded from the first run.

**Fix:** Changed to `CREATE TABLE` (no `OR REPLACE`) preceded by a `SHOW TABLES LIKE` check. If the table already exists, the DDL step is skipped entirely. This made the tool safe to re-run mid-migration.

**V2 problem 2 — stage and local directory not cleaned up:** After V2 finished, the target stage and the local Parquet directory were left behind. Running it twice would accumulate stale files.

**Fix:** Added explicit end-of-run cleanup: drop target stage, delete local directory, close both sessions.

---

#### V3 → V4: `print()` Everywhere. Monolithic `main()`. No Error Handling.

**V3 problem:** The entire pipeline was inside `main()` as a linear sequence of `print()` statements. There was no way to distinguish a normal log line from an error. If any step failed, Python's traceback was the only signal — no context about which stage, which chunk, what state the resources were in.

**Fix — three changes:**

1. **`print()` → Python `logging` module.** Every log line now has a level (`INFO`, `ERROR`, `EXCEPTION`) and a structured prefix (`[DDL]`, `[DOWNLOAD]`, `[UPLOAD]`, `[CLEANUP]`). You can filter by level in production. Errors are distinguishable from progress messages.

2. **Separation of concerns.** `main()` was split into four named functions: `setup_stages_and_dirs()`, `generate_and_create_table()`, `get_order_by_key()`, `process_chunks()`, `cleanup_resources()`. Each has a single responsibility. `cleanup_resources()` uses a `finally` block — sessions are always closed even if an exception is raised mid-migration.

3. **`try/except` with `logging.exception()`.** Each function wraps its logic in a try/except that logs the full exception traceback (not just the message) and re-raises. This gives you the full stack trace in the log output while still halting the pipeline cleanly.

Also in V4: added a named source stage (`CUSTOMER_src_stage`) instead of V1's `@%CUSTOMER` table stage. The table stage is Snowflake's auto-created internal stage per table — you can't drop it, you can't fully control its lifecycle, and it's shared with anything else that uses that table. A named stage is explicitly created, owned, and dropped by the tool.

---

#### V4 → V5: Sequential Chunk Processing Meant No Visibility Into What Was Staged.

**V4 design:** Every chunk was: unload to stage → download locally → upload to target → load into target → delete local file → next chunk. Linear, one at a time. If the transfer phase failed on chunk 47 of 100, you had no way to see what had already been unloaded or what was still in the source stage.

**V5 fix — two-phase architecture:**

Phase 1: `unload_all_chunks()` — unload every chunk from the source table into the source stage. All 100 chunks. Don't touch the target yet.

Phase 2: `list_stage_files()` — call `LIST @{src_stage}` and get the exact list of files that are physically in the stage. This is a checkpoint. You see exactly what was exported before a single byte is moved to the target.

Phase 3: `transfer_and_load_chunks()` — iterate through that file list, download each file, upload to target stage, COPY INTO target table, clean up local and target stage.

**Why this matters:**
- The unload phase and transfer phase are now independently verifiable. After phase 1, you can inspect the stage and confirm all chunks are there.
- The `list_stage_files()` manifest decouples the loop from the chunk index logic — you iterate over actual files, not assumed chunk numbers. If the stage has 98 files instead of 100, you know exactly which chunks are missing before you start loading anything.
- A failure in the transfer phase doesn't require re-running the unload phase — the stage still has all the files.

---

### How to Open (say this first)

> *"This was a Python utility to move large tables — a million-plus rows — between two separate Snowflake accounts. There's no direct Snowflake-to-Snowflake transfer, so the approach was a chunked pipeline: break the table into ordered Parquet slices, move each slice through a local hop, load into the target via COPY INTO. The interesting part isn't just the mechanism — it's that I built this in five iterations. Each version was a direct response to a concrete problem I hit during testing: hardcoded keys, destructive DDL on re-runs, no error structure, and eventually a full architectural split into two phases so the unload and transfer steps were independently verifiable."*

---

### Key Technical Points to Cover

| # | Point | What to say |
|---|-------|-------------|
| 1 | **Why chunk at all** | "Snowflake can hit memory limits on very large single-query exports. Chunking also gives you progress visibility — you know chunk 47 of 100 loaded correctly — and resume capability. If chunk 60 fails, you restart from 60, not from zero." |
| 2 | **Why ORDER BY is mandatory for chunking** | "LIMIT + OFFSET without ORDER BY is non-deterministic in Snowflake — the same query run twice can return different rows in different orders. That means two chunks could return overlapping rows, or some rows could be missed entirely. The ORDER BY makes the pagination deterministic. The tool auto-discovers the ORDER BY key from `INFORMATION_SCHEMA` if you don't specify one." |
| 3 | **Parquet as the intermediate format** | "Parquet preserves column type metadata through the local hop. CSV would turn every column into a string — you'd lose type fidelity on timestamps, numbers, booleans. Snowflake's Snowpark compresses the Parquet files with Snappy automatically, so the local files are compact." |
| 4 | **DDL auto-generation from INFORMATION_SCHEMA** | "Rather than requiring a pre-created target table, the tool queries `INFORMATION_SCHEMA.COLUMNS` on the source and builds the `CREATE TABLE` DDL dynamically — preserving VARCHAR lengths, NUMBER precision and scale, and NOT NULL constraints. The existence check before DDL means re-runs are safe — it won't drop and recreate a table that already has data." |
| 5 | **Table stage vs named stage** | "V1 used `@%CUSTOMER` — Snowflake's auto-created table stage. That's convenient but you can't drop it, you can't isolate its lifecycle, and it's shared with any other process using that table. Moving to a named stage (`CUSTOMER_src_stage`) means the tool owns the full lifecycle: create at start, drop at end, isolated from everything else." |
| 6 | **Two-phase architecture (V5)** | "The final version split the pipeline into unload-all-then-transfer-all instead of chunk-by-chunk. After unloading everything to the source stage, `LIST @{stage}` gives you a manifest of exactly what's there. You verify before you move anything to the target. A transfer failure doesn't require re-running the unload. And you're iterating over actual staged files, not assumed chunk numbers — so missing files are immediately visible." |
| 7 | **MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE** | "The COPY INTO uses name-based column matching, not positional. Snowflake's Parquet export and the `CREATE TABLE` DDL could theoretically have columns in different orders depending on how `INFORMATION_SCHEMA` returns them. Name matching makes column order irrelevant." |

---

### Deep Technical Layer — What's Actually Happening Under the Hood

#### `copy_into_location()` — What Snowpark Compiles This To

`df.write.copy_into_location(location=stage_path, file_format_type="parquet", header=True, overwrite=True)` is not a Python file write. Snowpark compiles this into a `COPY INTO @CUSTOMER_src_stage/chunk_0.parquet FROM (SELECT * FROM CUSTOMER ORDER BY C_CUSTKEY LIMIT 10000 OFFSET 0) FILE_FORMAT = (TYPE = PARQUET) OVERWRITE = TRUE` statement and executes it **server-side inside Snowflake**. The Parquet file is written directly from Snowflake's compute layer to the internal stage (which is Snowflake-managed blob storage — S3, Azure Blob, or GCS depending on the Snowflake deployment). No data has left Snowflake at this step. Snappy compression is applied automatically — it's the default codec for Parquet in Snowflake's COPY INTO. `overwrite=True` is essential for re-runability: if `chunk_5.parquet` already exists in the stage from an interrupted run, `OVERWRITE = TRUE` replaces it. Without this, the `copy_into_location` call would fail if the file already exists.

#### `session.file.get()` and `session.file.put()` — The Local Hop Mechanics

`src_session.file.get(f"@{src_stage}/{base_file}", local_dir)` is a wrapper around Snowflake's `GET` command. Snowflake authenticates to its own backing blob storage (S3/Azure Blob/GCS) and streams the file over HTTPS to the local directory. This is the only point where data physically leaves Snowflake.

`tgt_session.file.put(os.path.join(local_dir, base_file), f"@{tgt_stage}", auto_compress=False, overwrite=True)` — `auto_compress=False` here is not optional. The default is `True`, which tells Snowflake to gzip the file before uploading. But the Parquet file is already Snappy-compressed. If `auto_compress=True`, Snowflake produces `chunk_0.parquet.gz` on the target stage instead of `chunk_0.parquet`. The subsequent `COPY INTO` with `FILE_FORMAT = (TYPE = PARQUET)` would fail to recognize `.parquet.gz` — it expects a `.parquet` extension. The result would be zero rows loaded with no obvious error, just a silent skip. `auto_compress=False` keeps the file as-is.

#### `MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE` — Why Positional Loading Would Break

Parquet files have an embedded schema in their file footer (the Parquet metadata block). When Snowflake exports via `copy_into_location`, it writes the column names into this footer. `MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE` tells the `COPY INTO` to read each column's name from the Parquet footer and find the matching column in the target table by name, ignoring case. Without this, `COPY INTO` uses positional loading — column 1 in the file maps to column 1 in the table. The DDL generation queries `INFORMATION_SCHEMA.COLUMNS ORDER BY ordinal_position`, and the Parquet export also uses `SELECT *` (which follows the same ordinal order). In practice they should match. But `INFORMATION_SCHEMA` ordering and `SELECT *` ordering can diverge after `ALTER TABLE ADD COLUMN` operations, which append columns to the end of `INFORMATION_SCHEMA` but `SELECT *` follows the physical storage order. Name-based matching is the correct default — it's resilient to column order divergence by design.

#### OFFSET Pagination's Hidden Performance Cost

`LIMIT 10000 OFFSET 990000` does not seek directly to row 990,000. Snowflake's execution engine evaluates the full `ORDER BY C_CUSTKEY` sort on the entire table, then skips the first 990,000 rows before returning 10,000. The cost is O(total rows scanned), not O(chunk size). Chunk 0 scans 10,000 rows. Chunk 99 scans 1,000,000 rows. The 100th chunk is ~100x more expensive than the first. For a 1M-row table this is acceptable. For 50M rows with 5,000 chunks, the later chunks become extremely slow. The production-grade replacement is range-based pagination: `WHERE C_CUSTKEY >= (i * 10000) AND C_CUSTKEY < ((i+1) * 10000)` — Snowflake can use micro-partition pruning on the ORDER BY key to make every chunk O(chunk_size) regardless of position. This requires the ORDER BY key to be a numeric or monotonic type and have dense enough distribution, which is why it wasn't implemented in V1 (the `get_order_by_key()` fallback can return any column type).

#### Chunk Naming and `LIST @stage` Sort Order

Files are named `chunk_0.parquet`, `chunk_1.parquet`, ..., `chunk_99.parquet`. `LIST @{src_stage}` returns file names sorted **lexicographically**, not numerically. Lexicographic sort produces: `chunk_0`, `chunk_1`, `chunk_10`, `chunk_11`, ..., `chunk_19`, `chunk_2`, `chunk_20`, ... This does not affect correctness — `COPY INTO` appends rows regardless of chunk load order. But if you added progress tracking or chunk-level validation keyed on file iteration order, the sequence would be misleading. Zero-padded names (`chunk_0000`, `chunk_0001`) would make lexicographic and numeric order identical — a clean next iteration.

#### Why Two Simultaneous Sessions Are Required

A Snowflake `Session` object is bound to a single account endpoint at creation time — `Session.builder.configs({"ACCOUNT": "source-account", ...}).create()` hardwires the session to the source account. There is no cross-account context switch in Snowpark. The target session (`tgt_sf_session`) must be created separately, pointing at the target account endpoint. Both sessions must exist simultaneously because the pipeline interleaves operations across both accounts: unload from source stage → download locally (source session) → upload to target stage → COPY INTO target table (target session). If you tried to reuse one session, you'd have to close and re-open it between operations, losing all session-level state (USE DATABASE, USE SCHEMA, USE WAREHOUSE settings) and adding connection latency per chunk.

#### `SHOW TABLES LIKE` vs `INFORMATION_SCHEMA` for Existence Check

`SHOW TABLES LIKE 'CUSTOMER'` is a metadata operation — it queries Snowflake's metadata layer directly without going through query compilation or optimization. It returns immediately. `SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES WHERE table_name = 'CUSTOMER'` is also metadata-only but passes through Snowflake's full query pipeline — parsing, optimization, execution planning — before touching the same underlying metadata. For an existence check that runs once per migration, the difference is negligible. The reason to prefer `SHOW TABLES LIKE` is that it's the idiomatic Snowflake pattern for this check — it's what Snowflake's own documentation recommends and what most Snowflake tooling uses.

---

### Anticipated Follow-up Questions

**Q: Why not use Snowflake Data Sharing or replication instead of this approach?**
> Snowflake Data Sharing requires both accounts to be in the same Snowflake region and potentially the same cloud provider. Replication is a paid feature that replicates entire databases, not individual tables. For a specific table migration between two accounts with no shared infrastructure, a direct pipeline through the Snowpark SDK was the pragmatic solution.

**Q: How does `LIMIT + OFFSET` pagination scale for very large tables?**
> It's not perfect — Snowflake still scans from the beginning for each OFFSET, which means later chunks are slightly more expensive than earlier ones. For tables in the hundreds of millions of rows, a cursor-based approach using a range query on the ORDER BY key (e.g., `WHERE C_CUSTKEY BETWEEN X AND Y`) would be more efficient. For the 1M-row scale this was built for, OFFSET pagination was acceptable and simpler.

**Q: What happens if a chunk fails mid-transfer in V5?**
> The source stage still has all the Parquet files from the unload phase. The transfer loop iterates from the `list_stage_files()` manifest. You can re-run the transfer phase by restarting the script — the DDL existence check means the target table won't be recreated, and COPY INTO with `MATCH_BY_COLUMN_NAME` loading into an existing table will just append the remaining chunks. For a more robust resume, you'd track which files were successfully loaded and filter the manifest — that would be the next iteration.

**Q: What is the Snowflake Snowpark SDK — why use it instead of the `snowflake-connector-python`?**
> The `snowflake-connector-python` is the low-level DBAPI connector — it executes SQL strings and returns rows. Snowpark is a higher-level SDK that treats a Snowflake table as a DataFrame object and has built-in methods for file operations: `session.file.get()` to download from a stage to local, `session.file.put()` to upload from local to a stage. Using Snowpark meant not having to shell out to `snowsql` or implement HTTP-level stage file transfers manually.

**Q: Why does the ORDER BY key need to be the first column in INFORMATION_SCHEMA by default?**
> The fallback logic picks the first column by `ordinal_position` — position 1 in the table's schema. That's typically the primary key or the leading identifier column, which is usually a good sort key for deterministic pagination. It's a reasonable default, and the `order_by_keys` override exists precisely for cases where the first column is not the right sort key (e.g., if column 1 is a VARCHAR name instead of a numeric ID).

**Q: What prevented duplicate rows if the script was re-run on a table that already had data loaded?**
> In the current implementation, COPY INTO appends to the target table — there's no deduplication. The DDL existence check prevents recreating the table, but re-running a completed migration would load duplicates. For a production-grade tool, you'd add a row count comparison after load and skip re-loading chunks whose row counts already match. That's a known gap and a clear next iteration.

---

### The Iterative Development Angle — Use This When Asked "Tell Me About a Time You Improved Something"

> *"The first version worked — it moved data. But it had a hardcoded key, no DDL generation, and if you ran it twice it would destroy the target table. Each version fixed the most pressing problem at the time. By V4, I had proper logging, error handling, and separation of concerns — the code was maintainable. V5 was the real architectural insight: I realized that doing unload-then-transfer chunk-by-chunk meant I was flying blind. I didn't know what was in the stage until I tried to load it. The two-phase split — unload everything first, list the stage, then transfer — gave me a checkpoint I could inspect. That's the difference between a script that works and a tool you can trust."*

---

### Pitfalls to Avoid

- **Don't just say "I used chunking for large tables."** Every data engineer knows chunking. The story is *why* each design decision was made — deterministic ORDER BY, named stages over table stages, two-phase architecture, schema introspection for DDL. Those specifics are what separate you from someone who just wrote a loop.
- **The iterative version history is your strongest asset here.** It shows you didn't just write code — you diagnosed problems, redesigned, and improved. Walk through V1→V5 if given the time. It proves end-to-end ownership.
- **Don't skip the `CREATE OR REPLACE` → existence check story.** It's a real production safety issue (destructive DDL on retry) and the fix shows you thought about operational correctness, not just the happy path.
- **The two-phase V5 architecture is your answer to any "scalability" or "reliability" question.** Decoupled phases, stage manifest as a checkpoint, transfer can be retried without re-unloading.
- **If asked about limitations** — be honest about OFFSET pagination inefficiency at extreme scale and the no-deduplication-on-retry gap. Knowing the limits of your own tool is a sign of engineering maturity.

---

---
