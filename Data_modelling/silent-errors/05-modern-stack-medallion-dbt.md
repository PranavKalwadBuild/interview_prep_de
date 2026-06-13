<!-- Part of Data_modelling: Silent Errors — Modern Stack: Medallion and dbt -->

# Silent Errors — Modern Stack: Medallion Architecture and dbt

The modern lakehouse stack (Bronze/Silver/Gold + dbt) introduces a new class of silent errors
unique to layered, contract-free, view-heavy pipeline architectures. These errors are often more
dangerous than traditional warehouse bugs because the layered trust model (Gold is clean because
Silver is clean because Bronze is raw) means a defect at any layer silently propagates forward
with no circuit breaker.

---

### 1. Bronze Layer Schema Drift Silently Corrupting Silver

**What it looks like:**
Fivetran or Airbyte syncs a source table into Bronze. Silver models `SELECT *` from Bronze or
select explicit column names. The source system adds a new column or renames an existing one.

**What actually happens:**
- `SELECT *` path: Silver silently inherits the new column with no transformation, no validation,
  no lineage annotation. Gold models that expect a specific column set now receive extra columns
  they don't account for.
- Explicit column path: Silver silently ignores the new column entirely — the renamed column
  produces NULL in Silver because the old name no longer exists. No error is thrown because
  `SELECT old_col FROM bronze_table` returns NULL when `old_col` doesn't exist in databases that
  allow it (Redshift, some Spark configurations), or fails hard in strict-mode Snowflake.

**Why it's insidious:**
Bronze loads succeed. Silver models compile. If Silver uses `SELECT *`, downstream column counts
change but queries don't break. If Silver uses explicit columns, the renamed column silently
becomes NULL across all Silver and Gold records added after the rename — old records are correct,
new ones are not.

**Example:**
```sql
-- Source system renames 'region_code' to 'market_code' on 2024-08-01

-- Silver model (explicit columns):
SELECT
    customer_id,
    region_code,    -- this column no longer exists after Aug 1; returns NULL in permissive mode
    account_tier
FROM bronze_customers;

-- Gold model:
SELECT region_code, SUM(revenue) FROM silver_customers GROUP BY region_code;
-- After Aug 1: all new customers have region_code = NULL
-- Old customers have region_code populated correctly
-- The split is invisible — the table appears fully populated
```

**Detection query / invariant:**
```sql
-- Check for sudden increase in NULL rates on key dimension columns
SELECT
    DATE_TRUNC('day', loaded_at)  AS load_day,
    COUNT(*)                      AS total_rows,
    COUNT(region_code)            AS non_null_region,
    1.0 - COUNT(region_code) / COUNT(*) AS null_rate
FROM silver_customers
GROUP BY 1
ORDER BY 1;
-- A step-change increase in null_rate on a specific date = schema drift at Bronze

-- Prevention: use schema contract enforcement (dbt contracts, Great Expectations, or Soda)
-- dbt: add `contract: enforced: true` to model config
```

**Real-world consequence:**
A regional performance report shows all customers acquired after August as "null region" —
which aggregates to an "other/unknown" bucket in BI tools. Regional managers see a collapse in
their acquisition numbers. The real acquisition is healthy; it's just mis-attributed to unknown.

---

### 2. Bronze NULL vs. Empty String Inconsistency Splitting Aggregation Groups

**What it looks like:**
The same logical "no value" state is represented differently in the Bronze layer: some records
have `region = NULL`, others have `region = ''` (empty string). Silver normalization converts
one but not the other.

**What actually happens:**
`GROUP BY region` in Gold produces two separate groups for "no region": one for NULL and one
for empty string `''`. Aggregations are split across these two groups. Reports that filter on
`WHERE region IS NULL` miss the `''` group. `WHERE region = ''` misses the NULL group.
Neither group shows the full picture.

**Why it's insidious:**
Both NULL and `''` are valid values in any SQL engine. The Silver normalization step ran without
error. The split groups look like small "other" categories — easy to dismiss as edge cases.

**Example:**
```sql
-- Bronze: 500 rows with region=NULL, 300 rows with region='' (both mean "unknown")
-- Silver: COALESCE(region, 'unknown') converts NULL → 'unknown' but does NOT convert ''

-- Gold aggregation:
SELECT region, COUNT(*) AS customers
FROM gold_customers GROUP BY region;
-- Result:
-- 'West'    : 4200
-- 'East'    : 3800
-- 'unknown' : 500   ← came from NULLs
-- ''        : 300   ← came from empty strings, not normalized
-- Total for "no region": 800, but visible as two separate groups
```

