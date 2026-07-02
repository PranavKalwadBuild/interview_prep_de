<!-- data-modelling-patterns: Anti-Patterns with Autopsy -->

# Anti-Patterns with Autopsy

## Anti-Pattern 1: The God Fact Table

**What it is**: A single fact table that combines multiple business processes at different grains — e.g., a table that has one row per order line but also includes columns for the order header's shipping method, the customer's lifetime order count, the warehouse's current inventory for the ordered SKU, and the marketing campaign that drove the session.

**Why it gets built**: It starts with a legitimate convenience request — "can you just add the customer's total order count to the order line table so I don't have to join?" The data engineer adds the column. Over 18 months, 40 more "just add" requests create a 250-column table.

**How it fails at scale**:

1. **Grain ambiguity**: The `lifetime_order_count` is a customer-level attribute. When you `SUM(lifetime_order_count) GROUP BY product`, you sum the customer's lifetime count for every product they bought — wildly inflated numbers that look like revenue metrics.

2. **Stale denormalized columns**: `warehouse_inventory_qty` was correct when loaded. By the time analysts use it, the inventory has changed. There is no clear owner of this column's refresh SLA.

3. **Storage explosion**: A 1B-row order line fact table where 30 columns are denormalized customer attributes means the customer data is physically replicated 1B times. In columnar storage this is less severe (columns compress independently), but it is still wasteful and creates maintenance burden on every customer attribute change.

4. **SCD confusion**: If `customer_loyalty_tier` is denormalized into the God Fact and the customer's tier changes, what do you do? Update all 500 past rows? That corrupts the historical record. Leave it? Now the column means "current tier" for some rows and "tier at order time" for others — undocumented and inconsistent.

**The autopsy**: The query "revenue by customer segment" starts returning doubled numbers in Q3. Investigation reveals that customers who placed multiple orders have their `customer_segment` value updated by the nightly refresh, but the fact table was loaded with the segment value at order time — inconsistently. Some rows have the order-time segment; others were overwritten by subsequent refreshes. The fix requires rebuilding the entire fact table with a proper SCD Type 2 join to the customer dimension.

**The fix**: Never put dimension attributes into the fact table. Join at query time or build a pre-computed OBT as a separate layer built intentionally from properly governed dimensions.

## Anti-Pattern 2: Over-Normalized Analytics Models (The 12-Table Join Problem)

**What it is**: Applying OLTP normalization principles to analytics models. A query to answer "revenue by product category" requires joining through 12 tables because every attribute is in its own normalized table.

**How it fails**:

```sql
-- This query should be 2 lines. It takes 47 lines because normalization was applied incorrectly.
SELECT
    pc.category_name,
    SUM(oi.quantity * oi.unit_price) AS revenue
FROM order_items oi
JOIN orders o ON oi.order_id = o.id
JOIN customers c ON o.customer_id = c.id
JOIN customer_profiles cp ON c.id = cp.customer_id
JOIN product_variants pv ON oi.variant_id = pv.id
JOIN products p ON pv.product_id = p.id
JOIN product_subcategories psc ON p.subcategory_id = psc.id
JOIN product_categories pc ON psc.category_id = pc.id
JOIN product_category_hierarchies pch ON pc.id = pch.category_id
JOIN category_display_names cdn ON pch.display_id = cdn.id
JOIN ...
```

In a columnar warehouse, each join is a hash join requiring full scans of both sides if proper clustering is absent. 12 joins on large tables means 12 full scans. Query time: minutes to hours.

**The autopsy**: The analytics engineer built the warehouse schema by running `pg_dump` on the production PostgreSQL database and loading it into Snowflake. The OLTP schema had 3NF normalization appropriate for transactional consistency. In the analytics context, the 3NF schema creates a join explosion that makes simple reporting impossible.

**The fix**: Dimension tables in analytics must be intentionally denormalized. The `product_category` hierarchy should be a single row in `dim_product` with `category_name`, `subcategory_name`, `department_name` all present — even if this "violates" normalization. Analytics models are read-many, write-once. Normalization's purpose (update anomaly prevention) does not apply to the analytics layer.

