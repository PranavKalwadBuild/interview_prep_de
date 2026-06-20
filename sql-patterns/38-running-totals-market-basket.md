<!-- Part of sql-patterns: Running Totals, Cumulative Metrics, and Market Basket / Co-occurrence -->
<!-- Source: sql_patterns.md lines 9841–10111 -->

## 24. Running Totals & Cumulative Metrics

### What it solves

Compute a metric that accumulates over time — running sum, running count, cumulative revenue.

### Keywords to spot

> "running total", "cumulative", "so far", "up to this date",
> "year-to-date", "all previous records", "progressively",
> "total by end of day X"

*(See also Pattern 3 for the window function syntax)*

### Boilerplate — Cumulative distinct users (new user growth curve)

```sql
-- How many unique users had traded by each date?
WITH daily_first_trades AS (
    SELECT user_id, MIN(DATE(executed_at)) AS first_trade_date
    FROM trades
    GROUP BY user_id
),
daily_new_users AS (
    SELECT first_trade_date, COUNT(*) AS new_users
    FROM daily_first_trades
    GROUP BY first_trade_date
)
SELECT
    first_trade_date,
    new_users,
    SUM(new_users) OVER (ORDER BY first_trade_date) AS cumulative_users
FROM daily_new_users
ORDER BY first_trade_date;
```

### Edge Cases

#### Edge 24-A: Running total goes negative — need to floor at zero

**Problem:**

```sql
-- Credit card running balance can go negative temporarily (payment before statement)
-- If business rule says "balance cannot go below 0, floor at 0":

-- WRONG — just computing the running total without floor:
SUM(CASE WHEN txn_type = 'CREDIT' THEN  amount ELSE -amount END)
OVER (PARTITION BY account_id ORDER BY txn_date ROWS UNBOUNDED PRECEDING) AS balance
-- May return -500 for an overpayment — which is technically correct but violates business rule
```

**Fix — there is no "GREATEST(running_sum, 0)" that SQL computes incrementally:**

```sql
-- FIX — there is no "GREATEST(running_sum, 0)" that SQL computes incrementally
-- The only correct approach for floored running totals is a recursive CTE or application logic:
WITH RECURSIVE balance_calc AS (
    SELECT txn_id, account_id, txn_date, amount, txn_type,
           GREATEST(
               CASE WHEN txn_type = 'CREDIT' THEN amount ELSE -amount END,
               0
           ) AS balance,
           ROW_NUMBER() OVER (PARTITION BY account_id ORDER BY txn_date, txn_id) AS rn
    FROM transactions WHERE rn = 1  -- first transaction per account

    UNION ALL

    SELECT t.txn_id, t.account_id, t.txn_date, t.amount, t.txn_type,
           GREATEST(b.balance + CASE WHEN t.txn_type = 'CREDIT' THEN t.amount ELSE -t.amount END, 0),
           t.rn
    FROM transactions t
    JOIN balance_calc b ON t.account_id = b.account_id AND t.rn = b.rn + 1
)
SELECT * FROM balance_calc;
-- NOTE: recursive CTEs for running totals with logic are expensive on large tables
-- For large-scale systems, this is better handled in streaming (Flink, Kafka Streams)
---

### At Scale

*No specific at-scale documentation for this pattern.*

---

## 25. Market Basket / Co-occurrence

### What it solves

Find items that frequently appear together — products bought together, trading pairs co-traded by the same user.

### Keywords to spot

> "frequently together", "co-occurrence", "bought together",
> "users who traded both X and Y", "pairs of", "association",
> "cross-sell", "affinity", "bundled", "combination",
> "what else do users who do X also do", "commonly paired",
> "appear in same order", "co-adoption"

### Business Context

- **Fintech:** Users who traded both BTC and ETH (cross-asset behaviour — target with cross-sell campaigns); pairs of assets most commonly held together (portfolio clustering for robo-advisory)
- **E-commerce:** Products frequently bought together (Amazon "frequently bought together" widget; recommendation engine input); identify which accessories are co-purchased with hero SKUs
- **SaaS:** Features commonly used in the same session (UX bundling decisions — should these be one feature?); identify which two features, when both adopted, predict long-term retention
- **Support/DevOps:** Error codes that co-occur in the same pipeline run (root cause clustering — one upstream failure triggers many downstream errors); alert correlation for on-call noise reduction
- **Marketing:** Ad creatives that are clicked together in the same session (fatigue analysis); campaigns that co-convert the same users (overlap for budget optimisation)

### Boilerplate

```sql
-- Users who traded both BTC_INR and ETH_INR
SELECT a.user_id
FROM trades a
JOIN trades b ON a.user_id = b.user_id
WHERE a.trading_pair = 'BTC_INR'
  AND b.trading_pair = 'ETH_INR';

