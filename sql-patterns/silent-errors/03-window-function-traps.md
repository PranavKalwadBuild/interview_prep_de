<!-- sql-patterns: Silent Errors — Window Function Traps -->

# Silent Errors — Window Function Traps

Window functions are among the most powerful SQL constructs — and among the most silently wrong. The frame specification, the ORDER BY clause, and partition type mismatches all interact in ways that produce plausible-looking but incorrect results. The bugs are invisible because the function returns a number; it just returns the wrong number.

---

### Default RANGE Frame with Ties — Running Total Includes Future Rows

**What it looks like:**
```sql
SELECT
    order_date,
    amount,
    SUM(amount) OVER (ORDER BY order_date) AS running_total
FROM orders;
```

**What actually happens:** Without an explicit frame clause, `SUM(...) OVER (ORDER BY ...)` uses `RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW`. "Current row" in RANGE semantics means all rows with the same ORDER BY value as the current row — i.e., all peers (ties) are included in the frame together.

If three orders share the same `order_date`, all three rows in that date group will show the same running total: the total *including all three orders for that date*, not an incremental per-row total.

**Why it's insidious:** The result looks like a valid running total. The sum is correct for the last row of each date group. But comparing day-over-day, you cannot reconstruct daily increments from the running total without knowing which rows tie.

**Minimal repro:**
```sql
WITH orders AS (
    SELECT * FROM (VALUES ('2024-01-01', 100),('2024-01-01', 200),('2024-01-02', 50)) t(dt,amt)
)
SELECT
    dt, amt,
    SUM(amt) OVER (ORDER BY dt)              AS range_running,  -- 300, 300, 350 (both Jan-1 rows = 300)
    SUM(amt) OVER (ORDER BY dt ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
                                              AS rows_running   -- 100, 300, 350 (row-by-row correct)
FROM orders;
```

**How to catch it:**
```sql
-- Invariant: the last running total should equal SUM of all rows
-- If you see duplicate values in a running total, suspect RANGE frame with ties.
SELECT order_date, running_total,
       COUNT(*) OVER (PARTITION BY order_date, running_total) AS tie_count
FROM (SELECT ...) t
WHERE tie_count > 1 AND order_date = (SELECT MIN(order_date) FROM ...);
```

**Real-world trigger:** Daily revenue cumulative chart. Dates with multiple transactions (common on promotion days) all show the end-of-day total rather than per-transaction incremental amounts. The chart looks smooth except on high-volume days where the running total plateaus, then jumps.

---

### LAST_VALUE Returns Current Row — Default Frame Cuts the Partition Short

**What it looks like:**
```sql
SELECT
    account_id,
    status,
    event_time,
    LAST_VALUE(status) OVER (PARTITION BY account_id ORDER BY event_time) AS current_status
FROM account_events;
```

**What actually happens:** The default frame is `RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW`. For each row, `LAST_VALUE` returns the last value in the window *up to the current row* — which is always the current row's own value. Every row's `current_status` equals its own `status`. The function is a no-op.

**Why it's insidious:** The column is populated with valid-looking statuses. They are not wrong per se — they are the current row's status — but the developer intended the *final* status in the partition. No error, no NULLs, just quietly wrong semantics.

**Minimal repro:**
```sql
WITH events AS (
    SELECT * FROM (VALUES
        (1, 'created',    '2024-01-01'::DATE),
        (1, 'processing', '2024-01-02'::DATE),
        (1, 'completed',  '2024-01-03'::DATE)
    ) t(acct, status, dt)
)
SELECT
    acct, dt, status,
    LAST_VALUE(status) OVER (PARTITION BY acct ORDER BY dt)
        AS wrong_last,   -- 'created', 'processing', 'completed' (always current row)
    LAST_VALUE(status) OVER (PARTITION BY acct ORDER BY dt
        ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING)
        AS correct_last  -- 'completed', 'completed', 'completed'
FROM events;
```

