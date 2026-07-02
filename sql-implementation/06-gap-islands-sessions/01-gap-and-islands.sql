USE `sql-patterns`;

-- =============================================================================
-- GAP AND ISLANDS PATTERNS
-- Database: sql-patterns | Table: leave_requests
-- Techniques: ROW_NUMBER() date-subtraction trick, LAG/LEAD on boundaries,
--             WITH RECURSIVE date expansion, overlap detection
-- =============================================================================

-- =============================================================================
-- SECTION 1: CLASSIC ISLANDS VIA DATE EXPANSION (WITH RECURSIVE)
-- =============================================================================
-- Technique: expand every leave_request to one row per calendar day, then use
-- (calendar_date - ROW_NUMBER()) as the island key.  Consecutive calendar days
-- produce the same key because both the date and the row-number advance by 1.
-- =============================================================================

-- Step 1: expand each leave request into individual calendar days
WITH RECURSIVE date_series AS (
    -- anchor: the first day of every leave request
    SELECT
        request_id,
        emp_id,
        leave_type,
        start_date,
        end_date,
        start_date AS calendar_date
    FROM leave_requests

    UNION ALL

    -- recursive member: advance one day until end_date is reached
    SELECT
        ds.request_id,
        ds.emp_id,
        ds.leave_type,
        ds.start_date,
        ds.end_date,
        DATE_ADD(ds.calendar_date, INTERVAL 1 DAY)
    FROM date_series ds
    WHERE ds.calendar_date < ds.end_date
),

-- Step 2: assign a global row-number per employee ordered by calendar day
numbered AS (
    SELECT
        emp_id,
        calendar_date,
        ROW_NUMBER() OVER (PARTITION BY emp_id ORDER BY calendar_date) AS rn
    FROM (
        -- deduplicate: overlapping requests expand to the same calendar day twice
        SELECT DISTINCT emp_id, calendar_date
        FROM date_series
    ) deduped
),

-- Step 3: island_key = calendar_date - rn (constant within a consecutive run)
islands_raw AS (
    SELECT
        emp_id,
        calendar_date,
        DATE_SUB(calendar_date, INTERVAL rn DAY) AS island_key
    FROM numbered
)

-- Step 4: collapse each island to its start, end, and duration
SELECT
    ir.emp_id,
    e.first_name,
    e.last_name,
    MIN(ir.calendar_date)                          AS island_start,
    MAX(ir.calendar_date)                          AS island_end,
    DATEDIFF(MAX(ir.calendar_date), MIN(ir.calendar_date)) + 1 AS island_days
FROM islands_raw ir
JOIN employees e USING (emp_id)
GROUP BY ir.emp_id, e.first_name, e.last_name, ir.island_key
ORDER BY ir.emp_id, island_start;

/*
EXPECTED RESULT (selected employees):
emp_id | first_name | last_name | island_start | island_end | island_days
-------+------------+-----------+--------------+------------+------------
     5 | Emma       | Davis     | 2024-01-15   | 2024-01-19 |          5  ← requests 3+4 merged (consecutive)
     5 | Emma       | Davis     | 2024-03-05   | 2024-03-08 |          4  ← request 5 separate
     6 | Frank      | Brown     | 2024-05-13   | 2024-05-15 |          3  ← requests 17+18 merged (consecutive)
     7 | Grace      | Wilson    | 2024-02-01   | 2024-02-05 |          5  ← request 6 alone (Feb 6-7 gap)
     7 | Grace      | Wilson    | 2024-02-08   | 2024-02-12 |          5  ← request 7 alone
     9 | Iris       | Taylor    | 2024-05-01   | 2024-05-31 |         31  ← single long parental block
    12 | Liam       | Jackson   | 2024-04-10   | 2024-04-22 |         13  ← overlapping requests merged into one island
    16 | Peter      | Martinez  | 2023-12-27   | 2023-12-31 |          5  ← request 9 alone (Jan 1 gap)
    16 | Peter      | Martinez  | 2024-01-02   | 2024-01-05 |          4  ← request 10 alone
*/


-- =============================================================================
-- SECTION 2: ISLANDS WITHOUT DAY EXPANSION (START/END DATE APPROACH)
-- =============================================================================
-- Technique: tag a row as a "new island" when its start_date is more than one
-- day after the previous request's end_date (for the same employee).  A running
-- SUM of those flags produces a monotonically increasing island_id per employee.
-- This is faster than date expansion but treats each request atomically (does
-- not merge overlapping requests the same way Section 1 does).
-- =============================================================================

