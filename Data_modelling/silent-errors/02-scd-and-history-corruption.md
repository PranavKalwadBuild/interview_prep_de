<!-- data-modelling-patterns: Silent Errors — SCD and History Corruption -->

<!-- Part of Data_modelling: Silent Errors — SCD and History Corruption -->

# Silent Errors — SCD and History Corruption

Slowly Changing Dimension errors are among the most dangerous silent failures because they corrupt
the historical record retroactively. Facts that were reported correctly last quarter can silently
become wrong this quarter after a dimension pipeline re-runs. These bugs survive in production
for months because they are mathematically plausible and only detectable through careful temporal
audit queries.

---

### 1. SCD Type 2 + Late-Arriving Facts (Wrong Snapshot Join)

**What it looks like:**
An SCD Type 2 dimension has `effective_from` and `effective_to` date columns. Facts join to the
dimension using a `BETWEEN` predicate to find the snapshot valid at the time of the event.

**What actually happens:**
A fact event arrives with a business date that falls between two consecutive dimension snapshots.
If the join logic uses `>= effective_from AND < effective_to` and the late fact's event_date
is slightly before the current snapshot's `effective_from`, it should join the previous snapshot.
But if the load timestamp of the late fact is later than the dimension snapshot update, the join
silently picks the newer snapshot — using attributes that did not exist at event time.

**Why it's insidious:**
Every individual row is valid. The date range join is correct syntax. The error is in the ordering
of pipeline execution versus event timing. No foreign key violation. No NULL join.

**Example:**
```sql
-- Dimension snapshot
-- effective_from=2024-01-01, effective_to=2024-06-01 → region='West'
-- effective_from=2024-06-01, effective_to=9999-12-31 → region='Northwest' (rebrand)

-- Late-arriving fact: sale occurred 2024-05-28 (should join to 'West')
-- But fact arrives in the warehouse on 2024-07-10 (after pipeline already closed old snapshot)

SELECT
    fs.sale_date,
    dc.region        -- silently returns 'Northwest' instead of 'West'
FROM fact_sales fs
JOIN dim_customer dc
  ON fs.customer_key = dc.customer_key
  AND fs.sale_date BETWEEN dc.effective_from AND dc.effective_to;
-- If late fact's event_date overlaps a gap or off-by-one boundary, wrong snapshot is used
```

**Detection query / invariant:**
```sql
-- Check for facts whose event_date is outside all effective ranges for their customer_key
SELECT
    fs.sale_id,
    fs.sale_date,
    fs.customer_key
FROM fact_sales fs
WHERE NOT EXISTS (
    SELECT 1 FROM dim_customer dc
    WHERE dc.customer_key = fs.customer_key
      AND fs.sale_date >= dc.effective_from
      AND fs.sale_date < dc.effective_to
);
-- Any row here joined to the wrong snapshot or was silently dropped
```

**Real-world consequence:**
Historical revenue-by-region reports silently attribute May sales to "Northwest" (the post-rebrand
region). The rebrand is assessed as having an immediate positive revenue impact — actually it was
already in the pipeline before the rebrand.

---

### 2. SCD Type 2 `effective_to` Overlap from Same-Batch Dual Update

**What it looks like:**
Two dimension updates for the same natural key arrive in the same ETL batch. The pipeline uses
`LAG(effective_from) OVER (PARTITION BY natural_key ORDER BY effective_from)` to set `effective_to`.

**What actually happens:**
Both records have `effective_from = batch_date`. The LAG of the second record is `batch_date`.
So `effective_to = batch_date = effective_from` — a zero-duration record. The intermediate
dimension state is permanently invisible because `effective_to = effective_from` means no fact
can ever satisfy `event_date >= effective_from AND event_date < effective_to` for this record.

**Why it's insidious:**
The pipeline runs without error. The dimension table has valid rows. A count of dimension rows
looks correct. The zero-duration row is only visible when you query for `effective_to = effective_from`.

**Example:**
```sql
-- Two updates arrive in the same batch for customer_key=1001
-- After LAG calculation:
-- Row 1: effective_from=2024-09-01, effective_to=2024-09-01  (zero-duration — invisible)
-- Row 2: effective_from=2024-09-01, effective_to=9999-12-31  (current)
-- The intermediate state between Row 1 and the previous row is permanently lost

-- Any fact between the previous effective_to and 2024-09-01 joins to the pre-batch state
-- The intermediate update is permanently missing from the history
```

