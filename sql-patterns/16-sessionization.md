<!-- sql-patterns: Sessionization Pattern -->

# Sessionization

## What it solves

Group user activity events into "sessions" — a session ends when there is a gap of more than N minutes between events.

## Keywords to spot

> "session", "visit", "within X minutes of each other", "idle timeout",
> "group activity events", "how long did the session last",
> "inactivity period", "engagement window",
> "burst of activity", "episode", "interaction window", "bounce",
> "restart after gap", "new visit", "activity cluster", "conversation thread"

## Business Context

- **Product Analytics:** Group app events into sessions (30-min inactivity = new session); compute session duration, events per session, and bounce rate (single-event sessions)
- **E-commerce:** Group page views into shopping sessions; sessions per user per day; detect "window shoppers" (many sessions, no purchase) vs "decisive buyers" (1 session, purchase)
- **Gaming:** Group play events into game sessions; measure average session length per level; identify players whose sessions are getting shorter (early churn signal)
- **Support/Chat:** Group support ticket interactions into a single conversation thread by customer (20-min gap = new conversation); measure first-response time per session
- **Fintech:** Group rapid-fire trades by the same user within 60 seconds (algorithmic trading detection); identify "panic selling" sessions where a user places multiple sells in a short window
- **Streaming/Media:** Group content play events into viewing sessions; identify binge sessions (> 3 episodes back-to-back)

## Boilerplate

```sql
-- Business: group user app events into sessions (30-min inactivity = new session)
WITH with_prev_time AS (
    SELECT
        user_id,
        event_type,
        event_at,
        LAG(event_at) OVER (PARTITION BY user_id ORDER BY event_at) AS prev_event_at
    FROM user_events
),

session_breaks AS (
    SELECT *,
        CASE
            WHEN prev_event_at IS NULL
            THEN 1 ELSE 0
        END AS is_new_session
    FROM with_prev_time
),

with_session_id AS (
    SELECT *,
        SUM(is_new_session) OVER (
            PARTITION BY user_id
            ORDER BY event_at
        ) AS session_id
    FROM session_breaks
)

SELECT
    user_id,
    session_id,
    MIN(event_at)                               AS session_start,
    MAX(event_at)                               AS session_end,
    COUNT(*)                                    AS events_in_session
FROM with_session_id
GROUP BY user_id, session_id;
```

## Gotchas

- Sessionization is gap-and-islands applied to time gaps — the only difference is the break condition uses a time threshold instead of a value condition
- Single-event sessions are valid (duration = 0)

## Edge Cases

### Edge 6-A: Multiple events at the exact same timestamp

**Problem:**

```sql
-- Two events at identical timestamps: which one is "first"? Which gap do you compute?
-- LAG on tied timestamps is non-deterministic

WITH lagged AS (
    SELECT user_id, event_at, event_type,
        LAG(event_at) OVER (PARTITION BY user_id ORDER BY event_at) AS prev_event_at
        -- TRAP: with two events at 14:00:00, one arbitrarily gets prev = NULL (treated as session start)
        -- and the other gets prev = 14:00:00 (0 gap = same session)
    FROM user_events
)
```

**Fix — add a tiebreaker to ORDER BY:**

```sql
LAG(event_at) OVER (PARTITION BY user_id ORDER BY event_at, event_id)
-- Now the order is deterministic. Two events at 14:00:00 will always be ordered by event_id.
-- The gap between them = 0 seconds < 30 minutes → same session (correct)
```

### Edge 6-B: Session spanning midnight — date-based aggregation breaks

**Problem:**

```sql
-- A session starting at 23:45 on Jan 1 and ending at 00:15 on Jan 2
-- If you aggregate sessions by DATE(session_start), this session appears under Jan 1
-- But if you aggregate by DATE(event_at) for each event, events span two days

-- Session-level: group all events by session_id, report by DATE(MIN(event_at))
-- Event-level: each event keeps its own date — cross-midnight sessions contribute to two dates

-- For reporting "daily active sessions", use session start time:
SELECT
    DATE(session_start) AS activity_date,
    COUNT(DISTINCT session_id) AS sessions
FROM sessions
GROUP BY 1;
-- This is usually correct — a session "belongs" to the day it started
```

**Fix:**

