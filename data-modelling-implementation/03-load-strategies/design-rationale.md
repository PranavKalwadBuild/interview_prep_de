# Load Strategies — Design Rationale

Reference for `01-load-strategies.sql`. Each section maps to one pattern
in that file and expands on the engineering reasoning behind it.

---

## 1. When to Use Each Strategy

| Strategy | Table size | Change rate | History needed? | Idempotent? |
|---|---|---|---|---|
| Truncate-and-reload | Small (< 100K rows) | Any | No | Yes (by design) |
| Upsert (ON DUPLICATE KEY) | Any | Low–medium | No (SCD1 only) | Yes |
| Staging-table merge | Any | Medium–high | Yes (SCD2) | Yes (if guarded) |
| Append-only | Any | N/A (new rows only) | N/A | No — needs guard |
| Delete-then-insert | Any | Any | N/A (snapshots) | Yes (by design) |

Decision rule of thumb:
- **Reference / lookup dimension, small:** truncate-and-reload.
- **Large dimension, history not required:** upsert.
- **Large dimension, SCD2 history required:** staging-table merge.
- **Transaction fact, new time window:** append-only.
- **Periodic snapshot fact, re-runnable:** delete-then-insert.

---

## 2. Batch vs Micro-batch vs Streaming Load Implications

### Batch (hourly / daily / monthly)
All five strategies work well in batch mode. The full source extract is
available, the target is locked for a bounded window, and the pipeline can
be retried from scratch if it fails.

Truncate-and-reload is most natural for batch because "reload everything
from the last snapshot" is a single, cheap operation.

### Micro-batch (every 5–15 minutes)
Truncate-and-reload becomes expensive if the dimension has grown large —
you re-extract and re-insert thousands of rows every few minutes. Prefer
upsert or staging-table merge so only the delta (changed rows since the
last micro-batch) is processed.

Fact tables loaded in micro-batch must be append-only with a guard clause
(`WHERE NOT EXISTS` or a dedup key) so that overlapping micro-batch windows
do not insert duplicate rows.

### Streaming (event-by-event via Kafka / Flink / Spark Streaming)
Truncate-and-reload is entirely inappropriate — you cannot drop and reload
a 50M-row dimension every time one employee changes their name.

The standard streaming dimension pattern is upsert: incoming CDC events
(INSERT / UPDATE / DELETE) from a Debezium-style source are applied
individually using ON DUPLICATE KEY UPDATE or a keyed state store.

Fact tables in streaming pipelines are always append-only; the consumer
writes each event as a new row. Idempotency is managed via event-level
deduplication keys or exactly-once semantics at the stream processor layer
(not in the SQL itself).

---

## 3. Idempotency Requirement for Each Strategy

Idempotency means: running the same pipeline for the same time window
twice produces the same final state as running it once.

| Strategy | Idempotent out of the box? | How to enforce it |
|---|---|---|
| Truncate-and-reload | Yes | TRUNCATE clears all prior rows |
| Upsert | Yes | Duplicate key collision is a no-op if values match |
| Staging-table merge | Mostly | Guard the INSERT with `WHERE de.emp_id IS NULL`; ensure UPDATE is not additive |
| Append-only | No | Wrap with `WHERE NOT EXISTS (SELECT 1 FROM fact ... WHERE pay_year = ? AND pay_month = ? AND employee_sk = ?)` |
| Delete-then-insert | Yes | DELETE removes the prior load; INSERT rebuilds it |

Non-idempotent pipelines are dangerous in production: a retry after a
partial failure doubles rows in the fact table and inflates all aggregates.
Make every pipeline idempotent before considering it production-ready.

---

## 4. The Delete-Detection Problem

**None of the five strategies above automatically propagate hard deletes
from the source system to the warehouse.** This is one of the most common
bugs in data warehouse pipelines.

### The problem
If an employee row is physically deleted from `dm_oltp.employees`, the
corresponding `dim_employee` row in the warehouse is never touched by any
of these patterns:
- Truncate-and-reload on `dim_employee` would catch it — but you cannot
  truncate an SCD2 table because that destroys all historical versions.
- Upsert only fires on incoming rows; a missing row generates no event.
- Staging-table merge only inserts new rows and updates matched rows;
  unmatched rows in the target are ignored.
- Append-only and delete-then-insert operate on fact tables, which should
  never delete historical fact rows anyway.

### Common solutions

**Option A — Full-outer-join tombstone sweep (batch)**
After every load, join the staging extract to the target dimension on the
natural key. Rows in the target with no matching staging row are marked
`is_deleted = 1` (or `status = 'Terminated'`). Works well for batch; too
slow for micro-batch on large tables.

**Option B — Soft-delete via CDC**
Use Change Data Capture (Debezium, AWS DMS, Fivetran) to capture DELETE
events from the source binlog. The pipeline receives an explicit DELETE
record and applies a logical delete to the warehouse row. Most reliable,
but requires binlog access and a CDC infrastructure.

**Option C — Watermark + count reconciliation**
After each load, compare `COUNT(*)` in the source vs the number of
`is_current = 1` rows in the target. A discrepancy triggers an alert.
Catches deletes but does not automatically remediate them.

**Option D — Periodic full reconciliation**
Run a full-outer-join reconciliation job weekly (not every batch) to catch
any deletes that slipped through. Acceptable for slowly-changing dimensions
where a one-week lag on delete propagation is tolerable.

For this project's domain (employee dimension, 41 rows), Option A or D is
sufficient. For a 50M-row customer dimension, you would need Option B.

---

## 5. Interview Angle

### "How would you handle a dimension table with 50M rows that changes 5% daily?"

**The naive wrong answer:** truncate-and-reload.
Truncating 50M rows and re-inserting 50M rows every day costs hours of I/O
and blocks readers during the window. Non-starter.

**The correct answer (structured response):**

1. **Identify the change volume.** 5% of 50M = 2.5M rows change daily.
   That is still a large delta, but it is far smaller than a full reload.

2. **Use a staging-table merge (Section 3 pattern).**
   Extract only changed rows from the source using a high-water-mark
   (`WHERE updated_at > last_run_ts`) or CDC. Load them into a staging
   table (2.5M rows, not 50M). Run the two-step UPDATE + INSERT.

3. **Handle SCD Type 2 explicitly.** If history matters, expire the old
   row (set `expiry_date = CURDATE() - 1`, `is_current = 0`) in the UPDATE
   step, and insert the new version in the INSERT step.

4. **Handle deletes separately.** Use CDC or a nightly reconciliation job.
   Do not rely on the merge step.

5. **Add partitioning or clustering.** A 50M-row dimension with an index
   on `emp_id` and `is_current` keeps the SCD2 lookup O(log n) per row.
   If the dimension is a fact-adjacent table, consider partitioning by
   `effective_date` year to limit partition scans.

6. **Monitor with row-count checks.** After every run, assert that
   `COUNT(is_current = 1)` in the target is within 5% of `COUNT(*)` in
   the source. Fail loudly if not.

**Follow-up trap:** "Can you do this in a single SQL statement?"
Answer: Not in MySQL. MySQL lacks native MERGE. The two-step staging pattern
is the idiomatic MySQL solution. In Snowflake or BigQuery you would use
`MERGE INTO`. In dbt you would use `incremental` materialization with a
`unique_key`.
