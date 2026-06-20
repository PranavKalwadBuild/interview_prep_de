<!-- Part of sql-patterns: Set Operations — UNION, INTERSECT, EXCEPT -->
<!-- Source: sql_patterns.md lines 9154–9375 -->

## 21. Set Operations (UNION / INTERSECT / EXCEPT)

### What it solves

Combine results of multiple queries: union (all rows), intersection (common rows), difference (rows in A but not B).

### Keywords to spot

> "combine", "all records from both", "appear in both",
> "in A but not B", "users who did X but not Y",
> "missing from", "exclusive to",
> "reconciliation", "delta between", "set difference", "overlap",
> "common to both", "merge two sources", "stack tables", "union of"

### Business Context

- **Fintech:** Users who deposited but never traded (EXCEPT — winback campaign target); combine trade data from two brokers (UNION ALL) for a unified position report; users who appear in both fraud watchlist AND active traders (INTERSECT — urgent review queue)
- **E-commerce:** Customers who browsed but never purchased (EXCEPT — retargeting list); products in catalogue but never ordered (EXCEPT — dead stock alert)
- **Data Engineering:** EXCEPT between staging and production to find discrepancies after a migration; UNION ALL to stack historical and incremental loads before dedup
- **Marketing:** Users in segment A (high value) but not segment B (already emailed) for targeted outreach; INTERSECT to find users who qualify for multiple promotions simultaneously
- **Compliance:** Find accounts present in transaction data but absent from KYC records (EXCEPT — onboarding gap); find users in two different sanction screening lists (UNION DISTINCT)

### Boilerplate

```sql
-- UNION ALL: combine (keep duplicates)
SELECT user_id, 'exchange_a' AS source FROM exchange_a_trades
UNION ALL
SELECT user_id, 'exchange_b' AS source FROM exchange_b_trades;

-- UNION: combine (remove duplicates)
SELECT user_id FROM deposits
UNION
SELECT user_id FROM withdrawals;

-- INTERSECT: users who both deposited AND traded
SELECT user_id FROM deposits
INTERSECT
SELECT user_id FROM trades;

-- EXCEPT / MINUS: users who deposited but NEVER traded
SELECT user_id FROM deposits
EXCEPT
SELECT user_id FROM trades;
-- UNION deduplicates rows (more expensive — requires sort or hash)
-- UNION ALL keeps all rows (faster)
-- Using UNION where UNION ALL is needed: duplicates silently removed
-- Using UNION ALL where UNION is needed: duplicates silently kept

-- Scenario: combining transactions from two systems, then summing
-- WRONG with UNION: if same txn_id exists in both systems, it's deduplicated
--                   SUM undercounts revenue by one txn
-- WRONG with UNION ALL: if same txn_id was intentionally in both (test + prod mixed),
--                       SUM double-counts that transaction
```

**Fix — be explicit about intent and add validation:**

```sql
-- After UNION ALL, check for duplicates:
SELECT txn_id, COUNT(*) AS cnt FROM (
    SELECT txn_id FROM system_a
    UNION ALL
    SELECT txn_id FROM system_b
) combined
GROUP BY txn_id
HAVING cnt > 1;  -- these txn_ids appear in both systems — investigate before summing
```

#### Edge 21-B: EXCEPT / MINUS misses rows due to NULL treatment

**Problem:**

```sql
-- EXCEPT treats NULLs as equal (for deduplication purposes)
-- So: row (txn_id=1, amount=NULL) EXCEPT row (txn_id=1, amount=NULL) → removed (correct)
-- But: row (txn_id=1, amount=100) EXCEPT row (txn_id=1, amount=NULL) → NOT removed
-- Two rows that differ only in NULL vs 100 are considered different → both survive

-- Trap: using EXCEPT to find "unchanged" rows between source and target
-- If source has amount=100 and target has amount=NULL (not updated yet)
-- EXCEPT will NOT subtract this row → it appears in the diff as "changed"
-- which is correct! NULL vs 100 IS a difference.

-- But if BOTH have amount=NULL, EXCEPT correctly removes it (NULL = NULL for EXCEPT)
-- This is the OPPOSITE of how NULL works in WHERE — NULL = NULL in set operations but not in WHERE
```

**Fix:**

