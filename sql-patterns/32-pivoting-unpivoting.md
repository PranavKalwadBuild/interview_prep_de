<!-- Part of sql-patterns: Pivoting and Unpivoting -->
<!-- Source: sql_patterns.md lines 8432–8625 -->

## 18. Pivoting & Unpivoting

### What it solves

- **Pivot**: Turn row values into columns (rotate)
- **Unpivot**: Turn columns into rows (reverse)

### Keywords to spot
> "pivot", "transpose", "turn rows into columns", "wide format",
> "one column per category", "reshape", "column per month",
> "cross-tab", "matrix format", "wide table", "rotate",
> "rows to columns", "columns to rows", "normalise", "denormalise",
> "spread across columns", "flatten"

### Business Context

- **Fintech/Retail:** Show monthly revenue/volume with one column per month for a BI dashboard (cohort matrix); pivot trade type (BUY/SELL) from rows into side-by-side columns for comparison reports
- **Analytics:** Convert a key-value attribute store (user_id, attribute, value) to a wide feature table for ML model input; unpivot a wide sales table back to long format for window functions
- **Reporting:** Pivot survey responses (one row per question per respondent) into one row per respondent with one column per question; cross-tab of product × region revenue
- **Data Engineering:** Unpivot a wide report received from a finance system back to long format for aggregation; normalise a denormalised Excel export into a relational schema
- **A/B Testing:** Pivot experiment metrics (metric_name, value) from long to wide so each metric has its own column per variant for easy statistical comparison

### Boilerplate — Manual Pivot (CASE WHEN)

```sql
-- Pivot: rows of (user_id, month, volume) → one column per month
SELECT
    user_id,
    SUM(CASE WHEN month = '2024-01' THEN volume ELSE 0 END) AS jan_2024,
    SUM(CASE WHEN month = '2024-02' THEN volume ELSE 0 END) AS feb_2024,
    SUM(CASE WHEN month = '2024-03' THEN volume ELSE 0 END) AS mar_2024
FROM monthly_volume
GROUP BY user_id;
```

### Boilerplate — Unpivot (UNION ALL)

```sql
-- Unpivot: wide table → long table
SELECT user_id, 'jan_2024' AS month, jan_2024 AS volume FROM wide_table
UNION ALL
SELECT user_id, 'feb_2024' AS month, feb_2024 AS volume FROM wide_table
UNION ALL
SELECT user_id, 'mar_2024' AS month, mar_2024 AS volume FROM wide_table;
```

### Gotchas

- Manual pivot requires knowing all column values in advance (not dynamic)
- Dynamic pivot requires stored procedures or application-layer code in most SQL dialects
- For analytics, long (unpivoted) format is generally better for window functions and GROUP BY

### Edge Cases

#### Edge 18-A: ELSE 0 in SUM pivot hides NULLs; ELSE NULL in COUNT inflates them

**Problem:**

```sql
-- Pivoting monthly revenue with CASE WHEN + SUM
SELECT
    product_id,
    SUM(CASE WHEN month = 'Jan' THEN revenue ELSE 0 END) AS jan,
    SUM(CASE WHEN month = 'Feb' THEN revenue ELSE 0 END) AS feb
FROM monthly_revenue GROUP BY product_id;
-- If a product has no revenue in Jan: jan = 0 (correct for revenue, SUM of empty = 0)
-- But: if the ABSENCE of data means "no data" (not zero), using 0 is misleading
-- Report: Jan revenue = 0 looks like "measured zero", not "no measurement"
```

**Fix — use NULL for "no data" and 0 for "measured zero":**

```sql
-- FIX — use NULL for "no data" and 0 for "measured zero":
SUM(CASE WHEN month = 'Jan' THEN revenue END) AS jan  -- NULL if no Jan rows for this product
-- Then downstream consumers can distinguish NULL (no measurement) from 0 (actual zero revenue)
```

#### Edge 18-B: Dynamic pivot — unknown number of categories

**Problem:**

```sql
-- CASE WHEN pivot requires hardcoded column names
-- If new product categories are added, the pivot query silently misses them
-- (no error — the new category just doesn't appear as a column)

-- WRONG — will miss 'Premium' category added after query was written:
SUM(CASE WHEN category = 'Basic'    THEN revenue END) AS basic,
SUM(CASE WHEN category = 'Pro'      THEN revenue END) AS pro,
-- 'Premium' launched in Q3 → never appears in report → revenue silently missing

-- Detection:
SELECT DISTINCT category FROM products;  -- run this first to see all categories
-- Then update the pivot query OR use dynamic SQL

-- Cannot be done in pure SQL — requires stored procedure or application-layer logic
-- In dbt: use `{% for cat in categories %}` Jinja2 loop to generate dynamic columns
```

**Fix:**

```sql
-- For static known categories: enumerate them and add a catch-all for new ones:
SELECT product_id,
    SUM(CASE WHEN category = 'Basic'    THEN revenue END) AS basic_revenue,
    SUM(CASE WHEN category = 'Pro'      THEN revenue END) AS pro_revenue,
    SUM(CASE WHEN category = 'Premium'  THEN revenue END) AS premium_revenue,
    SUM(CASE WHEN category NOT IN ('Basic', 'Pro', 'Premium') THEN revenue END) AS other_revenue
FROM monthly_revenue GROUP BY product_id;
-- 'other_revenue' catches any new categories silently — alert when it is non-zero

-- Add a monitoring check that alerts when new categories appear:
SELECT DISTINCT category FROM products
WHERE category NOT IN ('Basic', 'Pro', 'Premium');
-- Run this nightly; if it returns rows, update the pivot query before the next report

```sql
-- BEFORE: pivot with 12 month columns + 50 category combinations
SELECT product_id,
    SUM(CASE WHEN month = 'Jan' AND category = 'A' THEN revenue END) AS jan_a,
    SUM(CASE WHEN month = 'Jan' AND category = 'B' THEN revenue END) AS jan_b,
    -- ... 598 more columns (12 months × 50 categories)
FROM sales GROUP BY product_id;
-- 600 CASE WHEN expressions evaluated for every 800M rows — CPU intensive

-- FIX 1: Keep data in long (unpivoted) format; pivot only at the presentation layer
-- Long format is more efficient in columnar storage and more flexible for ad-hoc queries
-- Use BI tools (Tableau, Looker, Metabase) to pivot for display
-- SQL: return the pre-aggregated unpivoted result:
SELECT product_id, DATE_TRUNC('month', sale_date) AS month, category, SUM(revenue) AS revenue
FROM sales
WHERE sale_date >= '2024-01-01'
GROUP BY product_id, month, category;
-- 3 output columns, arbitrary months/categories — BI tool handles the pivot

-- FIX 2: If wide pivot is required, pre-aggregate then pivot (two steps)
-- Step 1: aggregate raw data to (product, month, category, revenue) → much smaller table
CREATE TABLE monthly_product_revenue AS
SELECT product_id, month, category, SUM(revenue) AS revenue
FROM sales GROUP BY product_id, month, category;
-- Step 2: pivot on the small aggregated table
SELECT product_id,
    SUM(CASE WHEN month = 'Jan' THEN revenue END) AS jan_revenue,
    ...
FROM monthly_product_revenue GROUP BY product_id;
-- Pivot runs on 100K rows (aggregated) not 800M (raw)
```

#### System-Level Fix


---

---


