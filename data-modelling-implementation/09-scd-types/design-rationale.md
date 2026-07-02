# SCD Types — Design Rationale

## Overview

Slowly Changing Dimensions (SCDs) describe how a data warehouse handles attribute changes in dimension tables over time. Choosing the wrong type is one of the most common warehouse design mistakes because it either destroys historical accuracy (Type 1 overused) or causes uncontrolled row explosion (Type 2 overused).

---

## SCD Type Reference

| Type | Rule | Storage Cost | Query Complexity | History Fidelity |
|------|------|-------------|-----------------|-----------------|
| **0** | Write once, never update | Lowest (1 row per entity) | Trivial | None — preserves original only |
| **1** | Overwrite in-place | Lowest (1 row per entity) | Trivial | None — old value lost forever |
| **2** | New row per change | High (1 row per change event) | Medium (need date-range or is_current filter) | Full — complete point-in-time history |
| **3** | Add previous-value column | Low (1 row, extra column) | Low | Partial — one step back only |
| **4** | Separate history table for fast-changing attr | Medium (main dim stays slim) | Medium (join to history table) | Full for that attribute |
| **6** | Hybrid: SCD0 + SCD1 + SCD2 | High (same as Type 2) | Medium | Full history + always-current column |

---

## SCD Type 0 — Retain Original

**Rule:** Once written, never update. The ETL pipeline intentionally omits any UPDATE statement for this column.

**When to use:**
- Regulatory and audit fields where the "as-of-contract" value must be preserved
- Original hire salary for compliance reporting
- Founding department name for historical governance

**Gotcha:** Enforcement is purely by convention (ETL discipline), not a database constraint. A `GENERATED ALWAYS AS` column or application-layer validation is the only way to make it truly immutable in MySQL.

---

## SCD Type 1 — Overwrite

**Rule:** UPDATE the row in-place. The previous value is gone.

**When to use:**
- Correcting typos and data-entry errors (emp 22 NULL email, emp 19 salary=0.00)
- Backfilling attributes that arrived late (phone number added 3 months post-hire)
- Non-significant changes where history has no business value (preferred name spelling)

**When NOT to use:** Any attribute where "what was it at time T?" is a business question. If auditors will ask "what was this employee's job title in Q3 2023?", SCD1 is wrong.

---

## SCD Type 2 — Full History

**Rule:** Close the current row (set `expiry_date`, `is_current = 0`), insert a new row. The `employee_sk` surrogate key changes with each new version.

**When to use:**
- Job title changes (classic example — every promotion must be trackable)
- Department transfers when payroll allocation by department must be historically accurate
- Salary band changes when the warehouse is the system of record for compensation history

### The Fact Join Problem

SCD2 causes a subtle issue: **`employee_sk` is not stable across an employee's lifetime.** Alice Johnson has:
- `employee_sk = 101` when she was a Senior Software Engineer (2022-01-01 to 2024-05-31)
- `employee_sk = 215` when she became Engineering Lead (2024-06-01 onwards)

A `fact_salary_payment` row from March 2024 correctly stores `employee_sk = 101`. A fact row from August 2024 stores `employee_sk = 215`. **This is correct by design** — the SK captures the dimension state valid at the time of the event.

The danger is in incorrect ETL: if the fact load always joins on `emp_id` to get the *current* `employee_sk`, all historical fact rows get re-pointed to the new SK after a promotion. Historical payroll then shows Alice's 2023 salary under "Engineering Lead", which never existed.

**Fix:** Always resolve `employee_sk` at fact load time using a date-range join:
```sql
JOIN dim_employee de
  ON de.emp_id          = src.emp_id
 AND de.effective_date <= src.pay_date
 AND (de.expiry_date    > src.pay_date OR de.expiry_date IS NULL)
```

---

## SCD Type 3 — Current + Previous Column

**When to use:** Narrow cases where "one step back" is sufficient — e.g., "show employees who transferred departments within the last cycle" and you only ever care about one prior department.

**Hard limitation:** If an employee changes departments three times, the first two are permanently lost. Only the most recent previous value survives. This makes SCD3 unsuitable for any audit trail requirement.

