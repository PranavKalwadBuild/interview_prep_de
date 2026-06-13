<!-- Part of data-modelling-patterns: Choosing Right Model, Fan-out Trap, M:N, Hierarchies -->

# Part 5 — Design Decisions and Edge Cases

---

## 16. Choosing the Right Model

**What it solves:** Selecting the modelling approach that fits the use case, team size, and technical constraints.

> **Keywords to spot:** "which model would you use", "how would you design this", "trade-offs", "why star schema over snowflake"

**Decision Matrix:**

| Factor | Normalized (3NF) | Star Schema | Snowflake Schema | Data Vault | Medallion / OBT |
|---|---|---|---|---|---|
| Primary use | OLTP, transactional | OLAP, BI reporting | OLAP, storage-sensitive | Enterprise, multi-source | Lakehouse, self-service |
| Team size | Any | Small–Large | Medium–Large | Large | Small–Medium |
| Schema changes | Easier to adapt | Requires dim changes | Requires dim changes | Most flexible | Moderate |
| Query complexity | High (many joins) | Low (1-hop joins) | Medium | Very high (vault → mart) | Very low (OBT) |
| Auditability | Low | Medium | Medium | Very high | Low–Medium |
| Multiple source systems | Difficult | Difficult | Difficult | Designed for this | Moderate |
| BI tool performance | Poor | Excellent | Good | Poor (needs mart) | Excellent |
| History tracking | Limited | SCD 2 on dims | SCD 2 on dims | Built-in (satellites) | Complex |
| Storage efficiency | High | Medium | High | Low (many tables) | Low (wide tables) |

**Decision flowchart (simplified):**

```
Is this OLTP / transactional? ──Yes──> Normalize to 3NF
         │
         No
         │
Multiple conflicting source systems? ──Yes──> Data Vault 2.0
         │
         No
         │
Single team, self-service analytics? ──Yes──> Medallion + OBT (Gold layer)
         │
         No
         │
Standard BI reporting? ──Yes──> Star Schema (default choice)
         │
         No
         │
Storage-constrained + many hierarchy levels? ──Yes──> Snowflake Schema
```

---

## 17. Fan-out Trap (Chasm Trap)

**What it solves:** Prevents row multiplication that occurs when joining two fact tables through a shared dimension, or when joining a fact table to a dimension that has a 1:N relationship at the wrong level.

> **Keywords to spot:** "double counting", "inflated totals", "row multiplication", "joining two fact tables", "different grains", "sales total is wrong"

**The problem — numerical example:**

You have:
- `fact_sales` at order-line grain: customer C-001 has 3 orders, each $100 = $300 total
- `fact_support_tickets` at ticket grain: customer C-001 has 2 tickets

Both tables share `dim_customer`. You want: "for each customer, show total revenue and total tickets."

**Wrong approach — direct join:**

```sql
-- BAD: this will multiply rows
select
    c.customer_id,
    sum(s.revenue)          as total_revenue,
    count(t.ticket_sk)      as ticket_count
from dim_customer c
left join fact_sales s          on c.customer_sk = s.customer_sk
left join fact_support_tickets t on c.customer_sk = t.customer_sk
group by c.customer_id;
```

**What actually happens:**

For customer C-001:
- 3 sales rows × 2 ticket rows = 6 joined rows
- `sum(revenue)` = $100 × 6 rows where revenue appears = $600 (should be $300)
- `count(tickets)` = 6 (should be 2)

Every metric is wrong. The revenue is doubled because each sale row is joined to each ticket row.

**Correct approach — aggregate each fact independently first, then join:**

```sql
-- GOOD: aggregate each fact to the shared dimension grain first
with customer_sales as (
    select
        customer_sk,
        sum(revenue)        as total_revenue,
        count(*)            as order_count
    from fact_sales
    group by customer_sk
),
customer_tickets as (
    select
        customer_sk,
        count(*)            as ticket_count
    from fact_support_tickets
    group by customer_sk
)
select
    c.customer_id,
    coalesce(s.total_revenue, 0)    as total_revenue,
    coalesce(s.order_count, 0)      as order_count,
    coalesce(t.ticket_count, 0)     as ticket_count
from dim_customer c
left join customer_sales s   on c.customer_sk = s.customer_sk
left join customer_tickets t on c.customer_sk = t.customer_sk;
```

**Now the math works:**
- `customer_sales` has 1 row for C-001: total_revenue = $300
- `customer_tickets` has 1 row for C-001: ticket_count = 2
- Join 1 × 1 = 1 row. Both numbers correct.

**Detecting fan-out:**

```sql
-- Check row counts before and after a suspicious join
select count(*) from fact_sales;                -- N rows
select count(*) from fact_sales
join dim_customer on ...;                       -- should still be ~N rows
-- If count inflates significantly, you have a fan-out
```

**Gotchas:**
- Fan-out is the most dangerous silent bug in data warehousing. The query runs, returns results, and looks plausible. Nobody notices until someone checks the numbers against a source system.
- Whenever joining two fact tables, always aggregate both to the shared dimension grain in CTEs first. No exceptions.
- The problem is worse with outer joins — NULLs from one side get multiplied, distorting COUNT and SUM.

---

## 18. Many-to-Many Relationships

**What it solves:** Handles genuine M:N relationships in dimensional models without fan-out.

> **Keywords to spot:** "product in multiple categories", "patient has multiple diagnoses", "employee in multiple cost centers", "multi-label", "multiple values per entity"

