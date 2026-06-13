<!-- Part of sql-patterns: SCD Type 1 — Iterations 0 through 5 (Base MERGE through Hard/Soft Deletes) -->
<!-- Source: sql_patterns.md lines 6073–6392 -->

## 13-A. SCD Type 1 — Logic with Iterations

### What it solves

SCD Type 1 = **overwrite**. When a source attribute changes, you simply update the target row in place. No history is kept — the old value is gone. Use it when the business only cares about the **current state** (e.g., current email address, current city).

### When to use SCD Type 1 vs Type 2

| | SCD 1 | SCD 2 |
|---|---|---|
| History needed? | No | Yes |
| Storage cost | Low | Higher (one row per version) |
| Query complexity | Simple | Range joins, `is_current` filters |
| Example | Customer email change | Customer tier change (Silver → Gold) |

---

### Schema used across all iterations

```sql
-- Source (staging layer — raw ingest from upstream system)
-- staging.stg_customers
-- customer_id  | name    | email              | city      | phone | updated_at
-- 1001         | Alice   | alice@example.com  | Delhi     | NULL  | 2026-05-01 10:00:00
-- 1002         | Bob     | bob@example.com    | Mumbai    | NULL  | 2026-05-01 09:00:00

-- Target (dimension table)
-- dim_customers
-- customer_id  | name  | email  | city  | phone | is_active | created_at | updated_at | deleted_at
```sql

---

### Iteration 0 — Base MERGE (Naive starting point)

The simplest possible SCD1: insert new rows, overwrite existing ones.

```sql
MERGE INTO dim_customers AS t
USING stg_customers AS s
ON t.customer_id = s.customer_id

WHEN MATCHED THEN
    UPDATE SET
        t.name       = s.name,
        t.email      = s.email,
        t.city       = s.city,
        t.updated_at = s.updated_at

WHEN NOT MATCHED THEN
    INSERT (customer_id, name, email, city, created_at, updated_at, is_active)
    VALUES (s.customer_id, s.name, s.email, s.city, CURRENT_TIMESTAMP, s.updated_at, TRUE);
```

**What this breaks under:**

- Runs this twice on the same data → every matched row gets updated, `updated_at` bumps → downstream incrementals pick up fake changes
- Source sends `NULL` for `city` and target has `'Delhi'` → `<>` returns NULL → row NOT updated → silent data quality bug
- Source sends a late record (older `updated_at`) → overwrites the newer data already in target
- Source omits a customer → target keeps stale record with no indication it was deleted

Each iteration below fixes one of these problems, building on the previous one.

---

### Iteration 1 — Idempotency (Only update when something actually changed)

**Problem:** Run the same batch twice. Every matched row fires `WHEN MATCHED` → `updated_at` gets bumped even though nothing changed → any downstream incremental model using `WHERE updated_at > last_run` picks up these ghost rows.

**Fix:** Add a change-detection condition to `WHEN MATCHED`:

```sql
MERGE INTO dim_customers AS t
USING stg_customers AS s
ON t.customer_id = s.customer_id

WHEN MATCHED AND (
    t.name  <> s.name
    OR t.email <> s.email
    OR t.city  <> s.city
) THEN
    UPDATE SET
        t.name       = s.name,
        t.email      = s.email,
        t.city       = s.city,
        t.updated_at = s.updated_at

WHEN NOT MATCHED THEN
    INSERT (customer_id, name, email, city, created_at, updated_at, is_active)
    VALUES (s.customer_id, s.name, s.email, s.city, CURRENT_TIMESTAMP, s.updated_at, TRUE);
```

**Now:** Running the same batch twice → `WHEN MATCHED` condition is FALSE → zero rows updated → `updated_at` stays clean → downstream incrementals see no phantom changes.

**But it still breaks when:** Either side has a NULL value.

- `NULL <> 'Mumbai'` → evaluates to NULL, not TRUE → the row is silently skipped → bug.

---

### Iteration 2 — NULL-Safe Comparison (IS DISTINCT FROM)

**Problem:** Source sends `city = NULL` (the customer cleared their city). Target has `city = 'Delhi'`. The condition `t.city <> s.city` evaluates to `NULL` (not `TRUE`) → `WHEN MATCHED` doesn't fire → the NULL from source never makes it to target.

