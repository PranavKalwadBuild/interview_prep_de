<!-- sql-patterns: Physical Design Examples and Skew -->

# 35.6 Physical Design Examples

## Example 1: Event table queried by date

```sql
SELECT COUNT(*)
FROM events
WHERE event_date >= DATE '2025-01-01'
  AND event_date <  DATE '2025-01-08';
```

**Good design:** Partition by `event_date`.

**Why:** The query naturally selects a contiguous time slice. Date partitioning lets the optimizer skip unrelated periods.

**Edge case:** If most queries scan full months, monthly partitions may be better than daily partitions. If most queries scan one or two days, daily partitions are usually better.

## Example 2: Account ledger queried by account and time

```sql
SELECT *
FROM ledger_entries
WHERE account_id = 101
  AND posted_at >= TIMESTAMP '2025-01-01 00:00:00'
  AND posted_at <  TIMESTAMP '2025-02-01 00:00:00'
ORDER BY posted_at;
```

**Good design:** Access path on `(account_id, posted_at)` or partition by period plus an index/order key on account.

**Why:** The query is both selective by account and ordered by time.

**Gotcha:** `(posted_at, account_id)` is better for broad date scans. `(account_id, posted_at)` is better for single-account timelines.

## Example 3: Large fact-to-dimension join

```sql
SELECT
    f.order_id,
    d.customer_segment
FROM fact_orders f
INNER JOIN dim_customers d
    ON f.customer_id = d.customer_id;
```

**Good design:** Ensure `dim_customers.customer_id` is unique and indexed. For very large fact tables, also use an access path on `fact_orders.customer_id` if joins by customer are frequent.

**Gotcha:** Indexing the dimension only may not be enough when the fact table is huge and the query has no selective filter.

## Example 4: Skewed key

```sql
SELECT merchant_id, COUNT(*)
FROM transactions
GROUP BY merchant_id;
```

If one merchant owns 40% of all rows, any design based only on `merchant_id` will create a hotspot.

**Fix options**

- Pre-aggregate by `(merchant_id, event_date)` and roll up later.
- Add a second key such as date when queries allow it.
- Split unusually large entities into separate processing batches.
- Track top-key skew as a data quality metric.

## Example 5: Function-wrapped predicate

```sql
-- Risky: may bypass partition pruning or index usage.
WHERE CAST(event_timestamp AS DATE) = DATE '2025-01-15'
```

Prefer:

```sql
WHERE event_timestamp >= TIMESTAMP '2025-01-15 00:00:00'
  AND event_timestamp <  TIMESTAMP '2025-01-16 00:00:00'
```

## Verification Queries

Use `EXPLAIN` to verify that the intended access path is used.

**PostgreSQL**

```sql
EXPLAIN
SELECT COUNT(*)
FROM events
WHERE event_date >= DATE '2025-01-01'
  AND event_date <  DATE '2025-01-08';
```

**MySQL**

```sql
EXPLAIN
SELECT COUNT(*)
FROM events
WHERE event_date >= DATE '2025-01-01'
  AND event_date <  DATE '2025-01-08';
```

## Gotchas

- `EXPLAIN` estimates are not proof of runtime performance. Use actual execution metrics when available.
- A stale statistics estimate can make a good key look unused.
- If a predicate is not selective, a full scan may be the correct plan.

