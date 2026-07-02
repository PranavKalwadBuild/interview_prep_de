<!-- sql-patterns: Silent Errors — Type Coercion and Casting -->

# Silent Errors — Type Coercion and Casting

SQL engines will convert between types on your behalf rather than fail. This implicit helpfulness is the source of an entire class of silent wrong results: the engine does the conversion, returns a number, and you never know the conversion changed the answer.

---

### VARCHAR Numeric Comparison — Lexicographic vs Numeric Order

**What it looks like:**
```sql
SELECT * FROM orders WHERE order_id > '9';
```

**What actually happens:** If `order_id` is stored as VARCHAR, comparison is lexicographic (character-by-character, left to right). `'10'` < `'9'` because `'1'` < `'9'`. `'100'` < `'9'`. The filter silently misclassifies the majority of IDs in the range 10–99999.


**Minimal repro:**
```sql
WITH ids AS (SELECT * FROM (VALUES ('1'),('9'),('10'),('100'),('2')) t(id))
SELECT id FROM ids WHERE id > '9' ORDER BY id;
-- Returns nothing (lexicographically, '10' < '9', '100' < '9', etc.)

SELECT id FROM ids ORDER BY id;           -- '1','10','100','2','9'  (lexicographic)
SELECT id FROM ids ORDER BY id::INT;      -- 1,2,9,10,100            (numeric)
```

**How to catch it:**
```sql
-- Detect numeric data stored as VARCHAR
SELECT column_name, data_type
FROM information_schema.columns
WHERE table_name = 'orders' AND column_name = 'order_id';

-- Spot-check: does ORDER BY produce unexpected sequence?
SELECT order_id FROM orders ORDER BY order_id LIMIT 20;
-- If you see '10' before '2', it's lexicographic.
```

**Real-world trigger:** Legacy system migration. Order IDs were BIGINT in the old system, landed as VARCHAR in the new warehouse via a JSON pipeline. Range queries on order IDs silently return wrong sets for 6 months.

---

### Integer Division Truncation — 1/2 = 0

**What it looks like:**
```sql
SELECT
    clicks / impressions AS ctr,
    revenue / orders     AS revenue_per_order
FROM campaign_metrics;
```

**What actually happens:** When both operands are integers, SQL performs integer division: the result is truncated toward zero with no rounding. `1 / 2 = 0`. `47 / 638 = 0`. Every ratio smaller than 1.0 silently becomes zero.

**Why it's insidious:** The query runs. The column is populated. The values are `0.000000` or `0` — plausible if the metric genuinely could be zero. Reports showing CTR = 0.00% for all campaigns look like a data quality problem, not a type problem.

**Minimal repro:**
```sql
SELECT
    1 / 2                     AS int_div,      -- 0
    1.0 / 2                   AS float_div,    -- 0.5
    CAST(1 AS FLOAT) / 2      AS cast_div,     -- 0.5
    1 / NULLIF(2, 0)          AS nullif_div    -- 0  (still integer division!)
```

**How to catch it:**
```sql
-- Detection: are all your rates 0?
SELECT COUNT(*) FROM campaign_metrics WHERE ctr = 0;

-- Fix: cast at least one operand before division
SELECT
    clicks::FLOAT / NULLIF(impressions, 0) AS ctr
FROM campaign_metrics;
```

**Real-world trigger:** Analytics engineer ports a metric from Python to SQL. In Python `1/2 = 0.5`. In SQL `1/2 = 0`. The CTR column in the warehouse returns 0 for all campaigns with fewer clicks than impressions, which is most campaigns during warm-up.

---

### Implicit DATE/TIMESTAMP Cast Timezone Shift on Write

**What it looks like:**


**Why it's insidious:** The value returned looks like a valid timestamp. The shift only surfaces when two sessions with different timezone settings compare results, or when a timestamp comparison crosses a timezone boundary.


**How to catch it:**

**Real-world trigger:** ETL pipeline runs in a container set to UTC. Source application is running in EST. Timestamps are ingested without timezone tagging. All event timestamps are silently 5 hours off. Time-series joins to session data from another system produce zero-match JOIN results for entire hours of each day.

---

### DECIMAL Precision Loss on JOIN Keys

**What it looks like:**
```sql
-- Table A: product_id NUMERIC(18,6)
-- Table B: product_id NUMERIC(18,4)
SELECT a.*, b.price
FROM table_a a
JOIN table_b b ON a.product_id = b.product_id;
```


**Why it's insidious:** Most product IDs don't use 4–6 decimal places, so the bug lies dormant. It activates only for keys that happen to use the extra precision — often a subset introduced by a new product catalog import.

**Minimal repro:**
```sql
WITH a AS (SELECT CAST(1.000001 AS NUMERIC(18,6)) AS id),
     b AS (SELECT CAST(1.0000 AS NUMERIC(18,4)) AS id)
SELECT a.id, b.id
FROM a JOIN b ON a.id = b.id;
-- 0 rows — precision mismatch causes JOIN miss
```

**How to catch it:**
```sql
-- After a JOIN, check for unexpected non-matches:
SELECT COUNT(*) FROM table_a a
WHERE NOT EXISTS (SELECT 1 FROM table_b b WHERE CAST(a.product_id AS NUMERIC(18,4)) = b.product_id);
```