```sql
-- Always anchor session-level reporting to session_start (not per-event date),
-- and document the choice clearly:
SELECT
    DATE(session_start) AS activity_date,    -- session belongs to the day it started
    COUNT(DISTINCT session_id)  AS sessions,
    COUNT(DISTINCT user_id)     AS active_users
FROM sessions
GROUP BY DATE(session_start)
ORDER BY activity_date;
-- For cross-midnight sessions: the full session is attributed to the start day.
-- If you need per-event daily counts instead, use event_at not session_start and 
-- accept that one session can contribute to two calendar days.
```

### Edge 6-C: Very long gap at the end of data — open sessions

**Problem:**

```sql
-- The last event of a user never has a "next event" — LAG/LEAD of the last row returns NULL
-- For open-ended sessions (user might still be active): session end is undefined

WITH lagged AS (
    SELECT *,
        LEAD(event_at) OVER (PARTITION BY user_id ORDER BY event_at) AS next_event_at
    FROM user_events
),
session_boundaries AS (
    SELECT *,
        CASE
            WHEN next_event_at IS NULL THEN 1               -- last event = session end (open)
            WHEN next_event_at - event_at > INTERVAL '30 min' THEN 1
            ELSE 0
        END AS is_session_end
    FROM lagged
)
-- The last event in the ENTIRE table (next_event_at IS NULL) is marked as a session end
-- This is usually correct. But it conflates two cases:
-- 1. User genuinely left (gap > 30 min, but no next event to prove it)
-- 2. User's session is still ongoing (data was cut off at query time)
```

**Fix — separate "last event in data" from "last event with large gap":**

```sql
-- FIX — separate "last event in data" from "last event with large gap":
CASE
    WHEN next_event_at IS NULL
         AND event_at < NOW() - INTERVAL '30 min' THEN 1   -- old enough to call closed
    WHEN next_event_at IS NULL                             THEN 0   -- recent — session may be open
    WHEN next_event_at - event_at > INTERVAL '30 min'     THEN 1
    ELSE 0
END AS is_session_end
---

### At Scale

#### Failure Mechanism

```

user_events: 2B rows (all time)
PARTITION BY user_id ORDER BY event_at → full shuffle of 2B rows
For a user with 5M events: entire 5M row partition in one executor's memory
Session boundary detection: O(N) sequential scan per partition (can't parallelise within partition)

```

**File system amplification:** event tables often have millions of small files (one per minute from streaming) — each 5MB file has per-file overhead → `PARTITION BY user_id` reads thousands of files per user.

#### Code-Level Fix

```sql
-- BEFORE: sessionize entire 2B row history
WITH lagged AS (
    SELECT user_id, event_at, event_type,
        LAG(event_at) OVER (PARTITION BY user_id ORDER BY event_at) AS prev_event_at
    FROM user_events    -- 2B rows
)
...

-- FIX 1: Process only the active session window (last 24h or last N days)
WITH lagged AS (
    SELECT user_id, event_at, event_type,
        LAG(event_at) OVER (PARTITION BY user_id ORDER BY event_at) AS prev_event_at
    FROM user_events
    WHERE event_at >= CURRENT_TIMESTAMP - INTERVAL '24' HOUR
),
...

-- FIX 2: Maintain sessions incrementally.
-- Process only new events since the last successful watermark, update open sessions,
-- and close sessions once no new event has arrived within the inactivity threshold.
    .groupBy(
        session_window($"event_at", "30 minutes"),
        $"user_id"
    )
    .agg(
        count("*").as("event_count"),
        min("event_at").as("session_start"),
        max("event_at").as("session_end")
    )
-- This is exactly the SQL sessionization pattern but in streaming — O(1) state per active session
```

#### System-Level Fix

```sql
-- Run nightly after streaming ingestion:
OPTIMIZE user_events
WHERE event_date = CURRENT_DATE - 1   -- compact yesterday's files

-- Target file size: 128MB–512MB (Delta default: 1GB, often too large for streaming data)
ALTER TABLE user_events SET TBLPROPERTIES (
    'delta.targetFileSize' = '134217728'  -- 128MB per file
);

-- Sessionization queries (PARTITION BY user_id ORDER BY event_at) prune micro-partitions
-- by user_id first → reads only micro-partitions containing that user's events

-- Session queries: partition pruning by date, cluster pruning by user_id
-- Cost: pay only for partitions and clusters accessed
CREATE OR REPLACE TABLE user_events
PARTITION BY DATE(event_at)
OPTIONS (partition_expiration_days = 365)
AS SELECT * FROM raw_user_events;
---

---

