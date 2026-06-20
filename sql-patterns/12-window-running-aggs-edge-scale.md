<!-- Part of sql-patterns: Running Aggregates — Edge Cases and Scale -->

## Running Aggregates — Edge Cases and Scale

Running aggregates are simple at small scale and expensive at large scale because every row depends on an ordered prefix of rows.

### Edge 1: Non-unique ordering creates unstable totals

**Problem:**

```sql
SELECT
    user_id,
    txn_time,
    amount,
    SUM(amount) OVER (
        PARTITION BY user_id
        ORDER BY txn_time
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ) AS running_amount
FROM transactions;
```

If two rows have the same `txn_time`, their relative order is not guaranteed. The final total is the same, but intermediate running totals can flip.

**Fix: add a deterministic tiebreaker**

```sql
ORDER BY txn_time, txn_id
```

### Edge 2: `ROWS` and `RANGE` answer different questions

`ROWS 6 PRECEDING` means "the previous six physical rows." It is not the same as "the previous six calendar days" when dates are missing or duplicated.

Use `ROWS` for row-count windows. Use date predicates, date spines, or calendar joins for calendar windows.

### Edge 3: Large partitions dominate runtime

```sql
SUM(amount) OVER (
    PARTITION BY user_id
    ORDER BY txn_time, txn_id
    ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
) AS running_amount
```

If one user has millions of transactions, that user's partition becomes the bottleneck even if most users are small.

### Code-Level Fix

```sql
-- Reduce input before computing the running total.
WITH scoped AS (
    SELECT *
    FROM transactions
    WHERE txn_time >= TIMESTAMP '2025-01-01 00:00:00'
      AND txn_time <  TIMESTAMP '2025-02-01 00:00:00'
)
SELECT
    user_id,
    txn_time,
    txn_id,
    SUM(amount) OVER (
        PARTITION BY user_id
        ORDER BY txn_time, txn_id
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ) AS running_amount
FROM scoped;
```

### System-Level Fix

For frequently requested running totals, maintain snapshots.

```sql
CREATE TABLE daily_account_balances AS
SELECT
    account_id,
    balance_date,
    SUM(day_amount) OVER (
        PARTITION BY account_id
        ORDER BY balance_date
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ) AS end_of_day_balance
FROM account_daily_amounts;
```

Then detail queries only need to start from the latest snapshot and add recent events.

### Gotchas

- Running totals require deterministic ordering.
- Recomputing from the beginning of history is usually unnecessary.
- A date spine is safer than assuming every date exists in the fact table.
- Large single-key partitions need a special design, not just more SQL syntax.

