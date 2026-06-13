<!-- Part of sql-patterns: String Aggregation -->
<!-- Source: sql_patterns.md lines 8626–8867 -->

## 19. String Aggregation

### What it solves

Concatenate multiple row values into a single delimited string within a group.

### Keywords to spot

> "list of", "comma-separated", "all values in a group as one string",
> "concatenate per group", "array of", "combine into one",
> "collect all", "enumerate", "pipe-delimited", "joined values",
> "tags", "labels", "categories as a string", "semi-colon separated"

### Business Context

- **Fintech:** List all trading pairs a user has ever traded as a comma-separated string (profile feature); concatenate all KYC document types submitted per user into a single audit field
- **E-commerce:** Show all product tags per SKU for search indexing; list all order IDs per customer in one field for a customer service summary view; concatenate all discount codes applied per order
- **SaaS:** Comma-separated list of features used per account per month (usage summary email); list of all roles assigned to a user as a single string for permission audit
- **Data Quality:** Aggregate all error messages per pipeline run into one diagnostic string (alerting payload); collect all failed validation rule names per record into one column
- **Marketing:** Comma-separated list of campaign touchpoints per customer journey (attribution string); all UTM sources a user came from before converting

### Boilerplate

```

```sql
-- MySQL / BigQuery
SELECT
    user_id,
    GROUP_CONCAT(DISTINCT trading_pair ORDER BY trading_pair SEPARATOR ', ') AS pairs_traded
FROM trades
GROUP BY user_id;

-- PostgreSQL
SELECT
    user_id,
    STRING_AGG(DISTINCT trading_pair, ', ' ORDER BY trading_pair) AS pairs_traded
FROM trades
GROUP BY user_id;

-- Snowflake
SELECT
    user_id,
    LISTAGG(DISTINCT trading_pair, ', ') WITHIN GROUP (ORDER BY trading_pair) AS pairs_traded
FROM trades
GROUP BY user_id;

-- Standard array (BigQuery / Snowflake / Postgres)
SELECT
    user_id,
    ARRAY_AGG(DISTINCT trading_pair ORDER BY trading_pair) AS pairs_array
FROM trades
GROUP BY user_id;
```

### Gotchas

- `GROUP_CONCAT` has a default length limit in MySQL (1024 chars) — set `group_concat_max_len` if needed
- `DISTINCT` inside string aggregation is supported in most dialects but syntax varies
- Know which function your target DB uses — this is a common syntax trap in interviews

### Edge Cases

#### Edge 19-A: STRING_AGG result exceeds VARCHAR column length limit

**Problem:**

```sql
-- STRING_AGG('a', ', ') with 10,000 names → result can exceed 64KB
-- In Snowflake and BigQuery: TEXT/STRING is virtually unlimited → fine
-- In MySQL: GROUP_CONCAT has a default max length of 1,024 characters → silently truncates!

-- MySQL fix: increase the limit:
SET SESSION group_concat_max_len = 1000000;
SELECT GROUP_CONCAT(employee_name ORDER BY employee_name SEPARATOR ', ') FROM employees;

-- Or detect truncation: check if the result ends mid-word or doesn't match COUNT:
SELECT dept_id,
    GROUP_CONCAT(full_name SEPARATOR ',') AS names,
    LENGTH(GROUP_CONCAT(full_name SEPARATOR ',')) AS name_len,
    COUNT(*) AS emp_count
FROM employees
GROUP BY dept_id
HAVING LENGTH(GROUP_CONCAT(full_name SEPARATOR ',')) >= @@group_concat_max_len - 1;
-- These groups were likely truncated
```

**Fix:**

```sql
-- MySQL: increase SESSION limit for GROUP_CONCAT:
SET SESSION group_concat_max_len = 1000000;
SELECT GROUP_CONCAT(employee_name ORDER BY employee_name SEPARATOR ', ')
FROM employees
GROUP BY dept_id;

-- Detection of truncation in MySQL (catch rows where result was cut off):
SELECT dept_id,
    GROUP_CONCAT(full_name SEPARATOR ',') AS names,
    LENGTH(GROUP_CONCAT(full_name SEPARATOR ',')) AS name_len,
    COUNT(*) AS emp_count
FROM employees
GROUP BY dept_id
HAVING LENGTH(GROUP_CONCAT(full_name SEPARATOR ',')) >= @@group_concat_max_len - 1;
-- Rows here were likely silently truncated — raise an error or increase the limit

-- For Snowflake / BigQuery: STRING is unbounded; no limit change needed.
-- For large aggregations across all engines: prefer ARRAY_AGG over STRING_AGG
-- to avoid delimiter-parsing overhead on read:
SELECT dept_id,
    ARRAY_AGG(employee_name ORDER BY employee_name) AS name_array
FROM employees
GROUP BY dept_id;
```

#### Edge 19-B: ORDER BY inside STRING_AGG is not supported in all engines

**Problem:**

```sql
-- PostgreSQL / Snowflake / BigQuery: ORDER BY inside STRING_AGG is supported
STRING_AGG(full_name, ', ' ORDER BY full_name)

