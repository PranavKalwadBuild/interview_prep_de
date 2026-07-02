# Design Rationale — OLTP vs OLAP Foundations

## 1. Why OLTP Uses 3NF

Third Normal Form (3NF) is the standard target for transactional databases because it eliminates three classes of data anomaly that would otherwise corrupt operational records.

**The three anomalies 3NF prevents:**

| Anomaly | Example without 3NF | How 3NF fixes it |
|---|---|---|
| Update anomaly | Department name stored in every employee row — rename "Engineering" requires touching 200 rows; partial failure = inconsistent state | Dept name stored once in `departments`; employees hold only `dept_id` |
| Insert anomaly | Cannot record a new department until at least one employee joins it | Departments table is independent; insert dept without employees |
| Delete anomaly | Deleting the last employee in a department loses the department record | Departments persist independently |

**Functional dependencies in the employee domain:**

```
emp_id → first_name, last_name, email, hire_date, job_title, dept_id
dept_id → dept_name, location, cost_center          -- separate table
(emp_id, effective_date) → salary                   -- separate table
```

Each fact is stored exactly once. This means writes are fast (update one row in one table, not hundreds of rows across many tables) and the database can enforce FK constraints, unique constraints, and NOT NULL at the storage layer.

**The cost:** analytical queries require joining 4–6 tables to reconstruct a complete picture. That is acceptable in OLTP because the application knows exactly what it needs, queries by primary key, and returns single-digit row counts.

---

## 2. Why OLAP Denormalizes

A data warehouse serves a fundamentally different workload: aggregations over millions of rows with unpredictable filter combinations. Analysts do not know in advance which columns they will group by. They also do not want to write six-level JOIN chains every time they explore a dataset.

**The star schema answer:** pre-join the descriptive attributes into wide dimension tables. The fact table holds only foreign keys (surrogate) and numeric measures.

**What denormalization buys:**

- **Query simplicity.** `SELECT dept_name, AVG(gross_salary) FROM fact_salary_payment JOIN dim_department ...` — one join, done. No chasing through `employees → departments → salary_history`.
- **Aggregation speed.** Columnar storage engines (Redshift, BigQuery, Snowflake, DuckDB) read only the columns referenced in `SELECT`. A 40-column wide row costs nothing if the query touches 4 columns.
- **BI tool compatibility.** Tableau, Power BI, and Looker all auto-generate SQL from star schemas. They cannot auto-generate correlated subqueries over a 3NF schema.
- **Analyst ergonomics.** A junior analyst can answer "what is average salary by department and quarter?" from a star schema without understanding the source system's normalization choices.

**The cost:** storage duplication (department name repeated in every fact row), and more complex ETL to keep dimensions in sync. Those costs are worth paying when read volume dwarfs write volume by orders of magnitude.

**Rule of thumb:** if your query latency is more important than your storage cost, denormalize. Cloud object storage is cheap; analyst time is not.

---

## 3. ETL vs ELT — When to Use Each

### ETL (Extract → Transform → Load)

Data is cleaned, validated, and reshaped *before* it enters the target system. Transformations run in an orchestration layer (SSIS, Informatica, Spark, Python).

**Use ETL when:**
- The target warehouse has limited compute (on-premise MySQL, traditional RDBMS)
- Sensitive PII must be masked or dropped before it touches the warehouse
- Source-to-target schema differences are large and the warehouse cannot express the transform in SQL
- Storage costs are high and you cannot afford to land raw data

**Downsides:**
- If transform logic changes, historical data is gone — you cannot replay
- Debugging failures requires inspecting intermediate files outside the warehouse
- Two systems to maintain: the transform layer and the warehouse

### ELT (Extract → Load → Transform)

Raw data lands in the warehouse first ("bronze" / raw layer). Transformations are SQL models executed inside the warehouse engine.

**Use ELT when:**
- The warehouse is a cloud MPP system (Snowflake, BigQuery, Redshift, Databricks) — transform compute is elastic and cheap
- You want full data lineage and the ability to replay any transform
- Transformations are version-controlled SQL (dbt) and tested like application code
- Time-to-first-load matters (raw data available to analysts immediately, even if not fully cleaned)

**Cloud data warehouse implications:**
- Snowflake and BigQuery bill per byte scanned / per second of compute — running transforms inside the warehouse is cost-efficient because you scale up for the transform window and scale back down immediately
- dbt makes ELT the default pattern: models are SQL `SELECT` statements, tests are assertions on the output, lineage is auto-documented
- Column masking and row-level security in the warehouse replace pre-load PII scrubbing

**Practical answer for interviews:** "Our team uses ELT with a bronze/silver/gold medallion architecture. Raw data lands in bronze with `_load_ts` and `_batch_id` for lineage. dbt models transform bronze → silver (clean, deduplicated) → gold (star schema facts and dims). This means we can always replay a failed transform without touching the source system."

---

## 4. Three Levels of Data Modelling Applied to the Employee Domain

### Conceptual Model

Describes *what* entities exist and *how they relate*, without implementation detail. Audience: business stakeholders, architects.

