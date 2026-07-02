<!-- data-modelling-patterns: Silent Errors — Grain and Aggregation Integrity -->

<!-- Part of Data_modelling: Silent Errors — Grain and Aggregation Integrity -->

# Silent Errors — Grain and Aggregation Integrity

Grain and aggregation errors are the final mile of silent corruption: the data model is correct,
the ETL ran correctly, but the query or reporting layer aggregates at the wrong level or mixes
incompatible grains. These bugs are especially hard to catch in self-service BI environments
where non-technical analysts build their own reports by joining tables without understanding
the grain of each.

---

### 1. Grain Violation in a Fact Table — Two Grains, One Table

**What it looks like:**
A fact table contains both order-header-level rows (one per order) and order-line-level rows
(one per product per order). The table is used by all reports as a single source of truth.

**What actually happens:**
`SUM(revenue)` on the entire table double-counts orders that have line items. A $1000 order with
5 line items contributes both the header-level $1000 row AND the sum of 5 line-level rows that
also total $1000. `SUM(revenue)` = $2000 for a single $1000 order.

**Why it's insidious:**
The table has valid rows. No schema constraint enforces grain. Each row is individually correct.
The inflation is only visible when comparing against a source-level aggregate — which most
engineers don't do routinely.

**Example:**
```sql
-- Fact table with mixed grain:
-- Row type 1: grain=order,  order_id=5001, product_key=NULL, revenue=1000 (header total)
-- Row type 2: grain=line,   order_id=5001, product_key=101,  revenue=600  (line 1)
-- Row type 3: grain=line,   order_id=5001, product_key=102,  revenue=400  (line 2)

SELECT SUM(revenue) FROM fact_orders;  -- returns 2000, actual is 1000

-- Or more subtly: some orders have header rows, others only have line rows
-- The inflation ratio varies by order, making the pattern even harder to spot
```

**Detection query / invariant:**
```sql
-- Detect mixed grain: check whether any order_id has both a NULL product_key (header)
-- and non-NULL product_key (line) row
SELECT
    order_id,
    SUM(CASE WHEN product_key IS NULL THEN 1 ELSE 0 END) AS header_rows,
    SUM(CASE WHEN product_key IS NOT NULL THEN 1 ELSE 0 END) AS line_rows
FROM fact_orders
GROUP BY order_id
HAVING header_rows > 0 AND line_rows > 0;
-- Any result = mixed grain, double-counting guaranteed for those orders

-- Invariant: SUM(revenue) should equal source system's total order value
SELECT SUM(revenue) AS warehouse_total FROM fact_orders;
SELECT SUM(order_total) AS source_total FROM source_orders;
-- If warehouse_total > source_total, grain violation exists
```

**Real-world consequence:**
Finance uses the fact table for revenue reporting. Revenue is overstated by ~40% because half
the orders have header rows in addition to line rows (the header rows were added when order-level
discounts were introduced). Quarterly earnings report is overstated. Restatement is required.

---

### 2. Mixed-Period Join: Daily Fact to Monthly Fact

**What it looks like:**
A daily sales fact is joined to a monthly target fact on `MONTH(sale_date) = target_month`.
Each daily row in the query result now has the full monthly target attached.

**What actually happens:**
Summing the monthly target column over a month of daily data produces 28–31× the real monthly
target (once per day in the month). A "pacing" report comparing daily actuals to monthly targets
is wildly inflated on the target side.

**Why it's insidious:**
The JOIN is logically correct — each day belongs to its month. The inflation is only visible
to someone who knows that monthly targets must not be summed across daily rows. In a BI tool
that auto-aggregates, this is a one-click mistake.

**Example:**
```sql
-- fact_daily_sales: date, region, daily_revenue (30 rows for June per region)
-- fact_monthly_targets: month, region, monthly_target (1 row for June per region)

SELECT
    MONTH(fds.sale_date) AS month,
    fds.region,
    SUM(fds.daily_revenue)   AS actual_revenue,    -- correct
    SUM(fmt.monthly_target)  AS target_revenue     -- WRONG: 30 * monthly_target
FROM fact_daily_sales fds
JOIN fact_monthly_targets fmt
  ON MONTH(fds.sale_date) = fmt.month
  AND fds.region = fmt.region
GROUP BY 1, 2;
-- June monthly_target=$500K appears 30 times → SUM = $15M
```

