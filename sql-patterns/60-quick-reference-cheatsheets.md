<!-- sql-patterns: Quick Reference — Q21–Q24, Keyword→Pattern Map, Window Function Cheat Sheet -->

-- Method 1: Correlated subquery
SELECT t.*
FROM transactions t
WHERE t.amount > (
    SELECT AVG(t2.amount)
    FROM transactions t2
    WHERE t2.user_id = t.user_id
);

-- Method 2: Window function (more efficient — single table scan)
SELECT *
FROM (
    SELECT *,
           AVG(amount) OVER (PARTITION BY user_id) AS user_avg
    FROM transactions
) t
WHERE amount > user_avg;
---

# Q21. Count of Events in a Sliding 7-Day Window

**The question:** "For each day, count the number of orders placed in the prior 7 days (including today)."

```sql
SELECT
    order_date,
    COUNT(*) OVER (
        ORDER BY order_date
        RANGE BETWEEN INTERVAL '6 days' PRECEDING AND CURRENT ROW
    ) AS orders_last_7_days
FROM (
    SELECT DISTINCT order_date FROM orders
) daily
ORDER BY order_date;
---

### Q22. Compare Two Tables for Differences (Data Reconciliation)

**The question:** "Find rows that exist in table A but not in table B, and vice versa."

```sql
-- Rows in table_a but not table_b
SELECT 'only_in_a' AS source, id, col1, col2 FROM table_a
EXCEPT
SELECT 'only_in_a', id, col1, col2 FROM table_b

UNION ALL

-- Rows in table_b but not table_a
SELECT 'only_in_b', id, col1, col2 FROM table_b
EXCEPT
SELECT 'only_in_b', id, col1, col2 FROM table_a;

-- Full diff using FULL OUTER JOIN (shows modified values side by side)
SELECT
    COALESCE(a.id, b.id) AS id,
    a.col1 AS a_col1, b.col1 AS b_col1,
    CASE
        WHEN a.id IS NULL THEN 'only in B'
        WHEN b.id IS NULL THEN 'only in A'
        ELSE 'value differs'
    END AS diff_type
FROM table_a a
FULL OUTER JOIN table_b b ON a.id = b.id
WHERE a.col1 IS DISTINCT FROM b.col1   -- PostgreSQL syntax for NULL-safe compare
   OR a.id IS NULL OR b.id IS NULL;
---

# Q23. Customers Active in Both Periods (Retention)

**The question:** "Find customers who purchased in both Q1 2024 and Q2 2024."

```sql
-- INTERSECT approach
SELECT customer_id FROM orders WHERE order_date BETWEEN '2024-01-01' AND '2024-03-31'
INTERSECT
SELECT customer_id FROM orders WHERE order_date BETWEEN '2024-04-01' AND '2024-06-30';

-- Self-join approach (easier to extend to more periods)
SELECT q1.customer_id
FROM orders q1
JOIN orders q2 ON q1.customer_id = q2.customer_id
WHERE q1.order_date BETWEEN '2024-01-01' AND '2024-03-31'
  AND q2.order_date BETWEEN '2024-04-01' AND '2024-06-30'
GROUP BY q1.customer_id;
-- Slow: function on column prevents index use
WHERE YEAR(order_date) = 2024

-- Fast: range filter can use an index
WHERE order_date >= '2024-01-01' AND order_date < '2025-01-01'

-- Slow: correlated subquery re-runs for every outer row
SELECT * FROM orders o
WHERE amount > (SELECT AVG(amount) FROM orders WHERE customer_id = o.customer_id);

-- Fast: window function — single table scan
SELECT * FROM (
    SELECT *, AVG(amount) OVER (PARTITION BY customer_id) AS avg_amount FROM orders
) t WHERE amount > avg_amount;
---

---

## Quick Reference: Keyword → Pattern

| Keyword / Phrase | Pattern to Apply |
|---|---|
| "cannot use alias in WHERE", "window function in WHERE" | SQL Order of Execution (#0) |
| "consecutive", "streak", "in a row", "back-to-back" | Gap and Islands (#5) |
| "session", "idle timeout", "activity window", "episode" | Sessionization (#6) |
| "top N per", "highest per group", "leaderboard" | Top-N per Group (#8) + Window Ranking (#1) |
| "previous value", "change from prior", "time between events" | LAG/LEAD (#2) |
| "cumulative", "running total", "year-to-date", "balance so far" | Running Aggregates (#3, #24) |
| "moving average", "7-day rolling", "trailing N days" | Rolling Window (#9) |
| "MoM", "YoY", "vs last period", "QoQ", "same week last year" | Period-over-Period (#10) |
| "zero for missing days", "fill gaps", "date spine" | Date Spine (#11) |
| "cohort", "retention", "returning users", "engagement decay" | Cohort Analysis (#12) |
| "funnel", "conversion", "drop-off", "abandonment" | Funnel Analysis (#13) |
| "as of", "what was the value at the time", "effective date" | SCD Type 2 (#14) |
| "BUY vs SELL count", "breakdown by status", "split by" | Conditional Aggregation (#15) |
| "pairs", "within X minutes of each other", "same table twice" | Self Join (#16) |
| "hierarchy", "all subordinates", "org chart", "bill of materials" | Recursive CTE (#17) |
| "pivot", "one column per month", "rows to columns" | Pivot (#18) |
| "list of", "comma-separated per group", "collect all" | String Aggregation (#19) |
| "null check", "data quality", "freshness", "volume drop" | Data Quality Patterns (#20) |
| "in A but not B", "reconciliation delta", "appear in both" | Set Operations (#21) |
| "never did", "not in", "no match", "inactive", "lapsed" | Anti-Join (#22) |
| "median", "p90", "percentile", "distribution", "tail latency" | Percentiles (#23) |
| "missing IDs", "gaps in sequence", "skipped numbers" | Gaps in Sequential IDs (#29) |
| "deduplicate", "keep latest", "one per entity", "canonical record" | Deduplication (#7) |
| "quartile", "decile", "segment", "RFM", "spend tier" | NTILE (#27) |
| "slow query", "optimise", "reduce cost", "full table scan" | Performance Patterns (#30) |
| "extract year/month/week", "date truncation", "age", "fiscal" | Date Functions (#31) |
| "first ever in group", "opening value", "baseline" | FIRST_VALUE / LAST_VALUE (#4) |
| "frequently together", "co-occurrence", "cross-sell" | Market Basket (#25) |
| "current status", "latest state", "most recent record" | Latest Record per Entity (#28) |

---

## Window Function Cheat Sheet

```sql
-- Full syntax
FUNCTION_NAME() OVER (
    [PARTITION BY col1, col2]   -- group context
    [ORDER BY col3 DESC]        -- ordering within group
    [ROWS/RANGE BETWEEN ... AND ...]  -- frame definition
)

-- Common functions
ROW_NUMBER()          -- unique rank per row
RANK()                -- rank with gaps on ties
DENSE_RANK()          -- rank without gaps on ties
NTILE(n)              -- bucket into n groups
LAG(col, n, default)  -- value n rows before
LEAD(col, n, default) -- value n rows after
FIRST_VALUE(col)      -- first value in frame
LAST_VALUE(col)       -- last value in frame (needs explicit frame)
SUM/AVG/COUNT/MIN/MAX -- aggregate over window

-- Frame shortcuts
ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW    -- cumulative
ROWS BETWEEN 6 PRECEDING AND CURRENT ROW            -- rolling 7 rows
ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING  -- whole partition
---