## Anti-Pattern 3: Missing SCD Handling (Silent Data Corruption)

**What it is**: Dimensions that change over time are treated as Type 1 (overwrite) when the business actually needs Type 2 (history). The corruption is silent — queries return wrong answers but no error is thrown.

**Scenario**: The `dim_salesperson` table has a `region` column. Salespeople are reassigned between regions quarterly. The table is loaded with Type 1 (current values overwrite). An analyst queries "revenue by salesperson region for Q1." The query joins to `dim_salesperson` and gets the current region for each salesperson — not the Q1 region. A salesperson who was reassigned from East to West in April now appears to have generated all their Q1 revenue in West. The East region is undercounted; West is overcounted.

**Why it's silent**: The query executes successfully. The numbers sum correctly. The regional totals add up to total revenue. Nothing looks wrong unless you independently validate against a known-correct Q1 regional figure.

**The autopsy**: The corrupted regional report is included in a board presentation. The VP of East Sales disputes the numbers — their region appears far below Q1 actuals. Investigation reveals the SCD issue. Rebuilding requires either (a) sourcing historical region assignments from the CRM's change log (if it exists) or (b) accepting that Q1 historical data is irreparably incorrect.

**The fix**: Before modeling any dimension, answer: "If this attribute changes, do we ever need to know its historical value in the context of a past fact?" If yes, it requires Type 2. The engineering cost of Type 2 is real but recoverable. The cost of discovering missing SCD handling after 18 months of corrupted reports is not.

## Anti-Pattern 4: Sparse Fact Tables

**What it is**: A single fact table that attempts to represent multiple business processes with incompatible grains, resulting in a table where most columns are NULL for most rows.

**Example**: A `fact_financial_events` table with 150 columns that represents loan originations, payments, fee accruals, charge-offs, and rate changes — all as different row types. A loan origination row populates `origination_amount`, `origination_date`, `ltv_ratio`, `fico_score` but has NULLs in `payment_amount`, `accrual_type`, `charge_off_reason`. A payment row populates `payment_amount` but has NULLs in all origination columns.

**How it fails**:

1. **Storage waste**: In columnar storage, NULL columns are compressed very efficiently — but not to zero. At 1B rows with 90% NULL density, you are paying for 100M non-NULL values spread across 150 columns, with encoding overhead for 900M NULLs.

2. **Query errors**: `SUM(payment_amount)` on the table returns the correct sum — but `AVG(payment_amount)` excludes NULLs and returns the correct average only if analysts remember that most rows are not payments. New analysts will write `SELECT AVG(payment_amount) FROM fact_financial_events` and get a result that silently excludes 85% of rows.

3. **Impossible constraints**: You cannot enforce `NOT NULL` on `payment_amount` because origination rows need it to be NULL. You lose the ability to catch data quality issues via database constraints.

**The fix**: One fact table per business process. `fact_loan_origination`, `fact_payment`, `fact_fee_accrual`, `fact_charge_off` — each with the columns appropriate to their grain and process. A unified `fact_financial_events` OBT is acceptable as a final reporting layer built from the properly structured per-process facts, but only if built intentionally with documented NULL semantics.

## Anti-Pattern 5: Premature Aggregation (Losing Grain Before You Need It)

**What it is**: Aggregating data to a summary grain during the ELT process before storing it in the warehouse, discarding the raw grain.

**Scenario**: The data team builds a daily pipeline that loads `total_orders` and `total_revenue` by day and product category into a summary table. Three months later, a product manager asks: "How many distinct customers bought in each category last month?" This question cannot be answered from the summary table — distinct customer count requires the individual order lines to determine uniqueness. The raw order lines were never loaded.

**A more insidious form**: Loading inventory positions as the daily opening balance only, discarding the individual movement records. Six months later: "Why did inventory for SKU XYZ drop by 500 units on March 14th?" No movement detail exists to answer this.

**The fix**: Always store the finest available grain in the warehouse. Pre-aggregated tables are supplemental query acceleration layers — they are never a substitute for the atomic fact. The storage cost of raw grain data in columnar warehouses is dramatically lower than in row-oriented systems (2–5x compression is typical). The cost of not having granular data when a question arrives is unbounded.