```sql
-- EXCEPT removes rows where ALL columns match (NULL = NULL for set operations).
-- For comparing tables where NULL values should be treated as equal to NULL:
-- the behaviour is already correct — no fix needed for that case.

-- The actionable fix is for the "unchanged rows" use case:
-- To find rows that exist in source but NOT in target (for data reconciliation):
SELECT s.txn_id, s.amount, s.status
FROM source_transactions s
WHERE NOT EXISTS (
    SELECT 1 FROM dwh_transactions d
    WHERE d.txn_id = s.txn_id
      AND COALESCE(d.amount, -999) = COALESCE(s.amount, -999)  -- treat NULL as equal
      AND COALESCE(d.status, '') = COALESCE(s.status, '')
);
-- COALESCE converts NULLs to sentinel values so NULL = NULL comparison works in WHERE
-- This is more explicit than EXCEPT and allows column-level control of NULL handling
```

#### Edge 21-C: Column count / type mismatch in UNION

**Problem:**

```sql
-- BREAKS: different number of columns
SELECT txn_id, amount FROM transactions_2024
UNION ALL
SELECT txn_id, amount, status FROM transactions_2025;  -- ERROR: different column count

-- Implicit type widening — may work but lose precision:
SELECT txn_id, amount::DECIMAL(10,2) FROM old_transactions
UNION ALL
SELECT txn_id, amount::FLOAT FROM new_transactions;
-- Result column is FLOAT (wider type wins) → old transactions lose decimal precision
```

**Fix — CAST both sides to the same explicit type before UNION:**

```sql

---

### At Scale

#### Failure Mechanism

`UNION` (distinct) on 800M rows:

- Requires hashing ALL rows to detect duplicates: O(N) hash table in memory
- For cross-dataset reconciliation (EXCEPT): sorts both datasets to find differences: O(N log N)
- `UNION ALL` has no dedup cost — only network transfer (still expensive at scale)

#### Code-Level Fix

```sql
-- BEFORE: UNION reconciliation across two 400M row tables
SELECT txn_id FROM source_transactions   -- 400M rows
EXCEPT
SELECT txn_id FROM dwh_transactions;     -- 400M rows
-- Requires sorting both 400M row sets and comparing: O(N log N) × 2

-- FIX 1: Use EXISTS-based reconciliation (can use indexes/partition pruning)
SELECT txn_id FROM source_transactions s
WHERE NOT EXISTS (
    SELECT 1 FROM dwh_transactions d WHERE d.txn_id = s.txn_id
    AND d.txn_date = s.txn_date   -- partition-prunable predicate
);
-- With partition pruning on txn_date: reads only matching date partitions in DWH

-- FIX 2: For large UNION ALL (combining N data sources), materialize the combined table
-- Rather than UNION ALL at query time, run the UNION ALL at ETL time:
INSERT INTO combined_transactions
SELECT *, 'source_a' AS source FROM source_a_transactions WHERE processed_date = CURRENT_DATE
UNION ALL
SELECT *, 'source_b' AS source FROM source_b_transactions WHERE processed_date = CURRENT_DATE;
-- Query: SELECT * FROM combined_transactions WHERE source = 'source_a' AND txn_date = :d
-- No UNION ALL at query time

-- FIX 3: Bloom filter-based set membership test (approximate but 1000× faster)
-- "Does this transaction exist in the DWH?" — approximate answer via bloom filter:
-- Build a bloom filter over dwh_transactions.txn_id (once per day)
-- Query against the bloom filter (in-memory, sub-millisecond per lookup)
-- False positive rate: 0.1% (configurable); false negative rate: 0%
```

#### System-Level Fix

```sql
-- MERGE is more efficient than EXCEPT + INSERT for reconciliation:
MERGE INTO dwh_transactions t
USING source_transactions s ON t.txn_id = s.txn_id
WHEN NOT MATCHED THEN INSERT *;
-- Delta: uses bloom filter + data skipping to find matching rows
-- Much faster than EXCEPT on large tables

ALTER TABLE source_transactions ENABLE CHANGE_TRACKING;
-- Instead of EXCEPT to find new rows, use change tracking stream (like Delta CDF)
-- Only process changed rows (inserts, updates, deletes) since last sync
---

---


