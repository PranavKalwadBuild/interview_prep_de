<!-- Part of sql-patterns: Ordering, Distribution, and Key Choice -->

## 35.5 Ordering, Clustering, and Distribution

### Ordering / clustering

Ordering stores nearby key values near each other physically. It helps range predicates and ordered window queries because the database can read fewer row ranges or sort less data.

```sql
-- Query shape that benefits from ordering by (event_date, user_id)
SELECT *
FROM transactions
WHERE event_date >= DATE '2025-01-01'
  AND event_date <  DATE '2025-02-01'
  AND user_id = 42;
```

### Compound key order matters

For a compound access path on `(event_date, user_id, status)`, predicates on the leftmost columns help the most.

| Predicate | Likely benefit |
|---|---|
| `event_date = ...` | Strong |
| `event_date = ... AND user_id = ...` | Stronger |
| `user_id = ...` without `event_date` | Weaker |
| `status = ...` only | Usually weak |

### Index fallback examples

ANSI SQL does not standardize physical indexing syntax. Use PostgreSQL/MySQL forms when you need executable examples.

**PostgreSQL**

```sql
CREATE INDEX idx_transactions_event_user
    ON transactions (event_date, user_id);
```

**MySQL**

```sql
CREATE INDEX idx_transactions_event_user
    ON transactions (event_date, user_id);
```

### Distribution / bucketing

Distribution decides where rows live in a parallel execution system. The portable concept is simple: rows with the same join key should be co-located when large joins are frequent.

```sql
SELECT
    t.txn_id,
    u.user_segment
FROM transactions t
INNER JOIN users u
    ON t.user_id = u.user_id;
```

If both large tables are physically organized by `user_id`, the join can avoid moving as much data. In single-node systems this is mostly an indexing concern; in parallel systems it is also a data-placement concern.

### Choosing columns

| Query pattern | Good physical design |
|---|---|
| Most queries filter by date range | Partition by date |
| Date range plus user lookup | Partition by date, index/order by user |
| Large equality joins | Index or distribute by join key |
| Frequent ordered window by account/date | Access path on `(account_id, event_date)` |
| Rare ad hoc filters | Do not over-design; measure first |

### Gotchas

- A key that helps one query can hurt another by increasing write cost and maintenance.
- Low-cardinality leading columns often produce skew; high-cardinality leading columns may reduce pruning.
- Physical design must match the most common expensive predicates, not every possible predicate.
- If query filters use functions on the key, the access path may not be used.

