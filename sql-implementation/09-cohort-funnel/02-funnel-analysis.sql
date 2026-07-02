USE `sql-patterns`;

-- ============================================================
-- FILE: 09-cohort-funnel/02-funnel-analysis.sql
-- DATABASE: sql-patterns
-- TOPIC: Funnel Analysis — simple funnel, strict ordered funnel,
--        session-scoped funnel, time-to-convert, drop-off,
--        funnel by day, repeat users
-- KEY FLAWS IN DATA:
--   emp 14   session_id = NULL (3 events — untracked device)
--   emp 14   skips login->view_payslip->update_profile; direct submit_leave
--            -> reveals data quality issue (strict funnel excludes them)
--   emp 12   submits leave in sess-12B without having updated profile ever
--   emp 9    sess-9A (login->view->update->logout) + sess-9B (submit_leave only)
--   emp 5    sess-5A (full user funnel) + sess-5B (approve_leave path)
--   approve_leave = manager action; excluded from user funnel steps
-- FUNNEL STEP ORDER: login -> view_payslip -> update_profile -> submit_leave -> logout
-- ============================================================


-- ============================================================
-- 1. SIMPLE FUNNEL — DISTINCT USERS AT EACH STEP
-- Count distinct emp_id per funnel step regardless of order.
-- Conversion rate = step_count / previous_step_count.
-- NOTE: submit_leave (5) > update_profile (4) because emp 12 and
--       emp 14 never did update_profile but did submit_leave.
--       This reveals a data quality / step-skipping issue.
-- ============================================================

WITH funnel_steps AS (
    SELECT 1 AS step_order, 'login'          AS step_name UNION ALL
    SELECT 2,               'view_payslip'                UNION ALL
    SELECT 3,               'update_profile'              UNION ALL
    SELECT 4,               'submit_leave'                UNION ALL
    SELECT 5,               'logout'
),
step_counts AS (
    SELECT
        fs.step_order,
        fs.step_name,
        COUNT(DISTINCT e.emp_id) AS users_reached
    FROM funnel_steps fs
    LEFT JOIN emp_events e ON e.event_type = fs.step_name
    GROUP BY fs.step_order, fs.step_name
)
SELECT
    sc.step_order,
    sc.step_name,
    sc.users_reached,
    LAG(sc.users_reached) OVER (ORDER BY sc.step_order)    AS prev_step_users,
    CASE
        WHEN LAG(sc.users_reached) OVER (ORDER BY sc.step_order) IS NULL
            THEN 100.0
        ELSE ROUND(
            sc.users_reached
            / LAG(sc.users_reached) OVER (ORDER BY sc.step_order) * 100, 1)
    END                                                     AS conversion_from_prev_pct
FROM step_counts sc
ORDER BY sc.step_order;

-- Expected (simple funnel, no ordering enforcement):
-- step 1 login:          9 users  (emp 5,6,7,8,9,12,14,20,25) -- conv 100%
-- step 2 view_payslip:   7 users  (emp 5,6,7,8,9,12,25)       -- conv 77.8%
-- step 3 update_profile: 4 users  (emp 5,7,8,9)               -- conv 57.1%
-- step 4 submit_leave:   5 users  (emp 5,8,9,12,14)           -- conv 125.0%  ANOMALY
-- step 5 logout:         7 users  (emp 5,6,8,9,12,20,25)      -- conv 140.0%  ANOMALY
-- submit_leave > update_profile = data quality issue (emp 12, emp 14 skipped steps)


-- ============================================================
-- 2. STRICT ORDERED FUNNEL
-- Each step requires ALL prior steps completed in order.
-- Step 2 base = step 1 users who ALSO had view_payslip AFTER login.
-- CTE chain: each CTE filters from the previous step's set.
-- ============================================================