**The bridge table approach (covered in Section 11-E) is the standard solution.** Here's the full pattern with a concrete example:

**Scenario:** A healthcare encounter can have multiple ICD-10 diagnosis codes. Each ICD code appears on multiple encounters.

```sql
create table dim_diagnosis (
    diagnosis_sk        int primary key,
    icd10_code          varchar(10) not null,
    diagnosis_name      varchar(300),
    diagnosis_category  varchar(100),
    is_chronic          boolean
);

create table fact_encounters (
    encounter_sk        bigint primary key,
    patient_sk          bigint  references dim_patient(patient_sk),
    provider_sk         bigint  references dim_provider(provider_sk),
    admit_date_sk       int     references dim_date(date_sk),
    discharge_date_sk   int     references dim_date(date_sk),
    -- grain: one row per patient encounter
    encounter_id        varchar(50),
    los_days            int,            -- length of stay
    total_charges       decimal(12,2)
);

-- Bridge table: one row per encounter-diagnosis pair
create table bridge_encounter_diagnosis (
    encounter_sk        bigint  references fact_encounters(encounter_sk),
    diagnosis_sk        int     references dim_diagnosis(diagnosis_sk),
    diagnosis_sequence  int,            -- 1 = primary diagnosis, 2+ = secondary
    primary key (encounter_sk, diagnosis_sk)
);
```

**Query — total charges by diagnosis category:**

```sql
select
    d.diagnosis_category,
    count(distinct fe.encounter_sk)     as encounter_count,
    sum(fe.total_charges)               as total_charges
from fact_encounters fe
join bridge_encounter_diagnosis bed on fe.encounter_sk    = bed.encounter_sk
join dim_diagnosis d                on bed.diagnosis_sk   = d.diagnosis_sk
group by 1
order by 3 desc;
```

**Warning:** This query will correctly count an encounter once per diagnosis category. But if one encounter has 2 diagnoses in the same category, the encounter is counted twice in that category and `total_charges` is doubled for that category. This is often the desired behavior (the encounter is "attributed" to that category). Document which interpretation you're using.

**Gotchas:**
- Bridge tables shift the complexity from the schema to the query. Every downstream analyst must know the bridge exists.
- If you need charges attributed only to the primary diagnosis, filter `WHERE bed.diagnosis_sequence = 1`.
- Weighted bridges (Section 11-E) are needed when the attribution should be split proportionally, not duplicated.

---

## 19. Hierarchies

**What it solves:** Represents parent-child structures (org charts, product trees, geographic rollups) in SQL tables.

> **Keywords to spot:** "hierarchy", "org chart", "parent-child", "recursive", "rollup", "drill-down", "tree structure", "manager reports"

### Fixed-depth hierarchy

When you know the hierarchy has a fixed number of levels (e.g., always: Company → Division → Department → Team), flatten it into one table.

```sql
-- 4-level org hierarchy, fixed depth
create table dim_org_hierarchy (
    org_node_sk         bigint primary key,
    team_id             varchar(50),
    team_name           varchar(100),
    department_id       varchar(50),
    department_name     varchar(100),
    division_id         varchar(50),
    division_name       varchar(100),
    company_id          varchar(50),
    company_name        varchar(100)
);

-- Every employee row can join directly to this for any level of rollup
create table dim_employee (
    employee_sk         bigint primary key,
    employee_id         varchar(50) not null,
    full_name           varchar(200),
    org_node_sk         bigint  references dim_org_hierarchy(org_node_sk),
    hire_date           date,
    salary              decimal(12,2)
);
```

**Query — headcount by division:**

```sql
select
    h.division_name,
    count(e.employee_sk) as headcount
from dim_employee e
join dim_org_hierarchy h on e.org_node_sk = h.org_node_sk
group by 1;
```

### Variable-depth hierarchy — adjacency list

When depth is unknown (org charts, category trees), store parent-child pairs.

```sql
create table dim_category_tree (
    category_id     varchar(50) primary key,
    category_name   varchar(100),
    parent_id       varchar(50)  references dim_category_tree(category_id),
    depth           int         -- 0 = root
);
```

Querying requires recursive CTEs (covered in `sql_patterns.md` section 17). The adjacency list is simple to maintain but slow to query at arbitrary depths.

### Variable-depth hierarchy — closure table

Pre-computes all ancestor-descendant pairs. Fastest for querying but more complex to maintain.

```sql
-- Stores every ancestor-descendant pair for every node
create table category_closure (
    ancestor_id     varchar(50)  references dim_category_tree(category_id),
    descendant_id   varchar(50)  references dim_category_tree(category_id),
    depth           int,         -- 0 = self-reference, 1 = direct parent, etc.
    primary key (ancestor_id, descendant_id)
);
```

**Query — all products under "Electronics" at any depth:**

```sql
select p.*
from dim_product p
join category_closure cc
    on p.category_id = cc.descendant_id
where cc.ancestor_id = 'CAT-ELECTRONICS'
  and cc.depth > 0;   -- exclude self
```

**Gotchas:**
- Closure tables are the right answer for large hierarchies with frequent "get all descendants" queries. The table size is O(N²) in the worst case (fully nested), but in practice most hierarchies are sparse.
- Fixed-depth flattening is the right answer for BI tools — analysts can simply filter on `division_name` without needing recursive logic.
- Adjacency lists are fine for small hierarchies or when recursive CTE support is robust (Snowflake, BigQuery, Postgres all support it).
