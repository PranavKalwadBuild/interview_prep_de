<!-- Part of data-modelling-patterns: Late Arriving Facts, NULL Handling, Performance -->

# Edge Cases and Performance

---

## 20. Late Arriving Facts

**What it solves:** Handles fact records that arrive after their associated dimension records have already moved forward in time (SCD 2 changes), or fact records that arrive after the period they belong to has already been closed.

> **Keywords to spot:** "late arriving data", "backfill", "out of order", "event arrived late", "dimension already changed", "historical fact load"

**Problem 1: Fact arrives after the dimension version has expired**

Customer C-001 moved from Chicago to New York on 2024-06-01. An order placed on 2024-05-20 arrives in the warehouse on 2024-07-15 (late). At load time, the current `customer_sk` for C-001 points to the New York version.

```sql
-- Wrong: using current customer_sk
insert into fact_sales (customer_sk, ...)
select
    c.customer_sk,   -- this is the New York version (wrong!)
    ...
from staging_late_orders o
join dim_customer c on c.customer_id = o.customer_id and c.is_current = true;

-- Correct: look up the customer version that was active at event time
insert into fact_sales (customer_sk, ...)
select
    c.customer_sk,   -- this finds the Chicago version (correct!)
    ...
from staging_late_orders o
join dim_customer c
    on  c.customer_id      = o.customer_id
    and o.order_date between c.effective_from and coalesce(c.effective_to, '9999-12-31');
```

**Problem 2: Late-arriving dimension (dimension arrives after the fact)**

A product is loaded into the warehouse on day 1. The product's dimension attributes (name, category) arrive on day 3. Facts loaded on day 1 and 2 have a FK to a placeholder "Unknown" dimension row.

**Solution — Unknown dimension row + backfill:**

```sql
-- Step 1: On first encounter of an unknown product, insert a placeholder
insert into dim_product (product_sk, product_id, product_name, category)
values (nextval('dim_product_sk_seq'), 'P-999', 'Unknown Product', 'Unknown');

-- Facts load with this placeholder SK

-- Step 2: When the real attributes arrive, update the placeholder (SCD 1 on Unknown rows)
update dim_product
set
    product_name = 'Wireless Headphones',
    category     = 'Electronics'
where product_id = 'P-999'
  and product_name = 'Unknown Product';
-- The fact table FKs don't need to change — they already point to the right SK
```

**Problem 3: Late-arriving facts for periodic snapshots (closed periods)**

A transaction from November arrives in December after the November snapshot has been finalized.

**Options:**

```sql
-- Option A: Restate the November snapshot (most accurate, most expensive)
-- Re-run the entire November snapshot job with the late record included

-- Option B: Apply the late fact to the earliest open period (pragmatic)
-- Add the transaction to December's snapshot instead

-- Option C: Create a "correction" or "adjustment" row
insert into fact_account_daily_snapshot (
    snapshot_sk, snapshot_date_sk, account_sk,
    closing_balance, transaction_count, is_correction, correction_reason
)
values (
    nextval('snapshot_sk_seq'),
    20241201,       -- correction applied to current period
    ...,
    ...,
    1,
    true,
    'Late-arriving November transaction'
);
```

**Gotchas:**
- Late-arriving facts are the rule, not the exception, in production systems. Design for them from day one.
- Document your late-arrival policy (how many days late you accept, what happens after that cutoff).
- Accumulating snapshot facts (Section 10-C) are particularly vulnerable: when a milestone date arrives late, you need to UPDATE the existing row, not insert a new one.

---

## 21. NULL Handling in Dimensional Models

**What it solves:** Prevents NULLs in fact table FK columns from breaking joins and aggregations, and establishes a consistent vocabulary for missing/unknown/not-applicable data.

> **Keywords to spot:** "null foreign key", "missing dimension", "unknown customer", "not applicable", "null in fact table", "surrogate key for nulls"

### Why NULLs in FK columns are dangerous

```sql
-- fact table has NULLs in product_sk for transactions with no product
select
    p.category,
    sum(f.revenue)
from fact_transactions f
left join dim_product p on f.product_sk = p.product_sk
group by p.category;
-- Rows where product_sk IS NULL will have category = NULL
-- They get lumped under NULL in GROUP BY — often lost in reports or charts
```

### The -1 surrogate key pattern

Insert a special "Unknown" or "Not Applicable" row in every dimension with `_sk = -1` (or another sentinel value). Fact table FKs that would otherwise be NULL point to this row instead.

```sql
-- Insert unknown rows in every dimension
insert into dim_customer (customer_sk, customer_id, full_name, city, segment)
values (-1, 'UNKNOWN', 'Unknown Customer', 'Unknown', 'Unknown');

insert into dim_product (product_sk, product_id, product_name, category)
values (-1, 'UNKNOWN', 'Unknown Product', 'Unknown');

insert into dim_date (date_sk, full_date, day_of_week_name, month_name)
values (-1, '1900-01-01', 'Unknown', 'Unknown');
```

**In the ETL — replace NULL FKs with -1:**

