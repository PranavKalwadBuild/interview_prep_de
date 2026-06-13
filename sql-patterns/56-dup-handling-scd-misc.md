<!-- Part of sql-patterns: Duplicate Handling — Funnel through Anti-Join (36-M to 36-S) -->
<!-- Source: sql_patterns.md lines 14686–14984 -->

### 36-M. Duplicates in Funnel Analysis

#### Problem — Duplicate funnel step events inflate conversion counts and rates

```sql
-- A user clicks "Add to Cart" twice (double-click). Both events land in the table.
-- Step 2 (Add to Cart) count = actual users × 2 → conversion rate from Step 1 to Step 2
-- appears > 100% (or is severely inflated).

WITH funnel AS (
    SELECT
        user_id,
        MAX(CASE WHEN event_type = 'page_view'   THEN 1 ELSE 0 END) AS step1,
        MAX(CASE WHEN event_type = 'add_to_cart' THEN 1 ELSE 0 END) AS step2,
        MAX(CASE WHEN event_type = 'checkout'    THEN 1 ELSE 0 END) AS step3,
        MAX(CASE WHEN event_type = 'purchase'    THEN 1 ELSE 0 END) AS step4
    FROM events
    GROUP BY user_id   -- MAX collapses duplicates: 1 OR 1 = 1; still 1 ✓
)
-- This pattern is already duplicate-resistant because MAX(0/1) is idempotent.
-- The problem occurs when using COUNT instead of MAX:

-- WRONG — COUNT inflates with duplicates:
SELECT
    COUNT(CASE WHEN event_type = 'add_to_cart' THEN 1 END) AS step2_events
FROM events;
-- Two 'add_to_cart' rows for same user = step2_events = 2 (should be 1 user)

-- CORRECT — always use COUNT DISTINCT on user_id for funnel steps, not COUNT(*):
SELECT
    COUNT(DISTINCT CASE WHEN event_type = 'page_view'   THEN user_id END) AS step1_users,
    COUNT(DISTINCT CASE WHEN event_type = 'add_to_cart' THEN user_id END) AS step2_users,
    COUNT(DISTINCT CASE WHEN event_type = 'checkout'    THEN user_id END) AS step3_users,
    COUNT(DISTINCT CASE WHEN event_type = 'purchase'    THEN user_id END) AS step4_users
FROM events;
-- COUNT DISTINCT on user_id is inherently duplicate-resistant.

-- For ordered funnel (user must complete steps in sequence), dedup by step first:
WITH step_events AS (
    SELECT DISTINCT user_id, event_type, DATE_TRUNC('day', event_ts) AS event_day
    FROM events     -- deduplicate per user per step per day
)
...
```

---

### 36-N. Duplicates in SCD Type 2

#### Problem — Multiple active rows for the same entity

```sql
-- SCD2 convention: exactly one row per entity with valid_to IS NULL (= current record).
-- A pipeline retry inserts the same new record twice → two active rows.
-- All point-in-time queries that join on valid_to IS NULL now return 2 rows per entity
-- → downstream JOINs fan out → report numbers are doubled.

-- Detect: find entities with more than one active record
SELECT surrogate_key, entity_id, COUNT(*) AS active_count
FROM dim_customers
WHERE valid_to IS NULL
GROUP BY surrogate_key, entity_id
HAVING COUNT(*) > 1;

-- FIX 1: idempotent INSERT with NOT EXISTS guard
INSERT INTO dim_customers (entity_id, name, valid_from, valid_to)
SELECT s.entity_id, s.name, CURRENT_DATE, NULL
FROM staging_customers s
WHERE NOT EXISTS (
    SELECT 1 FROM dim_customers d
    WHERE d.entity_id = s.entity_id
      AND d.valid_to IS NULL
      AND d.name = s.name         -- only insert if the attribute actually changed
);

-- FIX 2: unique constraint on (entity_id) WHERE valid_to IS NULL (PostgreSQL partial index)
CREATE UNIQUE INDEX uq_dim_customers_active
ON dim_customers (entity_id)
WHERE valid_to IS NULL;
-- The database enforces at most one active row per entity_id at the storage level.

-- FIX 3: dedup active rows as a recovery query (use when duplicates already exist)
WITH ranked_active AS (
    SELECT *,
        ROW_NUMBER() OVER (
            PARTITION BY entity_id
            ORDER BY valid_from DESC, surrogate_key DESC   -- keep latest insert
        ) AS rn
    FROM dim_customers
    WHERE valid_to IS NULL
)
-- Mark losers (rn > 1) as expired
UPDATE dim_customers
SET valid_to = CURRENT_DATE
WHERE surrogate_key IN (
    SELECT surrogate_key FROM ranked_active WHERE rn > 1
);
```

