<!-- sql-patterns: Edge Case Detection — SQL Execution Order + Core Pattern Edge Cases (Part 1) -->

# Edge Case Detection — Where and How Queries Break

Every pattern in this guide has failure modes that are silent — no error, wrong results, reported with confidence. This section catalogs them by pattern with the exact input data that triggers the break, the engine-level explanation, and the fix. All examples use fintech/banking context (Slice-type workloads).

---

## 33-0. SQL Order of Execution — Edge Cases

### Edge 0-A: Using a SELECT alias in WHERE

**Problem:**

```sql
-- BREAKS: alias 'fee' computed in SELECT, which runs AFTER WHERE
SELECT txn_amount * 0.02 AS fee, user_id
FROM transactions
WHERE fee > 100;           -- ERROR: column "fee" does not exist

-- Why: WHERE runs at step 2; SELECT at step 5. 'fee' doesn't exist yet.
```

**Fix A — repeat the expression:**

```sql
WHERE txn_amount * 0.02 > 100
```

**Fix B — wrap in CTE (CTE runs before main SELECT):**

```sql
WITH fees AS (SELECT *, txn_amount * 0.02 AS fee FROM transactions)
SELECT * FROM fees WHERE fee > 100;
```

### Edge 0-B: Filtering on a window function result in WHERE

**Problem:**

```sql
-- BREAKS: window functions execute in SELECT (step 5), WHERE runs at step 2
SELECT *, ROW_NUMBER() OVER (PARTITION BY user_id ORDER BY executed_at DESC) AS rn
FROM trades
WHERE rn = 1;              -- ERROR: column "rn" does not exist
```

**Fix — wrap in CTE:**


### Edge 0-C: Aggregate in WHERE instead of HAVING

**Problem:**

```sql
-- BREAKS: COUNT(*) is an aggregate; aggregates not allowed in WHERE
SELECT user_id, COUNT(*) AS txn_count
FROM transactions
WHERE COUNT(*) > 10        -- ERROR: aggregate functions not allowed in WHERE
GROUP BY user_id;
```

**Fix — move to HAVING:**

```sql
SELECT user_id, COUNT(*) AS txn_count
FROM transactions
GROUP BY user_id
HAVING COUNT(*) > 10;
```

### Edge 0-D: GROUP BY alias (engine-specific silently wrong behavior)

**Problem:**


**Fix — repeat the full expression:**

```sql
GROUP BY DATE_TRUNC('month', txn_date)

-- Or use positional grouping (both safe):
GROUP BY 1
```

### Edge 0-E: LEFT JOIN silently converted to INNER JOIN by WHERE filter

**Problem:**

```sql
-- BREAKS: WHERE on right-table column rejects NULL rows → LEFT JOIN becomes INNER JOIN
SELECT l.loan_id, l.amount, r.repaid_amount
FROM loans l
LEFT JOIN repayments r ON l.loan_id = r.loan_id
WHERE r.repaid_amount > 0;    -- NULL repaid_amount (unrepaid loans) = UNKNOWN → excluded
```

**Fix A — keep condition in ON clause:**

```sql
LEFT JOIN repayments r ON l.loan_id = r.loan_id AND r.repaid_amount > 0
-- Unrepaid loans still appear; repaid_amount is just NULL when condition fails
```

**Fix B — include NULLs explicitly in WHERE:**

```sql
WHERE r.repaid_amount > 0 OR r.repaid_amount IS NULL
```


