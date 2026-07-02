<!-- sql-patterns: Window Functions — Running Aggregates + ROWS vs RANGE Deep Dive -->

# Window Functions — Running Aggregates

## What it solves

Compute cumulative or moving aggregates (SUM, AVG, COUNT, MIN, MAX) over an ordered window.

## Keywords to spot

> "cumulative", "running total", "year-to-date", "month-to-date", "so far",
> "up to this point", "all previous rows", "expanding window",
> "balance to date", "net position", "progressively", "accumulate",
> "by end of", "how much so far", "total through", "up to and including"

## Business Context

- **Fintech:** Cumulative deposits by a user up to each transaction date; running net position (buys minus sells) per asset; year-to-date P&L per portfolio
- **E-commerce:** Running total revenue per day; cumulative GMV per seller per quarter; track whether a customer has crossed a loyalty reward threshold
- **SaaS:** Cumulative signups over time; running count of feature activations; waterfall chart of MRR additions and churn each month
- **HR/Analytics:** Year-to-date headcount growth; cumulative attrition count per quarter; running total of training hours completed per employee
- **Logistics:** Running count of deliveries completed per driver per shift; cumulative distance driven per vehicle per month

## Boilerplate

```sql
-- Pattern: Cumulative SUM (running total)
SELECT
    user_id,
    trade_date,
    trade_amount,
    SUM(trade_amount) OVER (
        PARTITION BY user_id
        ORDER BY trade_date
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ) AS cumulative_amount
FROM trades;

-- Pattern: Cumulative COUNT
SELECT
    user_id,
    executed_at,
    COUNT(*) OVER (
        PARTITION BY user_id
        ORDER BY executed_at
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ) AS trade_number   -- which trade is this for the user (1st, 2nd, 3rd...)
FROM trades;

-- Pattern: Running MAX (track highest price seen so far)
SELECT
    trade_date,
    trading_pair,
    close_price,
    MAX(close_price) OVER (
        PARTITION BY trading_pair
        ORDER BY trade_date
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ) AS all_time_high_so_far
FROM daily_prices;
---

### ROWS BETWEEN vs RANGE BETWEEN — Deep Dive

#### Why window frames exist at all

When you write a window function like `SUM(amount) OVER (PARTITION BY user_id ORDER BY trade_date)`, SQL needs to answer a precise question for every single row:

> **"Which other rows in this partition contribute to the aggregate for THIS row?"**

That subset of contributing rows is called the **window frame**. Without specifying it explicitly, the database picks a default — and that default is frequently not what you expect.

**The default frame rules:**

| `OVER(...)` clause | Default frame applied |
|---|---|
| `OVER()` — no ORDER BY | `ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING` (entire partition) |
| `OVER(ORDER BY col)` — ORDER BY but no frame | `RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW` |
| `OVER(ORDER BY col ROWS BETWEEN ...)` | Exactly as you specified |

The critical danger: **the default when you have an ORDER BY is RANGE-based**, and RANGE handles ties in a way that produces silent, unexpected results.

---

#### Frame boundary syntax

Both ROWS and RANGE use the same boundary keywords:

```sql
FUNCTION() OVER (
    PARTITION BY ...
    ORDER BY ...
    <ROWS|RANGE|GROUPS> BETWEEN <start_bound> AND <end_bound>
)
```

**Available boundary values:**

| Boundary | Meaning |
|---|---|
| `UNBOUNDED PRECEDING` | The very first row of the partition |
| `N PRECEDING` | N units before the current row (rows or value offset) |
| `CURRENT ROW` | The current row itself |
| `N FOLLOWING` | N units after the current row |
| `UNBOUNDED FOLLOWING` | The very last row of the partition |

**Common frame recipes:**

```sql
-- All rows from start of partition to current row (cumulative)
ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW

-- Entire partition (grand total on every row)
ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING

-- Rolling 7-row window (current + 6 preceding)
ROWS BETWEEN 6 PRECEDING AND CURRENT ROW

