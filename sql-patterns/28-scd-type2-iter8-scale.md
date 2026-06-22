<!-- Part of sql-patterns: SCD Type 2 — Iteration 8 (Single MERGE), Iteration Summary, Gotchas, Edge Cases, At Scale -->
<!-- Source: sql_patterns.md lines 7362–7739 -->

### Iteration 8 — Single-Statement MERGE-Based SCD2

#### Why this works

The two-phase approach (Phase 1: expire old rows, Phase 2: insert new versions) requires two separate DML statements. A single-statement MERGE is possible by exploiting a clever trick in the MERGE source: **UNION two types of rows together**.

- **EXPIRE rows**: join the staging table to the current dimension rows where something changed. These rows carry the real `sk_customer` surrogate key from the target table.
- **INSERT rows**: new versions to be created (both brand-new customers and updated versions of changed customers). These rows have `sk_customer = NULL` because no matching current row exists yet (or we intentionally set it to NULL).

The MERGE join condition is `target.sk_customer = source.sk_customer AND source.action = 'EXPIRE'` (implicit — only EXPIRE rows have a non-NULL `sk_customer`). Because INSERT rows have `sk_customer = NULL`, they **never match** anything in the target, so they fall into `WHEN NOT MATCHED → INSERT`. The two branches of MERGE handle both operations atomically in one statement.

```

EXPIRE rows → sk_customer IS NOT NULL → MATCHED → UPDATE (close old row)
INSERT rows → sk_customer IS NULL     → NOT MATCHED → INSERT (open new row)

```

#### The MERGE code

```sql
UPDATE dim_customers
SET
    valid_to = CURRENT_TIMESTAMP,
    is_current = FALSE
WHERE is_current = TRUE
  AND customer_id IN (
      SELECT s.customer_id
      FROM stg_customers s
      WHERE s.name  <> dim_customers.name
         OR s.email <> dim_customers.email
         OR s.city  <> dim_customers.city
         OR s.phone <> dim_customers.phone
  );

INSERT INTO dim_customers
    (customer_id, name, email, city, phone, valid_from, valid_to, is_current, created_at)
SELECT
    s.customer_id,
    s.name,
    s.email,
    s.city,
    s.phone,
    CURRENT_TIMESTAMP AS valid_from,
    NULL AS valid_to,
    TRUE AS is_current,
    CURRENT_TIMESTAMP AS created_at
FROM stg_customers s
WHERE NOT EXISTS (
    SELECT 1 FROM dim_customers d
    WHERE d.customer_id = s.customer_id
      AND d.is_current = TRUE
      AND d.name = s.name
      AND d.email = s.email
      AND d.city = s.city
      AND d.phone = s.phone
);
```

#### When to use this vs the two-phase approach

| Approach | Pros | Cons | Best for |
|---|---|---|---|
| **Two-phase (Iterations 0-7)** | Explicit and readable; easy to debug if one phase fails; works on all platforms including older MySQL/PostgreSQL | Two statements — not atomic unless wrapped in a transaction; harder to schedule as a single unit | Any platform; teams that value debuggability; environments without strong MERGE support |

#### Duplicate guard for the INSERT branch

If `stg_customers` can contain duplicate `customer_id` rows (e.g., two rows for the same customer in the same batch), the INSERT branch of the UNION will produce multiple rows with `sk_customer = NULL` for the same customer. MERGE will try to insert both, which is either silently wrong (two active rows for one customer) or raises an ambiguous match error depending on the platform.

Add a deduplication step before the MERGE using `ROW_NUMBER()`:

```sql
-- In the INSERT branch, deduplicate source before the MERGE:
WITH deduped_source AS (
    SELECT *,
        ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY updated_at DESC) AS rn
    FROM stg_customers
)
SELECT * FROM deduped_source WHERE rn = 1
```

Replace the `FROM stg_customers s` in both branches of the UNION with `FROM deduped_source s` (after defining `deduped_source` as a CTE wrapping the entire MERGE source). This guarantees at most one EXPIRE row and one INSERT row per `customer_id`, eliminating the ambiguous match risk.

---

### Iteration summary

| Iteration | Problem solved | Key addition |
|---|---|---|
| 0 | Base two-phase SCD2 | Phase 1 (expire) + Phase 2 (insert new versions) |
| 1 | Idempotency | Phase 2 guards with `NOT EXISTS (is_current AND values match)` |
| 2 | NULL safety | Replace all `=`/`<>` change detection with `IS DISTINCT FROM` |
| 3 | Late arrivals | `s.updated_at > d.valid_from` guard; use `s.updated_at` as `valid_from` |
| 4 | Same batch re-runs | `ROW_NUMBER()` dedup on source CTE |
| 5 | Deletes | Hard delete (UPDATE absent rows) vs Soft delete (`is_deleted` version) |
| 6 | Schema evolution | `COALESCE` default + add new column to change-detection clause |
| 7 | Deleted record reappeared | `NOT EXISTS (is_current = TRUE ...)` naturally handles reactivation |
| 8 | Single-statement atomicity | MERGE with UNION source: EXPIRE rows (real sk) → MATCHED→UPDATE; INSERT rows (sk=NULL) → NOT MATCHED→INSERT |

