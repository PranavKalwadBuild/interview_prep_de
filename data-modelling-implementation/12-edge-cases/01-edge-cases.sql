-- =============================================================================
-- FILE: 12-edge-cases/01-edge-cases.sql
-- PURPOSE: Handle real-world edge cases in the dm_oltp / dm_warehouse pipeline.
-- MySQL 8.0+
-- =============================================================================

USE dm_warehouse;

-- =============================================================================
-- SECTION 1: LATE-ARRIVING FACTS
-- =============================================================================
-- Scenario
-- --------
-- A salary payment for January 2024 arrives in the ETL pipeline in March 2024.
-- Between January and March, emp_id = 7 was promoted — a new SCD2 row was
-- written to dim_employee (new employee_sk, new effective_date).
-- The January fact MUST reference the January-valid row, not the current row.

-- ❌ WRONG — uses the current (post-promotion) employee_sk
-- -----------------------------------------------------------------------
INSERT INTO fact_salary_payment (
    employee_sk, dept_sk, job_sk, pay_date_sk,
    salary_amount, bonus_amount, pay_year, pay_month
)
SELECT
    e.employee_sk,          -- WRONG: this is the March 2024 row (post-promotion)
    e.dept_sk,
    e.job_sk,
    d.date_sk,
    6500.00,
    NULL,
    2024, 1
FROM  dim_employee e
JOIN  dim_date     d ON d.date_actual = '2024-01-31'
WHERE e.emp_id    = 7
  AND e.is_current = 1;    -- WRONG: is_current refers to March 2024 state


-- ✅ CORRECT — use the effective-date window to find the January 2024 row
-- -----------------------------------------------------------------------
-- The SCD2 row valid on 2024-01-31 satisfies:
--   effective_date <= '2024-01-31'  AND  (expiry_date > '2024-01-31' OR expiry_date IS NULL)
INSERT INTO fact_salary_payment (
    employee_sk, dept_sk, job_sk, pay_date_sk,
    salary_amount, bonus_amount, pay_year, pay_month
)
SELECT
    e.employee_sk,          -- CORRECT: the January-valid surrogate key
    e.dept_sk,
    e.job_sk,
    d.date_sk,
    6500.00,
    NULL,
    2024, 1
FROM  dim_employee e
JOIN  dim_date     d ON d.date_actual = '2024-01-31'
WHERE e.emp_id          = 7
  AND e.effective_date  <= '2024-01-31'
  AND (e.expiry_date     > '2024-01-31' OR e.expiry_date IS NULL);
-- If no row matches this window, the dimension was not populated correctly —
-- investigate the SCD2 load, do not fall back to is_current = 1.


-- Handling a missing date in dim_date (e.g., 2024-02-29 does not exist)
-- -----------------------------------------------------------------------
-- Strategy: use a sentinel date_sk = 19000101 ("Unknown Date") so the fact
-- row can still be inserted with a valid FK rather than a NULL or rejected row.

-- Create the sentinel row once during warehouse setup:
INSERT IGNORE INTO dim_date
    (date_sk, date_actual, year, quarter, month,
     month_name, week_of_year, day_of_month, day_of_week,
     day_name, is_weekend, is_holiday, is_last_day_of_month,
     fiscal_year, fiscal_quarter)
VALUES
    (19000101, '1900-01-01', 1900, 1, 1,
     'January', 1, 1, 2,
     'Monday', 0, 1, 0,
     1900, 1);

-- Load with sentinel fallback:
INSERT INTO fact_salary_payment (
    employee_sk, dept_sk, job_sk, pay_date_sk,
    salary_amount, bonus_amount, pay_year, pay_month
)
SELECT
    e.employee_sk,
    e.dept_sk,
    e.job_sk,
    COALESCE(d.date_sk, 19000101)   AS pay_date_sk,  -- sentinel if date missing
    6500.00,
    NULL,
    2024, 2
FROM  dim_employee e
LEFT JOIN dim_date d ON d.date_actual = '2024-02-29'   -- does not exist → NULL
WHERE e.emp_id         = 7
  AND e.effective_date <= '2024-02-29'
  AND (e.expiry_date    > '2024-02-29' OR e.expiry_date IS NULL);