WITH
-- Step 1: all employees who logged in (get their earliest login timestamp)
step1_login AS (
    SELECT emp_id, MIN(event_ts) AS login_ts
    FROM emp_events
    WHERE event_type = 'login'
    GROUP BY emp_id
),
-- Step 2: from step1, those who viewed payslip AFTER their login
step2_view AS (
    SELECT s1.emp_id,
           s1.login_ts,
           MIN(e.event_ts) AS view_ts
    FROM step1_login s1
    JOIN emp_events e
        ON e.emp_id = s1.emp_id
       AND e.event_type = 'view_payslip'
       AND e.event_ts > s1.login_ts
    GROUP BY s1.emp_id, s1.login_ts
),
-- Step 3: from step2, those who updated profile AFTER view_payslip
step3_update AS (
    SELECT s2.emp_id,
           s2.login_ts,
           s2.view_ts,
           MIN(e.event_ts) AS update_ts
    FROM step2_view s2
    JOIN emp_events e
        ON e.emp_id = s2.emp_id
       AND e.event_type = 'update_profile'
       AND e.event_ts > s2.view_ts
    GROUP BY s2.emp_id, s2.login_ts, s2.view_ts
),
-- Step 4: from step3, those who submitted leave AFTER update_profile
step4_submit AS (
    SELECT s3.emp_id,
           s3.login_ts,
           s3.view_ts,
           s3.update_ts,
           MIN(e.event_ts) AS submit_ts
    FROM step3_update s3
    JOIN emp_events e
        ON e.emp_id = s3.emp_id
       AND e.event_type = 'submit_leave'
       AND e.event_ts > s3.update_ts
    GROUP BY s3.emp_id, s3.login_ts, s3.view_ts, s3.update_ts
),
-- Step 5: from step4, those who logged out AFTER submit_leave
step5_logout AS (
    SELECT s4.emp_id,
           s4.login_ts,
           s4.view_ts,
           s4.update_ts,
           s4.submit_ts,
           MIN(e.event_ts) AS logout_ts
    FROM step4_submit s4
    JOIN emp_events e
        ON e.emp_id = s4.emp_id
       AND e.event_type = 'logout'
       AND e.event_ts > s4.submit_ts
    GROUP BY s4.emp_id, s4.login_ts, s4.view_ts, s4.update_ts, s4.submit_ts
),
funnel_counts AS (
    SELECT 1 AS step_order, 'login'          AS step_name, COUNT(*) AS users_reached FROM step1_login UNION ALL
    SELECT 2,               'view_payslip',                 COUNT(*) FROM step2_view   UNION ALL
    SELECT 3,               'update_profile',               COUNT(*) FROM step3_update UNION ALL
    SELECT 4,               'submit_leave',                 COUNT(*) FROM step4_submit UNION ALL
    SELECT 5,               'logout',                       COUNT(*) FROM step5_logout
)
SELECT
    step_order,
    step_name,
    users_reached,
    LAG(users_reached) OVER (ORDER BY step_order)      AS prev_step_users,
    CASE
        WHEN LAG(users_reached) OVER (ORDER BY step_order) IS NULL THEN 100.0
        ELSE ROUND(
            users_reached
            / LAG(users_reached) OVER (ORDER BY step_order) * 100, 1)
    END                                                AS conversion_pct,
    ROUND(users_reached / MAX(users_reached) OVER () * 100, 1)
                                                       AS overall_pct
FROM funnel_counts
ORDER BY step_order;

-- Expected (strict ordered funnel):
-- step 1 login:          9  -- 100% overall
-- step 2 view_payslip:   7  -- 77.8% of step1
-- step 3 update_profile: 4  -- 57.1% of step2
-- step 4 submit_leave:   3  -- 75.0% of step3  (emp 5, 8, 9 only)
-- step 5 logout:         3  -- 100% of step4   (same 3: emp 5, 8, 9)
-- emp 7: updated profile but never submitted leave -> drops at step 4
-- emp 14: in simple funnel submit_leave but excluded here (no login->view->update chain)


-- ============================================================
-- 3. FUNNEL WITH SESSION CONTEXT (30-MINUTE GAP RULE)
-- Assign sessions by: new session if gap from previous event > 30 min.
-- Strict funnel steps must all occur within the same derived session.
-- emp 9 crossed session boundaries (sess-9A login+view+update, sess-9B submit)
-- should NOT count as completing submit_leave step within one session.
-- ============================================================

