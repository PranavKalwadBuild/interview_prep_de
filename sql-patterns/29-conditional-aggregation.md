<!-- Part of sql-patterns: Conditional Aggregations -->
<!-- Source: sql_patterns.md lines 7740–7971 -->

## 15. Conditional Aggregations

### What it solves

Compute multiple aggregations (counts, sums) for different subsets of data in a single pass — instead of multiple queries or subqueries.

### Keywords to spot

> "count of X and Y separately", "sum of approved vs rejected",
> "breakdown by status", "pivot", "aggregate per category in one row",
> "how many users did A vs B vs C",
> "split by", "by type", "separate columns for", "compare categories in one row",
> "ratio of", "proportion of", "% of total per group", "flag and count"

### Business Context

- **Fintech:** Count BUY vs SELL trades per user per day; sum of successful vs failed deposits; ratio of declined to approved transactions per merchant (fraud pattern)
- **E-commerce:** Count orders by status (placed/shipped/delivered/returned) per seller per week; % of returns per product category; revenue from new vs returning customers in one row per day
- **SaaS:** Count logins vs feature uses vs support tickets per account per week; active vs churned vs trial users per plan tier in a single summary row
- **Marketing:** Impressions vs clicks vs conversions per campaign per channel in one row; paid vs organic vs referral revenue per day
- **A/B Testing:** Count and sum metrics per experiment variant (control vs treatment) in a single aggregated row for easy comparison

### Boilerplate

```sql
-- Count trades by type per user per day
SELECT
    user_id,
    DATE(executed_at)                                  AS trade_date,
    COUNT(*)                                           AS total_trades,
    SUM(CASE WHEN trade_type = 'BUY'  THEN 1 ELSE 0 END) AS buy_count,
    SUM(CASE WHEN trade_type = 'SELL' THEN 1 ELSE 0 END) AS sell_count,
    SUM(CASE WHEN trade_type = 'BUY'  THEN trade_amount ELSE 0 END) AS buy_volume,
    SUM(CASE WHEN trade_type = 'SELL' THEN trade_amount ELSE 0 END) AS sell_volume,
    -- Ratio
    ROUND(
        SUM(CASE WHEN trade_type = 'BUY' THEN 1 ELSE 0 END) * 100.0 / COUNT(*), 2
    ) AS buy_pct
FROM trades
GROUP BY user_id, DATE(executed_at);

-- Filter within aggregation (COUNT + CASE pattern)
SELECT
    user_id,
    COUNT(DISTINCT CASE WHEN status = 'SUCCESS' THEN txn_id END) AS successful_txns,
    COUNT(DISTINCT CASE WHEN status = 'FAILED'  THEN txn_id END) AS failed_txns,
    SUM(CASE WHEN status = 'SUCCESS' THEN amount ELSE 0 END)     AS successful_amount
FROM transactions
GROUP BY user_id;
```

### Gotchas

- `SUM(CASE WHEN ... THEN 1 ELSE 0 END)` = `COUNT(CASE WHEN ... THEN 1 END)` — both work, but SUM is more explicit
- `COUNT(CASE WHEN ... THEN 1 END)` — the ELSE is implicitly NULL, and COUNT ignores NULLs — equivalent to ELSE 0 for SUM
- Use `FILTER (WHERE ...)` in PostgreSQL as a cleaner alternative: `COUNT(*) FILTER (WHERE status = 'SUCCESS')`

### Edge Cases

#### Edge 15-A: COUNT with ELSE 0 counts ALL rows, not matching rows

**Problem:**

```sql
-- WRONG — returns TOTAL row count, not just rows where condition matches:
SELECT
    dept_id,
    COUNT(CASE WHEN status = 'APPROVED' THEN 1 ELSE 0 END) AS approved_count
FROM applications GROUP BY dept_id;
-- ELSE 0 means: non-APPROVED rows contribute 0 — but 0 IS NOT NULL
-- COUNT counts non-NULL values — 0 is not NULL → ALL rows counted!

-- CORRECT — ELSE NULL (or no ELSE, which defaults to NULL):
COUNT(CASE WHEN status = 'APPROVED' THEN 1 END) AS approved_count
-- Non-APPROVED rows return NULL (from implicit ELSE NULL)
-- COUNT ignores NULL → only APPROVED rows counted

-- This single mistake inflates conditional counts to equal total row count
-- and is extremely common in production code
```

**Fix:**

```sql
-- Always use NULL (not 0) as the ELSE in COUNT-based conditional aggregation:

-- CORRECT: no ELSE (implicit ELSE NULL) — only matching rows counted
SELECT
    dept_id,
    COUNT(CASE WHEN status = 'APPROVED' THEN 1 END)  AS approved_count,
    COUNT(CASE WHEN status = 'PENDING'  THEN 1 END)  AS pending_count,
    COUNT(CASE WHEN status = 'REJECTED' THEN 1 END)  AS rejected_count,
    COUNT(*)                                          AS total_count
FROM applications
GROUP BY dept_id;

SELECT
    dept_id,
    COUNT(*) FILTER (WHERE status = 'APPROVED') AS approved_count,
    COUNT(*) FILTER (WHERE status = 'PENDING')  AS pending_count,
    COUNT(*) FILTER (WHERE status = 'REJECTED') AS rejected_count,
    COUNT(*)                                    AS total_count
FROM applications
GROUP BY dept_id;
-- FILTER is unambiguous about its intent; no risk of accidentally writing ELSE 0
```