WITH ordered AS (
    SELECT
        request_id,
        emp_id,
        leave_type,
        start_date,
        end_date,
        -- previous request's end_date for this employee
        LAG(end_date) OVER (PARTITION BY emp_id ORDER BY start_date, request_id) AS prev_end
    FROM leave_requests
),

flagged AS (
    SELECT
        *,
        -- new island when there is no overlap/adjacency with the previous row
        CASE
            WHEN prev_end IS NULL THEN 1                       -- very first request for employee
            WHEN start_date > DATE_ADD(prev_end, INTERVAL 1 DAY) THEN 1  -- gap exists
            ELSE 0                                             -- consecutive or overlapping
        END AS new_island_flag
    FROM ordered
),

with_island_id AS (
    SELECT
        *,
        SUM(new_island_flag) OVER (
            PARTITION BY emp_id
            ORDER BY start_date, request_id
            ROWS UNBOUNDED PRECEDING
        ) AS island_id
    FROM flagged
)

SELECT
    w.emp_id,
    e.first_name,
    e.last_name,
    w.island_id,
    MIN(w.start_date)                                          AS island_start,
    MAX(w.end_date)                                            AS island_end,
    DATEDIFF(MAX(w.end_date), MIN(w.start_date)) + 1          AS total_days,
    COUNT(*)                                                   AS request_count
FROM with_island_id w
JOIN employees e USING (emp_id)
GROUP BY w.emp_id, e.first_name, e.last_name, w.island_id
ORDER BY w.emp_id, w.island_id;

/*
EXPECTED RESULT (selected employees):
emp_id | first_name | last_name | island_id | island_start | island_end | total_days | request_count
-------+------------+-----------+-----------+--------------+------------+------------+---------------
     5 | Emma       | Davis     |         1 | 2024-01-15   | 2024-01-19 |          5 |             2  ← requests 3+4
     5 | Emma       | Davis     |         2 | 2024-03-05   | 2024-03-08 |          4 |             1
     6 | Frank      | Brown     |         1 | 2024-05-13   | 2024-05-15 |          3 |             2  ← requests 17+18
     7 | Grace      | Wilson    |         1 | 2024-02-01   | 2024-02-05 |          5 |             1
     7 | Grace      | Wilson    |         2 | 2024-02-08   | 2024-02-12 |          5 |             1
     9 | Iris       | Taylor    |         1 | 2024-05-01   | 2024-05-31 |         31 |             1
    12 | Liam       | Jackson   |         1 | 2024-04-10   | 2024-04-22 |         13 |             2  ← overlapping merged
    16 | Peter      | Martinez  |         1 | 2023-12-27   | 2023-12-31 |          5 |             1
    16 | Peter      | Martinez  |         2 | 2024-01-02   | 2024-01-05 |          4 |             1
*/


-- =============================================================================
-- SECTION 3: DETECTING GAPS BETWEEN ISLANDS
-- =============================================================================
-- Technique: once islands are established, use LEAD() on island boundaries to
-- find the gap between the end of one island and the start of the next.
-- Gap start = previous island's end_date + 1 day
-- Gap end   = next island's start_date - 1 day
-- =============================================================================

WITH ordered AS (
    SELECT
        emp_id,
        start_date,
        end_date,
        LAG(end_date) OVER (PARTITION BY emp_id ORDER BY start_date, request_id) AS prev_end
    FROM leave_requests
),

flagged AS (
    SELECT *,
        CASE
            WHEN prev_end IS NULL THEN 1
            WHEN start_date > DATE_ADD(prev_end, INTERVAL 1 DAY) THEN 1
            ELSE 0
        END AS new_island_flag
    FROM ordered
),

with_island_id AS (
    SELECT *,
        SUM(new_island_flag) OVER (
            PARTITION BY emp_id ORDER BY start_date ROWS UNBOUNDED PRECEDING
        ) AS island_id
    FROM flagged
),

island_boundaries AS (
    SELECT
        emp_id,
        island_id,
        MIN(start_date) AS island_start,
        MAX(end_date)   AS island_end
    FROM with_island_id
    GROUP BY emp_id, island_id
)

SELECT
    b.emp_id,
    e.first_name,
    e.last_name,
    -- gap is between this island's end and the NEXT island's start
    DATE_ADD(b.island_end, INTERVAL 1 DAY)                                  AS gap_start,
    DATE_SUB(
        LEAD(b.island_start) OVER (PARTITION BY b.emp_id ORDER BY b.island_id),
        INTERVAL 1 DAY
    )                                                                        AS gap_end,
    DATEDIFF(
        DATE_SUB(
            LEAD(b.island_start) OVER (PARTITION BY b.emp_id ORDER BY b.island_id),
            INTERVAL 1 DAY
        ),
        b.island_end
    )                                                                        AS gap_days
