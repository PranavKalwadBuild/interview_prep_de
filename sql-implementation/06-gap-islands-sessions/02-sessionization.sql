USE `sql-patterns`;

-- =============================================================================
-- SESSIONIZATION PATTERNS
-- Database: sql-patterns | Table: emp_events
-- Techniques: LAG() gap detection, SUM() running island counter,
--             FIRST_VALUE / LAST_VALUE with explicit frames, cohort bucketing
-- Rule: 30-minute idle gap between consecutive events = new session boundary
-- =============================================================================

-- =============================================================================
-- SECTION 1: SESSION BOUNDARY DETECTION (DERIVE SESSIONS FROM RAW TIMESTAMPS)
-- =============================================================================
-- Technique: use LAG(event_ts) partitioned by emp_id to get the previous event
-- time, compute gap in minutes with TIMESTAMPDIFF, flag gaps > 30 minutes as
-- session boundaries, then accumulate a running SUM of flags to produce a
-- monotonically increasing session_num per employee.
-- NOTE: the pre-assigned session_id column is intentionally ignored here.
-- =============================================================================

WITH lagged AS (
    SELECT
        event_id,
        emp_id,
        event_type,
        event_ts,
        page,
        session_id,                                -- kept for cross-validation in Section 3
        LAG(event_ts) OVER (
            PARTITION BY emp_id
            ORDER BY event_ts
        ) AS prev_ts
    FROM emp_events
),

gaps AS (
    SELECT
        *,
        TIMESTAMPDIFF(MINUTE, prev_ts, event_ts) AS gap_minutes,
        CASE
            WHEN prev_ts IS NULL THEN 1            -- first event for employee = new session
            WHEN TIMESTAMPDIFF(MINUTE, prev_ts, event_ts) > 30 THEN 1
            ELSE 0
        END AS new_session_flag
    FROM lagged
),

with_session_num AS (
    SELECT
        *,
        SUM(new_session_flag) OVER (
            PARTITION BY emp_id
            ORDER BY event_ts
            ROWS UNBOUNDED PRECEDING
        ) AS session_num
    FROM gaps
)

SELECT
    event_id,
    emp_id,
    event_type,
    event_ts,
    gap_minutes,
    new_session_flag,
    session_num,
    CONCAT(emp_id, '-S', session_num)  AS derived_session_key
FROM with_session_num
ORDER BY emp_id, event_ts;

/*
EXPECTED RESULT (selected rows):
emp_id | event_type      | event_ts            | gap_minutes | new_session_flag | session_num | derived_session_key
-------+-----------------+---------------------+-------------+------------------+-------------+--------------------
     5 | login           | 2024-06-01 10:00:00 |        NULL |                1 |           1 | 5-S1
     5 | view_payslip    | 2024-06-01 10:04:00 |           4 |                0 |           1 | 5-S1
     5 | update_profile  | 2024-06-01 10:09:00 |           5 |                0 |           1 | 5-S1
     5 | submit_leave    | 2024-06-01 10:14:00 |           5 |                0 |           1 | 5-S1
     5 | logout          | 2024-06-01 10:20:00 |           6 |                0 |           1 | 5-S1
     5 | login           | 2024-06-01 14:00:00 |         220 |                1 |           2 | 5-S2  ← 220-min gap
     9 | logout          | 2024-06-01 09:18:00 |           6 |                0 |           1 | 9-S1
     9 | login           | 2024-06-01 11:02:00 |         104 |                1 |           2 | 9-S2  ← 104-min gap
    14 | login           | 2024-06-01 09:00:00 |        NULL |                1 |           1 | 14-S1  ← session_id IS NULL (FLAW)
*/


-- =============================================================================
-- SECTION 2: SESSION SUMMARY METRICS
-- =============================================================================
-- Technique: aggregate over (emp_id, session_num) computed in Section 1.
-- FIRST_VALUE and LAST_VALUE use explicit frame clauses because MySQL's default
-- frame is RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW, which causes
-- LAST_VALUE to return the current row rather than the partition tail.
-- =============================================================================

WITH lagged AS (
    SELECT
        event_id, emp_id, event_type, event_ts,
        LAG(event_ts) OVER (PARTITION BY emp_id ORDER BY event_ts) AS prev_ts
    FROM emp_events
),

