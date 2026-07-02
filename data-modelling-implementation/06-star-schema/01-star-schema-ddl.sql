-- ============================================================
-- 06-star-schema / 01-star-schema-ddl.sql
-- Database: dm_warehouse
--
-- This file does NOT recreate the schema (that lives in
-- 00-setup/02-warehouse-schema.sql). Instead it:
--
--   SECTION 1 — Kimball's 4-step design process applied to
--               the employee/HR domain (comment blocks).
--   SECTION 2 — 5 representative star schema queries.
--   SECTION 3 — Star vs snowflake comparison with code.
--   SECTION 4 — Conformed dimension proof (dept_sk in all facts).
--
-- Run prerequisites: 00-setup/01-source-oltp-schema.sql and
-- 00-setup/02-warehouse-schema.sql must be executed first,
-- and the warehouse must be populated (ETL not shown here).
-- Queries are written to run correctly against the schema;
-- results depend on ETL load state.
-- ============================================================

USE dm_warehouse;

-- ─────────────────────────────────────────────────────────────
-- SECTION 1 — KIMBALL'S 4-STEP DESIGN PROCESS
-- ─────────────────────────────────────────────────────────────
/*
  Ralph Kimball's dimensional modelling methodology begins with
  four questions that must be answered before a single table is
  created. Getting these wrong — especially step 2 (grain) — is
  the most common cause of fact table fan-out, double-counting,
  and "why don't my numbers match?" dashboard bugs.

  ══════════════════════════════════════════════════════════════
  STEP 1 — SELECT THE BUSINESS PROCESS
  ══════════════════════════════════════════════════════════════
  The business process is the operational activity that generates
  the measurements we want to analyse. It corresponds to a source
  system transaction or event.

  For this project we selected TWO business processes:

  A) PAYROLL — each month, every active employee receives a salary
     payment. The source event is a payment record in the payroll
     system. This generates fact_salary_payment.

  B) HEADCOUNT REPORTING — at month-end, each department has a
     count of active employees, total payroll, and average salary.
     This is a management reporting process, not a transaction.
     The source is a snapshot query over dm_oltp.employees.
     This generates fact_monthly_headcount.

  Why two processes? They answer different questions:
  - "How much did we pay Alice in March?" → fact_salary_payment
  - "How many engineers did we have at end of March?" → fact_monthly_headcount
  A single fact table cannot correctly serve both without mixing grains.

  ══════════════════════════════════════════════════════════════
  STEP 2 — DECLARE THE GRAIN
  ══════════════════════════════════════════════════════════════
  The grain is the precise definition of what ONE ROW in the fact
  table represents. It must be declared at the atomic level of the
  source process before any dimensions are added.

  fact_salary_payment  GRAIN: one row per employee per monthly pay period.
    An employee with 12 months of tenure has exactly 12 rows.
    Splitting to a daily grain would require knowing the pay day (not
    available from the source); rolling up to annual would lose monthly
    variance. Monthly is the natural atomic grain.

  fact_monthly_headcount  GRAIN: one row per department per calendar month.
    There is exactly ONE row for Engineering for March 2024. There is no
    per-employee breakdown here — that would change the grain to
    (employee × month), which is the salary payment grain.

  GRAIN VIOLATION EXAMPLE (what NOT to do):
    If you try to store both salary_amount (per employee) AND dept_headcount
    (per department) in the same fact table, you must either:
    a) Repeat the headcount for every employee in the dept (fan-out), or
    b) Leave salary_amount NULL for the headcount rows.
    Both are wrong. Separate grains → separate fact tables.

  ══════════════════════════════════════════════════════════════
  STEP 3 — IDENTIFY THE DIMENSIONS
  ══════════════════════════════════════════════════════════════
  Once the grain is declared, dimensions are the context that
  describes each measurement. Ask: "Who, what, when, where, why
  for each row in the fact table?"

  For fact_salary_payment (grain: employee × pay month):
    WHO:   dim_employee — which employee received the payment?
    WHAT:  dim_job — what role did the employee hold that month?
    WHEN:  dim_date — which month-end date does this payment represent?
    WHERE: dim_department — which department was the employee in?
    FLAGS: dim_employee_flags — are any data quality flags set?

  dim_date is ROLE-PLAYING: the same physical table is used as
  pay_date, hire_date, snapshot_date, submit_date, start_date, etc.
  Each usage aliases the table under a different name in the query.

  ══════════════════════════════════════════════════════════════
  STEP 4 — IDENTIFY THE FACTS
  ══════════════════════════════════════════════════════════════
  Facts are the numeric measurements that the business process
  generates. They must be consistent with the declared grain.

  fact_salary_payment measures:
    salary_amount   — ADDITIVE across all dimensions (sum by dept,
                      by month, by job family all make sense).
    bonus_amount    — ADDITIVE (same rules as salary).

  fact_monthly_headcount measures:
    headcount       — SEMI-ADDITIVE: sum across departments is valid
                      (total company headcount), but sum across months
                      is NOT valid (March headcount + April headcount
                      is not a meaningful number).
    total_payroll   — SEMI-ADDITIVE: same rule as headcount.
    avg_salary      — NON-ADDITIVE: NEVER SUM this. Re-derive by
                      dividing total_payroll by headcount when a
                      cross-department average is needed.

  WHY ADDITIVITY MATTERS:
  BI tools aggregate by default. If a tool SUMs avg_salary across
  departments, it produces a number that looks plausible but is
  mathematically wrong. Documenting additivity prevents this.
*/

