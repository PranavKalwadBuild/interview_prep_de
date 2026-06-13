<!-- Part of sql-patterns: Silent Errors — Platform-Specific: Snowflake -->

# Silent Errors — Platform-Specific: Snowflake

Snowflake introduces its own class of silent errors on top of the standard SQL gotchas. VARIANT semi-structured handling, session parameters that control core SQL behavior, and Snowflake-specific functions with non-obvious defaults are responsible for a distinct category of bugs that only appear in Snowflake environments. Most of these bugs produce NULL or silently wrong results without any error message.

---

### VARIANT :: Cast — Float String to INT Returns NULL, Not an Error

**What it looks like:**
```sql
SELECT
    event_data:amount::INT AS amount
FROM events;
```

**What actually happens:** If `event_data:amount` is stored in JSON as `1.5` (a JSON number with decimal) or `"1.5"` (a JSON string), the `::INT` cast returns NULL. Snowflake cannot directly cast a float-valued or float-string VARIANT to INT. No error is raised — just NULL silently propagated through all downstream calculations.

**Why it's insidious:** If most records have integer amounts (`100`, `200`), the cast works correctly for those rows and the column appears populated. Only the records with decimal amounts silently become NULL. `SUM(amount)` excludes those rows. A report of total revenue shows a number slightly lower than reality, with no indication of missing rows.

**Minimal repro:**
```sql
SELECT
    PARSE_JSON('{"amount": 100}'):amount::INT     AS int_ok,           -- 100
    PARSE_JSON('{"amount": 1.5}'):amount::INT     AS float_to_int,     -- NULL (silent!)
    PARSE_JSON('{"amount": "1.5"}'):amount::INT   AS str_float_to_int, -- NULL (silent!)
    PARSE_JSON('{"amount": 1.5}'):amount::FLOAT::INT   AS float_safe,  -- 1 (truncated, but works)
    TRY_CAST(PARSE_JSON('{"amount": "1.5"}'):amount::STRING AS FLOAT)::INT AS str_safe -- 1
```

**How to catch it:**
```sql
-- Always use TRY_CAST for VARIANT values where type is uncertain:
SELECT TRY_CAST(event_data:amount::STRING AS INT) AS amount_int
FROM events;
-- TRY_CAST returns NULL on failure — same as ::INT — but makes the intent explicit.

-- Detect NULL bleeding from VARIANT casts:
SELECT
    COUNT(*) AS total_rows,
    COUNT(event_data:amount::INT) AS non_null_int_casts,
    COUNT(*) - COUNT(event_data:amount::INT) AS silently_null
FROM events;
-- If silently_null > 0, investigate what the non-integer values look like:
SELECT DISTINCT TYPEOF(event_data:amount) FROM events;
```

**Real-world trigger:** Payment webhook events from two processors. Processor A always sends integer amounts (`100`). Processor B sends amounts with cents as floats (`100.50`). Processor B's revenue is silently NULL in every `::INT` cast. Total revenue is understated by exactly Processor B's volume — which happens to be the largest processor.

---

### FLATTEN with OUTER => FALSE (Default) — Rows with Empty/NULL Arrays Silently Dropped

**What it looks like:**
```sql
SELECT
    u.user_id,
    f.value::STRING AS tag
FROM users u,
     LATERAL FLATTEN(input => u.tags) f;
```

**What actually happens:** `FLATTEN` with default `OUTER => FALSE` completely omits any row where the input array is NULL or empty `[]`. Users with no tags silently disappear from the result. If the intent is to show all users (even tagless ones) with NULL for the tag column, the query silently produces a subset of users.

**Why it's insidious:** The result looks complete. If most users have tags, the row count is close to the expected total. Only users with zero tags are missing — which may be a minority. The bug only surfaces when comparing row counts between this table and the users source.

**Minimal repro:**
```sql
WITH users AS (
    SELECT * FROM (VALUES
        (1, PARSE_JSON('["vip","active"]')),
        (2, PARSE_JSON('["new"]')),
        (3, PARSE_JSON('[]')),              -- empty array
        (4, NULL::VARIANT)                  -- NULL array
    ) t(uid, tags)
)
SELECT u.uid, f.value
FROM users u,
LATERAL FLATTEN(input => u.tags) f;
-- Returns: uid=1 (twice), uid=2 (once)
-- MISSING: uid=3 and uid=4 silently dropped!

-- With OUTER => TRUE:
SELECT u.uid, f.value
FROM users u,
LATERAL FLATTEN(input => u.tags, OUTER => TRUE) f;
-- Returns: uid=1 (twice), uid=2 (once), uid=3 (NULL), uid=4 (NULL)
```