**Detection query / invariant:**
```sql
-- Find zero-duration SCD2 records
SELECT
    customer_key,
    natural_key,
    effective_from,
    effective_to
FROM dim_customer
WHERE effective_to = effective_from   -- zero-duration ghost record
   OR effective_to < effective_from;  -- impossible inverted record

-- Also check for gaps (periods not covered by any snapshot)
SELECT a.customer_key, a.effective_to AS gap_start, b.effective_from AS gap_end
FROM dim_customer a
JOIN dim_customer b ON a.customer_key = b.customer_key
  AND b.effective_from > a.effective_to
WHERE NOT EXISTS (
    SELECT 1 FROM dim_customer c
    WHERE c.customer_key = a.customer_key
      AND c.effective_from > a.effective_to
      AND c.effective_from <= b.effective_from
);
```

**Real-world consequence:**
A customer changed their account tier twice in one day (Bronze → Silver → Gold via two API events
hitting the batch in the same window). The Silver tier never appears in history. Revenue
attributed to Silver tier for that customer is silently zero.

---

### 3. SCD Type 2 Full-Refresh Surrogate Key Wipe

**What it looks like:**
The SCD Type 2 pipeline is re-run with `--full-refresh`. A new set of surrogate keys is generated
(auto-increment or hash-based) for all dimension records. The dimension table is dropped and rebuilt.

**What actually happens:**
The fact table still holds the old surrogate keys. After the full refresh, those surrogate keys
either don't exist in the new dimension (broken foreign key — no error if FK is not enforced) or
they exist but map to completely different dimension records (if using a hash-based key that was
regenerated from the same natural keys — keys are the same but the row ordering or hash seed
changed). Fact-to-dimension joins silently return wrong attribute values or NULL.

**Why it's insidious:**
No foreign key constraints in most cloud data warehouses (Snowflake, BigQuery, Redshift do not
enforce FK by default). Queries run, return rows, produce numbers. The numbers are just wrong.

**Example:**
```sql
-- Before full refresh: surrogate_key=101 → customer='Acme Corp', region='West'
-- After full refresh:  surrogate_key=101 → customer='Beta LLC',  region='East'
--                      (auto-increment restarted from 1 — same integer, different entity)

-- Fact table still has surrogate_key=101 for Acme's transactions
-- After refresh, those transactions are attributed to Beta LLC
SELECT dc.customer_name, SUM(fs.revenue)
FROM fact_sales fs
JOIN dim_customer dc ON fs.customer_key = dc.surrogate_key
GROUP BY dc.customer_name;
-- 'Acme Corp' disappears from reports; 'Beta LLC' gets Acme's revenue added to its own
```

**Detection query / invariant:**
```sql
-- After a dimension reload, check that natural keys in dimension match natural keys
-- cross-referenced from the fact table (via a staging or source join)
SELECT
    fs.customer_natural_key,           -- if stored on fact
    dc.natural_key AS dim_natural_key
FROM fact_sales fs
JOIN dim_customer dc ON fs.customer_key = dc.surrogate_key
WHERE fs.customer_natural_key <> dc.natural_key
LIMIT 100;
-- Any mismatch = surrogate key reassignment corruption
```

**Real-world consequence:**
A full-refresh run on a Friday evening silently reassigns all historical fact revenue to different
customers. Monday morning revenue-per-customer reports show dramatic shifts. Several hours of
incident response trace the cause to the weekend pipeline run.

---

### 4. SCD Type 1 Applied to a Reporting Attribute (Retroactive Rewrite)

**What it looks like:**
A customer `segment` column is updated in-place (Type 1 / overwrite) when the customer moves
from one segment to another. The dim table always shows the current segment. Fact tables join
to the dim table at query time.

**What actually happens:**
All historical fact rows for that customer now report the new segment — even transactions from
years ago. Revenue attribution by segment is silently rewritten every time a customer changes
segment. Historical trend analysis compares different customer cohorts under old vs. new segment
labels.

**Why it's insidious:**
The dimension update was deliberate. The developer applied Type 1 because segment was considered
"correctable." The business impact (retroactive revenue reattribution) was never considered.
No error. No data anomaly. Just wrong history.

**Example:**
```sql
-- Customer 1001 was 'SMB' from 2022–2024, upgraded to 'Enterprise' in 2024

-- Type 1 update:
UPDATE dim_customer SET segment = 'Enterprise' WHERE customer_id = 1001;

-- Now all historical revenue is attributed to 'Enterprise'
SELECT segment, YEAR(sale_date) AS yr, SUM(revenue)
FROM fact_sales fs JOIN dim_customer dc ON fs.customer_key = dc.customer_key
GROUP BY segment, yr;
-- 2022 and 2023 rows for customer 1001 now show 'Enterprise', not 'SMB'
-- SMB 2022 revenue is understated; Enterprise 2022 revenue is overstated
```

