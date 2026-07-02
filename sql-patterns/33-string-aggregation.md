<!-- sql-patterns: String Aggregation -->

# String Aggregation

## What it solves

Concatenate multiple row values into a single delimited string within a group.

## Keywords to spot

> "list of", "comma-separated", "all values in a group as one string",
> "concatenate per group", "combine into one", "collect all",
> "tags", "labels", "pipe-delimited", "audit list"

## Business Context

- **Fintech:** List trading pairs per user; concatenate KYC document types into an audit field.
- **E-commerce:** Show all product tags per SKU; list order IDs per customer for support.
- **SaaS:** Summarize roles, enabled features, or monthly usage categories per account.
- **Data Quality:** Aggregate failed validation rule names per record into one diagnostic field.

## ANSI-first pattern

Modern SQL defines `LISTAGG` for ordered string aggregation.

```sql
SELECT
    user_id,
    LISTAGG(trading_pair, ', ')
        WITHIN GROUP (ORDER BY trading_pair) AS pairs_traded
FROM trades
GROUP BY user_id;
```

If duplicates matter, decide that explicitly before aggregation.

```sql
WITH distinct_pairs AS (
    SELECT DISTINCT user_id, trading_pair
    FROM trades
)
SELECT
    user_id,
    LISTAGG(trading_pair, ', ')
        WITHIN GROUP (ORDER BY trading_pair) AS pairs_traded
FROM distinct_pairs
GROUP BY user_id;
```

## PostgreSQL fallback

```sql
SELECT
    user_id,
    STRING_AGG(trading_pair, ', ' ORDER BY trading_pair) AS pairs_traded
FROM (
    SELECT DISTINCT user_id, trading_pair
    FROM trades
) d
GROUP BY user_id;
```

## MySQL fallback

```sql
SELECT
    user_id,
    GROUP_CONCAT(trading_pair ORDER BY trading_pair SEPARATOR ', ') AS pairs_traded
FROM (
    SELECT DISTINCT user_id, trading_pair
    FROM trades
) d
GROUP BY user_id;
```

## Gotchas

- String aggregation is not a relational shape. It is best for display, exports, and compact diagnostics, not for downstream joins.
- Ordering is not optional. Without `ORDER BY`, the same group can produce a different string order after plan changes.
- Duplicate handling belongs before aggregation. `DISTINCT` inside the aggregate is not portable enough to be the default teaching pattern.
- `NULL` input values are usually ignored. If missing values must appear, convert them first with `COALESCE`.

## Edge Cases

### Edge 19-A: Aggregated string becomes too large

**Problem:**

```sql
SELECT
    merchant_id,
    LISTAGG(CAST(txn_id AS VARCHAR(40)), ', ')
        WITHIN GROUP (ORDER BY executed_at) AS txn_ids
FROM transactions
GROUP BY merchant_id;
```

This can create a very large string for high-volume merchants. Even when the database allows the result, it can consume memory, slow the query, and produce an output no downstream user can read.

**Fix: aggregate only the useful subset**

```sql
WITH ranked AS (
    SELECT
        merchant_id,
        txn_id,
        executed_at,
        ROW_NUMBER() OVER (
            PARTITION BY merchant_id
            ORDER BY executed_at DESC, txn_id DESC
        ) AS rn
    FROM transactions
)
SELECT
    merchant_id,
    LISTAGG(CAST(txn_id AS VARCHAR(40)), ', ')
        WITHIN GROUP (ORDER BY executed_at DESC, txn_id DESC) AS recent_txn_ids
FROM ranked
WHERE rn <= 100
GROUP BY merchant_id;
```

**MySQL note:** `GROUP_CONCAT` has a configurable maximum length. If you must use it for large groups, set and monitor `group_concat_max_len`, and treat near-limit results as suspicious.

```sql
SET SESSION group_concat_max_len = 1000000;
```

### Edge 19-B: Delimiter collisions

**Problem:** If values contain the delimiter, the aggregated string is ambiguous.

```sql
-- These two source sets can produce confusing strings:
-- ('A', 'B,C') and ('A,B', 'C')
```

**Fix:** Use a delimiter that cannot occur in the source, escape values before aggregation, or do not serialize the values into a string. For analytics, keep one row per value.

### Edge 19-C: NULL values disappear

```sql
SELECT
    order_id,
    LISTAGG(COALESCE(promo_code, '<missing>'), ', ')
        WITHIN GROUP (ORDER BY promo_code) AS promo_codes
FROM order_promotions
GROUP BY order_id;
```

Use this only when the placeholder has a clear business meaning. Otherwise, report missing counts separately:

```sql
SELECT
    order_id,
    COUNT(*) AS rows_seen,
    COUNT(promo_code) AS non_null_promo_codes
FROM order_promotions
GROUP BY order_id;
```

## At Scale

String aggregation can become a memory hotspot because every value in a group must be collected before one output row is emitted.

**Better modeling options**

- Keep the many-to-one relationship in a child table and query it when needed.
- Store a bounded summary such as the first 100 ordered values, not the complete history.
- For counts, use `COUNT`, `COUNT(DISTINCT ...)`, or pre-aggregated metrics instead of serialized IDs.
- For display, build the string close to the consuming application after filtering to a human-sized list.

