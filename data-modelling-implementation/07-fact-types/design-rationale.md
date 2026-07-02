# Fact Table Types — Design Rationale

## 1. Transaction Fact

### When to use
A transaction fact records a **single business event at a point in time** — a payment, a sale, a login, an order line.
Use it when:
- The event is atomic and discrete (each occurrence is independent)
- You need the finest-grained audit trail
- Downstream aggregations vary widely (sometimes by day, sometimes by month, sometimes by product)

### Measure additivity

| Additivity | Meaning | Example | Safe operations |
|---|---|---|---|
| **Fully additive** | Can SUM across all dimensions | `salary_amount`, `bonus_amount` | SUM across time, dept, job level |
| **Semi-additive** | Additive across some dims, not others | `account_balance`, `headcount` | SUM across accounts on same date; do NOT SUM across dates |
| **Non-additive** | Cannot meaningfully SUM in any direction | `avg_salary`, `ratio`, `rate` | Always re-derive from atomic rows |

**The non-additive trap**: storing a pre-computed `avg_salary` column and later `SUM`-ing it across departments is a silent data quality bug. The correct pattern is always `SUM(salary) / COUNT(DISTINCT emp_id)` from atomic rows.

### Characteristics
- Rows are **append-only** — never updated, never deleted
- Volume grows with every event — plan partitioning by date for large fact tables
- ETL is simple: INSERT the event row when the event occurs
- Enables point-in-time analysis by filtering on date keys


## 2. Periodic Snapshot Fact

### When to use
A periodic snapshot captures the **state of the world at regular intervals** (daily, weekly, monthly) regardless of whether anything changed.
Use it when:
- You need to answer "what was the headcount / balance / inventory on date X?"
- The underlying dimension changes slowly and you need to track cumulative state
- Period-over-period comparison (LAG, growth rates) is a primary use case

### The no-delete rule
**Rows are never deleted**, even if a department shuts down or its headcount drops to zero.
If a row were deleted, any query asking "what was dept X's headcount in month M?" would return NULL instead of 0.
The ETL must write a row for every (dimension member × time period), populating zeros where appropriate.

### Semi-additivity trap
Headcount is the canonical semi-additive measure:

| Aggregation | Safe? | Reason |
|---|---|---|
| `SUM(headcount)` across departments **on the same date** | Yes — fully additive | 14 Engineering + 5 HR = 19 staff on that date |
| `SUM(headcount)` across **months** for one department | No — gives cumulative occupancy | Summing Jan + Feb + ... + Dec headcount counts each employee 12 times |
| `SUM(avg_salary)` in any direction | Never — non-additive | Must always re-derive from atomic salary rows |

The correct way to query a period range is to pick a single snapshot date (usually the most recent month-end) or to use `LAG()` / window functions to compare two specific points.

### Appropriate for slowly changing totals
Payroll, headcount, inventory on hand, loan balance — all suit the periodic snapshot because the business cares about the accumulated state, not each individual contributing transaction.


## 3. Accumulating Snapshot Fact

### When to use
An accumulating snapshot tracks a **bounded, multi-stage pipeline** where each entity (a leave request, a loan application, a hiring requisition) moves through a defined set of stages.
Use it when:
- The process has a **clear start and end** with a fixed set of milestones
- You want to measure **velocity** (how long each stage takes)
- Reporting needs to show where things are in the pipeline right now

### Multiple date FKs
Each milestone gets its own date foreign key pointing to `dim_date`:
```
submit_date_sk    → when the request was submitted
approve_date_sk   → when it was approved (NULL until approved)
reject_date_sk    → when it was rejected (NULL unless rejected)
start_date_sk     → when the leave period begins
end_date_sk       → when the leave period ends
```
NULL date keys are intentional and semantically meaningful: they indicate the milestone has not yet been reached.