**Detection query / invariant:**
```sql
-- Never SUM a monthly measure in a query that also aggregates daily data
-- Correct approach: join pre-aggregated daily to monthly
WITH daily_agg AS (
    SELECT MONTH(sale_date) AS month, region, SUM(daily_revenue) AS actual_revenue
    FROM fact_daily_sales GROUP BY 1, 2
)
SELECT
    d.month,
    d.region,
    d.actual_revenue,
    t.monthly_target,           -- use directly, NOT SUM()
    d.actual_revenue / NULLIF(t.monthly_target, 0) AS attainment_pct
FROM daily_agg d
JOIN fact_monthly_targets t ON d.month = t.month AND d.region = t.region;
```

**Real-world consequence:**
A sales pacing dashboard shows monthly attainment at 3% for June (actual $500K vs "target" $15M
from the inflated SUM). Sales leadership believes the team is massively behind. An emergency
performance review is convened. The actual attainment is 100%.

---

### 3. Periodic Snapshot SUM Across Time Periods

**What it looks like:**
A periodic snapshot fact table stores inventory levels (units on hand) once per day. A report
`SUM(units_on_hand)` over a date range is used for "total inventory exposure."

**What actually happens:**
`SUM(units_on_hand)` over 30 days of snapshots gives 30× the actual inventory level (each day's
snapshot counts independently). The correct aggregation for "end-of-period inventory" is a
filter on the last snapshot date. The correct aggregation for "average daily inventory" is `AVG`.
Neither is `SUM`.

**Why it's insidious:**
`SUM()` is the default BI aggregation function. Inventory looks like any other numeric measure
to a non-expert report builder. The result is implausible only if you know the true inventory level.

**Example:**
```sql
-- Periodic snapshot: 30 rows in June, one per day
-- Each row has units_on_hand = 10,000 (stable inventory during the month)

-- WRONG report:
SELECT MONTH(snapshot_date), SUM(units_on_hand) AS total_inventory
FROM fact_inventory_snapshot
WHERE snapshot_date BETWEEN '2024-06-01' AND '2024-06-30'
GROUP BY 1;
-- Result: 300,000 units (30 days × 10,000 per day)
-- Actual: 10,000 units

-- CORRECT options:
-- End-of-period: WHERE snapshot_date = '2024-06-30'
-- Average daily: AVG(units_on_hand)
-- For business-process additive: only total units RECEIVED or SHIPPED (transaction fact)
```

**Detection query / invariant:**
```sql
-- Check: does SUM(snapshot_measure) / COUNT(DISTINCT snapshot_date) ≈ AVG(snapshot_measure)?
-- If ratio is close to COUNT(DISTINCT snapshot_date), the measure is being summed across time
SELECT
    MONTH(snapshot_date) AS month,
    SUM(units_on_hand)                  AS sum_inventory,
    AVG(units_on_hand)                  AS avg_inventory,
    COUNT(DISTINCT snapshot_date)       AS snapshot_count,
    SUM(units_on_hand) / COUNT(DISTINCT snapshot_date) AS implied_avg
FROM fact_inventory_snapshot
GROUP BY 1
HAVING ABS(sum_inventory / NULLIF(implied_avg, 0) - COUNT(DISTINCT snapshot_date)) < 1;
-- Close to snapshot_count = the SUM equals avg * days = meaningless aggregate
```

**Real-world consequence:**
Supply chain report shows 300,000 units "at risk" when inventory is actually 10,000 units.
A procurement emergency order is placed for 50,000 additional units. Overstock costs $2M in
carrying costs before the error is discovered.

---

### 4. NULL Propagation in Multi-Level Aggregation (Empty Days as Zeros)

**What it looks like:**
Silver aggregates raw events to daily level. Days with no events produce no rows (or are filled
with 0 via a date spine). Gold aggregates daily to monthly. A second Gold model calculates
average daily activity for trend analysis.

**What actually happens:**
The daily model fills days with 0 events as `metric = 0` (via `COALESCE(metric, 0)` from a
date spine). The monthly average includes those 0-value days in the denominator. The average
is artificially depressed by zero-activity days — which may be genuine business zeros OR may be
pipeline failures (data not yet loaded, source outage).

