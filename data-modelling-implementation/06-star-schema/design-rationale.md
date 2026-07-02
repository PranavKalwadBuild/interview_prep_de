# 06 — Star Schema: Design Rationale

## What this folder covers

How the dimensional model for the HR/employee domain was designed, why it
looks the way it does, and how to defend every structural decision in an
interview. All design choices are grounded in the same 41-employee dm_oltp
source used throughout this project.

---

## Kimball's 4-Step Design Process — Applied to the Employee Domain

Kimball's methodology is not optional scaffolding — it is the discipline that
prevents the most expensive data warehouse bugs. Work through all four steps
before writing a single CREATE TABLE.

### Step 1 — Select the business process

A business process is the operational activity that generates the measurements
you want to analyse. Choose the process, not the report.

| Business Process | Source system event | Resulting fact table |
|---|---|---|
| Payroll disbursement | Monthly pay run | `fact_salary_payment` |
| Headcount reporting | Month-end snapshot query | `fact_monthly_headcount` |
| Leave management | Leave request lifecycle | `fact_leave_lifecycle` |
| Project staffing | Project assignment record | `fact_project_coverage` |
| Performance management | Review submission | `fact_performance_review` |

**Why separate processes need separate fact tables:** each process has its own
grain. Mixing payroll amounts (per employee) with headcount (per department)
in the same fact table forces you to either repeat headcount for every employee
row (fan-out) or leave salary NULL for headcount rows. Both choices corrupt
aggregations.

### Step 2 — Declare the grain

The grain is the precise definition of what one row in the fact table
represents. It must be stated in business terms, at the most atomic level
available from the source, before you identify dimensions or facts.

**Grain declarations for this schema:**

| Fact table | Grain |
|---|---|
| `fact_salary_payment` | One row per employee per monthly pay period |
| `fact_monthly_headcount` | One row per department per calendar month-end |
| `fact_leave_lifecycle` | One row per leave request (accumulating) |
| `fact_project_coverage` | One row per employee per project assignment |
| `fact_performance_review` | One row per performance review event |

**Why getting grain wrong is the #1 modelling mistake:**

Grain errors are silent. The table populates, the ETL runs, the dashboard
loads — but the numbers are wrong, and nobody knows why until a senior analyst
spots that the Engineering payroll is exactly 8x higher than expected and
traces it back to 8 department rows being joined to each salary row.

Common grain mistakes:
- **Mixed grain:** storing both per-employee salary and per-department headcount
  in the same fact table. Aggregations are wrong in both directions.
- **Too coarse:** declaring grain as "annual" when monthly data is available.
  You lose the ability to answer "which month had the highest attrition?"
- **Too fine:** declaring grain as "daily" when the source only generates
  monthly records. You end up with empty rows or fabricated daily splits.
- **Unspecified:** "one row per payment" is not specific enough. Does that
  mean one row per payslip (one per employee per month)? Or one row per
  payslip line item (multiple rows per employee per month)? The grain must
  be unambiguous.

**The grain test:** if you can insert a row that does not match your grain
declaration without triggering a constraint violation, your unique key
constraint does not enforce the grain. Add a UNIQUE KEY on the combination
of surrogate keys that define the grain.

### Step 3 — Identify the dimensions

Dimensions provide the context ("who, what, when, where") for each measurement.
Once the grain is fixed, the dimensions are the natural grouping axes for
the business questions the fact table is meant to answer.

For `fact_salary_payment` (grain: employee x pay month):

| Question | Dimension |
|---|---|
| Who received it? | `dim_employee` |
| What role did they hold at that time? | `dim_job` |
| When was it paid? | `dim_date` (role: pay date) |
| Which department were they in? | `dim_department` |
| Any data quality flags? | `dim_employee_flags` |

**Dimension design decisions:**

- `dim_date` is **role-playing**: one physical table, aliased differently
  in each context (`pay_date`, `hire_date`, `snapshot_date`, `submit_date`).
  This avoids creating five identical calendar tables.
- `dim_employee_flags` is a **junk dimension**: five boolean flags
  (is_contractor, is_terminated, is_future_hire, has_null_salary, has_null_email)
  that do not belong to any single entity are grouped into one small table.
  The alternative — five nullable columns in the fact table — widens every
  fact row, makes index design harder, and cannot be filtered efficiently
  by combination.
