<!-- sql-patterns: Median, Mode, and NTILE Bucketing -->

# Median & Mode

## What it solves

Find the middle value (median) or most frequent value (mode) of a distribution.

## Keywords to spot

> "most common", "most frequent", "mode", "median", "middle value",
> "typical", "most popular"

## Boilerplate — Mode

```sql
-- Most common trading pair overall
SELECT trading_pair, COUNT(*) AS freq
FROM trades
GROUP BY trading_pair
ORDER BY freq DESC
LIMIT 1;

-- Mode per user (most-traded pair per user)
WITH ranked AS (
    SELECT
        user_id,
        trading_pair,
        COUNT(*) AS freq,
        RANK() OVER (PARTITION BY user_id ORDER BY COUNT(*) DESC) AS rnk
    FROM trades
    GROUP BY user_id, trading_pair
)
SELECT user_id, trading_pair, freq
FROM ranked WHERE rnk = 1;
```

## Edge Cases

### Edge 26-A: Median with even number of rows — two middle values

**Problem:**

```sql
-- Standard PERCENTILE_CONT handles this correctly (interpolates)
-- Manual ROW_NUMBER median has a subtle bug with even row counts:

WITH ranked AS (
    SELECT loan_amount,
           ROW_NUMBER() OVER (ORDER BY loan_amount) AS rn,
           COUNT(*) OVER () AS total
    FROM loan_applications
)
SELECT AVG(loan_amount) AS median
FROM ranked
WHERE rn IN (FLOOR((total + 1) / 2.0), CEIL((total + 1) / 2.0));
-- For total = 4: rn IN (2.0, 3.0) → rows 2 and 3 → AVG of 200 and 300 = 250 ✓
-- For total = 5: rn IN (2.5, 3.5) → FLOOR=2, CEIL=3... wait:
-- FLOOR(6/2.0) = 3, CEIL(6/2.0) = 3 → same row → AVG of one value = row 3 ✓ (middle of 5)
-- For total = 1: rn IN (1, 1) → only row 1 → correct ✓

-- BUT: PERCENTILE_CONT is simpler and handles all these cases:
SELECT PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY loan_amount) FROM loan_applications;
```

**Fix:**

```sql
-- Use PERCENTILE_CONT for the standard median — it handles even and odd row counts correctly:
SELECT
    loan_type,
    PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY loan_amount) AS median_loan_amount
FROM loan_applications
GROUP BY loan_type;
-- Even count: interpolates between the two middle values (e.g., avg(200, 300) = 250)
-- Odd count: returns the exact middle value
-- No manual ROW_NUMBER logic required

-- If manual ROW_NUMBER approach is required (e.g., engine lacks PERCENTILE_CONT):
WITH ranked AS (
    SELECT loan_amount,
           ROW_NUMBER() OVER (ORDER BY loan_amount) AS rn,
           COUNT(*) OVER ()                         AS total
    FROM loan_applications
)
SELECT AVG(loan_amount) AS median
FROM ranked
WHERE rn IN (
    FLOOR((total + 1) / 2.0),
    CEIL((total + 1)  / 2.0)
);
-- FLOOR and CEIL of the same value when total is odd → selects one row (the middle)
-- FLOOR and CEIL of different values when total is even → selects two middle rows, averages them
```

### Edge 26-B: Multiple modes — which one to return?

**Problem:**

```sql
-- MODE() aggregate function (PostgreSQL 9.4+) returns ONE mode value
-- If there are multiple modes (tied frequency), it returns one arbitrarily

SELECT MODE() WITHIN GROUP (ORDER BY credit_score) AS modal_credit_score
FROM users;
-- If 650 and 700 both appear 500 times: returns one of them (engine-dependent which)
```

**Fix — detect all modes:**

```sql
WITH freq AS (
    SELECT credit_score, COUNT(*) AS freq FROM users GROUP BY credit_score
),
max_freq AS (
    SELECT MAX(freq) AS max_freq FROM freq
)
SELECT credit_score AS mode_value, freq
FROM freq WHERE freq = (SELECT max_freq FROM max_freq)
ORDER BY credit_score;  -- returns ALL tied modes
---

### At Scale

*No specific at-scale documentation for this pattern.*

---

## 27. NTILE & Bucketing

### What it solves

Divide rows into N equal-sized buckets for analysis, percentile banding, or A/B group assignment.

### Keywords to spot

> "quartile", "decile", "bucket", "equal groups", "divide into N parts",
> "top 25%", "bottom 10%", "segment users",
> "band", "tier", "equal-sized groups", "split into",
> "RFM", "volume tier", "spend tier", "assign group",
> "top quintile", "bottom quartile"

### Business Context

- **Fintech:** Segment users into quartiles by trading volume for targeted product campaigns (Q1 = power traders, Q4 = occasional traders); decile analysis of wallet balances for fee tier design
- **E-commerce:** Identify top-decile customers by LTV for VIP loyalty program; divide products into deciles by margin for category management prioritisation
- **HR:** Rank employees by performance score into quartiles for forced-ranking review calibration; identify bottom quartile for performance improvement plan
- **Marketing:** Assign users to decile buckets by engagement score for progressive messaging (Q1 = convert now, Q10 = nurture); RFM segmentation using NTILE on recency, frequency, and monetary independently
- **Risk:** Assign merchants into risk deciles by chargeback rate (top decile = high risk — enhanced monitoring); segment loan applicants into credit score buckets for pricing

### Boilerplate

```sql
SELECT
    user_id,
    total_volume,
    NTILE(4)   OVER (ORDER BY total_volume DESC) AS volume_quartile,   -- 1=top 25%
    NTILE(10)  OVER (ORDER BY total_volume DESC) AS volume_decile,
    NTILE(100) OVER (ORDER BY total_volume DESC) AS volume_percentile
