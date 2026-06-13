<!-- Part of sql-patterns: Silent Errors — Floating Point and Numeric Precision -->

# Silent Errors — Floating Point and Numeric Precision

IEEE 754 floating-point arithmetic is the right tool for scientific computing and the wrong tool for financial data. SQL's integer division truncation and cross-engine rounding differences produce results that are incorrect but never raise errors. These bugs compound over time: a small per-row error accumulates into a large aggregate error at scale.

---

### Floating-Point Equality — WHERE amount = 0.1 Never Matches

**What it looks like:**
```sql
SELECT * FROM transactions WHERE fee_rate = 0.1;
```

**What actually happens:** `0.1` cannot be represented exactly in IEEE 754 binary floating-point. The stored value is approximately `0.1000000000000000055511151231257827021181583404541015625`. The literal `0.1` in the WHERE clause is subject to the same approximation but may be rounded differently than the stored value. The comparison `stored_float = literal_float` can evaluate to FALSE even when both represent "0.1."

**Why it's insidious:** This works in most rows because the rounding is consistent for the same literal. But if the stored value was computed (e.g., `price * tax_rate` where `tax_rate = 0.05 + 0.05`), the computation may introduce a different rounding path than storing the literal `0.1` directly. The filter silently returns zero rows for computed float values.

**Minimal repro:**
```sql
SELECT
    0.1::FLOAT = 0.1::FLOAT                           AS literal_equals_literal,  -- TRUE (same path)
    (0.05::FLOAT + 0.05::FLOAT) = 0.1::FLOAT          AS computed_equals_literal,  -- may be FALSE
    ABS((0.05::FLOAT + 0.05::FLOAT) - 0.1::FLOAT) < 1e-9 AS epsilon_compare        -- TRUE (correct)
```

**How to catch it:**
```sql
-- Never use = on FLOAT columns for exact business values.
-- Use NUMERIC/DECIMAL for any value requiring exact comparison.
-- If you must use FLOAT, use an epsilon range:
WHERE ABS(fee_rate - 0.1) < 0.0000001

-- Or store percentages as integers (basis points):
WHERE fee_rate_bps = 1000  -- 10% = 1000 bps
```

**Real-world trigger:** Transaction fee waiver applied when `fee_rate = 0.1` (10% tier). Fees are computed by dividing a stored integer basis-point value by 1000.0, producing a computed float. The fee waiver check never matches the computed float. Customers in the 10% tier silently continue paying fees they should not pay for 3 billing cycles.

---

### Accumulating Float Error in Running SUM at Scale

**What it looks like:**
```sql
SELECT
    date,
    SUM(unit_price) OVER (ORDER BY date ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS cumulative_price
FROM daily_prices;
```

**What actually happens:** Summing 1 million rows of `0.1::FLOAT` does not produce exactly `100000.0`. IEEE 754 rounding errors accumulate with each addition. The result is approximately `99999.9999999998` or similar. Small per-operation errors compound to a meaningful absolute error over millions of operations.

**Why it's insidious:** The error is small in relative terms (parts-per-billion). It only becomes visible at scale (large row counts) or when exact reconciliation is required (financial totals). A `SUM` that should exactly match an external total silently differs by small amounts.

**Minimal repro:**
```sql
-- Postgres: sum 1M values of 0.1 as FLOAT vs NUMERIC
WITH vals AS (SELECT 0.1::FLOAT AS fval, 0.1::NUMERIC AS nval FROM generate_series(1,1000000))
SELECT
    SUM(fval) AS float_sum,    -- ~99999.9999999... (not exactly 100000)
    SUM(nval) AS numeric_sum   -- 100000.0000000   (exact)
FROM vals;
```

**How to catch it:**
```sql
-- For financial aggregations, always use NUMERIC/DECIMAL, not FLOAT.
-- Reconciliation invariant: compare float aggregates to NUMERIC control:
SELECT
    SUM(amount::FLOAT)   AS float_total,
    SUM(amount::NUMERIC) AS numeric_total,
    ABS(SUM(amount::FLOAT) - SUM(amount::NUMERIC)) AS discrepancy
FROM transactions;
-- If discrepancy > 0.01, you have float accumulation error.
```

**Real-world trigger:** Billing reconciliation between a data warehouse (FLOAT amounts) and an accounting system (DECIMAL amounts). Warehouse totals are consistently off by $0.03–$0.47 per million transactions. Finance team escalates a "rounding error audit" that takes 2 weeks to trace back to float vs decimal storage.

---

### NUMERIC vs FLOAT Division Result Type — Silent Precision Loss on Mixed Expressions

**What it looks like:**
```sql
SELECT
    revenue / total_costs AS margin
FROM financial_summary;
-- revenue is NUMERIC(18,2), total_costs is FLOAT
```

