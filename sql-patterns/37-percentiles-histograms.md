<!-- Part of sql-patterns: Percentiles and Histograms -->
<!-- Source: sql_patterns.md lines 9573–9840 -->

## 23. Percentiles & Histograms

### What it solves

Compute distribution statistics — median, p90, p99, bucketed distributions.

### Keywords to spot

> "median", "percentile", "p90", "p95", "p99",
> "distribution", "histogram", "bucket", "quantile",
> "what % of users", "spread of values",
> "P50", "long tail", "tail latency", "outlier boundary",
> "value at X% of population", "how spread out", "variance",
> "SLA compliance %", "within acceptable range"

### Business Context

- **Fintech/Infrastructure:** p99 trade execution latency (SLA — must be < 200ms); median order size per trading pair (customer profile); distribution of deposit amounts to size fraud thresholds
- **E-commerce:** Distribution of order values in buckets (pricing strategy); p90 delivery time per carrier (carrier SLA benchmarking); histogram of cart sizes to optimise checkout UX
- **SaaS/Platform:** p95 API response time (SLA reporting); median session duration per plan tier (product quality signal); p99 job run time for pipeline SLA management
- **HR:** Salary distribution by department for pay equity analysis; percentile ranking of employee performance scores for forced ranking calibration; median years-to-promotion by department
- **Risk/Compliance:** Distribution of transaction sizes to set automated review thresholds; p99 of daily withdrawal amounts per customer for AML trip-wire calibration

### Boilerplate — Percentile functions

```

```sql
-- PostgreSQL / BigQuery
SELECT
    trading_pair,
    PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY trade_amount) AS median_amount,
    PERCENTILE_CONT(0.90) WITHIN GROUP (ORDER BY trade_amount) AS p90_amount,
    PERCENTILE_CONT(0.99) WITHIN GROUP (ORDER BY trade_amount) AS p99_amount
FROM trades
GROUP BY trading_pair;

-- Snowflake
SELECT
    trading_pair,
    MEDIAN(trade_amount)                          AS median_amount,
    PERCENTILE_CONT(0.90) WITHIN GROUP (ORDER BY trade_amount) AS p90_amount
FROM trades
GROUP BY trading_pair;

-- NTILE approach for approximate percentile
SELECT
    user_id,
    trade_amount,
    NTILE(100) OVER (ORDER BY trade_amount) AS percentile_bucket
FROM trades;
```

### Boilerplate — Histogram with buckets

```sql
-- Bucket trade amounts into ranges
SELECT
    CASE
        WHEN trade_amount <  1000    THEN '0-1K'
        WHEN trade_amount <  10000   THEN '1K-10K'
        WHEN trade_amount <  100000  THEN '10K-100K'
        WHEN trade_amount <  1000000 THEN '100K-1M'
        ELSE '1M+'
    END AS amount_bucket,
    COUNT(*)       AS num_trades,
    SUM(trade_amount) AS total_volume
FROM trades
GROUP BY 1
ORDER BY MIN(trade_amount);
```

### Gotchas

- `PERCENTILE_CONT` interpolates between values (continuous); `PERCENTILE_DISC` returns an actual value from the dataset
- Median = `PERCENTILE_CONT(0.5)`
- Not all databases support `PERCENTILE_CONT` — know the alternative for your target DB

### Edge Cases

#### Edge 23-A: PERCENTILE_CONT vs PERCENTILE_DISC — two different answers

**Problem:**

```sql
-- PERCENTILE_CONT (continuous): interpolates between adjacent values
-- PERCENTILE_DISC (discrete):   returns an actual existing value

-- Data: loan amounts [100, 200, 300, 400, 500]
SELECT
    PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY loan_amount) AS median_cont,  -- 300 (middle value)
    PERCENTILE_DISC(0.5) WITHIN GROUP (ORDER BY loan_amount) AS median_disc   -- 300 (same here)

-- Data with even count: [100, 200, 300, 400]
SELECT
    PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY loan_amount) AS median_cont,  -- 250 (interpolated)
    PERCENTILE_DISC(0.5) WITHIN GROUP (ORDER BY loan_amount) AS median_disc   -- 200 (lower middle)

-- For financial reporting: PERCENTILE_DISC is safer (always an actual data point)
-- For smooth statistical analysis: PERCENTILE_CONT is standard
-- Using the wrong one can make median look wrong to stakeholders who check the data
```

**Fix:**

```sql
-- Choose explicitly based on the business requirement and document the decision:

-- For financial reporting where stakeholders will verify results against the raw data:
-- Use PERCENTILE_DISC (returns an actual existing value, easier to verify):
SELECT
    trading_pair,
    PERCENTILE_DISC(0.5) WITHIN GROUP (ORDER BY trade_amount) AS median_trade_amount
FROM trades
GROUP BY trading_pair;
-- Stakeholder can find this exact value in the source data ✓

-- For smooth statistical analysis or when interpolation is expected (e.g., P&L reports):
-- Use PERCENTILE_CONT:
SELECT
    trading_pair,
    PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY trade_amount) AS median_trade_amount
FROM trades
GROUP BY trading_pair;

-- Always add a comment explaining which function was chosen and why:
-- "Using PERCENTILE_DISC per RBI reporting guidelines (exact data values required)"
```

#### Edge 23-B: APPROX_PERCENTILE vs exact percentile — when the difference matters

**Problem:**

```sql
-- APPROX_PERCENTILE / APPROX_QUANTILE (Spark, BigQuery, Snowflake) is faster but approximate
-- Accuracy: typically within 1% of actual value for large datasets
-- The error is probabilistic — occasionally worse