### Gotchas

- **Range join:** always `valid_from <= event_time < valid_to`, never `<=` for `valid_to` — exact boundary duplicates a row in the result
- **`valid_to IS NULL` vs `is_current = TRUE`:** keep both in sync — never let them drift
- **Multiple active rows** for the same `customer_id` (both `is_current = TRUE`) = data quality incident — add a DQ check: `SELECT customer_id FROM dim_customers WHERE is_current = TRUE GROUP BY customer_id HAVING COUNT(*) > 1`
- **Surrogate key joins:** fact tables must join on `sk_customer`, not `customer_id` — joining on `customer_id` in a SCD2 table produces a fan-out (one fact row × N historical dimension rows = N result rows)
- **`s.updated_at` as `valid_from`** (Iteration 3) means your history accurately reflects *when the business change happened*, not when your pipeline ran — critical for audit and point-in-time correctness
- **dbt snapshot alternative:** dbt's `{% snapshot %}` block automates the entire two-phase pattern above and handles most of these edge cases. In a dbt project, always prefer snapshots over hand-rolled SCD2 SQL

### Edge Cases

#### Edge 14-A: Multiple changes on the same day — ambiguous valid_from

**Problem:**

```sql
-- User's credit tier changes twice on 2024-03-15:
-- 09:00: Bronze → Silver (automated upgrade)
-- 14:00: Silver → Gold  (manual override by ops team)
-- Both get valid_from = '2024-03-15' — but valid_to for the Bronze record = '2024-03-15'
-- This creates a zero-duration row AND an ambiguous join

-- user_id | tier   | valid_from  | valid_to
--   U1    | Bronze | 2024-01-01  | 2024-03-15  ← zero-duration on March 15!
--   U1    | Silver | 2024-03-15  | 2024-03-15  ← zero-duration Silver record
--   U1    | Gold   | 2024-03-15  | NULL        ← current

-- Query: "what was U1's tier on 2024-03-15?"
SELECT tier FROM user_tiers
WHERE user_id = 'U1'
  AND valid_from <= '2024-03-15'
  AND (valid_to IS NULL OR valid_to >= '2024-03-15');
-- Returns: Silver AND Gold (both match!) → FAN-OUT → wrong join result
```

**Fix A — use timestamps (not dates) for valid_from/valid_to:**

```sql
-- valid_from = 2024-03-15 09:00, valid_to = 2024-03-15 14:00 (Silver)
-- valid_from = 2024-03-15 14:00, valid_to = NULL (Gold)
-- Now point-in-time query at 2024-03-15 12:00 returns exactly Silver ✓
```

**Fix B — if timestamps not available, use ROW_NUMBER to pick the LAST change on that day:**

```sql
WITH latest_on_day AS (
    SELECT *,
        ROW_NUMBER() OVER (
            PARTITION BY user_id, valid_from
            ORDER BY change_seq DESC  -- latest change sequence on that day
        ) AS rn
    FROM user_tiers
)
SELECT * FROM latest_on_day WHERE rn = 1;  -- keep only the last change per day per user
```

#### Edge 14-B: Fact record falls in a gap between SCD2 versions

**Problem:**

```sql
-- user_tiers has versions: Silver valid_from=Jan1 valid_to=Mar31,
--                          Gold valid_from=Apr2 valid_to=NULL
-- There is a gap: April 1 has no tier record (data quality — no version covers April 1)

-- A transaction on April 1 joins to ZERO tier records:
SELECT t.txn_id, ut.tier
FROM transactions t
JOIN user_tiers ut
    ON t.user_id = ut.user_id
    AND t.txn_date >= ut.valid_from
    AND (ut.valid_to IS NULL OR t.txn_date < ut.valid_to);
-- April 1 transaction: valid_from(Gold)=Apr2 > Apr1 → doesn't match Gold
--                      valid_to(Silver)=Mar31 < Apr1 → doesn't match Silver
-- RESULT: April 1 transaction has NO matching tier → drops from INNER JOIN
-- With LEFT JOIN: tier IS NULL for April 1 transactions
```

**Fix — detect and report gaps in SCD2 coverage:**