with_session_num AS (
    SELECT
        *,
        SUM(CASE
                WHEN prev_ts IS NULL THEN 1
                WHEN TIMESTAMPDIFF(MINUTE, prev_ts, event_ts) > 30 THEN 1
                ELSE 0
            END) OVER (
            PARTITION BY emp_id ORDER BY event_ts ROWS UNBOUNDED PRECEDING
        ) AS session_num
    FROM lagged
),

session_metrics AS (
    SELECT
        emp_id,
        session_num,
        CONCAT(emp_id, '-S', session_num)           AS derived_session_key,
        MIN(event_ts)                               AS session_start,
        MAX(event_ts)                               AS session_end,
        TIMESTAMPDIFF(MINUTE, MIN(event_ts), MAX(event_ts)) AS session_duration_minutes,
        COUNT(*)                                    AS event_count,
        -- FIRST_VALUE: first event_type in the session
        FIRST_VALUE(event_type) OVER (
            PARTITION BY emp_id, session_num
            ORDER BY event_ts
            ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING
        )                                           AS first_event,
        -- LAST_VALUE requires ROWS BETWEEN ... UNBOUNDED FOLLOWING to reach the end
        LAST_VALUE(event_type) OVER (
            PARTITION BY emp_id, session_num
            ORDER BY event_ts
            ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING
        )                                           AS last_event
    FROM with_session_num
    GROUP BY emp_id, session_num, derived_session_key
)

SELECT
    *,
    CASE WHEN event_count = 1 THEN 'bounced' ELSE 'engaged' END AS session_quality
FROM session_metrics
ORDER BY emp_id, session_num;

/*
EXPECTED RESULT:
derived_session_key | session_start       | session_end         | session_duration_minutes | event_count | first_event | last_event     | session_quality
--------------------+---------------------+---------------------+--------------------------+-------------+-------------+----------------+----------------
5-S1                | 2024-06-01 10:00:00 | 2024-06-01 10:20:00 |                       20 |           5 | login       | logout         | engaged
5-S2                | 2024-06-01 14:00:00 | 2024-06-01 14:09:00 |                        9 |           3 | login       | logout         | engaged
9-S1                | 2024-06-01 09:00:00 | 2024-06-01 09:18:00 |                       18 |           4 | login       | logout         | engaged
9-S2                | 2024-06-01 11:02:00 | 2024-06-01 11:08:00 |                        6 |           2 | login       | submit_leave   | engaged  ← no logout (FLAW)
12-S1               | 2024-06-01 08:45:00 | 2024-06-01 08:57:00 |                       12 |           3 | login       | logout         | engaged
12-S2               | 2024-06-01 13:30:00 | 2024-06-01 13:40:00 |                       10 |           3 | login       | logout         | engaged
14-S1               | 2024-06-01 09:00:00 | 2024-06-01 09:45:00 |                       45 |           3 | login       | submit_leave   | engaged  ← all 3 NULL session_id events
*/


-- =============================================================================
-- SECTION 3: CROSS-VALIDATE AGAINST PRE-ASSIGNED SESSION_ID
-- =============================================================================
-- Technique: join derived session_num against the stored session_id column.
-- Events with NULL session_id are flagged as a data-quality flaw (emp 14).
-- The NULL events still form a coherent session under the 30-minute rule.
-- =============================================================================

-- 3a. Events with NULL session_id (data quality flaw — emp 14, Noah Harris)
SELECT
    ee.event_id,
    ee.emp_id,
    e.first_name,
    e.last_name,
    ee.event_type,
    ee.event_ts,
    ee.session_id                       AS stored_session_id,
    'NULL session_id — data flaw'       AS issue
FROM emp_events ee
JOIN employees e USING (emp_id)
WHERE ee.session_id IS NULL
ORDER BY ee.emp_id, ee.event_ts;

/*
EXPECTED RESULT:
event_id | emp_id | first_name | last_name | event_type      | event_ts            | stored_session_id | issue
---------+--------+------------+-----------+-----------------+---------------------+-------------------+--------------------------
      XX |     14 | Noah       | Harris    | login           | 2024-06-01 09:00:00 | NULL              | NULL session_id — data flaw
      XX |     14 | Noah       | Harris    | update_profile  | 2024-06-01 09:22:00 | NULL              | NULL session_id — data flaw
      XX |     14 | Noah       | Harris    | submit_leave    | 2024-06-01 09:45:00 | NULL              | NULL session_id — data flaw
All 3 events are within 30 minutes of each other → they belong to session 14-S1 by the derived rule.
*/

