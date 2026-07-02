# 05 — Normalization: Design Rationale

## What this folder covers

How to take a raw, spreadsheet-style data dump and systematically eliminate
redundancy through the normal forms, then consciously reverse that process
for analytics performance. Every concept is grounded in the HR/employee
domain used throughout this project.

---

## Normal Form Progression

### 0NF — Unnormalized

**Rule:** No structure requirements. Repeating groups and multi-valued cells
are allowed.

**Violation it prevents (by removing this):** Nothing is prevented while you
remain here — 0NF _is_ the problem. A column like `projects = 'Phoenix,Apollo'`
cannot be JOINed to a projects table, cannot be indexed, and breaks every
aggregation. Multiple columns for the same attribute (`salary_jan`, `salary_feb`,
`salary_mar`) mean the schema must change every time the time horizon grows.

**HR example:** A spreadsheet export from the payroll system with one row per
employee, three salary columns for Q1, and a comma-delimited list of project
assignments in a single cell.

---

### 1NF — First Normal Form

**Rule:** All column values are atomic (indivisible). No repeating column
groups. The table has a primary key that uniquely identifies each row.

**Violation it prevents:** Positional coupling and string-parsing queries.
If `projects` and `project_roles` are comma-delimited pairs, a role update
requires splitting, modifying, and re-joining the string — error-prone and
unindexable.

**What changed:** Each employee × project × pay_month combination becomes its
own row. `salary_jan/feb/mar` columns collapse to `(pay_month, salary_amount)`.
The composite primary key is `(emp_id, project_id, pay_month)`.

**HR example:** Alice on two projects for three months = 6 rows, each with
a single `salary_amount` and a single `project_role`. `SUM(salary_amount)` now
works correctly.

**Remaining problem:** `project_name` appears in every row for a project —
if project 101 is renamed, every row must be updated. This is a partial
dependency, addressed in 2NF.

---

### 2NF — Second Normal Form

**Rule:** Must be in 1NF, and every non-key attribute must depend on the
_entire_ primary key — no partial dependencies. Partial dependencies only
arise when the primary key is composite.

**Violation it prevents:** Update anomalies on attributes that belong to only
part of the key. In the 1NF table, `project_name` depends only on `project_id`
(not on the full `(emp_id, project_id, pay_month)` key). Renaming project 101
requires updating thousands of rows instead of one.

**What changed:** `nf_2nf_projects` is extracted with `project_id` as its own
PK. `nf_2nf_employees` holds employee-level attributes. `nf_2nf_assignments`
holds only what genuinely depends on the full composite key: `project_role`
and `salary_amount` for that period.

**HR example:** Project "Phoenix" renamed to "Phoenix-v2": one `UPDATE` in
`nf_2nf_projects`. All assignment rows remain unchanged. Before 2NF, you'd
need a bulk update across every assignment row for that project.

**Remaining problem:** `dept_name` and `dept_location` in `nf_2nf_employees`
depend on `dept_id`, not on `emp_id`. This is a transitive dependency,
addressed in 3NF.

---

### 3NF — Third Normal Form

