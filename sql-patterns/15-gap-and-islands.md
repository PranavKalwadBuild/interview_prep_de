<!-- Part of sql-patterns: Gap and Islands Pattern -->
<!-- Source: sql_patterns.md lines 3749–4107 -->

## 5. Gap and Islands

### What it solves

Identify **consecutive sequences** (islands) of rows that share a property, separated by breaks (gaps). The classic multi-step SQL pattern for sequence analysis.

### Keywords to spot

> "consecutive", "sequence", "streak", "uninterrupted", "continuous",
> "how long", "run of", "chain of", "group of successive",
> "first/last in a streak", "how many in a row",
> "without interruption", "break in", "contiguous", "back-to-back",
> "sustained", "ongoing", "continuous run", "escalating", "monotonically"

### Business Context

- **Fintech:** Users with 5+ consecutive trading days (engagement badge); detect escalating buy order sequences (potential market manipulation signal); consecutive days a user's portfolio was in the red
- **E-commerce:** Customers who purchased on 7+ consecutive days; identify sales streaks per product to time inventory replenishment; consecutive days a discount code was applied
- **SaaS:** Users with uninterrupted daily logins (streak-based engagement rewards); longest streak of daily active use per account tier; consecutive months of paying subscription
- **DevOps/Monitoring:** Periods of continuous system uptime or downtime (SLA reporting); consecutive failed health checks → page on-call after N failures; contiguous error windows in application logs
- **Sports/Gaming:** Win/loss streaks; consecutive days of app engagement; unbroken daily quest completion runs
- **Subscription/Media:** Consecutive months a customer renewed without downgrading; uninterrupted binge-watching sessions across days

### Core Idea

1. Order rows per group by time
2. Flag each row where the sequence **breaks** (`is_break = 1`)
3. `SUM(is_break) OVER (ORDER BY ...)` creates a monotonically incrementing group ID
4. Group by that ID and filter for length

### Boilerplate — Value-based sequence (escalation)

```sql
-- Business: detect 3+ consecutive BUY trades with 10% escalation per trade
WITH ordered AS (
    SELECT
        trade_id,
        user_id,
        trading_pair,
        amount_inr,
        executed_at,
        LAG(amount_inr) OVER (
            PARTITION BY user_id, trading_pair
            ORDER BY executed_at
        ) AS prev_amount
    FROM trades
    WHERE trade_type = 'BUY'
),

break_flags AS (
    SELECT *,
        CASE
            WHEN prev_amount IS NULL OR amount_inr < prev_amount * 1.10
            THEN 1 ELSE 0
        END AS is_break
    FROM ordered
),

sequence_groups AS (
    SELECT *,
        SUM(is_break) OVER (
            PARTITION BY user_id, trading_pair
            ORDER BY executed_at
        ) AS seq_group_id
    FROM break_flags
)

SELECT
    user_id,
    trading_pair,
    seq_group_id,
    MIN(trade_id)   AS sequence_start,
    MAX(trade_id)   AS sequence_end,
    COUNT(*)        AS sequence_length,
    MAX(amount_inr) AS max_amount
FROM sequence_groups
GROUP BY user_id, trading_pair, seq_group_id
HAVING COUNT(*) >= 3;
```

### Boilerplate — Date-based streak (consecutive active days)

```sql
-- Business: users with 5+ consecutive trading days
WITH daily_activity AS (
    SELECT DISTINCT
        user_id,
        DATE(executed_at) AS trade_date
    FROM trades
),

with_prev AS (
    SELECT
        user_id,
        trade_date,
        LAG(trade_date) OVER (PARTITION BY user_id ORDER BY trade_date) AS prev_date
    FROM daily_activity
),

break_flags AS (
    SELECT *,
        CASE
            WHEN prev_date IS NULL
            THEN 1 ELSE 0
        END AS is_break
    FROM with_prev
),

streaks AS (
    SELECT *,
        SUM(is_break) OVER (PARTITION BY user_id ORDER BY trade_date) AS streak_id
    FROM break_flags
)

SELECT
    user_id,
    streak_id,
    MIN(trade_date) AS streak_start,
    MAX(trade_date) AS streak_end,
    COUNT(*)        AS streak_length_days
FROM streaks
GROUP BY user_id, streak_id
HAVING COUNT(*) >= 5;
```

