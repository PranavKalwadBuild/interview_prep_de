<!-- Part of sql-patterns: SCD Type 2 — Core Concept, Schema, Point-in-Time Query, Iterations 0–3 -->
<!-- Source: sql_patterns.md lines 6714–7037 -->

## 14. Slowly Changing Dimensions (SCD Type 2)

### What it solves

SCD Type 2 = **keep full history**. Every time an attribute changes, you close the existing row and insert a new one. This lets you answer "what was the value **at the time** of this event?" — something SCD1 destroys forever by overwriting.

### Keywords to spot

> "as of date", "what was the value at the time of",
> "historical state", "point-in-time", "current vs historical",
> "what was the user's tier when they made the trade",
> "slowly changing", "effective date", "expiry date",
> "valid from / valid to", "at the time of transaction",
> "what was active when", "temporal join", "bi-temporal",
> "version history", "what changed", "reconstruct state at"

### Business Context

- **Fintech:** What fee/KYC tier was active for a user at the time of each transaction; what FX rate was in effect when an order was placed
- **E-commerce:** What price/discount was active for a product when an order was placed (accurate revenue accounting)
- **HR:** What was an employee's department/salary band at the time of a performance review
- **Telecom:** What plan was a customer on when they made a call (correct billing)
- **Healthcare:** Which insurance plan covered a patient during a specific procedure

### Why SCD2 needs two operations (critical to understand)

SCD1 can overwrite in place — one MERGE handles everything. SCD2 cannot, because for every change you must:

1. **Close** the currently active row (`valid_to = today, is_current = FALSE`)
2. **Insert** a brand new row with the updated values (`valid_from = today, valid_to = NULL, is_current = TRUE`)

A single MERGE cannot UPDATE an existing row AND INSERT a new row for the same join key in the same statement. This means SCD2 always requires **two phases**:

- **Phase 1** — MERGE or UPDATE: expire the changed rows
- **Phase 2** — INSERT: create the new versions

---

### Schema used across all iterations

```sql
-- Source (staging)
-- stg_customers: customer_id | name | email | city | phone | updated_at

-- Target (SCD2 dimension table)
-- dim_customers:
--   sk_customer  AUTOINCREMENT  -- surrogate key (always use this for joins from fact tables)
--   customer_id  INT            -- natural key
--   name         VARCHAR
--   email        VARCHAR
--   city         VARCHAR
--   phone        VARCHAR
--   valid_from   TIMESTAMP      -- when this version became active
--   valid_to     TIMESTAMP      -- NULL = currently active; set when row is closed
--   is_current   BOOLEAN        -- TRUE for the active row; FALSE for all historical rows
--   created_at   TIMESTAMP      -- when this row was inserted into dim
```

**Why a surrogate key?**
Fact tables join to `sk_customer`, not `customer_id`. If customer 1001 has 3 historical versions, each has a different `sk_customer`. The fact table records which version was active at the time of the event.

---

### Point-in-Time Query (read-side — must know cold)

Before writing the load logic, understand what the output is used for:

```sql
-- "What tier was each customer when they made their transaction?"
SELECT
    t.txn_id,
    t.customer_id,
    t.amount,
    d.city          AS city_at_txn_time,  -- the version active when txn happened
    d.name          AS name_at_txn_time
FROM transactions t
JOIN dim_customers d
    ON  t.customer_id  = d.customer_id
    AND t.txn_ts      >= d.valid_from
    AND (d.valid_to IS NULL OR t.txn_ts < d.valid_to);  -- ← the range join

-- Get only the current active row
SELECT * FROM dim_customers WHERE is_current = TRUE;
-- OR equivalently:
SELECT * FROM dim_customers WHERE valid_to IS NULL;
```

**Range join rule:** `valid_from <= event_time < valid_to`. Never use `<=` for `valid_to` — you'd double-count the row at the exact boundary timestamp.

---

### Iteration 0 — Base Two-Phase SCD2 (Naive starting point)

```sql
-- ============================================================
-- PHASE 1: Expire rows that have changed
-- ============================================================
UPDATE dim_customers
SET
    valid_to   = CURRENT_TIMESTAMP,
    is_current = FALSE
WHERE is_current = TRUE
  AND customer_id IN (
      SELECT s.customer_id
      FROM stg_customers s
      JOIN dim_customers d ON s.customer_id = d.customer_id AND d.is_current = TRUE
      WHERE s.name  <> d.name
         OR s.email <> d.email
         OR s.city  <> d.city
  );

-- ============================================================
-- PHASE 2: Insert new versions (changed records + brand new customers)
-- ============================================================
INSERT INTO dim_customers
    (customer_id, name, email, city, phone, valid_from, valid_to, is_current, created_at)

-- Branch A: Brand new customers (never seen before)
SELECT s.customer_id, s.name, s.email, s.city, s.phone,
       CURRENT_TIMESTAMP, NULL, TRUE, CURRENT_TIMESTAMP
FROM stg_customers s
WHERE NOT EXISTS (
    SELECT 1 FROM dim_customers d WHERE d.customer_id = s.customer_id
)

UNION ALL

-- Branch B: Changed customers (current row was just expired by Phase 1)
SELECT s.customer_id, s.name, s.email, s.city, s.phone,
       CURRENT_TIMESTAMP, NULL, TRUE, CURRENT_TIMESTAMP
FROM stg_customers s
JOIN dim_customers d ON s.customer_id = d.customer_id AND d.is_current = FALSE
                    AND d.valid_to = CURRENT_TIMESTAMP  -- just expired this run
WHERE s.name  <> d.name
   OR s.email <> d.email
   OR s.city  <> d.city;
```

