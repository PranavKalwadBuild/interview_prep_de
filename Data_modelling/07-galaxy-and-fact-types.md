<!-- Part of data-modelling-patterns: Galaxy Schema, all 4 Fact Table Types -->

# Galaxy Schema and Fact Table Types

---

## 9. Galaxy Schema (Constellation)

**What it solves:** Multiple fact tables sharing conformed dimension tables. The natural shape of a mature data warehouse.

> **Keywords to spot:** "multiple fact tables", "shared dimensions", "enterprise data warehouse", "conformed dimensions", "cross-subject-area analysis"

**Business Context:**
- **Retail:** `fact_sales` and `fact_inventory` both reference `dim_product`, `dim_store`, `dim_date`
- **Fintech:** `fact_transactions` and `fact_account_balances` both reference `dim_account`, `dim_date`
- **SaaS:** `fact_user_events` and `fact_subscriptions` both reference `dim_user`, `dim_date`, `dim_plan`

**Schema diagram:**

```
dim_date ────< fact_sales >──── dim_product ────< fact_inventory
                  |                                      |
              dim_store ─────────────────────────────────┘
              dim_customer
```

**DDL — two fact tables sharing conformed dimensions:**

```sql
-- Shared dimensions (already defined in Section 7)
-- dim_date, dim_product, dim_store

create table fact_sales (
    sales_sk        bigint primary key,
    order_date_sk   int     references dim_date(date_sk),
    product_sk      bigint  references dim_product(product_sk),
    store_sk        bigint  references dim_store(store_sk),
    customer_sk     bigint  references dim_customer(customer_sk),
    quantity_sold   int,
    revenue         decimal(12,2)
);

create table fact_inventory (
    inventory_sk    bigint primary key,
    snapshot_date_sk int    references dim_date(date_sk),
    product_sk      bigint  references dim_product(product_sk),
    store_sk        bigint  references dim_store(store_sk),
    -- grain: one row per product per store per day
    units_on_hand   int,
    units_on_order  int,
    reorder_flag    boolean
);
```

**Cross-fact analysis:**

The power of conformed dimensions is that you can join across fact tables:

```sql
-- Sell-through rate: how much of inventory was sold?
select
    d.full_date,
    p.product_name,
    s.store_name,
    sum(fs.quantity_sold)           as units_sold,
    avg(fi.units_on_hand)           as avg_inventory,
    sum(fs.quantity_sold) * 1.0
        / nullif(avg(fi.units_on_hand), 0) as sell_through_rate
from fact_sales fs
join fact_inventory fi
    on  fs.product_sk      = fi.product_sk
    and fs.store_sk        = fi.store_sk
    and fs.order_date_sk   = fi.snapshot_date_sk
join dim_date d    on fs.order_date_sk = d.date_sk
join dim_product p on fs.product_sk    = p.product_sk
join dim_store s   on fs.store_sk      = s.store_sk
group by 1, 2, 3;
```

**Gotchas:**
- Cross-fact joins are only safe when the grains are compatible (or you aggregate the finer grain first). Joining `fact_sales` at line-item grain directly to `fact_inventory` at daily-product-store grain without aggregation will inflate counts. See Section 17 on fan-out.
- "Galaxy schema" is just a name for the natural end-state of a data warehouse. You don't design for galaxy from day one — you design each subject area as a star, and the galaxy emerges.

---

## 10. Fact Table Types

---

### 10-A. Transaction Fact

**What it solves:** Records a discrete business event at the moment it happens. The most common fact table type.

> **Keywords to spot:** "each transaction", "event log", "append-only", "point in time", "never updated after load"

**When to use:** When the business process produces discrete events — purchases, clicks, payments, logins, shipments.

**Business scenario:** Each row is one payment processed. A payment is an event that happens once and doesn't change (you can void it, but voiding is a new event).