FROM (
    SELECT user_id, SUM(trade_amount) AS total_volume
    FROM trades
    GROUP BY user_id
) user_volumes;
```

### Gotchas

- Bucket 1 = highest values when `ORDER BY DESC`
- If rows don't divide evenly, earlier buckets get the extra row
- `NTILE` doesn't guarantee equal counts when there are ties

### Edge Cases

#### Edge 27-A: NTILE(N) when N > number of rows in partition

**Problem:**

```sql
-- NTILE(4) on a partition with only 2 rows
-- Expected: 4 buckets. Reality: only 2 rows → buckets 3 and 4 are empty
-- The 2 rows get assigned buckets 1 and 2 — no error, no warning

SELECT user_id, loan_amount,
    NTILE(4) OVER (PARTITION BY region ORDER BY loan_amount DESC) AS quartile
FROM loan_applications;
-- region='RURAL' has only 2 loan applications → quartiles 3 and 4 will never appear for this region
-- Dashboard showing "quartile 3 = 0 loans in RURAL" → actually means "too few data points"
-- Don't label these buckets "quartiles" when some are empty
```

**Fix — check row count before applying NTILE:**

```sql
SELECT region, COUNT(*) AS loan_count,
    CASE WHEN COUNT(*) >= 4 THEN 'quartile analysis valid' ELSE 'insufficient data' END AS status
FROM loan_applications
GROUP BY region;
```

#### Edge 27-B: Uneven distribution — NTILE doesn't produce equal-sized buckets

**Problem:**

```sql
-- NTILE distributes remainder rows to the FIRST buckets
-- 10 rows into 3 tiles: bucket1=4, bucket2=3, bucket3=3 (not 3,3,4)
-- This is documented but often surprising

SELECT loan_amount,
    NTILE(3) OVER (ORDER BY loan_amount) AS tertile,
    COUNT(*) OVER (PARTITION BY NTILE(3) OVER (ORDER BY loan_amount)) AS bucket_size
    -- NOTE: nesting window functions is NOT directly supported in standard SQL
    -- Must wrap in a CTE to compute bucket sizes
FROM loan_applications ORDER BY loan_amount;
-- The first bucket always gets the extras, making it slightly larger
-- For equal-sized buckets, use WIDTH_BUCKET or custom logic based on PERCENT_RANK
```

**Fix:**

```sql
-- NTILE's uneven distribution is expected behaviour. The fix is to document it
-- and consider WIDTH_BUCKET for strict equal-sized buckets when needed:

-- Option 1: Accept NTILE's distribution and document it:
SELECT loan_amount,
    NTILE(3) OVER (ORDER BY loan_amount) AS tertile
    -- NOTE: if total rows not divisible by 3, the first bucket(s) receive the extra rows
FROM loan_applications ORDER BY loan_amount;

-- Option 2: Use PERCENT_RANK + CASE for equal-width percentile bands:
SELECT loan_amount,
    CASE
        WHEN PERCENT_RANK() OVER (ORDER BY loan_amount) < 1.0/3 THEN 1
        WHEN PERCENT_RANK() OVER (ORDER BY loan_amount) < 2.0/3 THEN 2
        ELSE 3
    END AS tertile
FROM loan_applications;

-- Option 3: WIDTH_BUCKET for equal-width value ranges (not equal row count):
SELECT loan_amount,
    WIDTH_BUCKET(loan_amount, min_amount, max_amount + 1, 3) AS tertile
FROM loan_applications
CROSS JOIN (SELECT MIN(loan_amount) AS min_amount, MAX(loan_amount) AS max_amount FROM loan_applications) bounds;
-- Divides the VALUE range equally; row counts per bucket will vary based on data distribution
```

---

### At Scale

*No specific at-scale documentation for this pattern.*

---