### Gotchas

- Always `DISTINCT` dates first if a user can have multiple events on the same day — otherwise same-day events count as separate rows and inflate streak count
- The `is_break` for the first row of each partition will always be 1 (prev is NULL) — this correctly starts `seq_group_id` at 1

### Edge Cases

#### Edge 5-A: Duplicate dates within the same partition break the streak logic

**Problem:**

```sql
-- The date-minus-rownumber trick assumes each date appears exactly once per partition
-- If a user logged in twice on 2024-01-03, ROW_NUMBER increments but the date doesn't
-- Result: two different streak_group values for the same date → island split incorrectly

WITH daily AS (
    SELECT user_id, login_date  -- NOT deduplicated
    FROM login_events
),
grouped AS (
    SELECT user_id, login_date,
        login_date - ROW_NUMBER() OVER (PARTITION BY user_id ORDER BY login_date)::INT AS grp
    FROM daily
)
-- user_id=U1, login_date=2024-01-03 appears twice:
-- Row 3: 2024-01-03 - 3 = 2023-12-31 → grp A
-- Row 4: 2024-01-03 - 4 = 2023-12-30 → grp B  ← different group for same date!
-- This splits what should be one island into two
```

**Fix — deduplicate first (always):**

```sql
WITH daily AS (
    SELECT DISTINCT user_id, CAST(login_at AS DATE) AS login_date
    FROM login_events
),
...
```

#### Edge 5-B: Single-row partitions — trivially one island

**Problem:**

```sql
-- A user who only logged in once → one island of length 1
-- The gap-and-island query handles this correctly (COUNT = 1, start = end)
-- But HAVING COUNT(*) >= 5 will correctly exclude them — no edge case here
-- Edge case is if you then try to compute duration: MAX - MIN = 0 days — that's valid

-- What breaks: computing AVG streak length across users when some have only 1 event
AVG(streak_length)    -- includes users with streak_length = 1 — correct but may skew metric
AVG(NULLIF(streak_length - 1, 0) + 1)  -- same, just harder to read; no benefit here
```

**Fix:**

```sql
-- Single-row partitions are handled correctly by gap-and-island queries.
-- The only action needed is to avoid mislabeling them — explicitly flag them:
WITH islands AS (
    SELECT user_id,
           MIN(login_date) AS streak_start,
           MAX(login_date) AS streak_end,
           COUNT(*) AS streak_length
    FROM (
        SELECT user_id, login_date,
            login_date - ROW_NUMBER() OVER (PARTITION BY user_id ORDER BY login_date)::INT AS grp
        FROM (SELECT DISTINCT user_id, CAST(login_at AS DATE) AS login_date FROM login_events) d
    ) g
    GROUP BY user_id, grp
)
SELECT user_id, streak_start, streak_end, streak_length,
    CASE WHEN streak_length = 1 THEN TRUE ELSE FALSE END AS is_single_day_streak
FROM islands;
-- Consumers can filter out single-day streaks with: WHERE streak_length > 1
```

#### Edge 5-C: Large time gaps create unexpected very long "islands" in value-based detection

**Problem:**

```sql
-- Fraud escalation: detect 3+ consecutive BUY trades with 10% step-up in amount
-- The pattern uses LAG to detect breaks. But what about a 6-month gap between trades?
-- The query doesn't consider time gaps — a sequence from Jan and then Aug counts as one island

WITH ordered AS (
    SELECT *,
        LAG(amount) OVER (PARTITION BY user_id ORDER BY executed_at) AS prev_amount,
        LAG(executed_at) OVER (PARTITION BY user_id ORDER BY executed_at) AS prev_time
    FROM trades WHERE trade_type = 'BUY'
),
break_flags AS (
    SELECT *,
        CASE
            WHEN prev_amount IS NULL THEN 1              -- first trade
            WHEN amount < prev_amount * 1.10 THEN 1      -- not escalating
            WHEN executed_at - prev_time > INTERVAL '30 days' THEN 1  -- ← add time gap break
            ELSE 0
        END AS is_break
    FROM ordered
)
-- Without the time gap condition, a trade escalation across 6 months would flag as suspicious
-- With it, you only detect escalation within a reasonable window
```

