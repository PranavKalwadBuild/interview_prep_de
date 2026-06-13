<!-- Part of sql-patterns: Duplicate Handling — Root Causes + Window Functions, LAG/LEAD, Running Aggregates, FIRST/LAST, Gap/Islands -->
<!-- Source: sql_patterns.md lines 14105–14388 -->

## 36. Duplicate Handling — Pattern-by-Pattern Deep Dive

Duplicates are the silent corrupting force in SQL analytics. Unlike NULLs, which propagate visibly through arithmetic and comparisons, duplicates pass through most queries undetected — inflating counts, distorting aggregations, and producing results that look correct but are wrong by 5%, 20%, or 10x. This section covers how duplicates manifest differently in each pattern and the precise fix for each.

---

### Root Causes Cheat Sheet

| Source | Mechanism | Typical Symptom |
|---|---|---|
| At-least-once delivery (Kafka, webhooks) | Same event delivered twice | SUM over-counts revenue |
| Pipeline retry on failure | INSERT runs twice | Duplicate rows with same PK |
| JOIN fan-out | Many-to-one join not pre-aggregated | Rows multiplied unexpectedly |
| UNION ALL without intent | Both sides contribute the same row | Double-counted records |
| Missed dedup in incremental load | New batch contains already-loaded rows | Cumulative inflated |
| Source system quirk | Two systems emit the same event | Counts > actual events |

---

### 36-A. Duplicates in Window Functions — Ranking

#### Problem 1 — Non-deterministic ROW_NUMBER due to tied ORDER BY

```sql
-- WRONG: ORDER BY updated_at alone — two rows with the same updated_at get
-- non-deterministic rn values. Which one gets rn=1 changes per execution.
WITH ranked AS (
    SELECT *,
        ROW_NUMBER() OVER (PARTITION BY user_id ORDER BY updated_at DESC) AS rn
    FROM user_events
)
SELECT * FROM ranked WHERE rn = 1;
-- If two events have identical updated_at, the "latest" record is random.

-- FIX: add a tiebreaker that is truly unique (event_id, surrogate key, load timestamp)
WITH ranked AS (
    SELECT *,
        ROW_NUMBER() OVER (
            PARTITION BY user_id
            ORDER BY updated_at DESC, event_id DESC   -- tiebreaker
        ) AS rn
    FROM user_events
)
SELECT * FROM ranked WHERE rn = 1;
```

#### Problem 2 — Duplicate rows inflate RANK / DENSE_RANK counts

```sql
-- Source has duplicate rows (same user_id + score). RANK gives both rn=1.
-- Downstream "top 3 users" query returns 4+ rows.

-- FIX: dedup source before ranking
WITH deduped AS (
    SELECT DISTINCT user_id, score   -- or ROW_NUMBER() if full dedup is needed
    FROM leaderboard
),
ranked AS (
    SELECT *, RANK() OVER (ORDER BY score DESC) AS rnk
    FROM deduped
)
SELECT * FROM ranked WHERE rnk <= 3;
```

---

### 36-B. Duplicates in LAG / LEAD

#### Problem — Duplicate timestamps make LAG return the wrong prior row

```sql
-- A user has two events on 2024-03-15 (retry caused a duplicate).
-- LAG returns the other duplicate as the "previous" event, not the actual prior day's event.

-- Timeline (wrong): 2024-03-14 → 2024-03-15 (dup1) → 2024-03-15 (dup2)
-- LAG for dup2 returns dup1 on same day — not 2024-03-14

-- FIX: dedup events by (user_id, event_date) before applying LAG
WITH deduped AS (
    SELECT user_id, event_date, SUM(amount) AS daily_amount
    FROM transactions
    GROUP BY user_id, event_date      -- collapse duplicates per day
),
lagged AS (
    SELECT *,
        LAG(daily_amount) OVER (PARTITION BY user_id ORDER BY event_date) AS prev_day_amount
    FROM deduped
)
SELECT * FROM lagged;
```

#### Problem — LEAD skips over duplicates, producing a misleading "next" value

```sql
-- If a user has two identical status events (PENDING, PENDING), LEAD returns PENDING
-- instead of the actual next distinct state.

-- FIX: deduplicate consecutive duplicates using LAG before applying LEAD
WITH consecutive_dedup AS (
    SELECT *,
        LAG(status) OVER (PARTITION BY user_id ORDER BY event_ts) AS prev_status
    FROM user_status_events
),
cleaned AS (
    SELECT * FROM consecutive_dedup
    WHERE status IS DISTINCT FROM prev_status   -- remove rows where status didn't change
)
SELECT *,
    LEAD(status) OVER (PARTITION BY user_id ORDER BY event_ts) AS next_status
FROM cleaned;
```

---

### 36-C. Duplicates in Running Aggregates

#### Problem — Duplicate transactions inflate the running total