-- =============================================================================
-- SECTION 2: NULL HANDLING IN DIMENSIONAL MODELS
-- =============================================================================

-- 2a: NULL in a Dimension attribute (dim_department.budget)
-- -----------------------------------------------------------------------
-- The Executive department has no approved budget yet → budget = NULL.
-- Rule: PRESERVE the NULL in the dimension; do not substitute 0 (zero is a
-- real value meaning "budget approved at $0", which is different from "unknown").
-- Apply COALESCE only at query time, with a clear label.

SELECT
    dept_name,
    location,
    COALESCE(budget, 0)          AS budget_display,    -- 0 for UI only
    CASE
        WHEN budget IS NULL THEN 'Budget Not Set'
        ELSE FORMAT(budget, 2)
    END                          AS budget_label
FROM  dim_department
ORDER BY dept_name;


-- 2b: NULL in a Fact measure (fact_salary_payment.salary_amount)
-- -----------------------------------------------------------------------
-- emp 10 and emp 15 have NULL salary in dm_oltp → salary_amount = NULL in fact.

-- SUM silently skips NULLs (this is ANSI SQL behaviour — expected and correct):
SELECT
    pay_year,
    pay_month,
    SUM(salary_amount)          AS total_payroll,       -- NULLs excluded silently
    COUNT(*)                    AS total_rows,           -- includes NULL-salary rows
    COUNT(salary_amount)        AS rows_with_salary      -- excludes NULL-salary rows
FROM  fact_salary_payment
WHERE pay_year = 2024
GROUP BY pay_year, pay_month
ORDER BY pay_month;

-- Audit query: flag the rows where salary IS NULL
SELECT
    f.payment_sk,
    e.emp_id,
    e.first_name,
    e.last_name,
    f.pay_year,
    f.pay_month,
    f.salary_amount             AS salary_amount_null_check
FROM  fact_salary_payment f
JOIN  dim_employee        e ON f.employee_sk = e.employee_sk
WHERE f.salary_amount IS NULL
  AND e.is_current = 1;


-- 2c: NULL FK in a Fact — Sentinel / Unknown Member Row
-- -----------------------------------------------------------------------
-- If a fact row has dept_id = NULL in the source (e.g., a purchase order
-- placed before a department was assigned), the DW FK must not be NULL
-- because NULL in a FK column breaks referential integrity and causes
-- fact rows to DROP from GROUP BY aggregations (NULL != any dept_sk).
-- Solution: create an "Unknown Department" sentinel and map NULL FKs to it.

-- Create the sentinel once (dept_sk = 0):
INSERT IGNORE INTO dim_department
    (dept_sk, dept_id, dept_name, location, budget)
VALUES
    (0, 0, 'Unknown Department', 'Unknown', NULL);

-- ETL mapping — use COALESCE to substitute the sentinel:
-- (Conceptual; actual INSERT depends on source system query)
--
-- INSERT INTO fact_salary_payment (dept_sk, ...)
-- SELECT COALESCE(d.dept_sk, 0), ...   -- 0 = Unknown, never NULL
-- FROM source_table s
-- LEFT JOIN dim_department d ON s.dept_id = d.dept_id;

-- Verify no NULL FKs exist in the fact table after load:
SELECT COUNT(*) AS null_dept_sk_rows
FROM  fact_salary_payment
WHERE dept_sk IS NULL;   -- should always return 0


-- 2d: NULL in SCD2 — termination_date handling
-- -----------------------------------------------------------------------
-- emp 35 is Terminated; in dm_oltp termination_date was initially NULL (Active).
-- When status flips, the SCD2 process:
--   1. Sets expiry_date on the current row to TODAY.
--   2. Inserts a new row with termination_date = <actual date>, is_current = 1.
-- Query pattern: use IS NULL as the "still active" check for termination_date.

SELECT
    emp_id,
    first_name,
    last_name,
    hire_date,
    termination_date,
    effective_date,
    expiry_date,
    is_current,
    CASE
        WHEN termination_date IS NULL THEN 'Active'
        ELSE 'Terminated'
    END AS derived_status
FROM  dim_employee
WHERE emp_id = 35
ORDER BY effective_date;


