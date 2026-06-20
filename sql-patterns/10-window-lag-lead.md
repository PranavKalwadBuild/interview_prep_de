<!-- Part of sql-patterns: Window Functions — LAG and LEAD -->
<!-- Source: sql_patterns.md lines 2250–2581 -->

## 2. Window Functions — LAG / LEAD

### What it solves

Access the value of a previous (`LAG`) or next (`LEAD`) row within an ordered partition — without a self-join.

### Keywords to spot

> "previous", "next", "compared to last", "change from prior", "consecutive",
> "difference between successive", "previous order", "prior period",
> "time between events", "detect a drop/spike",
> "velocity", "acceleration", "trend change", "before and after",
> "gap between", "time since last", "days between", "value before current",
> "what happened just before", "how long since", "preceding event"

### Business Context

- **Fintech:** Detect sudden spike in trade volume vs previous trade; price drop > 5% from prior close; flag an account where today's withdrawal is 10× yesterday's — potential fraud signal
- **E-commerce:** Time between a customer's consecutive orders (repurchase cadence); detect cart abandonment by finding sessions where a user viewed checkout but never returned; days between first and second purchase
- **SaaS:** Days since last login per user; detect churn signals from engagement drop; identify users whose feature usage fell more than 50% week-over-week
- **Logistics:** Time between shipment scans; flag packages with unusually long gaps between checkpoints (>24 h gap = SLA breach risk); detect out-of-order scan sequences
- **Healthcare:** Days between prescription refills; alert when a patient's next appointment is >90 days from their last one; detect missed follow-up visits
- **Subscription/Telecom:** Identify a subscriber whose data usage jumped 5× vs prior billing cycle; flag accounts with sudden plan downgrade followed by immediate cancellation
- **Gaming:** Time between login sessions; identify players whose session frequency drops (early churn predictor)

### Boilerplate

```sql
-- Pattern: Compare current row to previous row
SELECT
    user_id,
    trade_amount,
    executed_at,
    LAG(trade_amount, 1, 0)   OVER (PARTITION BY user_id ORDER BY executed_at) AS prev_amount,
    LEAD(trade_amount, 1, 0)  OVER (PARTITION BY user_id ORDER BY executed_at) AS next_amount,

    -- Delta
    trade_amount - LAG(trade_amount, 1) OVER (PARTITION BY user_id ORDER BY executed_at) AS amount_change,

    -- Time gap between events
        executed_at,
        LAG(executed_at, 1) OVER (PARTITION BY user_id ORDER BY executed_at)
    ) AS days_since_last_trade
FROM trades;

-- Pattern: Detect a >10% spike vs previous
WITH lagged AS (
    SELECT
        *,
        LAG(price) OVER (PARTITION BY trading_pair ORDER BY trade_date) AS prev_price
    FROM daily_prices
)
SELECT *,
    (price - prev_price) / prev_price * 100 AS pct_change
FROM lagged
WHERE ABS((price - prev_price) / prev_price) > 0.10;

-- Pattern: Find first and second occurrence (LAG = NULL means first)
WITH lagged AS (
    SELECT
        *,
        LAG(event_type) OVER (PARTITION BY user_id ORDER BY event_at) AS prev_event
    FROM user_events
)
SELECT * FROM lagged
WHERE prev_event IS NULL;  -- first event per user
```

### Gotchas

- `LAG(col, 1, default)` — third argument is the default when there is no previous row. Use `0` or `NULL` depending on your logic.
- LAG/LEAD do NOT skip NULLs by default in most SQL dialects
- Always specify both `PARTITION BY` and `ORDER BY` — without ORDER BY the result is undefined

### Edge Cases

#### Edge 2-A: LAG offset larger than partition size

**Problem:**

```sql
-- LAG(col, N) when N > number of rows in the partition → returns NULL (not an error)
-- This silently drops the calculation for small-partition rows

SELECT
    user_id,
    txn_date,
    amount,
    LAG(amount, 3) OVER (PARTITION BY user_id ORDER BY txn_date) AS amount_3_txns_ago
FROM transactions;
-- Users with fewer than 4 transactions get NULL for amount_3_txns_ago
-- This is correct behaviour, but easy to misinterpret as "user had no transactions"
-- vs "user didn't have 3 prior transactions"
```

