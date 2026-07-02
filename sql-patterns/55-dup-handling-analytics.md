<!-- sql-patterns: Duplicate Handling — Sessionization through Cohort Analysis (36-F to 36-L) -->

# 36-G. Duplicates in Deduplication (the Pattern Itself)

## Understanding duplicate types — not all duplicates are the same

```sql
-- TYPE 1 — Exact duplicates: every column is identical.
-- Cause: double INSERT, UNION ALL without intent.
-- Fix: SELECT DISTINCT or ROW_NUMBER() with any ORDER BY.

-- TYPE 2 — Soft duplicates (same business key, different metadata).
-- Example: same order_id appears twice, but with different loaded_at or status.
-- Cause: CDC delivering multiple versions, pipeline retry.
-- Fix: ROW_NUMBER() with a meaningful ORDER BY (latest loaded_at, highest status priority).

-- TYPE 3 — Fuzzy duplicates: same entity, different representation.
-- Example: 'Pranav K' and 'PRANAV KALWAD' are the same person.
-- Fix: normalise (LOWER, TRIM, REGEXP_REPLACE) before dedup key comparison.
```

## The three dedup patterns and when to use each

```sql
-- PATTERN A: DISTINCT — exact duplicates only
SELECT DISTINCT user_id, event_date, amount
FROM transactions;
-- Fails if even one column differs between "duplicates" (e.g., loaded_at differs)

-- PATTERN B: ROW_NUMBER() — soft duplicates (keep one per business key)
WITH ranked AS (
    SELECT *,
        ROW_NUMBER() OVER (
            PARTITION BY order_id           -- business key
            ORDER BY loaded_at DESC         -- keep the most recently loaded
        ) AS rn
    FROM orders
)
SELECT * FROM ranked WHERE rn = 1;
-- Safe even if metadata columns differ between duplicates.

-- PATTERN C: Hash-based dedup — detect exact content matches across systems
WITH hashed AS (
    SELECT *,
        MD5(CONCAT_WS('||',
            COALESCE(CAST(order_id  AS VARCHAR), '__NULL__'),
            COALESCE(CAST(amount    AS VARCHAR), '__NULL__'),
            COALESCE(status, '__NULL__'),
            COALESCE(CAST(created_at AS VARCHAR), '__NULL__')
        )) AS row_hash
    FROM orders
),
deduped AS (
    SELECT *,
        ROW_NUMBER() OVER (PARTITION BY row_hash ORDER BY loaded_at DESC) AS rn
    FROM hashed
)
SELECT * FROM deduped WHERE rn = 1;
-- NULL-safe: COALESCE with a sentinel ensures NULLs don't collapse the hash.

-- DETECT vs DELETE approach (preferred in data pipelines):
-- Don't delete — flag. Preserve the full audit trail.
WITH ranked AS (
    SELECT *,
        ROW_NUMBER() OVER (PARTITION BY order_id ORDER BY loaded_at DESC) AS rn,
        COUNT(*)     OVER (PARTITION BY order_id)                          AS dup_count
    FROM orders
)
SELECT
    *,
    CASE WHEN rn = 1 THEN 'WINNER' ELSE 'DUPLICATE' END AS dedup_status
FROM ranked;
-- Publish WINNER rows to the clean table; route DUPLICATE rows to a quarantine table.
```

---

# 36-H. Duplicates in Top-N per Group

## Problem — JOIN fan-out before ranking inflates row counts

```sql
-- Goal: top 3 products per category by revenue.
-- products has 1 row per product_id.
-- order_items has N rows per product_id (one per order line).

-- WRONG: join first, then rank → products appear N times → revenue is correct
-- but the partition inflates. Not wrong here, but a common fan-out trap:
WITH ranked AS (
    SELECT
        p.category,
        p.product_id,
        SUM(o.revenue) AS total_revenue,
        RANK() OVER (PARTITION BY p.category ORDER BY SUM(o.revenue) DESC) AS rnk
        -- ERROR: aggregate inside window function is not valid in most engines
    FROM products p
    JOIN order_items o ON p.product_id = o.product_id
    GROUP BY p.category, p.product_id
)
SELECT * FROM ranked WHERE rnk <= 3;
-- This actually works, but the anti-pattern is joining a tag/label table that has
-- multiple rows per product BEFORE aggregating:

-- WRONG: product_tags has 3 tags per product → revenue triple-counted
SELECT p.category, p.product_id, SUM(o.revenue) AS total_revenue
FROM products p
JOIN order_items o  ON p.product_id = o.product_id
JOIN product_tags t ON p.product_id = t.product_id  -- 3 rows per product!
GROUP BY p.category, p.product_id;
-- SUM(revenue) is now 3× the actual value.

-- FIX: aggregate the many-side BEFORE joining
WITH product_revenue AS (
    SELECT product_id, SUM(revenue) AS total_revenue
    FROM order_items
    GROUP BY product_id        -- clean: one row per product
),
ranked AS (
    SELECT
        p.category,
        p.product_id,
        r.total_revenue,
        RANK() OVER (PARTITION BY p.category ORDER BY r.total_revenue DESC) AS rnk
    FROM products p
    JOIN product_revenue r ON p.product_id = r.product_id
)
SELECT * FROM ranked WHERE rnk <= 3;
```

