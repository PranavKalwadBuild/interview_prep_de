<!-- Part of Data_modelling: Silent Errors — Fact Table Silent Errors -->

# Silent Errors — Fact Table Silent Errors

Fact table errors are particularly dangerous because they live at the measurement layer. A corrupted
dimension returns wrong attributes — a corrupted fact corrupts the actual numeric measures that
drive business decisions. Every pattern below passes schema validation, loads without error, and
produces results that look numerically reasonable.

---

### 1. Additive vs. Semi-Additive Confusion (Balance Summed Across Time)

**What it looks like:**
An account balance is stored as a measure in a periodic snapshot fact table. BI reports aggregate
it with `SUM()` — the same way they aggregate revenue, which is fully additive.

**What actually happens:**
Account balance is semi-additive: it can be summed across accounts (different entities at the same
point in time) but NOT across time periods. `SUM(balance)` over 30 daily snapshots for one account
gives 30× the actual balance, not the accumulated balance.

**Why it's insidious:**
No schema constraint differentiates additive from semi-additive measures. `SUM()` is syntactically
valid. The inflated number looks large but potentially plausible.

**Example:**
```sql
-- Periodic snapshot: daily account balance
-- fact_account_snapshot: account_key, snapshot_date, balance

-- Wrong (sums balance across all 30 days of June for each account)
SELECT
    account_key,
    SUM(balance) AS total_balance    -- WRONG: 30 * actual balance for a monthly report
FROM fact_account_snapshot
WHERE snapshot_date BETWEEN '2024-06-01' AND '2024-06-30'
GROUP BY account_key;

-- Correct: use LAST_VALUE or filter to end-of-period
SELECT account_key, balance AS eom_balance
FROM fact_account_snapshot
WHERE snapshot_date = '2024-06-30';

-- Or for AVG daily balance (deposit interest calculation):
SELECT account_key, AVG(balance) AS avg_daily_balance
FROM fact_account_snapshot
WHERE snapshot_date BETWEEN '2024-06-01' AND '2024-06-30'
GROUP BY account_key;
```

**Detection query / invariant:**
```sql
-- Check if balance SUM is suspiciously high relative to MAX
SELECT
    account_key,
    SUM(balance)          AS sum_balance,
    MAX(balance)          AS max_balance,
    COUNT(snapshot_date)  AS snapshot_count,
    SUM(balance) / NULLIF(MAX(balance), 0) AS sum_to_max_ratio
FROM fact_account_snapshot
WHERE snapshot_date BETWEEN '2024-06-01' AND '2024-06-30'
GROUP BY account_key
HAVING SUM(balance) / NULLIF(MAX(balance), 0) > 5;
-- Ratio close to snapshot_count = semi-additive measure being summed across time
```

**Real-world consequence:**
Total deposits under management reported to regulators are overstated by 30× because the monthly
report sums 30 daily snapshots. An emergency audit is triggered.

---

### 2. Factless Fact Double-Counting in Combined Queries

**What it looks like:**
A factless fact table records enrollment events (students enrolled in courses, customers enrolled in
promotions). A second fact table records transactions. A combined query joins both.

**What actually happens:**
Each enrollment row fans out against each transaction row for the same customer. If a customer
enrolled in 3 promotions and made 5 transactions, the combined result has 15 rows for that
customer. Aggregations are inflated by the cross-product.

**Why it's insidious:**
Each individual table is correct. The JOIN logic is structurally valid. The error only manifests in
the combined aggregation — which looks like a perfectly ordinary multi-table query.

**Example:**
```sql
-- factless_promotion_enrollment: customer_key, promotion_key (1 row per enrollment)
-- fact_transactions: customer_key, amount (1 row per transaction)

-- A customer has 3 active promotions and 5 transactions
-- The following gives 15 rows for that customer:
SELECT
    fpe.customer_key,
    fpe.promotion_key,
    SUM(ft.amount) AS revenue   -- 5 transactions * 3 enrollments = 5 amounts each counted 3x
FROM factless_promotion_enrollment fpe
JOIN fact_transactions ft ON fpe.customer_key = ft.customer_key
GROUP BY fpe.customer_key, fpe.promotion_key;
```

**Detection query / invariant:**
```sql
-- Compare total from combined query vs direct fact total
SELECT SUM(amount) AS direct_total FROM fact_transactions;

SELECT SUM(ft.amount) AS combined_total
FROM factless_promotion_enrollment fpe
JOIN fact_transactions ft ON fpe.customer_key = ft.customer_key;

-- If combined_total > direct_total, factless fact is inflating transaction measures
-- Fix: aggregate the factless fact first, then join on existence (NOT measures)
SELECT customer_key, COUNT(promotion_key) AS active_promotions
FROM factless_promotion_enrollment GROUP BY customer_key;
-- Then join this aggregated result to transaction fact
```

