<!-- Part of sql-patterns: Data Quality Patterns -->
<!-- Source: sql_patterns.md lines 8868–9153 -->

## 20. Data Quality Patterns

### What it solves

Detect and quantify data quality issues: nulls, duplicates, referential integrity violations, range violations, format issues.

### Keywords to spot

> "data quality", "completeness", "null check", "duplicate detection",
> "referential integrity", "orphan records", "out-of-range",
> "schema drift", "stale data", "freshness",
> "invalid values", "anomaly detection", "data contract", "SLA breach",
> "volume drop", "unexpected nulls", "cardinality check",
> "format validation", "uniqueness constraint", "pipeline health"

### Business Context

- **Any domain:** Null/completeness checks before loading to a warehouse or reporting layer; row count validation after each ETL step (volume anomaly = pipeline failure signal)
- **Fintech:** Validate every trade references a valid user_id (referential integrity); flag negative amounts or future-dated transactions; detect duplicate trade_ids from exchange feed retries
- **E-commerce:** Detect orders with missing shipping addresses or zero-price line items before invoicing; validate all product_ids in order_items exist in the products catalogue
- **Data Engineering:** Volume anomaly detection — row count drops >20% vs prior day signals a broken upstream pipeline; freshness checks (no data in last 2 hours = page on-call); schema drift detection (new column appeared, type changed)
- **Healthcare:** Referential integrity — every claim must reference a valid patient and provider; check that lab result values fall within physiologically plausible ranges
- **Compliance/Finance:** Every transaction must have a non-null counterparty; all amounts must sum to zero within a settlement batch (double-entry bookkeeping validation)

### Boilerplate — Null and completeness checks

```sql
-- Count nulls per column
SELECT
    COUNT(*)                                     AS total_rows,
    SUM(CASE WHEN trade_id    IS NULL THEN 1 ELSE 0 END) AS null_trade_id,
    SUM(CASE WHEN user_id     IS NULL THEN 1 ELSE 0 END) AS null_user_id,
    SUM(CASE WHEN trade_amount IS NULL THEN 1 ELSE 0 END) AS null_amount,
    SUM(CASE WHEN executed_at  IS NULL THEN 1 ELSE 0 END) AS null_timestamp,
    -- Completeness %
    ROUND(SUM(CASE WHEN trade_amount IS NOT NULL THEN 1 ELSE 0 END) * 100.0 / COUNT(*), 2) AS amount_completeness_pct
FROM trades;
```

### Boilerplate — Duplicate detection

```sql
-- Find duplicate trade_ids
SELECT trade_id, COUNT(*) AS occurrences
FROM trades
GROUP BY trade_id
HAVING COUNT(*) > 1;

-- Find fully duplicate rows
SELECT *, COUNT(*) AS cnt
FROM trades
GROUP BY trade_id, user_id, trading_pair, trade_amount, executed_at
HAVING COUNT(*) > 1;
```

### Boilerplate — Referential integrity

```sql
-- Orphan trades: trade references user_id that doesn't exist in users table
SELECT t.trade_id, t.user_id
FROM trades t
LEFT JOIN users u ON t.user_id = u.user_id
WHERE u.user_id IS NULL;
```

### Boilerplate — Range / boundary checks

```sql
SELECT
    COUNT(CASE WHEN trade_amount <= 0          THEN 1 END) AS negative_or_zero_amount,
    COUNT(CASE WHEN trade_amount > 10000000    THEN 1 END) AS suspicious_large_amount,
    COUNT(CASE WHEN executed_at > CURRENT_TIMESTAMP THEN 1 END) AS future_dated_trades,
    COUNT(CASE WHEN executed_at < '2018-01-01' THEN 1 END) AS too_old_trades
FROM trades;
```

### Boilerplate — Freshness check

```sql
-- Check if the latest record is stale (no data in last 1 hour)
SELECT
    MAX(ingested_at)                                        AS latest_ingestion,
    CASE
        THEN 'STALE' ELSE 'FRESH'
    END AS freshness_status
FROM raw_trades;
```

### Edge Cases

#### Edge 20-A: Implicit type coercion causes wrong comparisons

**Problem:**

```sql
-- TRAP: comparing a VARCHAR column to a numeric literal
-- WHERE user_id = 12345
-- If user_id is VARCHAR('12345'), the engine may:
-- A) Cast the VARCHAR to INT: '12345' → 12345 → comparison works for this row
-- B) Cast the INT to VARCHAR: 12345 → '12345' → works
-- C) Fail to use an index (scan instead)
-- D) Silently cast '12345 ' (with trailing space) differently

-- More dangerous: comparing VARCHAR account numbers
-- WHERE account_id = 007  -- numeric 7, but account_id = '007' (leading zeros!)
-- Implicit cast: '007' → 7 OR 007 → '7' → MISMATCH → row not found!
```

**Fix — always match types explicitly:**

```sql
WHERE account_id = '007'  -- quoted string literal for VARCHAR column
WHERE user_id = CAST('12345' AS INT)  -- explicit cast if needed

-- Detection: run EXPLAIN to check if a type cast appears in the query plan
```

#### Edge 20-B: Duplicate primary keys in dimension tables fan out fact table joins

**Problem:**