- `dim_employee` is **SCD Type 2**: when an employee changes department or
  job title, a new dim_employee row is inserted with a new `effective_date`
  and the old row's `expiry_date` is set. `fact_salary_payment` stores the
  `employee_sk` that was current during the pay period — so historical
  payroll reports show the employee in the correct department/role, not their
  current one.

### Step 4 — Identify the facts

Facts are the numeric measurements the business process generates. They must
be additivity-class labelled before any aggregation query is written.

| Fact table | Measure | Additivity |
|---|---|---|
| `fact_salary_payment` | `salary_amount` | Additive (sum across any dim) |
| `fact_salary_payment` | `bonus_amount` | Additive |
| `fact_monthly_headcount` | `headcount` | Semi-additive (sum across depts OK, sum across months is NOT) |
| `fact_monthly_headcount` | `total_payroll` | Semi-additive |
| `fact_monthly_headcount` | `avg_salary` | Non-additive (never SUM this) |
| `fact_leave_lifecycle` | `duration_days` | Additive |
| `fact_leave_lifecycle` | `days_to_decision` | Additive (per-request measure) |

**Non-additive measures in practice:** `avg_salary` is stored in
`fact_monthly_headcount` as a convenience for single-department lookups.
When a cross-department average is needed, always re-derive:
`SUM(total_payroll) / SUM(headcount)`. Never `AVG(avg_salary)` — that
produces a simple mean of department averages, which ignores department
size and is statistically incorrect.

---

## Star vs Snowflake Trade-off for the Employee Domain

### What the current schema actually is

The `dm_warehouse` schema is a **hybrid**:
- **Star** for the core structure: facts join directly to
  `dim_department`, `dim_date`, `dim_employee_flags`, and `dim_employee`.
- **Snowflake element** for job taxonomy: `dim_employee.job_sk` points to `dim_job`.

### Why not pure star?

Embedding all `dim_job` attributes directly into `dim_employee` would mean:
- Every one of the 41 current employees would repeat `job_family`,
  `job_level`, `job_level_label` for their job title.
