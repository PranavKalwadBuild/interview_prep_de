<!-- sql-patterns: Silent Errors — SQL Portability and Semi-Structured Data -->

# Silent Errors — SQL Portability and Semi-Structured Data

This chapter covers bugs that appear when SQL touches semi-structured data, session settings, file loads, and implementation-defined behavior. The examples stay ANSI-first. Where executable syntax is needed and ANSI SQL has no common implementation, PostgreSQL and MySQL examples are shown.

---

### JSON Numeric Casts — Decimal Values Lost or Rejected Differently

**What it looks like:**

```sql
SELECT
    CAST(amount_text AS INTEGER) AS amount_int
FROM incoming_events;
```

**What actually happens:** Source payloads often mix `100`, `100.00`, `"100"`, and `"100.50"`. Some systems reject decimal-to-integer casts, some truncate, and some return `NULL` through tolerant parsing functions. The silent error is not the specific behavior; it is assuming all payloads have the same numeric shape.

**Safer pattern: validate before casting**

```sql
SELECT
    amount_text,
    CASE
        WHEN amount_text IS NULL THEN 'missing'
        WHEN amount_text LIKE '%.%' THEN 'decimal_value'
        ELSE 'integer_like'
    END AS amount_shape
FROM incoming_events;
```

**PostgreSQL**

```sql
SELECT
    CAST(CAST(amount_text AS NUMERIC(18,2)) AS INTEGER) AS amount_int
FROM incoming_events
WHERE amount_text IS NOT NULL;
```

**MySQL**

```sql
SELECT
    CAST(CAST(amount_text AS DECIMAL(18,2)) AS SIGNED) AS amount_int
FROM incoming_events
WHERE amount_text IS NOT NULL;
```

**Gotcha:** Do not cast money-like values to integers unless the unit is explicit. Store cents as integers or amounts as decimals, but do not mix both conventions.

---

### Unnesting Optional Arrays — Parent Rows Disappear

**What it looks like:** A source row contains zero or more tags, items, or attributes. Expanding the array produces one row per child.

**What actually happens:** If the expansion behaves like an inner join, parent rows with empty arrays disappear. Counts now describe "parents with at least one child", not all parents.

**Portable relational model**

```sql
-- Parent table
CREATE TABLE users (
    user_id BIGINT PRIMARY KEY
);

-- Child table after ingestion
CREATE TABLE user_tags (
    user_id BIGINT,
    tag     VARCHAR(100)
);
```

To preserve tagless users:

```sql
SELECT
    u.user_id,
    t.tag
FROM users u
LEFT JOIN user_tags t
    ON t.user_id = u.user_id;
```

**Detection**

```sql
SELECT COUNT(*) AS users_total
FROM users;

SELECT COUNT(DISTINCT user_id) AS users_after_expansion
FROM user_tags;
```

If the second count is lower, decide whether that is expected or whether parent rows were silently dropped.

---

### File Load Column Mismatch — Keys Loaded as NULL

**What it looks like:** A file has `user_id`, while the target table expects `userid` or `userId`.

**What actually happens:** Name-based loading can fail to map semantically equivalent but differently named columns. Positional loading can be worse: it may load values into the wrong columns without a type error.

**Safer pattern: stage, validate, then insert**

```sql
CREATE TABLE stg_orders_raw (
    source_user_id VARCHAR(100),
    source_amount  VARCHAR(100),
    source_date    VARCHAR(100)
);

CREATE TABLE orders (
    user_id    BIGINT,
    amount     DECIMAL(18,2),
    order_date DATE
);
```sql
SELECT
    COUNT(*) AS total_rows,
    COUNT(source_user_id) AS non_null_user_ids,
    COUNT(source_amount) AS non_null_amounts
FROM stg_orders_raw;
```

Insert only after validation:

```sql
INSERT INTO orders (user_id, amount, order_date)
SELECT
    CAST(source_user_id AS BIGINT),
    CAST(source_amount AS DECIMAL(18,2)),
    CAST(source_date AS DATE)