### UPDATE pattern
This is the only standard Kimball fact type that is **updated in place**.
When the source system reports that a request has moved to the next stage, the ETL issues:
```sql
UPDATE fact_leave_lifecycle
SET approve_date_sk  = <date_sk>,
    current_status   = 'Approved',
    days_to_decision = DATEDIFF(approval_date, submit_date)
WHERE leave_request_id = <id>;
```
Because rows are mutable, change-data-capture (CDC) on the source is required to detect state transitions.

### Velocity metrics
The accumulating snapshot makes pipeline velocity trivially queryable:
- `days_to_decision = approve_date − submit_date`
- `avg(days_to_decision) GROUP BY dept` — which departments are slowest to approve leave?
- Count of requests with `approve_date_sk IS NULL` — current backlog size

### Limitations
- Only suitable for **well-defined, bounded** pipelines. If the process has many optional stages, repeated cycles, or no clear end, use a transaction fact instead.
- Requires UPDATE access in the warehouse (complicates immutable / append-only data lake architectures — consider a `current_status` column approach instead).
- History of stage transitions is lost (only the final milestone dates survive). If stage-change history matters, supplement with a transaction fact.


## 4. Factless Fact

### When to use
A factless fact records a **relationship or event that has no associated numeric measure**.
Use it when:
- You need to track enrollment, assignment, attendance, or coverage
- The business question is about **presence or absence** ("which projects have no staff?")
- You need to count relationships (rows) rather than sum a value

### How to answer questions without measures
The "measure" is the **count of rows** or the **presence / absence of a row**:

| Question | Pattern |
|---|---|
| How many employees are on project X? | `COUNT(employee_sk) WHERE project_id = X` |
| Which projects have no employees? | `LEFT JOIN` + `WHERE employee_sk IS NULL` |
| Which employees are on 3+ concurrent projects? | Self-join with overlapping date range condition |
| What % of a department is on a project? | `COUNT(DISTINCT fpc.employee_sk) / COUNT(DISTINCT de.employee_sk)` |

### Coverage analysis use cases
- **Staffing coverage**: are all projects adequately staffed?
- **Training coverage**: which employees have NOT completed a required course?
- **Regulatory coverage**: which assets have no assigned owner?

In all cases, the factless fact is paired with a "list of all possibilities" (a dimension or a `DISTINCT` subquery) and LEFT-joined to find the missing rows.


## Choosing the right fact type

> "Is your event atomic (transaction fact), a regular state capture (periodic snapshot), a lifecycle (accumulating snapshot), or a relationship (factless fact)?"

| Criterion | Transaction | Periodic Snapshot | Accumulating Snapshot | Factless |
|---|---|---|---|---|
| Event is atomic, timestamped | Yes | No | No | No |
| State is captured at regular intervals | No | Yes | No | No |
| Entity moves through defined stages | No | No | Yes | No |
| No numeric measure — only a relationship | No | No | No | Yes |
| Rows are inserted only | Yes | Yes (new month) | No (also UPDATEd) | Yes |
| Rows are never deleted | Yes | Yes (no-delete rule) | No (sometimes) | Yes |
| Supports period-over-period LAG | Possible | Native | No | No |


## Interview question

**"What's the difference between a transaction fact and a periodic snapshot, and when would you use each?"**

A **transaction fact** records each business event as it occurs — one row per event, append-only, finest granularity. Use it when you need to analyze individual events (every payment, every sale), when aggregation windows vary widely, or when drill-through to a single transaction matters.

A **periodic snapshot** captures the state of the world at fixed intervals regardless of whether anything changed. Use it when the question is "what is the current/historical level of something?" rather than "what events happened?" The canonical example is headcount: you do not want to re-derive headcount from every hire and termination transaction; you want to read the pre-computed snapshot for the month.

The critical distinction: transaction facts are **event-driven and sparse** (a row exists only if an event occurred); periodic snapshots are **time-driven and dense** (a row exists for every period, even if the value is zero). The no-delete rule and the semi-additivity of measures like headcount are defining properties of the periodic snapshot.
