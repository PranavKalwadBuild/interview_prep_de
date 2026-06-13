<!-- Part of sql-patterns: Self Joins and Consecutive Row Comparisons -->
<!-- Source: sql_patterns.md lines 7972–8192 -->

## 16. Self Joins & Consecutive Row Comparisons

### What it solves

Compare a row with another row in the same table — pairs, hierarchies, consecutive events.

### Keywords to spot

> "pairs", "matches", "compare each row with another",
> "find users who traded with each other", "parent-child",
> "manager-employee", "transactions within X minutes of each other",
> "same table twice", "row compared to another row", "cross-reference within table",
> "events close together", "overlap", "simultaneous", "relate to itself"

### Business Context

- **Fintech:** Two trades from the same user within 5 minutes (wash trading / market manipulation detection); detect round-trip transactions (buy and sell of same asset within 1 hour)
- **E-commerce:** Find product pairs frequently bought together in the same order (market basket analysis seed data); identify orders placed by the same device within 10 minutes (potential duplicate order)
- **HR:** Self-join employees table to get manager name and grade alongside each employee; find all peer pairs in the same team for 360-review matching
- **Logistics:** Find consecutive shipment scans from the same carrier within 1 hour; detect overlapping delivery windows for the same driver
- **Fraud:** Two card transactions at different merchants within 2 minutes (physical impossibility — card cloning signal); accounts that share the same device ID or IP (account linkage graph)

### Boilerplate — Consecutive event pairs

```

```sql
-- Find pairs of trades by same user within 5 minutes
SELECT
    a.user_id,
    a.trade_id      AS trade1_id,
    b.trade_id      AS trade2_id,
    a.executed_at   AS trade1_time,
    b.executed_at   AS trade2_time,
    DATEDIFF('minute', a.executed_at, b.executed_at) AS minutes_apart
FROM trades a
JOIN trades b
    ON  a.user_id = b.user_id
    AND a.trade_id < b.trade_id          -- avoid duplicates and self-join
    AND DATEDIFF('minute', a.executed_at, b.executed_at) BETWEEN 0 AND 5;
```

### Boilerplate — Hierarchy (manager/employee)

```sql
-- employees(emp_id, emp_name, manager_id)
SELECT
    e.emp_id,
    e.emp_name,
    m.emp_name AS manager_name
FROM employees e
LEFT JOIN employees m ON e.manager_id = m.emp_id;
```

### Gotchas

- Always add `a.id < b.id` or `a.id != b.id` to avoid self-pairs and duplicates
- Self-joins on large tables are expensive — window functions (LAG/LEAD) are preferred for consecutive row comparisons
- For hierarchies deeper than 2 levels, use Recursive CTEs

### Edge Cases

#### Edge 16-A: Many-to-many self-join causes cartesian explosion

**Problem:**

```sql
-- Find all pairs of users in the same referral group
-- referrals(referrer_id, referred_id) is a many-to-many relationship

SELECT r1.referred_id AS user_a, r2.referred_id AS user_b
FROM referrals r1
JOIN referrals r2 ON r1.referrer_id = r2.referrer_id
WHERE r1.referred_id != r2.referred_id;
-- If one referrer has 1000 referred users → 1000 × 999 = 999,000 pairs
-- At 10,000 referred → 100,000,000 rows → OOM or very long query
```

**Fix — add deduplication to avoid (A,B) and (B,A) both appearing:**

```sql
-- FIX — add deduplication to avoid (A,B) and (B,A) both appearing:
WHERE r1.referred_id < r2.referred_id   -- only keep pairs where A < B (lexicographic)
-- Halves the result set

-- Also: if the table has millions of rows, consider whether a self-join is the right approach
-- Alternative: aggregate referred users per referrer into an array, then unnest and pair
```

#### Edge 16-B: Self join for "employee earns more than manager" breaks for CEO (NULL manager)

**Problem:**

```sql
-- Standard self-join for manager comparison:
SELECT e.emp_id, e.salary AS emp_salary, m.salary AS mgr_salary
FROM employees e
JOIN employees m ON e.manager_id = m.emp_id
WHERE e.salary > m.salary;
-- CEO has manager_id = NULL → e.manager_id = NULL → NULL = m.emp_id = UNKNOWN
-- CEO is excluded from the result — this is CORRECT (no manager to compare to)