---

### 36-O. Duplicates in Conditional Aggregation / CASE WHEN

#### Problem — Duplicate rows inflate COUNT-based conditional aggregations

```sql
-- Counting users by KYC status using conditional aggregation:
SELECT
    COUNT(CASE WHEN kyc_status = 'APPROVED' THEN 1 END) AS approved_count,
    COUNT(CASE WHEN kyc_status = 'PENDING'  THEN 1 END) AS pending_count
FROM kyc_events;
-- If a user has two 'APPROVED' rows (pipeline ran twice), approved_count = 2 for that user.

-- FIX 1: COUNT DISTINCT on user_id within CASE
SELECT
    COUNT(DISTINCT CASE WHEN kyc_status = 'APPROVED' THEN user_id END) AS approved_users,
    COUNT(DISTINCT CASE WHEN kyc_status = 'PENDING'  THEN user_id END) AS pending_users
FROM kyc_events;
-- Counts distinct users per status — immune to row-level duplicates.

-- FIX 2: dedup first, then aggregate
WITH latest_status AS (
    SELECT *,
        ROW_NUMBER() OVER (PARTITION BY user_id ORDER BY updated_at DESC) AS rn
    FROM kyc_events
),
current_status AS (SELECT * FROM latest_status WHERE rn = 1)
SELECT
    COUNT(CASE WHEN kyc_status = 'APPROVED' THEN 1 END) AS approved_count,
    COUNT(CASE WHEN kyc_status = 'PENDING'  THEN 1 END) AS pending_count
FROM current_status;
-- Now exactly one row per user → COUNT is accurate.

-- SUM with CASE — duplicates inflate the sum:
SELECT SUM(CASE WHEN category = 'A' THEN amount ELSE 0 END) AS cat_a_revenue
FROM orders;
-- Fix: dedup orders by order_id before summing.
```

---

### 36-P. Duplicates in Self Joins

#### Problem 1 — Symmetric pairs: A→B and B→A both appear

```sql
-- Find all pairs of users who share a city:
SELECT a.user_id, b.user_id
FROM users a
JOIN users b ON a.city = b.city AND a.user_id <> b.user_id;
-- This returns (Alice, Bob) AND (Bob, Alice) — every pair appears twice.

-- FIX: enforce ordering to get each pair once
SELECT a.user_id AS user_a, b.user_id AS user_b
FROM users a
JOIN users b ON a.city = b.city AND a.user_id < b.user_id;  -- < eliminates symmetric pairs
```

#### Problem 2 — Self join on a non-unique column fans out

```sql
-- Compare each employee to the average salary in their department using a self join:
SELECT e.emp_id, e.salary, d.avg_salary
FROM employees e
JOIN (
    SELECT dept_id, AVG(salary) AS avg_salary
    FROM employees
    GROUP BY dept_id          -- aggregate first: 1 row per dept
) d ON e.dept_id = d.dept_id;

-- WRONG version (joining raw employees to themselves without aggregation):
SELECT a.emp_id, a.salary, AVG(b.salary) AS dept_avg
FROM employees a
JOIN employees b ON a.dept_id = b.dept_id
GROUP BY a.emp_id, a.salary;
-- Works mathematically but each employee row joins to N department rows → O(N²) scan.
-- For large tables: pre-aggregate to 1-row-per-dept, then join (as shown above).
```

---

### 36-Q. Duplicates in String Aggregation

#### Problem — STRING_AGG / LISTAGG produces repeated values