**What actually happens:** When NUMERIC and FLOAT are mixed in an arithmetic expression, SQL implicitly casts NUMERIC to FLOAT (FLOAT has higher type precedence in most engines). The result is a FLOAT, losing the precision guarantees of NUMERIC. For financial calculations, the margin computed as FLOAT may differ from the margin computed as NUMERIC(18,8) in the last few decimal places.

**Why it's insidious:** The result looks like a precise decimal. The loss of NUMERIC's precision guarantees is invisible in the output format. It only surfaces in reconciliation or when the margin is used in further calculations that amplify the rounding error.

**Minimal repro:**
```sql
WITH data AS (SELECT 1.0::NUMERIC(18,2) AS rev, 3.0::FLOAT AS cost)
SELECT
    rev / cost                           AS mixed_division,   -- FLOAT result
    rev / cost::NUMERIC(18,2)            AS numeric_division, -- NUMERIC result
    (rev / cost) - (rev / cost::NUMERIC(18,2)) AS difference  -- should be ~0
FROM data;
-- 1.0/3.0 as FLOAT: 0.3333333333333333 (IEEE approximation)
-- 1.0/3.0 as NUMERIC(18,2)/NUMERIC(18,2): 0.3333333333333333... to declared precision
```

**How to catch it:**
```sql
-- Audit division expressions for type mixing:
-- In Snowflake/PostgreSQL, SYSTEM$TYPEOF or pg_typeof can reveal result types:
SELECT pg_typeof(revenue / total_costs) FROM financial_summary LIMIT 1;
-- If result is 'double precision' when you expected 'numeric', you have implicit FLOAT promotion.
```

**Real-world trigger:** Tax calculation pipeline. Tax rate stored as FLOAT (from a legacy system). Tax base stored as NUMERIC. The product `tax_base * tax_rate` promotes to FLOAT, introduces rounding, and the computed tax differs from the auditor's calculation by $0.01 for some line items — which triggers an automated compliance flag.

---

### ROUND Banker's Rounding in PostgreSQL vs Half-Up in Snowflake/MySQL

**What it looks like:**
```sql
SELECT ROUND(amount, 2) AS rounded_amount FROM financial_records;
```

**What actually happens:**
- PostgreSQL applies **banker's rounding** (round-half-to-even) for NUMERIC types: `ROUND(2.5) = 2`, `ROUND(3.5) = 4`.
- Snowflake applies **round-half-away-from-zero** (standard rounding): `ROUND(2.5) = 3`, `ROUND(3.5) = 4`.
- MySQL applies **round-half-away-from-zero**: `ROUND(2.5) = 3`.

The same `ROUND()` call on the same value produces different results depending on the engine. Code migrated between engines silently changes rounding behavior for all `.5` cases.

**Why it's insidious:** For individual transactions, the difference is exactly $0.005 or less. The discrepancy only becomes visible when aggregating many rounded values — where banker's rounding tends to be unbiased (half round up, half round down) while half-up rounding systematically overstates the total by exactly `$0.005 × count_of_half_values`.

**Minimal repro:**
```sql
-- PostgreSQL (banker's rounding for NUMERIC):
SELECT ROUND(2.5::NUMERIC, 0),   -- 2 (rounds to nearest even)
       ROUND(3.5::NUMERIC, 0),   -- 4 (rounds to nearest even)
       ROUND(4.5::NUMERIC, 0);   -- 4 (rounds to nearest even)

-- Snowflake (half-away-from-zero):
SELECT ROUND(2.5, 0),  -- 3
       ROUND(3.5, 0),  -- 4
       ROUND(4.5, 0);  -- 5

-- Cross-engine consistent rounding (always half-up):
SELECT FLOOR(amount + 0.5) AS manual_round_half_up  -- works everywhere
```

**How to catch it:**
```sql
-- Test on your engine:
SELECT ROUND(0.5, 0), ROUND(1.5, 0), ROUND(2.5, 0), ROUND(3.5, 0);
-- If output is 0,2,2,4 → banker's rounding (PostgreSQL NUMERIC)
-- If output is 1,2,3,4 → half-up rounding (Snowflake, MySQL)
```

**Real-world trigger:** Financial reporting model migrated from PostgreSQL to Snowflake. Unit price rounding for invoices silently changes for all ".5" cent values. Invoices are over by $0.005 per line item with a half-cent value. Over 2 million monthly invoices, the total discrepancy exceeds $1,000 per month — detectable only in aggregate reconciliation.

---

### Integer Overflow in SUM Without Error

**What it looks like:**
```sql
SELECT SUM(page_views) AS total_views FROM web_analytics;
-- page_views is INT (32-bit, max ~2.1 billion)
```