```sql
create table fact_payments (
    payment_sk          bigint primary key,
    payment_date_sk     int     references dim_date(date_sk),
    account_sk          bigint  references dim_account(account_sk),
    merchant_sk         bigint  references dim_merchant(merchant_sk),
    channel_sk          bigint  references dim_channel(channel_sk),
    -- grain: one row per payment transaction
    payment_id          varchar(50),   -- degenerate dimension
    payment_amount      decimal(12,2),
    currency_code       char(3),
    is_declined         boolean,
    processing_fee      decimal(8,4)
);
```

**What breaks if you use the wrong type:**
- Using a periodic snapshot here would require a row per account per day even on days with no activity — expensive and misleading.
- Using an accumulating snapshot here doesn't make sense — payments don't have a lifecycle with multiple milestone dates.

**Gotchas:**
- Transaction facts are append-only. Once loaded, rows are never updated (corrections come in as new offsetting rows or a separate corrections table).
- The `payment_id` stored directly on the row is a degenerate dimension. Don't create a `dim_payment` with nothing but the ID — that's wasteful.

---

### 10-B. Periodic Snapshot Fact

**What it solves:** Records the state of something at regular, predictable intervals — regardless of whether anything happened in that period.

> **Keywords to spot:** "daily balance", "end-of-month", "weekly inventory", "point-in-time status", "snapshot", "every period has a row"

**When to use:** When you need to track cumulative or status metrics over time — balances, inventory levels, headcount, subscriber counts.

**Business scenario:** Each row is the state of a bank account at end of day. If there were no transactions, a row is still created with the current balance (which equals the prior day balance).

```sql
create table fact_account_daily_snapshot (
    snapshot_sk         bigint primary key,
    snapshot_date_sk    int    references dim_date(date_sk),
    account_sk          bigint references dim_account(account_sk),
    -- grain: one row per account per calendar day
    closing_balance     decimal(15,2),
    available_balance   decimal(15,2),
    transaction_count   int,
    total_credits       decimal(12,2),
    total_debits        decimal(12,2),
    days_since_activity int
);
```

**What breaks if you use the wrong type:**
- Using a transaction fact here means days with no activity have no row. Queries for "what was the balance on 2024-03-15?" need complex last-value logic instead of a simple lookup. Dashboards show gaps instead of flat lines.

**Gotchas:**
- Periodic snapshots are expensive to store — one row per entity per period adds up fast at scale. Partition on the snapshot date and cluster on the entity key.
- Semi-additive measures (like `closing_balance`) cannot be summed across time periods — only across other dimensions. Summing balances across 30 days gives you a meaningless number. Sum across accounts on one day — valid. Average across time periods — valid.
- The "semi-additive" label is important in interviews: know which measures in a periodic snapshot are additive vs semi-additive vs non-additive.

---

### 10-C. Accumulating Snapshot Fact

**What it solves:** Tracks the lifecycle of a long-running business process through multiple milestones. Each row represents one instance of the process, updated as it progresses through stages.

> **Keywords to spot:** "pipeline stages", "lifecycle", "application process", "order fulfillment", "loan process", "end-to-end tracking", "milestone dates", "elapsed time between stages"

**When to use:** When a business process has a defined sequence of steps and you need to measure cycle times, bottlenecks, and completion rates across the entire pipeline.

**Business scenario:** A loan application progresses through: submitted → credit check → approved/rejected → disbursed → closed. Each application gets one row, with date columns for each milestone.

```sql
create table fact_loan_lifecycle (
    loan_sk                 bigint primary key,
    applicant_sk            bigint  references dim_customer(customer_sk),
    product_sk              bigint  references dim_loan_product(product_sk),
    submitted_date_sk       int     references dim_date(date_sk),
    credit_check_date_sk    int     references dim_date(date_sk),   -- nullable
    decision_date_sk        int     references dim_date(date_sk),   -- nullable
    disbursement_date_sk    int     references dim_date(date_sk),   -- nullable
    closed_date_sk          int     references dim_date(date_sk),   -- nullable
    -- grain: one row per loan application
    loan_id                 varchar(50),  -- degenerate dimension
    loan_amount             decimal(15,2),
    current_status          varchar(50),
    days_submitted_to_decision  int,      -- calculated, updated when decision is made
    days_decision_to_disburse   int,      -- calculated, updated when disbursed
    is_approved             boolean,
    rejection_reason        varchar(100)
);
```