-- 3b. Side-by-side comparison of derived key vs stored session_id for all events
WITH lagged AS (
    SELECT
        event_id, emp_id, event_type, event_ts, session_id,
        LAG(event_ts) OVER (PARTITION BY emp_id ORDER BY event_ts) AS prev_ts
    FROM emp_events
),

with_session_num AS (
    SELECT
        *,
        SUM(CASE
                WHEN prev_ts IS NULL THEN 1
                WHEN TIMESTAMPDIFF(MINUTE, prev_ts, event_ts) > 30 THEN 1
                ELSE 0
            END) OVER (
            PARTITION BY emp_id ORDER BY event_ts ROWS UNBOUNDED PRECEDING
        ) AS session_num
    FROM lagged
)

SELECT
    event_id,
    emp_id,
    event_type,
    event_ts,
    session_id                              AS stored_session_id,
    CONCAT(emp_id, '-S', session_num)       AS derived_session_key,
    CASE
        WHEN session_id IS NULL THEN 'MISSING stored session_id'
        ELSE 'OK'
    END                                     AS validation_status
FROM with_session_num
ORDER BY emp_id, event_ts;


-- =============================================================================
-- SECTION 4: SESSION COUNTS PER EMPLOYEE
-- =============================================================================
-- Aggregate session-level metrics per employee.
-- Emp 9 (Iris Taylor) and emp 12 (Liam Jackson) each have 2 sessions.
-- =============================================================================

WITH lagged AS (
    SELECT
        event_id, emp_id, event_ts,
        LAG(event_ts) OVER (PARTITION BY emp_id ORDER BY event_ts) AS prev_ts
    FROM emp_events
),

with_session_num AS (
    SELECT
        *,
        SUM(CASE
                WHEN prev_ts IS NULL THEN 1
                WHEN TIMESTAMPDIFF(MINUTE, prev_ts, event_ts) > 30 THEN 1
                ELSE 0
            END) OVER (
            PARTITION BY emp_id ORDER BY event_ts ROWS UNBOUNDED PRECEDING
        ) AS session_num
    FROM lagged
),

session_summaries AS (
    SELECT
        emp_id,
        session_num,
        MIN(event_ts)  AS session_start,
        MAX(event_ts)  AS session_end,
        COUNT(*)       AS event_count,
        TIMESTAMPDIFF(MINUTE, MIN(event_ts), MAX(event_ts)) AS duration_minutes
    FROM with_session_num
    GROUP BY emp_id, session_num
)

SELECT
    ss.emp_id,
    e.first_name,
    e.last_name,
    COUNT(DISTINCT ss.session_num)              AS total_sessions,
    SUM(ss.event_count)                         AS total_events,
    ROUND(AVG(ss.duration_minutes), 1)          AS avg_session_length_minutes,
    MIN(ss.duration_minutes)                    AS min_session_minutes,
    MAX(ss.duration_minutes)                    AS max_session_minutes
FROM session_summaries ss
JOIN employees e USING (emp_id)
GROUP BY ss.emp_id, e.first_name, e.last_name
ORDER BY total_sessions DESC, ss.emp_id;

/*
EXPECTED RESULT:
emp_id | first_name | last_name | total_sessions | total_events | avg_session_length_minutes
-------+------------+-----------+----------------+--------------+---------------------------
     5 | Emma       | Davis     |              2 |            8 |                       14.5
     9 | Iris       | Taylor    |              2 |            6 |                       12.0
    12 | Liam       | Jackson   |              2 |            6 |                       11.0
     6 | Frank      | Brown     |              1 |            3 |                        X.X
     7 | Grace      | Wilson    |              1 |            3 |                        X.X
     8 | Henry      | Moore     |              1 |            5 |                        X.X
    14 | Noah       | Harris    |              1 |            3 |                       45.0
    20 | Tom        | Lewis     |              1 |            3 |                        X.X
    25 | Anna       | Parker    |              1 |            3 |                        X.X
*/


-- =============================================================================
-- SECTION 5: LONGEST AND SHORTEST SESSIONS
-- =============================================================================
-- RANK() by duration DESC per employee surfaces the longest session first.
-- Sessions where all events share the same timestamp have duration = 0.
-- =============================================================================