-- =============================================================================
-- SECTION 3: PERFORMANCE CONSIDERATIONS
-- =============================================================================

-- 3a: Partitioning fact_salary_payment by pay_year
-- -----------------------------------------------------------------------
-- Range partitioning lets the query planner skip entire partitions when a
-- WHERE clause filters on pay_year — known as "partition pruning".
-- A full-year query (pay_year = 2023) scans only the p2023 partition
-- instead of the entire table.

ALTER TABLE fact_salary_payment
    PARTITION BY RANGE (pay_year) (
        PARTITION p2020 VALUES LESS THAN (2021),
        PARTITION p2021 VALUES LESS THAN (2022),
        PARTITION p2022 VALUES LESS THAN (2023),
        PARTITION p2023 VALUES LESS THAN (2024),
        PARTITION p2024 VALUES LESS THAN (2025),
        PARTITION pmax  VALUES LESS THAN MAXVALUE
    );
-- Note: in MySQL, the partition column must be part of the PRIMARY KEY
-- or any UNIQUE KEY.  Adjust the PK to include pay_year if needed:
--   PRIMARY KEY (payment_sk, pay_year)

-- Verify partition pruning (look for "partitions" column in EXPLAIN):
EXPLAIN SELECT *
FROM  fact_salary_payment
WHERE pay_year = 2023;


-- 3b: Index strategy for fact and dimension tables
-- -----------------------------------------------------------------------

-- fact_salary_payment: indexes on FK columns used in JOINs and filters
CREATE INDEX IF NOT EXISTS idx_fsp_employee   ON fact_salary_payment (employee_sk);
CREATE INDEX IF NOT EXISTS idx_fsp_dept       ON fact_salary_payment (dept_sk);
CREATE INDEX IF NOT EXISTS idx_fsp_pay_date   ON fact_salary_payment (pay_date_sk);
CREATE INDEX IF NOT EXISTS idx_fsp_year_month ON fact_salary_payment (pay_year, pay_month);

-- dim_employee: composite index for surrogate key lookups (most common query)
CREATE INDEX IF NOT EXISTS idx_de_emp_current ON dim_employee (emp_id, is_current);
-- Rationale: ETL lookups always filter by emp_id AND is_current = 1 or date window.
-- The composite index satisfies both columns in one scan.

-- dim_date: index on the natural key (date_actual) for date-range joins
CREATE INDEX IF NOT EXISTS idx_dd_date_actual ON dim_date (date_actual);

-- Dimensions are typically small (< 1M rows) — no partitioning needed.
-- Facts grow unboundedly → partitioned by time, indexed by FK.


-- 3c: Engineering dept skew — 14 of 41 employees (34%)
-- -----------------------------------------------------------------------
-- In a single-node MySQL DW, this is a query planner concern: GROUP BY dept_sk
-- produces unequal group sizes (Engineering = 14 rows, others average ~3 rows).
-- MySQL handles this fine at 41-row scale.

-- Observe the skew:
SELECT
    d.dept_name,
    COUNT(e.employee_sk)                                    AS headcount,
    ROUND(COUNT(e.employee_sk) / SUM(COUNT(e.employee_sk)) OVER () * 100, 1)
                                                            AS pct_of_total
FROM  dim_employee   e
JOIN  dim_department d ON e.dept_sk = d.dept_sk
WHERE e.is_current = 1
GROUP BY d.dept_sk, d.dept_name
ORDER BY headcount DESC;

-- At scale (Spark / distributed engine):
-- Engineering's partition receives 34% of rows while others receive ~8% each.
-- This causes stragglers in shuffle-heavy operations (GROUP BY, JOIN).
-- Mitigation strategies:
--   1. Salting: append a random suffix (0–N) to dept_sk, increase parallelism,
--      then sum partial aggregates.
--   2. Sub-partition facts by a second column (e.g., job_sk or pay_month)
--      so each partition is more evenly sized.
--   3. Broadcast join: keep dim_department small enough to broadcast, avoiding
--      a shuffle altogether for the dimension join.
-- In this MySQL warehouse, the skew only matters if a FULL TABLE SCAN is
-- required; proper indexes eliminate most skew-driven performance issues.