**Why it's insidious:**
COALESCE(metric, 0) is explicitly coded. The developer intended 0 for empty days. The error is
semantic: zero means "no activity happened" AND "data was not loaded" — identical representation,
different meaning.

**Example:**
```sql
-- Silver: date spine left-joined to events, COALESCE fills empties
INSERT INTO silver_daily_signups
SELECT
    ds.date,
    COALESCE(COUNT(e.user_id), 0) AS signups
FROM date_spine ds
LEFT JOIN raw_signups e ON ds.date = e.signup_date::date
GROUP BY ds.date;

-- Gold: monthly average (includes zero days from pipeline failures)
SELECT
    DATE_TRUNC('month', date) AS month,
    AVG(signups) AS avg_daily_signups   -- depressed by pipeline-failure days (zeros)
FROM silver_daily_signups
GROUP BY 1;

-- If pipeline failed for 3 days in August, those 3 days are 0 in silver
-- August avg is computed over 31 days (3 of which are pipeline failures showing 0)
-- Actual avg for 28 active days is higher; reported avg is artificially lower
```

**Detection query / invariant:**
```sql
-- Check for suspicious zero-signup days that correlate with known pipeline run failures
SELECT
    sd.date,
    sd.signups,
    pl.pipeline_status
FROM silver_daily_signups sd
LEFT JOIN pipeline_run_log pl ON sd.date = pl.run_date
WHERE sd.signups = 0
ORDER BY sd.date;
-- If pipeline_status = 'failed' on days with signups=0 → those zeros are pipeline artefacts, not real

-- Fix: use NULL (not 0) for days with no data, let BI handle display formatting
-- Use a separate `data_available` flag to distinguish genuine zero from missing
```

**Real-world consequence:**
Product growth team reports "August was a weak month for signups." A feature team rushes a
signup flow redesign. The August "weakness" was 3 days of pipeline failure inflating the
denominator. Real signup rates were healthy.

---

### 5. Slowly Changing KPI — Retroactive History Rewrite on Pipeline Rerun

**What it looks like:**
A KPI is defined as `(revenue - cost) / revenue`. Cost data is delivered by finance monthly with
retroactive adjustments for the prior 3 months. Rerunning the pipeline updates cost for those
3 months. The KPI is recomputed from the updated cost.

**What actually happens:**
Historical KPI numbers silently change every month when cost adjustments arrive. A slide deck
from last month showing "June KPI = 32.4%" is inconsistent with the current warehouse showing
"June KPI = 29.8%." Business stakeholders see discrepancies between board decks and live
dashboards and lose trust in both.

**Why it's insidious:**
The recomputation is mathematically correct — cost adjustments should flow through to KPIs.
The silent error is that there is no audit trail of what the KPI was at each reporting date,
making point-in-time reporting impossible.

**Example:**
```sql
-- Pipeline rebuilds fact_kpi for last 3 months whenever cost adjustments arrive
-- June 2024: pipeline runs on July 1 → KPI=32.4% (used in July board deck)
-- August adjustment: cost data revised for June → KPI recomputes → June KPI=29.8%
-- Board deck from July shows 32.4%; live dashboard shows 29.8%

-- No error. Both numbers are "correct" at their respective reporting moments.
-- Stakeholders: "which number do we trust?"
```

**Detection query / invariant:**
```sql
-- Pattern: store a "reporting_snapshot" table that freezes KPIs at report date
-- Detect retroactive changes by comparing snapshot to live:
SELECT
    rs.reporting_month,
    rs.snapshot_kpi,
    lk.current_kpi,
    ABS(rs.snapshot_kpi - lk.current_kpi) AS kpi_drift
FROM kpi_reporting_snapshots rs
JOIN live_kpi lk ON rs.reporting_month = lk.month
WHERE ABS(rs.snapshot_kpi - lk.current_kpi) > 0.005  -- > 0.5% drift
ORDER BY kpi_drift DESC;

-- Prevention: implement a snapshot/audit table that records KPI values at report close
-- Document which KPI version was used for each board report
```

