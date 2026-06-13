## 4. Financial Services

### When to Use This Design

Financial services data modeling is governed by two imperatives that conflict with analytical convenience: **regulatory auditability** (every balance must be reconstructable at any historical date) and **transaction finality** (once settled, a transaction cannot be deleted or modified — only corrected via offsetting entries). The business questions:

- What was the account balance for account 12345 as of the close of business on December 31?
- Which transactions are driving the discrepancy between the general ledger and the sub-ledger?
- What is the total credit exposure to counterparty X across all products as of today?
- Show me the complete audit trail for all changes to the rate on loan 9999.

### The Schema

#### Double-Entry Accounting Ledger

Double-entry is the foundational constraint: every financial transaction must have equal debits and credits. The ledger model enforces this at the data level by storing both legs of every entry.

```sql
-- Journal entry header
CREATE TABLE fact_journal_entry (
    journal_entry_key       BIGINT          NOT NULL,
    journal_entry_id        VARCHAR(80)     NOT NULL,   -- source system JE ID
    entry_date              DATE            NOT NULL,
    entry_date_key          INT             NOT NULL,
    posting_datetime        TIMESTAMP       NOT NULL,   -- when it hit the GL
    effective_date          DATE            NOT NULL,   -- business date it applies to
    journal_type            VARCHAR(30)     NOT NULL,   -- 'STANDARD','REVERSAL','ADJUSTMENT','ACCRUAL'
    source_system           VARCHAR(50)     NOT NULL,
    reference_id            VARCHAR(100),              -- payment ID, trade ID, etc.
    description             VARCHAR(500),
    posted_by_user          VARCHAR(200)    NOT NULL,
    approved_by_user        VARCHAR(200),
    is_reversed             BOOLEAN         NOT NULL    DEFAULT FALSE,
    reversing_entry_id      VARCHAR(80),               -- points to reversal JE if applicable
    -- Validation
    debit_total             NUMERIC(20,4)   NOT NULL,
    credit_total            NUMERIC(20,4)   NOT NULL,
    is_balanced             BOOLEAN         NOT NULL    GENERATED ALWAYS AS (debit_total = credit_total),
    PRIMARY KEY (journal_entry_key)
)
PARTITION BY (entry_date_key)
CLUSTER BY (source_system, journal_type);

-- Journal entry lines (one row per account leg)
CREATE TABLE fact_journal_entry_line (
    je_line_key             BIGINT          NOT NULL,
    journal_entry_key       BIGINT          NOT NULL,
    journal_entry_id        VARCHAR(80)     NOT NULL,
    line_sequence           INT             NOT NULL,
    account_key             BIGINT          NOT NULL,
    cost_center_key         BIGINT,
    entity_key              BIGINT          NOT NULL,   -- legal entity
    debit_credit_flag       CHAR(1)         NOT NULL,   -- 'D' or 'C'
    amount                  NUMERIC(20,4)   NOT NULL,   -- always positive
    currency_code           CHAR(3)         NOT NULL,
    functional_amount       NUMERIC(20,4),             -- converted to functional currency
    exchange_rate           NUMERIC(14,8),
    counterparty_key        BIGINT,
    PRIMARY KEY (je_line_key)
)
PARTITION BY RANGE (journal_entry_key)  -- co-partitioned with header
CLUSTER BY (account_key, entity_key);
```

**Why amount is always positive with a debit_credit_flag**: Signed amounts (negative for credits) seem more intuitive but create aggregation errors. `SUM(amount)` on a signed column gives you zero for a balanced entry — which looks correct but hides all activity. `SUM(CASE WHEN debit_credit_flag = 'D' THEN amount ELSE 0 END)` is unambiguous. Regulatory systems (Basel III reporting, GAAP sub-ledger reconciliation) always use unsigned amounts with explicit sign flags.

#### Account Dimension with SCD Type 2

