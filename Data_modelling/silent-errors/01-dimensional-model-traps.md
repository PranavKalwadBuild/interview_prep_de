<!-- data-modelling-patterns: Silent Errors — Dimensional Model Traps -->

<!-- Part of Data_modelling: Silent Errors — Dimensional Model Traps -->

# Silent Errors — Dimensional Model Traps

These are structural errors in star schemas, galaxy schemas, and dimensional models. Every pattern
below runs without an exception, passes code review because each individual JOIN looks correct, and
produces results that are numerically plausible — just wrong.

---

### 1. Fan-Out Trap

**What it looks like:**
A fact table is joined to a dimension that has more than one row per fact foreign key. The JOIN
logic is syntactically correct and returns rows without error.

**What actually happens:**
Each fact row is duplicated once per matching dimension row. `SUM(revenue)` is inflated by the
degree of fan-out (2 matching dimension rows → 2× revenue).

**Why it's insidious:**
The JOIN condition is valid SQL. Row counts look reasonable. The result set has the right columns.
The inflation is only visible if you independently know the true total.

**Example:**
```sql
-- dim_promotion has multiple rows per product_key (multiple promotions active at once)
SELECT
    dp.promotion_name,
    SUM(fs.revenue)          AS total_revenue   -- silently 2x or 3x inflated
FROM fact_sales fs
JOIN dim_promotion dp ON fs.product_key = dp.product_key
GROUP BY dp.promotion_name;
```

**Detection query / invariant:**
```sql
-- Check for fan-out: does the dimension have > 1 row per FK value?
SELECT product_key, COUNT(*) AS cnt
FROM dim_promotion
GROUP BY product_key
HAVING COUNT(*) > 1;

-- Compare aggregated total against a baseline (no dimension join)
SELECT SUM(revenue) FROM fact_sales;                          -- baseline
SELECT SUM(fs.revenue) FROM fact_sales fs JOIN dim_promotion dp ON fs.product_key = dp.product_key;
-- If second > first, you have fan-out
```

**Real-world consequence:**
Marketing reports revenue lift from a promotion campaign that is 2× the real lift. Campaign is
deemed successful. Budget is doubled for the next quarter. ROI is never actually positive.

---

### 2. Chasm Trap (Galaxy Schema Double-Count)

**What it looks like:**
Two fact tables share a common dimension. A single query joins both facts through that dimension
to produce a combined report.

**What actually happens:**
The result is effectively a Cartesian product of the two fact tables for any entity that appears in
both. A customer with 3 orders and 2 support tickets produces 6 rows for that customer in the
combined result. Aggregations are inflated by the cross-product factor.

**Why it's insidious:**
Each individual star schema is correct. The cross-fact join is the problem — and it looks like a
normal multi-table join to anyone reviewing the query.

**Example:**
```sql
-- fact_orders: 1 row per order
-- fact_support: 1 row per support ticket
-- Both join to dim_customer

SELECT
    dc.customer_name,
    SUM(fo.order_value)    AS total_orders,      -- inflated by # support tickets
    COUNT(fs.ticket_id)    AS support_tickets     -- inflated by # orders
FROM dim_customer dc
JOIN fact_orders   fo ON dc.customer_key = fo.customer_key
JOIN fact_support  fs ON dc.customer_key = fs.customer_key
GROUP BY dc.customer_name;
```

**Detection query / invariant:**
```sql
-- Correct approach: aggregate each fact independently, then join
WITH order_agg AS (
    SELECT customer_key, SUM(order_value) AS total_orders
    FROM fact_orders GROUP BY customer_key
),
support_agg AS (
    SELECT customer_key, COUNT(ticket_id) AS support_tickets
    FROM fact_support GROUP BY customer_key
)
SELECT dc.customer_name, oa.total_orders, sa.support_tickets
FROM dim_customer dc
LEFT JOIN order_agg   oa ON dc.customer_key = oa.customer_key
LEFT JOIN support_agg sa ON dc.customer_key = sa.customer_key;

-- If this total differs from the direct join total, you had a chasm trap.
```

**Real-world consequence:**
A churn analysis that joins support tickets to orders concludes that high-ticket customers have
3× the order value — but that's purely the cross-product artifact. Customer success invests
heavily in account management for the wrong segment.

---

### 3. Role-Playing Dimension Aliased Incorrectly