**What actually happens:** In some engines and configurations, `SUM(INT)` can overflow silently. MySQL with certain configurations returns a negative number when the sum exceeds `2^31 - 1`. PostgreSQL promotes `SUM(INT)` to BIGINT automatically, avoiding the issue. SQL Server may return an arithmetic overflow error (not silent). Snowflake promotes to BIGINT.

The silent case: MySQL without strict mode, or any engine where the intermediate accumulator wraps around, returns a plausible-looking negative number or wrong positive number with no error.

**Minimal repro:**
```sql
-- MySQL behavior (may vary by version and mode):
SELECT SUM(val) FROM (SELECT 2000000000 AS val UNION ALL SELECT 200000000) t;
-- May return -2094967296 (silent overflow) or 2200000000 (if promoted to BIGINT)

-- Safe pattern: always CAST to BIGINT before SUM for large counters:
SELECT SUM(page_views::BIGINT) AS total_views FROM web_analytics;
```

**How to catch it:**
```sql
-- Sanity check: SUM should be > MAX and > any individual row
SELECT
    MAX(page_views)     AS max_per_row,
    SUM(page_views)     AS total,
    COUNT(*)            AS row_count
FROM web_analytics;
-- If total < max_per_row, overflow has occurred.
-- If total is negative, overflow has definitely occurred.
```

**Real-world trigger:** Ad platform total impression count. Table has 800M rows with average 3M impressions per row. `SUM(INT)` silently overflows to a large negative number. Total impression report sent to advertiser shows -1.2 billion impressions. Billing team catches the issue in the invoice review, but only after the report was already sent.

---

### DECIMAL Division Scale Expansion — Silent Precision Truncation at Storage

**What it looks like:**
```sql
CREATE TABLE rates AS
SELECT 1 / 3 AS rate;  -- what precision does 'rate' get?
```

**What actually happens:** `1 / 3` where both operands are integers returns `0` (integer division). `1.0 / 3` returns a NUMERIC/FLOAT depending on the engine, with engine-specific scale. In Snowflake, `1.0 / 3` returns `0.333333333` (to 9 decimal places). When stored in a table with a declared column precision lower than 9, the value is silently truncated.

**Minimal repro:**
```sql
-- Snowflake: NUMERIC(18,2) column
CREATE OR REPLACE TEMP TABLE rate_store (rate NUMERIC(18,2));
INSERT INTO rate_store SELECT 1.0 / 3;
SELECT * FROM rate_store;  -- returns 0.33 (truncated from 0.333333...)

-- Compare to:
SELECT 1.0::NUMERIC(18,10) / 3::NUMERIC(18,10);  -- 0.3333333333 (full precision)
```

**How to catch it:**
```sql
-- When storing computed rates, always specify adequate precision:
CREATE TABLE rates (rate NUMERIC(18, 10));  -- 10 decimal places for rates
-- And verify the stored value matches the computed value:
SELECT ABS(rate - (1.0/3)) < 0.0000001 FROM rate_store;
```

**Real-world trigger:** Interest rate stored as NUMERIC(18,2) in a mortgage calculation table. A rate of 1/3% is stored as 0.33% instead of 0.333...%. Compounded monthly over a 30-year mortgage, this truncation produces a total interest error of thousands of dollars per loan.

---

### Implicit NUMERIC Promotion in Window Functions — Different Precision Than Expected

**What it looks like:**
```sql
SELECT
    product_id,
    price,
    AVG(price) OVER (PARTITION BY category) AS category_avg_price
FROM products;
```

**What actually happens:** If `price` is `NUMERIC(10,2)`, `AVG()` in different engines returns different precision:
- PostgreSQL: `AVG(NUMERIC)` returns `NUMERIC` with full precision.
- Snowflake: `AVG(NUMERIC(10,2))` may return `FLOAT` in some contexts.
- MySQL: `AVG()` returns a DOUBLE (floating-point).

The implicit type promotion means a column you believe is NUMERIC (exact decimal) may actually be FLOAT (IEEE approximation) in the result set, silently losing exactness.

**Minimal repro:**
```sql
-- Check the result type of AVG on a NUMERIC column:
-- PostgreSQL:
SELECT pg_typeof(AVG(price)) FROM products LIMIT 1;
-- Returns 'numeric' in PostgreSQL (good)

-- MySQL:
-- Returns 'double' silently (implicit float promotion)
```

**How to catch it:**
```sql
-- Explicitly cast the result of AVG to the desired precision:
SELECT AVG(price)::NUMERIC(18,4) AS category_avg_price
FROM products
GROUP BY category;
```

**Real-world trigger:** Price benchmark report using windowed AVG. Result type is implicitly FLOAT in MySQL. Downstream comparison `WHERE price < category_avg_price` has floating-point comparison issues. A $10.00 product with a $10.00 category average is silently excluded because `10.00::NUMERIC != 10.000000000000002::FLOAT`.