WITH
event_with_gap AS (
    SELECT
        event_id,
        emp_id,
        event_type,
        event_ts,
        session_id,
        LAG(event_ts) OVER (PARTITION BY emp_id ORDER BY event_ts)  AS prev_ts,
        CASE
            WHEN LAG(event_ts) OVER (PARTITION BY emp_id ORDER BY event_ts) IS NULL
                THEN 1
            WHEN TIMESTAMPDIFF(MINUTE,
                    LAG(event_ts) OVER (PARTITION BY emp_id ORDER BY event_ts),
                    event_ts) > 30
                THEN 1
            ELSE 0
        END AS is_new_session
    FROM emp_events
),
event_with_session AS (
    SELECT
        event_id,
        emp_id,
        event_type,
        event_ts,
        session_id                                                   AS original_session_id,
        SUM(is_new_session) OVER (
            PARTITION BY emp_id
            ORDER BY event_ts
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        )                                                            AS derived_session_num
    FROM event_with_gap
),
sess_step1 AS (
    SELECT emp_id, derived_session_num, MIN(event_ts) AS login_ts
    FROM event_with_session
    WHERE event_type = 'login'
    GROUP BY emp_id, derived_session_num
),
sess_step2 AS (
    SELECT s1.emp_id, s1.derived_session_num, s1.login_ts,
           MIN(e.event_ts) AS view_ts
    FROM sess_step1 s1
    JOIN event_with_session e
        ON e.emp_id = s1.emp_id
       AND e.derived_session_num = s1.derived_session_num
       AND e.event_type = 'view_payslip'
       AND e.event_ts > s1.login_ts
    GROUP BY s1.emp_id, s1.derived_session_num, s1.login_ts
),
sess_step3 AS (
    SELECT s2.emp_id, s2.derived_session_num, s2.login_ts, s2.view_ts,
           MIN(e.event_ts) AS update_ts
    FROM sess_step2 s2
    JOIN event_with_session e
        ON e.emp_id = s2.emp_id
       AND e.derived_session_num = s2.derived_session_num
       AND e.event_type = 'update_profile'
       AND e.event_ts > s2.view_ts
    GROUP BY s2.emp_id, s2.derived_session_num, s2.login_ts, s2.view_ts
),
sess_step4 AS (
    SELECT s3.emp_id, s3.derived_session_num,
           s3.login_ts, s3.view_ts, s3.update_ts,
           MIN(e.event_ts) AS submit_ts
    FROM sess_step3 s3
    JOIN event_with_session e
        ON e.emp_id = s3.emp_id
       AND e.derived_session_num = s3.derived_session_num
       AND e.event_type = 'submit_leave'
       AND e.event_ts > s3.update_ts
    GROUP BY s3.emp_id, s3.derived_session_num, s3.login_ts, s3.view_ts, s3.update_ts
),
sess_step5 AS (
    SELECT s4.emp_id, s4.derived_session_num,
           s4.login_ts, s4.view_ts, s4.update_ts, s4.submit_ts,
           MIN(e.event_ts) AS logout_ts
    FROM sess_step4 s4
    JOIN event_with_session e
        ON e.emp_id = s4.emp_id
       AND e.derived_session_num = s4.derived_session_num
       AND e.event_type = 'logout'
       AND e.event_ts > s4.submit_ts
    GROUP BY s4.emp_id, s4.derived_session_num,
             s4.login_ts, s4.view_ts, s4.update_ts, s4.submit_ts
),
session_funnel_counts AS (
    SELECT 1 AS step_order, 'login'          AS step_name, COUNT(DISTINCT emp_id) AS users FROM sess_step1 UNION ALL
    SELECT 2,               'view_payslip',                 COUNT(DISTINCT emp_id) FROM sess_step2          UNION ALL
    SELECT 3,               'update_profile',               COUNT(DISTINCT emp_id) FROM sess_step3          UNION ALL
    SELECT 4,               'submit_leave',                 COUNT(DISTINCT emp_id) FROM sess_step4          UNION ALL
    SELECT 5,               'logout',                       COUNT(DISTINCT emp_id) FROM sess_step5
)
SELECT
    step_order,
    step_name,
    users                                                           AS users_in_session,
    LAG(users) OVER (ORDER BY step_order)                          AS prev_step_users,
    CASE
        WHEN LAG(users) OVER (ORDER BY step_order) IS NULL THEN 100.0
        ELSE ROUND(users / LAG(users) OVER (ORDER BY step_order) * 100, 1)
    END                                                            AS conversion_pct
