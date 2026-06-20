<!-- Part of sql-patterns: SCD Type 1 — Iterations 6-7, Final MERGE, Summary, Gotchas, Edge Cases, At Scale -->
<!-- Source: sql_patterns.md lines 6393–6713 -->

### Iteration 6 — Schema Evolution (New Column Added to Source)

**Problem:** Source adds a `phone` column that didn't exist before. The existing target table doesn't have it yet.

**Two scenarios:**

#### Scenario A — Column already added to target (DDL ran first), source sometimes sends NULL

```sql
-- Handle gracefully with COALESCE in the INSERT:
WHEN NOT MATCHED BY TARGET THEN
    INSERT (customer_id, name, email, city, phone, created_at, updated_at, is_active, deleted_at)
    VALUES (
        s.customer_id,
        s.name,
        s.email,
        s.city,
        COALESCE(s.phone, 'N/A'),   -- ← default when source sends NULL for new column
        CURRENT_TIMESTAMP,
        s.updated_at,
        TRUE,
        NULL
    )
```

And include `phone` in the change-detection clause:

```sql
WHEN MATCHED
    AND s.updated_at > t.updated_at
    AND (
        t.name  IS DISTINCT FROM s.name
        OR t.email IS DISTINCT FROM s.email
        OR t.city  IS DISTINCT FROM s.city
        OR t.phone IS DISTINCT FROM s.phone   -- ← new column added here
    ) THEN
    UPDATE SET
        t.name       = s.name,
        t.email      = s.email,
        t.city       = s.city,
        t.phone      = COALESCE(s.phone, t.phone),  -- ← don't overwrite existing with NULL
        t.updated_at = s.updated_at,
        t.is_active  = TRUE,
        t.deleted_at = NULL
```

#### Scenario B — Backfill existing rows after column is added

```sql
-- After ALTER TABLE dim_customers ADD COLUMN phone VARCHAR:
-- Backfill all pre-existing rows that predate the new column
UPDATE dim_customers
SET phone = 'N/A'
WHERE phone IS NULL;
```

**Rule:** When you add a column to target, always provide a default (via `COALESCE` in MERGE and a one-time `UPDATE` backfill). Never rely on NULL as a legitimate default unless the business explicitly accepts it.

---

### Iteration 7 — Deleted Record Reappeared

**Problem:** `customer_id = 1001` was soft-deleted yesterday (`is_active = FALSE`, `deleted_at = 2026-05-19`). Today they reappear in the source (customer re-registered). The naive MERGE fires `WHEN MATCHED` because the key exists in both source and target — but if the customer's other fields (name, email, city) are unchanged, `IS DISTINCT FROM` detects no diff → `WHEN MATCHED` is skipped → the row stays soft-deleted. Customer is invisible to consumers. Silent bug.

**Fix:** Include `t.is_active = FALSE` as an additional trigger in the change-detection clause, so a reappearing soft-deleted customer ALWAYS gets reactivated regardless of whether other fields changed:

```sql
WHEN MATCHED
    AND s.updated_at > t.updated_at
    AND (
        t.name     IS DISTINCT FROM s.name
        OR t.email IS DISTINCT FROM s.email
        OR t.city  IS DISTINCT FROM s.city
        OR t.phone IS DISTINCT FROM s.phone
        OR t.is_active = FALSE              -- ← reactivate even if no other field changed
    ) THEN
    UPDATE SET
        t.name       = s.name,
        t.email      = s.email,
        t.city       = s.city,
        t.phone      = COALESCE(s.phone, t.phone),
        t.updated_at = s.updated_at,
        t.is_active  = TRUE,                -- ← reactivate
        t.deleted_at = NULL                 -- ← clear deletion marker
```

**Now:** Reappearing customer → `t.is_active = FALSE` is TRUE → `WHEN MATCHED` fires → row reactivated → downstream sees the customer as active again.

---

### Final MERGE — All Constraints Handled

This is the production-grade SCD1 MERGE incorporating every iteration above:

```sql
MERGE INTO dim_customers AS t
USING (
    -- Iteration 4: Deduplicate source to prevent duplicate-key errors on retry
    SELECT *
    FROM (
        SELECT *,
               ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY updated_at DESC) AS rn
        FROM stg_customers
    ) deduped
    WHERE rn = 1
) AS s
ON t.customer_id = s.customer_id

-- Iteration 1+2+3+6+7: Only update if data actually changed, newer, or was soft-deleted
WHEN MATCHED
    AND s.updated_at > t.updated_at          -- Iteration 3: reject late-arriving records
    AND (
        t.name     IS DISTINCT FROM s.name   -- Iteration 2: NULL-safe comparison
        OR t.email IS DISTINCT FROM s.email
        OR t.city  IS DISTINCT FROM s.city
        OR t.phone IS DISTINCT FROM s.phone  -- Iteration 6: new column included
        OR t.is_active = FALSE               -- Iteration 7: reappearing deleted record
    ) THEN
    UPDATE SET
        t.name       = s.name,
        t.email      = s.email,
        t.city       = s.city,
        t.phone      = COALESCE(s.phone, t.phone),  -- Iteration 6: don't overwrite with NULL
        t.updated_at = s.updated_at,
        t.is_active  = TRUE,                         -- Iteration 7: reactivate
        t.deleted_at = NULL                          -- Iteration 7: clear deletion marker

-- Iteration 1+4: Only insert genuinely new keys
WHEN NOT MATCHED BY TARGET THEN
    INSERT (customer_id, name, email, city, phone, created_at, updated_at, is_active, deleted_at)
    VALUES (
        s.customer_id,
        s.name,
        s.email,
        s.city,
        COALESCE(s.phone, 'N/A'),   -- Iteration 6: default for new column
        CURRENT_TIMESTAMP,
        s.updated_at,
        TRUE,
        NULL
    )

-- Iteration 5: Soft delete rows absent from source
WHEN NOT MATCHED BY SOURCE THEN
    UPDATE SET
        t.is_active  = FALSE,
        t.deleted_at = CURRENT_TIMESTAMP;
```

### Iteration summary

| Iteration | Problem solved | Key addition |
|---|---|---|
| 0 | Base MERGE | Insert new, overwrite existing |
| 1 | Idempotency | `IS DISTINCT FROM` change detection, no phantom updates |
| 2 | NULL safety | Replace `<>` with `IS DISTINCT FROM` |
| 3 | Late arrivals | `s.updated_at > t.updated_at` guard |
| 4 | Same batch re-runs | `ROW_NUMBER()` dedup on source |
| 5 | Deletes | Hard delete (`DELETE`) vs Soft delete (`is_active = FALSE`) |
| 6 | Schema evolution | `COALESCE` for new columns, backfill `UPDATE` |
| 7 | Deleted record reappears | `OR t.is_active = FALSE` + reactivation in `UPDATE SET` |

### Gotchas

- The `updated_at` guard (Iteration 3) assumes the source timestamp is trustworthy. If the source system always re-stamps `updated_at = NOW()` on every export, drop the guard and rely solely on `IS DISTINCT FROM`.
- Soft deletes require a discipline contract: every consumer query must filter `WHERE is_active = TRUE`, or build a view that does it automatically.

### Edge Cases

#### Edge 13-A: Out-of-order events — step B happens before step A in timestamps

**Problem:**

```sql
-- Real scenario: KYC system sends approval event with a slight delay
-- kyc_complete event arrives in the table 2 minutes BEFORE the signup event
-- (due to event replay, clock skew, or async processing)

-- Simple funnel (MAX approach) does NOT detect order — counts this user as "done KYC" ✓
-- Ordered funnel (timestamp comparison) rejects this user — kyc_at < signup_at ✗

-- WRONG — rejects legitimate users due to out-of-order events:
COUNT(CASE WHEN kyc_at > signup_at THEN 1 END) AS completed_kyc_after_signup
```

**Fix — use a tolerance window:**

```sql
COUNT(CASE WHEN kyc_at > signup_at - INTERVAL '5 minutes' THEN 1 END)
-- Allow kyc event up to 5 minutes before signup (clock skew tolerance)

-- Or: use event sequence number instead of timestamp for ordering:
COUNT(CASE WHEN kyc_seq > signup_seq THEN 1 END)
-- If your events have a reliable sequence/event_id, use that instead of wall-clock time
```

#### Edge 13-B: Same step completed multiple times — double-counting

**Problem:**

```sql
-- A user fails KYC twice and passes on the third attempt
-- kyc_complete events: 2024-01-05 (fail), 2024-01-10 (fail), 2024-01-15 (pass)
-- MAX(CASE WHEN event_type = 'kyc_attempt') = 1 → user counted as having done KYC
-- But: COUNT(CASE WHEN event_type = 'kyc_attempt') = 3 → inflates step count

-- TRAP: when summing step counts, SUM(did_kyc) counts users, not attempts
-- But if you use COUNT(*) FILTER (WHERE event_type = 'kyc_attempt') you count attempts
-- Mixing these in the same funnel gives inconsistent conversion rates
```

**Fix:**


---

### At Scale

#### Failure Mechanism

The MAX(CASE WHEN ...) funnel requires **one full GROUP BY scan** of the events table. At 2B events for 100M users, this is a single-pass scan — reasonably efficient. The problem is:

- `COUNT(DISTINCT event_type)` patterns require expensive HyperLogLog sketches
- Ordered funnel (timestamp comparison) requires a **self-join** on the events table → N² risk
- Per-cohort funnels with GROUPING SETS require multiple aggregation passes

#### Code-Level Fix


#### System-Level Fix


---

---