```sql
CREATE TABLE dim_account (
    account_key             BIGINT          NOT NULL,
    account_id              VARCHAR(30)     NOT NULL,   -- GL account code
    account_name            VARCHAR(200)    NOT NULL,
    account_type            VARCHAR(20)     NOT NULL,  -- 'ASSET','LIABILITY','EQUITY','REVENUE','EXPENSE'
    account_subtype         VARCHAR(50),
    normal_balance          CHAR(1)         NOT NULL,  -- 'D' (asset/expense) or 'C' (liab/equity/rev)
    parent_account_id       VARCHAR(30),               -- for rollup hierarchy
    fs_line_item            VARCHAR(100),              -- financial statement mapping
    is_intercompany         BOOLEAN         NOT NULL   DEFAULT FALSE,
    is_control_account      BOOLEAN         NOT NULL   DEFAULT FALSE,
    -- SCD Type 2
    eff_start_date          DATE            NOT NULL,
    eff_end_date            DATE            NOT NULL   DEFAULT '9999-12-31',
    is_current              BOOLEAN         NOT NULL   DEFAULT TRUE,
    PRIMARY KEY (account_key)
)
CLUSTER BY (account_type, account_id);
```

#### Transaction Fact at Multiple Granularities

The key design decision for financial transactions is whether to store at event grain or daily position grain. The answer is **both** — for different use cases.

```sql
-- Transaction fact (event grain — one row per settled transaction)
CREATE TABLE fact_transaction (
    transaction_key         BIGINT          NOT NULL,
    transaction_id          VARCHAR(80)     NOT NULL,
    transaction_date_key    INT             NOT NULL,
    transaction_datetime    TIMESTAMP       NOT NULL,
    value_date              DATE            NOT NULL,   -- economic settlement date
    account_key             BIGINT          NOT NULL,
    counterparty_key        BIGINT,
    product_key             BIGINT          NOT NULL,
    transaction_type        VARCHAR(30)     NOT NULL,  -- 'PAYMENT','TRANSFER','FEE','INTEREST','CHARGE_OFF'
    debit_credit_flag       CHAR(1)         NOT NULL,
    amount                  NUMERIC(20,4)   NOT NULL,
    currency_code           CHAR(3)         NOT NULL,
    functional_amount       NUMERIC(20,4)   NOT NULL,
    running_balance         NUMERIC(20,4),             -- denormalized for common queries, maintained by load
    channel                 VARCHAR(30),
    reference_number        VARCHAR(100),
    je_line_key             BIGINT,                    -- link to GL entry
    PRIMARY KEY (transaction_key)
)
PARTITION BY (transaction_date_key)
CLUSTER BY (account_key, transaction_type);

-- Daily position / account balance fact (snapshot grain)
CREATE TABLE fact_account_daily_position (
    position_key            BIGINT          NOT NULL,
    position_date_key       INT             NOT NULL,
    account_key             BIGINT          NOT NULL,
    entity_key              BIGINT          NOT NULL,
    product_key             BIGINT          NOT NULL,
    opening_balance         NUMERIC(20,4)   NOT NULL,
    total_debits            NUMERIC(20,4)   NOT NULL   DEFAULT 0,
    total_credits           NUMERIC(20,4)   NOT NULL   DEFAULT 0,
    closing_balance         NUMERIC(20,4)   NOT NULL,
    accrued_interest        NUMERIC(20,4),
    currency_code           CHAR(3)         NOT NULL,
    functional_closing_balance NUMERIC(20,4),
    PRIMARY KEY (position_key)
)
PARTITION BY (position_date_key)
CLUSTER BY (account_key, entity_key);
```

#### Point-in-Time Balance Reconstruction

The canonical financial services hard problem: "What was the balance of account X at close of business on December 31, 2023?" There are three approaches, each with different tradeoffs:

**Option 1: Scan transaction fact and sum from inception**
```sql
SELECT
    SUM(CASE WHEN debit_credit_flag = 'D' THEN amount ELSE -amount END) AS balance
FROM fact_transaction
WHERE account_key = 99999
  AND transaction_date_key <= 20231231;
```
Correct, but at 10 years of transaction history this is a multi-billion row scan for a single account. Unacceptable response time.

**Option 2: Use daily position snapshot**
```sql
SELECT closing_balance
FROM fact_account_daily_position
WHERE account_key = 99999
  AND position_date_key = 20231231;
```
O(1) lookup, millisecond response. But what if December 31 was not loaded (weekend, holiday processing delay)? The query returns NULL instead of the correct balance. You need:

```sql
SELECT closing_balance
FROM fact_account_daily_position
WHERE account_key = 99999
  AND position_date_key = (
      SELECT MAX(position_date_key)
      FROM fact_account_daily_position
      WHERE account_key = 99999
        AND position_date_key <= 20231231
  );
```