```sql
-- A payment webhook fires twice → two rows for the same payment_id.
-- Running SUM double-counts that payment for all subsequent rows.

SELECT
    user_id,
    txn_date,
    amount,
    SUM(amount) OVER (PARTITION BY user_id ORDER BY txn_date
                      ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS running_total
FROM transactions;
-- If txn_id 'T999' appears twice → running_total is inflated from T999 onward.

-- FIX: dedup at the source CTE before computing the window
WITH deduped AS (
    SELECT DISTINCT ON (payment_id)   -- PostgreSQL; for other engines use ROW_NUMBER()
        user_id, txn_date, amount, payment_id
    FROM transactions
    ORDER BY payment_id, loaded_at DESC   -- keep latest load for the same payment
),
-- Generic (all engines):
deduped_generic AS (
    SELECT *,
        ROW_NUMBER() OVER (PARTITION BY payment_id ORDER BY loaded_at DESC) AS rn
    FROM transactions
),
cleaned AS (SELECT * FROM deduped_generic WHERE rn = 1)
SELECT
    user_id, txn_date, amount,
    SUM(amount) OVER (PARTITION BY user_id ORDER BY txn_date
                      ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS running_total
FROM cleaned;
```

---

### 36-D. Duplicates in FIRST_VALUE / LAST_VALUE

#### Problem — Duplicates at the boundary make FIRST_VALUE non-deterministic

```sql
-- Two rows with the same earliest timestamp → FIRST_VALUE picks one arbitrarily.
SELECT
    user_id,
    FIRST_VALUE(product_id) OVER (
        PARTITION BY user_id ORDER BY purchase_ts
    ) AS first_product_purchased
FROM purchases;
-- If two rows share the minimum purchase_ts, FIRST_VALUE is engine-dependent.

-- FIX: break the tie with a unique column
SELECT
    user_id,
    FIRST_VALUE(product_id) OVER (
        PARTITION BY user_id ORDER BY purchase_ts ASC, purchase_id ASC
    ) AS first_product_purchased
FROM purchases;

-- Alternatively: aggregate to guaranteed unique before the window
WITH first_purchase AS (
    SELECT user_id, MIN(purchase_ts) AS first_ts
    FROM purchases
    GROUP BY user_id
)
SELECT p.user_id, p.product_id AS first_product_purchased
FROM purchases p
JOIN first_purchase fp
    ON p.user_id = fp.user_id AND p.purchase_ts = fp.first_ts
QUALIFY ROW_NUMBER() OVER (PARTITION BY p.user_id ORDER BY p.purchase_id) = 1;
-- QUALIFY handles the residual tie on purchase_ts via purchase_id
```

---

### 36-E. Duplicates in Gap and Islands

#### Problem — Duplicate dates shatter the island logic

```sql
-- The standard gap-and-island technique:
--   island_id = date - ROW_NUMBER()  (constant within a consecutive streak)
-- Duplicate dates break this: ROW_NUMBER increments but date doesn't →
-- two different island_id values for the same streak date → streak split.

-- Login dates (raw, with duplicates):
-- user_id | login_date
-- 1       | 2024-01-01
-- 1       | 2024-01-01  ← duplicate
-- 1       | 2024-01-02

-- Without dedup:
-- rn=1 → 2024-01-01 - 1 = 2023-12-31 (island A)
-- rn=2 → 2024-01-01 - 2 = 2023-12-30 (island B) ← different island!
-- rn=3 → 2024-01-02 - 3 = 2023-12-30 (island B)
-- Result: streak of 2 days reported as two separate islands of length 1 and 2 — wrong.

-- FIX: always dedup dates before gap-and-island
WITH deduped_logins AS (
    SELECT DISTINCT user_id, login_date
    FROM user_logins
),
islands AS (
    SELECT
        user_id,
        login_date,
        login_date - CAST(ROW_NUMBER() OVER (
            PARTITION BY user_id ORDER BY login_date
        ) AS INT) AS island_id
    FROM deduped_logins
)
SELECT
    user_id,
    MIN(login_date) AS streak_start,
    MAX(login_date) AS streak_end,
    COUNT(*)        AS streak_length
FROM islands
GROUP BY user_id, island_id;
```

---

### 36-F. Duplicates in Sessionization

#### Problem — Duplicate events inflate session event count and corrupt session boundaries

```sql
-- A click event is delivered twice (at-least-once Kafka delivery).
-- The duplicate has the same event_ts as the original.
-- LAG-based session gap detection computes gap = 0 for the duplicate → it joins
-- the prior session instead of starting a new one. Session length is inflated.

-- FIX 1: dedup by event_id before sessionization
WITH deduped_events AS (
    SELECT *,
        ROW_NUMBER() OVER (PARTITION BY event_id ORDER BY loaded_at DESC) AS rn
    FROM clickstream
),
cleaned AS (
    SELECT * FROM deduped_events WHERE rn = 1
),
-- Now apply sessionization on cleaned
gaps AS (
    SELECT *,
        LAG(event_ts) OVER (PARTITION BY user_id ORDER BY event_ts) AS prev_ts
    FROM cleaned
),
sessions AS (
    SELECT *,
        SUM(CASE WHEN DATEDIFF('minute', prev_ts, event_ts) > 30 OR prev_ts IS NULL
                 THEN 1 ELSE 0 END)
            OVER (PARTITION BY user_id ORDER BY event_ts
                  ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS session_id
    FROM gaps
)
SELECT * FROM sessions;

-- FIX 2: if event_id is unavailable, dedup on (user_id, event_type, event_ts)
WITH deduped_events AS (
    SELECT DISTINCT user_id, event_type, event_ts, page_url
    FROM clickstream
)
...
```

---

