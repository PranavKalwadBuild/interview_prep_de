<!-- Part of sql-patterns: SCD Type 2 — Iterations 4–7, Final Production SCD2, Audit Log Reconstruction -->
<!-- Source: sql_patterns.md lines 7038–7361 -->

### Iteration 4 — Same Batch of Data Coming Again

**Problem:** Pipeline retried. Staging is reloaded with the same data. Or `stg_customers` is populated with `INSERT INTO ... SELECT` without a prior TRUNCATE, producing duplicate rows per `customer_id`.

**Fix:** Deduplicate the source in a CTE, then use it in both phases:

```sql
-- Deduplicated source CTE — use this in both phases
WITH src AS (
    SELECT *
    FROM (
        SELECT *,
               ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY updated_at DESC) AS rn
        FROM stg_customers
    ) deduped
    WHERE rn = 1
)

-- PHASE 1: Expire changed rows (source is deduped)
UPDATE dim_customers
SET valid_to = CURRENT_TIMESTAMP, is_current = FALSE
WHERE is_current = TRUE
  AND customer_id IN (
      SELECT s.customer_id
      FROM src s
      JOIN dim_customers d ON s.customer_id = d.customer_id AND d.is_current = TRUE
      WHERE s.updated_at > d.valid_from
        AND (
          s.name  IS DISTINCT FROM d.name
          OR s.email IS DISTINCT FROM d.email
          OR s.city  IS DISTINCT FROM d.city
        )
  );

-- PHASE 2: Insert new versions
INSERT INTO dim_customers
    (customer_id, name, email, city, phone, valid_from, valid_to, is_current, created_at)

SELECT s.customer_id, s.name, s.email, s.city, s.phone,
       s.updated_at, NULL, TRUE, CURRENT_TIMESTAMP
FROM src s
WHERE NOT EXISTS (
    SELECT 1 FROM dim_customers d
    WHERE d.customer_id = s.customer_id
      AND d.is_current  = TRUE
      AND d.name  IS NOT DISTINCT FROM s.name
      AND d.email IS NOT DISTINCT FROM s.email
      AND d.city  IS NOT DISTINCT FROM s.city
);
-- Note: this single INSERT covers both brand new customers AND changed customers.
-- Brand new: NOT EXISTS returns TRUE (no active row at all) → insert fires.
-- Changed: NOT EXISTS returns TRUE (active row was just expired) → insert fires.
-- Unchanged: NOT EXISTS returns FALSE (active row matches source) → insert skipped.
-- Same batch re-run: NOT EXISTS returns FALSE (new active row already inserted) → insert skipped.
```

**Now:** Re-running on the same batch is fully safe.

---

### Iteration 5 — Hard Deletes vs Soft Deletes

When a customer disappears from the source extract, two options:

#### Option A — Hard Delete (close the current row, leave history intact)

```sql
-- Expire rows for customers absent from this batch
UPDATE dim_customers
SET valid_to   = CURRENT_TIMESTAMP,
    is_current = FALSE
WHERE is_current = TRUE
  AND customer_id NOT IN (SELECT customer_id FROM src);
```

This preserves all historical rows but closes the active one. The customer still exists in dim_customers for historical fact joins — they just have no `is_current = TRUE` row.

**Risk:** Only valid when source is a **complete snapshot**. If source is a daily delta, absent customers are simply not in today's file — hard deleting them corrupts the dimension.

#### Option B — Soft Delete (insert a new version with a deleted flag)

```sql
-- Add is_deleted column to dim_customers

-- Phase 1: Expire current row for deleted customers
UPDATE dim_customers
SET valid_to = CURRENT_TIMESTAMP, is_current = FALSE
WHERE is_current = TRUE
  AND customer_id NOT IN (SELECT customer_id FROM src);

-- Phase 2-C: Insert a "deleted" version as the new current row
INSERT INTO dim_customers
    (customer_id, name, email, city, phone, valid_from, valid_to, is_current, is_deleted, created_at)
SELECT
    d.customer_id, d.name, d.email, d.city, d.phone,
    CURRENT_TIMESTAMP,  -- valid_from: when deletion was detected
    NULL,               -- valid_to: NULL = this deleted version is current
    TRUE,
    TRUE,               -- is_deleted = TRUE signals this is a deletion record
    CURRENT_TIMESTAMP
FROM dim_customers d
WHERE d.is_current = FALSE
  AND d.valid_to = CURRENT_TIMESTAMP  -- just expired this run
  AND d.customer_id NOT IN (SELECT customer_id FROM src);
```