**Detection query / invariant:**
```sql
-- If the segment was truly Type 1 correctable, no history should matter.
-- But if you have a separate audit or event log, cross-check:
SELECT
    al.customer_id,
    al.segment_at_event_time,
    dc.segment AS current_segment
FROM customer_audit_log al
JOIN dim_customer dc ON al.customer_id = dc.customer_id
WHERE al.segment_at_event_time <> dc.segment;
-- Mismatches = Type 1 overwrote analytically meaningful history
```

**Real-world consequence:**
A year-over-year SMB vs Enterprise revenue comparison shows SMB declining and Enterprise growing
faster than expected. Leadership launches an SMB retention program. The real cause is that high-value
SMB customers graduated to Enterprise — and their entire historical revenue followed them retroactively.

---

### 5. SCD Type 6 Stale `current_*` Columns from Failed Partial Update

**What it looks like:**
SCD Type 6 stores both the historical attribute per version (`region`) and the current-as-of-today
attribute (`current_region`) on every row. The `current_region` is updated via a separate UPDATE
statement after each dimension change.

**What actually happens:**
The MERGE that inserts the new dimension version succeeds. The subsequent UPDATE that sets
`current_region` on all historical rows fails (timeout, mid-pipeline error, partial commit).
Historical rows still show `current_region = 'West'` while the new row shows `current_region = 'Northwest'`.
Queries filtering on `current_region` return inconsistent results depending on which rows they touch.

**Why it's insidious:**
The MERGE succeeded. The pipeline logged success. Only the secondary UPDATE silently left stale
values. Row counts are correct. Data type checks pass.

**Example:**
```sql
-- Type 6 table structure
-- customer_key | effective_from | region | current_region
-- After partial update:
-- 1001, 2022-01-01, 'West', 'West'           -- stale: should be 'Northwest'
-- 1001, 2024-01-01, 'West', 'Northwest'      -- current: 'Northwest' (correct on new row)
-- 1001, 2024-06-01, 'Northwest', 'Northwest' -- new row: correct

-- Query using current_region to filter (should return only current records):
SELECT customer_key, current_region, SUM(revenue)
FROM fact_sales fs JOIN dim_customer dc ON fs.customer_key = dc.customer_key
WHERE dc.current_region = 'West'    -- pulls old historical row + stale current_region rows
GROUP BY customer_key, current_region;
```

**Detection query / invariant:**
```sql
-- current_region should be the same for ALL rows of a given customer_key
SELECT customer_key, COUNT(DISTINCT current_region) AS distinct_current_values
FROM dim_customer
GROUP BY customer_key
HAVING COUNT(DISTINCT current_region) > 1;
-- Any result here = stale current_* values from a partial Type 6 update
```

**Real-world consequence:**
A dashboard filtering on `current_region = 'Northwest'` misses 40% of records for the affected
customers because their historical rows still say 'West'. Regional managers see lower-than-expected
numbers and attribute it to a reporting delay rather than a data corruption.

---

### 6. Surrogate Key Hash Collision (MD5 at Scale)

**What it looks like:**
Surrogate keys are generated using `MD5(natural_key)` or `MD5(CONCAT(col1, col2, col3))`. The
hash is used as the primary key of the dimension and as the foreign key on the fact table.

**What actually happens:**
At sufficient scale (tens or hundreds of millions of distinct natural keys), two different natural
keys hash to the same MD5 value. The dimension table either raises a PK violation (detectable) or,
if deduplication logic silently discards one, merges two distinct real-world entities under one
surrogate key. All facts for both entities now join to the same dimension record.

**Why it's insidious:**
MD5 produces 128-bit hashes. The birthday paradox probability of collision reaches ~50% at ~2^64
inputs (~18 quintillion) — far beyond most datasets. But partial-MD5 (using UPPER or LOWER 64 bits
in Snowflake) reaches 50% collision probability at ~4 billion rows — well within large-scale
data warehouse ranges. When a collision occurs and the PK constraint is absent, no error surfaces.

**Example:**
```sql
-- Surrogate key generation
SELECT
    MD5(CONCAT(customer_id, '|', source_system)) AS customer_sk,
    customer_id,
    source_system,
    customer_name
FROM staging_customers;

-- If customer_id='92849372', source='US' and customer_id='00113958', source='EU'
-- hash to the same MD5, dim_customer will have one row
-- All 'EU' customer facts now join to the 'US' customer dimension record
```

**Detection query / invariant:**
```sql
-- After dimension load, verify hash uniqueness against natural key
SELECT
    customer_sk,
    COUNT(DISTINCT natural_key) AS distinct_natural_keys
FROM dim_customer
GROUP BY customer_sk
HAVING COUNT(DISTINCT natural_key) > 1;
-- Any result = hash collision

-- Prevention: use SHA-256 instead of MD5, or concatenate a salt
SELECT SHA2(CONCAT(customer_id, '|', source_system, '|', 'v2'), 256) AS customer_sk ...
```