**What it looks like:**
A single date dimension is used for multiple roles (order date, ship date, due date) via SQL
aliases. The aliases appear correct in the model.

**What actually happens:**
Both aliases point to the same join key. Shipping lag (ship_date - order_date) is always zero
because both resolve to the same date dimension row.

**Why it's insidious:**
The query runs correctly. `ship_date_key` and `order_date_key` are both valid columns on the
fact table. The mistake is that both WHERE clauses or SELECT columns reference the same alias
target — invisible unless you trace the join predicate carefully.

**Example:**
```sql
-- Bug: both joins use the same alias
SELECT
    d_order.calendar_date   AS order_date,
    d_ship.calendar_date    AS ship_date,
    -- These will ALWAYS be equal — shipping lag is always 0
    DATEDIFF('day', d_order.calendar_date, d_ship.calendar_date) AS shipping_lag_days
FROM fact_orders fo
JOIN dim_date d_order ON fo.order_date_key  = d_order.date_key
JOIN dim_date d_ship  ON fo.order_date_key  = d_ship.date_key   -- BUG: should be ship_date_key
```

**Detection query / invariant:**
```sql
-- Shipping lag should have a distribution. If all values = 0, the alias is wrong.
SELECT
    MIN(DATEDIFF('day', order_date_key, ship_date_key)) AS min_lag,
    MAX(DATEDIFF('day', order_date_key, ship_date_key)) AS max_lag,
    AVG(DATEDIFF('day', order_date_key, ship_date_key)) AS avg_lag
FROM fact_orders;
-- All zeros = role-playing alias bug (or genuinely instantaneous fulfilment — verify with source)
```

**Real-world consequence:**
Logistics KPI "average shipping lag" is reported as 0 days for months. SLA compliance looks
perfect. Warehouse operations investment is cut. When the bug is fixed, actual avg lag is 3.2 days
and the company is already in breach of customer SLAs.

---

### 4. Degenerate Dimension Key Collision Across Systems

**What it looks like:**
Order numbers stored as a degenerate dimension (string column on the fact table, no separate
dimension table). Fact rows are grouped or filtered by order number.

**What actually happens:**
After a SAP→Salesforce migration, both systems independently generate `order_id = 'ORD-1001'`
for completely different orders. Grouping collapses distinct orders from two systems into one
summary row. Revenue for both orders is summed under one identity.

**Why it's insidious:**
No foreign key constraint exists (degenerate dimensions have none). The fact table looks perfectly
valid. The collision is invisible unless you trace back to source system identifiers.

**Example:**
```sql
-- After migration both systems produced overlapping IDs
SELECT
    degenerate_order_id,
    SUM(line_revenue) AS total_revenue
FROM fact_order_lines
GROUP BY degenerate_order_id;
-- 'ORD-1001' silently sums revenue from two completely different orders
```

**Detection query / invariant:**
```sql
-- Add source_system to the group-by and compare
SELECT
    degenerate_order_id,
    source_system,
    SUM(line_revenue) AS revenue
FROM fact_order_lines
GROUP BY degenerate_order_id, source_system;

-- Then compare against GROUP BY degenerate_order_id alone
-- Discrepancy = collision
```

**Real-world consequence:**
Revenue per order in a post-migration reconciliation report is doubled for colliding IDs. Finance
signs off on the migration as "clean" because total revenue matches. Per-order metrics are wrong
indefinitely.

---

### 5. Conformed Dimension Drift Across Data Marts

**What it looks like:**
A `customer` dimension is shared across the Sales mart and the Support mart. Both reference
`customer_id`. Cross-mart reports join through this shared key.

**What actually happens:**
The Sales mart adopted a new customer segmentation model (enterprise/mid-market/SMB) in Q2.
The Support mart still uses the old segmentation (large/medium/small). `customer_id` values are
the same but `segment` means different things. Cross-mart segment analysis compares apples to
oranges silently.

**Why it's insidious:**
The join on `customer_id` is structurally correct. Both `segment` columns have values. There is
no schema error. The semantic drift is invisible without business context.

**Example:**
```sql
-- Cross-mart query: support tickets per sales segment
SELECT
    s.segment,           -- Sales mart segment (enterprise/mid-market/SMB)
    COUNT(st.ticket_id)  AS support_tickets
FROM sales_mart.dim_customer s
JOIN support_mart.fact_tickets st ON s.customer_id = st.customer_id
GROUP BY s.segment;
-- Result is wrong because st was assigned using old segment rules at ticket creation
```