**The defining characteristic:** Unlike transaction facts (append-only), accumulating snapshot rows are **updated** as milestones complete. The ETL for this table runs `UPDATE` statements, not just `INSERT`.

**What breaks if you use the wrong type:**
- Using a transaction fact would require multiple rows per loan (one per status change), making cycle time calculations complex and requiring session-like logic to reconstruct the timeline.
- Using a periodic snapshot would create a row per loan per day — most of which are identical. Extremely wasteful and still hard to calculate stage durations.

**Gotchas:**
- The nullable date_sk columns are essential — not every loan reaches every milestone (rejected loans never get a disbursement date). Use -1 to reference the `dim_date` "Unknown" row rather than NULL, if your tool doesn't handle NULL FK gracefully.
- When a milestone date is filled in, **both** the date_sk column and the derived duration column update atomically. Your pipeline logic must handle this correctly.
- This is the least common fact type but the most distinctive in interviews. Mentioning it when discussing pipeline/lifecycle modeling signals strong Kimball knowledge.

---

### 10-D. Factless Fact

**What it solves:** Records that an event occurred, or that a relationship exists, without any numeric measures. Answers "did X happen?" and "what is eligible/enrolled?"

> **Keywords to spot:** "coverage", "eligibility", "enrollment", "attendance", "event occurred", "did the promotion apply", "no measures just participation"

**When to use:** When the event itself is the information — no amount, count, or dollar value is attached.

**Business scenario 1 (event occurred):** Student attendance. Was student X present in class Y on date Z? The fact is the attendance event — there's nothing to measure.

```sql
create table fact_student_attendance (
    attendance_sk   bigint primary key,
    student_sk      bigint  references dim_student(student_sk),
    course_sk       bigint  references dim_course(course_sk),
    date_sk         int     references dim_date(date_sk),
    -- grain: one row per student per class session attended
    -- no measures — presence is the fact
    attendance_status varchar(20)  -- 'present', 'excused', 'unexcused'
);
```

**Business scenario 2 (coverage/eligibility):** What products are eligible for a promotion?

```sql
create table fact_promotion_coverage (
    coverage_sk     bigint primary key,
    promotion_sk    bigint  references dim_promotion(promotion_sk),
    product_sk      bigint  references dim_product(product_sk),
    store_sk        bigint  references dim_store(store_sk),
    effective_date_sk int   references dim_date(date_sk),
    expiry_date_sk    int   references dim_date(date_sk)
    -- grain: one row per promotion-product-store combination during coverage window
    -- no measures — eligibility is the fact
);
```

**How to use it in queries:**

```sql
-- Which promotions had eligible products but no actual sales?
select
    p.promotion_name,
    count(distinct fpc.product_sk) as eligible_products,
    count(distinct fs.product_sk)  as products_sold
from fact_promotion_coverage fpc
join dim_promotion p on fpc.promotion_sk = p.promotion_sk
left join fact_sales fs
    on  fpc.product_sk      = fs.product_sk
    and fpc.store_sk        = fs.store_sk
    and fs.order_date_sk between fpc.effective_date_sk and fpc.expiry_date_sk
group by 1
having count(distinct fs.product_sk) = 0;
```

**What breaks if you use the wrong type:**
- Storing eligibility in a dimension attribute works for simple cases but makes it impossible to answer "which products were eligible on which dates" without complex logic.

**Gotchas:**
- Factless facts often have the same row count as their grain — many rows, no aggregatable numbers. COUNT() is usually the only meaningful aggregation.
- The most common interview mistake is adding a dummy measure column (`event_count int default 1`). This works but is not truly factless. Interviewers who are strict will note the distinction.