**Real-world consequence:**
Two customers — one a small domestic account, one a large international enterprise — get merged
under one surrogate key. The enterprise customer's high-value transactions are attributed to the
small domestic account. The enterprise account appears to have $0 in the warehouse. Contract
renewal is mishandled because the account manager's view shows no transaction history.

---

### 7. SCD Close Logic Using `CURRENT_DATE` Instead of Batch Load Timestamp

**What it looks like:**
When a new dimension version is inserted, the previous version's `effective_to` is set to
`CURRENT_DATE` (or `GETDATE()`, `NOW()`).

**What actually happens:**
If the pipeline runs at 11:59 PM on a Wednesday and the batch processes records from Monday
through Wednesday, records closed on Wednesday look like they were valid through end-of-day
Wednesday — even if the source change occurred Monday morning. If the pipeline fails and reruns
on Friday, `CURRENT_DATE` is now Friday — meaning records look like they were valid Thursday
and Friday when they were not.

**Why it's insidious:**
`CURRENT_DATE` seems like a natural way to set "closed as of today." The error only appears when
comparing close dates against actual source change timestamps in an audit query.

**Example:**
```sql
-- Closing old dimension version
UPDATE dim_customer
SET effective_to = CURRENT_DATE        -- BUG: should be the batch's data_as_of date
WHERE customer_key = 1001
  AND current_flag = 'Y';

-- If the source changed 3 days ago and pipeline ran today:
-- effective_to = today (3 days too late)
-- Historical facts from those 3 days are attributed to the wrong dimension version
```

**Detection query / invariant:**
```sql
-- Compare dimension close dates against the actual source change event dates
SELECT
    dc.customer_key,
    dc.effective_to              AS dimension_close_date,
    src.attribute_change_date    AS source_change_date,
    DATEDIFF('day', src.attribute_change_date, dc.effective_to) AS drift_days
FROM dim_customer dc
JOIN source_customer_changelog src ON dc.natural_key = src.customer_id
WHERE dc.effective_to <> '9999-12-31'
  AND ABS(DATEDIFF('day', src.attribute_change_date, dc.effective_to)) > 1;
-- > 1 day drift = CURRENT_DATE vs batch timestamp mismatch
```

**Real-world consequence:**
A customer who moved from 'West' to 'East' on Monday is still attributed to 'West' through Friday
in the historical record because the pipeline ran Friday and used `CURRENT_DATE=Friday` as the
close date for the Monday snapshot. Regional P&L has 4 extra days of revenue in the wrong region.

---

### 8. SCD Type 3 Overused — "Current" and "Previous" Columns Desynchronise

**What it looks like:**
SCD Type 3 stores both `current_region` and `previous_region` on a single row per customer.
A pipeline updates `current_region` to the new value and copies old `current_region` to
`previous_region`. This handles one level of history.

**What actually happens:**
A third change arrives. The pipeline correctly sets `current_region = 'Northwest'` and
`previous_region = 'West'`. But the second change ('East' → 'West') is permanently lost because
Type 3 can only hold one level of history. Queries comparing `current_region` vs `previous_region`
now compare the third and first states, skipping the second — with no indication that a middle
state existed.

**Why it's insidious:**
Type 3 is often chosen deliberately for simplicity. The pipeline logic works perfectly for one
change. A second change produces silently wrong "before/after" comparisons. No error is raised.
The middle dimension state is permanently lost.

**Example:**
```sql
-- Customer history: East → West (Oct) → Northwest (Dec)
-- After Type 3 update in December:
-- current_region = 'Northwest', previous_region = 'West'
-- The 'East' state is gone forever

-- A "region movement" report comparing previous vs current:
SELECT previous_region, current_region, COUNT(*) AS customers
FROM dim_customer GROUP BY previous_region, current_region;
-- Shows East→Northwest as if customers jumped directly; West period invisible
```

**Detection query / invariant:**
```sql
-- No direct detection SQL exists — the middle state is unrecoverable.
-- Prevention: maintain a separate audit log or change event table
-- Detection of the pattern: check if any customers have had more than 2 changes
SELECT customer_id, COUNT(*) AS change_count
FROM source_customer_changelog
GROUP BY customer_id
HAVING COUNT(*) > 2;
-- These customers have guaranteed history loss in a Type 3 design
```

**Real-world consequence:**
A geographic market expansion analysis compares "previous region" vs "current region" to calculate
customer migration between regions. Customers who moved twice appear to have made direct jumps,
overstating migration from distant regions and understating local migration.