```sql
WITH gaps AS (
    SELECT
        user_id, tier, valid_from, valid_to,
        LEAD(valid_from) OVER (PARTITION BY user_id ORDER BY valid_from) AS next_valid_from
    FROM user_tiers
)
SELECT user_id, valid_to AS gap_start, next_valid_from AS gap_end
FROM gaps
WHERE valid_to IS NOT NULL
  AND next_valid_from > valid_to;  -- gap between end of one version and start of next
```

#### Edge 14-C: Fact record before first SCD2 version

**Problem:**

```sql
-- Transaction happened on 2023-12-15 but user_tiers starts 2024-01-01
-- (User created account before tier system was implemented)
-- This transaction has no matching tier record → drops from INNER JOIN

-- Detection:
SELECT t.txn_id, t.txn_date, MIN(ut.valid_from) AS earliest_tier_date
FROM transactions t
LEFT JOIN user_tiers ut ON t.user_id = ut.user_id
GROUP BY t.txn_id, t.txn_date
HAVING t.txn_date < MIN(ut.valid_from);  -- txn before any tier version

-- Fix: either backfill a "LEGACY" tier version from epoch to the first real version,
-- or handle it explicitly in the join:
LEFT JOIN user_tiers ut
    ON t.user_id = ut.user_id
    AND t.txn_date >= ut.valid_from
    AND (ut.valid_to IS NULL OR t.txn_date < ut.valid_to)
WHERE COALESCE(ut.tier, 'LEGACY') IS NOT NULL  -- treat unmatched txns as LEGACY tier
```

**Fix:**

```sql
-- Option A: backfill a 'LEGACY' tier row covering epoch to first real version:
WITH tier_with_legacy AS (
    SELECT user_id, tier, valid_from, valid_to FROM user_tiers
    UNION ALL
    SELECT user_id, 'LEGACY' AS tier,
           DATE '1900-01-01' AS valid_from,
           MIN(valid_from) AS valid_to
    FROM user_tiers
    GROUP BY user_id
)
SELECT t.txn_id, COALESCE(ut.tier, 'LEGACY') AS tier
FROM transactions t
LEFT JOIN tier_with_legacy ut
    ON  t.user_id   = ut.user_id
    AND t.txn_date >= ut.valid_from
    AND (ut.valid_to IS NULL OR t.txn_date < ut.valid_to);

-- Option B: label pre-system transactions explicitly:
SELECT t.txn_id, t.txn_date,
    CASE
        WHEN ut.tier IS NULL THEN 'PRE_TIER_SYSTEM'
        ELSE ut.tier
    END AS effective_tier
FROM transactions t
LEFT JOIN user_tiers ut
    ON  t.user_id   = ut.user_id
    AND t.txn_date >= ut.valid_from
    AND (ut.valid_to IS NULL OR t.txn_date < ut.valid_to);
```

---

### At Scale

#### Failure Mechanism

The temporal join pattern at scale:

```sql
-- BEFORE: expensive range join on 800M transactions × large SCD2 table
SELECT t.txn_id, ut.tier
FROM transactions t   -- 800M rows
JOIN user_tiers ut    -- 200M rows (many historical versions)
    ON t.user_id = ut.user_id
    AND t.txn_date >= ut.valid_from
    AND (ut.valid_to IS NULL OR t.txn_date < ut.valid_to);

-- FIX 1: Add a month bridge table so most of the join is equality-based.
-- Populate scd2_month_bridge during ETL with one row per covered month.
WITH txn_with_month AS (
    SELECT txn_id, user_id, txn_date,
        DATE_TRUNC('month', txn_date) AS month_key
    FROM transactions
)
SELECT t.txn_id, s.tier
FROM txn_with_month t
JOIN scd2_month_bridge s
    ON t.user_id = s.user_id
   AND t.month_key = s.month_key
   AND t.txn_date >= s.valid_from
   AND (s.valid_to IS NULL OR t.txn_date < s.valid_to);
-- The month key narrows candidates before the exact range predicate is applied.

-- FIX 2: Denormalize the current tier directly into the fact table at write time
-- If 95% of queries only need the tier AT TIME OF TRANSACTION (not arbitrary point-in-time):
-- Store tier_at_txn in the transactions table itself
-- Update it at ingestion via a lookup: SELECT tier FROM user_tiers WHERE valid_to IS NULL
-- Query: SELECT txn_id, tier_at_txn FROM transactions — zero join needed at query time

```

#### System-Level Fix

```sql
CREATE TABLE user_tiers (
    user_id     BIGINT,
    tier        VARCHAR(10),
    valid_from  DATE,
    valid_to    DATE
);

CREATE INDEX idx_user_tiers_user_from
    ON user_tiers (user_id, valid_from);

-- The access path narrows candidates by user before applying the date range.
```

---

---