**Option 3: Hybrid (production pattern)**
Use daily snapshots for dates where snapshots exist, fall back to transaction summation for gaps. This is encapsulated in a SQL view or a dbt model that generates the correct balance for any arbitrary date.

#### Risk/Exposure Modeling

Credit exposure requires knowing, at any point in time, how much a given counterparty owes across all products and legal entities. This is the "aggregation across grains" problem:

```sql
CREATE TABLE fact_credit_exposure (
    exposure_key            BIGINT          NOT NULL,
    exposure_date_key       INT             NOT NULL,
    counterparty_key        BIGINT          NOT NULL,
    entity_key              BIGINT          NOT NULL,
    product_key             BIGINT          NOT NULL,
    facility_id             VARCHAR(50),               -- credit limit facility
    exposure_type           VARCHAR(30)     NOT NULL,  -- 'DRAWN','UNDRAWN','CONTINGENT','DERIVATIVE_MtM'
    gross_exposure          NUMERIC(20,4)   NOT NULL,
    collateral_value        NUMERIC(20,4)   NOT NULL   DEFAULT 0,
    net_exposure            NUMERIC(20,4)   NOT NULL,  -- gross - collateral
    pd_estimate             NUMERIC(8,6),              -- Probability of Default
    lgd_estimate            NUMERIC(8,6),              -- Loss Given Default
    expected_credit_loss    NUMERIC(20,4),             -- pd * lgd * net_exposure
    currency_code           CHAR(3)         NOT NULL,
    PRIMARY KEY (exposure_key)
)
PARTITION BY (exposure_date_key)
CLUSTER BY (counterparty_key, entity_key, exposure_type);
```

### The Hard Problems

**Audit Trail for Rate Changes**: When a loan's interest rate changes (rate adjustment, renegotiation, error correction), the history of rate changes must be preserved not just as the current rate but with the exact window each rate was effective. This is another bi-temporal requirement. The `dim_account` SCD Type 2 captures when the warehouse learned about the rate change. A separate `fact_account_rate_history` table captures the contractually effective rate windows:

```sql
CREATE TABLE fact_account_rate_history (
    rate_history_key        BIGINT          NOT NULL,
    account_key             BIGINT          NOT NULL,
    account_id              VARCHAR(30)     NOT NULL,
    rate_type               VARCHAR(30)     NOT NULL,  -- 'INTEREST','PENALTY','PROMO'
    rate_value              NUMERIC(10,6)   NOT NULL,
    rate_basis              VARCHAR(20)     NOT NULL,  -- 'ANNUAL','DAILY','MONTHLY'
    contractual_start_date  DATE            NOT NULL,  -- valid time: when rate is effective
    contractual_end_date    DATE            NOT NULL   DEFAULT '9999-12-31',
    recorded_at             TIMESTAMP       NOT NULL,  -- transaction time
    recorded_by             VARCHAR(200)    NOT NULL,
    change_reason           VARCHAR(200),
    PRIMARY KEY (rate_history_key)
)
CLUSTER BY (account_key, rate_type);
```

**Balance Reconciliation at Any Historical Date**: The daily position fact assumes the GL and sub-ledger are always in sync. They are not. Reconciliation breaks require querying `fact_journal_entry_line` summed by account versus `fact_account_daily_position.closing_balance` for the same account and date. Discrepancies are expected during end-of-day processing windows. The correct architecture stores a `reconciliation_status` flag on `fact_account_daily_position` that is updated when the GL sign-off process runs.

### Scale Mechanics

At a major bank, the `fact_transaction` table grows at 100M–500M rows per day across all products. Five years of retention yields 100B+ rows. This is beyond the scale where daily partition scans are acceptable even for a single account. The practical solution used by Citi, JPMorgan, and others in their analytical warehouses:

1. Partition by `transaction_date_key` (daily)
2. Cluster by `(account_key, transaction_type)` within partitions
3. Maintain pre-computed `fact_account_daily_position` as the primary query surface
4. Retain raw transactions in "cold" storage (GCS/S3) beyond 2 years; hot warehouse holds only recent history
5. For point-in-time balance questions on accounts older than 2 years, query the archived daily snapshots in cold storage
