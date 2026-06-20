<!-- Part of sql-patterns: Date Functions — ANSI-first date and timestamp handling -->

## M. Date Functions & Transformations

### Why dates are hard in SQL

Date logic is where otherwise portable SQL usually starts to drift. The safest interview and production habit is to express the idea in modern ANSI SQL first:

- Use typed `DATE`, `TIME`, and `TIMESTAMP` values instead of formatted strings.
- Use `CURRENT_DATE`, `CURRENT_TIMESTAMP`, `EXTRACT`, `CAST`, and `INTERVAL` where possible.
- Use half-open timestamp ranges: `>= start_ts AND < next_start_ts`.
- Avoid applying functions to indexed, partitioned, or sorted timestamp columns in `WHERE`.
- If ANSI SQL has no common implementation, show both PostgreSQL and MySQL explicitly.

---

### A. Current Date and Time

```sql
SELECT
    CURRENT_DATE      AS current_date_value,
    CURRENT_TIMESTAMP AS current_timestamp_value;
```

**Gotchas and edge cases**

- `CURRENT_DATE` has no time component. It is appropriate for date-level reporting, not exact event ordering.
- `CURRENT_TIMESTAMP` is a timestamp. It may include timezone semantics depending on the database and column type, so do not mix it casually with local wall-clock timestamps.
- For reproducible pipelines, pass an explicit `as_of_date` or `run_timestamp` parameter instead of calling `CURRENT_DATE` in many places.

---

### B. Extracting Parts

`EXTRACT` is the most portable way to pull date parts.

```sql
SELECT
    EXTRACT(YEAR    FROM executed_at) AS executed_year,
    EXTRACT(MONTH   FROM executed_at) AS executed_month,
    EXTRACT(DAY     FROM executed_at) AS executed_day,
    EXTRACT(HOUR    FROM executed_at) AS executed_hour,
    EXTRACT(MINUTE  FROM executed_at) AS executed_minute,
    EXTRACT(SECOND  FROM executed_at) AS executed_second
FROM trades;
```

**Gotchas and edge cases**

- Week number, day-of-week, and quarter extraction are less portable than year/month/day. Define the business rule first: ISO week or calendar week, Monday start or Sunday start, fiscal quarter or calendar quarter.
- Do not filter with `EXTRACT(YEAR FROM executed_at) = 2025` on large tables. It is readable but often prevents pruning or index usage. Prefer a range predicate:

```sql
WHERE executed_at >= TIMESTAMP '2025-01-01 00:00:00'
  AND executed_at <  TIMESTAMP '2026-01-01 00:00:00'
```

---

### C. Date Truncation and Period Starts

Modern ANSI SQL does not define one universally implemented `DATE_TRUNC` function. For portability, write period boundaries as ranges. When you need a period-start value, use PostgreSQL/MySQL fallbacks.

```sql
-- ANSI-first filtering: all events in March 2025
WHERE executed_at >= TIMESTAMP '2025-03-01 00:00:00'
  AND executed_at <  TIMESTAMP '2025-04-01 00:00:00';
```

**PostgreSQL**

```sql
SELECT
    DATE_TRUNC('month', executed_at) AS month_start,
    DATE_TRUNC('day', executed_at)   AS day_start
FROM trades;
```

**MySQL**

```sql
SELECT
    CAST(DATE_FORMAT(executed_at, '%Y-%m-01') AS DATE) AS month_start,
    CAST(executed_at AS DATE)                         AS day_start
FROM trades;
```

**Gotchas and edge cases**

- Truncating for display is fine. Truncating inside a `WHERE` predicate is often expensive.
- Week starts are business definitions, not universal truths. Store a calendar table with `week_start_date`, `iso_week`, fiscal periods, and holiday flags when weekly reporting matters.
- Month truncation should return a date/timestamp, not a string, unless the final output truly needs a label.

---

### D. Date Arithmetic

ANSI SQL interval syntax is the cleanest default for adding or subtracting time.

```sql
SELECT
    executed_at + INTERVAL '7' DAY    AS seven_days_later,
    executed_at - INTERVAL '1' MONTH  AS one_month_earlier,
    executed_at + INTERVAL '2' HOUR   AS two_hours_later
FROM trades;
```

**PostgreSQL**

```sql
SELECT
    executed_at + INTERVAL '7 days'   AS seven_days_later,
    executed_at - INTERVAL '1 month'  AS one_month_earlier,
    executed_at + INTERVAL '2 hours'  AS two_hours_later
FROM trades;
```

