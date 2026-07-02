# Design Decisions — Rationale

Companion to `01-design-decisions.sql`. Explains *why* each pattern is chosen,
how to detect the failure mode, and how to answer the interview question.

---

## 1. The Fan-out Trap (Chasm Trap)

### What it is
When you JOIN two fact tables on a shared dimension key — without pre-aggregating
either side first — the JOIN cardinality multiplies rows before the GROUP BY runs.
An employee on 3 projects contributes their monthly salary three times, inflating
every aggregate (SUM, AVG, COUNT) by the project count.

### How to detect it
- Run the suspicious query and check totals against a known-good source.
- Count rows before and after the JOIN: `SELECT COUNT(*) FROM fact_salary_payment`
  then `SELECT COUNT(*) FROM fact_salary_payment JOIN fact_project_coverage ...`.
  If the second count is larger than the first, fan-out is occurring.
- Look for ratios that match typical project counts (totals inflated ×2 or ×3).

### How to fix it
**Never join two fact tables directly.** Use the *drill-across* technique:
1. Aggregate each fact independently to the desired grain.
2. Join the two result sets on the conformed dimension key (employee_sk, dept_sk).
3. The join is now 1:1 because both sides were pre-aggregated.

The join happens at the *presentation layer* (BI tool, CTE, or application),
not in the raw fact-to-fact query.

---

## 2. Many-to-Many Relationships

Three patterns for handling M:N in different stack contexts:

| Pattern | When to use | Trade-offs |
|---|---|---|
| **Bridge table** (Kimball) | Relational DW, MySQL/Postgres/Redshift | Requires weight integrity check; joins are explicit and auditable |
| **Array column** (Parquet / BigQuery / Snowflake) | Lakehouse / columnar store | Good for read-heavy analytics; hard to filter or explode without UNNEST |
| **Link table** (Data Vault 2.0) | Highly auditable enterprise DW | Hub-Link-Satellite pattern; every relationship is its own Satellite; more tables, higher rigour |

### Bridge table rules
- Each row = one (employee, project) pair.
- `allocation_weight` must sum to 1.0 per employee across all their projects.
  - 0.5 + 0.5 = two projects, equal split
  - 0.6 + 0.4 = two projects, 60/40 split
- Violation check: `SELECT employee_sk, SUM(allocation_weight) FROM bridge_emp_project GROUP BY employee_sk HAVING SUM(allocation_weight) != 1.0`
- Never put salary or headcount into the bridge; it is only a resolution table.

---

## 3. Hierarchies

### Three approaches

| Approach | Best for | Query cost | Maintenance cost |
|---|---|---|---|
| Recursive CTE | OLTP ad-hoc, small datasets, arbitrary depth | O(depth) scan per query | None (reads live data) |
| Pre-flattened closure table (`bridge_hierarchy`) | DW, large orgs, frequent hierarchy queries | O(1) index seek | Rebuild on every org change |
| Snowflake dimension (fixed-depth) | Simple 2-3 level hierarchies (Region → Country → City) | Simple multi-table join | Schema change needed to add levels |

### Why not hardcode manager levels?
- `manager_level_1_emp_id`, `manager_level_2_emp_id` columns break on every reorg.
- Depth is assumed at schema design time; real orgs add VP layers, flatten to fewer tiers, etc.
- Queries must change *column names* (not just *values*) to accommodate new levels.

### Closure table population
Run the recursive CTE (see `01-design-decisions.sql`) and insert every
ancestor-descendant pair — including the self-row (`levels_below = 0`) — into
`bridge_hierarchy`. Rebuild nightly or after each org change event.

---

## 4. Model-Type Decision Checklist

Use this checklist when starting a new fact or dimension table.

```
1. What is the grain?
   → One row per ________ × ________ (e.g., employee × pay month)
   → If you cannot state the grain precisely, do not build the table yet.

2. What fact type?
   → Transactional   — event fires once, row is immutable (salary payment, hire)
   → Periodic snapshot — taken at a fixed cadence regardless of events (headcount)
   → Accumulating snapshot — one row per lifecycle event; columns are updated as
                             status advances (leave request, project milestone)
   → Factless fact    — records that something happened; no numeric measure
                        (project assignment, attendance)

3. Does a dimension change over time?
   → SCD Type 0: static reference (department code)
   → SCD Type 1: overwrite, no history (fix a typo in an email)
   → SCD Type 2: add a new row, preserve history (employee job title change)
   → SCD Type 3: add a "previous value" column (rarely used; lossy)

4. Is there a many-to-many relationship?
   → Yes → add a bridge table with a weight column.
   → No  → FK column in the fact table suffices.

5. Is there a hierarchy?
   → Fixed depth (≤ 3) → snowflake dimension is fine.
   → Variable / deep   → closure table (bridge_hierarchy) in DW;
                          recursive CTE for OLTP.
```

---

## 5. Interview Question: Org Chart in a Data Warehouse

**"How would you model an employee org chart in a data warehouse?"**

Walk through these options in order:

1. **State the problem**: `manager_id` is a self-referencing FK. The depth is
   unknown and changes with org restructuring. Hardcoding levels is brittle.

2. **Option A — Recursive CTE at query time**: works for OLTP and ad-hoc needs.
   MySQL 8.0+ `WITH RECURSIVE` traverses the tree in one statement. Downside:
   re-executed on every query; slow for large orgs or frequent use.

3. **Option B — Closure table in the DW**: pre-compute every ancestor-descendant
   pair nightly. Store in `bridge_hierarchy(ancestor_emp_id, descendant_emp_id,
   levels_below, is_direct_parent)`. Query is a single indexed lookup — O(1)
   regardless of org depth.

4. **Option C — Snowflake dimension**: only for fixed-depth hierarchies. A
   `dim_region` can snowflake to `dim_country` to `dim_continent` because
   geography has a known, stable three-level structure. Employee orgs do not.

5. **Trade-off summary**: closure table is the standard Kimball DW answer.
   Recursive CTE is fine for OLTP or reporting tools that support it natively.
   Never hardcode levels.