-- Safe to use: general trend analysis, dashboards, exploration
-- NOT safe: regulatory reporting (RBI requires exact figures), financial audits, SLAs

-- Detection: compare approximate vs exact on a sample:
SELECT
    PERCENTILE_CONT(0.99) WITHIN GROUP (ORDER BY response_time_ms) AS exact_p99,
    APPROX_PERCENTILE(response_time_ms, 0.99)                       AS approx_p99,
    ABS(
        PERCENTILE_CONT(0.99) WITHIN GROUP (ORDER BY response_time_ms)
        - APPROX_PERCENTILE(response_time_ms, 0.99)
    ) AS error_ms
FROM api_response_times;
-- If error_ms > your acceptable threshold, use exact PERCENTILE_CONT
```

**Fix:**

```sql
-- Use APPROX_PERCENTILE for dashboards/exploration; exact PERCENTILE_CONT for compliance:

-- Dashboards and trend analysis (approximate is fine):
SELECT trading_pair,
    APPROX_PERCENTILE(trade_amount, 0.99) AS approx_p99  -- Snowflake
FROM trades GROUP BY trading_pair;

-- Regulatory reporting / SLA measurement (exact required):
SELECT trading_pair,
    PERCENTILE_CONT(0.99) WITHIN GROUP (ORDER BY trade_amount) AS exact_p99
FROM trades GROUP BY trading_pair;

-- To validate the error margin:
SELECT
    PERCENTILE_CONT(0.99) WITHIN GROUP (ORDER BY trade_amount) AS exact_p99,
    APPROX_PERCENTILE(trade_amount, 0.99) AS approx_p99,
    ABS(PERCENTILE_CONT(0.99) WITHIN GROUP (ORDER BY trade_amount)
        - APPROX_PERCENTILE(trade_amount, 0.99)) AS abs_error
FROM trades;
-- If abs_error / exact_p99 < 0.01 (1%), use approximate for non-regulated use cases
```

---

### At Scale

#### Failure Mechanism

`PERCENTILE_CONT(0.99) WITHIN GROUP (ORDER BY trade_amount)` on 800M rows:

- Requires a **global sort** of 800M values: O(N log N) — the most expensive SQL operation
- Per-group percentiles (`GROUP BY trading_pair`): sort within each group — slightly better but still O(N log N) total
- At 800M rows × 8 bytes = 6.4GB of data to sort: requires hundreds of GBs of disk spill in most engines

#### Code-Level Fix

```sql

```sql
-- BEFORE: exact p99 on 800M rows
SELECT trading_pair,
    PERCENTILE_CONT(0.99) WITHIN GROUP (ORDER BY trade_amount) AS p99_amount
FROM trades GROUP BY trading_pair;
-- Requires: sort all 800M rows within each trading_pair partition

-- FIX 1: Approximate percentile (t-digest / HLL) — 1% error, 100× faster
-- Databricks / Spark:
SELECT trading_pair,
    PERCENTILE_APPROX(trade_amount, 0.99, 10000) AS approx_p99
FROM trades GROUP BY trading_pair;
-- PERCENTILE_APPROX: uses t-digest algorithm, accuracy param = 10000 (higher = more accurate)

-- Snowflake:
SELECT trading_pair,
    APPROX_PERCENTILE(trade_amount, 0.99) AS approx_p99  -- uses Greenwald-Khanna algorithm
FROM trades GROUP BY trading_pair;

-- BigQuery:
SELECT trading_pair,
    APPROX_QUANTILES(trade_amount, 100)[OFFSET(99)] AS approx_p99
FROM trades GROUP BY trading_pair;

-- FIX 2: For exact percentiles, pre-aggregate to a histogram first
-- Build a histogram with 1000 buckets (captures percentile with 0.1% accuracy)
WITH hist AS (
    SELECT trading_pair,
        WIDTH_BUCKET(trade_amount, 0, 10000000, 1000) AS bucket,
        COUNT(*) AS cnt
    FROM trades GROUP BY trading_pair, bucket
),
cumulative AS (
    SELECT *,
        SUM(cnt) OVER (PARTITION BY trading_pair ORDER BY bucket ROWS UNBOUNDED PRECEDING) AS cum_cnt,
        SUM(cnt) OVER (PARTITION BY trading_pair) AS total_cnt
    FROM hist
)
SELECT trading_pair, bucket, cum_cnt / total_cnt AS cumulative_pct
FROM cumulative
WHERE cum_cnt / total_cnt >= 0.99
QUALIFY ROW_NUMBER() OVER (PARTITION BY trading_pair ORDER BY bucket) = 1;
-- Histogram built from 800M rows → 1000 buckets per trading_pair → ~50K rows
-- Percentile from histogram: trivial operation on 50K rows
```

#### System-Level Fix

```sql
-- Pre-compute and store percentile results (run hourly/daily):
CREATE TABLE metric_percentiles (
    metric_name  VARCHAR(50),
    group_key    VARCHAR(100),
    p50          DECIMAL(15,2),
    p90          DECIMAL(15,2),
    p95          DECIMAL(15,2),
    p99          DECIMAL(15,2),
    computed_at  TIMESTAMP
)
-- Tiny table: one row per metric per group per time period
-- Percentile query: SELECT p99 FROM metric_percentiles WHERE group_key = 'BTC_INR' — instant

-- For streaming p99 (real-time API latency SLA monitoring):
-- Use a UDAF (User-Defined Aggregate Function) that maintains a t-digest sketch
-- Emit running p99 from the sketch every 10 seconds
-- Zero sort, O(1) space per sketch, O(log N) update per event
```

```sql

---

---

