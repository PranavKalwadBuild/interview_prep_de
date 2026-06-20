<!-- Part of sql-patterns: Partitioning, Ordering, and Access Paths — Mental Model -->

## 35. Partitioning, Ordering, and Access Paths

> **Scope:** Platform-agnostic physical design concepts with ANSI-style SQL examples. PostgreSQL/MySQL syntax appears only where ANSI SQL has no common implementation.

### 35-0. Mental Model — What Problem Each Solves

| Design choice | Problem it solves | Physical effect |
|---|---|---|
| **Partitioning** | Avoid reading unrelated slices of a large table | Stores separate physical groups by range, list, or hash bucket |
| **Ordering / clustering** | Avoid scanning every row inside the selected slice | Keeps nearby values physically close so ranges can be skipped |
| **Indexing** | Speed selective lookups and joins | Maintains a separate search structure over one or more columns |
| **Distribution / bucketing** | Reduce movement for large joins in parallel systems | Places rows with the same key together |

These concepts are independent. A table can be partitioned by date, ordered by customer, and indexed by a transaction key.

```
Query:
  WHERE event_date = DATE '2025-01-15'
    AND user_id = 42

Without physical design:
  Read the full table.

With date partitioning:
  Read only the 2025-01-15 slice.

With ordering by user_id inside each date slice:
  Skip row ranges that cannot contain user_id = 42.

With an index on user_id:
  Use the search structure for point lookups or selective joins.
```

---

### 35-1. Partitioning Deep Dive

Partitioning splits a table into physical pieces based on a column expression. At query time, the optimizer can eliminate partitions that cannot satisfy the predicate. This is called partition pruning.

#### Range partitioning

Best for time-series data and ordered numeric ranges.

```sql
CREATE TABLE transactions (
    txn_id      BIGINT,
    user_id     BIGINT,
    amount      DECIMAL(18,2),
    event_date  DATE,
    status      VARCHAR(20)
);
```

Conceptually:

```
transactions_2025_q1: event_date >= 2025-01-01 and < 2025-04-01
transactions_2025_q2: event_date >= 2025-04-01 and < 2025-07-01
```

**PostgreSQL fallback**

```sql
CREATE TABLE transactions (
    txn_id      BIGINT,
    user_id     BIGINT,
    amount      DECIMAL(18,2),
    event_date  DATE,
    status      VARCHAR(20)
) PARTITION BY RANGE (event_date);

CREATE TABLE transactions_2025_q1 PARTITION OF transactions
    FOR VALUES FROM ('2025-01-01') TO ('2025-04-01');
```

**MySQL fallback**

```sql
CREATE TABLE transactions (
    txn_id      BIGINT,
    user_id     BIGINT,
    amount      DECIMAL(18,2),
    event_date  DATE,
    status      VARCHAR(20)
)
PARTITION BY RANGE COLUMNS (event_date) (
    PARTITION p2025q1 VALUES LESS THAN ('2025-04-01'),
    PARTITION p2025q2 VALUES LESS THAN ('2025-07-01')
);
```

#### List partitioning

Useful for low-cardinality values when queries commonly filter on one value or a small set of values.

```sql
-- Conceptual partition groups:
-- region IN ('NORTH', 'NORTHEAST')
-- region IN ('SOUTH', 'SOUTHEAST')
```

Use list partitioning only when the list is stable and business-owned. Free-form strings and fast-changing categories create operational pain.

#### Hash partitioning

Useful when no natural range exists and writes or reads need to be spread evenly.

```sql
-- Conceptual hash buckets:
-- bucket = hash(user_id) modulo 16
```

Hash partitioning helps distribution, but it does not help a date-range query unless the query also knows the hash bucket.

---

### 35-2. Partition Pruning

This form enables pruning:

```sql
SELECT SUM(amount)
FROM transactions
WHERE event_date >= DATE '2025-01-01'
  AND event_date <  DATE '2025-02-01';
```

This form often defeats pruning:

```sql
SELECT SUM(amount)
FROM transactions
WHERE EXTRACT(YEAR FROM event_date) = 2025;
```

**Why:** The optimizer can compare partition boundaries to literal ranges. Once the partition column is wrapped in a function, the engine may need to evaluate each row or each partition value before deciding.

### 35-3. Partition Granularity

```
Too coarse:
  Monthly partitions for queries that usually need one day.
  The query reads far more data than needed.

Too fine:
  Hourly partitions for years of data.
  Planning overhead and tiny partitions dominate runtime.

Usually reasonable:
  Daily partitions for high-volume event data.
  Monthly partitions for reporting tables queried by full month.
```

### 35-4. Cardinality Rules

| Column shape | Good partition key? | Why |
|---|---|---|
| Date over months/years | Yes | Natural pruning by reporting range |
| Tenant or region with stable small set | Sometimes | Works if most queries filter by it |
| User ID or transaction ID | Usually no | Too many tiny partitions |
| Status with 2-10 values | Usually no | Partitions become uneven and not selective |
| Free text | No | Unbounded, unstable, and hard to manage |

### Gotchas

- Partitioning is not indexing. It skips broad slices; it does not make every point lookup fast.
- Partition by columns used in `WHERE`, not columns merely displayed in `SELECT`.
- Composite partitioning is powerful but easy to overdo. Every extra dimension multiplies maintenance complexity.
- Backfills and late-arriving records must target the correct partition, or historical queries silently miss data.

