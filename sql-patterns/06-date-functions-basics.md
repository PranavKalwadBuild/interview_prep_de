<!-- Part of sql-patterns: Date Functions — Current Date, Extracting Parts, Truncation, Arithmetic, Difference, Formatting, Parsing -->
<!-- Source: sql_patterns.md lines 1188–1407 -->

## M. Date Functions & Transformations

### Why dates are hard in SQL

Date/time handling is the single most engine-specific area of SQL. The same operation can be written 3–4 different ways depending on whether you're in MySQL, PostgreSQL, Snowflake, BigQuery, Spark SQL, or SQL Server. This section covers the **conceptual operations** that exist in every engine, followed by the most common syntax variants, and then the most frequently needed transformation patterns.

---

### A. Current Date and Time

| Concept | Standard / Most portable | PostgreSQL | MySQL | Snowflake | BigQuery | Spark SQL |
|---|---|---|---|---|---|---|
| Current date (no time) | `CURRENT_DATE` | `CURRENT_DATE` | `CURDATE()` | `CURRENT_DATE` | `CURRENT_DATE()` | `CURRENT_DATE` |
| Current timestamp | `CURRENT_TIMESTAMP` | `NOW()` | `NOW()` | `CURRENT_TIMESTAMP` | `CURRENT_TIMESTAMP()` | `CURRENT_TIMESTAMP` |
| Current timestamp with TZ | `CURRENT_TIMESTAMP` | `NOW()` | — | `SYSDATE()` | `CURRENT_TIMESTAMP()` | `now()` |

```sql
-- Most portable — works in PostgreSQL, Snowflake, BigQuery, Spark, SQL Server:
SELECT CURRENT_DATE          -- date only (no time)
SELECT CURRENT_TIMESTAMP     -- date + time (with timezone in pg/snowflake)

-- MySQL alternative:
SELECT CURDATE(), NOW()
```sql

---

### B. Extracting Parts from a Date / Timestamp

The most universally supported approach is `EXTRACT()`:

```sql
-- EXTRACT — works in PostgreSQL, Snowflake, BigQuery, MySQL 8+, Spark SQL
SELECT
    EXTRACT(YEAR   FROM executed_at) AS yr,
    EXTRACT(MONTH  FROM executed_at) AS mo,
    EXTRACT(DAY    FROM executed_at) AS dy,
    EXTRACT(HOUR   FROM executed_at) AS hr,
    EXTRACT(MINUTE FROM executed_at) AS mi,
    EXTRACT(SECOND FROM executed_at) AS sc,
    EXTRACT(DOW    FROM executed_at) AS day_of_week,   -- 0=Sun…6=Sat (PostgreSQL/Spark)
    EXTRACT(DOY    FROM executed_at) AS day_of_year,
    EXTRACT(WEEK   FROM executed_at) AS week_of_year,
    EXTRACT(QUARTER FROM executed_at) AS quarter
FROM trades;
```

**Engine-specific shorthand functions** (less portable, but common in interviews):

```sql
-- MySQL / Spark SQL
YEAR(executed_at)       MONTH(executed_at)      DAY(executed_at)
HOUR(executed_at)       MINUTE(executed_at)     SECOND(executed_at)
WEEKOFYEAR(executed_at) QUARTER(executed_at)    DAYOFWEEK(executed_at)

-- Snowflake
YEAR(executed_at)       MONTH(executed_at)      DAY(executed_at)
HOUR(executed_at)       MINUTE(executed_at)     DAYOFWEEK(executed_at)

-- BigQuery
EXTRACT(YEAR FROM executed_at)     -- EXTRACT is the primary method
DATE_PART('year', executed_at)     -- also supported

-- SQL Server
YEAR(executed_at)       MONTH(executed_at)      DAY(executed_at)
DATEPART(WEEKDAY, executed_at)     DATEPART(ISO_WEEK, executed_at)
```sql

---

### C. Date Truncation

Truncation sets everything below a given unit to its minimum value (e.g., truncating a timestamp to month → first of that month at midnight).

```sql
-- DATE_TRUNC — PostgreSQL, Snowflake, BigQuery, Spark SQL, DuckDB
DATE_TRUNC('year',    executed_at)    -- 2024-01-01 00:00:00
DATE_TRUNC('quarter', executed_at)    -- 2024-01-01 / 2024-04-01 / etc.
DATE_TRUNC('month',   executed_at)    -- 2024-03-01 00:00:00
DATE_TRUNC('week',    executed_at)    -- Monday of the week (ISO week)
DATE_TRUNC('day',     executed_at)    -- 2024-03-15 00:00:00
DATE_TRUNC('hour',    executed_at)    -- 2024-03-15 14:00:00
DATE_TRUNC('minute',  executed_at)    -- 2024-03-15 14:22:00

-- MySQL equivalent (no DATE_TRUNC — use DATE_FORMAT or manual expression)
DATE_FORMAT(executed_at, '%Y-%m-01')             -- truncate to month
DATE_FORMAT(executed_at, '%Y-01-01')             -- truncate to year
STR_TO_DATE(DATE_FORMAT(executed_at,'%Y%u Monday'), '%X%V %W')  -- truncate to week (complex)

-- SQL Server equivalent
DATETRUNC(month, executed_at)   -- SQL Server 2022+
DATEFROMPARTS(YEAR(executed_at), MONTH(executed_at), 1)  -- truncate to month (older)
```

