<!-- Part of sql-patterns: Window Functions — FIRST_VALUE and LAST_VALUE -->
<!-- Source: sql_patterns.md lines 3573–3748 -->

## 4. Window Functions — FIRST_VALUE / LAST_VALUE

### What it solves

Return the first or last value in an ordered window partition.

### Keywords to spot

> "first ever", "first in group", "original value", "most recent value in group",clearclear
n

> "what was the starting price", "initial deposit",
> "opening value", "closing value", "baseline", "anchor value",
> "what was the price when", "inaugural", "founding", "what did they start at",
> "compare to the beginning", "what is the latest in the group"

### Business Context

- **Fintech:** Opening price of a trading pair for the day vs current; initial deposit amount vs current balance; first KYC tier a user was assigned
- **E-commerce:** Original list price of a product vs current discounted price; first item ever added to cart in a session
- **SaaS:** The plan tier a user was on when they first signed up (baseline for upgrade analysis); the first feature a user activated (activation moment)
- **HR:** Employee's original salary vs most recent salary (without using self-join); starting department vs current department
- **Logistics:** First scan location of a package (origin) vs latest scan location; initial estimated delivery date vs current estimated date

### Boilerplate

```

```sql
-- Pattern: First value in group
SELECT
    user_id,
    trading_pair,
    price,
    trade_date,
    FIRST_VALUE(price) OVER (
        PARTITION BY user_id, trading_pair
        ORDER BY trade_date
        ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING
    ) AS first_trade_price,

    LAST_VALUE(price) OVER (
        PARTITION BY user_id, trading_pair
        ORDER BY trade_date
        ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING
    ) AS last_trade_price
FROM trades;
```

### Gotchas

- `LAST_VALUE` requires `ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING` — the default frame cuts off at the current row, giving you the current row's value, not the last
- In most cases, `FIRST_VALUE` + `ORDER BY DESC` = `LAST_VALUE` with correct frame. Safer to use this approach.

### Edge Cases

#### Edge 4-A: LAST_VALUE with default frame returns current row's value

**Problem:**

```sql
-- THE most common FIRST_VALUE/LAST_VALUE mistake
-- Default frame when ORDER BY is present: RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
-- For LAST_VALUE this means: last value up to the current row = the CURRENT ROW's value

SELECT
    user_id, credit_tier, event_date,
    LAST_VALUE(credit_tier) OVER (
        PARTITION BY user_id
        ORDER BY event_date     -- ← default frame cuts at current row!
    ) AS supposedly_latest_tier
FROM user_events;
-- This returns the CURRENT ROW's credit_tier, not the actual latest tier in the partition
-- Looks correct on the last row, but every other row returns its own value
```

**Fix — always specify the full frame for LAST_VALUE:**

```sql
-- FIX — always specify the full frame for LAST_VALUE:
LAST_VALUE(credit_tier) OVER (
    PARTITION BY user_id
    ORDER BY event_date
    ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING  -- look at the entire partition
)
```

#### Edge 4-B: FIRST_VALUE on a partition where the first row has NULL

**Problem:**

```sql
-- FIRST_VALUE returns the value of the first ordered row — even if it's NULL
SELECT
    user_id, event_date, credit_tier,
    FIRST_VALUE(credit_tier) OVER (
        PARTITION BY user_id
        ORDER BY event_date
        ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING
    ) AS first_credit_tier
FROM user_events;
-- If the first event has credit_tier IS NULL (signup event, tier not yet assigned)
-- → first_credit_tier = NULL for ALL rows in that partition
```

**Fix — use FIRST_VALUE with IGNORE NULLS (Snowflake/BigQuery/DuckDB/Spark):**

```sql
-- FIX — use FIRST_VALUE with IGNORE NULLS (Snowflake/BigQuery/DuckDB/Spark):
FIRST_VALUE(credit_tier IGNORE NULLS) OVER (...)
-- Returns the first NON-NULL credit_tier in the partition
```

```sql

---

### At Scale

#### Failure Mechanism

Same shuffle + sort cost as LAG/LEAD. The additional problem: `ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING` forces the engine to see the **entire partition** before returning any result — no streaming, no early termination. For a user with 10M events, the entire 10M row partition is held in memory before the first output row is emitted.

#### Code-Level Fix

```

```sql
-- BEFORE: FIRST_VALUE on 800M rows — holds entire user partition in memory
SELECT user_id, event_date, credit_tier,
    FIRST_VALUE(credit_tier IGNORE NULLS) OVER (
        PARTITION BY user_id ORDER BY event_date
        ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING
    ) AS original_tier
FROM user_events;

-- FIX: Compute FIRST_VALUE via aggregation — cheaper than window function at scale
WITH first_assignments AS (
    SELECT user_id, MIN(event_date) AS first_assignment_date
    FROM user_events WHERE credit_tier IS NOT NULL
    GROUP BY user_id
),
first_tiers AS (
    SELECT e.user_id, e.credit_tier AS original_tier
    FROM user_events e
    JOIN first_assignments f
        ON e.user_id = f.user_id AND e.event_date = f.first_assignment_date
    WHERE e.credit_tier IS NOT NULL
)
-- Use this lookup table instead of re-computing FIRST_VALUE on every query
SELECT e.user_id, e.event_date, e.credit_tier, ft.original_tier
FROM user_events e
LEFT JOIN first_tiers ft ON e.user_id = ft.user_id;
-- GROUP BY + JOIN = 2 shuffles but both on much smaller data
-- vs FIRST_VALUE = 1 shuffle + sort on full 800M rows (worse for large data)
```

#### System-Level Fix

```sql
-- Materialise the "original tier" lookup table:
CREATE TABLE dim_user_original_tier AS
SELECT user_id,
       FIRST_VALUE(credit_tier IGNORE NULLS) OVER (
           PARTITION BY user_id ORDER BY event_date
           ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING
       ) AS original_tier
FROM user_events
QUALIFY ROW_NUMBER() OVER (PARTITION BY user_id ORDER BY event_date) = 1;
-- This runs once at ETL time; query time cost = a simple lookup join
```

```sql

---

---

