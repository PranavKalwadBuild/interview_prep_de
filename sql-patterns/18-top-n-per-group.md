<!-- sql-patterns: Top-N per Group -->

# Top-N per Group

## What it solves

Select the top N rows within each group (category, user, date, etc.).

## Keywords to spot

> "top 3 per", "best performing per category", "highest N per",
> "most recent N per user", "for each X find the top Y",
> "top performers in each", "leading N by", "worst N per",
> "bottom N", "podium for each", "top contributors per", "highest scoring per group"

## Business Context

- **Fintech:** Top 3 traded pairs per user per month (personalised dashboard); top 5 users by trading volume per day (leaderboard); worst 3 performing assets per portfolio per quarter
- **E-commerce:** Top 3 best-selling products per category (homepage merchandising); top 5 customers by revenue per region (key account management); bottom 5 rated sellers per category
- **SaaS:** Top 3 most-used features per account tier (product roadmap prioritisation); top 10 error types per service per week (on-call prioritisation)
- **Media/Content:** Top 5 most-watched videos per genre per month (recommendation carousel); top 3 creators by subscriber growth per week
- **Logistics:** Top 3 carriers by on-time delivery rate per origin city; worst 5 routes by average delay per quarter
- **HR:** Top 3 highest-earning employees per department (pay equity audit); top 5 employees by tenure per job grade

## Boilerplate

```sql
-- Pattern: Top-3 trading pairs per user by volume
WITH ranked AS (
    SELECT
        user_id,
        trading_pair,
        SUM(trade_amount) AS total_volume,
        DENSE_RANK() OVER (
            PARTITION BY user_id
            ORDER BY SUM(trade_amount) DESC
        ) AS rnk
    FROM trades
    GROUP BY user_id, trading_pair
)
SELECT user_id, trading_pair, total_volume, rnk
FROM ranked
WHERE rnk <= 3;

-- Note: Cannot use window function directly on aggregated column in one step
-- Must wrap in a CTE or subquery first
```

## Gotchas

- You cannot filter on a window function alias in the same SELECT — must wrap in a subquery/CTE
- Use `DENSE_RANK` if ties should share a rank. Use `ROW_NUMBER` if you want exactly N rows.

## Edge Cases

### Edge 8-A: Group has fewer than N rows

**Problem:**

```sql
-- "Find top 5 transactions per user"
-- Users with fewer than 5 transactions: all their rows are returned (rn <= 5 always true)
-- This is CORRECT BEHAVIOUR — but easy to misinterpret as "at least 5 transactions per user"

WITH ranked AS (
    SELECT *,
        ROW_NUMBER() OVER (PARTITION BY user_id ORDER BY amount DESC) AS rn
    FROM transactions
)
SELECT * FROM ranked WHERE rn <= 5;
-- User U1 has 3 transactions → all 3 appear in result (rn = 1, 2, 3 — all <= 5)
-- This is usually what you want: "show up to 5"
-- If you want EXACTLY 5 (exclude users with fewer): add HAVING COUNT(*) >= 5 in a prior CTE

WITH user_txn_counts AS (
    SELECT user_id FROM transactions GROUP BY user_id HAVING COUNT(*) >= 5
),
ranked AS (
    SELECT t.*,
        ROW_NUMBER() OVER (PARTITION BY t.user_id ORDER BY t.amount DESC) AS rn
    FROM transactions t
    WHERE t.user_id IN (SELECT user_id FROM user_txn_counts)
)
SELECT * FROM ranked WHERE rn <= 5;
```

**Fix:**

```sql
-- If "at least N" is the requirement, pre-filter users before ranking:
WITH user_txn_counts AS (
    SELECT user_id FROM transactions
    GROUP BY user_id
    HAVING COUNT(*) >= 5    -- only users with 5+ transactions
),
ranked AS (
    SELECT t.*,
        ROW_NUMBER() OVER (PARTITION BY t.user_id ORDER BY t.amount DESC) AS rn
    FROM transactions t
    WHERE t.user_id IN (SELECT user_id FROM user_txn_counts)
)
SELECT * FROM ranked WHERE rn <= 5;
-- Users with fewer than 5 transactions are excluded entirely.
-- If "up to N" is acceptable (show all rows for users with fewer than N), 
-- simply omit the pre-filter — the original query is already correct.
```

### Edge 8-B: All rows in a group are tied — ROW_NUMBER vs DENSE_RANK give very different results

**Problem:**

```sql
-- All 10 transactions for user U1 have amount = 1000
-- "Top 3" means what?

-- ROW_NUMBER: assigns 1,2,3,4,...10 arbitrarily → returns 3 rows (non-deterministic which 3)
-- RANK:       all rows get rank 1 → WHERE rnk <= 3 returns ALL 10 rows (not 3!)
-- DENSE_RANK: same as RANK in this case → all 10 rows returned

-- Be explicit about which function matches the business question:
-- "Top 3 rows regardless of ties" → ROW_NUMBER + tiebreaker
-- "Top 3 rank positions (may return more than 3 rows on ties)" → DENSE_RANK

-- Fintech example: top 3 borrowers by loan amount for a credit review
-- If 5 borrowers all have the same maximum loan amount:
-- Business wants to review exactly 3 → ROW_NUMBER with a stable tiebreaker (e.g., application_date ASC)
-- Business wants to review all tied borrowers → RANK or DENSE_RANK
```

**Fix:**

```sql
-- Make the choice explicit based on the business requirement:

-- Option 1: Exactly 3 rows per group, stable tiebreaker (e.g., for credit review workflows):
WITH ranked AS (
    SELECT *,
        ROW_NUMBER() OVER (
            PARTITION BY group_id
            ORDER BY loan_amount DESC, application_date ASC  -- stable tiebreaker
        ) AS rn
    FROM loan_applications
)
SELECT * FROM ranked WHERE rn <= 3;   -- always exactly 3 rows per group

-- Option 2: All borrowers at the top 3 rank positions (for inclusive review):
WITH ranked AS (
    SELECT *,
        DENSE_RANK() OVER (PARTITION BY group_id ORDER BY loan_amount DESC) AS rnk
    FROM loan_applications
)
SELECT * FROM ranked WHERE rnk <= 3;  -- may return more than 3 rows on ties
-- Document which option was chosen and why in the query comment header
```

---

## At Scale

### Failure Mechanism

`DENSE_RANK() OVER (PARTITION BY trading_pair ORDER BY SUM(trade_amount) DESC)`:

1. Aggregate `GROUP BY (user_id, trading_pair)` → produces M × P rows (users × pairs)
2. Window rank `PARTITION BY trading_pair` → shuffle by `trading_pair` across all nodes
3. Filter `WHERE rnk <= 3` → discard most rows

If there are 500 trading pairs and each has 10M unique users → 5B intermediate rows from the GROUP BY.

### Code-Level Fix

```sql


#### System-Level Fix


---

---