FROM session_funnel_counts
ORDER BY step_order;

-- Expected (session-scoped strict funnel):
-- login:          9  (unique employees across all sessions)
-- view_payslip:   7  (within same derived session as login)
-- update_profile: 4  (emp 5, 7, 8, 9 -- all within single session)
-- submit_leave:   2  (emp 5 sess-5A, emp 8 sess-8A -- all 4 steps in 1 session)
--                    emp 9: login+view+update in sess-9A, submit in sess-9B -> excluded
-- logout:         2  (emp 5, emp 8)


-- ============================================================
-- 4. TIME-TO-CONVERT AT EACH STEP (FULL FUNNEL COMPLETERS)
-- For the 3 employees who completed the strict funnel (emp 5, 8, 9):
-- time from login to each subsequent step in seconds.
-- Uses TIMESTAMPDIFF(SECOND, ...) for MySQL compatibility.
-- ============================================================

WITH
step1_login AS (
    SELECT emp_id, MIN(event_ts) AS login_ts
    FROM emp_events
    WHERE event_type = 'login'
    GROUP BY emp_id
),
step2_view AS (
    SELECT s1.emp_id, s1.login_ts, MIN(e.event_ts) AS view_ts
    FROM step1_login s1
    JOIN emp_events e ON e.emp_id = s1.emp_id
        AND e.event_type = 'view_payslip' AND e.event_ts > s1.login_ts
    GROUP BY s1.emp_id, s1.login_ts
),
step3_update AS (
    SELECT s2.emp_id, s2.login_ts, s2.view_ts, MIN(e.event_ts) AS update_ts
    FROM step2_view s2
    JOIN emp_events e ON e.emp_id = s2.emp_id
        AND e.event_type = 'update_profile' AND e.event_ts > s2.view_ts
    GROUP BY s2.emp_id, s2.login_ts, s2.view_ts
),
step4_submit AS (
    SELECT s3.emp_id, s3.login_ts, s3.view_ts, s3.update_ts,
           MIN(e.event_ts) AS submit_ts
    FROM step3_update s3
    JOIN emp_events e ON e.emp_id = s3.emp_id
        AND e.event_type = 'submit_leave' AND e.event_ts > s3.update_ts
    GROUP BY s3.emp_id, s3.login_ts, s3.view_ts, s3.update_ts
),
step5_logout AS (
    SELECT s4.emp_id, s4.login_ts, s4.view_ts, s4.update_ts, s4.submit_ts,
           MIN(e.event_ts) AS logout_ts
    FROM step4_submit s4
    JOIN emp_events e ON e.emp_id = s4.emp_id
        AND e.event_type = 'logout' AND e.event_ts > s4.submit_ts
    GROUP BY s4.emp_id, s4.login_ts, s4.view_ts, s4.update_ts, s4.submit_ts
)
-- Per-employee conversion times
SELECT
    s5.emp_id,
    TIMESTAMPDIFF(SECOND, s5.login_ts, s5.view_ts)     AS sec_login_to_view,
    TIMESTAMPDIFF(SECOND, s5.login_ts, s5.update_ts)   AS sec_login_to_update,
    TIMESTAMPDIFF(SECOND, s5.login_ts, s5.submit_ts)   AS sec_login_to_submit,
    TIMESTAMPDIFF(SECOND, s5.login_ts, s5.logout_ts)   AS sec_login_to_logout
FROM step5_logout s5
ORDER BY s5.emp_id;

