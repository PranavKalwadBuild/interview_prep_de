<!-- sql-patterns: Edge Cases Part 2 + At Scale — JOINs -->

# Edge Cases Part 2 + At Scale — JOINs

## Why joins break at scale

Joins are where row counts unexpectedly grow, estimates drift, and memory pressure appears. The SQL may be logically correct while the physical work is much larger than expected.

## Failure Mechanism

```sql
SELECT
    t.txn_id,
    u.segment
FROM transactions t
JOIN users u
    ON t.user_id = u.user_id;
```

If both inputs are large, the database must match rows by `user_id`. When the join key is not selective, not indexed, or badly skewed, the join can dominate the whole query.

## Code-Level Fix

Filter, project, and validate cardinality before the join.

```sql
WITH scoped_transactions AS (
    SELECT txn_id, user_id, amount
    FROM transactions
    WHERE txn_date >= DATE '2025-01-01'
      AND txn_date <  DATE '2025-02-01'
),
deduped_users AS (
    SELECT user_id, MAX(segment) AS segment
    FROM users
    GROUP BY user_id
)
SELECT
    t.txn_id,
    u.segment
FROM scoped_transactions t
LEFT JOIN deduped_users u
    ON t.user_id = u.user_id;
```

## System-Level Fix

- Ensure the dimension join key is unique.
- Add access paths on repeated large join keys.
- Pre-aggregate detail tables before joining when detail is not needed.
- Maintain denormalized reporting tables for extremely common joins.
- Track key skew so one dominant value does not control runtime.

## Gotchas

- A `LEFT JOIN` followed by `WHERE right_table.col = ...` becomes an inner join.
- A many-to-many join multiplies rows even when every individual key exists.
- `COUNT(DISTINCT ...)` after a fan-out can hide the multiplication instead of fixing it.
- Small sample data rarely shows production skew.