**How to catch it:**
```sql
-- Invariant: FLATTEN result distinct users should equal source users count:
SELECT COUNT(DISTINCT user_id) FROM flatten_result;
SELECT COUNT(*) FROM users;
-- If flatten_result < users, rows were dropped by FLATTEN.
```

**Real-world trigger:** User segmentation model unnests behavioral tags for each user. Users with no behavioral data (new users, churned users) have empty or NULL tag arrays. They silently disappear from the segmentation output. Campaigns targeted at "all users" miss 15% of the user base — the users with no behavioral history, who are exactly the high-priority reactivation targets.

---

### COPY INTO with MATCH_BY_COLUMN_NAME — Case Mismatch Loads NULL

**What it looks like:**
```sql
COPY INTO orders
FROM @my_stage/orders.parquet
FILE_FORMAT = (TYPE = PARQUET)
MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE;
```

**What actually happens:** `CASE_INSENSITIVE` matches `UserID` in the file to `USERID` in the table. But if the Parquet file has a column named `user_id` (snake_case) and the Snowflake table has `USERID` (no underscore), the names don't match — they are not case variations of the same name. Snowflake silently loads NULL into the `USERID` column for every row instead of erroring.

**Why it's insidious:** The COPY INTO succeeds. Row counts are correct. The column exists in the target table. The values are just silently NULL. A downstream query that filters `WHERE USERID IS NOT NULL` silently returns zero rows.

**Minimal repro:**
```sql
-- Parquet file schema: {user_id: int, amount: float}
-- Target table schema: (USERID INT, AMOUNT FLOAT)

COPY INTO my_table (USERID, AMOUNT)
FROM @stage/file.parquet
MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE;
-- 'user_id' (snake_case) != 'USERID' (no underscore)
-- USERID column loaded with NULL for all rows. No error.

-- Fix: either rename the Parquet column to match, or use positional COPY:
COPY INTO my_table FROM (SELECT $1:user_id::INT, $1:amount::FLOAT FROM @stage/file.parquet)
```

**How to catch it:**
```sql
-- After COPY INTO, validate that key columns are not unexpectedly NULL:
SELECT COUNT(*) AS total, COUNT(USERID) AS non_null_userid
FROM my_table
WHERE _load_timestamp = CURRENT_DATE;
-- If non_null_userid < total, column name mismatch occurred.
```

**Real-world trigger:** A vendor-provided Parquet export uses snake_case column names. The Snowflake staging table was created with PascalCase names. MATCH_BY_COLUMN_NAME=CASE_INSENSITIVE is used expecting it to handle any naming convention. All JOIN keys load as NULL. Every downstream join to this table returns zero rows. Load appears successful — zero errors in the COPY history.

---

### Snowflake Clustering Key Pruning Bypass — Silent Full Table Scan

**What it looks like:**
```sql
-- Table is clustered on ts (TIMESTAMP_NTZ)
SELECT * FROM events WHERE DATE(ts) = '2024-01-15';
```

**What actually happens:** The clustering key is `ts` (the raw timestamp). `DATE(ts)` creates a derived expression — Snowflake cannot use micro-partition pruning on a derived expression. The query silently performs a full table scan instead of pruning to only the micro-partitions containing `2024-01-15` data.

**Why it's insidious:** The query returns correct results. It's just 100–1000× slower than it should be, and consumes far more credits than expected. The silence comes from the fact that no error is raised, no warning is issued, and the QUERY PROFILE may not obviously flag "clustering key not used" unless you know to look for it.

**Minimal repro:**
```sql
-- Query that bypasses clustering:
SELECT COUNT(*) FROM events WHERE DATE(ts) = '2024-01-15';
-- Full scan of entire table

-- Query that uses clustering:
SELECT COUNT(*) FROM events
WHERE ts >= '2024-01-15'::TIMESTAMP
  AND ts  < '2024-01-16'::TIMESTAMP;
-- Micro-partition pruning active, reads only relevant partitions
```

**How to catch it:**
```sql
-- Check the query profile for "Partitions scanned" vs "Partitions total":
-- In Snowflake UI: Query Details → Profile → TableScan node
-- Partitions scanned should be << Partitions total for clustered queries.

-- Alternatively: use SYSTEM$CLUSTERING_INFORMATION to understand clustering depth:
SELECT SYSTEM$CLUSTERING_INFORMATION('events', '(ts)');

-- Rule: never apply a function to a clustering key column in a WHERE clause.
-- Use range predicates on the raw column instead.
```

**Real-world trigger:** Daily event processing query on a 10TB events table. Cluster key is `event_timestamp`. An analyst adds `WHERE DATE(event_timestamp) = CURRENT_DATE` for readability. Query cost jumps from 5 credits (pruned) to 2,000 credits (full scan) daily. Cloud cost spike is noticed in the monthly billing review, not in query behavior.