**Real-world consequence:**
A "promotions impact" dashboard shows revenue for customers enrolled in promotions as 3× higher
than revenue for non-enrolled customers. Promotion budget is tripled based on this finding.
The actual lift is 15%.

---

### 3. NULL Foreign Key in Fact Table — Silent Row Drop vs. Silent NULL Attribution

**What it looks like:**
A fact row has a NULL value for a dimension foreign key (e.g., `channel_key IS NULL` for a
transaction with an unknown acquisition channel). The query joins to the dimension table.

**What actually happens:**
- With `INNER JOIN`: the fact row is silently dropped. Revenue for NULL-channel transactions
  disappears from reports entirely.
- With `LEFT JOIN`: the fact row appears with NULL dimension attributes, which may be excluded
  by BI filters, coalesced to a default, or accidentally included in "unattributed" totals.
Both cases are wrong in different ways and produce different answers depending on join type.

**Why it's insidious:**
The data loads correctly. No schema violation. The query runs and returns rows. The difference
between INNER and LEFT JOIN is invisible until someone notices that grand totals don't match.

**Example:**
```sql
-- fact_sales has channel_key = NULL for 12% of rows (direct sales with unknown source)

-- INNER JOIN silently drops 12% of revenue
SELECT
    dc.channel_name,
    SUM(fs.revenue) AS revenue
FROM fact_sales fs
INNER JOIN dim_channel dc ON fs.channel_key = dc.channel_key   -- drops NULL channel rows
GROUP BY dc.channel_name;

-- LEFT JOIN includes them but attributes NULL channel as its own "group"
SELECT dc.channel_name, SUM(fs.revenue)
FROM fact_sales fs
LEFT JOIN dim_channel dc ON fs.channel_key = dc.channel_key
GROUP BY dc.channel_name;
-- channel_name = NULL row exists with significant revenue — may be filtered out in BI tool
```

**Detection query / invariant:**
```sql
-- Baseline: total revenue without any dimension join
SELECT SUM(revenue) AS total FROM fact_sales;

-- Revenue covered by INNER JOIN
SELECT SUM(fs.revenue) AS joined_total
FROM fact_sales fs INNER JOIN dim_channel dc ON fs.channel_key = dc.channel_key;

-- Revenue lost to INNER JOIN
SELECT (SELECT SUM(revenue) FROM fact_sales) -
       (SELECT SUM(fs.revenue) FROM fact_sales fs
        INNER JOIN dim_channel dc ON fs.channel_key = dc.channel_key)
AS silently_dropped_revenue;

-- Also: explicit NULL FK audit
SELECT COUNT(*) AS null_fk_rows, SUM(revenue) AS null_fk_revenue
FROM fact_sales WHERE channel_key IS NULL;
```

**Real-world consequence:**
Channel attribution report shows digital, retail, and wholesale. 12% of revenue with no channel
tag disappears. Digital is assumed to be underfunded; budget is reallocated. The missing 12% was
largely in-store direct sales with system entry issues — the real gap was data entry, not channel.

---

### 4. Date Dimension FK Mismatch — Timezone-Induced Grain Shift

**What it looks like:**
A fact table stores `event_timestamp TIMESTAMP (UTC)`. It joins to a date dimension on
`CAST(event_timestamp AS DATE)`. The BI layer displays dates in local timezone (EST/PST).

**What actually happens:**
An event at `2024-03-15 02:30 UTC` casts to `2024-03-15` in UTC. But in EST (UTC-5), it is
`2024-03-14 21:30`. The fact table joins to `2024-03-15` in the date dimension, but the business
considers this event as occurring on `2024-03-14`. End-of-day reports for March 14 are understated;
March 15 is overstated by the count of events in the UTC midnight-to-5am window.

**Why it's insidious:**
The CAST is technically correct for UTC. The date dimension is correctly structured. The join is
valid. The error is invisible without timezone awareness — and the magnitude is small (only
events in the UTC 00:00–05:00 window), making it look like noise.

**Example:**
```sql
-- Fact table in UTC, date dimension in local time
SELECT
    dd.full_date,
    COUNT(fs.event_id) AS daily_events,
    SUM(fs.revenue)    AS daily_revenue
FROM fact_events fs
JOIN dim_date dd
  ON CAST(fs.event_timestamp AS DATE) = dd.full_date   -- UTC date, not local date
GROUP BY dd.full_date
ORDER BY dd.full_date;
-- Events at 00:30 UTC on Mar 15 appear in Mar 15 report, not Mar 14 (EST)
```