> **Rule of thumb for grouping by time period:** always prefer `DATE_TRUNC` over `DATE_FORMAT` + string. `DATE_TRUNC` returns a proper date/timestamp that sorts correctly; string formats lose sort order unless you format as `YYYY-MM`.

---

### D. Date Arithmetic — Adding and Subtracting

```sql
-- Standard SQL interval syntax (PostgreSQL, DuckDB, Spark SQL):
executed_at + INTERVAL '7 days'
executed_at - INTERVAL '1 month'
executed_at + INTERVAL '2 hours 30 minutes'

-- Snowflake: DATEADD function
DATEADD(day,   7,  executed_at)
DATEADD(month, -1, executed_at)
DATEADD(year,  1,  executed_at)

-- MySQL: DATE_ADD / DATE_SUB
DATE_ADD(executed_at, INTERVAL 7 DAY)
DATE_SUB(executed_at, INTERVAL 1 MONTH)

-- BigQuery: DATE_ADD / DATE_SUB / TIMESTAMP_ADD
DATE_ADD(trade_date, INTERVAL 7 DAY)
TIMESTAMP_ADD(executed_at, INTERVAL 30 MINUTE)

-- SQL Server: DATEADD
DATEADD(day,    7,  executed_at)
DATEADD(month, -1,  executed_at)

-- Spark SQL: date_add / date_sub (days only) or interval syntax
date_add(trade_date, 7)
date_sub(trade_date, 30)
executed_at + INTERVAL 1 HOUR
```sql

---

### E. Date Difference — Days Between Two Dates

```sql
-- DATEDIFF — most engines support this but argument ORDER differs!

-- MySQL / Spark SQL: DATEDIFF(end_date, start_date) → positive if end > start
DATEDIFF(end_date, start_date)

-- Snowflake: DATEDIFF(unit, start_date, end_date)
DATEDIFF('day',    start_date, end_date)
DATEDIFF('month',  start_date, end_date)
DATEDIFF('year',   start_date, end_date)
DATEDIFF('hour',   start_ts,   end_ts)
DATEDIFF('minute', start_ts,   end_ts)

-- BigQuery: DATE_DIFF(end_date, start_date, unit)
DATE_DIFF(end_date,   start_date, DAY)
DATE_DIFF(end_date,   start_date, MONTH)
TIMESTAMP_DIFF(end_ts, start_ts,  MINUTE)

-- PostgreSQL: direct subtraction returns an interval
end_date - start_date                          -- returns INTEGER (days) for DATE types
EXTRACT(DAY FROM (end_ts - start_ts))          -- extract days from interval
DATE_PART('day', end_ts - start_ts)            -- same as above

-- SQL Server: DATEDIFF(unit, start_date, end_date)
DATEDIFF(DAY,    start_date, end_date)
DATEDIFF(MONTH,  start_date, end_date)
DATEDIFF(MINUTE, start_ts,   end_ts)
```

> **Interview tip:** The most common mistake is reversing the argument order between MySQL and SQL Server/Snowflake. Always state which engine you're using and double-check the argument order.

---

### F. Formatting Dates as Strings

```sql
-- PostgreSQL / Redshift
TO_CHAR(executed_at, 'YYYY-MM-DD')
TO_CHAR(executed_at, 'YYYY-MM')        -- for month grouping as string
TO_CHAR(executed_at, 'Day')            -- full weekday name (Monday)
TO_CHAR(executed_at, 'DY')             -- abbreviated (Mon)
TO_CHAR(executed_at, 'HH24:MI:SS')     -- time portion

-- MySQL / Spark SQL
DATE_FORMAT(executed_at, '%Y-%m-%d')
DATE_FORMAT(executed_at, '%Y-%m')
DATE_FORMAT(executed_at, '%W')         -- full weekday name
DATE_FORMAT(executed_at, '%a')         -- abbreviated (Mon)

-- Snowflake / BigQuery
TO_VARCHAR(executed_at, 'YYYY-MM-DD')  -- Snowflake
FORMAT_DATE('%Y-%m', trade_date)       -- BigQuery (DATE only)
FORMAT_TIMESTAMP('%Y-%m-%d', ts)       -- BigQuery (TIMESTAMP)

-- SQL Server
FORMAT(executed_at, 'yyyy-MM-dd')
CONVERT(VARCHAR, executed_at, 23)      -- ISO 8601 date
```sql

---

### G. Parsing Strings into Dates

```sql
-- CAST — most portable, works when string is in ISO 8601 format (YYYY-MM-DD):
CAST('2024-03-15' AS DATE)
CAST('2024-03-15 14:30:00' AS TIMESTAMP)
TRY_CAST('2024-03-15' AS DATE)         -- Snowflake / SQL Server — returns NULL on failure

-- PostgreSQL
TO_DATE('15/03/2024', 'DD/MM/YYYY')
TO_TIMESTAMP('15/03/2024 14:30', 'DD/MM/YYYY HH24:MI')

-- MySQL / Spark SQL
STR_TO_DATE('15/03/2024', '%d/%m/%Y')

-- Snowflake
TO_DATE('15-03-2024', 'DD-MM-YYYY')
TRY_TO_DATE('15-03-2024', 'DD-MM-YYYY')  -- NULL on failure

-- BigQuery
PARSE_DATE('%d/%m/%Y', '15/03/2024')
PARSE_TIMESTAMP('%d/%m/%Y %H:%M', '15/03/2024 14:30')
```sql

---

