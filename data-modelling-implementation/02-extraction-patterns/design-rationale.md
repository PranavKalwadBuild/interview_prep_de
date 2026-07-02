# Design Rationale — Extraction Patterns

## 1. Full vs Incremental Extraction Trade-offs

The choice between full and incremental extraction is not a technical preference — it is a function of table size, pipeline frequency, and source system tolerance.

### Full Extraction

Read every row on every run. Truncate the staging table, reload completely.

**When it is the right choice:**
- Tables with fewer than ~500k rows where a full scan completes in seconds
- Tables with no reliable change-tracking column (`updated_at`, `created_at`, CDC)
- Initial / backfill loads regardless of table size
- Daily pipelines on tables that change infrequently (e.g., `departments` — 8 rows)
- Pipelines where correctness of every row matters more than speed (compliance reporting)

**When it breaks down:**
- Tables with tens of millions of rows — full scans lock I/O on the source DB
- Sub-hourly pipelines — re-scanning a 50M-row table every 15 minutes is unsustainable
- Source systems with read replicas but strict connection limits

**Rule of thumb:** if a full scan completes in under 60 seconds and the pipeline runs at most hourly, full extraction is fine. Beyond that, invest in incremental.

### Incremental Extraction

Read only rows changed since the last run. Requires state (the watermark) to be persisted between runs.

**Benefits:**
- Dramatically lower source I/O — only changed rows travel over the wire
- Faster pipeline runs, fresher data in the warehouse
- Less competition with OLTP workloads during business hours

**Hidden costs:**
- State management: the watermark must be stored, updated atomically, and recovered after failures
- Schema drift: if the source table adds columns, the incremental extract may miss them silently
- Deletes: rows deleted from the source are invisible to a watermark query on that same table

**The delete problem in detail:**

Suppose `emp_id = 42` is terminated and deleted from `dm_oltp.employees` on March 15. Your watermark extract runs `WHERE updated_at > @last_watermark`. Since the row is gone, it is not returned. Your warehouse still shows emp 42 as Active. The only way to detect this without CDC is a periodic reconciliation: compare the set of `emp_id` values in source vs warehouse and soft-delete orphans.

---

## 2. Watermark Pitfalls

### Pitfall 1 — UPDATE Detection Requires `updated_at`

If you filter only on `created_at`, you capture new rows but miss updates to existing rows. The `updated_at` column must be present, maintained by the application on every UPDATE, and indexed for efficient range scans.

If the ORM does not maintain `updated_at` automatically, triggers can backfill it — but that adds write overhead.

### Pitfall 2 — Clock Skew

The source database server and the pipeline runner may have clocks that differ by seconds or minutes. A row committed at `23:59:58` on the DB server might be invisible to a pipeline that starts at `00:00:00` on a server 10 seconds ahead.

**Fix:** Always subtract a safety buffer from the watermark before using it as a filter boundary.

```sql
SET @safe_watermark = TIMESTAMPADD(MINUTE, -5, @last_watermark);
SELECT * FROM employees WHERE updated_at > @safe_watermark;
```

The 5-minute buffer means you re-extract the last 5 minutes of data on every run. Deduplication in the staging layer (via `ON DUPLICATE KEY UPDATE`) handles the overlap cleanly.

### Pitfall 3 — Timezone Mismatch

Source database stores timestamps in UTC. Pipeline runner is configured to local time (e.g., US/Eastern). The watermark stored as `2024-03-15 00:00:00` means different things to each system. Rows in the 5-hour window around midnight UTC may be skipped or double-extracted.

**Fix:** Standardize everything to UTC. Store watermarks as UTC. Cast source timestamps to UTC before comparing. Document the timezone assumption in the pipeline metadata.

### Pitfall 4 — Bulk Loads Bypassing `updated_at`

Data engineering teams sometimes run raw SQL `UPDATE` statements (migrations, bulk corrections) that do not trigger ORM hooks or `ON UPDATE CURRENT_TIMESTAMP` mechanisms. The rows change, but `updated_at` does not. Your watermark extraction misses all of them.

**Fix:** Audit for bulk updates in your runbooks. After any bulk update, force a full extract of the affected table for that pipeline run.

### Pitfall 5 — Transaction Isolation

MySQL's default isolation level is `REPEATABLE READ`. A pipeline running a long `SELECT` sees a consistent snapshot from when its transaction started. Rows committed during the pipeline run are invisible until the next run. This is usually desirable — it prevents partially-committed batches from appearing in the warehouse. But it also means the watermark must be set to the snapshot start time, not `NOW()`, to avoid a gap.

---

## 3. CDC — Advantages and Complexity Cost

### What CDC Gives You

| Capability | Watermark Extract | CDC |
|---|---|---|
| Detect INSERTs | Yes (if `created_at` present) | Yes |
| Detect UPDATEs | Yes (if `updated_at` present) | Yes |
| Detect DELETEs | No | Yes |
| Capture old values | No | Yes (before-image) |
| Near-real-time | No (polling) | Yes (event-driven) |
| Source schema dependency | `updated_at` column required | None (reads binary log) |

### Real CDC (Debezium + Kafka)

Debezium connects to MySQL's binary log (`binlog`) with `binlog_format=ROW` and emits a Kafka message for every INSERT, UPDATE, and DELETE. The message contains:

- `op`: `c` (create), `u` (update), `d` (delete), `r` (snapshot/read)
- `before`: the row's values before the change (null for inserts)
- `after`: the row's values after the change (null for deletes)
- `ts_ms`: event timestamp

**Complexity cost:**
- Requires `binlog_format = ROW` on the MySQL server
- Needs a Kafka cluster, Debezium connector framework (Kafka Connect), and schema registry
- Out-of-order events are possible if Kafka partitions are misconfigured
- Schema changes (ALTER TABLE) require careful connector reconfiguration
- Operational burden: monitoring consumer lag, connector restarts, offset management

### Trigger-Based CDC (as shown in the SQL file)

A reasonable middle ground for teams that cannot access the binlog. Triggers write to a change log table; the pipeline polls the change log on a schedule.

**When trigger-based CDC is acceptable:**
- Database is on shared hosting or a managed RDS instance without binlog access
- Write throughput is below ~5k rows/second (trigger overhead is negligible below this)
- The team lacks the infrastructure to run Kafka and Debezium

**When to upgrade to real CDC:**
- Write throughput grows beyond trigger overhead tolerance
- Sub-minute data freshness is required
- You need to capture DDL changes (triggers do not capture `ALTER TABLE`)

---

## 4. Idempotency — Why Every Pipeline Step Must Be Re-runnable

### The Core Principle

A pipeline step is idempotent if running it multiple times produces the same result as running it once. This is not a nice-to-have; it is a hard requirement for production data pipelines.

**Why pipelines fail and need retries:**
- Network timeouts between pipeline runner and database
- Source database briefly unavailable (maintenance window, failover)
- Out-of-memory on the transform node
- Upstream dependency not yet complete (late data)
- Human operator reruns a failed task manually to debug

### Idempotency by Layer

**Extraction (staging layer):**
Use `TRUNCATE TABLE stg_*; INSERT INTO stg_* SELECT * FROM source`. Truncate makes the load stateless — re-running always produces a fresh, complete staging snapshot.

**Transformation (silver layer):**
If transformations are implemented as `CREATE TABLE AS SELECT` or `INSERT OVERWRITE`, they are inherently idempotent. If using `INSERT INTO`, add a deduplication step or a `NOT EXISTS` guard.

**Loading (fact / dim tables):**
- For dimensions: upsert on the natural key (`emp_id`, `dept_id`). If the row exists, update it; if not, insert it.
- For facts: check for existing `(date_key, emp_key)` pairs before inserting, or use a staging-swap pattern.

### The Staging-Swap Pattern (production-grade)

```
1. TRUNCATE stg_fact_salary_payment;
2. INSERT INTO stg_fact_salary_payment (load from source);
3. Validate: row counts, NULL checks, referential integrity;
4. BEGIN;
   DELETE FROM fact_salary_payment WHERE date_key = @target_partition;
   INSERT INTO fact_salary_payment SELECT * FROM stg_fact_salary_payment;
   COMMIT;
```

If step 3 fails, step 4 never runs — the live fact table is untouched. If step 4 fails, the transaction rolls back. Re-running from step 1 is always safe.

---

## 5. Interview Angle — Late-Arriving Data from an API Without `updated_at`

**The question:** "How would you handle late-arriving data from an API that doesn't expose an `updated_at` field?"

This is a common scenario with third-party APIs (Salesforce, HubSpot, Jira) that return resources without reliable change timestamps.

**Approach 1 — Full re-extract with hash comparison**

On every run, re-fetch all records from the API. Compute a hash of each record's content. Compare against the hash stored from the previous run. If the hash differs, the record changed.

```sql
-- Row hash computed at extraction time
ALTER TABLE stg_employees_full
    ADD COLUMN row_hash CHAR(64) GENERATED ALWAYS AS (
        SHA2(CONCAT_WS('|', emp_id, first_name, last_name, email,
                        hire_date, job_title, dept_id, employment_status), 256)
    ) STORED;
```

Load only rows where `row_hash` differs from the warehouse copy. This gives you change detection without `updated_at`, at the cost of a full extract every run.

**Approach 2 — Pagination with a created-date cursor**

If the API supports sorting by `created_at` and records are immutable once created (e.g., event logs, audit entries), paginate forward from the last known `created_at`. This works for append-only sources.

**Approach 3 — Webhook + event queue**

If the API supports webhooks, register a webhook that POSTs change events to your ingest endpoint. Events land in a queue (SQS, Kafka). The pipeline consumes events in order. This is the ELT equivalent of CDC — near-real-time, no polling.

**Approach 4 — Scheduled full reconciliation**

Run a lightweight incremental extract hourly and a full reconciliation nightly. The full reconciliation catches anything the incremental missed (late arrivals, backdated corrections). This is the pragmatic middle ground when the API is unreliable.

**What the interviewer is really asking:**

They want to see that you understand:
1. Watermark extraction assumes `updated_at` — if it is absent, the strategy breaks
2. You know multiple fallback strategies (hash comparison, full reload, event-driven)
3. You can quantify the trade-off: full reload is safe but expensive; hash comparison adds compute; webhooks are real-time but require API support
4. You ask clarifying questions: "Is this API append-only or does it support updates? What is the acceptable data freshness SLA? How many records does it return per page?"

**One-sentence interview answer:**

"Without `updated_at`, I would use a full re-extract with row-hash comparison to detect changes, run it on a schedule that matches the freshness SLA, and push for a webhook integration as a longer-term improvement — because polling a paginated API for millions of records is expensive and fragile."