**Detection query / invariant:**
```sql
-- Check segment label distribution across marts for the same customer_ids
SELECT
    s.customer_id,
    s.segment          AS sales_segment,
    sup.segment        AS support_segment
FROM sales_mart.dim_customer s
JOIN support_mart.dim_customer sup ON s.customer_id = sup.customer_id
WHERE s.segment <> sup.segment
LIMIT 100;
-- Non-zero row count = conformed dimension drift
```

**Real-world consequence:**
Enterprise support cost-per-ticket analysis is used to price enterprise contracts. The segment
definitions don't match, so enterprise cost is calculated against a different customer set than
the one being priced. Contract economics are miscalculated.

---

### 6. Junk Dimension NULL Explosion

**What it looks like:**
A junk dimension combines several low-cardinality flag columns (e.g., `is_promo`, `is_digital`,
`channel`) into a single surrogate key. Each unique combination of flags gets one row.

**What actually happens:**
When any flag is NULL, the combination is treated as a distinct new row in the junk dimension.
`NULL, 'web', 'Y'` and `NULL, 'web', 'N'` are two separate rows — even if business logic says
NULL means "not applicable." Junk dimension cardinality grows unboundedly and fact rows for
NULL-flag events join to incorrect surrogate keys.

**Why it's insidious:**
NULL is a valid SQL value. The junk dimension INSERT doesn't fail. Aggregations by flag produce
wrong counts because NULL flags are split across multiple rows rather than rolled up.

**Example:**
```sql
-- Junk dimension creation (simplified)
INSERT INTO dim_junk (is_promo, is_digital, channel, junk_key)
SELECT DISTINCT is_promo, is_digital, channel, HASH(is_promo, is_digital, channel)
FROM staging_events;
-- NULL || 'web' || 'Y' gets its own row
-- NULL || 'web' || 'N' gets a DIFFERENT row
-- Both should logically map to "channel=web, digital=unknown"

-- Downstream: COUNT(*) WHERE is_promo IS NULL breaks because NULLs landed in multiple junk rows
SELECT SUM(revenue) FROM fact_sales fs
JOIN dim_junk dj ON fs.junk_key = dj.junk_key
WHERE dj.is_promo IS NULL;  -- silently undercounts because NULLs are split
```

**Detection query / invariant:**
```sql
-- Check for NULL-heavy junk dimension rows
SELECT COUNT(*) AS null_combination_rows
FROM dim_junk
WHERE is_promo IS NULL OR is_digital IS NULL OR channel IS NULL;

-- If high, check whether those rows are intended or artifacts
-- Fix: COALESCE(is_promo, 'N/A') before hashing
```

**Real-world consequence:**
Promotion lift analysis excludes a significant chunk of events (those with NULL promo flags) from
the "no promotion" group — they're silently split into multiple junk rows, none of which aggregates
cleanly. Promotion appears more effective than it is.

---

### 7. Bridge Table Double-Counting for Total Metrics

**What it looks like:**
A customer-to-segment many-to-many bridge table resolves which customers belong to which
segments. Queries join the fact table through the bridge to get segment-level revenue.

**What actually happens:**
A customer in two segments (e.g., "loyalty" and "enterprise") contributes their full revenue to
both segments. When segments are summed to a grand total, that customer's revenue is counted
twice. This is arithmetically "correct by design" for per-segment analysis but silently wrong
for grand-total metrics.

**Why it's insidious:**
Per-segment numbers are correct. The bridge table is architecturally standard. The error only
manifests when someone sums segment totals to derive a company-wide total — a completely natural
thing to do in a BI tool.

**Example:**
```sql
-- Revenue by segment (correct per segment, but sum is wrong for total)
SELECT
    bs.segment_key,
    ds.segment_name,
    SUM(fs.revenue) AS segment_revenue
FROM fact_sales fs
JOIN bridge_customer_segment bs ON fs.customer_key = bs.customer_key
JOIN dim_segment ds ON bs.segment_key = ds.segment_key
GROUP BY bs.segment_key, ds.segment_name;

-- A BI user selects "SUM(segment_revenue)" across all segments
-- Result: $12M. Actual company revenue: $9M (3M counted twice for dual-segment customers)
```