---

## SCD Type 4 — Mini-Dimension / Attribute History Table

**The real-world problem it solves:**

Consider salary. In a typical company:
- Employee name changes: ~0.1 times per year (marriage, legal)
- Job title changes: ~0.3 times per year (annual promotion cycle)
- Salary changes: ~2 times per year (annual review + mid-year adjustments)

If you apply SCD2 to the full `dim_employee` row every time salary changes, you double the row count every six months. After five years, a 1,000-employee company has ~64,000 dimension rows — mostly identical except for the salary column.

**SCD4 solution:** Keep `dim_employee` as a stable single-row-per-employee table. Put salary into `dim_employee_salary_hist` with `effective_date` / `expiry_date`. The fact table joins `dim_employee` for stable attributes (name, job title) and `dim_employee_salary_hist` for the salary at the time of the fact event.

**Trade-off:** One additional join in every fact query that needs salary. This is usually worth it when the fast-changing attribute changes significantly more often than the rest of the dimension.

---

## SCD Type 6 — Hybrid (1 + 2 + 3)

**Structure:**
- `original_dept_name` — SCD0: captured at first load, never touched
- `current_dept_name` — SCD1: updated on ALL historical rows whenever a change occurs
- `effective_date / expiry_date / is_current` — SCD2: full row versioning

**When to use:** When you have two consumers with different needs:
1. Analytics / BI dashboard that always wants the *current* department (no date-range filter)
2. Audit / compliance report that wants "what department was this employee in on date X?"

With SCD6 you serve both from the same table:
- Current state: `WHERE is_current = 1` — `current_dept_name` is always up-to-date
- Historical state: `WHERE effective_date <= :date AND (expiry_date > :date OR expiry_date IS NULL)` — row content is accurate for that period; `current_dept_name` tells you where they are *now*

**Storage cost:** Same as SCD2 — one row per change event. The extra `original_dept_name` and `current_dept_name` columns are negligible.

---

## The Delete Problem

What happens when an employee record is hard-deleted from the OLTP system?

**Never delete from the dimension.** The warehouse is the system of record for historical fact joins. If `dim_employee` row for `emp_id = 35` is deleted, all `fact_salary_payment` rows with that `employee_sk` become orphans and aggregate queries will silently under-count.

**Correct pattern — soft delete:**
```sql
ALTER TABLE dim_employee ADD COLUMN is_active TINYINT(1) NOT NULL DEFAULT 1;

-- When OLTP deletes emp 35 (Terminated):
UPDATE dim_employee
SET    is_active       = 0,
       termination_date = CURDATE(),
       expiry_date      = CURDATE() - INTERVAL 1 DAY,
       is_current       = 0
WHERE  emp_id = 35;
```

Facts retain their foreign key reference. Reports filter `is_active = 1` for headcount but can still include terminated employees for payroll history.

---

## Interview: "What SCD type would you use for employee job title changes?"

**Answer: SCD Type 2.**

**Why not SCD1?** SCD1 overwrites the previous value. If Alice was promoted from Senior Engineer to Engineering Lead, any historical payroll or project fact joined to her dimension row would show "Engineering Lead" even for periods when she was still a Senior Engineer. Headcount-by-job-title reports for prior quarters would be wrong.

**Why not SCD3?** SCD3 stores only one prior value. An employee who changes titles three times loses all but the most recent previous title. It cannot answer "what was Alice's title in Q2 2022?" if she has had four titles since then.

**Why SCD2?** Every title change creates a new dimension row with a new surrogate key, bounded by `effective_date` and `expiry_date`. Facts written during Alice's Senior Engineer period store the SK pointing to that row. Facts written after her promotion store the new SK. Point-in-time queries are exact. The only cost is increased row count in the dimension table, which is almost always acceptable.

**Follow-up consideration:** If the organisation also needs "what is Alice's current title?" without a date-range filter on every query, layer SCD1 on top (i.e., SCD6): keep `current_job_title` updated on all rows. This gives the best of both worlds at the cost of one extra UPDATE per title change.
