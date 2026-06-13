<!-- Part of sql-patterns: Window Functions — Running Aggregates: Gotchas, Edge Cases, At Scale -->
<!-- Source: sql_patterns.md lines 2951–3210 -->

### Gotchas

- **The default is RANGE, not ROWS** — when you write `ORDER BY col` without a frame, the engine applies `RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW`. This silently expands the frame for all tied rows.
- **Ties in ROWS are deterministic only with a stable sort** — if two rows have the same ORDER BY value, ROWS picks one before the other arbitrarily. Add a tiebreaker column (e.g., `ORDER BY trade_date, trade_id`) for determinism.
- **RANGE with N PRECEDING requires a numeric or date ORDER BY column** — you cannot use RANGE with a string or non-ordinal column.
- **FIRST_VALUE always needs an explicit frame** — without `ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING`, LAST_VALUE only looks up to the current row (returns current row value, not the last in the partition).
- **LAG, LEAD, ROW_NUMBER, RANK, DENSE_RANK, NTILE ignore the frame clause** — specifying ROWS/RANGE has no effect on these functions.

### Edge Cases

#### Edge 3-A: Default RANGE frame explodes on tied dates

> **Deep dive:** This edge case is covered in full with six traps, engine differences, and a diagnostic checklist in [Section 3-A — Window Function Default Frame: The RANGE Trap](#3-a-window-function-default-frame--the-range-trap).

**Problem:**
```sql
-- The classic trap — covered in Section 3 but worth drilling as an edge case
-- Data: user_id=U1 has 500 transactions on 2024-01-15 (high-frequency trading day)
-- Running total WITHOUT explicit ROWS frame:

SUM(amount) OVER (
    PARTITION BY user_id
    ORDER BY txn_date    -- no explicit frame → default RANGE
)
-- On 2024-01-15, ALL 500 transactions see the SAME running total:
-- the sum of all transactions up to AND INCLUDING all of Jan 15
-- This is almost certainly wrong for an intraday running balance
```

**Fix:**

```sql
SUM(amount) OVER (
    PARTITION BY user_id
    ORDER BY txn_timestamp    -- use timestamp (unique) instead of date
    ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
)
```

#### Edge 3-B: Running MIN/MAX — resetting is not possible without a workaround

**Problem:**

```sql
-- A common interview mistake: expecting MIN to "reset" when a new minimum appears
-- Running MIN gives the minimum SO FAR from the start of the partition — it never goes up

SELECT txn_date, close_price,
    MIN(close_price) OVER (
        PARTITION BY trading_pair
        ORDER BY txn_date
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ) AS running_low_price   -- always decreasing or flat — never increases
FROM daily_prices;

-- This is correct behaviour. But if you want "MIN over last 7 days only":
MIN(close_price) OVER (
    PARTITION BY trading_pair
    ORDER BY txn_date
    ROWS BETWEEN 6 PRECEDING AND CURRENT ROW   -- 7-day sliding minimum
)
-- This CAN increase (old low drops out of window) — not a running min but a rolling min
```

**Fix:**

```sql
-- Running MIN/MAX inherently accumulates from the start — that behaviour is correct.
-- If you want a RESETTING min (e.g., min within each trading session), use a session group:
WITH sessions AS (
    SELECT *,
        SUM(CASE WHEN is_new_session = 1 THEN 1 ELSE 0 END)
            OVER (PARTITION BY trading_pair ORDER BY txn_date ROWS UNBOUNDED PRECEDING)
        AS session_id
    FROM (
        SELECT *,
            CASE WHEN LAG(txn_date) OVER (PARTITION BY trading_pair ORDER BY txn_date) IS NULL
                      OR txn_date > LAG(txn_date) OVER (PARTITION BY trading_pair ORDER BY txn_date) + INTERVAL '1 day'
                 THEN 1 ELSE 0 END AS is_new_session
        FROM daily_prices
    ) t
)
SELECT txn_date, close_price,
    MIN(close_price) OVER (
        PARTITION BY trading_pair, session_id
        ORDER BY txn_date
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ) AS session_running_low    -- resets at each new session
FROM sessions;
```

#### Edge 3-C: ROWS window at partition start has fewer rows than the frame

**Problem:**

```sql
-- Rolling 7-day average at the start of the data:
AVG(txn_amount) OVER (
    PARTITION BY user_id
    ORDER BY txn_date
    ROWS BETWEEN 6 PRECEDING AND CURRENT ROW   -- wants 7 rows
)
-- Row 1: only 1 row available → average of 1 row (not NULL, not error)
-- Row 2: 2 rows available
-- Row 7: first row with full 7-row window

-- This is the correct behaviour — the window shrinks at the boundary
-- But if you're computing "7-day trailing average", the early rows are biased
-- (calculated from fewer data points)
```

**Fix — mark early rows explicitly:**

```sql
SELECT
    txn_date, txn_amount,
    AVG(txn_amount) OVER (PARTITION BY user_id ORDER BY txn_date ROWS BETWEEN 6 PRECEDING AND CURRENT ROW) AS avg_7d,
    COUNT(*) OVER (PARTITION BY user_id ORDER BY txn_date ROWS BETWEEN 6 PRECEDING AND CURRENT ROW) AS rows_in_window,
    -- Flag "incomplete" windows at start:
    CASE WHEN ROW_NUMBER() OVER (PARTITION BY user_id ORDER BY txn_date) < 7
         THEN TRUE ELSE FALSE END AS is_warm_up_period
FROM transactions;
```

```sql

---

### At Scale

#### Failure Mechanism

`SUM(amount) OVER (PARTITION BY user_id ORDER BY txn_date ROWS UNBOUNDED PRECEDING)`:

- Shuffle by `user_id`: 800M rows across network
- **Sequential dependency**: each row's running total depends on the prior row — cannot be parallelised within a partition
- Partition skew amplified: the single executor handling a power user's 50M transactions must compute them **one by one** (O(N) sequential)

#### Code-Level Fix

```

```sql
-- BEFORE: running total computed inline — all 800M rows shuffled, sequential per user
SELECT user_id, txn_date, amount,
    SUM(amount) OVER (PARTITION BY user_id ORDER BY txn_date ROWS UNBOUNDED PRECEDING) AS balance
FROM transactions;

-- FIX 1: Pre-aggregate to daily level, then compute running total on daily summaries
-- Most business questions about running balance are at day granularity, not transaction granularity
WITH daily_totals AS (
    SELECT user_id, txn_date, SUM(amount) AS daily_net   -- aggregate from 800M to ~5M daily rows
    FROM transactions
    GROUP BY user_id, txn_date
)
SELECT user_id, txn_date, daily_net,
    SUM(daily_net) OVER (PARTITION BY user_id ORDER BY txn_date ROWS UNBOUNDED PRECEDING) AS balance
FROM daily_totals;
-- Running total now on 5M rows (daily summaries) not 800M (individual transactions)
-- 160× less data shuffled and sorted

-- FIX 2: Materialise the running balance at write time (event-driven architecture)
-- In a banking system: balance is a first-class entity, updated on every transaction
-- The SQL running total query is a reconciliation tool, not the primary balance source
CREATE TABLE account_balances (
    user_id    STRING,
    as_of_date DATE,
    balance    DECIMAL(15,2),
    PRIMARY KEY (user_id, as_of_date)
);
-- Update via MERGE on every transaction — balance is always current
-- Query: SELECT balance FROM account_balances WHERE user_id = :id AND as_of_date = :date
-- Zero window function cost at query time

-- FIX 3: Spark — parallelise with prefix-sum algorithm (for when you genuinely need all rows)
-- Step 1: Compute running total per spark partition (parallel, no shuffle needed)
-- Step 2: Compute the "base offset" for each partition from the last row of prior partitions
-- Step 3: Add the offset to each partition's running total
-- This is a 3-pass parallel prefix sum — 3 shuffles but all parallelisable
-- In practice: use Spark's window function with AQE for automatic parallelisation
SET spark.sql.adaptive.enabled = true;
SET spark.sql.shuffle.partitions = 1000;  -- more partitions = more parallelism per user group
```

#### System-Level Fix

```sql
-- Delta Lake: materialise daily balance table with incremental updates
-- dbt incremental model (strategy = merge):
-- merge key: (user_id, as_of_date)
-- On each run: process only new transactions, merge into daily_balances

-- Snowflake Dynamic Table for auto-refreshed running balance:
CREATE OR REPLACE DYNAMIC TABLE daily_user_balance
  LAG = '1 hour'                -- refresh every hour
  WAREHOUSE = compute_wh
AS
WITH daily AS (
    SELECT user_id, txn_date, SUM(amount) AS daily_net
    FROM transactions GROUP BY user_id, txn_date
)
SELECT user_id, txn_date, daily_net,
    SUM(daily_net) OVER (PARTITION BY user_id ORDER BY txn_date ROWS UNBOUNDED PRECEDING) AS balance
FROM daily;
-- Snowflake handles incremental refresh; query hits the materialized result
```

### System-Level Fix — Event Sourcing for Running Totals

#### System-Level Fix — Event Sourcing Pattern

```sql
-- The scale problem: running total is fundamentally sequential
-- The architectural solution: treat balance as a derived projection, not a query result

-- Level 1: Daily snapshot table (avoid recomputing from epoch every time)
CREATE TABLE account_balance_snapshots (
    account_id   STRING,
    snapshot_date DATE,
    balance       DECIMAL(20,2),
    last_txn_id   STRING        -- watermark for incremental update
)
USING DELTA
PARTITIONED BY (snapshot_date)
TBLPROPERTIES ('delta.bloomFilter.columns' = 'account_id');
-- Running total query: SELECT balance FROM account_balance_snapshots WHERE snapshot_date = :d AND account_id = :id
-- Zero window function; O(1) lookup

-- Level 2: Incremental balance update (not from-scratch recompute)
MERGE INTO account_balance_snapshots s
USING (
    SELECT account_id,
        CURRENT_DATE AS snapshot_date,
        yesterday_balance + SUM(txn_amount) AS balance,
        MAX(txn_id) AS last_txn_id
    FROM (
        -- Yesterday's balance:
        SELECT account_id, balance AS yesterday_balance, last_txn_id AS last_txn_id
        FROM account_balance_snapshots WHERE snapshot_date = CURRENT_DATE - 1
    ) prev
    JOIN (
        -- Today's transactions:
        SELECT account_id, txn_id,
            CASE WHEN txn_type = 'CREDIT' THEN amount ELSE -amount END AS txn_amount
        FROM transactions WHERE txn_date = CURRENT_DATE
    ) today ON prev.account_id = today.account_id
    GROUP BY account_id, yesterday_balance
) new_balances ON s.account_id = new_balances.account_id AND s.snapshot_date = new_balances.snapshot_date
WHEN NOT MATCHED THEN INSERT *
WHEN MATCHED THEN UPDATE SET s.balance = new_balances.balance;
-- Cost: only processes TODAY's transactions (2M rows) not all 800M rows from epoch
-- The running total is maintained incrementally — O(new_rows) not O(all_rows)
```

```sql

---

---