**Detection query / invariant:**
```sql
-- Check event volume in the UTC midnight-to-timezone-offset window
SELECT
    CAST(event_timestamp AS DATE)                              AS utc_date,
    CAST(CONVERT_TIMEZONE('UTC', 'America/New_York', event_timestamp) AS DATE) AS est_date,
    COUNT(*) AS event_count,
    SUM(revenue) AS revenue
FROM fact_events
WHERE HOUR(event_timestamp) < 5   -- UTC hours that fall in prior day in EST
GROUP BY 1, 2
HAVING utc_date <> est_date;      -- Rows here are date-misattributed
```

**Real-world consequence:**
End-of-day flash reports sent to sales leadership at 5 PM EST show numbers that don't reconcile
to the next morning's full-day totals. The discrepancy is blamed on pipeline lag when it is
actually a systematic timezone attribution error.

---

### 5. Measure Stored at Wrong Grain (Header-Level Measure in Line-Level Fact)

**What it looks like:**
A discount amount is negotiated at the order header level. The fact table is at order line level
(one row per product in the order). The ETL copies the header discount to every line row.

**What actually happens:**
An order has a $100 discount and 5 line items. Each line row carries $100 discount.
`SUM(discount)` = $500 for a single order that should show $100. Every order is overstated by
N× where N is the number of line items.

**Why it's insidious:**
The ETL logic is "copy header columns to all child rows" — a very common pattern for denormalization.
The discount column has valid values. No NULL, no type error. The inflation is only visible when
comparing discount totals to source system order-header reports.

**Example:**
```sql
-- Order 9001: total discount = $100, 5 line items
-- fact_order_lines after ETL:
-- line 1: order_id=9001, revenue=200, discount=100  ← discount copied from header
-- line 2: order_id=9001, revenue=150, discount=100
-- ...
-- line 5: order_id=9001, revenue=80,  discount=100

SELECT order_id, SUM(revenue) AS total_revenue, SUM(discount) AS total_discount
FROM fact_order_lines
GROUP BY order_id;
-- order_id=9001: revenue=$730 (correct), discount=$500 (WRONG — should be $100)
```

**Detection query / invariant:**
```sql
-- Compare line-level aggregated discount vs source order-header discount
SELECT
    fol.order_id,
    SUM(fol.discount)          AS line_sum_discount,
    src.order_header_discount  AS header_discount
FROM fact_order_lines fol
JOIN source_order_headers src ON fol.order_id = src.order_id
GROUP BY fol.order_id, src.order_header_discount
HAVING ABS(SUM(fol.discount) - src.order_header_discount) > 0.01
ORDER BY ABS(SUM(fol.discount) - src.order_header_discount) DESC;
```

**Real-world consequence:**
Gross margin analysis overstates discount leakage by the average number of line items per order
(typically 3–8×). A pricing review concludes that the discount policy is too aggressive. Discount
caps are tightened, reducing sales conversion — the real discount leakage was within acceptable bounds.

---

### 6. Periodic Snapshot Stale Carry-Forward Bug

**What it looks like:**
A periodic snapshot carries forward the last known value for inactive accounts using
`COALESCE(current_balance, LAG(balance) OVER (...))`. Inactive accounts should maintain their
last known balance rather than showing NULL.

**What actually happens:**
If the lag value is also NULL (the account had no prior snapshot that period — e.g., a newly
opened account with no prior period), `COALESCE(NULL, NULL)` returns NULL. Downstream logic
may then treat NULL as 0. Total balance reports show sudden drops when new accounts with no
prior history are introduced — the carry-forward logic silently assigns 0 instead of omitting
the period.

**Why it's insidious:**
The COALESCE is correct for established accounts. Only new accounts (no prior period row) expose
the bug. The drop in total balance looks like a business event — accounts closing, withdrawals —
not a pipeline defect.

**Example:**
```sql
-- Snapshot generation
INSERT INTO fact_account_snapshot (account_key, snapshot_date, balance)
SELECT
    account_key,
    '2024-07-31',
    COALESCE(
        current_month_balance,
        LAG(balance) OVER (PARTITION BY account_key ORDER BY snapshot_date)
    ) AS balance
FROM monthly_account_extract;

-- New account opened in July with no June snapshot:
-- current_month_balance = NULL (not yet calculated), LAG = NULL (no prior row)
-- COALESCE(NULL, NULL) = NULL → downstream COALESCE(balance, 0) = 0
-- Total balance drops by all new-account balances
```

**Detection query / invariant:**
```sql
-- Find snapshot rows where balance = 0 but account is active in source system
SELECT
    fas.account_key,
    fas.snapshot_date,
    fas.balance,
    src.actual_balance
FROM fact_account_snapshot fas
JOIN source_accounts src ON fas.account_key = src.account_key
  AND fas.snapshot_date = src.as_of_date
WHERE fas.balance = 0 AND src.actual_balance <> 0;
```