-- Rolling window centred on current row (3 before, 3 after)
ROWS BETWEEN 3 PRECEDING AND 3 FOLLOWING

-- Only the current row (same as no frame for non-aggregate functions)
ROWS BETWEEN CURRENT ROW AND CURRENT ROW
---

### ROWS BETWEEN — physical row offset

`ROWS` counts **actual physical rows** in the ordered partition. "3 PRECEDING" means exactly the 3 rows immediately before the current row in the result order, regardless of the values in those rows.

```

Partition ordered by trade_date:

 Row | trade_date  | amount | ROWS frame (ROWS BETWEEN 2 PRECEDING AND CURRENT ROW)
-----|-------------|--------|----------------------------------------------
  1  | 2024-01-01  |  100   | frame = {row1}           → SUM = 100
  2  | 2024-01-02  |  200   | frame = {row1, row2}     → SUM = 300
  3  | 2024-01-02  |  150   | frame = {row1, row2, row3} → SUM = 450  ← both Jan 2 rows included
  4  | 2024-01-03  |  300   | frame = {row2, row3, row4} → SUM = 650
  5  | 2024-01-05  |  250   | frame = {row3, row4, row5} → SUM = 700

```

ROWS counts rows, not dates. Notice rows 2 and 3 share the same date — ROWS treats them as separate physical rows.

---

### RANGE BETWEEN — logical value offset

`RANGE` defines the frame based on **the value of the ORDER BY column**, not physical row position. "CURRENT ROW" in RANGE means all rows whose ORDER BY value equals the current row's value. "N PRECEDING" means all rows whose ORDER BY value is within N of the current row's value.

```

Same partition, same data, but using RANGE BETWEEN 2 PRECEDING AND CURRENT ROW:

 Row | trade_date  | amount | RANGE frame (value-based, ORDER BY trade_date)
-----|-------------|--------|----------------------------------------------
  1  | 2024-01-01  |  100   | date range: [Dec 30 – Jan 1] → {row1}   → SUM = 100
  2  | 2024-01-02  |  200   | date range: [Dec 31 – Jan 2] → {row1, row2, row3} → SUM = 450
  3  | 2024-01-02  |  150   | date range: [Dec 31 – Jan 2] → {row1, row2, row3} → SUM = 450  ← same as row 2!
  4  | 2024-01-03  |  300   | date range: [Jan 1 – Jan 3]  → {row1, row2, row3, row4} → SUM = 750
  5  | 2024-01-05  |  250   | date range: [Jan 3 – Jan 5]  → {row4, row5} → SUM = 550

```

Key observations:

- Rows 2 and 3 are tied on `trade_date` (Jan 2). RANGE treats them **identically** — both get the same SUM because both see the same frame (all rows with date between Jan 1 and Jan 2).
- Row 5 (Jan 5) skips Jan 4 entirely because there is no row for Jan 4. RANGE "looks back 2 calendar days", not "looks back 2 rows".

---

### The default frame trap — silent wrong results

This is the most important gotcha in all of window functions:

```sql
-- This looks innocent but has the default RANGE frame:
SELECT
    user_id,
    trade_date,
    amount,
    SUM(amount) OVER (
        PARTITION BY user_id
        ORDER BY trade_date     -- ← no explicit frame!
        -- default is: RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ) AS running_total
FROM trades;
```sql

With data:

```

user_id | trade_date  | amount
--------|-------------|-------
  U1    | 2024-01-01  |  100
  U1    | 2024-01-01  |  200   ← tied on trade_date
  U1    | 2024-01-02  |  150

```

**RANGE result (default — wrong for most use cases):**

```

user_id | trade_date  | amount | running_total
--------|-------------|--------|---------------
  U1    | 2024-01-01  |  100   |   300   ← both Jan 1 rows see SUM = 300 (RANGE includes all ties)
  U1    | 2024-01-01  |  200   |   300   ← same! both see the full Jan 1 group
  U1    | 2024-01-02  |  150   |   450

```