**What this breaks under:**

- Running twice: Phase 1 tries to expire already-expired rows (no `is_current = TRUE` rows remain, so Phase 1 is safe) — but Phase 2 re-fires Branch B by looking for `valid_to = CURRENT_TIMESTAMP`, which could also match rows expired on a previous run at the same second. Double-inserts.
- NULLs: `s.name <> d.name` returns NULL when either side is NULL → row silently skipped.
- Late arrivals: an older record from source closes a newer current row, corrupting history.
- Same batch twice: Branch B's `valid_to = CURRENT_TIMESTAMP` match logic is fragile.

Each iteration below fixes one of these.

---

### Iteration 1 — Idempotency (Don't fire unless something actually changed)

**Problem:** Running Phase 1 on unchanged data still checks every row. More critically — Branch B in Phase 2 uses `valid_to = CURRENT_TIMESTAMP` as a proxy for "just expired this run", but that exact timestamp can collide with prior runs.

**Fix:** Separate the change-detection from the expiry-detection. Use a staging CTE that explicitly identifies changed rows, then Phase 2 reads from source directly with a "no current active matching row" guard.

```sql
-- PHASE 1: Expire only rows that have actually changed
UPDATE dim_customers
SET
    valid_to   = CURRENT_TIMESTAMP,
    is_current = FALSE
WHERE is_current = TRUE
  AND customer_id IN (
      SELECT s.customer_id
      FROM stg_customers s
      JOIN dim_customers d ON s.customer_id = d.customer_id AND d.is_current = TRUE
      WHERE s.name  <> d.name
         OR s.email <> d.email
         OR s.city  <> d.city
  );

-- PHASE 2: Insert new version for any customer that has no matching active row
INSERT INTO dim_customers
    (customer_id, name, email, city, phone, valid_from, valid_to, is_current, created_at)

-- Branch A: Brand new customers
SELECT s.customer_id, s.name, s.email, s.city, s.phone,
       CURRENT_TIMESTAMP, NULL, TRUE, CURRENT_TIMESTAMP
FROM stg_customers s
WHERE NOT EXISTS (SELECT 1 FROM dim_customers d WHERE d.customer_id = s.customer_id)

UNION ALL

-- Branch B: Changed customers — no active row matching source values
SELECT s.customer_id, s.name, s.email, s.city, s.phone,
       CURRENT_TIMESTAMP, NULL, TRUE, CURRENT_TIMESTAMP
FROM stg_customers s
WHERE NOT EXISTS (
    SELECT 1 FROM dim_customers d
    WHERE d.customer_id = s.customer_id
      AND d.is_current  = TRUE
      AND d.name  = s.name    -- if an active row already matches → no insert needed
      AND d.email = s.email
      AND d.city  = s.city
)
AND EXISTS (
    SELECT 1 FROM dim_customers d WHERE d.customer_id = s.customer_id  -- must exist in dim (not brand new)
);
```

**Now:** Running the same batch twice:

- Phase 1 re-runs → `is_current = TRUE` rows were already expired → subquery finds nothing → no rows updated ✓
- Phase 2 Branch B re-runs → `NOT EXISTS (... is_current = TRUE AND name = s.name ...)` → the new active row now matches → NOT EXISTS is FALSE → no duplicate insert ✓

**Still breaks:** NULLs. The `=` comparisons in `NOT EXISTS` return NULL when either side is NULL.

---

### Iteration 2 — NULL-Safe Comparison (IS DISTINCT FROM)

**Problem:** Source sends `city = NULL`. Target has `city = 'Delhi'`. Phase 1's `s.city <> d.city` returns NULL → row not expired → no new version created → change is silently swallowed. Also Phase 2's `d.city = s.city` returns NULL → `NOT EXISTS` is always TRUE → duplicate inserts for any NULL field.

**Fix:** Replace every `=` and `<>` used for change detection with `IS DISTINCT FROM` / `IS NOT DISTINCT FROM`:

```sql
-- PHASE 1: NULL-safe expiry
UPDATE dim_customers
SET valid_to = CURRENT_TIMESTAMP, is_current = FALSE
WHERE is_current = TRUE
  AND customer_id IN (
      SELECT s.customer_id
      FROM stg_customers s
      JOIN dim_customers d ON s.customer_id = d.customer_id AND d.is_current = TRUE
      WHERE s.name  IS DISTINCT FROM d.name    -- ← NULL-safe: NULL→'Alice' fires, NULL→NULL skips
         OR s.email IS DISTINCT FROM d.email
         OR s.city  IS DISTINCT FROM d.city
  );

-- PHASE 2: NULL-safe no-duplicate guard
INSERT INTO dim_customers
    (customer_id, name, email, city, phone, valid_from, valid_to, is_current, created_at)

-- Branch A: Brand new customers
SELECT s.customer_id, s.name, s.email, s.city, s.phone,
       CURRENT_TIMESTAMP, NULL, TRUE, CURRENT_TIMESTAMP
FROM stg_customers s
WHERE NOT EXISTS (SELECT 1 FROM dim_customers d WHERE d.customer_id = s.customer_id)

UNION ALL

-- Branch B: Changed customers
SELECT s.customer_id, s.name, s.email, s.city, s.phone,
       CURRENT_TIMESTAMP, NULL, TRUE, CURRENT_TIMESTAMP
FROM stg_customers s
WHERE NOT EXISTS (
    SELECT 1 FROM dim_customers d
    WHERE d.customer_id = s.customer_id
      AND d.is_current  = TRUE
      AND d.name  IS NOT DISTINCT FROM s.name   -- ← NULL-safe equality
      AND d.email IS NOT DISTINCT FROM s.email
      AND d.city  IS NOT DISTINCT FROM s.city
)
AND EXISTS (SELECT 1 FROM dim_customers d WHERE d.customer_id = s.customer_id);
```

> **IS DISTINCT FROM truth table:**
> `NULL IS DISTINCT FROM NULL` → FALSE (no change — skip) ✓
> `NULL IS DISTINCT FROM 'Delhi'` → TRUE (change detected — expire + insert) ✓
> `'Delhi' IS DISTINCT FROM 'Delhi'` → FALSE (no change — skip) ✓

---

### Iteration 3 — Late Arriving Records

**Problem:** Daily pipeline runs at 08:00. At 10:00 a record for `customer_id = 1001` arrives with `updated_at = 2026-01-15`. Target already has a current version with `valid_from = 2026-04-01` (months newer). Without a guard:

- Phase 1 detects a diff (the late record has a different city) → expires the current row (which is correct as of April) → closes a valid version
- Phase 2 inserts a January-state row as the new "current" version → history is now corrupted

**Fix:** Add a timestamp guard in Phase 1. Only expire if the source record is **newer** than the current row:

```sql
-- PHASE 1: Only expire if source is newer than the currently active row
UPDATE dim_customers
SET valid_to = CURRENT_TIMESTAMP, is_current = FALSE
WHERE is_current = TRUE
  AND customer_id IN (
      SELECT s.customer_id
      FROM stg_customers s
      JOIN dim_customers d ON s.customer_id = d.customer_id AND d.is_current = TRUE
      WHERE s.updated_at > d.valid_from             -- ← reject late-arriving records
        AND (
          s.name  IS DISTINCT FROM d.name
          OR s.email IS DISTINCT FROM d.email
          OR s.city  IS DISTINCT FROM d.city
        )
  );

-- PHASE 2: Only insert a new version if source is newer than the latest known version
INSERT INTO dim_customers
    (customer_id, name, email, city, phone, valid_from, valid_to, is_current, created_at)

-- Branch A: Brand new customers
SELECT s.customer_id, s.name, s.email, s.city, s.phone,
       s.updated_at, NULL, TRUE, CURRENT_TIMESTAMP
FROM stg_customers s
WHERE NOT EXISTS (SELECT 1 FROM dim_customers d WHERE d.customer_id = s.customer_id)

UNION ALL

-- Branch B: Changed customers — source is newer, and no matching active row exists
SELECT s.customer_id, s.name, s.email, s.city, s.phone,
       s.updated_at, NULL, TRUE, CURRENT_TIMESTAMP   -- ← use s.updated_at as valid_from, not CURRENT_TIMESTAMP
FROM stg_customers s
WHERE NOT EXISTS (
    SELECT 1 FROM dim_customers d
    WHERE d.customer_id = s.customer_id
      AND d.is_current  = TRUE
      AND d.name  IS NOT DISTINCT FROM s.name
      AND d.email IS NOT DISTINCT FROM s.email
      AND d.city  IS NOT DISTINCT FROM s.city
)
AND EXISTS (
    SELECT 1 FROM dim_customers d
    WHERE d.customer_id = s.customer_id
      AND s.updated_at > d.valid_from   -- ← source must be newer than the current row we just expired
);
```

**Note:** `valid_from` is now set to `s.updated_at` (the business timestamp), not `CURRENT_TIMESTAMP`. This correctly records *when the change happened in the source system*, not when your pipeline ran.

---