-- All pairs of trading pairs co-traded by same user, ranked by frequency
WITH user_pairs AS (
    SELECT
        a.user_id,
        a.trading_pair AS pair1,
        b.trading_pair AS pair2
    FROM (SELECT DISTINCT user_id, trading_pair FROM trades) a
    JOIN (SELECT DISTINCT user_id, trading_pair FROM trades) b
        ON  a.user_id = b.user_id
        AND a.trading_pair < b.trading_pair  -- avoid duplicates
)
SELECT pair1, pair2, COUNT(DISTINCT user_id) AS co_traders
FROM user_pairs
GROUP BY pair1, pair2
ORDER BY co_traders DESC;
```

### Edge Cases

#### Edge 25-A: Self-pairing — product A paired with product A

**Problem:**

```sql
-- Market basket: find products frequently bought together
SELECT a.product_id AS prod_a, b.product_id AS prod_b, COUNT(*) AS co_occurrences
FROM order_items a
JOIN order_items b ON a.order_id = b.order_id
-- TRAP: no condition to prevent a.product_id = b.product_id → self-pairs!
-- Product P1 "bought together with P1" = every order containing P1 → artificially inflated
```

**Fix A — exclude self-pairs and avoid double-counting (A,B) and (B,A):**

```sql
WHERE a.product_id < b.product_id   -- strict less-than: excludes self-pairs AND (B,A)
```

**Fix B — if product_id is not orderable (UUID), use != and then deduplicate:**

```sql
WHERE a.product_id != b.product_id
-- Then: LEAST(a.product_id, b.product_id) || '|' || GREATEST(a.product_id, b.product_id) as pair_key
-- GROUP BY pair_key → divides counts by 2 to remove double-count
```

#### Edge 25-B: Cartesian explosion on large baskets

**Problem:**

```sql
-- An order with 1,000 line items: JOIN produces 1,000 × 999 = 999,000 rows for that ONE order
-- An e-commerce site with average basket size 10 items: manageable
-- A wholesale order with 500+ line items: query OOMs or runs for hours
```

**Fix — filter to only popular items (pre-aggregate):**

```sql
WITH popular_products AS (
    SELECT product_id FROM order_items
    GROUP BY product_id HAVING COUNT(DISTINCT order_id) > 100  -- min 100 orders
),
filtered_items AS (
    SELECT order_id, product_id FROM order_items
    WHERE product_id IN (SELECT product_id FROM popular_products)
)
SELECT a.product_id, b.product_id, COUNT(*) AS co_count
FROM filtered_items a
JOIN filtered_items b ON a.order_id = b.order_id AND a.product_id < b.product_id
GROUP BY a.product_id, b.product_id
HAVING COUNT(*) > 50
ORDER BY co_count DESC;
---

### At Scale

#### Failure Mechanism

Self-join for co-occurrence on 10M orders with average 10 items each:

- `JOIN order_items a JOIN order_items b ON a.order_id = b.order_id AND a.product_id < b.product_id`
- Average: 10 × 9 / 2 = 45 pairs per order × 10M orders = **450M pair rows**
- At 100 bytes each: 45GB intermediate result
- For orders with 100+ items (wholesale): single order produces 4,950 pairs → skew explosion

#### Code-Level Fix

```sql
-- FIX: Use sparse co-occurrence matrix approach
-- Step 1: per product, compute the set of orders it appears in → inverted index
WITH product_orders AS (
    SELECT product_id,
        COUNT(DISTINCT order_id) AS order_count
    FROM order_items
    GROUP BY product_id
    HAVING COUNT(DISTINCT order_id) >= 100    -- filter rare items (reduce combination space)
),
-- Step 2: count co-occurrences using array intersection (much cheaper than row-level join)
co_occurrence AS (
    SELECT a.product_id AS prod_a, b.product_id AS prod_b,
        SIZE(ARRAY_INTERSECT(a.order_set, b.order_set)) AS co_count
    FROM product_orders a
    JOIN product_orders b ON a.product_id < b.product_id
    WHERE SIZE(ARRAY_INTERSECT(a.order_set, b.order_set)) >= 50  -- minimum threshold
)
SELECT prod_a, prod_b, co_count
FROM co_occurrence
ORDER BY co_count DESC LIMIT 1000;
-- ARRAY_INTERSECT on sorted arrays: O(|A| + |B|) vs row-level join O(|A| × |B|)
-- For product with 10K orders: array intersection = 10K+10K = 20K ops vs 100M row-join ops
```

#### System-Level Fix

```sql
-- Pre-compute co-occurrence matrix nightly
CREATE TABLE product_cooccurrence (
    product_a      STRING,
    product_b      STRING,
    co_count       BIGINT,
    lift           DECIMAL(8,4),  -- co_count / (freq_a × freq_b) — recommendation signal
    computed_date  DATE
)
PARTITIONED BY (computed_date)
TBLPROPERTIES ('delta.bloomFilter.columns' = 'product_a');
-- Recommendation query: SELECT product_b, lift FROM product_cooccurrence
--                       WHERE product_a = 'P001' ORDER BY lift DESC LIMIT 10
-- Sub-second; no join at query time
---

---