**Fix — distinguish "no prior data" from "small partition":**

```sql
-- FIX — distinguish "no prior data" from "small partition":
LAG(amount, 3) OVER (...)  AS amount_3_txns_ago,
ROW_NUMBER() OVER (PARTITION BY user_id ORDER BY txn_date) AS txn_seq
-- If txn_seq < 4 AND amount_3_txns_ago IS NULL → small partition (expected NULL)
-- If txn_seq >= 4 AND amount_3_txns_ago IS NULL → prior value was genuinely NULL
```

#### Edge 2-B: LAG propagating NULL from the prior row

**Problem:**

```sql
-- Two sources of NULL in LAG output that look identical:
-- Source 1: no prior row (first row in partition)
-- Source 2: prior row's value was genuinely NULL

-- Data:
-- txn_id | user_id | amount
--   1    |  U1     | 1000
--   2    |  U1     | NULL    ← amount not captured (data quality)
--   3    |  U1     | 500

SELECT txn_id, user_id, amount,
    LAG(amount) OVER (PARTITION BY user_id ORDER BY txn_id) AS prev_amount
FROM transactions;

-- Result:
-- txn_id | amount | prev_amount
--   1    | 1000   | NULL        ← first row
--   2    | NULL   | 1000
--   3    | 500    | NULL        ← prior row's amount was NULL (data quality)

-- Both rows 1 and 3 show NULL prev_amount — but for different reasons
-- Computing growth rate: (amount - prev_amount) / prev_amount = NULL in both cases
-- but row 3's NULL is a data quality issue, not a legitimate "first transaction"
```

**Fix — use sentinel default to distinguish:**

```sql
LAG(amount, 1, -999) OVER (...)   -- -999 means "first row in partition"
-- row 1: prev_amount = -999 (first row)
-- row 3: prev_amount = NULL (prior row had NULL amount — data issue)
```

#### Edge 2-C: MoM growth rate breaks for the first period

**Problem:**

```sql
-- BREAKS: first month has no prior month → LAG = NULL → division by NULL = NULL
-- Often reported as 'N/A' which is correct, but the formula must handle it explicitly

WITH monthly AS (
    SELECT DATE_TRUNC('month', txn_date) AS month, SUM(amount) AS revenue
    FROM transactions GROUP BY 1
)
SELECT
    month, revenue,
    (revenue - LAG(revenue) OVER (ORDER BY month))
    / LAG(revenue) OVER (ORDER BY month) * 100 AS mom_pct  -- NULL for first month: OK
    -- BUT: what if LAG(revenue) = 0 for a month with no transactions?
    -- LAG of 0 causes divide by zero ERROR (not NULL — actual exception in some engines)
FROM monthly;
```

**Fix — guard both NULL and zero prior revenue:**

```sql
CASE
    WHEN LAG(revenue) OVER (ORDER BY month) IS NULL THEN NULL   -- first period
    WHEN LAG(revenue) OVER (ORDER BY month) = 0    THEN NULL   -- no prior revenue
    ELSE ROUND(100.0 * (revenue - LAG(revenue) OVER (ORDER BY month))
                     / LAG(revenue) OVER (ORDER BY month), 2)
END AS mom_pct
```

#### Edge 2-D: LAG skipping NULLs — engine support is inconsistent

**Problem:**

```sql
-- Some engines support LAG(col IGNORE NULLS) to skip NULL values in the lag lookup
-- Support:
-- PostgreSQL: NO — must implement manually
-- MySQL:      NO

-- BREAKS in PostgreSQL: LAG(credit_score IGNORE NULLS) is a syntax error
-- Naive LAG without IGNORE NULLS propagates NULL from prior row,
-- making it impossible to distinguish "first row" from "prior row had NULL"
SELECT user_id, event_date, credit_score,
    LAG(credit_score) OVER (PARTITION BY user_id ORDER BY event_date) AS prev_score
FROM user_events;
-- If prev row's credit_score IS NULL: prev_score = NULL (same as first-row case)
```

**Fix:**