**Rule:** Never use `<>` or `=` for change detection when either side can be NULL. Use `IS DISTINCT FROM`.

```sql
-- IS DISTINCT FROM truth table (vs <>):
-- NULL IS DISTINCT FROM NULL  → FALSE  (they are the same — no update needed) ✓
-- NULL IS DISTINCT FROM 'Delhi' → TRUE  (they differ — update needed)         ✓
-- 'Delhi' <> NULL             → NULL   (ambiguous — update silently skipped)  ✗
```

**Fix:** Replace every `<>` in the change-detection clause with `IS DISTINCT FROM`:

```sql
MERGE INTO dim_customers AS t
USING stg_customers AS s
ON t.customer_id = s.customer_id

WHEN MATCHED AND (
    t.name  IS DISTINCT FROM s.name
    OR t.email IS DISTINCT FROM s.email
    OR t.city  IS DISTINCT FROM s.city
) THEN
    UPDATE SET
        t.name       = s.name,
        t.email      = s.email,
        t.city       = s.city,
        t.updated_at = s.updated_at

WHEN NOT MATCHED THEN
    INSERT (customer_id, name, email, city, created_at, updated_at, is_active)
    VALUES (s.customer_id, s.name, s.email, s.city, CURRENT_TIMESTAMP, s.updated_at, TRUE);
```

> **Snowflake note:** Snowflake supports `IS DISTINCT FROM` natively. In MySQL use `<=>` (NULL-safe equals) and negate it. In BigQuery use `source IS DISTINCT FROM target`.

---

### Iteration 3 — Late Arriving Records

**Problem:** Your pipeline runs daily. Today's batch contains a record for `customer_id = 1001` with `updated_at = 2026-01-15` — but target already has `updated_at = 2026-05-01` (months newer). The naive MERGE overwrites the newer data with the stale late-arriving record.

**Why it happens:** Upstream systems can resend old data (replication replay, ETL retry, data corrections).

**Fix:** Add a timestamp guard — only overwrite the target if the source is actually newer:

```sql
MERGE INTO dim_customers AS t
USING stg_customers AS s
ON t.customer_id = s.customer_id

WHEN MATCHED
    AND s.updated_at > t.updated_at               -- ← only accept newer data
    AND (
        t.name  IS DISTINCT FROM s.name
        OR t.email IS DISTINCT FROM s.email
        OR t.city  IS DISTINCT FROM s.city
    ) THEN
    UPDATE SET
        t.name       = s.name,
        t.email      = s.email,
        t.city       = s.city,
        t.updated_at = s.updated_at

WHEN NOT MATCHED THEN
    INSERT (customer_id, name, email, city, created_at, updated_at, is_active)
    VALUES (s.customer_id, s.name, s.email, s.city, CURRENT_TIMESTAMP, s.updated_at, TRUE);
```

**Now:** Late arriving record with old `updated_at` → `s.updated_at > t.updated_at` is FALSE → row skipped → target retains the correct newer state.

**Edge case to know:** If `updated_at` is not reliable (upstream sets it to CURRENT_TIMESTAMP on every export regardless of actual change), this guard can suppress real updates. In that case, drop the timestamp guard and rely only on `IS DISTINCT FROM`.

---

### Iteration 4 — Same Batch of Data Coming Again

**Problem:** Batch job retries or is re-triggered. The exact same staging data re-arrives. Without guards:

- MATCHED rows: `IS DISTINCT FROM` detects no diff → no update (safe ✓)
- NOT MATCHED rows: Were these already inserted on first run? If yes, the join key NOW exists in target → `WHEN NOT MATCHED` won't fire again (safe ✓)

**The hidden bug:** What if the staging table is truncated and reloaded before the MERGE runs a second time? The MERGE re-runs cleanly. But what if your pipeline does something like `INSERT INTO stg_customers SELECT ...` without a prior TRUNCATE — and runs twice? Then staging has duplicate rows for the same `customer_id`.

**Fix:** Deduplicate the source inside the MERGE:

```sql
MERGE INTO dim_customers AS t
USING (
    -- Deduplicate source: take the most recent record per customer
    SELECT *
    FROM (
        SELECT *,
               ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY updated_at DESC) AS rn
        FROM stg_customers
    ) deduped
    WHERE rn = 1
) AS s
ON t.customer_id = s.customer_id

WHEN MATCHED
    AND s.updated_at > t.updated_at
    AND (
        t.name  IS DISTINCT FROM s.name
        OR t.email IS DISTINCT FROM s.email
        OR t.city  IS DISTINCT FROM s.city
    ) THEN
    UPDATE SET
        t.name       = s.name,
        t.email      = s.email,
        t.city       = s.city,
        t.updated_at = s.updated_at

WHEN NOT MATCHED THEN
    INSERT (customer_id, name, email, city, created_at, updated_at, is_active)
    VALUES (s.customer_id, s.name, s.email, s.city, CURRENT_TIMESTAMP, s.updated_at, TRUE);
```

**Now:** Duplicate source rows for same key → `ROW_NUMBER()` keeps only the newest → MERGE sees exactly one source row per key → fully idempotent.

---

### Iteration 5 — Hard Deletes vs Soft Deletes

**Problem:** A customer no longer appears in the source extract. Two possible business meanings:

1. **They were deleted** — target should reflect this
2. **Source was a partial extract** — absence doesn't mean deletion

#### Option A — Hard Delete (physically remove the row)

```sql
-- Add this clause to the MERGE (Snowflake / SQL Server syntax):
WHEN NOT MATCHED BY SOURCE THEN DELETE;
```

**Full MERGE with hard delete:**

```sql
MERGE INTO dim_customers AS t
USING (
    SELECT *, ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY updated_at DESC) AS rn
    FROM stg_customers
) AS s
ON t.customer_id = s.customer_id AND s.rn = 1

WHEN MATCHED
    AND s.updated_at > t.updated_at
    AND (
        t.name  IS DISTINCT FROM s.name
        OR t.email IS DISTINCT FROM s.email
        OR t.city  IS DISTINCT FROM s.city
    ) THEN
    UPDATE SET t.name = s.name, t.email = s.email, t.city = s.city, t.updated_at = s.updated_at

WHEN NOT MATCHED BY TARGET THEN
    INSERT (customer_id, name, email, city, created_at, updated_at, is_active)
    VALUES (s.customer_id, s.name, s.email, s.city, CURRENT_TIMESTAMP, s.updated_at, TRUE)

WHEN NOT MATCHED BY SOURCE THEN DELETE;   -- ← hard delete
```

**Risk:** Source is a partial daily delta (not a full snapshot) → customers absent from today's file get permanently deleted. Only use hard delete when source sends a **complete snapshot** every run.

#### Option B — Soft Delete (mark as inactive, keep the row)

```sql
-- Replace WHEN NOT MATCHED BY SOURCE → DELETE with:
WHEN NOT MATCHED BY SOURCE THEN
    UPDATE SET
        t.is_active  = FALSE,
        t.deleted_at = CURRENT_TIMESTAMP;
```

**Full MERGE with soft delete:**

```sql
MERGE INTO dim_customers AS t
USING (
    SELECT *, ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY updated_at DESC) AS rn
    FROM stg_customers
) AS s
ON t.customer_id = s.customer_id AND s.rn = 1

WHEN MATCHED
    AND s.updated_at > t.updated_at
    AND (
        t.name  IS DISTINCT FROM s.name
        OR t.email IS DISTINCT FROM s.email
        OR t.city  IS DISTINCT FROM s.city
    ) THEN
    UPDATE SET
        t.name       = s.name,
        t.email      = s.email,
        t.city       = s.city,
        t.updated_at = s.updated_at,
        t.is_active  = TRUE,        -- ← reactivate in case it was previously deleted
        t.deleted_at = NULL

WHEN NOT MATCHED BY TARGET THEN
    INSERT (customer_id, name, email, city, created_at, updated_at, is_active, deleted_at)
    VALUES (s.customer_id, s.name, s.email, s.city, CURRENT_TIMESTAMP, s.updated_at, TRUE, NULL)

WHEN NOT MATCHED BY SOURCE THEN
    UPDATE SET
        t.is_active  = FALSE,       -- ← soft delete: mark, don't remove
        t.deleted_at = CURRENT_TIMESTAMP;
```

**Downstream query impact of soft deletes:**

```sql
-- All consumers must always filter on is_active:
SELECT * FROM dim_customers WHERE is_active = TRUE;
```sql

---