FROM island_boundaries b
JOIN employees e USING (emp_id)
HAVING gap_start IS NOT NULL
   AND gap_end   IS NOT NULL
   AND gap_days  > 0
ORDER BY b.emp_id, gap_start;

/*
EXPECTED RESULT:
emp_id | first_name | last_name | gap_start  | gap_end    | gap_days
-------+------------+-----------+------------+------------+---------
     5 | Emma       | Davis     | 2024-01-20 | 2024-03-04 |       45  ← between Jan and Mar blocks
     7 | Grace      | Wilson    | 2024-02-06 | 2024-02-07 |        2  ← Feb 6-7 weekend gap
    16 | Peter      | Martinez  | 2024-01-01 | 2024-01-01 |        1  ← New Year's Day gap
*/


-- =============================================================================
-- SECTION 4: OVERLAPPING INTERVALS DETECTION
-- =============================================================================
-- Technique: self-join leave_requests for the same employee and check the
-- standard overlap condition:
--   A overlaps B  iff  A.start <= B.end  AND  A.end >= B.start
-- Using r1.request_id < r2.request_id avoids duplicate pairs.
-- This surfaces the data-quality FLAW for emp 12 (Liam Jackson).
-- =============================================================================

SELECT
    r1.emp_id,
    e.first_name,
    e.last_name,
    r1.request_id   AS request_id_1,
    r1.start_date   AS start_1,
    r1.end_date     AS end_1,
    r2.request_id   AS request_id_2,
    r2.start_date   AS start_2,
    r2.end_date     AS end_2,
    -- number of calendar days that overlap
    DATEDIFF(
        LEAST(r1.end_date, r2.end_date),
        GREATEST(r1.start_date, r2.start_date)
    ) + 1           AS overlap_days
FROM leave_requests r1
JOIN leave_requests r2
    ON  r1.emp_id      = r2.emp_id
    AND r1.request_id  < r2.request_id          -- each pair once
    AND r1.start_date <= r2.end_date             -- overlap condition part 1
    AND r1.end_date   >= r2.start_date           -- overlap condition part 2
JOIN employees e ON r1.emp_id = e.emp_id
ORDER BY r1.emp_id, r1.request_id;

/*
EXPECTED RESULT:
emp_id | first_name | last_name | request_id_1 | start_1    | end_1      | request_id_2 | start_2    | end_2      | overlap_days
-------+------------+-----------+--------------+------------+------------+--------------+------------+------------+-------------
    12 | Liam       | Jackson   |            1 | 2024-04-10 | 2024-04-17 |            2 | 2024-04-15 | 2024-04-22 |           3
DATA QUALITY FLAW: requests 1 and 2 for emp 12 overlap on 2024-04-15 through 2024-04-17 (3 days).
*/


-- =============================================================================
-- SECTION 5: GAPS IN SEQUENTIAL IDs (PURCHASE ORDERS EXAMPLE)
-- =============================================================================
-- Technique: use WITH RECURSIVE to generate every integer from 1 to
-- MAX(order_id), then LEFT JOIN to find IDs with no matching row.
-- Applicable to any table with a sequential primary key.
-- Demonstrated against leave_requests.request_id as a proxy.
-- =============================================================================

WITH RECURSIVE all_ids AS (
    -- anchor: start at 1
    SELECT 1 AS id

    UNION ALL

    -- recursive: increment until we reach the max request_id
    SELECT id + 1
    FROM all_ids
    WHERE id < (SELECT MAX(request_id) FROM leave_requests)
)

SELECT
    a.id                AS missing_request_id
FROM all_ids a
LEFT JOIN leave_requests lr ON a.id = lr.request_id
WHERE lr.request_id IS NULL
ORDER BY a.id;

/*
EXPECTED RESULT:
missing_request_id
------------------
(any integer from 1 to MAX(request_id) that has no row in leave_requests)
With 20 requests numbered 1-20 and no gaps: result set is empty.
If request_id values are non-contiguous (e.g., 1,2,3,5,6) then 4 would appear.

To apply the same pattern to a hypothetical purchase_orders table:
  WITH RECURSIVE seq AS (
      SELECT 1 AS n
      UNION ALL
      SELECT n + 1 FROM seq WHERE n < (SELECT MAX(order_id) FROM purchase_orders)
  )
  SELECT s.n AS missing_order_id
  FROM seq s
  LEFT JOIN purchase_orders po ON s.n = po.order_id
  WHERE po.order_id IS NULL;
*/