- SCD2 creates new `dim_employee` rows when an employee changes department.
  With embedded job attributes, a job taxonomy reorganisation (e.g., "Data
  Engineer" moves from Engineering to Analytics family) would require updating
  every historical SCD2 row for every Data Engineer — polluting historical
  records.
- `dim_job` has ~20 distinct rows. The extra join is trivially cheap.

### Why not full snowflake?

A full snowflake would also normalise `dim_department` into child tables
(separate city, region, and budget tables). That introduces extra joins
for the most common filter in HR analytics. Department is the first GROUP BY
in almost every HR report. The pure snowflake saves storage at the cost of
query complexity and BI tool join configuration.

### The decision matrix

| Criterion | Pure Star | Hybrid (current) | Pure Snowflake |
|---|---|---|---|
| Query joins from fact | Fewest | 1 extra for dim_job | Most |
| BI tool setup effort | Minimal | Minimal (1 extra join) | High |
| Storage footprint | Highest redundancy | Moderate | Lowest |
| Taxonomy update risk | Highest | Low (1 row in dim_job) | Lowest |
| Analyst comprehension | Easiest | Easy | More cognitive load |

**Decision:** hybrid is optimal for this 41-employee domain. The snowflake
element is limited to `dim_job`, where the taxonomy update benefit justifies
the join. Everything else is star.

---

## Conformed Dimensions — Why dim_department Must Be Identical Across All Facts

### Definition

A conformed dimension has identical column definitions, surrogate keys, and
business meaning across every fact table that references it. `dept_sk = 3` means
"HR department" in `fact_salary_payment`, `fact_monthly_headcount`,
`fact_performance_review`, `fact_leave_lifecycle`, and `fact_project_coverage`
— all pointing to the same physical row in `dim_department`.

### Why it matters

Without conformance, cross-process analysis breaks. If `dept_sk = 3` meant
HR in the payroll model but Customer Success in the headcount model (because
someone built the headcount dim from a different source), then a combined
report showing payroll + headcount by department would silently mix HR payroll
with Customer Success headcount. The numbers look plausible — they are wrong.

### How conformance is enforced in this schema

1. **Single physical table**: `dm_warehouse.dim_department` is the only
   department dimension. There is no `dim_dept_payroll` or `dim_dept_headcount`
   variant.
2. **Single ETL load path**: all five fact table ETL processes look up
   `dept_sk` by joining to the same `dim_department` using `dept_id` (natural
   key from dm_oltp). The surrogate key assignment is centralised.
3. **Foreign key constraints**: every fact table has a FK to `dim_department.dept_sk`.
   An orphan dept_sk in any fact table would fail at load time.

### Conformed dimension anti-patterns to watch for

- Building department-specific dimension tables for each reporting domain.
- Storing different levels of granularity in different copies (e.g., top-level
  department in one fact, sub-department in another) and calling both
  `dim_department`.
- Not matching on natural key — if two ETL processes both insert "Engineering"
  but generate different `dept_sk` values, conformance is broken even if the
  data looks the same.

---

## The Fan-Out Trap — Introduction

Fan-out (also called "row multiplication" or "double counting") occurs when
a fact table is joined to a dimension or another fact table and the join
produces more rows than the fact table's grain.

**Simple example:** if `fact_salary_payment` is at the grain of
employee x pay month (one row), and you try to join it to
`fact_monthly_headcount` (grain: dept x month) without aggregating first,
every salary row for Engineering employees will be duplicated by the number of
headcount snapshot rows for Engineering — producing a SUM(salary_amount) that
is wrong by exactly the number of months in the headcount fact.

The fix is always to aggregate each fact to the same grain before joining,
or to use a BI tool that handles multi-fact queries correctly (e.g., separate
queries with a post-JOIN in the presentation layer).

The fan-out trap is covered fully in `11-design-decisions/` with worked
examples showing the wrong query, the wrong result, and the correct approach.

---

## Interview: "Walk me through how you'd design a star schema for an HR system"

A structured answer using Kimball's 4 steps, with the domain-specific details
that signal depth of understanding:

---

**Step 1 — Pick the business process**

"The first question I ask is: what is the operational process generating the
data? For HR, the most important processes are payroll (a monthly transaction),
headcount (a periodic snapshot), and leave management (an accumulating lifecycle).
Each gets its own fact table because they have different grains."

**Step 2 — Declare the grain**

"For payroll, the grain is one row per employee per monthly pay period. I
choose monthly because that matches the source system's pay cycle — going
daily would fabricate data, going annual would lose monthly variance.
Getting this wrong produces fan-out or missing data, so I always write the
grain declaration as a comment in the DDL before writing any column definitions."

**Step 3 — Identify the dimensions**

"For the payroll fact, I need: the employee (who), their job role (what they do),
the department (where), the date (when), and a junk dimension for data quality
flags. The employee dimension uses SCD Type 2 because people change jobs and
departments — historical payroll reports must show the role they held at the
time, not their current role."

**Step 4 — Identify the facts**

"Salary amount and bonus amount are additive — safe to sum across any
dimension. I document this because BI tools aggregate by default, and a
non-additive measure like average salary must never be summed — it should be
re-derived from totals."

**On star vs snowflake**

"I would choose a hybrid. The core facts join directly to the main dimensions
(star) for query simplicity. I would normalise the job taxonomy into a separate
dim_job (snowflake element) because job families reorganise occasionally and
I do not want to update every employee row when they do. Everything else stays
flat in the dimension."

**On conformed dimensions**

"Department is a conformed dimension — the same dim_department table and the
same dept_sk values are used in payroll, headcount, leave, and project facts.
This lets me write a single GROUP BY dept_name across all four facts in a BI
tool without reconciliation work. I enforce this by centralising the
surrogate key assignment in the ETL's dimension lookup step."

**On the SCD2 / fact interaction**

"The fact table stores the employee_sk that was current at the time of the
payment, not the employee's current sk. This is the critical point — if Alice
was promoted in April, her March salary row should show her pre-promotion role.
If the ETL always uses the latest is_current=1 employee_sk, historical role
reporting is wrong. The fix is to look up employee_sk using the pay_date
against the SCD2 effective_date / expiry_date range."