**Soft delete benefit:** The full timeline is preserved, including the deletion event. Fact records that occurred before deletion still join correctly. `is_deleted = TRUE` rows are the terminal version.

| | Hard Delete | Soft Delete |
|---|---|---|
| History preserved? | Partial (historical rows stay, active row closed) | Full (deletion event is a new version) |
| Source type needed | Full snapshot | Any |
| Downstream query impact | Filter `is_current = TRUE` excludes deleted | Filter `is_current = TRUE AND is_deleted = FALSE` |
| Audit trail | No record that deletion occurred | Deletion timestamped as a version |

---

### Iteration 6 — Schema Evolution (New Column Added)

**Problem:** Source adds a `phone` column. Target table doesn't have it yet. All existing active rows have no `phone` value.

**Two-step approach:**

**Step 1 — DDL first (before pipeline runs):**

```sql
ALTER TABLE dim_customers ADD COLUMN phone VARCHAR DEFAULT 'N/A';
-- Backfill historical rows
UPDATE dim_customers SET phone = 'N/A' WHERE phone IS NULL;
```

**Step 2 — Add `phone` to change detection and inserts:**

```sql
-- In Phase 1, add phone to change detection:
WHERE s.updated_at > d.valid_from
  AND (
    s.name  IS DISTINCT FROM d.name
    OR s.email IS DISTINCT FROM d.email
    OR s.city  IS DISTINCT FROM d.city
    OR s.phone IS DISTINCT FROM d.phone    -- ← new column: a phone change now creates a new SCD2 version
  )

-- In Phase 2 INSERT:
INSERT INTO dim_customers
    (customer_id, name, email, city, phone, valid_from, valid_to, is_current, created_at)
SELECT s.customer_id, s.name, s.email, s.city,
       COALESCE(s.phone, 'N/A'),    -- ← default when source sends NULL for the new column
       s.updated_at, NULL, TRUE, CURRENT_TIMESTAMP
FROM src s
WHERE NOT EXISTS (
    SELECT 1 FROM dim_customers d
    WHERE d.customer_id = s.customer_id
      AND d.is_current  = TRUE
      AND d.name  IS NOT DISTINCT FROM s.name
      AND d.email IS NOT DISTINCT FROM s.email
      AND d.city  IS NOT DISTINCT FROM s.city
      AND d.phone IS NOT DISTINCT FROM s.phone   -- ← include in not-changed guard
);
```

**Schema evolution rule for SCD2:** Adding a new tracked column means every existing customer gets a new SCD2 version on the next pipeline run (because `d.phone IS DISTINCT FROM s.phone` will be TRUE for all current rows that have `phone = 'N/A'` but source sends a real value). Decide upfront whether the new column is **tracked** (changes create new versions) or **non-tracked** (changes overwrite in place, like SCD1). Non-tracked columns are updated directly without creating a new version.

---

### Iteration 7 — Deleted Record Reappeared

**Problem:** Customer 1001 was closed last month (no `is_current = TRUE` row, only historical rows). Customer re-registers and appears in source again.

Phase 1 looks only at `is_current = TRUE` rows — there are none for 1001 — so Phase 1 does nothing.

Phase 2's `NOT EXISTS` check: "no active row exists that matches source" → `NOT EXISTS` is TRUE (there is no `is_current = TRUE` row at all) → insert fires correctly and creates a new active row ✓

**But only if the `NOT EXISTS` guard doesn't check `customer_id` existence globally.** In Iteration 4, the single-INSERT Phase 2 uses:

```sql
WHERE NOT EXISTS (
    SELECT 1 FROM dim_customers d
    WHERE d.customer_id = s.customer_id
      AND d.is_current = TRUE          -- ← THIS is the key
      AND d.name IS NOT DISTINCT FROM s.name
      ...
)
```

Because the condition requires `is_current = TRUE` AND a value match, a customer with only `is_current = FALSE` rows satisfies `NOT EXISTS` → insert fires → new active row created ✓

**Make it explicit with a comment and add reactivation to Phase 1's scope check:**