**How to catch it:**
```sql
-- If LAST_VALUE equals the current row's value for non-last rows, the frame is wrong:
SELECT COUNT(*) FROM (
    SELECT status,
           LAST_VALUE(status) OVER (PARTITION BY account_id ORDER BY event_time) AS last_val,
           ROW_NUMBER() OVER (PARTITION BY account_id ORDER BY event_time DESC) AS rn
    FROM account_events
) t
WHERE rn > 1 AND status = last_val;
-- Count > 0 means LAST_VALUE is just echoing current row
```

**Real-world trigger:** Account status as-of-date logic. A report joins account status at the time of a transaction. `LAST_VALUE` intended to carry forward the final known status instead returns the status at each individual event — making every row appear to have the status it had *at that moment* rather than the *most recent* status.

---

### ROW_NUMBER() with Non-Deterministic ORDER BY — Unstable Row Assignment

**What it looks like:**
```sql
SELECT
    user_id,
    event_time,
    ROW_NUMBER() OVER (PARTITION BY user_id ORDER BY event_time) AS event_seq
FROM events;
```

**What actually happens:** If multiple rows share the same `event_time` for a user, the ORDER BY is non-deterministic for those tied rows. SQL does not guarantee a consistent ordering of ties. Different query executions, different cluster states, or query plan changes can assign different row numbers to tied rows — making the sequence non-reproducible.

**Why it's insidious:** For the vast majority of partitions with no ties, ROW_NUMBER is perfectly deterministic. The bug only activates for users with multiple events in the same second (or millisecond, depending on timestamp precision). These are exactly the users generating the most activity — high-value users.

**Minimal repro:**
```sql
WITH events AS (
    SELECT 1 AS uid, '2024-01-01 10:00:00'::TIMESTAMP AS ts, 'click'  AS type
    UNION ALL
    SELECT 1, '2024-01-01 10:00:00'::TIMESTAMP, 'view'
)
SELECT uid, ts, type,
       ROW_NUMBER() OVER (PARTITION BY uid ORDER BY ts) AS rn
FROM events;
-- 'click' and 'view' can be assigned rn=1 or rn=2 in any order.
-- Re-run the query and you may get a different assignment.
```

**How to catch it:**
```sql
-- Always include a tiebreaker column:
ROW_NUMBER() OVER (PARTITION BY user_id ORDER BY event_time, event_id)
-- event_id (a surrogate key) provides a deterministic tiebreaker.

-- Detection: look for ties in your ORDER BY columns:
SELECT user_id, event_time, COUNT(*) AS tie_count
FROM events
GROUP BY user_id, event_time
HAVING COUNT(*) > 1;
```

**Real-world trigger:** Session reconstruction logic picks the first event per user per session using ROW_NUMBER. Two events at the same timestamp mean different "first events" are returned on each pipeline run. Session start times jump between runs, making funnel analysis non-reproducible.

---

### RANK() Gaps vs DENSE_RANK() — Downstream <= N Breaks

**What it looks like:**
```sql
SELECT user_id, score,
       RANK() OVER (ORDER BY score DESC) AS rank_position
FROM user_scores
WHERE rank_position <= 10;  -- "top 10"
```