-- Aggregated conversion times:
WITH
step1_login AS (SELECT emp_id, MIN(event_ts) AS login_ts FROM emp_events WHERE event_type = 'login' GROUP BY emp_id),
step2_view   AS (SELECT s1.emp_id, s1.login_ts, MIN(e.event_ts) AS view_ts   FROM step1_login s1 JOIN emp_events e ON e.emp_id=s1.emp_id AND e.event_type='view_payslip'   AND e.event_ts>s1.login_ts GROUP BY s1.emp_id,s1.login_ts),
step3_update AS (SELECT s2.emp_id, s2.login_ts, s2.view_ts, MIN(e.event_ts) AS update_ts FROM step2_view s2 JOIN emp_events e ON e.emp_id=s2.emp_id AND e.event_type='update_profile' AND e.event_ts>s2.view_ts GROUP BY s2.emp_id,s2.login_ts,s2.view_ts),
step4_submit AS (SELECT s3.emp_id, s3.login_ts, s3.view_ts, s3.update_ts, MIN(e.event_ts) AS submit_ts FROM step3_update s3 JOIN emp_events e ON e.emp_id=s3.emp_id AND e.event_type='submit_leave' AND e.event_ts>s3.update_ts GROUP BY s3.emp_id,s3.login_ts,s3.view_ts,s3.update_ts),
step5_logout AS (SELECT s4.emp_id, s4.login_ts, s4.view_ts, s4.update_ts, s4.submit_ts, MIN(e.event_ts) AS logout_ts FROM step4_submit s4 JOIN emp_events e ON e.emp_id=s4.emp_id AND e.event_type='logout' AND e.event_ts>s4.submit_ts GROUP BY s4.emp_id,s4.login_ts,s4.view_ts,s4.update_ts,s4.submit_ts)
SELECT
    ROUND(AVG(TIMESTAMPDIFF(SECOND, login_ts, view_ts)),   1) AS avg_sec_to_view,
    MIN(TIMESTAMPDIFF(SECOND, login_ts, view_ts))             AS min_sec_to_view,
    MAX(TIMESTAMPDIFF(SECOND, login_ts, view_ts))             AS max_sec_to_view,
    ROUND(AVG(TIMESTAMPDIFF(SECOND, login_ts, update_ts)), 1) AS avg_sec_to_update,
    ROUND(AVG(TIMESTAMPDIFF(SECOND, login_ts, submit_ts)), 1) AS avg_sec_to_submit,
    ROUND(AVG(TIMESTAMPDIFF(SECOND, login_ts, logout_ts)), 1) AS avg_sec_to_logout
FROM step5_logout;

-- Expected (3 completers: emp 5, 8, 9):
-- emp 5 (sess-5A 2024-01-15): login=10:00, view=10:04, update=10:09, submit=10:14, logout=10:20
--   sec_to_view=240, sec_to_update=540, sec_to_submit=840, sec_to_logout=1200
-- emp 8 (sess-8A 2024-01-16): login=15:00, view=15:03, update=15:08, submit=15:14, logout=15:21
--   sec_to_view=180, sec_to_update=480, sec_to_submit=840, sec_to_logout=1260
-- emp 9: login=09:00 (sess-9A), submit=11:08 (sess-9B) -> large gap (~7680s to submit)
--   included in strict funnel (no session boundary constraint), inflates avg_sec_to_submit


-- ============================================================
-- 5. DROP-OFF ANALYSIS
-- For each funnel step: employees who completed THIS step
-- but did NOT complete the NEXT step (by strict ordering).
-- ============================================================

WITH
step1_login AS (
    SELECT emp_id, MIN(event_ts) AS login_ts
    FROM emp_events WHERE event_type = 'login'
    GROUP BY emp_id
),
step2_view AS (
    SELECT s1.emp_id, s1.login_ts, MIN(e.event_ts) AS view_ts
    FROM step1_login s1
    JOIN emp_events e ON e.emp_id=s1.emp_id
        AND e.event_type='view_payslip' AND e.event_ts>s1.login_ts
    GROUP BY s1.emp_id, s1.login_ts
),
step3_update AS (
    SELECT s2.emp_id, s2.login_ts, s2.view_ts, MIN(e.event_ts) AS update_ts
    FROM step2_view s2
    JOIN emp_events e ON e.emp_id=s2.emp_id
        AND e.event_type='update_profile' AND e.event_ts>s2.view_ts
    GROUP BY s2.emp_id, s2.login_ts, s2.view_ts
),
step4_submit AS (
    SELECT s3.emp_id, s3.login_ts, s3.view_ts, s3.update_ts, MIN(e.event_ts) AS submit_ts
    FROM step3_update s3
    JOIN emp_events e ON e.emp_id=s3.emp_id
        AND e.event_type='submit_leave' AND e.event_ts>s3.update_ts
    GROUP BY s3.emp_id, s3.login_ts, s3.view_ts, s3.update_ts
),
step5_logout AS (
    SELECT s4.emp_id, s4.submit_ts, MIN(e.event_ts) AS logout_ts
    FROM step4_submit s4
    JOIN emp_events e ON e.emp_id=s4.emp_id
        AND e.event_type='logout' AND e.event_ts>s4.submit_ts
    GROUP BY s4.emp_id, s4.submit_ts
)
SELECT
    'login_no_view'       AS drop_off_stage,
    GROUP_CONCAT(s1.emp_id ORDER BY s1.emp_id SEPARATOR ', ') AS dropped_emp_ids,
    COUNT(*)                                                   AS drop_count