-- But: if the question is "find employees who earn more than their manager OR have no manager"
LEFT JOIN employees m ON e.manager_id = m.emp_id
WHERE e.salary > m.salary OR m.emp_id IS NULL
-- CEO (no manager) is now included
```

**Fix:**

```sql
-- If the business question is 'employees who earn more than their manager':
-- INNER JOIN correctly excludes the CEO — document this:
SELECT e.emp_id, e.name, e.salary AS emp_salary,
       m.name AS manager_name, m.salary AS mgr_salary
FROM employees e
JOIN employees m ON e.manager_id = m.emp_id   -- CEO excluded (manager_id IS NULL)
WHERE e.salary > m.salary;

-- If the question includes 'OR have no manager' — use LEFT JOIN:
SELECT e.emp_id, e.name, e.salary,
    CASE
        WHEN m.emp_id IS NULL THEN 'No manager (CEO or top-level)'
        WHEN e.salary > m.salary THEN 'Earns more than manager'
        ELSE 'Does not earn more than manager'
    END AS comparison
FROM employees e
LEFT JOIN employees m ON e.manager_id = m.emp_id;
```

---

### At Scale

#### Failure Mechanism

Self-join for "trades within 5 minutes of each other":

```sql

```sql
JOIN trades b ON a.user_id = b.user_id AND DATEDIFF('minute', a.executed_at, b.executed_at) BETWEEN 0 AND 5
```

- This is an **inequality range join** — same problem as SCD2
- For a user with 10,000 trades: 10,000 × 10,000 = 100M pair comparisons just for that user
- For 1M active users: total comparisons can reach billions
- No hash join possible; Spark falls back to BroadcastNestedLoopJoin (extremely slow)

#### Code-Level Fix

```sql
-- BEFORE: self-join for wash trade detection (pairs within 5 minutes)
SELECT a.trade_id AS trade1, b.trade_id AS trade2
FROM trades a
JOIN trades b
    ON a.user_id = b.user_id
    AND a.trade_id < b.trade_id
    AND DATEDIFF('minute', a.executed_at, b.executed_at) BETWEEN 0 AND 5;
-- For 1M users × avg 100 trades each = 10B self-join rows before filter

-- FIX 1: Use LAG instead of self-join for "consecutive events" patterns
-- LAG only compares each row to its PREVIOUS row — O(N), not O(N²)
SELECT
    trade_id,
    user_id,
    executed_at,
    LAG(trade_id)    OVER (PARTITION BY user_id ORDER BY executed_at) AS prev_trade_id,
    LAG(executed_at) OVER (PARTITION BY user_id ORDER BY executed_at) AS prev_executed_at,
    DATEDIFF('minute',
        LAG(executed_at) OVER (PARTITION BY user_id ORDER BY executed_at),
        executed_at
    ) AS minutes_since_last_trade
FROM trades
WHERE DATEDIFF('minute',
    LAG(executed_at) OVER (PARTITION BY user_id ORDER BY executed_at),
    executed_at) <= 5;   -- can't use this in WHERE — use CTE
-- Correct approach:
WITH lagged AS (
    SELECT *,
        LAG(executed_at) OVER (PARTITION BY user_id ORDER BY executed_at) AS prev_at
    FROM trades
)
SELECT trade_id, user_id, executed_at, prev_at
FROM lagged
WHERE DATEDIFF('minute', prev_at, executed_at) <= 5;
-- O(N) not O(N²) — works on any size data

-- FIX 2: For all-pairs within window (not just consecutive): use sorted merge
-- Sort by (user_id, executed_at), then use a sliding window with pointer
-- This is best implemented in Spark DataFrames or a user-defined UDTF
-- Pure SQL self-join for all-pairs is fundamentally O(N²) — avoid at scale
```

#### System-Level Fix

```sql
-- For real-time fraud pair detection: use Apache Flink's temporal join or window join
-- Flink: join two streams within a time window without materialising all pairs
-- Pattern: for each trade event, check if another trade from the same user exists
-- in the last 5 minutes using Flink's interval join:
trades.joinLateral(
    trades,
    "a.user_id = b.user_id AND b.executed_at BETWEEN a.executed_at AND a.executed_at + 5.minutes"
) -- Flink pushes the 5-minute bound into the state TTL — O(N) state per user

-- Delta Lake: for batch wash-trade detection, use bucketing to avoid cross-node self-join
CREATE TABLE trades_bucketed
USING DELTA
CLUSTERED BY (user_id) INTO 500 BUCKETS;
-- Self-join on user_id with bucket join: each executor only self-joins its own bucket
-- Bucket size: 800M / 500 = 1.6M rows per bucket → 1.6M × 1.6M / 2 pairs max per bucket
-- With 5-minute time filter: much fewer actual pairs
```

```sql

---

---