```sql
-- dim_products should have one row per product_id (primary key)
-- Due to a data pipeline bug, it has duplicates

-- Diagnostic:
SELECT product_id, COUNT(*) AS cnt FROM dim_products GROUP BY product_id HAVING cnt > 1;

-- If this returns rows, every fact-to-dim join using product_id will FAN OUT:
SELECT f.order_id, f.amount, d.product_name, d.category
FROM fact_orders f
JOIN dim_products d ON f.product_id = d.product_id;
-- If dim_products has 3 rows for product_id=P123 → each order for P123 appears 3 times
-- SUM(f.amount) will be 3× the correct value — silent wrong result

-- Detection in the join itself:
WITH join_result AS (
    SELECT f.order_id, f.amount, COUNT(*) AS join_count
    FROM fact_orders f
    JOIN dim_products d ON f.product_id = d.product_id
    GROUP BY f.order_id, f.amount
)
SELECT * FROM join_result WHERE join_count > 1;  -- these orders fanned out
```

**Fix:**

```sql
-- Step 1: detect duplicates in the dimension before joining:
SELECT product_id, COUNT(*) AS cnt
FROM dim_products
GROUP BY product_id
HAVING cnt > 1;
-- If this returns rows, fix at the source before querying

-- Step 2: if you cannot fix the source, dedup the dimension inline:
WITH dim_deduped AS (
    SELECT *,
        ROW_NUMBER() OVER (PARTITION BY product_id ORDER BY updated_at DESC) AS rn
    FROM dim_products
)
SELECT f.order_id, f.amount, d.product_name, d.category
FROM fact_orders f
JOIN dim_deduped d ON f.product_id = d.product_id AND d.rn = 1;
-- Exactly one dim row per product_id → no fan-out → correct SUM(amount)

-- Step 3: add a data quality assertion in dbt or your pipeline:
-- assert: SELECT COUNT(*) FROM dim_products GROUP BY product_id HAVING COUNT(*) > 1 → 0 rows
-- Fail the pipeline if duplicates are detected at load time
```

#### Edge 20-C: Decimal precision loss in FLOAT columns

**Problem:**

```sql
-- FLOAT and DOUBLE are approximate (IEEE 754) — they cannot represent all decimals exactly
-- Storing money amounts as FLOAT is a common and dangerous mistake

-- Example: UPI transaction amounts stored as FLOAT
SELECT 0.1 + 0.2;          -- Returns 0.30000000000000004 in FLOAT
SELECT 1000000.01 + 0.01;  -- May lose the 0.01 entirely for large FLOAT values
```

**Fix — always use DECIMAL(p, s) for monetary amounts:**

```sql
-- FIX: always use DECIMAL(p, s) for monetary amounts:
amount DECIMAL(15, 2)   -- up to 13 digits before decimal, exactly 2 after
-- DECIMAL is exact arithmetic — 0.1 + 0.2 = 0.3 exactly

-- Detection:
SELECT amount, ROUND(amount, 2), amount - ROUND(amount, 2) AS precision_error
FROM transactions
WHERE ABS(amount - ROUND(amount, 2)) > 0.000001;  -- rows where float imprecision shows
---

### At Scale

#### Failure Mechanism

Running a comprehensive NULL audit on an 800M row table:

```sql
SELECT COUNT(*) - COUNT(col1), COUNT(*) - COUNT(col2), ...  -- 20 columns
FROM transactions;
```

This is actually efficient (single pass). The real scale problems are:

1. **Row-level validation** (e.g., `WHERE amount != ROUND(amount, 2)`) requires a full scan with a computed predicate — no index/partition pruning
2. **Cross-table consistency checks** (e.g., "every transaction must have a matching user") require large JOINs
3. **Running data quality checks on every query execution** in production — thousands of scans per hour

#### Code-Level Fix

```sql
-- FIX 1: Run DQ checks on samples, not full tables, for exploration
SELECT COUNT(*) - COUNT(amount) AS null_amount_count,
    ROUND(100.0 * (COUNT(*) - COUNT(amount)) / COUNT(*), 4) AS null_pct
FROM transactions
TABLESAMPLE (1 PERCENT);   -- scan 1% of data → 8M rows instead of 800M
-- For NULL rates: 1% sample gives 0.01% confidence interval (accurate enough for DQ alerting)

-- FIX 2: Push DQ validation to write time (not query time)
ALTER TABLE transactions ADD CONSTRAINT amount_positive CHECK (amount > 0);
ALTER TABLE transactions ADD CONSTRAINT txn_id_not_null CHECK (txn_id IS NOT NULL);
-- These constraints run at write time (INSERT/MERGE) — zero DQ query overhead at read time
-- Failed constraint → row rejected at ingest, logged in Delta transaction log

-- FIX 3: For large cross-table consistency: run as overnight batch, not interactive query
-- Store results in a dq_results table; dashboard reads dq_results, not raw tables
CREATE TABLE dq_results (
    check_name   VARCHAR(100),
    run_date     DATE,
    failed_count BIGINT,
    pass_rate    DECIMAL(5,4)
);
-- Populate nightly: INSERT INTO dq_results SELECT 'null_amount', CURRENT_DATE, ...
-- Query: SELECT * FROM dq_results WHERE run_date = CURRENT_DATE  -- instant
```

#### System-Level Fix

```sql
-- dbt tests run at ETL time (not query time):
-- schema.yml:
-- - name: transactions
--   columns:
--     - name: txn_id
--       tests: [not_null, unique]
--     - name: amount
--       tests: [not_null, positive_values]
-- dbt runs these tests after each model build — failures block downstream models

-- Run data quality checks as a pipeline step, not inside every production query.
-- Store results in metadata tables so failures can block downstream loads.

CREATE TABLE dq_results (
    check_name    VARCHAR(100),
    checked_at    TIMESTAMP,
    failed_count  BIGINT
);
---

---

