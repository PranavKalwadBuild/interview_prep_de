# Dimension Types — Design Rationale

## 1. Conformed Dimension

### What it is
A conformed dimension is a dimension table that carries **the same meaning, the same surrogate keys, and the same attribute definitions across every fact table that references it**.

In this schema, `dim_department` is conformed: its `dept_sk` foreign key appears in `fact_salary_payment`, `fact_monthly_headcount`, `fact_performance_review`, and `fact_leave_lifecycle`. Every one of those facts uses the same physical table with the same rows.

### The bus architecture
Ralph Kimball's "bus architecture" is the framework that enforces conformance. The bus matrix lists every business process (fact table) as a row and every dimension as a column — a check mark means that fact uses that dimension. Any dimension appearing in two or more facts must be conformed to enable cross-fact queries.

### Why conformance enables drill-across queries
A drill-across query joins results from two separate fact tables using a shared dimension:

```sql
-- Only works because dim_department is conformed across both facts
SELECT dd.dept_name, avg_salary, avg_review_rating
FROM dim_department dd
JOIN (SELECT dept_sk, AVG(salary_amount) FROM fact_salary_payment GROUP BY dept_sk) sp USING (dept_sk)
JOIN (SELECT dept_sk, AVG(rating)        FROM fact_performance_review GROUP BY dept_sk) pr USING (dept_sk);
```

If the two facts had different department lookup tables with different keys or different granularity, this join would be impossible or would produce mismatched results.

### Non-conformed anti-pattern
Non-conformance occurs when the same concept is modeled differently in two facts: different surrogate keys, different level of detail, or different attribute names. Symptoms: reports from two teams produce different numbers for "Engineering headcount"; BI tools cannot join the datasets without a translation layer.


## 2. Junk Dimension

### When to use
Use a junk dimension when a fact table would otherwise carry **5 or more low-cardinality boolean or flag attributes** that do not belong to any single business entity.

Typical indicators:
- `is_contractor`, `is_terminated`, `is_future_hire` (boolean: 2 values each)
- Flag or status codes with 3-10 possible values
- Audit attributes: `created_by_system`, `is_manual_override`

Without a junk dimension, these attributes sit as nullable columns directly on the fact table. Every query that filters on a combination must handle NULLs inline. With a junk dimension, the ETL pre-computes all valid flag combinations, assigns a surrogate key, and the fact carries a single `flag_sk` column.

### What NOT to put in a junk dimension
- **High-cardinality attributes**: department names, city, vendor name — these have too many possible values and change over time; they belong in full dimension tables
- **Attributes with their own descriptive sub-attributes**: anything that has a description, a hierarchy, or additional columns warrants its own dimension
- **Measures**: no numeric values in a dimension table

### Cardinality math
With 5 binary flags, the theoretical maximum is 2^5 = 32 combinations. In practice, most combinations are invalid (e.g., `is_terminated = 1` and `is_future_hire = 1` simultaneously does not make business sense). The junk dimension table will have far fewer rows than the theoretical maximum — often 5-15 rows for a typical HR flag set.


## 3. Role-Playing Dimension

### One physical table, multiple logical roles
A role-playing dimension is a single physical table used in **multiple semantic roles within the same query** or fact table. Each role is represented by a different foreign key column in the fact, each pointing to the same physical dimension.

In `fact_leave_lifecycle`:
- `submit_date_sk` — "the date this request was submitted"
- `approve_date_sk` — "the date this request was approved"
- `start_date_sk` — "the date the leave period begins"
- `end_date_sk` — "the date the leave period ends"

All four columns are foreign keys to `dim_date`. In a query, each is aliased with a meaningful name (`submit`, `approved`, `lv_start`, `lv_end`), giving the same calendar attributes under different business semantics.

`dim_employee` plays a similar role in `fact_performance_review`, where `employee_sk` is the reviewee and `reviewer_sk` is the reviewer — both point to the same physical table.

### BI tool implications
Many BI tools (Tableau, Power BI) do not automatically support role-playing dimensions. They require a separate named **view** per role:

```sql
CREATE VIEW dim_submit_date   AS SELECT * FROM dim_date;
CREATE VIEW dim_approved_date AS SELECT * FROM dim_date;
CREATE VIEW dim_leave_start   AS SELECT * FROM dim_date;
CREATE VIEW dim_leave_end     AS SELECT * FROM dim_date;
```

Each view is then exposed as a separate logical table in the semantic layer with a named relationship to the fact. The underlying physical storage remains a single `dim_date` table.

### Why not just duplicate the table?
Duplication would create four copies of `dim_date`, each requiring independent ETL maintenance. A bug fix or a new fiscal year column would need to be applied four times. The single-table approach keeps maintenance centralized.


## 4. Degenerate Dimension

### What it is
A degenerate dimension is a **natural key from the source system stored directly in the fact table**, with no corresponding dimension table. It is "degenerate" in the sense that it has been dimensionalized down to just a key — there are no additional attributes worth storing in a separate table.

Examples in this schema:
- `fact_leave_lifecycle.leave_request_id` — the source PK from `leave_requests`
- `fact_performance_review.review_id` — the source PK from `performance_reviews`

### When it is appropriate
- The ID is the only attribute — no description, no category, no hierarchy
- The primary use case is **point lookup** ("show me leave request 12") or **traceability** back to the source system
- The ID appears once per fact row (true 1:1 with the grain)