**Real-world trigger:** Two systems use the same product ID but one was built with extra precision "just in case." A nightly reconciliation JOIN silently drops 0.3% of products — those with fractional IDs added by the new catalog system.

---

### CAST(float AS INT) Truncates, Does Not Round

**What it looks like:**
```sql
SELECT CAST(score AS INT) AS score_bucket FROM predictions;
```

**What actually happens:** `CAST(1.9 AS INT) = 1`. `CAST(2.7 AS INT) = 2`. SQL truncates toward zero — not rounding. A model outputting scores like `0.99` gets bucketed as `0`, not `1`.

**Why it's insidious:** The result is an integer, which is expected. The truncation is silent. The difference between truncation and rounding is not surfaced anywhere in the query output.

**Minimal repro:**
```sql
SELECT
    CAST(1.9 AS INT)    AS truncated,   -- 1
    ROUND(1.9)::INT     AS rounded,     -- 2
    CAST(-1.9 AS INT)   AS neg_trunc,   -- -1 (toward zero, not floor)
    FLOOR(-1.9)::INT    AS floored      -- -2
```

**How to catch it:** Any `CAST(float_col AS INT)` should be replaced with `ROUND(float_col)::INT` unless truncation is explicitly the semantic intent. Review all CAST expressions in metric definitions.

**Real-world trigger:** ML model scores bucketed into integer tiers for targeting. Score of `0.99` (near-certain conversion) lands in bucket `0` (non-converter). High-intent users receive no marketing for an entire campaign cycle.

---

### VARCHAR Length Silent Truncation on Insert

**What it looks like:**
```sql
-- Column defined as VARCHAR(50)
INSERT INTO customers (notes) VALUES ('This is a very long note that exceeds fifty characters and has important content');
```


**Why it's insidious:** The insert succeeds. The data is queryable. The truncation only surfaces when someone reads the record and notices the truncated text — which may not happen for records that are only processed programmatically.

**Minimal repro (MySQL without strict mode):**
```sql
SET sql_mode = '';  -- disable strict mode
CREATE TABLE t (notes VARCHAR(5));
INSERT INTO t VALUES ('hello world');  -- silently truncated to 'hello'
SELECT * FROM t;                       -- returns 'hello'
```

**How to catch it:**

**Real-world trigger:** Customer notes field stores contractual obligations. Long legal text is truncated silently. Customer service agents see incomplete notes and mishandle a support case.

---

### Boolean-to-Integer Implicit Cast Across Engines

**What it looks like:**
```sql
SELECT SUM(is_active) AS active_count FROM users;
-- where is_active is BOOLEAN
```



**Minimal repro:**
```sql
-- PostgreSQL: this errors
SELECT SUM(true::boolean);  -- ERROR: function sum(boolean) does not exist

-- Correct cross-engine pattern:
SELECT SUM(CASE WHEN is_active THEN 1 ELSE 0 END) AS active_count FROM users;
-- Or: COUNT(*) FILTER (WHERE is_active = true)  [PostgreSQL 9.4+]
```

**How to catch it:** Audit any `SUM()` or `AVG()` applied to BOOLEAN columns. Make the integer cast explicit: `SUM(is_active::INT)` or `SUM(CASE WHEN is_active THEN 1 ELSE 0 END)`.


---

### Semi-Structured Numeric Cast Silently Loses Decimal Values

**What it looks like:**
```sql
SELECT CAST(amount_text AS INTEGER) AS amount_int
FROM events
WHERE event_type = 'purchase';
```


**Why it's insidious:** If 95% of records have integer amounts (`'100'`), the cast works and looks correct. The 5% with decimal amounts (`'100.50'`) may fail, truncate, round, or become NULL depending on the implementation. Any of those outcomes is wrong if the business value is money.

**Minimal repro:**
```sql
SELECT
    amount_text,
    CAST(amount_text AS DECIMAL(18,2)) AS amount_decimal
FROM events;
```

**How to catch it:**


---

### Implicit Cast in JOIN Predicate — Index Miss and Wrong Results

**What it looks like:**
```sql
-- users.user_id is BIGINT
-- sessions.user_id is VARCHAR
SELECT u.name, COUNT(s.session_id)
FROM users u
JOIN sessions s ON u.user_id = s.user_id
GROUP BY u.name;
```


**Why it's insidious:** If most IDs are pure numerics, the join works for 98% of rows. The 2% with non-numeric IDs (guest users, test accounts, external OAuth IDs) silently disappear. Row counts look reasonable.

**Minimal repro:**
```sql
WITH users AS (SELECT 1::BIGINT AS user_id, 'Alice' AS name),
     sessions AS (SELECT '1' AS user_id, 'sess1' AS session_id
                  UNION ALL SELECT 'guest_abc', 'sess2')
SELECT u.name, s.session_id
FROM users u JOIN sessions s ON u.user_id = s.user_id;
-- 'guest_abc' session silently drops (cast attempt fails silently in some engines)
```

**How to catch it:**
```sql
-- Check for sessions with no matching user AFTER fixing the cast:
SELECT COUNT(*) FROM sessions s
WHERE NOT EXISTS (SELECT 1 FROM users u WHERE u.user_id::VARCHAR = s.user_id);
```

**Real-world trigger:** Auth system migration introduces alphanumeric user IDs for a new SSO provider. All sessions for SSO users silently drop from user-behavior analytics. SSO adoption appears to show zero engagement.