FROM step1_login s1
LEFT JOIN step2_view s2 ON s1.emp_id = s2.emp_id
WHERE s2.emp_id IS NULL

UNION ALL

SELECT
    'viewed_no_update',
    GROUP_CONCAT(s2.emp_id ORDER BY s2.emp_id SEPARATOR ', '),
    COUNT(*)
FROM step2_view s2
LEFT JOIN step3_update s3 ON s2.emp_id = s3.emp_id
WHERE s3.emp_id IS NULL

UNION ALL

SELECT
    'updated_no_submit',
    GROUP_CONCAT(s3.emp_id ORDER BY s3.emp_id SEPARATOR ', '),
    COUNT(*)
FROM step3_update s3
LEFT JOIN step4_submit s4 ON s3.emp_id = s4.emp_id
WHERE s4.emp_id IS NULL

UNION ALL

SELECT
    'submitted_no_logout',
    GROUP_CONCAT(s4.emp_id ORDER BY s4.emp_id SEPARATOR ', '),
    COUNT(*)
FROM step4_submit s4
LEFT JOIN step5_logout s5 ON s4.emp_id = s5.emp_id
WHERE s5.emp_id IS NULL;

-- Expected:
-- login_no_view:     emp 14, 20  -> 2  (emp 14 no login->view chain; emp 20 only approved leave)
-- viewed_no_update:  emp 6, 25   -> 2  (viewed payslip then logged out without updating profile)
-- updated_no_submit: emp 7       -> 1  (updated profile, no submit_leave after)
-- submitted_no_logout: emp 9     -> 1  (sess-9B has submit_leave but no logout in data)


-- ============================================================
-- 6. FUNNEL BY DAY
-- Strict funnel completion counts aggregated by DATE(login event_ts).
-- Login event dates in data: 2024-01-15, 2024-01-16, 2024-02-05,
--   2024-02-20, 2024-03-15
-- emp 14 events on 2024-03-10 have no login event -> not counted here.
-- ============================================================

WITH
step1_login AS (
    SELECT emp_id, MIN(event_ts) AS login_ts, DATE(MIN(event_ts)) AS login_date
    FROM emp_events WHERE event_type = 'login'
    GROUP BY emp_id
),
step2_view AS (
    SELECT s1.emp_id, s1.login_ts, s1.login_date, MIN(e.event_ts) AS view_ts
    FROM step1_login s1
    JOIN emp_events e ON e.emp_id=s1.emp_id
        AND e.event_type='view_payslip' AND e.event_ts>s1.login_ts
    GROUP BY s1.emp_id, s1.login_ts, s1.login_date
),
step3_update AS (
    SELECT s2.emp_id, s2.login_ts, s2.login_date, s2.view_ts, MIN(e.event_ts) AS update_ts
    FROM step2_view s2
    JOIN emp_events e ON e.emp_id=s2.emp_id
        AND e.event_type='update_profile' AND e.event_ts>s2.view_ts
    GROUP BY s2.emp_id, s2.login_ts, s2.login_date, s2.view_ts
),
step4_submit AS (
    SELECT s3.emp_id, s3.login_date, s3.login_ts, s3.view_ts, s3.update_ts,
           MIN(e.event_ts) AS submit_ts
    FROM step3_update s3
    JOIN emp_events e ON e.emp_id=s3.emp_id
        AND e.event_type='submit_leave' AND e.event_ts>s3.update_ts
    GROUP BY s3.emp_id, s3.login_date, s3.login_ts, s3.view_ts, s3.update_ts
)
SELECT
    s1.login_date                              AS event_day,
    COUNT(DISTINCT s1.emp_id)                  AS step1_login,
    COUNT(DISTINCT s2.emp_id)                  AS step2_view,
    COUNT(DISTINCT s3.emp_id)                  AS step3_update,
    COUNT(DISTINCT s4.emp_id)                  AS step4_submit