---

# 36-I. Duplicates in Rolling Window Aggregations

## Problem — Duplicate events inflate the rolling count / sum

```sql
-- 7-day rolling count of unique users. Source has duplicate event rows
-- (same user_id + event_ts from a retry).
SELECT
    event_date,
    COUNT(DISTINCT user_id) OVER (
        ORDER BY event_date
        RANGE BETWEEN INTERVAL '6 days' PRECEDING AND CURRENT ROW
    ) AS rolling_7d_users
FROM daily_events;
-- COUNT DISTINCT mitigates user-level duplicates within the window,
-- but if the goal is COUNT(*) (event count), duplicates inflate directly.

-- FIX for event count: dedup before the window
WITH deduped AS (
    SELECT *,
        ROW_NUMBER() OVER (PARTITION BY event_id ORDER BY loaded_at DESC) AS rn
    FROM events
),
clean AS (SELECT * FROM deduped WHERE rn = 1)
SELECT
    event_date,
    COUNT(*) OVER (
        ORDER BY event_date
        RANGE BETWEEN INTERVAL '6 days' PRECEDING AND CURRENT ROW
    ) AS rolling_7d_events
FROM clean;

-- Rule of thumb:
-- For USER-level metrics  → COUNT(DISTINCT user_id) tolerates duplicates
-- For EVENT-level metrics → dedup on event_id first, then COUNT(*)
```

---

# 36-J. Duplicates in Period-over-Period / MoM / YoY

## Problem — Duplicate transactions inflate the monthly revenue baseline

```sql
-- If January has 5 duplicate transactions (same txn_id loaded twice),
-- Jan revenue = 2× actual → Feb MoM growth looks negative even if Feb was flat.

WITH monthly AS (
    SELECT
        DATE_TRUNC('month', txn_date) AS month,
        SUM(amount)                   AS revenue
    FROM transactions     -- duplicates not removed → SUM is wrong
    GROUP BY 1
)
SELECT
    month,
    revenue,
    LAG(revenue) OVER (ORDER BY month) AS prev_revenue,
    ROUND(100.0 * (revenue - LAG(revenue) OVER (ORDER BY month))
               / NULLIF(LAG(revenue) OVER (ORDER BY month), 0), 2) AS mom_growth_pct
FROM monthly;

-- FIX: dedup transactions before the monthly aggregation
WITH deduped AS (
    SELECT *,
        ROW_NUMBER() OVER (PARTITION BY txn_id ORDER BY loaded_at DESC) AS rn
    FROM transactions
),
clean_txns AS (SELECT * FROM deduped WHERE rn = 1),
monthly AS (
    SELECT
        DATE_TRUNC('month', txn_date) AS month,
        SUM(amount)                   AS revenue
    FROM clean_txns
    GROUP BY 1
)
SELECT
    month, revenue,
    LAG(revenue) OVER (ORDER BY month)                                AS prev_revenue,
    ROUND(100.0 * (revenue - LAG(revenue) OVER (ORDER BY month))
               / NULLIF(LAG(revenue) OVER (ORDER BY month), 0), 2)   AS mom_growth_pct
FROM monthly;
```

---

# 36-K. Duplicates in Date Spine / Calendar Table

## Problem — Duplicate fact rows cause multiple matches per spine date

```sql
-- date_spine has 1 row per date (guaranteed).
-- daily_revenue fact table has 2 rows for 2024-03-15 (duplicate transaction date).
-- LEFT JOIN produces 2 rows for 2024-03-15 in the output — spine is no longer 1:1.

SELECT
    s.dt,
    COALESCE(d.revenue, 0) AS revenue
FROM date_spine s
LEFT JOIN daily_revenue d ON s.dt = d.txn_date;
-- If daily_revenue has 2 rows for 2024-03-15, spine row 2024-03-15 fans out to 2.

-- FIX: aggregate the fact table to guaranteed 1-row-per-date BEFORE joining the spine
WITH daily_agg AS (
    SELECT txn_date, SUM(revenue) AS revenue
    FROM transactions
    GROUP BY txn_date    -- 1 row per date guaranteed
)
SELECT
    s.dt,
    COALESCE(d.revenue, 0) AS revenue
FROM date_spine s
LEFT JOIN daily_agg d ON s.dt = d.txn_date;

-- Rule: the spine is the controlling table. Any table joined to the spine
-- must be pre-aggregated to 1 row per spine key (date, user, etc.).
```

---

# 36-L. Duplicates in Cohort Analysis & Retention

## Problem — Duplicate first-event rows inflate cohort size


---