**Rule:** Must be in 2NF, and no non-key attribute may depend on another
non-key attribute. Every non-key attribute must depend on the key, the whole
key, and nothing but the key (Codd's mantra).

**Identifying the transitive dependency in the HR schema:**

```
emp_id → dept_id          (direct: employee belongs to a department)
dept_id → dept_name       (indirect: department name determined by dept_id)
dept_id → dept_location   (indirect: location determined by dept_id)
```

Therefore `emp_id → dept_name` via the non-key intermediary `dept_id`.
`dept_name` and `dept_location` are transitively dependent on `emp_id`.

**Violation it prevents:** Update anomalies when a department attribute
changes. If Engineering moves from Austin to Seattle, in the 2NF table you
must update every Engineering employee row. Miss one row and the table is
inconsistent.

**What changed:** `nf_3nf_departments` is extracted with `dept_id` as its PK,
holding `dept_name` and `dept_location`. `nf_3nf_employees` retains only
`dept_id` as a foreign key — no embedded department attributes.

**dm_oltp is already in 3NF.** The original schema designers performed this
split:
- `dm_oltp.employees`: `emp_id PK`, `dept_id FK` — no `dept_name` column.
- `dm_oltp.departments`: `dept_id PK`, `dept_name`, `location`.

The 0NF and 1NF tables in `01-normalization.sql` reconstruct the pre-normalised
form for teaching purposes only.

**HR example:** Engineering relocates to Seattle: `UPDATE departments SET location = 'Seattle' WHERE dept_id = 2;` — one row, instantly consistent across all employee queries.

---

### BCNF — Boyce-Codd Normal Form

**Rule:** Must be in 3NF, and for every non-trivial functional dependency
`X → Y`, `X` must be a superkey (a set of attributes that can uniquely
identify any row in the table).

**Difference from 3NF:** 3NF permits a non-key attribute to be a determinant
if the dependent attribute is itself part of a candidate key. BCNF forbids
this entirely — every determinant must be a superkey, period.

**Classic counter-example (scheduling):**

| student | course  | teacher  |
|---------|---------|----------|
| Alice   | DB      | Dr. Chen |
| Alice   | ML      | Dr. Park |
| Bob     | DB      | Dr. Lee  |

Functional dependencies:
- `(student, course) → teacher` — composite PK determines teacher
- `teacher → course` — each teacher teaches exactly one course

The table is in 3NF (teacher is part of a candidate key path) but NOT in BCNF
because `teacher → course` and `teacher` is not a superkey.

**BCNF vs 3NF in practice for OLTP:** The distinction rarely matters for the
HR domain. `dm_oltp` is already in BCNF — no such scheduling ambiguity exists.
BCNF becomes relevant in scheduling, timetabling, or complex M:N intersection
tables with overlapping candidate keys. For most OLTP designs, hitting 3NF is
the practical target. BCNF is a refinement applied when a specific anomaly
pattern is discovered through data modelling review.

---

## Deliberate Denormalization — When and Why

### The rule is a starting point, not a finish line

Normalization eliminates redundancy to protect data integrity during writes.
But a read-heavy analytics system has different constraints: it rarely writes,
it queries millions of rows per second, and it must aggregate across many
dimensions simultaneously. Joins are expensive. Normalization works against you.

### When to denormalize

| Scenario | Rationale |
|---|---|
| OLAP / data warehouse dimensions | Star schema embeds attributes directly in dim tables to eliminate joins from fact queries. |
| One Big Table (OBT) for BI tools | A single wide Parquet table lets Tableau/Looker push down column filters without joining. |
| Columnar storage (Redshift, BigQuery, Snowflake) | Column pruning means wide tables are cheap — you only read the columns you query. |
| Reporting aggregates | Pre-computing `avg_salary` in `fact_monthly_headcount` avoids recalculating over fact_salary_payment on every dashboard refresh. |
| High-read, low-write | If a table is written once (ETL load) and queried thousands of times per day, redundancy cost is a one-time payment; join-avoidance is a recurring saving. |

### When NOT to denormalize

- OLTP systems with frequent concurrent writes — denorm tables suffer update anomalies.
- Tables where the redundant attribute changes frequently (e.g., employee name, which can change on marriage/legal name change).
- When referential integrity across the redundant copy cannot be enforced at the application layer.

### The OBT pattern

```sql
-- Parquet layer (pseudocode / BigQuery-style)
CREATE OR REPLACE TABLE analytics.employee_wide AS
SELECT
    emp.*,
    d.dept_name, d.location AS dept_location,
    j.job_family, j.job_level_label
FROM dim_employee emp
JOIN dim_department d ON emp.dept_sk = d.dept_sk
JOIN dim_job j        ON emp.job_sk  = j.job_sk;
```

BI consumers query `employee_wide` directly — no JOIN syntax, no optimizer
decisions, maximum readability for non-SQL analysts.

---

## The `employees.salary` Denormalized Column — Acceptable OLTP Shortcut

`dm_oltp.employees.salary` is a copy of the most recent `salary_history.new_salary`
for that employee. This is a deliberate denormalization in the OLTP layer.

**Why it is acceptable:**
1. `salary_history` is the **authoritative source of truth** — the warehouse
   ETL reads `salary_history` to reconstruct point-in-time salary values.
2. The application writes to `salary_history` first, then updates
   `employees.salary` in the same transaction — consistency is enforced
   at the application layer.
3. The shortcut avoids a correlated subquery (`SELECT new_salary FROM salary_history WHERE emp_id = ? ORDER BY effective_date DESC LIMIT 1`) on every employee lookup.

**Intentional flaws this exposes:**
- `employees.salary IS NULL` for emp 10 and 15 (contractors with no salary history).
- `employees.salary = 0.00` for emp 19 (soft duplicate of emp 18, data entry error).
- Both flaws are preserved into `dm_warehouse.dim_employee` and flagged via
  `dim_employee_flags.has_null_salary = 1`.

---

## Interview: "Is your source schema in 3NF?"

A structured way to assess any source schema during a data engineering interview
or design review:

### Step 1 — Check for 1NF violations
- Any column storing multiple values? (`projects = 'Phoenix,Apollo'`)
- Any column group that repeats? (`salary_jan`, `salary_feb`, `salary_mar`)
- Is there a primary key?

If yes to any: the schema is not even in 1NF. Note this as a serious flaw.

### Step 2 — Check for 2NF violations (composite keys only)
- Which tables have composite primary keys?
- For each non-key column, does it depend on the entire composite key, or
  only part of it?
- Example: in a `project_assignments(emp_id, project_id)` table, does
  `project_name` depend on the pair or just on `project_id`?

If partial dependency exists: 2NF violation. The attribute belongs in a
separate table keyed by only the relevant part of the composite key.

### Step 3 — Check for 3NF violations (all tables)
- For each non-key column `A`, is there another non-key column `B` such that
  `B → A` (B determines A)?
- Example: `employees` table has `dept_id` and `dept_name` — `dept_id → dept_name`
  is a transitive dependency.

If transitive dependency exists: 3NF violation. Extract the determinant and
its dependents into their own table.

### Step 4 — State your conclusion
"The dm_oltp source schema is in 3NF. The only deliberate denormalization is
`employees.salary`, which is a current-value copy maintained by the application
for read performance. The authoritative source for salary history is the
`salary_history` table, which the ETL uses for point-in-time reconstruction."

### Red flags that indicate a schema is NOT in 3NF
- Department name columns appearing in an employee table.
- City/state/zip all in one table with city → state dependency (zip → city,
  city → state: transitive chain).
- Product category description stored in an order line table alongside
  `product_category_id`.
- Manager name stored alongside `manager_id` in the same employee row.