**Detection query / invariant:**
```sql
-- Check Bronze for both NULL and empty string on the same column
SELECT
    CASE
        WHEN region IS NULL  THEN 'null_value'
        WHEN region = ''     THEN 'empty_string'
        ELSE 'has_value'
    END AS value_type,
    COUNT(*) AS row_count
FROM bronze_customers
GROUP BY 1;

-- If both null_value and empty_string are non-zero, Silver normalization must handle both
-- Fix: CASE WHEN region IS NULL OR region = '' THEN 'unknown' ELSE region END
```

**Real-world consequence:**
Customer acquisition analysis by region is used for territory planning. The 300 empty-string
customers are treated as a separate micro-segment in territory assignment. They receive generic
outreach instead of regional sales coverage, reducing conversion rate for 5% of the pipeline.

---

### 3. dbt View Fan-Out — Non-Materialized Model Runs Twice

**What it looks like:**
A dbt model D is configured as `materialized='view'`. Models B and C both `ref(D)`. Model A
`ref(B)` and `ref(C)`. The DAG is valid and acyclic.

**What actually happens:**
Since D is a view (not a table), each reference to D causes the underlying query to execute at
runtime. When A joins B and C, and both B and C internally query D (the view), D's query runs
twice — once for B and once for C. If D reads from a source that changes between these two
executions (streaming table, live source, any non-idempotent source), B and C see different
snapshots of D. A's join then silently compares data from two different points in time.

**Why it's insidious:**
The dbt DAG is correct. No test fails. The double execution is invisible in dbt run output —
dbt reports each model once, not the number of times the underlying view is queried. Only query
profiling or cost analysis reveals that D ran twice.

**Example:**
```
Model D (view): expensive CDC event aggregation — reads from a streaming source table
Model B (table): ref(D), adds customer attributes
Model C (table): ref(D), adds product attributes
Model A (table): ref(B) JOIN ref(C)

When B runs: D executes and reads CDC events up to timestamp T1
When C runs: D executes and reads CDC events up to timestamp T2 (T2 > T1, 2 minutes later)

A joins B (T1 snapshot) with C (T2 snapshot) → silent temporal mismatch
```

**Detection query / invariant:**
```yaml
# Prevention: materialize shared, expensive, or time-sensitive models as tables or incrementals
# In dbt project.yml or model config:
models:
  your_project:
    staging:
      +materialized: view       # fine for simple, cheap transformations
    intermediate:
      +materialized: table      # materialize shared intermediate models
    marts:
      +materialized: table

# Detection: run dbt docs generate and inspect the DAG for view models with multiple parents
# Any view with 2+ downstream refs is a fan-out candidate
```

**Real-world consequence:**
A revenue reconciliation model joins a product dimension (built from CDC view, snapshot T1)
with a customer dimension (built from the same CDC view, snapshot T2). New customers added in
the 2-minute window between T1 and T2 appear in the customer join but not the product join.
Their revenue appears with correct customer attribution but NULL product attribution — silently
misclassified as "unknown product."

---

### 4. One Big Table (OBT) Dimension Staleness — Historical Segment Drift

**What it looks like:**
An OBT is built by pre-joining facts to dimensions at write time. Each row contains all
dimension attributes at the time of the event. New rows are written with current dimension
attributes.

**What actually happens:**
When a dimension attribute changes (customer segment changes from SMB to Enterprise), historical
OBT rows still carry the old segment value. New OBT rows for the same customer carry the new
value. A trend analysis of revenue by segment silently compares old segment rules on historical
rows against new segment rules on recent rows — a like-for-like comparison that is actually
unlike.

**Why it's insidious:**
Each individual OBT row was correct at write time. No row is wrong in isolation. The error is
in comparing historical rows (old attribute values) to recent rows (new attribute values) as
if they represent the same segmentation scheme.

**Example:**
```sql
-- OBT rows for customer 1001:
-- 2023-01-15, revenue=5000, segment='SMB'      ← written when customer was SMB
-- 2024-07-20, revenue=8000, segment='Enterprise' ← written after customer upgraded

-- Year-over-year by segment:
SELECT segment, YEAR(event_date), SUM(revenue)
FROM one_big_table GROUP BY segment, YEAR(event_date);
-- 2023 Enterprise revenue is understated (high-value customers shown as SMB then)
-- 2024 SMB revenue is understated (customers who graduated to Enterprise now missing from SMB)
-- The "SMB is declining" story is structurally guaranteed — it has nothing to do with business
```

**Detection query / invariant:**
```sql
-- Check for customers who changed segment but appear under old segment in OBT
SELECT
    obt.customer_id,
    obt.segment     AS obt_segment,
    dc.segment      AS current_segment,
    obt.event_date
FROM one_big_table obt
JOIN dim_customer dc ON obt.customer_id = dc.customer_id
WHERE obt.segment <> dc.segment
  AND obt.event_date < CURRENT_DATE - INTERVAL '1 day'  -- not in-flight
LIMIT 100;
-- Non-zero = OBT rows have stale dimension attributes vs current dimension

-- Proper fix: either accept point-in-time OBT values (document the limitation)
-- or rebuild OBT with SCD-type joins to get correct point-in-time attributes
```