WITH lagged AS (
    SELECT
        event_id, emp_id, event_ts,
        LAG(event_ts) OVER (PARTITION BY emp_id ORDER BY event_ts) AS prev_ts
    FROM emp_events
),

with_session_num AS (
    SELECT
        *,
        SUM(CASE
                WHEN prev_ts IS NULL THEN 1
                WHEN TIMESTAMPDIFF(MINUTE, prev_ts, event_ts) > 30 THEN 1
                ELSE 0
            END) OVER (
            PARTITION BY emp_id ORDER BY event_ts ROWS UNBOUNDED PRECEDING
        ) AS session_num
    FROM lagged
),

session_durations AS (
    SELECT
        emp_id,
        session_num,
        CONCAT(emp_id, '-S', session_num)                       AS derived_session_key,
        MIN(event_ts)                                           AS session_start,
        MAX(event_ts)                                           AS session_end,
        TIMESTAMPDIFF(MINUTE, MIN(event_ts), MAX(event_ts))    AS duration_minutes,
        COUNT(*)                                                AS event_count
    FROM with_session_num
    GROUP BY emp_id, session_num
)

SELECT
    sd.emp_id,
    e.first_name,
    e.last_name,
    sd.derived_session_key,
    sd.session_start,
    sd.session_end,
    sd.duration_minutes,
    sd.event_count,
    RANK() OVER (PARTITION BY sd.emp_id ORDER BY sd.duration_minutes DESC) AS rank_longest,
    RANK() OVER (PARTITION BY sd.emp_id ORDER BY sd.duration_minutes ASC)  AS rank_shortest,
    CASE WHEN sd.duration_minutes = 0 THEN 'zero-duration session' ELSE NULL END AS flag
FROM session_durations sd
JOIN employees e USING (emp_id)
ORDER BY sd.emp_id, rank_longest;

/*
EXPECTED RESULT:
emp_id | first_name | derived_session_key | duration_minutes | rank_longest | rank_shortest | flag
-------+------------+---------------------+------------------+--------------+---------------+------
     5 | Emma       | 5-S1                |               20 |            1 |             2 | NULL
     5 | Emma       | 5-S2                |                9 |            2 |             1 | NULL
     9 | Iris       | 9-S1                |               18 |            1 |             2 | NULL
     9 | Iris       | 9-S2                |                6 |            2 |             1 | NULL
    12 | Liam       | 12-S1               |               12 |            1 |             2 | NULL
    12 | Liam       | 12-S2               |               10 |            2 |             1 | NULL
Sessions with duration_minutes = 0 would be flagged "zero-duration session".
*/


-- =============================================================================
-- SECTION 6: SESSION COHORT BY HOUR-OF-DAY
-- =============================================================================
-- Bucket each session's start time into 4 time-of-day periods based on the
-- hour of session_start (HOUR() extracts 0-23 from a DATETIME).
-- =============================================================================

WITH lagged AS (
    SELECT
        event_id, emp_id, event_ts,
        LAG(event_ts) OVER (PARTITION BY emp_id ORDER BY event_ts) AS prev_ts
    FROM emp_events
),

with_session_num AS (
    SELECT
        *,
        SUM(CASE
                WHEN prev_ts IS NULL THEN 1
                WHEN TIMESTAMPDIFF(MINUTE, prev_ts, event_ts) > 30 THEN 1
                ELSE 0
            END) OVER (
            PARTITION BY emp_id ORDER BY event_ts ROWS UNBOUNDED PRECEDING
        ) AS session_num
    FROM lagged
),

session_starts AS (
    SELECT
        emp_id,
        session_num,
        MIN(event_ts) AS session_start
    FROM with_session_num
    GROUP BY emp_id, session_num
),

bucketed AS (
    SELECT
        emp_id,
        session_num,
        session_start,
        HOUR(session_start) AS start_hour,
        CASE
            WHEN HOUR(session_start) BETWEEN  6 AND 11 THEN 'Morning (06-11)'
            WHEN HOUR(session_start) BETWEEN 12 AND 17 THEN 'Afternoon (12-17)'
            WHEN HOUR(session_start) BETWEEN 18 AND 23 THEN 'Evening (18-23)'
            ELSE                                            'Night (00-05)'
        END AS time_bucket
    FROM session_starts
)

SELECT
    time_bucket,
    COUNT(*) AS session_count