#### Edge 15-B: Non-exhaustive CASE — the implicit ELSE NULL trap in SUM

**Problem:**

```sql
-- SUM with CASE WHERE some values fall into ELSE NULL:
SELECT
    SUM(CASE
        WHEN txn_type = 'DEBIT'  THEN -amount
        WHEN txn_type = 'CREDIT' THEN  amount
        -- No ELSE → ELSE NULL implicit
        -- What about txn_type = 'REVERSAL' or 'FEE'?
    END) AS net_balance
FROM transactions;
-- REVERSAL and FEE rows contribute NULL to the SUM
-- SUM ignores NULL → those rows are excluded from the net balance calculation
-- This could make your balance look larger than it is (missing fees)
```

**Fix — always have an explicit ELSE:**

```sql
CASE
    WHEN txn_type = 'DEBIT'    THEN -amount
    WHEN txn_type = 'CREDIT'   THEN  amount
    WHEN txn_type = 'REVERSAL' THEN  0        -- reversals net to zero
    WHEN txn_type = 'FEE'      THEN -amount   -- fees are debits
    ELSE 0                                    -- catch-all: log unexpected types separately
END
---

### At Scale

#### Failure Mechanism

Conditional aggregation (`SUM(CASE WHEN ... THEN amount END) × 20 conditions`) on 800M rows:

- Single full-table scan: efficient (one pass for all 20 conditions)
- **The real problem**: if this is run as an ad-hoc query on an unpartitioned table every time a dashboard loads → 800M row scan per dashboard refresh × N concurrent users = cluster saturation
- `GROUPING SETS` / `ROLLUP` / `CUBE` at scale: generates exponentially many groups — `CUBE(a,b,c,d)` = 16 grouping combinations × full scan each

#### Code-Level Fix

```sql
-- BEFORE: conditional aggregation on raw transactions for every dashboard load
SELECT
    user_id,
    DATE(executed_at) AS trade_date,
    SUM(CASE WHEN trade_type = 'BUY'  THEN amount ELSE 0 END) AS buy_volume,
    SUM(CASE WHEN trade_type = 'SELL' THEN amount ELSE 0 END) AS sell_volume,
    COUNT(CASE WHEN status = 'FAILED' THEN 1 END)              AS failed_count
FROM transactions   -- 800M rows, every dashboard load
GROUP BY user_id, DATE(executed_at);

-- FIX 1: Materialise daily conditional aggregates
CREATE TABLE user_daily_trading_stats AS
SELECT
    user_id,
    txn_date,
    SUM(CASE WHEN trade_type = 'BUY'  THEN amount ELSE 0 END) AS buy_volume,
    SUM(CASE WHEN trade_type = 'SELL' THEN amount ELSE 0 END) AS sell_volume,
    COUNT(CASE WHEN status = 'FAILED' THEN 1 END)              AS failed_count,
    COUNT(*) AS total_trades
FROM transactions
GROUP BY user_id, txn_date;
-- ETL: run nightly on the previous day's partition only (incremental)
-- Dashboard: SELECT * FROM user_daily_trading_stats WHERE txn_date >= :start AND user_id = :id
-- Cost: 1 row read per day per user vs 800M rows scanned

-- FIX 2: For ROLLUP/CUBE, materialise each grouping level separately
-- CUBE(trading_pair, user_segment, region) → 8 grouping combinations
-- Store in a summary table with a grouping_key column:
INSERT INTO summary_metrics
SELECT 'pair|segment|region' AS grp_key, trading_pair, user_segment, region, SUM(amount)
FROM transactions GROUP BY trading_pair, user_segment, region
UNION ALL
SELECT 'pair|segment', trading_pair, user_segment, NULL, SUM(amount)
FROM transactions GROUP BY trading_pair, user_segment
UNION ALL
-- ... all combinations
-- Query: SELECT * FROM summary_metrics WHERE grp_key = 'pair|segment' AND trading_pair = 'BTC'
```

#### System-Level Fix

```sql
CREATE OR REPLACE DYNAMIC TABLE daily_trading_stats
  LAG = '10 minutes'
  WAREHOUSE = reporting_wh
AS
SELECT user_id, txn_date,
    SUM(CASE WHEN trade_type = 'BUY'  THEN amount END) AS buy_vol,
    SUM(CASE WHEN trade_type = 'SELL' THEN amount END) AS sell_vol,
    COUNT(CASE WHEN status = 'FAILED' THEN 1 END)       AS failed_cnt
FROM transactions
GROUP BY user_id, txn_date;

-- Reserve BI Engine capacity for the reporting project
-- Pre-aggregated tables served in-memory: < 1 second for any filter combination

CREATE MATERIALIZED VIEW mv_daily_trading_stats
AUTO REFRESH YES
AS SELECT user_id, txn_date,
    SUM(CASE WHEN trade_type = 'BUY' THEN amount END) AS buy_vol
FROM transactions GROUP BY user_id, txn_date;
---

---