```sql
-- PHASE 2: Covers three cases — read the comments
INSERT INTO dim_customers
    (customer_id, name, email, city, phone, valid_from, valid_to, is_current, created_at)
SELECT s.customer_id, s.name, s.email, s.city, COALESCE(s.phone, 'N/A'),
       s.updated_at, NULL, TRUE, CURRENT_TIMESTAMP
FROM src s
WHERE NOT EXISTS (
    SELECT 1 FROM dim_customers d
    WHERE d.customer_id = s.customer_id
      AND d.is_current  = TRUE
      AND d.name  IS NOT DISTINCT FROM s.name
      AND d.email IS NOT DISTINCT FROM s.email
      AND d.city  IS NOT DISTINCT FROM s.city
      AND d.phone IS NOT DISTINCT FROM s.phone
);
-- Case 1 — brand new customer (no rows in dim at all):
--   NOT EXISTS → TRUE (no row of any kind) → INSERT fires ✓
-- Case 2 — changed customer (active row exists but values differ):
--   Phase 1 expired the active row → NOT EXISTS → TRUE (no active row) → INSERT fires ✓
-- Case 3 — reappearing customer (only is_current=FALSE rows exist):
--   NOT EXISTS → TRUE (no active row) → INSERT fires, creating a new version ✓
-- Case 4 — unchanged customer (active row exists and values match):
--   NOT EXISTS → FALSE → INSERT skipped ✓
-- Case 5 — same batch re-run:
--   New active row already inserted on first run → NOT EXISTS → FALSE → skipped ✓
---

### Final Production SCD2 — All Constraints Handled

```sql
-- ============================================================
-- Dedup source (Iteration 4: same-batch safety)
-- ============================================================
WITH src AS (
    SELECT *
    FROM (
        SELECT *,
               ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY updated_at DESC) AS rn
        FROM stg_customers
    ) deduped
    WHERE rn = 1
)

-- ============================================================
-- PHASE 1: Expire changed rows
-- ============================================================
UPDATE dim_customers
SET
    valid_to   = CURRENT_TIMESTAMP,
    is_current = FALSE
WHERE is_current = TRUE
  AND customer_id IN (
      SELECT s.customer_id
      FROM src s
      JOIN dim_customers d ON s.customer_id = d.customer_id AND d.is_current = TRUE
      WHERE s.updated_at > d.valid_from                    -- Iteration 3: reject late arrivals
        AND (
            s.name  IS DISTINCT FROM d.name                -- Iteration 2: NULL-safe change detection
            OR s.email IS DISTINCT FROM d.email
            OR s.city  IS DISTINCT FROM d.city
            OR s.phone IS DISTINCT FROM d.phone            -- Iteration 6: new column tracked
        )
  );

-- Phase 1-B: Close rows for hard-deleted customers (absent from source)
-- Only use if source is a FULL snapshot — comment out for delta loads
UPDATE dim_customers
SET valid_to = CURRENT_TIMESTAMP, is_current = FALSE
WHERE is_current = TRUE
  AND customer_id NOT IN (SELECT customer_id FROM src);  -- Iteration 5: hard delete

-- ============================================================
-- PHASE 2: Insert new versions
-- ============================================================
INSERT INTO dim_customers
    (customer_id, name, email, city, phone, valid_from, valid_to, is_current, created_at)
SELECT
    s.customer_id,
    s.name,
    s.email,
    s.city,
    COALESCE(s.phone, 'N/A'),   -- Iteration 6: schema evolution default
    s.updated_at,               -- Iteration 3: business timestamp as valid_from
    NULL,
    TRUE,
    CURRENT_TIMESTAMP
FROM src s
WHERE NOT EXISTS (
    -- Iteration 1+2+4+7: idempotent, NULL-safe, handles reappearing customers
    SELECT 1 FROM dim_customers d
    WHERE d.customer_id = s.customer_id
      AND d.is_current  = TRUE
      AND d.name  IS NOT DISTINCT FROM s.name
      AND d.email IS NOT DISTINCT FROM s.email
      AND d.city  IS NOT DISTINCT FROM s.city
      AND d.phone IS NOT DISTINCT FROM s.phone
);
---

### Reconstruct SCD2 from an audit log (bonus pattern)

When you're given a raw change log and asked to build the SCD2 table from scratch:

```sql
WITH change_log AS (
    SELECT customer_id, new_name AS name, new_city AS city, changed_at
    FROM customer_audit_log
),
with_next AS (
    SELECT
        customer_id,
        name,
        city,
        changed_at AS valid_from,
        LEAD(changed_at) OVER (PARTITION BY customer_id ORDER BY changed_at) AS valid_to
    FROM change_log
)
SELECT
    customer_id,
    name,
    city,
    valid_from,
    COALESCE(valid_to, '9999-12-31') AS valid_to,  -- NULL = still active
    (valid_to IS NULL) AS is_current
FROM with_next
ORDER BY customer_id, valid_from;
---