-- ─────────────────────────────────────────────────────────────
-- SECTION 2 — REPRESENTATIVE STAR SCHEMA QUERIES
-- ─────────────────────────────────────────────────────────────

-- ── Query A: Monthly payroll by department ────────────────────
/*
  Business question: How much did we pay in total salary and bonus
  per department per month for 2024?
  Fact: fact_salary_payment (grain: employee × pay month)
  Dimensions joined: dim_department, dim_date
  Aggregation: SUM of additive measures — safe.
*/
SELECT
    d.dept_name,
    dd.year,
    dd.month,
    dd.month_name,
    COUNT(DISTINCT fsp.employee_sk)          AS employee_count,
    SUM(fsp.salary_amount)                   AS total_salary,
    SUM(fsp.bonus_amount)                    AS total_bonus,
    SUM(fsp.salary_amount + fsp.bonus_amount) AS total_compensation
FROM fact_salary_payment fsp
JOIN dim_department d  ON fsp.dept_sk     = d.dept_sk
JOIN dim_date       dd ON fsp.pay_date_sk = dd.date_sk
WHERE dd.year = 2024
GROUP BY
    d.dept_name,
    dd.year,
    dd.month,
    dd.month_name
ORDER BY
    d.dept_name,
    dd.month;

-- ── Query B: Current headcount by dept with average salary ────
/*
  Business question: What is the current headcount and average
  salary for each department as of the latest snapshot?
  Fact: fact_monthly_headcount (grain: dept × month)
  Dimension joined: dim_department
  Note: avg_salary is NON-ADDITIVE — do NOT sum it. Use the
  pre-computed column directly or re-derive from total_payroll.
*/
SELECT
    d.dept_name,
    d.location,
    fmh.snapshot_year,
    fmh.snapshot_month,
    fmh.headcount,
    fmh.active_count,
    fmh.terminated_count,
    fmh.total_payroll,
    fmh.avg_salary,                          -- NON-ADDITIVE: display as-is
    -- Safe cross-dept average: re-derive from totals, NOT SUM(avg_salary)
    SUM(fmh.total_payroll) OVER ()
        / NULLIF(SUM(fmh.headcount) OVER (), 0) AS company_avg_salary
FROM fact_monthly_headcount fmh
JOIN dim_department d ON fmh.dept_sk = d.dept_sk
WHERE (fmh.snapshot_year, fmh.snapshot_month) = (
    SELECT snapshot_year, snapshot_month
    FROM fact_monthly_headcount
    ORDER BY snapshot_year DESC, snapshot_month DESC
    LIMIT 1
)
ORDER BY fmh.headcount DESC;

-- ── Query C: Total salary paid by job level ───────────────────
/*
  Business question: How does total compensation break down by
  job level (Individual Contributor, Lead, Manager, Director)?
  Fact: fact_salary_payment
  Dimensions joined: dim_employee (for emp_id lookup), dim_job
  Note: dim_job is joined via fact_salary_payment.job_sk — the
  fact carries the job_sk that was current at time of payment,
  which correctly handles employees who were promoted mid-year.
*/
SELECT
    dj.job_level_label,
    dj.job_family,
    COUNT(DISTINCT fsp.employee_sk)          AS distinct_employees,
    SUM(fsp.salary_amount)                   AS total_salary,
    SUM(fsp.bonus_amount)                    AS total_bonus,
    AVG(fsp.salary_amount)                   AS avg_monthly_salary