FROM step1_login s1
LEFT JOIN step2_view   s2 ON s1.emp_id = s2.emp_id
LEFT JOIN step3_update s3 ON s1.emp_id = s3.emp_id
LEFT JOIN step4_submit s4 ON s1.emp_id = s4.emp_id
GROUP BY s1.login_date
ORDER BY s1.login_date;

-- Expected:
-- 2024-01-15: step1=3 (emp 5,6,9), step2=3, step3=2 (emp 5,9), step4=1 (emp 5)
--             emp 9 login in sess-9A on 2024-01-15; submit in sess-9B same day
--             strict funnel counts emp 9 at step4 (cross-session allowed in section 2)
-- 2024-01-16: step1=2 (emp 7,8), step2=2, step3=2, step4=1 (emp 8)
-- 2024-02-05: step1=1 (emp 12), step2=1, step3=0, step4=0
-- 2024-02-20: step1=1 (emp 20), step2=0, step3=0, step4=0
-- 2024-03-15: step1=1 (emp 25), step2=1, step3=0, step4=0


-- ============================================================
-- 7. REPEAT USERS — EMPLOYEES WITH EVENTS IN MORE THAN 1 SESSION
-- Count sessions per employee; flag multi-session users.
-- emp 5:  sess-5A (full funnel) + sess-5B (approve_leave path)
-- emp 9:  sess-9A (login->view->update->logout) + sess-9B (login->submit_leave)
-- emp 12: sess-12A (login->view->logout) + sess-12B (login->submit->logout)
-- emp 14: NULL session_id for all 3 events -> COUNT(DISTINCT NULL) = 1 in MySQL
-- ============================================================

WITH session_counts AS (
    SELECT
        emp_id,
        COUNT(DISTINCT session_id)  AS distinct_sessions,
        GROUP_CONCAT(DISTINCT session_id ORDER BY session_id SEPARATOR ' | ')
                                    AS session_ids,
        COUNT(*)                    AS total_events,
        GROUP_CONCAT(DISTINCT event_type ORDER BY event_type SEPARATOR ', ')
                                    AS event_types_seen
    FROM emp_events
    GROUP BY emp_id
)
SELECT
    sc.emp_id,
    CONCAT(e.first_name, ' ', e.last_name)     AS full_name,
    sc.distinct_sessions,
    sc.session_ids,
    sc.total_events,
    sc.event_types_seen,
    CASE WHEN sc.distinct_sessions > 1
         THEN 'multi-session' ELSE 'single-session' END  AS session_type
FROM session_counts sc
JOIN employees e ON e.emp_id = sc.emp_id
ORDER BY sc.distinct_sessions DESC, sc.emp_id;

-- Summary: multi-session vs single-session employee counts
SELECT
    SUM(CASE WHEN session_ct > 1 THEN 1 ELSE 0 END) AS multi_session_employees,
    SUM(CASE WHEN session_ct = 1 THEN 1 ELSE 0 END) AS single_session_employees,
    COUNT(*)                                         AS total_employees_with_events
FROM (
    SELECT emp_id, COUNT(DISTINCT session_id) AS session_ct
    FROM emp_events
    GROUP BY emp_id
) AS per_emp;

-- Expected:
-- 9 total employees with events
-- multi-session: emp 5, emp 9, emp 12 -> 3 employees
-- single-session: emp 6, 7, 8, 14, 20, 25 -> 6 employees
-- emp 14: all 3 events have NULL session_id; COUNT(DISTINCT NULL)=1 in MySQL
--         so emp 14 counts as single-session despite being untracked