**Real-world consequence:**
SMB segment appears to be losing revenue year-over-year. Enterprise appears to be growing
disproportionately. A strategic pivot toward enterprise sales is approved. The actual dynamic —
organic customer graduation — is obscured by the OBT historical-vs-current segment comparison.

---

### 5. dbt `on_schema_change=append_new_columns` — Biased Historical Averages

**What it looks like:**
A dbt incremental model is configured with `on_schema_change=append_new_columns`. A new column
is added to the source schema. dbt automatically adds the column to the target table, backfilling
historical rows with NULL.

**What actually happens:**
Historical rows have NULL for the new column. New rows have real values. `AVG(new_column)`
computed over the full history treats all historical NULLs as missing (excluded from AVG
calculation), which is correct SQL behaviour — but the effective window for the average is
only the period since the column was added. Trend analysis over the full history compares a
recent average (complete window) to a historical average (empty — computed as NULL for all
historical periods).

**Why it's insidious:**
dbt runs successfully. `on_schema_change=append_new_columns` is a valid, documented dbt feature.
The NULL backfill looks reasonable (column didn't exist historically). The silent error is that
any time-series analysis of the new column automatically has a truncated effective history.

**Example:**
```sql
-- New column 'session_duration' added to source on 2024-06-01
-- dbt appends column with NULL for all rows before 2024-06-01

-- Analysis: average session duration over the last 12 months
SELECT
    DATE_TRUNC('month', event_date) AS month,
    AVG(session_duration)           AS avg_session_duration
FROM silver_events
WHERE event_date >= '2023-06-01'
GROUP BY 1;
-- 2023-06 through 2024-05: AVG = NULL (all historical rows are NULL)
-- 2024-06 onwards: AVG shows real values
-- A trend chart starts in June 2024, not June 2023 — silently truncated history
```

**Detection query / invariant:**
```sql
-- Check when a column first had non-NULL values
SELECT
    DATE_TRUNC('month', event_date) AS month,
    COUNT(*) AS total_rows,
    COUNT(session_duration) AS non_null_rows,
    1.0 * COUNT(session_duration) / COUNT(*) AS fill_rate
FROM silver_events
GROUP BY 1
ORDER BY 1;
-- Fill rate jump from 0 to ~1.0 on a specific month = column was added that month
-- All analysis before that month is not comparable to analysis after

-- Prevention: document column_added_date metadata in the model schema.yml
-- and filter analyses to only use data from after column_added_date
```

**Real-world consequence:**
A product engagement report shows "session duration has dramatically improved since June" — but
there was no data before June. The improvement is a data artefact. Product team announces a
feature win. The baseline is fabricated.

---

### 6. dbt Seed Rebuild Leaving Downstream Stale

**What it looks like:**
A dbt seed CSV is used as a lookup dimension (e.g., `country_code_mapping.csv`). When the CSV
is updated, `dbt seed` is run to reload it. Downstream models that `ref()` the seed are
assumed to pick up the changes on the next run.

**What actually happens:**
In a partial production run (only running changed models, not full `dbt build`), downstream
models that reference the seed are not re-run if they are not flagged as changed. The seed
table is updated, but the downstream materialized tables still hold pre-seed-update data.
The stale downstream table serves the BI layer with outdated lookup values.

**Why it's insidious:**
`dbt seed` reports success. The seed table is correct. The downstream models are not re-run
because no model code changed — only the underlying seed data changed. The stale state persists
until the next full run.

**Example:**
```
CSV updated: added 'Kosovo' with country_code='XK' to seed
dbt seed runs: seed table updated correctly
Partial run: dbt run --select silver_customers  (does NOT include gold_revenue_by_country)
gold_revenue_by_country still uses old seed join — 'XK' revenue maps to NULL country
BI tool shows Kosovo revenue as 'unknown country' until next full build
```

**Detection query / invariant:**
```sql
-- Check for seed keys that exist in the seed table but produce NULL joins in downstream
SELECT
    rev.country_code,
    COUNT(*) AS transactions,
    SUM(rev.revenue) AS revenue
FROM gold_revenue_by_country rev
WHERE country_name IS NULL    -- NULL = seed join failed
  AND rev.country_code IS NOT NULL;
-- Non-zero = downstream model is stale relative to seed

-- Prevention: always run dbt build (not just dbt seed) after seed changes
-- Or: set seed models to trigger downstream model runs via dbt's --defer or slim CI patterns
```

**Real-world consequence:**
A country manager for a newly recognised territory cannot see their revenue in the BI tool for
two weeks — until a full dbt build is triggered. Revenue is attributed to "unknown" and excluded
from regional targets. Compensation calculations for that territory are based on understated revenue.

---

### 7. Gold Layer Column Rename in Silver — Silent NULL Cascade

**What it looks like:**
Silver layer is refactored. A column named `customer_key` is renamed to `cust_key` for
consistency with a new naming convention. Gold models reference Silver using column names.

**What actually happens:**
In cloud data warehouses that allow `SELECT nonexistent_column FROM table` without error
(some Spark configurations, dynamic SQL paths, or column-aliased views), the Gold models
silently return NULL for `customer_key` because the column no longer exists. In strict-mode
warehouses (Snowflake, BigQuery), this is a compile error — but if Gold models use dynamic
column resolution or `SELECT *` with later column filtering, the NULL can propagate silently.

**Why it's insidious:**
Silver ran successfully. Gold ran successfully. The output table has all expected columns. The
values in `customer_key` are simply NULL — indistinguishable from legitimate "no customer"
attribution without a NULL rate check.

**Example:**
```sql
-- Silver: renamed customer_key → cust_key on 2024-09-01
-- Gold model (not updated):
SELECT
    customer_key,   -- silently NULL if Silver doesn't enforce column contracts
    SUM(revenue) AS revenue
FROM silver_sales
GROUP BY customer_key;
-- All Gold rows: customer_key = NULL, revenue = correct
-- Revenue attribution by customer is completely broken; totals look fine
```

**Detection query / invariant:**
```sql
-- Monitor NULL rates on key join columns after each Silver deployment
SELECT
    'customer_key' AS column_name,
    COUNT(*) AS total_rows,
    SUM(CASE WHEN customer_key IS NULL THEN 1 ELSE 0 END) AS null_rows,
    1.0 * SUM(CASE WHEN customer_key IS NULL THEN 1 ELSE 0 END) / COUNT(*) AS null_rate
FROM gold_sales
WHERE loaded_at >= CURRENT_DATE - INTERVAL '1 day';   -- check recent loads only

-- Prevention: enforce column contracts using dbt model contracts
-- or add not_null tests on all FK columns in schema.yml
```

**Real-world consequence:**
Customer-level revenue attribution is NULL in Gold for 3 days after a Silver refactor deployment.
Executive dashboard shows revenue by product but customer revenue attribution is missing. Account
managers cannot see per-customer revenue for their portfolio during a critical end-of-quarter period.

---

### 8. Partitioning Column Function Wrap Disabling Partition Pruning

**What it looks like:**
A Gold table is partitioned on `event_date`. Downstream queries filter using `EXTRACT(YEAR FROM event_date) = 2024 AND EXTRACT(MONTH FROM event_date) = 6` for June 2024 data.

**What actually happens:**
Wrapping the partition column (`event_date`) in a function (`EXTRACT`) disables partition pruning
in BigQuery and Snowflake. The query scans the entire table instead of only the June 2024
partition. No error — just massively inflated cost and scan time.

In BigQuery specifically, this is a silent correctness risk for very large tables where scans
hit processing quotas — the query may silently truncate results if it hits a cost or byte scan
limit, returning partial data without an explicit error.

**Why it's insidious:**
The query returns correct results (assuming no scan limit). The cost inflation is the main symptom
but on smaller tables is invisible. On large tables with query result limits, partial results can
be returned without warning.

**Example:**
```sql
-- WRONG: disables partition pruning
SELECT DATE_TRUNC('day', event_date), SUM(revenue)
FROM gold_events
WHERE EXTRACT(YEAR FROM event_date) = 2024
  AND EXTRACT(MONTH FROM event_date) = 6
GROUP BY 1;
-- Scans ALL partitions, not just June 2024

-- CORRECT: enables partition pruning
SELECT DATE_TRUNC('day', event_date), SUM(revenue)
FROM gold_events
WHERE event_date >= '2024-06-01' AND event_date < '2024-07-01'
GROUP BY 1;
-- Scans only June 2024 partition
```

**Detection query / invariant:**
```sql
-- BigQuery: check PARTITIONS SCANNED in query details
-- Look for queries where PARTITIONS_SCANNED = TOTAL_PARTITIONS despite a date filter

-- Snowflake: run EXPLAIN and check "partitions scanned" vs "partitions total"
EXPLAIN
SELECT * FROM gold_events
WHERE EXTRACT(YEAR FROM event_date) = 2024;
-- If partitions scanned = partitions total → pruning disabled
```

**Real-world consequence:**
A daily analytics job that should scan 1 day of data scans 3 years of data because of function
wrapping in the WHERE clause. Query cost is 1095× higher than necessary. This is not noticed until
the monthly BigQuery bill arrives — $4,200 for what should be $3.85 in compute costs.