**Real-world consequence:**
The CFO presents a KPI of 32.4% to the board. Two months later, the audit committee reviews
the same period and sees 29.8% in the live system. Auditors question financial reporting
integrity. A forensic review confirms the number changed due to cost adjustments, but the
lack of a snapshot audit trail makes the explanation laborious.

---

### 6. Date Spine Zero vs. Legitimate Business Zero — Silent Quality Masquerade

**What it looks like:**
A date spine is left-joined to a fact table. `COALESCE(metric, 0)` fills NULL for days with
no events. The intent is to show 0 for days with no activity. The output looks complete.

**What actually happens:**
Some days show 0 because there was genuinely no business activity. Other days show 0 because
the pipeline failed that day and no data was loaded. A third category: days that are 0 because
the source system was down. All three look identical in the output. No flag distinguishes
"business zero" from "data missing."

**Why it's insidious:**
The output is valid SQL. COALESCE is correct. The report looks complete — every day has a value.
The distinction between the three zero types requires external knowledge (pipeline logs, source
system uptime).

**Example:**
```sql
-- Date spine with COALESCE: every day has a value
SELECT
    ds.date,
    COALESCE(SUM(f.revenue), 0) AS daily_revenue
FROM date_spine ds
LEFT JOIN fact_transactions f ON ds.date = f.transaction_date
WHERE ds.date BETWEEN '2024-01-01' AND '2024-12-31'
GROUP BY ds.date;

-- Result: every day shows a number (0 or actual revenue)
-- Days with revenue=0 could be:
--   (a) Sunday (store closed — genuine zero)
--   (b) Pipeline failed — data not yet loaded
--   (c) Actual slow day
-- (b) is a silent data quality issue; indistinguishable from (a) and (c)
```

**Detection query / invariant:**
```sql
-- Cross-check zero-revenue days against pipeline execution log
SELECT
    fs.date,
    fs.daily_revenue,
    pl.status AS pipeline_status,
    pl.rows_loaded
FROM (
    SELECT date, COALESCE(SUM(revenue), 0) AS daily_revenue
    FROM date_spine LEFT JOIN fact_transactions ON date = transaction_date
    GROUP BY date
) fs
JOIN pipeline_execution_log pl ON fs.date = pl.run_date
WHERE fs.daily_revenue = 0
  AND pl.status IN ('failed', 'skipped', 'no_data_loaded')
ORDER BY fs.date;
-- Matches here = pipeline-failure zeros masquerading as business zeros

-- Pattern: add a data_status column instead of coalescing to 0
-- Values: 'loaded', 'pipeline_failed', 'no_source_data', 'genuine_zero'
```

**Real-world consequence:**
A holiday calendar is built from "historically observed zero-revenue days" in the date spine
output. Three pipeline failure days are included as "holidays." The holiday staffing model
underestimates demand on those days. Customers experience service delays on what the model
predicted were low-demand days.

---

### 7. Pre-Aggregated Summary Used as a Denominator for Rate Calculation

**What it looks like:**
A daily active users (DAU) count is stored in a pre-aggregated summary table. A conversion rate
is calculated as `transactions / dau`. Both tables are filtered to the same date range and joined.

**What actually happens:**
DAU is pre-aggregated at a different grain than transactions (e.g., DAU is deduplicated across
the day; transactions include all events). When joined and used as a denominator, the DAU row
inflates if the JOIN is not cardinality-controlled, or DAU is summed when it should be averaged,
producing a denominator that is wrong for a rate calculation.

**Why it's insidious:**
Both source aggregations are individually correct. The rate calculation formula looks standard.
The error is in how the two aggregations are combined — and different BI tools handle this
differently, producing different (all wrong) answers from the same underlying query.

**Example:**
```sql
-- daily_active_users: date, dau_count (1 row per day — deduplicated unique users)
-- fact_transactions: date, user_id, transaction_id (multiple rows per user per day)

-- Wrong: SUM(dau_count) inflates denominator if joined on date with transactions
SELECT
    SUM(ft.transaction_count) AS total_transactions,
    SUM(dau.dau_count)       AS total_active_users,    -- wrong if dau fan-out exists
    SUM(ft.transaction_count) / NULLIF(SUM(dau.dau_count), 0) AS conversion_rate
FROM (SELECT date, COUNT(*) AS transaction_count FROM fact_transactions GROUP BY date) ft
JOIN daily_active_users dau ON ft.date = dau.date;
-- If dates have multiple rows in the join for any reason, dau_count inflates
```