FROM fact_salary_payment fsp
JOIN dim_job dj ON fsp.job_sk = dj.job_sk
GROUP BY
    dj.job_level,
    dj.job_level_label,
    dj.job_family
ORDER BY
    dj.job_level,
    dj.job_family;

-- ── Query D: Employees with NULL salary (data quality audit) ──
/*
  Business question: Which employees have a NULL salary flag?
  Who are they, what department are they in, and are they
  contractors or terminated?
  Tables: dim_employee (SCD2 — current rows only), dim_employee_flags,
          dim_department
  No fact table needed — this is a dimension-only audit query.
*/
SELECT
    de.emp_id,
    de.first_name,
    de.last_name,
    de.email,
    de.salary,
    de.hire_date,
    de.termination_date,
    dd.dept_name,
    dd.location,
    def.is_contractor,
    def.is_terminated,
    def.is_future_hire,
    def.has_null_salary,
    def.has_null_email,
    def.flag_description
FROM dim_employee de
JOIN dim_employee_flags def ON de.flag_sk   = def.flag_sk
JOIN dim_department     dd  ON de.dept_sk   = dd.dept_sk
WHERE de.is_current       = 1               -- SCD2: only the active version
  AND def.has_null_salary = 1               -- the flaw we're auditing
ORDER BY de.emp_id;

/*
  Expected results from the intentional flaws:
    emp 10  — NULL salary (contractor), has_null_salary = 1
    emp 15  — NULL salary (contractor), has_null_salary = 1
*/

-- ── Query E: Employee tenure calculation ──────────────────────
/*
  Business question: What is the current tenure (in years and
  months) for each active employee?
  Approach: use DATE arithmetic on dim_employee.hire_date directly.
  A dim_date JOIN for tenure is unnecessarily complex — hire_date
  is stored in dim_employee and DATEDIFF / TIMESTAMPDIFF work on
  the stored date column.

  When TO use dim_date for a date column: when you need to slice
  by fiscal year, quarter name, or week-of-year — attributes that
  are pre-computed in dim_date. For simple arithmetic (how many
  days/months between two dates) stay with date functions.
*/
SELECT
    de.emp_id,
    de.first_name,
    de.last_name,
    dd.dept_name,
    dj.job_title,
    dj.job_level_label,
    de.hire_date,
    de.salary,
    -- Tenure in complete years
    TIMESTAMPDIFF(YEAR,  de.hire_date, CURDATE())  AS tenure_years,
    -- Tenure in complete months (for sub-year precision)
    TIMESTAMPDIFF(MONTH, de.hire_date, CURDATE())  AS tenure_months,
    -- Flag employees hired in the future (emp 41 — intentional flaw)
    CASE WHEN de.hire_date > CURDATE() THEN 'FUTURE HIRE' ELSE 'OK' END
        AS hire_date_status
FROM dim_employee de
JOIN dim_department dd ON de.dept_sk = dd.dept_sk
JOIN dim_job        dj ON de.job_sk  = dj.job_sk
WHERE de.is_current = 1
ORDER BY de.hire_date ASC;

/*
  If you DID want to join to dim_date on hire_date (to get fiscal
  year of hire, or week-of-year the employee started):

    JOIN dim_date hire_dim
      ON hire_dim.date_actual = de.hire_date

  The role-play alias "hire_dim" makes the purpose explicit.
  The join is on date_actual (DATE) → date_sk cannot be used
  directly unless the warehouse stores hire_date_sk in dim_employee
  (an alternative design tradeoff: add hire_date_sk FK to
  dim_employee, allowing direct SK-to-SK join).
*/

