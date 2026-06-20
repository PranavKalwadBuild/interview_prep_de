<!-- Part of sql-patterns: Duplicate Handling — Latest Record, End-to-End Example, Quick Reference Card -->
<!-- Source: sql_patterns.md lines 14985–15205 -->

### 36-T. Duplicates in Latest Record per Entity

#### Problem — Multiple rows sharing the maximum timestamp

```sql
-- "Get the latest status per order."
-- An order has two rows with identical updated_at timestamps (system clock resolution issue).
-- MAX(updated_at) returns the same value for both — JOIN back produces 2 rows per order.

-- WRONG pattern (classic but fragile):
SELECT o.*
FROM orders o
JOIN (
    SELECT order_id, MAX(updated_at) AS max_ts
    FROM orders
    GROUP BY order_id
) latest ON o.order_id = latest.order_id AND o.updated_at = latest.max_ts;
-- If two rows share max_ts → JOIN returns both → output has 2 rows per order.

-- FIX: use ROW_NUMBER() with a tiebreaker — always produces exactly 1 row per entity
WITH ranked AS (
    SELECT *,
        ROW_NUMBER() OVER (
            PARTITION BY order_id
            ORDER BY updated_at DESC,
                     surrogate_key DESC     -- tiebreaker: higher surrogate = later insert
        ) AS rn
    FROM orders
)
SELECT * FROM ranked WHERE rn = 1;

-- If no surrogate key exists, use a hash of all columns as a deterministic tiebreaker:
WITH ranked AS (
    SELECT *,
        ROW_NUMBER() OVER (
            PARTITION BY order_id
            ORDER BY updated_at DESC,
                     MD5(CONCAT_WS('|', order_id, status, amount, updated_at)) DESC
        ) AS rn
    FROM orders
)
SELECT * FROM ranked WHERE rn = 1;
-- MD5 tiebreaker is deterministic — same result on every run, even with tied timestamps.
```

---

### 36-U. Full End-to-End Example — Revenue Pipeline with Duplicates Everywhere

A realistic pipeline where duplicates enter at multiple stages and compound.

```sql
-- SCENARIO: Daily revenue report for a fintech.
-- Sources of duplicates:
--   1. raw_transactions: webhook retries → same txn_id appears twice
--   2. product_categories: a product tagged to 2 categories → fan-out
--   3. user_events: click events delivered twice by Kafka

-- STEP 1: Dedup raw transactions (Type 2 soft duplicates — same txn_id, different loaded_at)
WITH clean_transactions AS (
    SELECT *,
        ROW_NUMBER() OVER (
            PARTITION BY txn_id
            ORDER BY loaded_at DESC     -- keep latest loaded version
        ) AS rn
    FROM raw_transactions
),
txns AS (
    SELECT txn_id, user_id, amount, txn_date, merchant_id
    FROM clean_transactions
    WHERE rn = 1
),

-- STEP 2: Aggregate categories BEFORE joining (prevent fan-out)
-- Product belongs to multiple categories → join without aggregation multiplies revenue
primary_category AS (
    SELECT product_id,
           MAX(category_name) AS primary_category   -- pick one category deterministically
    FROM product_categories
    GROUP BY product_id
),

-- STEP 3: Dedup user events by event_id before sessionization
clean_events AS (
    SELECT *,
        ROW_NUMBER() OVER (PARTITION BY event_id ORDER BY loaded_at DESC) AS rn
    FROM user_events
),
events AS (SELECT * FROM clean_events WHERE rn = 1),

-- STEP 4: Build daily revenue with clean inputs
daily_revenue AS (
    SELECT
        t.txn_date,
        pc.primary_category,
        SUM(t.amount)           AS revenue,
        COUNT(DISTINCT t.txn_id) AS txn_count,     -- DISTINCT as extra safety net
        COUNT(DISTINCT t.user_id) AS unique_users
    FROM txns t
    LEFT JOIN primary_category pc ON t.merchant_id = pc.product_id
    GROUP BY t.txn_date, pc.primary_category
),

-- STEP 5: MoM growth on clean daily revenue
monthly AS (
    SELECT
        DATE_TRUNC('month', txn_date) AS month,
        SUM(revenue)                  AS revenue
    FROM daily_revenue
    GROUP BY 1
)
SELECT
    month,
    revenue,
    LAG(revenue) OVER (ORDER BY month)  AS prev_month_revenue,
    ROUND(100.0 * (revenue - LAG(revenue) OVER (ORDER BY month))
               / NULLIF(LAG(revenue) OVER (ORDER BY month), 0), 2) AS mom_growth_pct
FROM monthly
ORDER BY month;
```

