<!-- sql-implementation: SQL Pattern Implementations — Navigation Index -->

# SQL Pattern Implementations

Runnable MySQL 8.0+ implementations of every pattern in `../sql-patterns/`, using a single shared employee/department dataset with intentional real-world data flaws (NULLs, duplicates, skew).

**Run order:** `00-setup/01-database-and-schema.sql` → `00-setup/02-seed-data.sql` → any pattern file.

---

## Schema Overview

**Database:** `` `sql-patterns` ``

| Table | Rows | Key Flaws Embedded |
|---|---|---|
| `departments` | 8 | `budget` NULL for Executive dept |
| `employees` | 41 | NULL salary (2 rows), NULL email (1 row), `0.00` salary soft-dup, future `hire_date`, terminated employee |
| `salary_history` | 34 | One exact duplicate row |
| `projects` | 12 | NULL `budget`, `end_date` < `start_date` |
| `project_assignments` | 25 | One exact duplicate row, NULL `hours_billed` |
| `performance_reviews` | 20 | NULL `rating`, NULL `reviewer_id` |
| `emp_events` | 40 | Missing logout events, NULL `session_id` rows |
| `purchase_orders` | 25 | One exact duplicate row, NULL `dept_id` orphan |
| `leave_requests` | 20 | Overlapping date ranges, NULL `leave_type` |

**Skew:** Engineering has 14/41 employees (34%) — intentional distribution skew.

---

## Folder Map

| Folder | Patterns Covered | Source Files |
|---|---|---|
| [00-setup/](00-setup/) | DDL + seed data | `01-database-and-schema.sql`, `02-seed-data.sql` |
| [01-basics/](01-basics/) | Data types, SELECT, filtering, aggregates, CASE WHEN | sql-patterns 01–03 |
| [02-joins/](02-joins/) | INNER/LEFT/RIGHT/FULL OUTER, self-join, cross-join | sql-patterns 02 |
| [03-nulls/](03-nulls/) | NULL fundamentals, 3VL, COALESCE, NULLIF, IFNULL | sql-patterns 04–05 |
| [04-dates/](04-dates/) | Date functions, parsing, truncation, transformation | sql-patterns 06–07 |
| [05-window-functions/](05-window-functions/) | Ranking, LAG/LEAD, running aggregates, FIRST/LAST VALUE | sql-patterns 09–14 |
| [06-gap-islands-sessions/](06-gap-islands-sessions/) | Gap-and-islands, sessionization | sql-patterns 15–16 |
| [07-dedup-top-n/](07-dedup-top-n/) | Deduplication, top-N per group | sql-patterns 17–18 |
| [08-time-patterns/](08-time-patterns/) | Rolling windows, period-over-period, date spine | sql-patterns 19–21 |
| [09-cohort-funnel/](09-cohort-funnel/) | Cohort retention, funnel analysis | sql-patterns 22–23 |
| [10-scd/](10-scd/) | SCD Type 1 and Type 2 | sql-patterns 24–28 |
| [11-advanced-sql/](11-advanced-sql/) | Conditional agg, self-joins, recursive CTEs, pivoting, string agg, set ops, anti-join | sql-patterns 29–40 |
| [12-data-quality/](12-data-quality/) | DQ checks, percentiles, histograms, median/mode | sql-patterns 34, 37, 39, 40 |
| [13-performance/](13-performance/) | Query optimisation patterns | sql-patterns 41 |

---

## Key Data Points to Know

**Employees with NULL salary:** emp 10 (contractor), emp 15 (new hire pending payroll).
**Soft duplicate:** emp 18 (Rachel Clark) and emp 19 (Samuel Clark) — same dept, same hire date, same title, but emp 19 has salary=0.00.
**Terminated employee:** emp 35 (Irene Nelson), termination_date=2024-03-31.
**Future hire date:** emp 41 (Riley Scott), hire_date=2025-08-01.

**Sessionization threshold:** 30 minutes idle gap = new session.
**Funnel steps (emp_events):** `login` → `view_payslip` → `update_profile` → `submit_leave` → `logout`.
**Gap-and-islands (leave_requests):** consecutive calendar days = same island; weekend gap = separate island.
**Market basket (purchase_orders):** item_category drives co-occurrence; one NULL dept_id orphan.