**MySQL**

```sql
SELECT
    DATE_ADD(executed_at, INTERVAL 7 DAY)    AS seven_days_later,
    DATE_SUB(executed_at, INTERVAL 1 MONTH)  AS one_month_earlier,
    DATE_ADD(executed_at, INTERVAL 2 HOUR)   AS two_hours_later
FROM trades;
```

**Gotchas and edge cases**

- Adding one month is not the same as adding 30 days. `2025-01-31 + 1 month` needs a clear end-of-month rule.
- Always confirm whether the column is a `DATE` or a `TIMESTAMP`; adding hours to a `DATE` may cast or truncate depending on implementation.
- For retention windows, prefer date ranges over computed integer differences.

---

### E. Date Difference


**PostgreSQL**

```sql
SELECT
    end_date - start_date AS days_between,
    EXTRACT(EPOCH FROM (end_ts - start_ts)) / 3600.0 AS hours_between
FROM events;
```

**MySQL**


**Gotchas and edge cases**

- Date differences count date boundaries, not necessarily complete elapsed 24-hour periods.
- Month differences are especially tricky because months have different lengths. For billing and cohorts, compare period-start dates rather than dividing days by 30.

---

### F. Formatting Dates as Strings

Formatting should usually happen at the presentation layer. In SQL, keep dates typed for joins, filtering, sorting, and grouping.

**Why presentation layer?** Date formatting introduces engine-specific behavior, prevents index usage, and complicates cross-database compatibility. Format only for final display.

**PostgreSQL**

```sql
SELECT TO_CHAR(executed_at, 'YYYY-MM-DD') AS executed_date_label
FROM trades;
```

**MySQL**

```sql
SELECT DATE_FORMAT(executed_at, 'YYYY-MM-DD') AS executed_date_label
FROM trades;
```

```sql
SELECT TO_CHAR(executed_at, 'YYYY-MM-DD') AS executed_date_label
FROM trades;
```

**MySQL**

```sql
SELECT DATE_FORMAT(executed_at, 'YYYY-MM-DD') AS executed_date_label
FROM trades;
```

**Gotchas and edge cases in date formatting:**

- **Inconsistent separators:** Some engines use different default separators based on locale settings
- **Leading zeros:** Format padding varies (MM vs M for months, DD vs D for days)
- **Case sensitivity:** Month/day names may be affected by database locale settings
- **Performance impact:** Formatting prevents use of indexes on date columns in WHERE clauses
- **Sorting issues:** Lexicographic sorting of formatted strings doesn't match chronological order unless using YYYY-MM-DD HH:MM:SS format
- **Timezone loss:** Formatting often drops timezone information, leading to ambiguity in distributed systems
- **Precision truncation:** Formatting to day level hides hour/minute/second components that may be significant for analysis

**Best practices:**
1. Always perform date formatting in the application layer or reporting tools
2. If formatting must be done in SQL, document the engine-specific function used
3. Use ISO 8601 format (YYYY-MM-DDTHH:MM:SSZ) for maximum compatibility when string representation is necessary
4. Consider creating database-specific views or functions to abstract formatting differences
5. Test formatted output across target database engines to ensure consistency


---

### G. Parsing Strings into Dates

Use `CAST` for ISO-formatted strings. For non-ISO formats, use PostgreSQL/MySQL parsing functions and validate failed parses explicitly.

```sql
SELECT
    CAST('2025-03-15' AS DATE) AS parsed_date,
    CAST('2025-03-15 14:30:00' AS TIMESTAMP) AS parsed_timestamp;
```

**PostgreSQL**

```sql
SELECT
    TO_DATE('15/03/2025', 'DD/MM/YYYY') AS parsed_date,
    TO_TIMESTAMP('15/03/2025 14:30', 'DD/MM/YYYY HH24:MI') AS parsed_timestamp;
```

**MySQL**

```sql
SELECT
    STR_TO_DATE('15/03/2025', '%d/%m/%Y') AS parsed_date,
    STR_TO_DATE('15/03/2025 14:30', '%d/%m/%Y %H:%i') AS parsed_timestamp;
```

**Gotchas and edge cases**

- Never assume free-form strings are valid dates. Profile invalid, blank, and ambiguous values before casting in a pipeline.
- Ambiguous inputs like `03/04/2025` must be tied to an explicit format.
- Store raw input and parsed output during ingestion if the source quality is uncertain; it makes bad-date audits possible later.