**Real-world consequence:**
Monthly total-assets-under-management report drops by $50M at the end of a high-growth month.
Risk team escalates to CFO as a potential data breach or large unexpected withdrawal. Root cause
is the carry-forward NULL bug on new accounts, discovered only after 3 hours of investigation.

---

### 7. Pre-Aggregated Fact Used for Drill-Down Analysis

**What it looks like:**
A daily revenue summary fact table is built for performance. BI tool users create reports against
it, selecting date, region, and revenue. An analyst then drills down to hourly breakdown by
dividing daily revenue by 24.

**What actually happens:**
The daily total divided by 24 assumes perfectly uniform revenue distribution throughout the day —
which is never true. Hourly "breakdown" is silently fabricated arithmetic, not real data. Reports
showing "peak hours" are based on this division, not actual hourly events.

**Why it's insidious:**
The daily total is correct. The hourly derivation is arithmetically valid SQL. No error is thrown.
The "hourly data" looks plausible because it follows the same daily trend.

**Example:**
```sql
-- Pre-aggregated daily fact
-- fact_daily_revenue: date, region, daily_revenue

-- Analyst creates an "hourly" view:
SELECT
    date,
    hour_of_day,
    daily_revenue / 24.0 AS hourly_revenue   -- WRONG: fabricated uniform distribution
FROM fact_daily_revenue
CROSS JOIN (SELECT SEQ4() AS hour_of_day FROM TABLE(GENERATOR(ROWCOUNT => 24))) hours;
```

**Detection query / invariant:**
```sql
-- Compare against actual transaction-level hourly aggregation
SELECT HOUR(event_timestamp) AS hr, SUM(revenue) AS real_hourly_revenue
FROM fact_transactions
WHERE CAST(event_timestamp AS DATE) = '2024-07-01'
GROUP BY 1;

-- Compare this to daily_revenue / 24 for the same date
-- If actual hourly distribution has peaks >2× average, the uniform division is misleading
```

**Real-world consequence:**
Staffing model is built on "hourly revenue" derived from daily total ÷ 24. Lunch-hour and
post-work peaks are invisible. Customer service is understaffed during real peak hours and
overstaffed during low-traffic periods.

---

### 8. Accumulating Snapshot — Milestone Date NULL vs. Not-Yet-Reached Ambiguity

**What it looks like:**
An accumulating snapshot fact table tracks order lifecycle milestones: `order_date`,
`warehouse_pick_date`, `ship_date`, `delivery_date`. NULL values represent milestones not yet
reached.

**What actually happens:**
A cancelled order never reaches `ship_date` or `delivery_date` — those columns remain NULL
forever. A delivered order whose `delivery_date` was not captured also has NULL `delivery_date`.
Queries filtering `WHERE delivery_date IS NULL` include both pending and cancelled orders —
two very different business states treated identically.

**Why it's insidious:**
NULL correctly represents "not yet occurred" for pending orders. It accidentally also represents
"never occurred" for cancellations and "data not captured" for system failures. All three cases
look the same in the fact table.

**Example:**
```sql
-- Three orders, same NULL delivery_date:
-- order_id=1: pending, still in transit
-- order_id=2: cancelled before shipment, delivery will never happen
-- order_id=3: delivered, but delivery confirmation event lost due to system outage

SELECT COUNT(*) AS orders_in_transit
FROM fact_order_lifecycle
WHERE ship_date IS NOT NULL AND delivery_date IS NULL;
-- Counts pending + cancelled (never shipped, ship_date also NULL in cancel case)
-- But if cancel flag is not enforced, ship_date may be NULL for both true in-transit and cancelled
```

**Detection query / invariant:**
```sql
-- Cross-check order status flags against milestone NULL patterns
SELECT
    order_status,
    COUNT(*) AS orders,
    SUM(CASE WHEN ship_date IS NULL THEN 1 ELSE 0 END) AS no_ship_date,
    SUM(CASE WHEN delivery_date IS NULL THEN 1 ELSE 0 END) AS no_delivery_date
FROM fact_order_lifecycle
GROUP BY order_status;
-- 'cancelled' with no_ship_date > 0 = fine
-- 'delivered' with no_delivery_date > 0 = silent data capture failure
```

**Real-world consequence:**
Logistics SLA dashboard shows 2,000 orders "in transit for >10 days" based on
`ship_date IS NOT NULL AND delivery_date IS NULL AND DATEDIFF(days, ship_date, TODAY) > 10`.
Operations team investigates carrier performance. Half those 2,000 orders were delivered but the
confirmation event was lost. Carrier receives unwarranted SLA penalties.