**Detection query / invariant:**
```sql
-- Validate that the DAU join is 1:1 (one DAU row per date per region)
SELECT
    date,
    COUNT(*) AS dau_rows_per_date
FROM daily_active_users
GROUP BY date
HAVING COUNT(*) > 1;
-- Non-zero = dau join is not 1:1, rate denominators will be inflated

-- Correct pattern: compute rate as window function or explicit subquery, not via join
SELECT
    date,
    transactions,
    dau,
    1.0 * transactions / NULLIF(dau, 0) AS conversion_rate
FROM (
    SELECT
        t.date,
        COUNT(t.transaction_id) AS transactions,
        MAX(d.dau_count) AS dau        -- MAX not SUM to prevent inflation
    FROM fact_transactions t
    JOIN daily_active_users d ON t.date = d.date
    GROUP BY t.date
);
```

**Real-world consequence:**
Product conversion rate is reported as 4.2%. Executive team benchmarks this against industry
(typically 2–3% for e-commerce) and concludes the product is performing excellently. Actual
conversion is 1.8% — the dau denominator was inflated by a one-to-many join artifact. Growth
investment decisions are based on a false competitive position.

---

### 8. Hierarchical Rollup Inconsistency — Leaf Nodes Sum to More Than Root

**What it looks like:**
A product hierarchy has Departments → Categories → Products. Fact revenue is stored at the
product level. Dashboard aggregates at each level of the hierarchy by summing revenue.

**What actually happens:**
Some products are assigned to multiple categories (a design flaw or ETL error). Revenue for
those products is summed under each category they belong to. The sum of all category revenues
exceeds the sum of all product revenues, and the sum of department revenues exceeds the actual
company revenue. Each level of the rollup is correct for its own level but inconsistent with
adjacent levels.

**Why it's insidious:**
Each individual level of aggregation is internally consistent. The discrepancy only appears
when comparing levels — which most reports don't do. The drill-down from Department to Category
to Product shows numbers that don't add up, but this is usually attributed to "rounding" or
"different filters."

**Example:**
```sql
-- Product 501 appears in both 'Electronics' and 'Smart Devices' categories (overlap)
-- Product 501 revenue = $100,000

-- Category-level rollup:
-- Electronics: $500,000 (includes $100K from P501)
-- Smart Devices: $300,000 (includes $100K from P501)
-- Total (sum of categories): $800,000

-- Department-level rollup:
-- Technology: $650,000 (de-duped across categories correctly)

-- Category sum ($800K) > Department total ($650K) — hierarchy is inconsistent
```

**Detection query / invariant:**
```sql
-- Check products assigned to multiple categories
SELECT product_key, COUNT(DISTINCT category_key) AS category_count
FROM product_category_bridge
GROUP BY product_key
HAVING COUNT(DISTINCT category_key) > 1;

-- Compare category-sum revenue to department-level revenue
WITH category_rev AS (
    SELECT dept_key, SUM(rev) AS cat_sum
    FROM (
        SELECT dcat.dept_key, SUM(fs.revenue) AS rev
        FROM fact_sales fs
        JOIN dim_category dcat ON fs.category_key = dcat.category_key
        GROUP BY dcat.dept_key
    ) GROUP BY dept_key
),
dept_rev AS (
    SELECT dept_key, SUM(revenue) AS dept_sum
    FROM fact_sales fs
    JOIN dim_category dc ON fs.category_key = dc.category_key
    GROUP BY dc.dept_key
)
SELECT cr.dept_key, cr.cat_sum, dr.dept_sum, cr.cat_sum - dr.dept_sum AS discrepancy
FROM category_rev cr JOIN dept_rev dr ON cr.dept_key = dr.dept_key
WHERE ABS(cr.cat_sum - dr.dept_sum) > 100;
```

**Real-world consequence:**
A merchandising report shows total category revenue ($800K) higher than department revenue
($650K) in a drill-down. Category managers believe they are outperforming department targets.
The discrepancy is due to product hierarchy overlap — not actual over-performance. Budget
allocations favour the "high-performing" overlapping categories.