-- MySQL: ORDER BY inside GROUP_CONCAT IS supported:
GROUP_CONCAT(full_name ORDER BY full_name SEPARATOR ', ')

-- Spark SQL < 3.0: STRING_AGG does not support ORDER BY within the function
-- Use: collect_list() then array_join() and sort separately

-- SQLite: GROUP_CONCAT does NOT support ORDER BY
-- Fix: use a subquery that pre-orders the data:
SELECT dept_id,
    GROUP_CONCAT(full_name) AS names
FROM (SELECT dept_id, full_name FROM employees ORDER BY full_name)
GROUP BY dept_id;
-- SQLite GROUP_CONCAT preserves row order from the subquery
```

**Fix:**

```sql
-- PostgreSQL / Snowflake / BigQuery (supports ORDER BY in STRING_AGG):
SELECT dept_id,
    STRING_AGG(full_name, ', ' ORDER BY full_name) AS sorted_names
FROM employees GROUP BY dept_id;

-- MySQL (supports ORDER BY in GROUP_CONCAT):
SELECT dept_id,
    GROUP_CONCAT(full_name ORDER BY full_name SEPARATOR ', ') AS sorted_names
FROM employees GROUP BY dept_id;

-- SQLite (no ORDER BY in GROUP_CONCAT — use pre-sorted subquery):
SELECT dept_id,
    GROUP_CONCAT(full_name) AS sorted_names
FROM (SELECT dept_id, full_name FROM employees ORDER BY full_name)
GROUP BY dept_id;

-- Spark SQL (collect_list + array_join, sorted separately):
SELECT dept_id,
    ARRAY_JOIN(SORT_ARRAY(COLLECT_LIST(full_name)), ', ') AS sorted_names
FROM employees GROUP BY dept_id;
```

---

### At Scale

#### Failure Mechanism

`STRING_AGG(txn_id, ',')` on 800M transaction IDs:

- Requires collecting ALL values in a partition into memory before emitting the result
- A single partition with 1M values produces a VARCHAR result of ~10MB
- In Snowflake/BigQuery: practically unlimited string length; but memory per group is the issue
- In Redshift/MySQL: hard VARCHAR limits → silent truncation
- `GROUP_CONCAT` in MySQL with default 1024-byte limit: **silently truncates** at scale

#### Code-Level Fix

```sql

```sql
-- BEFORE: aggregate all transaction IDs per merchant — millions of IDs
SELECT merchant_id,
    STRING_AGG(txn_id::VARCHAR, ',') AS txn_ids  -- could be a 100MB string for busy merchants!
FROM transactions GROUP BY merchant_id;

-- FIX 1: Only aggregate what you need (add LIMIT hint — not standard, but avoid large aggs)
-- The root question: why do you need all 1M transaction IDs as a comma-separated string?
-- If for display: limit to the most recent N:
SELECT merchant_id,
    STRING_AGG(txn_id::VARCHAR, ',' ORDER BY executed_at DESC)
        WITHIN FIRST 100  -- PostgreSQL: hypothetical — use ROW_NUMBER workaround
FROM transactions;
-- Correct approach with ROW_NUMBER:
WITH recent AS (
    SELECT merchant_id, txn_id, executed_at,
        ROW_NUMBER() OVER (PARTITION BY merchant_id ORDER BY executed_at DESC) AS rn
    FROM transactions
)
SELECT merchant_id, STRING_AGG(txn_id::VARCHAR, ',' ORDER BY executed_at DESC) AS recent_txn_ids
FROM recent WHERE rn <= 100 GROUP BY merchant_id;

-- FIX 2: If you need all IDs, store as an ARRAY not a VARCHAR string
-- BigQuery / Snowflake / Databricks support native ARRAY types:
SELECT merchant_id,
    ARRAY_AGG(txn_id ORDER BY executed_at DESC) AS txn_id_array  -- BigQuery / DuckDB
FROM transactions GROUP BY merchant_id;
-- Arrays are more efficient than VARCHAR concatenation: no delimiter parsing on read

-- FIX 3: Use approximate set operations instead of collecting IDs
-- If you want "how many unique transactions per merchant": COUNT(DISTINCT) or HLL
-- If you want "does merchant M have transaction T": use a proper lookup table, not a string match
```

#### System-Level Fix

```sql
-- Avoid string aggregation at scale altogether — it is an anti-pattern for large data
-- Correct architecture: store the relationship in a proper table
CREATE TABLE merchant_transactions (
    merchant_id STRING,
    txn_id      STRING,
    executed_at TIMESTAMP
)
USING DELTA
PARTITIONED BY (DATE(executed_at))
TBLPROPERTIES ('delta.bloomFilter.columns' = 'merchant_id,txn_id');

-- Query "all transactions for merchant M in January":
SELECT txn_id FROM merchant_transactions
WHERE merchant_id = 'M001' AND executed_at >= '2024-01-01' AND executed_at < '2024-02-01';
-- Partition pruning (by date) + bloom filter (by merchant_id) → sub-second on billions of rows
-- No string aggregation needed
```

```sql

---

---