```sql
SELECT user_id, event_date, credit_score,
    LAG(credit_score IGNORE NULLS) OVER (
        PARTITION BY user_id ORDER BY event_date
    ) AS last_known_score
FROM user_events;
-- Returns the most recent non-NULL credit_score from prior rows

-- PostgreSQL workaround using LAST_VALUE with IGNORE NULLS-equivalent pattern:
WITH forward_filled AS (
    SELECT user_id, event_date, credit_score,
        MAX(credit_score) FILTER (WHERE credit_score IS NOT NULL)
            OVER (PARTITION BY user_id ORDER BY event_date ROWS UNBOUNDED PRECEDING)
        AS last_non_null_score
    FROM user_events
)
SELECT user_id, event_date, credit_score,
    LAG(last_non_null_score) OVER (PARTITION BY user_id ORDER BY event_date) AS prev_known_score
FROM forward_filled;
---

### At Scale

#### Failure Mechanism

`LAG(amount) OVER (PARTITION BY user_id ORDER BY executed_at)` on 800M rows:

- Same as ranking: full shuffle by `user_id`, then sort by `executed_at` within each partition
- Additional cost: result is 800M rows (same cardinality as input — no reduction)
- **No early termination**: unlike TOP-N, LAG must compute values for every single row
- **Memory pressure**: if a user has 50M transactions, their entire partition must fit in one executor's memory

#### Code-Level Fix

```sql
-- BEFORE: LAG on entire 800M row table
SELECT user_id, executed_at, amount,
    LAG(amount) OVER (PARTITION BY user_id ORDER BY executed_at) AS prev_amount
FROM transactions;  -- 800M rows in, 800M rows out — full shuffle + sort

-- FIX 1: Limit to only the rows that NEED comparison (incremental processing)
-- Instead of computing LAG for all history, compute it only for new data + one lookback row
WITH new_txns AS (
    SELECT * FROM transactions
    WHERE txn_date = CURRENT_DATE   -- only today's new transactions
),
-- Pull the last transaction per user from yesterday (the "lookback")
prior_txns AS (
    SELECT user_id, amount, executed_at,
        ROW_NUMBER() OVER (PARTITION BY user_id ORDER BY executed_at DESC) AS rn
    FROM transactions
    WHERE txn_date = CURRENT_DATE - 1
),
combined AS (
    SELECT user_id, executed_at, amount, 'new' AS src FROM new_txns
    UNION ALL
    SELECT user_id, executed_at, amount, 'prior' AS src FROM prior_txns
)
SELECT *,
    LAG(amount) OVER (PARTITION BY user_id ORDER BY executed_at) AS prev_amount
FROM combined
WHERE src = 'new';   -- compute LAG only for today's rows; prior row is the anchor
-- Shuffle volume: today's rows + 1 prior row per user (trivial) instead of 800M

-- FIX 2: For fraud velocity (LAG within a time window), use a self-join with bound
SELECT a.txn_id, a.user_id, a.amount, a.executed_at,
    b.amount AS prev_amount, b.executed_at AS prev_executed_at
FROM transactions a
JOIN transactions b
    ON a.user_id = b.user_id
    AND b.executed_at = (
        SELECT MAX(executed_at) FROM transactions
        WHERE user_id = a.user_id AND executed_at < a.executed_at
        AND executed_at >= a.executed_at - INTERVAL '1 hour'  -- bounded window
    )
WHERE a.txn_date = CURRENT_DATE;
-- Liquid Clustering (Delta 3.0): no PARTITION BY limitation; incremental; online
-- Data is clustered on user_id + executed_at together
-- LAG(PARTITION BY user_id ORDER BY executed_at): reads co-located files per user
-- No partition overwrite needed — incremental clustering on new data only

-- For streaming LAG (real-time velocity checks): use Flink's KeyedProcessFunction
-- Emit (user_id, current_amount, prev_amount) directly from the stream
-- Store state per user_id in RocksDB (Flink's state backend)
-- No SQL LAG needed at query time — it's pre-computed in the stream
CREATE TABLE transactions (
    txn_id      BIGINT,
    user_id     BIGINT,
    executed_at TIMESTAMP,
    amount      DECIMAL(15,2)
)
-- Rows for same user are physically adjacent on disk
-- Rows within each user are sorted by executed_at
-- LAG(PARTITION BY user_id ORDER BY executed_at): sequential I/O per user, no random seek
---

---