---

### Snowflake TIMESTAMP_NTZ vs TIMESTAMP_LTZ in JOIN — Session Timezone Shift Causes JOIN Miss

**What it looks like:**
```sql
-- Table A: event_time TIMESTAMP_NTZ (wall-clock, no timezone)
-- Table B: session_time TIMESTAMP_LTZ (stored as UTC, displayed in session TZ)
SELECT a.*, b.*
FROM events a
JOIN sessions b ON a.event_time = b.session_time;
```

**What actually happens:** When comparing `TIMESTAMP_NTZ` to `TIMESTAMP_LTZ`, Snowflake converts the `TIMESTAMP_NTZ` value to `TIMESTAMP_LTZ` using the current session timezone. If the session is set to `America/New_York` (UTC-5), `event_time = '2024-01-15 12:00:00'::NTZ` is treated as `'2024-01-15 12:00:00 EST'` = `'2024-01-15 17:00:00 UTC'` for the comparison.

If `session_time` stores `'2024-01-15 12:00:00 UTC'` (the same physical moment but in UTC), they are now 5 hours apart in the comparison. The JOIN produces zero matches. No error.

**Minimal repro:**
```sql
ALTER SESSION SET TIMEZONE = 'America/New_York';

WITH events AS (
    SELECT '2024-01-15 12:00:00'::TIMESTAMP_NTZ AS etime  -- wall clock noon
),
sessions AS (
    SELECT '2024-01-15 12:00:00 +0000'::TIMESTAMP_LTZ AS stime  -- UTC noon
)
SELECT *
FROM events e JOIN sessions s ON e.etime = s.stime;
-- 0 rows: NTZ noon is treated as EST noon = 17:00 UTC, which != UTC noon
```

**How to catch it:**
```sql
-- Always JOIN timestamp columns of the same type.
-- If mixing is unavoidable, explicitly convert NTZ to UTC:
ON CONVERT_TIMEZONE('UTC', a.event_time) = CONVERT_TIMEZONE('UTC', b.session_time)

-- Or: standardize all timestamps to TIMESTAMP_NTZ UTC at ingestion time.

-- Detection:
SELECT COUNT(*) FROM events a
LEFT JOIN sessions b ON a.event_time = b.session_time
WHERE b.session_time IS NULL;
-- High count here, combined with low count on a TIMESTAMP_NTZ-to-NTZ join, signals the bug.
```

**Real-world trigger:** Session attribution model JOINs page events (NTZ, stored as wall-clock) to user sessions (LTZ, stored as UTC in the auth system). Session timezone is set to `America/Chicago` in the ETL container. The JOIN misses all session matches because the 6-hour offset causes every event timestamp to not match any session timestamp. Revenue attribution is zero for all events. The model appears to show zero attributed sessions for all users.

---

### Snowflake SEARCH OPTIMIZATION Not Applying — Silent Full Scan on Equality Predicate

**What it looks like:**
```sql
-- Search optimization added to a VARIANT column
ALTER TABLE events ADD SEARCH OPTIMIZATION ON EQUALITY(event_data:user_id);
-- Then query:
SELECT * FROM events WHERE event_data:user_id::STRING LIKE 'usr_%';
```

**What actually happens:** Snowflake Search Optimization for VARIANT columns only activates for **equality** predicates (`=`). Range predicates (`<`, `>`), LIKE predicates, and function applications do not benefit from Search Optimization. The optimization is silently inactive for the LIKE predicate. The query performs a full scan as if Search Optimization was never configured. No warning is issued.

**Why it's insidious:** The `ALTER TABLE ADD SEARCH OPTIMIZATION` command succeeds. The cost is charged (search optimization has a storage cost). The optimization appears in `SHOW TABLES` with `SEARCH_OPTIMIZATION = YES`. But the predicate type doesn't qualify, so the optimization is silently bypassed.

**Minimal repro:**
```sql
-- Check if Search Optimization is being used for a query:
EXPLAIN SELECT * FROM events WHERE event_data:user_id = 'usr_12345';
-- Look for "SearchOptimization" node in the plan (present for equality predicates)

EXPLAIN SELECT * FROM events WHERE event_data:user_id::STRING LIKE 'usr_%';
-- "SearchOptimization" node ABSENT — full scan despite SO being configured
```

**How to catch it:**
```sql
-- After adding Search Optimization, always run EXPLAIN to confirm it activates:
EXPLAIN <your_query>;
-- If you don't see a "SearchOptimization" node in the plan, SO is not applying.

-- Qualifying predicates for Search Optimization on VARIANT:
-- equality: v:field = 'value'          ✓
-- IN list: v:field IN ('a', 'b')       ✓
-- IS NULL / IS NOT NULL                ✓
-- LIKE / ILIKE / range                 ✗ (no SO benefit)
```