FROM bucketed
GROUP BY time_bucket
ORDER BY
    FIELD(time_bucket,
        'Morning (06-11)',
        'Afternoon (12-17)',
        'Evening (18-23)',
        'Night (00-05)'
    );

/*
EXPECTED RESULT (all sample sessions occur during business hours):
time_bucket        | session_count
-------------------+--------------
Morning (06-11)    |             X   ← sessions starting 06:00–11:59 (e.g., 09-S1, 12-S1, 14-S1, 9-S2, etc.)
Afternoon (12-17)  |             X   ← sessions starting 12:00–17:59 (e.g., 5-S2 at 14:00, 12-S2 at 13:30)
Evening (18-23)    |             0
Night (00-05)      |             0
*/


-- =============================================================================
-- SECTION 7: MISSING LOGOUT DETECTION (DATA QUALITY FLAWS)
-- =============================================================================
-- Technique: find the last event per (emp_id, session_num) and check whether
-- it equals 'logout'.  Sessions without a logout are incomplete/abandoned.
-- Known flaws: sess-9B (emp 9, Iris Taylor) and sess-7A (emp 7, Grace Wilson).
-- MySQL 8.0 has no LAST_VALUE with IGNORE NULLS, so use a subquery or
-- LAST_VALUE with ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING.
-- =============================================================================

WITH lagged AS (
    SELECT
        event_id, emp_id, event_type, event_ts,
        LAG(event_ts) OVER (PARTITION BY emp_id ORDER BY event_ts) AS prev_ts
    FROM emp_events
),

with_session_num AS (
    SELECT
        *,
        SUM(CASE
                WHEN prev_ts IS NULL THEN 1
                WHEN TIMESTAMPDIFF(MINUTE, prev_ts, event_ts) > 30 THEN 1
                ELSE 0
            END) OVER (
            PARTITION BY emp_id ORDER BY event_ts ROWS UNBOUNDED PRECEDING
        ) AS session_num
    FROM lagged
),

session_last_event AS (
    -- MAX(event_ts) per session to identify the final event
    SELECT
        emp_id,
        session_num,
        MAX(event_ts) AS last_event_ts
    FROM with_session_num
    GROUP BY emp_id, session_num
)

SELECT
    w.emp_id,
    e.first_name,
    e.last_name,
    w.session_num,
    CONCAT(w.emp_id, '-S', w.session_num)  AS derived_session_key,
    w.event_ts                             AS last_event_ts,
    w.event_type                           AS last_event_type,
    CASE
        WHEN w.event_type != 'logout' THEN 'MISSING LOGOUT — session incomplete'
        ELSE 'OK'
    END                                    AS logout_status
FROM with_session_num w
JOIN session_last_event sle
    ON  w.emp_id      = sle.emp_id
    AND w.session_num = sle.session_num
    AND w.event_ts    = sle.last_event_ts
JOIN employees e USING (emp_id)
ORDER BY w.emp_id, w.session_num;

/*
EXPECTED RESULT:
emp_id | first_name | last_name | session_num | derived_session_key | last_event_type | logout_status
-------+------------+-----------+-------------+---------------------+-----------------+---------------------------------------
     5 | Emma       | Davis     |           1 | 5-S1                | logout          | OK
     5 | Emma       | Davis     |           2 | 5-S2                | logout          | OK
     6 | Frank      | Brown     |           1 | 6-S1                | logout          | OK
     7 | Grace      | Wilson    |           1 | 7-S1                | update_profile  | MISSING LOGOUT — session incomplete  ← FLAW
     8 | Henry      | Moore     |           1 | 8-S1                | logout          | OK
     9 | Iris       | Taylor    |           1 | 9-S1                | logout          | OK
     9 | Iris       | Taylor    |           2 | 9-S2                | submit_leave    | MISSING LOGOUT — session incomplete  ← FLAW
    12 | Liam       | Jackson   |           1 | 12-S1               | logout          | OK
    12 | Liam       | Jackson   |           2 | 12-S2               | logout          | OK
    14 | Noah       | Harris    |           1 | 14-S1               | submit_leave    | MISSING LOGOUT — session incomplete  ← also missing (NULL session_id flaw)
    20 | Tom        | Lewis     |           1 | 20-S1               | logout          | OK
    25 | Anna       | Parker    |           1 | 25-S1               | logout          | OK
*/