**Where each dedup happens and why:**

| Stage | Duplicate Source | Fix Applied |
|---|---|---|
| `clean_transactions` | Webhook retry → same `txn_id` twice | `ROW_NUMBER() PARTITION BY txn_id ORDER BY loaded_at DESC` |
| `primary_category` | Product in 2 categories → fan-out | `MAX(category_name) GROUP BY product_id` |
| `clean_events` | Kafka at-least-once → same `event_id` twice | `ROW_NUMBER() PARTITION BY event_id ORDER BY loaded_at DESC` |
| `daily_revenue` | Extra safety | `COUNT(DISTINCT txn_id)` |

---

### 36-V. Duplicate Handling — Quick Reference Card

#### Detection queries


#### Fix patterns at a glance


#### Pattern → Duplicate Risk → Fix

| Pattern | Primary Duplicate Risk | Fix |
|---|---|---|
| Window Functions — Ranking | Tied ORDER BY → non-deterministic rn | Add tiebreaker column to ORDER BY |
| LAG / LEAD | Dup timestamps → wrong prior/next value | Dedup by (user, date) before LAG |
| Running Aggregates | Dup transactions inflate cumulative sum | Dedup by transaction_id first |
| FIRST_VALUE / LAST_VALUE | Dup boundary timestamps → non-deterministic | Add unique tiebreaker to ORDER BY |
| Gap and Islands | Dup dates break date − ROW_NUMBER() | DISTINCT dates before island logic |
| Sessionization | Dup events inflate session length | Dedup by event_id before session gaps |
| Deduplication | NULL keys never dedup; NULL poisons hash | COALESCE sentinel; PARTITION BY COALESCE(key, '__NULL__') |
| Top-N per Group | Many-side JOIN fan-out multiplies scores | Aggregate many-side before JOIN |
| Rolling Window | Dup events inflate rolling COUNT / SUM | Dedup by event_id; use COUNT DISTINCT for users |
| Period-over-Period | Dup txns inflate monthly base → MoM distorted | Dedup by txn_id before monthly GROUP BY |
| Date Spine | Dup fact rows fan out spine | Aggregate fact to 1-row-per-date before spine JOIN |
| Cohort Analysis | Dup first-event rows → user in two cohorts | Use MIN(date) for cohort assignment |
| Funnel Analysis | Dup step events → conversion > 100% | COUNT DISTINCT user_id per step; MAX(0/1) flag |
| SCD Type 2 | Pipeline retry → two active rows per entity | NOT EXISTS guard; partial UNIQUE index on valid_to IS NULL |
| Conditional Aggregation | Dup rows inflate COUNT-based metrics | COUNT DISTINCT user_id; dedup first |
| Self Joins | Symmetric pairs A→B and B→A | Filter with a.id < b.id |
| String Aggregation | Dup values in list | STRING_AGG(DISTINCT); or DISTINCT in CTE |
| Set Operations | UNION silently removes cross-source dupes | Use UNION ALL; dedup manually when needed |
| Anti-Join | Dup left-table rows → dup output rows | Dedup left table; prefer NOT EXISTS |
| Latest Record per Entity | Tied max timestamp → 2 rows per entity | ROW_NUMBER() with tiebreaker column |

---