Classic examples in retail: `order_number`, `invoice_number`, `ticket_id` — the only attribute of an order is its number; all other order attributes are captured in the fact or in other dimensions.

### When to create a full dimension instead
Create a dimension table when the natural key has associated attributes:
- If `leave_request_id` had a `priority_level` or `request_category`, those attributes would warrant a `dim_leave_request` table
- If the ID is shared across multiple fact rows (lower granularity than the grain), a dimension table helps avoid repeated NULL checks
- If users need to filter by attributes of the source record rather than just by the ID itself


## 5. Bridge Table

### The multi-valued dimension problem
A standard star schema assumes that each fact row has exactly one value for each dimension. When a fact row can relate to **multiple values of a dimension simultaneously** — an employee on multiple projects, a patient with multiple diagnoses, a product in multiple categories — the star schema breaks down.

The naive solutions fail:
- Comma-separated list in a fact column: impossible to filter or join on
- Multiple project FK columns (`project1_sk`, `project2_sk`, `project3_sk`): fixed cardinality, NULL-heavy, still not queryable by project
- Repeating the salary fact row once per project: **fan-out** — the salary amount is double (or triple) counted

A bridge table resolves the M:N by sitting between the fact and the dimension:

```
dim_employee --< bridge_emp_project >-- (project natural key)
                      allocation_weight
                      effective_date
                      expiry_date
```

### Allocation weights
When a measure from the fact table (e.g., salary) must be attributed across multiple dimension members, `allocation_weight` distributes the measure without double-counting:

```sql
weighted_payroll = salary * allocation_weight
```

An employee with 0.50 weight on Project A and 0.50 weight on Project B contributes half their salary to each project. Summing weighted payroll across all projects for that employee correctly reconstitutes their full salary.

### Double-counting avoidance
The correct pattern is to query the bridge table directly (count rows, sum weights) rather than joining the bridge to the fact and summing the fact measure. When the fact measure must be distributed, apply the weight in the SELECT clause — not by joining and grouping.


## 6. Calendar Dimension

### Why pre-built is faster than computed
Date arithmetic with MySQL functions (`YEAR()`, `MONTH()`, `DAYNAME()`, `WEEK()`) works, but:
- **Not indexable**: `WHERE YEAR(pay_date) = 2024` cannot use an index on `pay_date`; `WHERE pay_date_sk BETWEEN 20240101 AND 20241231` can use an index on the integer key
- **Fiscal year**: non-calendar fiscal years (e.g., FY starts April 1) cannot be derived from `YEAR()` alone; they require application logic or a lookup
- **Locale-specific names**: `DAYNAME()` returns locale-dependent strings; `day_name` in the dimension is always consistent
- **Holiday / special day flags**: no SQL function knows your company's observed holidays; those must be stored in a table

### Pre-computation wins
Every `is_weekend`, `is_month_end`, `fiscal_quarter` column in `dim_date` eliminates a CASE expression or a function call from every query that needs it. On large fact tables, this difference in query execution is significant.

### Fiscal year support
If the organization's fiscal year starts April 1:
- FY2024 Q1 = April 2024 to June 2024
- FY2024 Q2 = July 2024 to September 2024
- FY2024 Q3 = October 2024 to December 2024
- FY2024 Q4 = January 2025 to March 2025

Store `fiscal_year` and `fiscal_quarter` in `dim_date` when loading the ETL. Calendar and fiscal reporting are then interchangeable — swap `year`/`quarter` for `fiscal_year`/`fiscal_quarter` in any query.

### Gap detection via date spine
The most powerful use of a calendar dimension is gap detection. LEFT JOIN any fact table to `dim_date` to find periods where expected events did not occur:

```sql
-- Months where an employee had no salary record
SELECT d.year, d.month, de.emp_id
FROM dim_date d
CROSS JOIN dim_employee de
LEFT JOIN fact_salary_payment f ON f.pay_year = d.year AND f.pay_month = d.month
                                AND f.employee_sk = de.employee_sk
WHERE d.is_month_end = 1 AND f.payment_sk IS NULL;
```

Without the date spine, this query cannot be written cleanly — there is no way to generate the expected set of (month, employee) combinations to LEFT JOIN against.


## Choosing the right dimension type

| Scenario | Dimension type |
|---|---|
| Same dimension used across multiple fact tables | Conformed |
| 5+ low-cardinality boolean flags on a fact | Junk |
| Same table needed under multiple semantic roles in one query | Role-playing |
| Source system PK with no additional attributes | Degenerate |
| M:N relationship between employees and another entity | Bridge table |
| Date-based filtering, fiscal periods, gap detection | Calendar |


## Interview questions

**"What is a role-playing dimension?"**

A role-playing dimension is a single physical dimension table that is referenced multiple times in the same fact table or query, each time under a different alias representing a different business role. The canonical example is a date dimension used as submission date, approval date, and start date in the same fact — one table, three query-time aliases, each exposing the same calendar attributes under a different semantic meaning. Some BI tools require a named view per role to expose each alias as a separate logical table in the semantic layer.

**"When would you use a bridge table?"**

Use a bridge table when a fact row has a many-to-many relationship with a dimension — one employee on multiple projects, one patient with multiple diagnoses. Without a bridge table, the only alternatives are fan-out (which double-counts fact measures), comma-separated lists (which are not queryable in SQL), or fixed multi-column arrays (which cap cardinality). The bridge table sits between the fact and the dimension, optionally carrying an allocation weight to distribute semi-additive measures across dimension members without double-counting.