```
EMPLOYEE works-in DEPARTMENT
EMPLOYEE has-many SALARY_HISTORY records
EMPLOYEE is-assigned-to many PROJECTS
EMPLOYEE receives PERFORMANCE_REVIEWS
EMPLOYEE raises LEAVE_REQUESTS
DEPARTMENT raises PURCHASE_ORDERS
```

No data types, no PKs, no cardinalities specified at this level. The goal is shared vocabulary with the business.

### Logical Model

Adds attributes, data types (in abstract terms), primary keys, foreign keys, and cardinality. Still implementation-agnostic (could be MySQL, Postgres, Oracle, or a graph DB).

```
EMPLOYEE (emp_id PK, dept_id FK → DEPARTMENT, first_name VARCHAR,
          last_name VARCHAR, email VARCHAR UNIQUE, hire_date DATE,
          job_title VARCHAR, employment_status ENUM)

SALARY_HISTORY (history_id PK, emp_id FK → EMPLOYEE, salary DECIMAL,
                effective_date DATE, change_reason VARCHAR)

DEPARTMENT (dept_id PK, dept_name VARCHAR, location VARCHAR,
            cost_center VARCHAR, manager_id FK → EMPLOYEE)
```

Normalization decisions are made at this level: is salary in `employees` or in a separate `salary_history` table? The answer (separate table) comes from 3NF analysis.

### Physical Model

The actual DDL for a specific database engine. Adds:
- Storage engine (`InnoDB` in MySQL 8.0 for ACID + FK support)
- Index strategy (clustered index on PK, secondary indexes on FK columns and high-cardinality filter columns)
- Partitioning (salary_history partitioned by year for large tables)
- Data type precision (`DECIMAL(12,2)` not `FLOAT` for money)
- NULL vs NOT NULL constraints
- Default values, character sets (`utf8mb4`)

```sql
CREATE TABLE salary_history (
    history_id     INT UNSIGNED    NOT NULL AUTO_INCREMENT,
    emp_id         INT UNSIGNED    NOT NULL,
    salary         DECIMAL(12,2)   NOT NULL,
    effective_date DATE            NOT NULL,
    change_reason  VARCHAR(120)    NULL,
    created_at     TIMESTAMP       NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (history_id),
    INDEX idx_sh_emp_date (emp_id, effective_date DESC),
    CONSTRAINT fk_sh_emp FOREIGN KEY (emp_id) REFERENCES employees (emp_id)
        ON DELETE RESTRICT ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
```

**Interview tip:** Always state which level you are working at. If someone asks "how would you model employee salary?" — say "at the conceptual level, Salary is an attribute of Employee. At the logical level, I would separate it into a SALARY_HISTORY entity with a date range to track changes over time. At the physical level in MySQL, I would use DECIMAL(12,2), partition by year if the table exceeds 10M rows, and add a composite index on (emp_id, effective_date DESC)."

---

## 5. Interview Tips — "Walk Me Through Your Design Approach"

When an interviewer says *"walk me through your design approach"*, they are not asking for a schema dump. They are evaluating your reasoning process. Structure your answer as follows:

**Step 1 — Clarify the workload**

Before designing anything, ask:
- Is this OLTP or OLAP? Read-heavy or write-heavy?
- What are the top 3 queries this schema must serve?
- What is the expected data volume (rows/day) and retention period?
- Are there SLA requirements (query time, freshness)?

A candidate who asks these questions signals that they understand design is workload-driven, not a one-size-fits-all exercise.

**Step 2 — Start conceptual, not physical**

Name the entities and relationships before you touch data types. This shows you can communicate with non-technical stakeholders and that you think top-down.

**Step 3 — Justify normalization decisions explicitly**

Do not just say "I put salary in a separate table." Say *why*: "Salary changes over time. If I store it in the employee row I lose history and create an update anomaly every time someone gets a raise. A separate salary_history table with (emp_id, effective_date) as the natural key preserves full audit history and is in 3NF."

**Step 4 — Address trade-offs proactively**

Every design has costs. Mention them before the interviewer asks:
- "This 3NF design is clean for writes but requires 4 joins for the salary report. In an OLAP context I would denormalize into a fact + dimension model."
- "SCD Type 2 on the employee dimension preserves history but makes current-record lookups slightly more complex — you filter on `is_current = TRUE`."

**Step 5 — Know where your intentional flaws are**

The `dm_oltp` database contains deliberate data quality issues. Knowing them and explaining how your pipeline handles them is a differentiator:
- emp 10/15: NULL salary → `COALESCE(salary, 0)` in ETL, flag in `dim_employee_flags`
- emp 22: NULL email → substitute a synthetic internal email, raise a DQ alert
- emp 19: salary = 0.00 → valid value or data entry error? Flag it; do not silently drop
- emp 35: Terminated status → exclude from headcount facts, include in attrition metrics
- emp 41: future hire_date → reject at silver layer validation, quarantine in DQ table
- Duplicate rows in salary_history / purchase_orders → deduplicate in silver with `ROW_NUMBER() OVER (PARTITION BY natural_key ORDER BY created_at)`

**One-sentence summary for the interview room:**

"I design by starting with the question the business is trying to answer, choosing the normal form that matches the write/read workload, making normalization trade-offs explicit, and building in data quality handling from the start — because dirty source data is not an edge case, it is the default."