**Detection query / invariant:**
```sql
-- Compare bridge-based total against direct fact total
SELECT SUM(revenue) AS direct_total FROM fact_sales;

SELECT SUM(fs.revenue) AS bridge_total
FROM fact_sales fs
JOIN bridge_customer_segment bs ON fs.customer_key = bs.customer_key;

-- If bridge_total > direct_total, customers exist in multiple segments
-- Fix: use weighting factors (1/N where N = number of segments per customer)
-- or restrict grand-total queries to use direct fact without bridge
```

**Real-world consequence:**
Company-wide revenue is overstated by 15% in a board presentation built by summing segment
subtotals. The error is discovered after the board meeting when CFO reconciles to the GL.

---

### 8. Implicit Dimension Measure (Implicit Chasm Trap)

**What it looks like:**
A dimension table contains a numeric column — for example, `dim_product.list_price`. A query
joins a fact table to the dimension and sums the dimension measure alongside the fact measure.

**What actually happens:**
`list_price` is a dimension attribute, not an additive measure. When the fact has multiple
rows per product (e.g., multiple transactions), `SUM(dim_product.list_price)` inflates by the
transaction count. The dimension value gets treated as if it belonged to a separate fact table,
creating the classic implicit chasm trap.

**Why it's insidious:**
`SUM()` on a numeric column is syntactically valid. The query runs. The list price in the
dimension looks like a reasonable aggregate measure.

**Example:**
```sql
SELECT
    dp.product_name,
    SUM(fs.units_sold)      AS total_units,
    SUM(dp.list_price)      AS total_list_price    -- WRONG: list_price * number of transactions
FROM fact_sales fs
JOIN dim_product dp ON fs.product_key = dp.product_key
GROUP BY dp.product_name;
-- list_price is $50. Product sold 200 times. SUM(list_price) = $10,000, not $50.
```

**Detection query / invariant:**
```sql
-- Compare SUM(dim.list_price) to MAX(dim.list_price) per product
SELECT
    product_key,
    SUM(dp.list_price)  AS sum_price,
    MAX(dp.list_price)  AS max_price,
    COUNT(*)            AS fact_rows
FROM fact_sales fs
JOIN dim_product dp ON fs.product_key = dp.product_key
GROUP BY product_key
HAVING SUM(dp.list_price) <> MAX(dp.list_price);
-- Any row here = implicit chasm trap
```

**Real-world consequence:**
A pricing report shows "total list price" as 200× higher than actual price. Margins computed
against this inflated list price look impossibly thin. Pricing team launches an unnecessary
price increase investigation.

---

### 9. Snowflake Schema Dimension Join Shortcut

**What it looks like:**
A snowflake schema has `dim_product → dim_category → dim_department`. A query joins directly
from the fact to `dim_category`, skipping `dim_product`, to get department-level metrics.

**What actually happens:**
Products with no category assignment (orphan products) are silently excluded from the fact JOIN.
Department-level revenue is understated by the orphan product revenue. No error is thrown —
the INNER JOIN simply drops them.

**Why it's insidious:**
The snowflake join appears to be a "simpler" query. The missing rows are invisible because there's
no error — just a smaller result set. Row-count checks against the source won't catch this unless
they also check the specific orphan products.

**Example:**
```sql
-- Shortcut join misses products not linked to a category
SELECT
    dcat.category_name,
    SUM(fs.revenue)
FROM fact_sales fs
JOIN dim_category dcat ON fs.category_key = dcat.category_key  -- INNER JOIN drops NULLs
GROUP BY dcat.category_name;

-- Products where category_key IS NULL are silently dropped
-- Those products may represent 8% of revenue
```

**Detection query / invariant:**
```sql
-- Check how many fact rows have NULL or unmapped category_key
SELECT
    COUNT(*)                                            AS total_fact_rows,
    COUNT(dcat.category_key)                            AS matched_rows,
    COUNT(*) - COUNT(dcat.category_key)                 AS dropped_rows,
    SUM(fs.revenue)                                     AS total_revenue,
    SUM(CASE WHEN dcat.category_key IS NULL THEN fs.revenue ELSE 0 END) AS dropped_revenue
FROM fact_sales fs
LEFT JOIN dim_category dcat ON fs.category_key = dcat.category_key;
```

**Real-world consequence:**
Department revenue totals are used for P&L reporting. The missing 8% of revenue is never
attributed to a department, so no department is responsible for it — it disappears from the
P&L. Overal revenue reconciliation to the GL fails but is blamed on "data warehouse lag."