FROM stg_orders_raw
WHERE source_user_id IS NOT NULL;
```

**Gotcha:** Row count equality is not enough. Validate key-column completeness and representative value ranges after every load.

---

### Function-Wrapped Time Predicate — Correct Result, Bad Access Path

**What it looks like:**

```sql
SELECT COUNT(*)
FROM events
WHERE CAST(event_ts AS DATE) = DATE '2025-01-15';
```

**What actually happens:** The query returns correct rows, but applying a function to the timestamp can prevent index usage or partition pruning. This is a silent performance error: no wrong rows, but much more work than needed.

**Fix**

```sql
SELECT COUNT(*)
FROM events
WHERE event_ts >= TIMESTAMP '2025-01-15 00:00:00'
  AND event_ts <  TIMESTAMP '2025-01-16 00:00:00';
```

**Detection**

```sql
EXPLAIN
SELECT COUNT(*)
FROM events
WHERE event_ts >= TIMESTAMP '2025-01-15 00:00:00'
  AND event_ts <  TIMESTAMP '2025-01-16 00:00:00';
```

Check whether the plan uses the intended access path and estimates a selective row count.

---

### Timestamp Type Mismatch — Equal-Looking Times Do Not Join

**What it looks like:**

```sql
SELECT *
FROM events e
JOIN sessions s
    ON e.event_time = s.session_time;
```

**What actually happens:** One timestamp may represent local wall-clock time while another represents an absolute instant. They can display similarly yet refer to different moments, or display differently while referring to the same moment.

**Safer pattern**

```sql
-- Normalize during ingestion into a canonical timestamp column.
CREATE TABLE normalized_events (
    event_id       BIGINT,
    event_time_utc TIMESTAMP,
    source_timezone VARCHAR(100)
);
```

**Gotchas**

- Do not join timestamps from different systems until their timezone semantics are documented.
- Store the original source timestamp when audits matter.
- Use half-open time ranges instead of formatted strings for matching.

---

### JSON Null vs SQL NULL

**What it looks like:** A payload can contain a missing key, a JSON `null`, or a string value like `"null"`.

**What actually happens:** These states may collapse into SQL `NULL` during ingestion, losing information. Downstream logic cannot tell "field absent" from "field present but intentionally null".

**Safer relational landing shape**

```sql
CREATE TABLE staged_customer_attributes (
    customer_id BIGINT,
    attr_name   VARCHAR(100),
    attr_value  VARCHAR(4000),
    is_present  BOOLEAN,
    is_json_null BOOLEAN
);
```

**Detection**

```sql
SELECT
    attr_name,
    COUNT(*) AS rows_seen,
    SUM(CASE WHEN is_present THEN 1 ELSE 0 END) AS present_count,
    SUM(CASE WHEN is_json_null THEN 1 ELSE 0 END) AS json_null_count
FROM staged_customer_attributes
GROUP BY attr_name;
```

**Gotcha:** If "missing" and "explicitly null" have different business meanings, preserve both states before casting into final typed columns.

---

### Session Settings Change Query Meaning

**What it looks like:** Queries depend on default timezone, date style, collation, case sensitivity, or week-start behavior.

**What actually happens:** The same SQL text can produce different groupings, comparisons, or parsed dates when session settings differ.

**Safer pattern**

- Parse dates using explicit formats.
- Store normalized timestamps.
- Use calendar tables for week and fiscal definitions.
- Avoid relying on default string comparison behavior for business keys.

**Detection**

```sql
SELECT
    week_start_date,
    COUNT(*) AS event_count
FROM calendar_days c
JOIN events e
    ON CAST(e.event_ts AS DATE) = c.calendar_date
GROUP BY week_start_date;
```

Calendar tables make week semantics data-driven instead of session-driven.