**ROWS result (explicit — almost always what you want):**

```

user_id | trade_date  | amount | running_total
--------|-------------|--------|---------------
  U1    | 2024-01-01  |  100   |   100   ← only this row
  U1    | 2024-01-01  |  200   |   300   ← this row + prior row
  U1    | 2024-01-02  |  150   |   450   ← all three

```sql

```sql
-- Always be explicit to avoid the tie-expansion trap:
SUM(amount) OVER (
    PARTITION BY user_id
    ORDER BY trade_date
    ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW   -- ← explicit ROWS
)
---

#### When to use ROWS

Use `ROWS` in the vast majority of cases:

| Scenario | Use |
|---|---|
| Cumulative / running total | `ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW` |
| Rolling N-row moving average | `ROWS BETWEEN N-1 PRECEDING AND CURRENT ROW` |
| Any ORDER BY column with possible ties | `ROWS` — avoids tie-expansion surprises |
| FIRST_VALUE / LAST_VALUE | Always use `ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING` |
| ROW_NUMBER, RANK, LAG, LEAD | Frame clause not applicable — these ignore it |

```sql
-- 7-row rolling average (last 7 data points, not last 7 days)
AVG(close_price) OVER (
    PARTITION BY trading_pair
    ORDER BY trade_date
    ROWS BETWEEN 6 PRECEDING AND CURRENT ROW
)

-- Cumulative sum (strictly accumulating, tie-safe)
SUM(amount) OVER (
    PARTITION BY user_id
    ORDER BY executed_at      -- timestamp: likely unique, but use ROWS anyway
    ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
)
---

### When to use RANGE

Use `RANGE` when you want to aggregate **all rows that share the same ORDER BY value** as one logical unit, or when you need a **time-distance-based** window on irregular data:

| Scenario | Use |
|---|---|
| "Include all rows tied at this date in the running total" | `RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW` |
| Time-distance window on sparse/irregular dates | `RANGE BETWEEN INTERVAL '7' DAY PRECEDING AND CURRENT ROW` |
| Grand total that must equal the same value for all tied rows | `RANGE` |

```sql
-- Time-based rolling 7-day window (irregular dates — RANGE is the right tool here)
-- This includes ALL rows within 7 calendar days, not just 7 physical rows
SUM(amount) OVER (
    PARTITION BY user_id
    ORDER BY trade_date          -- must be DATE or numeric for RANGE intervals
    RANGE BETWEEN INTERVAL '7' DAY PRECEDING AND CURRENT ROW
)

-- Grand total (same value on every row in the partition)
-- Both ROWS and RANGE produce the same result here, but RANGE makes the intent clear
SUM(amount) OVER (
    PARTITION BY user_id
    RANGE BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING
)
Is your ORDER BY column unique (no ties possible)?
  └─ Yes → Either works, but ROWS is safer habit
  └─ No  → Do you WANT all tied rows to be treated as one logical group?
              └─ Yes → RANGE
              └─ No  → ROWS (gives each tied row its own physical frame)

Do you want exactly N preceding rows?
  └─ Yes → ROWS

Do you want all rows within N days/units of the current row's value?
  └─ Yes → RANGE (with interval offset)

Do you want the whole partition?
  └─ Either works; ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING is clearest
---


A third frame mode you may encounter:

`GROUPS` counts **distinct ORDER BY values** (not physical rows, not value distances). "1 GROUPS PRECEDING" means "the group of rows with the immediately preceding distinct value".

```sql
-- GROUPS frame: 1 preceding distinct date + current date group
SUM(amount) OVER (
    PARTITION BY user_id
    ORDER BY trade_date
    GROUPS BETWEEN 1 PRECEDING AND CURRENT ROW
)
-- For dates: 2024-01-01 (100, 200), 2024-01-02 (150)
-- Row on 2024-01-02 sees frame = {all Jan 1 rows} + {all Jan 2 rows} = 100+200+150 = 450
-- Useful when you want "current group + N groups back" regardless of how many rows are in each group
---