**What actually happens:** `RANK()` leaves gaps: if three users are tied at rank 1, the next user is rank 4. `WHERE rank_position <= 10` may return 12 users (three tied at #1 + nine more) or as few as 7 (if there are gaps that skip over 10). The "top 10" filter returns a variable, unpredictable number of rows.

**Why it's insidious:** When there are no ties, `RANK()` and `DENSE_RANK()` are identical. The bug is invisible until a tie case occurs in production. The first time it happens, the "top 10" list suddenly has 14 users or 6 users.

**Minimal repro:**
```sql
WITH scores AS (
    SELECT * FROM (VALUES ('A',100),('B',100),('C',90),('D',90),('E',80)) t(uid,score)
)
SELECT uid, score,
       RANK()       OVER (ORDER BY score DESC) AS rnk,        -- 1,1,3,3,5
       DENSE_RANK() OVER (ORDER BY score DESC) AS dense_rnk   -- 1,1,2,2,3
FROM scores;
-- WHERE rnk <= 2 returns 2 rows (only the two rank-1 ties)
-- WHERE dense_rnk <= 2 returns 4 rows (top 2 tiers)
```

**How to catch it:** Any `WHERE rank_col <= N` in a report must document whether ties should be included or excluded, and must use the right ranking function to enforce that contract. Add an assertion: `ASSERT (SELECT COUNT(*) FROM ranked WHERE rank_pos <= 10) BETWEEN 10 AND 20`.

**Real-world trigger:** Leaderboard shows "Top 10 performers." Two sales reps are tied for #1. With `RANK()`, the leaderboard shows only those two when filtered to `<= 1`. With `DENSE_RANK()`, ranks 1–10 always appear. Management sees a leaderboard that fluctuates between showing 2 people and 12 people depending on which quarter-end tie structure occurs.

---

### LAG/LEAD with IGNORE NULLS — Positional Offset vs Logical Offset

**What it looks like:**
```sql
SELECT
    date,
    value,
    LAG(value, 1 IGNORE NULLS) OVER (ORDER BY date) AS prev_non_null_value
FROM daily_metrics;
```

**What actually happens:** `IGNORE NULLS` causes LAG to skip NULL rows and find the *nearest non-NULL predecessor*, not the *row that is 1 position back*. If rows 3, 4, 5 are NULL and row 6 is non-NULL, `LAG(value, 1 IGNORE NULLS)` for row 6 returns the value from row 2, not row 5.

**Why it's insidious:** When there are no NULLs, `LAG(..., 1 IGNORE NULLS)` is identical to `LAG(..., 1)`. The bug only appears when NULL gaps exist. The function name suggests "previous value, skipping NULLs" which sounds reasonable — but it changes the semantics from positional to logical proximity.

**Minimal repro:**
```sql
WITH metrics AS (
    SELECT * FROM (VALUES
        ('2024-01-01', 100),
        ('2024-01-02', NULL),
        ('2024-01-03', NULL),
        ('2024-01-04', 150)
    ) t(dt, val)
)
SELECT dt, val,
       LAG(val, 1)              OVER (ORDER BY dt) AS positional_lag,  -- NULL (the NULL row)
       LAG(val, 1 IGNORE NULLS) OVER (ORDER BY dt) AS logical_lag      -- 100 (skipped 2 NULLs)
FROM metrics;
```

**How to catch it:** Test the function on a dataset with known NULL gaps. Verify whether your intent is "positional predecessor" (use plain LAG) or "most recent non-NULL value" (use IGNORE NULLS). They are different functions with the same syntax structure.

**Real-world trigger:** Revenue per day with NULL for weekends/holidays. `LAG IGNORE NULLS` used to compute week-over-week change. For Monday values, the LAG returns the previous Friday — skipping 2 days — which creates correct WoW comparison. If someone adds `IGNORE NULLS` to a positional-based feature engineering pipeline, it silently changes the lag from "1 day" to "1 non-null day."

---

### Partition Column Type Mismatch — String Sort Order Breaks Partitions

**What it looks like:**
```sql
SELECT
    CAST(user_id AS VARCHAR) AS user_id_str,
    event_time,
    ROW_NUMBER() OVER (PARTITION BY CAST(user_id AS VARCHAR) ORDER BY event_time) AS rn
FROM events;
```

**What actually happens:** Partitioning by a VARCHAR-cast integer means partition boundaries are based on lexicographic grouping, not numeric grouping. All user_ids still group correctly into single partitions (each distinct string is still one partition). However, if the ORDER BY is also a VARCHAR-cast integer (`ORDER BY CAST(sequence_num AS VARCHAR)`), the sort within each partition is lexicographic: `'10'` before `'2'` before `'9'`.

**Why it's insidious:** The function produces row numbers. The partition is correct (each user is in their own partition). Only the ordering within the partition is silently wrong. `rn = 1` is the earliest event only if there are no lexicographic ordering surprises.

**Minimal repro:**
```sql
WITH events AS (
    SELECT * FROM (VALUES (1,'seq_2'),(1,'seq_10'),(1,'seq_9')) t(uid, seq)
)
SELECT uid, seq,
       ROW_NUMBER() OVER (PARTITION BY uid ORDER BY seq)     AS wrong_rn,  -- seq_10=1, seq_2=2, seq_9=3
       ROW_NUMBER() OVER (PARTITION BY uid ORDER BY seq::INT) AS right_rn  -- seq_2=1, seq_9=2, seq_10=3
       -- seq must be extracted as INT for numeric sort
```

**How to catch it:** Any `ORDER BY` inside a window function that operates on an ID or sequence number stored as VARCHAR needs an explicit numeric cast. Audit window functions for VARCHAR ORDER BY columns that represent numeric sequences.

**Real-world trigger:** Event sequence numbers stored as padded strings (`'001'`, `'002'`) work correctly. An upstream system change removes zero-padding (`'1'`, `'2'`, `'10'`). The ORDER BY suddenly becomes lexicographic. Session reconstruction based on sequence number assigns wrong first/last event positions.

---

### Window with ORDER BY on Non-Unique Column + ROWS Frame — Plan-Dependent Results

**What it looks like:**
```sql
SELECT
    user_id,
    event_date,
    revenue,
    SUM(revenue) OVER (
        PARTITION BY user_id
        ORDER BY event_date
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ) AS running_revenue
FROM user_revenue;
```

**What actually happens:** If multiple rows share the same `event_date` for the same `user_id`, and the ORDER BY inside the window is only `event_date` (not unique), then the ordering of tied rows is undefined. With `ROWS BETWEEN ... CURRENT ROW`, the running sum depends on the physical row order for the tie group — which can differ between query executions, query plans, or parallel execution segments.

**Why it's insidious:** `ROWS` frame (as opposed to `RANGE`) was chosen precisely to avoid the "all ties get same total" problem described above. But `ROWS` does not fix non-determinism of the tie order — it just means different rows can receive different running totals depending on which physical order the engine picks for the ties.

**Minimal repro:**
```sql
-- On the same data, two equivalent queries can produce different running totals:
-- Execution 1: rows ordered (date=Jan1, rev=100), (date=Jan1, rev=200) → running: 100, 300
-- Execution 2: rows ordered (date=Jan1, rev=200), (date=Jan1, rev=100) → running: 200, 300
-- Both are technically correct given the non-deterministic order.
-- But idempotent pipeline runs will produce different intermediate values.
```

**How to catch it:**
```sql
-- Add a deterministic tiebreaker to every window ORDER BY:
SUM(revenue) OVER (
    PARTITION BY user_id
    ORDER BY event_date, transaction_id  -- transaction_id is unique
    ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
)
```

**Real-world trigger:** Pipeline runs twice on the same day due to a retry. The two runs produce different running totals for days with multiple transactions. Downstream deduplication logic that uses the running total as a value (not just a row selector) ends up with conflicting records.

---


**What it looks like:**


**Why it's insidious:** The ratios always sum to exactly 1.0, which looks correct. The problem is that the denominator is the sum of *attributed* revenue, not *total* revenue. A NULL-revenue category with significant business volume silently disappears from the denominator, inflating every other category's share.

**Minimal repro:**

**How to catch it:**
```sql
-- Verify denominator matches expected total:
SELECT SUM(revenue) AS attributed, (SELECT SUM(revenue) FROM source_table) AS total
FROM category_revenue;
-- If attributed < total, NULLs are inflating ratios.
```

**Real-world trigger:** Market share analysis by product category. A new "Other" category was added to the data model but not yet populated (all NULLs). Each existing category's market share is silently overstated by the proportion that "Other" should represent.
