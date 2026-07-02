# data-modelling-implementation

Runnable MySQL 8.0+ implementations of every pattern in `../Data_modelling/`,
using the same employee/department dataset as `sql-implementation` and
`pyspark-implementation`.

---

## Quick Start

Run scripts in this order:

```
00-setup/01-source-oltp-schema.sql   -- creates dm_oltp + 9 OLTP tables
00-setup/02-warehouse-schema.sql     -- creates dm_warehouse + 10 DW tables
00-setup/03-seed-source-data.sql     -- seeds 41 employees, 8 departments
<any pattern folder>                 -- independent; run in any order
```

Connect to MySQL 8.0+ and execute each file with:

```bash
mysql -u <user> -p < 00-setup/01-source-oltp-schema.sql
mysql -u <user> -p < 00-setup/02-warehouse-schema.sql
mysql -u <user> -p < 00-setup/03-seed-source-data.sql
```

---

## Databases

| Database | Purpose |
|---|---|
| `dm_oltp` | OLTP source — normalized employee/department schema with intentional data flaws |
| `dm_warehouse` | Star schema warehouse — dims, facts, and bridge tables |

---

## Schema Overview

### dm_oltp (9 tables)

| Table | Description |
|---|---|
| `employees` | 41 rows; contains NULL salaries, NULL email, salary=0, future hire_date |
| `departments` | 8 departments; Engineering has 14/41 employees (34% skew) |
| `jobs` | Job titles and families |
| `leave_requests` | Employee leave applications |
| `projects` | Project master |
| `employee_projects` | Source M:N join table |
| `salary_history` | Historical salary records |
| `performance_reviews` | Annual review scores |
| `audit_log` | Change tracking for SCD demos |

### dm_warehouse (10 tables)

| Table | Type | Grain |
|---|---|---|
| `dim_date` | Dimension | One row per calendar day |
| `dim_department` | Dimension (SCD0) | One row per department (static) |
| `dim_employee` | Dimension (SCD2) | One row per employee version |
| `dim_job` | Dimension (SCD0) | One row per job title |
| `fact_salary_payment` | Transaction fact | Employee × pay month |
| `fact_monthly_headcount` | Periodic snapshot | Department × month |
| `fact_leave_lifecycle` | Accumulating snapshot | One row per leave request |
| `fact_project_coverage` | Factless fact | Employee × project assignment |
| `bridge_emp_project` | Bridge table | Employee × project with weight |
| `bridge_hierarchy` | Bridge table | Ancestor-descendant org pairs |

---

## Folder Map

| Folder | Patterns covered | Key SQL file(s) | Source in Data_modelling/ |
|---|---|---|---|
| `00-setup/` | Schema creation, seed data | `01-source-oltp-schema.sql`, `02-warehouse-schema.sql`, `03-seed-source-data.sql` | — |
| `01-foundations/` | OLTP vs OLAP, row vs column store | `01-oltp-vs-olap.sql` | `01-foundations/` |
| `02-extraction-patterns/` | Full load, incremental, CDC | `01-extraction-patterns.sql` | `02-extraction-patterns/` |
| `03-load-strategies/` | Truncate-load, upsert, merge | `01-load-strategies.sql` | `03-load-strategies/` |
| `04-keys-and-cardinality/` | Surrogate vs natural keys, FK cardinality | `01-keys-and-cardinality.sql` | `04-keys-and-cardinality/` |
| `05-normalization/` | 1NF → 3NF → BCNF, denorm trade-offs | `01-normalization.sql` | `05-normalization/` |
| `06-star-schema/` | Full star schema DDL | `01-star-schema-ddl.sql` | `06-star-schema/` |
| `07-fact-types/` | Transaction, periodic snapshot, accumulating snapshot, factless | `01-fact-types.sql` | `07-fact-types/` |
| `08-dimension-types/` | Conformed, junk, role-playing, degenerate, slowly changing | `01-dimension-types.sql` | `08-dimension-types/` |
| `09-scd-types/` | SCD 0/1/2/3 — DDL + ETL merge patterns | `01-scd-types.sql` | `09-scd-types/` |
| `10-modern-stack/` | Medallion architecture, lake-house patterns | `01-modern-stack.sql` | `10-modern-stack/` |
| `11-design-decisions/` | Fan-out trap, M:N bridge, org hierarchy | `01-design-decisions.sql` | `11-design-decisions/` |
| `12-edge-cases/` | Late-arriving facts, NULL policy, partitioning, skew | `01-edge-cases.sql` | `12-edge-cases/` |

---

## Key Design Decisions

| Dimension / Fact | Decision | Rationale |
|---|---|---|
| `dim_employee` | SCD Type 2 | Job title and department changes must be tracked historically so salary facts reference the correct role |
| `dim_department` | SCD Type 0 | Department codes and names are stable reference data; changes are rare enough to handle as corrections |
| `dim_job` | SCD Type 0 | Job family and level labels are controlled vocabulary; new titles get new rows |
| `fact_salary_payment` | Transaction fact; grain = emp × pay month | Each payment is an immutable event; append-only; supports point-in-time payroll analysis |
| `fact_monthly_headcount` | Periodic snapshot; grain = dept × month | Headcount must be compared across months even when no hire/term event occurs |
| `fact_leave_lifecycle` | Accumulating snapshot; grain = leave request | A single leave request progresses through submit → approve → active → close; columns are updated in place |
| `fact_project_coverage` | Factless fact; grain = emp × project assignment | Records that an assignment exists; no natural numeric measure; coverage is the measure |
| `bridge_emp_project` | M:N bridge with `allocation_weight` | An employee can work on multiple projects; weights (summing to 1.0 per employee) enable proportional salary attribution |

---

## Intentional Data Flaws

These flaws are present in the seed data and are used across multiple pattern
folders to demonstrate real-world handling.

| Flaw | Where it surfaces |
|---|---|
| emp 10, 15: `salary = NULL` | `fact_salary_payment.salary_amount = NULL`; SUM skips silently; COUNT(*) vs COUNT(salary_amount) differ — demonstrated in `12-edge-cases/` |
| emp 22: `email = NULL` | `dim_employee.email = NULL`; SCD Type 1 correction pattern shown in `09-scd-types/` (overwrite without a new row) |
| emp 19: `salary = 0.00` | Soft duplicate / data-quality flag; `0.00` is not NULL but is suspicious; detected and flagged in `12-edge-cases/` |
| emp 35: `status = Terminated`, `termination_date IS NULL` initially | SCD2 adds a new row when the termination date is populated; NULL → NOT NULL transition shown in `09-scd-types/` and `12-edge-cases/` |
| emp 41: `hire_date` in the future | Future-dated hire; filter guard (`hire_date <= CURRENT_DATE`) demonstrated in `02-extraction-patterns/` |
| Engineering dept: 14/41 employees (34%) | Partition skew — query planner impact in MySQL, bucketing/salting trade-offs in distributed engines — discussed in `12-edge-cases/` |
