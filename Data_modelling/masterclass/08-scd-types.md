<!-- data-modelling-patterns: SCD Types in Depth -->

# SCD Types in Depth

## Type 1 — Overwrite

The current value replaces the old value. No history is retained.

```sql
-- Type 1 update: customer email address corrected
UPDATE dim_customer
SET email_address = 'new.email@example.com',
    dw_updated_at = CURRENT_TIMESTAMP
WHERE customer_id = 'CUST-001'
  AND is_current = TRUE;
```

**Can answer**: What is the customer's current email address?
**Cannot answer**: What email did we send to this customer in January 2023?
**Use when**: The attribute correction represents a fix to wrong data (typo, not a change). Business users never ask historical questions about this attribute.

## Type 2 — Add New Row (Full History)

A new row is inserted for every change. Old rows are expired with an `eff_end_date`.

```sql
-- Type 2 change: customer upgrades to Gold loyalty tier
UPDATE dim_customer
SET eff_end_date = '2024-06-14',
    is_current = FALSE,
    dw_updated_at = CURRENT_TIMESTAMP
WHERE customer_id = 'CUST-001'
  AND is_current = TRUE;

INSERT INTO dim_customer (
    customer_key, customer_id, loyalty_tier, eff_start_date, eff_end_date, is_current, dw_inserted_at, ...
) VALUES (
    99999, 'CUST-001', 'GOLD', '2024-06-15', '9999-12-31', TRUE, CURRENT_TIMESTAMP, ...
);
```

**Can answer**: What loyalty tier was the customer when they placed order X on March 10?
**Cannot answer**: What was the customer's loyalty tier corrected to after we discovered a data error (without bi-temporal)? (This requires the bi-temporal extension.)
**The COUNT DISTINCT problem**: If you `COUNT(DISTINCT customer_key)` on a Type 2 dimension joined to a fact, you count surrogate keys — and one logical customer has multiple surrogate keys. A customer who changed tier twice has 3 surrogate keys. `COUNT(DISTINCT customer_key)` returns 3 for what should be 1 distinct customer.

**Fix**: Always `COUNT(DISTINCT customer_id)` (the natural key) or `COUNT(DISTINCT customer_key) OVER (filter to is_current = TRUE)` when counting distinct customers.

```sql
-- WRONG: double-counts customers who changed loyalty tier
SELECT COUNT(DISTINCT customer_key) AS unique_customers
FROM fact_order_line;

-- CORRECT: count logical customers
SELECT COUNT(DISTINCT c.customer_id) AS unique_customers
FROM fact_order_line f
JOIN dim_customer c ON f.customer_key = c.customer_key;
-- The join uses the surrogate key at order time; natural key deduplicates
```

## Type 3 — Add Column for Prior Value

Only the current value and one prior value are stored. History beyond one change is lost.

```sql
ALTER TABLE dim_customer
ADD COLUMN prior_loyalty_tier VARCHAR(20),
ADD COLUMN loyalty_tier_change_date DATE;

-- Update:
UPDATE dim_customer
SET prior_loyalty_tier = loyalty_tier,
    loyalty_tier_change_date = '2024-06-15',
    loyalty_tier = 'GOLD'
WHERE customer_id = 'CUST-001' AND is_current = TRUE;
```

**Can answer**: What was the customer's previous tier before the most recent change?
**Cannot answer**: What was the tier 3 changes ago?
**Use when**: Analysts genuinely only ever need "current vs previous" (A/B test holdout comparison, promotion response analysis for the most recent change only). Rare in practice.

## Type 4 — Mini-Dimension (History Table)

Rapidly changing attributes are split into a separate history table. The main dimension stores only stable attributes.

```sql
-- Main dimension (stable attributes only)
CREATE TABLE dim_customer (
    customer_key     BIGINT  NOT NULL,
    customer_id      VARCHAR(50) NOT NULL,
    first_name       VARCHAR(100),
    last_name        VARCHAR(100),
    acquisition_date DATE,
    PRIMARY KEY (customer_key)
);

-- Mini-dimension for frequently changing profile attributes
CREATE TABLE dim_customer_profile (
    profile_key         BIGINT  NOT NULL,
    customer_id         VARCHAR(50) NOT NULL,
    loyalty_tier        VARCHAR(20),
    email_subscribed    BOOLEAN,
    sms_subscribed      BOOLEAN,
    last_purchase_date  DATE,
    eff_start_date      DATE   NOT NULL,
    eff_end_date        DATE   NOT NULL DEFAULT '9999-12-31',
    is_current          BOOLEAN NOT NULL DEFAULT TRUE,
    PRIMARY KEY (profile_key)
);
```