**Fix:**

```sql
-- Add a time gap break condition so a 6-month gap starts a new island:
WITH ordered AS (
    SELECT *,
        LAG(amount) OVER (PARTITION BY user_id ORDER BY executed_at) AS prev_amount,
        LAG(executed_at) OVER (PARTITION BY user_id ORDER BY executed_at) AS prev_time
    FROM trades WHERE trade_type = 'BUY'
),
break_flags AS (
    SELECT *,
        CASE
            WHEN prev_amount IS NULL THEN 1                              -- first trade ever
            WHEN amount < prev_amount * 1.10 THEN 1                     -- not escalating
            WHEN executed_at - prev_time > INTERVAL '30 days' THEN 1    -- stale gap → new island
            ELSE 0
        END AS is_break
    FROM ordered
),
islands AS (
    SELECT *,
        SUM(is_break) OVER (PARTITION BY user_id ORDER BY executed_at ROWS UNBOUNDED PRECEDING) AS grp
    FROM break_flags
)
SELECT user_id, grp,
    MIN(executed_at) AS island_start,
    MAX(executed_at) AS island_end,
    COUNT(*) AS escalation_length
FROM islands
GROUP BY user_id, grp
HAVING COUNT(*) >= 3;  -- flag users with 3+ consecutive escalating trades within 30 days
```

---

### At Scale

#### Failure Mechanism

```
Step 1: DISTINCT on 800M login_events → 400M unique (user_id, date) pairs
Step 2: ROW_NUMBER OVER (PARTITION BY user_id ORDER BY login_date) → shuffle + sort on 400M rows
Step 3: GROUP BY (user_id, streak_group) → second shuffle on 400M rows
Total: 2 full shuffles on hundreds of millions of rows + sort
```

Additionally: **result set cardinality is high** — could still be tens of millions of island rows.

#### Code-Level Fix

```sql
-- BEFORE: runs on all history
WITH daily AS (
    SELECT DISTINCT user_id, CAST(login_at AS DATE) AS login_date
    FROM login_events   -- 800M events
),
grouped AS (
    SELECT user_id, login_date,
        login_date - ROW_NUMBER() OVER (PARTITION BY user_id ORDER BY login_date)::INT AS grp
    FROM daily          -- 400M distinct days
)
SELECT user_id, MIN(login_date), MAX(login_date), COUNT(*) AS streak_len
FROM grouped GROUP BY user_id, grp;

-- FIX 1: Incremental gap-and-island — only extend existing streaks
-- Today's streak is yesterday's streak + 1 (if user was active yesterday)
-- OR it's a new streak of length 1 (if user was inactive yesterday)
MERGE INTO user_streaks s
USING (
    -- Today's active users:
    SELECT DISTINCT user_id, CURRENT_DATE AS login_date
    FROM login_events WHERE DATE(login_at) = CURRENT_DATE
) t ON s.user_id = t.user_id AND s.streak_end = CURRENT_DATE - 1
-- If yesterday's streak end matches: extend the streak
WHEN MATCHED THEN UPDATE SET streak_end = CURRENT_DATE, streak_length = streak_length + 1
-- New streak:
WHEN NOT MATCHED THEN INSERT (user_id, streak_start, streak_end, streak_length)
VALUES (t.user_id, CURRENT_DATE, CURRENT_DATE, 1);
-- This runs on only TODAY's active users (~100K rows) not 800M rows

-- FIX 2: Pre-aggregate to weekly activity bitmask for long-term streak analysis
-- Store a bitmask of which days in a week a user was active (7-bit integer)
-- Gap-and-island on weekly bitmasks is 52× cheaper than daily row-level analysis
```

#### System-Level Fix


---

---


