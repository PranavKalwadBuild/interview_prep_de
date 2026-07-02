<!-- sql-patterns: Physical Design Anti-Patterns and Cheat Sheet -->

# 35.7 Physical Design Anti-Patterns

## Anti-pattern 1: Partitioning by a unique identifier

```sql
-- Usually bad:
-- one partition or tiny physical group per user_id / txn_id
```

This creates too many tiny partitions and high planning overhead. Use an index for point lookups.

## Anti-pattern 2: Filtering with functions on key columns

```sql
WHERE EXTRACT(YEAR FROM event_date) = 2025
```

Prefer:

```sql
WHERE event_date >= DATE '2025-01-01'
  AND event_date <  DATE '2026-01-01'
```

## Anti-pattern 3: Designing for every query

Too many indexes, partitions, or ordering keys slow writes and increase maintenance. Optimize for the repeated expensive access patterns.

## Anti-pattern 4: Ignoring skew

A technically valid key can still be bad if one value dominates the data.

```sql
SELECT merchant_id, COUNT(*) AS row_count
FROM transactions
GROUP BY merchant_id
ORDER BY row_count DESC
FETCH FIRST 20 ROWS ONLY;
```

## PostgreSQL syntax reference

```sql
CREATE TABLE transactions (
    txn_id      BIGINT,
    event_date  DATE,
    user_id     BIGINT,
    amount      DECIMAL(18,2)
) PARTITION BY RANGE (event_date);

CREATE TABLE transactions_2025_01 PARTITION OF transactions
    FOR VALUES FROM ('2025-01-01') TO ('2025-02-01');

CREATE INDEX idx_transactions_user_date
    ON transactions (user_id, event_date);
```

## MySQL syntax reference

```sql
CREATE TABLE transactions (
    txn_id      BIGINT,
    event_date  DATE,
    user_id     BIGINT,
    amount      DECIMAL(18,2),
    INDEX idx_transactions_user_date (user_id, event_date)
)
PARTITION BY RANGE COLUMNS (event_date) (
    PARTITION p202501 VALUES LESS THAN ('2025-02-01'),
    PARTITION p202502 VALUES LESS THAN ('2025-03-01')
);
```

## Decision Cheat Sheet

| Access pattern | Recommended design |
|---|---|
| Always filter by date | Partition by date |
| Filter by date and account | Partition by date, index/order by account |
| Point lookup by ID | Index the ID |
| Large equality join | Index or co-locate by join key |
| Skewed key | Add time, pre-aggregate, or split large keys |
| Free-text search | Use a purpose-built search strategy outside ordinary partitioning |

## Verification Checklist

- Does `EXPLAIN` show a selective access path or partition pruning?
- Are estimated rows close to actual rows?
- Are the largest key values much larger than the median?
- Do write and backfill costs remain acceptable?
- Are date predicates written as half-open ranges?