-- ─────────────────────────────────────────────────────────────
-- SECTION 3 — STAR VS SNOWFLAKE COMPARISON
-- ─────────────────────────────────────────────────────────────
/*
  CURRENT DESIGN: HYBRID (star + snowflake element)
  ──────────────────────────────────────────────────
  The current dm_warehouse design is primarily a star schema, but
  dim_employee references dim_job via job_sk — making dim_job a
  normalised child of dim_employee. This is the SNOWFLAKE PATTERN.

  Star:      fact → dim_employee (has job_title, job_family inline)
  Snowflake: fact → dim_employee → dim_job (job_title in a child table)

  Why the snowflake element was chosen for dim_job:
    1. Multiple employees share the same job title. Storing job
       attributes (job_family, job_level, job_level_label) once in
       dim_job avoids repeating them for every employee row and
       every SCD2 version of each employee row.
    2. When the job taxonomy is reorganised (e.g., "Data Engineer"
       moves from Engineering family to Analytics family), updating
       ONE row in dim_job propagates immediately. In a pure star,
       you'd UPDATE every dim_employee row with that job_title.
    3. dim_job has low cardinality (~20 distinct job titles in the
       HR domain). The extra join is cheap.
*/

-- CURRENT SNOWFLAKE QUERY (requires two joins from fact):
SELECT
    fsp.payment_sk,
    de.first_name,
    de.last_name,
    dj.job_title,        -- comes from dim_job (snowflake level)
    dj.job_family,       -- comes from dim_job
    dj.job_level_label,  -- comes from dim_job
    fsp.salary_amount
FROM fact_salary_payment fsp
JOIN dim_employee de ON fsp.employee_sk = de.employee_sk
JOIN dim_job      dj ON de.job_sk       = dj.job_sk      -- snowflake join
WHERE de.is_current = 1
LIMIT 10;

/*
  PURE STAR ALTERNATIVE — embed job attributes directly in dim_employee:
  (This is what the table would look like in a pure star schema)

    dim_employee_star (
        employee_sk         INT PRIMARY KEY,
        emp_id              INT,
        first_name          VARCHAR(50),
        last_name           VARCHAR(50),
        email               VARCHAR(100),
        -- Job attributes embedded directly (no dim_job FK):
        job_title           VARCHAR(150),
        job_family          VARCHAR(100),
        job_level           INT,
        job_level_label     VARCHAR(30),
        -- Department FK still points to dim_department (star):
        dept_sk             INT,
        ...
    )

  PURE STAR QUERY (one fewer join):
    SELECT de.first_name, de.job_title, de.job_family, fsp.salary_amount
    FROM fact_salary_payment fsp
    JOIN dim_employee_star de ON fsp.employee_sk = de.employee_sk
    WHERE de.is_current = 1;

  TRADE-OFF ANALYSIS:
  ┌────────────────────────┬──────────────────────────┬──────────────────────────┐
  │ Criterion              │ Snowflake (current)      │ Pure Star (alternative)  │
  ├────────────────────────┼──────────────────────────┼──────────────────────────┤
  │ Query complexity       │ Extra JOIN to dim_job    │ No extra join needed     │
  │ BI tool friendliness   │ Two hops to get job_fam  │ All attributes in one row│
  │ Storage footprint      │ Less redundancy in dims  │ job attrs repeat per emp │
  │ Taxonomy update cost   │ 1 row in dim_job         │ UPDATE all emp rows      │
  │ SCD2 interaction       │ job_sk FK tracks changes │ job attrs baked into row │
  │ Cardinality risk       │ Low (dim_job is small)   │ N/A (no child table)     │
  └────────────────────────┴──────────────────────────┴──────────────────────────┘

  DECISION: Hybrid is the right call for this domain.
  - dim_job stays normalised (snowflake) because job taxonomy changes
    are infrequent but impactful when they happen.
  - dim_department stays as a direct FK from both dim_employee AND the
    fact tables (star) because dept lookups are the most common filter
    in HR analytics and should not require chaining through dim_employee.
*/

-- ─────────────────────────────────────────────────────────────
-- SECTION 4 — CONFORMED DIMENSION PROOF
-- ─────────────────────────────────────────────────────────────
/*
  CONFORMED DIMENSION DEFINITION:
  A dimension is conformed when it has identical content and meaning
  across multiple fact tables. BI tools can then combine metrics from
  different facts in a single query without producing incorrect results.

  dim_department is a conformed dimension in dm_warehouse:
    fact_salary_payment    references dept_sk
    fact_monthly_headcount references dept_sk
    fact_performance_review references dept_sk
    fact_leave_lifecycle   references dept_sk
    fact_project_coverage  references dept_sk

  This means "Engineering" in a payroll report is the SAME "Engineering"
  in a headcount report and a performance report. A BI tool can pivot
  all three metrics side by side with a single GROUP BY dept_name.

  If dim_department were NOT conformed (e.g., a separate dim_dept_payroll
  and dim_dept_headcount with different dept_id values or naming), a
  combined report would require a manual reconciliation step that is
  error-prone and opaque to consumers.
*/