**Use when**: A small set of attributes changes very frequently (daily or hourly) and tracking them in the main dimension would generate enormous numbers of Type 2 rows — bloating the dimension and degrading join performance on the fact.

## Type 6 — Hybrid (1+2+3)

Type 6 combines Type 1 (overwrite current value), Type 2 (add new row), and Type 3 (add prior value column) into a single row structure:

```sql
CREATE TABLE dim_customer_type6 (
    customer_key         BIGINT   NOT NULL,  -- surrogate key (changes on Type 2 event)
    customer_id          VARCHAR(50) NOT NULL,  -- natural key
    -- Type 2: historical value (value when this row was created)
    loyalty_tier_hist    VARCHAR(20) NOT NULL,
    -- Type 3: previous value (what the value was in the immediately prior row)
    loyalty_tier_prev    VARCHAR(20),
    -- Type 1: current value (always overwritten to show current, regardless of row age)
    loyalty_tier_curr    VARCHAR(20) NOT NULL,
    eff_start_date       DATE     NOT NULL,
    eff_end_date         DATE     NOT NULL DEFAULT '9999-12-31',
    is_current           BOOLEAN  NOT NULL DEFAULT TRUE,
    PRIMARY KEY (customer_key)
);
```

A historical fact row joined to a Type 6 dimension gives three perspectives simultaneously: the tier at the time of the fact (`loyalty_tier_hist`), the tier immediately before the change (`loyalty_tier_prev`), and the current tier (`loyalty_tier_curr`). This enables "what tier are they now vs what tier were they when they ordered?" without any additional join.

**Maintenance complexity**: When a new change creates a new Type 2 row, all prior rows for that customer must have their `loyalty_tier_curr` column updated (Type 1 overwrite across the history). At 100M customer rows, this update operation is expensive. Type 6 is appropriate for dimensions with < 10M rows where the "current value in historical context" query is frequent.

## Bi-Temporal: When Type 2 Is Insufficient

Type 2 records the transaction time: when the warehouse recorded the change. It does not record the valid time: when the change was actually effective in the real world. For most dimensions, these are the same. But when corrections are made retroactively, they diverge.

**Scenario**: A customer's loyalty tier was incorrectly coded as Bronze instead of Gold from January through March (a system error was discovered in April). A Type 2 model creates a new Gold row effective April 1. All January–March orders are still joined to the Bronze surrogate key. Historical revenue reports are wrong for those months — they show the wrong tier context.

The bi-temporal fix:

```sql
CREATE TABLE dim_customer_bitemporal (
    customer_key            BIGINT   NOT NULL,
    customer_id             VARCHAR(50) NOT NULL,
    loyalty_tier            VARCHAR(20),
    -- Valid time (real world)
    valid_from              DATE     NOT NULL,
    valid_to                DATE     NOT NULL DEFAULT '9999-12-31',
    -- Transaction time (warehouse recording)
    recorded_from           TIMESTAMP NOT NULL,
    recorded_to             TIMESTAMP NOT NULL DEFAULT '9999-12-31 23:59:59',
    is_current_valid        BOOLEAN  NOT NULL DEFAULT TRUE,
    PRIMARY KEY (customer_key)
);
```

The correction is modeled as:
1. Expire the incorrect Bronze rows (set `valid_to = '2023-03-31'` AND `recorded_to = CURRENT_TIMESTAMP`)
2. Insert corrected Gold rows with `valid_from = '2023-01-01'`, `valid_to = '2023-03-31'`, `recorded_from = CURRENT_TIMESTAMP`

Queries for the current view of history use `WHERE recorded_to = '9999-12-31 23:59:59'`. Queries for what the system believed before the correction use `WHERE recorded_from <= '<correction_date>'`. This is essential for auditability in regulated industries where "what did you report in Q1" must be answerable independently of subsequent corrections.