```sql
-- Aggregate product tags per order. An order has tag 'sale' twice (inserted twice).
SELECT
    order_id,
    STRING_AGG(tag, ', ') AS tags        -- 'sale, sale, electronics'
FROM order_tags
GROUP BY order_id;
-- 'sale' appears twice — looks like a data quality bug in the output.

-- FIX 1: use DISTINCT inside STRING_AGG (PostgreSQL, BigQuery, Databricks)
SELECT
    order_id,
    STRING_AGG(DISTINCT tag, ', ' ORDER BY tag) AS tags   -- 'electronics, sale'
FROM order_tags
GROUP BY order_id;

-- FIX 2: dedup source before aggregation (works on all engines including Snowflake/Redshift)
WITH deduped_tags AS (
    SELECT DISTINCT order_id, tag
    FROM order_tags
)
SELECT
    order_id,
    LISTAGG(tag, ', ') WITHIN GROUP (ORDER BY tag) AS tags
FROM deduped_tags
GROUP BY order_id;

-- Snowflake LISTAGG does not support DISTINCT natively — always use FIX 2 on Snowflake.
-- Redshift LISTAGG: same — no DISTINCT support; use FIX 2.
```

---

### 36-R. Duplicates in Set Operations

#### Problem — UNION vs UNION ALL: when deduplication is unintentional

```sql
-- Intent: combine two event tables, keep all rows including duplicates.
SELECT user_id, event_ts, event_type FROM app_events
UNION
SELECT user_id, event_ts, event_type FROM web_events;
-- UNION silently removes rows that appear in both tables.
-- A user who had the same event on both app and web loses one occurrence.

-- FIX: use UNION ALL when deduplication is NOT desired
SELECT user_id, event_ts, event_type FROM app_events
UNION ALL
SELECT user_id, event_ts, event_type FROM web_events;

-- When deduplication IS desired (e.g., both tables might have duplicate rows internally):
-- Step 1: dedup each source first, then UNION ALL (avoid UNION on large tables — it sorts)
WITH clean_app AS (
    SELECT DISTINCT user_id, event_ts, event_type FROM app_events
),
clean_web AS (
    SELECT DISTINCT user_id, event_ts, event_type FROM web_events
)
SELECT * FROM clean_app
UNION ALL
SELECT * FROM clean_web;
-- Then apply a final dedup if cross-source exact matches need removal:
-- wrap in ROW_NUMBER() OVER (PARTITION BY user_id, event_ts, event_type ORDER BY source)

-- Decision rule:
-- UNION     → deduplicate across both sides (expensive sort; avoid on large tables)
-- UNION ALL → keep all rows (faster; dedup manually if needed)
-- INTERSECT → rows in both sides, deduplicated
-- EXCEPT    → rows in left not in right, deduplicated
```

---

### 36-S. Duplicates in Anti-Join

#### Problem — Duplicates in the exclusion list cause unexpected behavior with NOT IN

```sql
-- Find customers who have never placed an order.
-- WRONG approach: NOT IN with a subquery that has NULL values (covered in NULL section)
-- Duplicate issue: NOT IN with duplicates is NOT a correctness problem (SQL handles it),
-- but it is a performance problem — the engine de-duplicates the list internally.

-- FIX: always prefer NOT EXISTS or LEFT JOIN IS NULL over NOT IN
-- NOT EXISTS handles duplicates in the subquery without performance penalty:
SELECT c.customer_id
FROM customers c
WHERE NOT EXISTS (
    SELECT 1 FROM orders o WHERE o.customer_id = c.customer_id
);

-- LEFT JOIN IS NULL:
SELECT c.customer_id
FROM customers c
LEFT JOIN orders o ON c.customer_id = o.customer_id
WHERE o.order_id IS NULL;
-- If orders has duplicate rows per customer_id, the LEFT JOIN fans out but
-- the WHERE o.order_id IS NULL filter only passes customers with NO match → still correct.
-- However, duplicates in orders make the LEFT JOIN more expensive (more rows scanned).
-- FIX: dedup orders first if the orders table has known duplicates.

-- Duplicate rows in the LEFT table (customers) cause multiple output rows per customer:
-- FIX: if customers can have duplicate customer_id rows, dedup customers first.
WITH unique_customers AS (
    SELECT DISTINCT customer_id FROM customers
)
SELECT uc.customer_id
FROM unique_customers uc
LEFT JOIN orders o ON uc.customer_id = o.customer_id
WHERE o.order_id IS NULL;
```

---

