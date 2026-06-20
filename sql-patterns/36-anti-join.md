<!-- Part of sql-patterns: Anti-Join Pattern (EXISTS, NOT IN, LEFT JOIN IS NULL) -->
<!-- Source: sql_patterns.md lines 9376–9572 -->

## 22. Anti-Join Pattern

### What it solves

Find rows in table A that have NO match in table B — the opposite of a regular join.

### Keywords to spot

> "never", "not in", "no corresponding", "missing",
> "users who have NOT done X", "records without a match",
> "absent from", "unmatched",
> "no record of", "without any", "zero occurrences", "lapsed",
> "inactive", "churned", "no activity in", "never completed",
> "find records in A that don't have a match in B"

### Business Context

- **Fintech:** Users who registered but never made a deposit (activation gap — trigger onboarding nudge); trades that were submitted but never settled (settlement failure detection); accounts that received a credit but never spent it
- **E-commerce:** Products with no orders in 30 days (slow-moving inventory); customers with no activity in 90 days (lapsed customer reactivation campaign); sellers with no listings (dormant seller accounts)
- **SaaS:** Accounts that signed up but never activated a feature (failed onboarding); users who were invited but never logged in (outstanding invite expiry)
- **Data Engineering:** Source records with no corresponding target record after ETL (reconciliation gap — rows dropped in pipeline); dimension table entries with no fact table rows (orphaned dimension members)
- **Compliance:** Users with no completed KYC but who have made transactions (regulatory risk flag); employees with system access but no valid employment record (access governance)

### Three equivalent approaches

```sql
-- Method 1: LEFT JOIN + IS NULL (best performance in most databases)
SELECT u.user_id
FROM users u
LEFT JOIN trades t ON u.user_id = t.user_id
WHERE t.user_id IS NULL;

-- Method 2: NOT EXISTS (readable, optimizer-friendly)
SELECT user_id
FROM users u
WHERE NOT EXISTS (
    SELECT 1 FROM trades t WHERE t.user_id = u.user_id
);

-- Method 3: NOT IN (dangerous with NULLs — avoid)
SELECT user_id
FROM users
WHERE user_id NOT IN (SELECT user_id FROM trades);
-- ⚠️ If trades.user_id has ANY NULL, this returns zero rows
```

### Gotchas

- **NEVER use `NOT IN` on a subquery that can return NULLs** — `NULL IN (1, 2, NULL)` returns NULL (not TRUE), so `NOT IN` returns no rows
- `LEFT JOIN IS NULL` and `NOT EXISTS` are safe and generally equivalent in performance
- Always default to `NOT EXISTS` or `LEFT JOIN IS NULL` in interviews

### Edge Cases

#### Edge 22-A: LEFT JOIN IS NULL with duplicates on the right side

**Problem:**

```sql
-- Anti-join via LEFT JOIN IS NULL: find borrowers with no defaults
SELECT b.borrower_id
FROM borrowers b
LEFT JOIN defaults d ON b.borrower_id = d.borrower_id
WHERE d.borrower_id IS NULL;

-- EDGE CASE: defaults table has TWO rows for the same borrower_id (duplicate defaults)
-- Result: the LEFT JOIN produces TWO matching rows for that borrower → INNER JOIN rows
--         both have non-NULL d.borrower_id → WHERE d.borrower_id IS NULL filters them out
--         borrower correctly appears ZERO times in result ✓

-- But: what about borrowers WITHOUT defaults?
-- They produce ONE row with d.borrower_id IS NULL → appear ONCE in result ✓
-- LEFT JOIN IS NULL is safe for anti-join even with duplicates on the right side
-- (NOT IN is NOT safe — NULL on right side poisons entire result)

-- The real edge case: what if borrowers table itself has duplicates?
-- borrower_id=B001 appears twice in borrowers table
-- → Both rows LEFT JOIN with zero defaults → BOTH appear in result
-- → Borrower B001 appears TWICE in the output (unexpected)
```

**Fix — dedup borrowers first, or add DISTINCT to the outer SELECT:**

```sql
-- FIX: dedup borrowers first, or add DISTINCT to the outer SELECT
SELECT DISTINCT b.borrower_id FROM borrowers b LEFT JOIN defaults d ... WHERE d.borrower_id IS NULL
```

#### Edge 22-B: EXISTS vs NOT EXISTS with correlated subquery scope

**Problem:**

```sql
-- NOT EXISTS is NULL-safe and correct, but correlated scope can be tricky

SELECT b.borrower_id FROM borrowers b
WHERE NOT EXISTS (
    SELECT 1 FROM defaults d WHERE d.borrower_id = b.borrower_id
);
-- This is correct and NULL-safe.

-- TRAP: accidentally writing an uncorrelated subquery (missing the correlation clause):
WHERE NOT EXISTS (
    SELECT 1 FROM defaults d    -- no WHERE linking d to b!
    -- This subquery returns rows if defaults table is non-empty at all
    -- NOT EXISTS (non-empty table) = FALSE → ZERO borrowers returned!
);
-- If the defaults table has ANY rows, this returns nothing
-- The query runs without error — silent complete failure
```

**Fix — always verify the correlation clause exists:**

```sql
WHERE d.borrower_id = b.borrower_id   -- ← must be present
---

### At Scale

#### Failure Mechanism

NOT EXISTS with a large correlated subquery:

```sql
WHERE NOT EXISTS (SELECT 1 FROM defaults d WHERE d.borrower_id = b.borrower_id)
-- BEFORE: NOT EXISTS on large tables
SELECT borrower_id FROM borrowers b
WHERE NOT EXISTS (SELECT 1 FROM defaults d WHERE d.borrower_id = b.borrower_id);

-- FIX 1: LEFT JOIN IS NULL — most optimisers convert this to hash anti-join
SELECT b.borrower_id
FROM borrowers b
LEFT JOIN defaults d ON b.borrower_id = d.borrower_id
WHERE d.borrower_id IS NULL;
-- Both are O(N + M) not O(N × M)

-- FIX 2: Use EXCEPT for set anti-join (no correlated subquery at all)
SELECT borrower_id FROM borrowers
EXCEPT
SELECT DISTINCT borrower_id FROM defaults WHERE borrower_id IS NOT NULL;
-- EXCEPT: O(N log N) sort + merge — scalable and free of correlated execution
-- Reads each table once (not N × M lookups)

-- FIX 3: For streaming anti-join (new borrowers with no prior defaults):
-- Pre-compute the set of defaulted borrowers as a bloom filter or hash set
-- Anti-join is then: bloom_filter.test(borrower_id) == FALSE
-- O(1) per borrower, zero SQL overhead
```

#### System-Level Fix

```sql
ALTER TABLE defaults SET TBLPROPERTIES (
    'delta.bloomFilter.columns' = 'borrower_id',
    'delta.bloomFilter.fpp' = '0.001'
);
-- Anti-join probe: bloom filter check first → most non-defaulted borrowers filtered immediately
-- Without bloom filter: reads Parquet row groups; with bloom filter: reads ~0.1% of row groups

ALTER TABLE defaults ADD SEARCH OPTIMIZATION ON EQUALITY(borrower_id);
-- NOT EXISTS correlated subquery: sub-millisecond lookup per borrower_id instead of full scan

CREATE TABLE defaults (borrower_id BIGINT, ...)
-- NOT EXISTS / LEFT JOIN IS NULL anti-join:
---

---