```sql
insert into fact_transactions (transaction_sk, customer_sk, product_sk, ...)
select
    nextval('transaction_sk_seq'),
    coalesce(c.customer_sk, -1),   -- -1 if customer not found
    coalesce(p.product_sk, -1),    -- -1 if product not found
    ...
from staging_transactions st
left join dim_customer c on st.customer_id = c.customer_id and c.is_current = true
left join dim_product  p on st.product_id  = p.product_id  and p.is_current = true;
```

Now `GROUP BY p.category` will show "Unknown" as a visible category instead of NULL getting silently dropped.

### NULL vs "N/A" vs "Unknown" in dimension tables

Use these three values consistently and never interchangeably:

| Value | Meaning | Example |
|---|---|---|
| `NULL` | The attribute is not applicable to this row — there is no value and there never will be | `middle_name` on a customer with no middle name |
| `'N/A'` | Not applicable in context — the attribute exists but doesn't apply | `spouse_name` for a single person |
| `'Unknown'` | The attribute is applicable but the value hasn't been collected or couldn't be found | `city` for a customer who skipped that field |

**Gotchas:**
- The -1 SK pattern works only if every dimension has the -1 row pre-populated. If it's missing, the FK lookup will fail and you're back to NULLs.
- Some tools display `NULL` and `'Unknown'` identically. Using a consistent string value ensures `GROUP BY` always groups unknowns together.
- In SCD 2 dimensions, the Unknown row (`SK = -1`) should never have `effective_from` and `effective_to` logic applied — it's a static placeholder.
- NULL measures in fact tables follow different rules. `SUM(revenue)` ignores NULLs — which is usually correct. But `COUNT(revenue)` vs `COUNT(*)` will differ if revenue is sometimes NULL. Be explicit.

---

## 22. Performance Considerations

**What it solves:** Ensures your data model performs at scale by choosing the right physical design options — partitioning, clustering, and materialization.

> **Keywords to spot:** "query is slow", "scan cost", "partition pruning", "clustering key", "materialized view", "incremental load", "full table scan"

### Partitioning

Divide a large table into smaller physical segments based on a column value. Queries that filter on the partition key only scan matching partitions — dramatic cost reduction.

```sql
-- Snowflake: cluster by date (partitioning equivalent)
create table fact_transactions (
    transaction_sk      bigint,
    transaction_date    date,
    customer_sk         bigint,
    amount              decimal(12,2)
)
cluster by (transaction_date);

-- BigQuery: partition by ingestion date or date column
create table `project.dataset.fact_transactions`
(
    transaction_sk      int64,
    transaction_date    date,
    customer_sk         int64,
    amount              numeric
)
partition by transaction_date;

-- PostgreSQL: declarative table partitioning
create table fact_transactions (
    transaction_sk      bigint,
    transaction_date    date,
    customer_sk         bigint,
    amount              decimal(12,2)
) partition by range (transaction_date);

create table fact_transactions_2024
    partition of fact_transactions
    for values from ('2024-01-01') to ('2025-01-01');
```

**Best partition keys:** Date columns (most queries filter on date). Avoid high-cardinality natural keys — too many partitions defeats the purpose.

### Clustering / Sort Keys

Within a partition, physically sort rows by a column to make range scans fast.

```sql
-- Snowflake: multi-column cluster key
create table fact_sales (
    ...
)
cluster by (order_date, customer_sk);

-- Redshift: sort key + dist key
create table fact_sales (
    ...
)
distkey(customer_sk)
sortkey(order_date, customer_sk);
```

**Best cluster keys:** After the partition key, cluster on the most commonly filtered or joined column — usually `customer_sk` or `product_sk` depending on the use case.

### Materialization choices

| Strategy | When to use | Trade-off |
|---|---|---|
| **Table** (physical) | Queried frequently, expensive to recompute | Uses storage, must be refreshed |
| **View** (virtual) | Simple transformations, underlying table changes frequently | Recomputes every query — expensive for complex logic |
| **Materialized View** | Expensive aggregations queried often, acceptable staleness | Storage + refresh cost, but much faster than view |
| **Incremental table** | Large fact tables, only new rows added daily | Complex to implement, risk of missing updates |

**Incremental load pattern — only process new rows:**

```sql
-- Load only transactions from the last partition/date
insert into fact_transactions
select
    ...
from silver.transactions_clean
where transaction_date = current_date - 1
  and transaction_sk not in (select transaction_sk from fact_transactions);
-- Better with a watermark: load rows with load_date > last_run_watermark
```

### General guidelines

- **Fact tables:** Always partition on the primary date column. Cluster on the most commonly joined dimension SK.
- **Dimension tables:** Small enough that full scans are fine. No partitioning needed unless the dimension has millions of rows (like `dim_user` at large scale).
- **Avoid SELECT \*:** In columnar warehouses, scanning unused columns wastes money. Select only what you need.
- **Filter early:** Push WHERE clauses to CTEs, not outer queries. In columnar engines, predicate pushdown is critical.

**Gotchas:**
- Over-partitioning is as bad as no partitioning. Snowflake recommends clustering keys only when tables exceed 1TB. BigQuery charges for metadata operations on over-partitioned tables.
- Materialized views become stale. Know your refresh schedule and whether your BI users understand the staleness.
- In Snowflake, `CLUSTER BY` is not free — automatic clustering consumes credits. Measure before enabling.