-- Proof: count distinct dept_sk values in each fact table and show
-- which departments appear across all facts.
SELECT
    d.dept_id,
    d.dept_name,
    d.location,
    MAX(CASE WHEN src.fact_name = 'fact_salary_payment'    THEN src.row_count ELSE 0 END) AS salary_payment_rows,
    MAX(CASE WHEN src.fact_name = 'fact_monthly_headcount' THEN src.row_count ELSE 0 END) AS headcount_rows,
    MAX(CASE WHEN src.fact_name = 'fact_performance_review'THEN src.row_count ELSE 0 END) AS perf_review_rows,
    MAX(CASE WHEN src.fact_name = 'fact_leave_lifecycle'   THEN src.row_count ELSE 0 END) AS leave_rows,
    MAX(CASE WHEN src.fact_name = 'fact_project_coverage'  THEN src.row_count ELSE 0 END) AS project_rows
FROM dim_department d
LEFT JOIN (
    SELECT 'fact_salary_payment'     AS fact_name, dept_sk, COUNT(*) AS row_count
    FROM fact_salary_payment GROUP BY dept_sk
    UNION ALL
    SELECT 'fact_monthly_headcount',  dept_sk, COUNT(*)
    FROM fact_monthly_headcount GROUP BY dept_sk
    UNION ALL
    SELECT 'fact_performance_review', dept_sk, COUNT(*)
    FROM fact_performance_review GROUP BY dept_sk
    UNION ALL
    SELECT 'fact_leave_lifecycle',    dept_sk, COUNT(*)
    FROM fact_leave_lifecycle GROUP BY dept_sk
    UNION ALL
    SELECT 'fact_project_coverage',   dept_sk, COUNT(*)
    FROM fact_project_coverage GROUP BY dept_sk
) src ON d.dept_sk = src.dept_sk
GROUP BY d.dept_id, d.dept_name, d.location
ORDER BY d.dept_id;

/*
  Expected output shape: one row per department from dim_department.
  Every row with populated fact counts confirms dim_department is used
  consistently across all five fact tables — this is the conformed
  dimension guarantee.

  A department with zeros in ALL fact columns is a reference row with
  no activity yet (e.g., a newly created department before the first
  payroll cycle). That is correct — dim rows may exist without
  corresponding fact rows.
*/

-- Simple count cross-check — does every dept_sk in each fact exist in dim_department?
-- (Zero rows = no orphan FKs = conformed)
SELECT 'fact_salary_payment'     AS fact_table, COUNT(*) AS orphan_dept_sk_count
FROM fact_salary_payment fsp
LEFT JOIN dim_department d ON fsp.dept_sk = d.dept_sk
WHERE d.dept_sk IS NULL
UNION ALL
SELECT 'fact_monthly_headcount',  COUNT(*)
FROM fact_monthly_headcount fmh
LEFT JOIN dim_department d ON fmh.dept_sk = d.dept_sk
WHERE d.dept_sk IS NULL
UNION ALL
SELECT 'fact_performance_review', COUNT(*)
FROM fact_performance_review fpr
LEFT JOIN dim_department d ON fpr.dept_sk = d.dept_sk
WHERE d.dept_sk IS NULL
UNION ALL
SELECT 'fact_leave_lifecycle',    COUNT(*)
FROM fact_leave_lifecycle fll
LEFT JOIN dim_department d ON fll.dept_sk = d.dept_sk
WHERE d.dept_sk IS NULL
UNION ALL
SELECT 'fact_project_coverage',   COUNT(*)
FROM fact_project_coverage fpc
LEFT JOIN dim_department d ON fpc.dept_sk = d.dept_sk
WHERE d.dept_sk IS NULL;

-- All five rows should return orphan_dept_sk_count = 0.