**Real-world trigger:** Engineering team adds Search Optimization to a 50TB events table for a "fast lookup by user ID" feature. The application query uses `WHERE payload:user_id LIKE CONCAT(user_id_prefix, '%')` for prefix search. SO is silently inactive. Queries take 45 seconds instead of the expected 50ms. The 45-second latency is only discovered in load testing.

---

### Snowflake JSON NULL vs SQL NULL Confusion — IS NULL Misses JSON Nulls

**What it looks like:**
```sql
SELECT *
FROM events
WHERE event_data:email IS NULL;
```

**What actually happens:** There are two distinct types of "null" in Snowflake VARIANT columns:
1. **SQL NULL**: the entire path is missing, or the VARIANT column itself is SQL NULL.
2. **JSON null** (`null`): the path exists and explicitly contains the JSON null value.

`IS NULL` only catches SQL NULL. If the JSON is `{"email": null}`, the path `event_data:email` returns a VARIANT with a JSON null value — not a SQL NULL. `event_data:email IS NULL` returns FALSE. `IS_NULL_VALUE(event_data:email)` returns TRUE.

This means filtering for "missing email" with `IS NULL` silently misses all records where email was explicitly set to JSON null.

**Minimal repro:**
```sql
WITH events AS (
    SELECT * FROM (VALUES
        (PARSE_JSON('{"email": "a@b.com"}')),
        (PARSE_JSON('{"email": null}')),         -- JSON null
        (PARSE_JSON('{}'))                        -- field missing (SQL NULL when accessed)
    ) t(event_data)
)
SELECT
    event_data:email                             AS email_value,
    event_data:email IS NULL                     AS is_sql_null,     -- FALSE for JSON null
    IS_NULL_VALUE(event_data:email)              AS is_json_null,    -- TRUE for JSON null
    event_data:email IS NULL
        OR IS_NULL_VALUE(event_data:email)       AS truly_null       -- catches both
FROM events;
```

**How to catch it:**
```sql
-- Always check for both SQL NULL and JSON null in VARIANT columns:
WHERE event_data:email IS NULL OR IS_NULL_VALUE(event_data:email)

-- Count how many records have JSON null specifically:
SELECT COUNT(*) FROM events WHERE IS_NULL_VALUE(event_data:email);
-- If > 0, IS NULL alone misses these records in your filters.
```

**Real-world trigger:** GDPR data erasure pipeline identifies users with NULL email (to stop email marketing). The erasure system sets `{"email": null}` explicitly in the source JSON. Snowflake's `IS NULL` filter misses all explicitly-erased emails. Marketing emails continue to be sent to users who formally requested erasure.

---

### Snowflake SECURE VIEW vs Regular View — Different Row-Level Filter Behavior

**What it looks like:**
```sql
CREATE SECURE VIEW user_summary AS
SELECT user_id, name, email, plan
FROM users
WHERE plan != 'internal';  -- hide internal test accounts
```

**What actually happens:** A SECURE VIEW in Snowflake prevents the query optimizer from pushing predicates through the view for performance. This is intentional for security. However, a side effect is that certain join pushdowns or filter optimizations available in regular views are silently disabled. In edge cases, this can cause the view to return different row sets than a regular view with identical SQL — specifically when the optimizer would normally use index-style pruning that SECURE VIEW disables.

More commonly: developers write logic in the SECURE VIEW definition that contains the bugs documented elsewhere in this guide (NULL filter, type coercion) without realizing the secure view's overhead means they cannot EXPLAIN the plan as easily to debug.

**Why it's insidious:** The SECURE VIEW prevents `SHOW CREATE VIEW` to external users — which also prevents detecting bugs in the view definition from outside the object owner context. Bugs in secure views are harder to find because the definition is hidden.

**How to catch it:**
```sql
-- As the view owner, inspect the definition:
SELECT GET_DDL('VIEW', 'USER_SUMMARY');

-- Validate row counts of SECURE VIEW vs expected source row count:
SELECT COUNT(*) FROM user_summary;
SELECT COUNT(*) FROM users WHERE plan != 'internal';
-- Should be equal. If not, the WHERE clause has NULL or type issues.

-- Test NULL behavior explicitly:
SELECT COUNT(*) FROM users WHERE plan IS NULL;
-- If > 0, 'plan != internal' silently excludes NULL-plan users.
```

**Real-world trigger:** Compliance team uses a SECURE VIEW to expose user data to a third-party analytics vendor. The view definition has `WHERE status != 'deleted'`. Users with NULL status (created before the status column was added) are silently excluded from the third-party analytics. The vendor's user count is consistently 8% lower than internal counts. Discrepancy is attributed to "vendor methodology differences" for 4 months.
