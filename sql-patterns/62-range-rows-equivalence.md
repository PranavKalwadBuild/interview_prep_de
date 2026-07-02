<!-- sql-patterns: RANGE vs ROWS — When They Produce Identical Output -->

# RANGE vs ROWS — When They Produce Identical Output

Companion to `13-window-default-frame.md`, which covers when RANGE and ROWS *differ*.
This file catalogs every case where they produce *identical* output, with proof through a single dataset.

---

## The Dataset

All examples use this table. Memorize it — you will trace every output against it.

```sql
CREATE TABLE sales (
    sale_id   INT,
    rep_id    INT,
    sale_date DATE,
    amount    INT
);

INSERT INTO sales VALUES
(1, 101, '2024-01-01', 100),
(2, 101, '2024-01-02', 150),
(3, 101, '2024-01-03', 200),
(4, 101, '2024-01-03', 250),  -- ties row 3 on sale_date within rep 101
(5, 102, '2024-01-01', 300),
(6, 102, '2024-01-04', 600),
(7, 102, '2024-01-07', 700);  -- gaps: Jan 5 and Jan 6 are absent
```

Key properties:
- **Rep 101, rows 1–4** — has a date tie (rows 3 & 4 share `2024-01-03`). Demonstrates where RANGE ≠ ROWS.
- **Rep 102, rows 5–7** — all dates unique. Demonstrates Case 3 (unique ORDER BY).
- **`sale_id` 1–7** — consecutive integers, no gaps, no duplicates. Demonstrates Case 5 (N-offset equivalence).

---

## Quick Reference

| Case | Condition | Frame | Why identical |
|------|-----------|-------|---------------|
| 1 | `ROW_NUMBER` / `RANK` / `DENSE_RANK` / `NTILE` / `LAG` / `LEAD` | any | Frame clause is ignored by these functions |
| 2 | Any function, any data | `UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING` | Both anchors are absolute — peer groups irrelevant |
| 3a | Unique ORDER BY values per partition | `UNBOUNDED PRECEDING AND CURRENT ROW` | Peer group = 1 row = physical current row |
| 3b | Unique ORDER BY values per partition | `CURRENT ROW AND UNBOUNDED FOLLOWING` | Same reason |
| 3c | Unique ORDER BY values per partition | `CURRENT ROW AND CURRENT ROW` | Same reason |
| 4 | Each partition has exactly 1 row | any | No neighbors to include or exclude |
| 5 | ORDER BY on consecutive integers (no gaps, no duplicates) | `N PRECEDING AND N FOLLOWING` | Value range [v−N, v+N] = exact same rows as N physical neighbors |

---

## Case 1 — Frame-Ignorant Functions

`ROW_NUMBER`, `RANK`, `DENSE_RANK`, `NTILE`, `LAG`, `LEAD` compute based on the ORDER BY sort order, not the frame. The frame clause is parsed and accepted syntactically but has zero effect on output.

```sql
SELECT
    sale_id,
    rep_id,
    sale_date,
    amount,
    ROW_NUMBER() OVER (
        PARTITION BY rep_id ORDER BY sale_date
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ) AS rn_rows,
    ROW_NUMBER() OVER (
        PARTITION BY rep_id ORDER BY sale_date
        RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ) AS rn_range,
    RANK() OVER (
        PARTITION BY rep_id ORDER BY sale_date
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ) AS rank_rows,
    RANK() OVER (
        PARTITION BY rep_id ORDER BY sale_date
        RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ) AS rank_range,
    LAG(amount, 1) OVER (
        PARTITION BY rep_id ORDER BY sale_date
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ) AS lag_rows,
    LAG(amount, 1) OVER (
        PARTITION BY rep_id ORDER BY sale_date
        RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ) AS lag_range
FROM sales
ORDER BY rep_id, sale_date, sale_id;
```

Output:

```
sale_id | rep_id | sale_date  | amount | rn_rows | rn_range | rank_rows | rank_range | lag_rows | lag_range
1       | 101    | 2024-01-01 | 100    | 1       | 1        | 1         | 1          | NULL     | NULL
2       | 101    | 2024-01-02 | 150    | 2       | 2        | 2         | 2          | 100      | 100
3       | 101    | 2024-01-03 | 200    | 3       | 3        | 3         | 3          | 150      | 150
4       | 101    | 2024-01-03 | 250    | 4       | 4        | 3         | 3          | 200      | 200
5       | 102    | 2024-01-01 | 300    | 1       | 1        | 1         | 1          | NULL     | NULL
6       | 102    | 2024-01-04 | 600    | 2       | 2        | 2         | 2          | 300      | 300
7       | 102    | 2024-01-07 | 700    | 3       | 3        | 3         | 3          | 600      | 600
```

`rn_rows = rn_range`, `rank_rows = rank_range`, `lag_rows = lag_range` for every row — including rows 3 and 4 which tie on `sale_date`.

**Why:** The engine sorts the partition by the ORDER BY column, then assigns ranks or offsets based on position in that sorted order. It never consults the frame. The frame concept does not exist in the execution model for these functions.

**Applies to:** `ROW_NUMBER`, `RANK`, `DENSE_RANK`, `NTILE(n)`, `LAG(col, n)`, `LEAD(col, n)`.

**Does NOT apply to:** `SUM`, `AVG`, `COUNT`, `MIN`, `MAX`, `FIRST_VALUE`, `LAST_VALUE`, `NTH_VALUE` — all of these read the frame.

---

## Case 2 — `UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING`

Both anchors are absolute — they pin to the start and end of the partition.
Peer-group expansion, the only mechanism by which RANGE differs from ROWS, has no role when both ends are already at the partition boundary.

```sql
SELECT
    sale_id,
    rep_id,
    sale_date,
    amount,
    SUM(amount) OVER (
        PARTITION BY rep_id ORDER BY sale_date
        ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING
    ) AS sum_rows,
    SUM(amount) OVER (
        PARTITION BY rep_id ORDER BY sale_date
        RANGE BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING
    ) AS sum_range,
    AVG(amount) OVER (
        PARTITION BY rep_id ORDER BY sale_date
        ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING
    ) AS avg_rows,
    AVG(amount) OVER (
        PARTITION BY rep_id ORDER BY sale_date
        RANGE BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING
    ) AS avg_range,
    MIN(amount) OVER (
        PARTITION BY rep_id ORDER BY sale_date
        ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING
    ) AS min_rows,
    MIN(amount) OVER (
        PARTITION BY rep_id ORDER BY sale_date
        RANGE BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING
    ) AS min_range
FROM sales
ORDER BY rep_id, sale_date, sale_id;
```

Output:

```
sale_id | rep_id | amount | sum_rows | sum_range | avg_rows | avg_range | min_rows | min_range
1       | 101    | 100    | 700      | 700       | 175      | 175       | 100      | 100
2       | 101    | 150    | 700      | 700       | 175      | 175       | 100      | 100
3       | 101    | 200    | 700      | 700       | 175      | 175       | 100      | 100
4       | 101    | 250    | 700      | 700       | 175      | 175       | 100      | 100
5       | 102    | 300    | 1600     | 1600      | 533      | 533       | 300      | 300
6       | 102    | 600    | 1600     | 1600      | 533      | 533       | 300      | 300
7       | 102    | 700    | 1600     | 1600      | 533      | 533       | 300      | 300
```

All `_rows = _range` across every row and every function, including the tied-date rows 3 and 4.

**Why:** The frame `UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING` always equals the entire partition. Whether the engine thinks about "peer groups" or "physical offsets" does not matter — the result is the same complete set of rows.

**Practical note:** `SUM(amount) OVER (PARTITION BY rep_id)` (no ORDER BY, no explicit frame) is equivalent — the default frame when there is no ORDER BY is `RANGE UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING`. Writing `ROWS UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING` explicitly gives the same output.

---

## Case 3 — Unique ORDER BY Values + `CURRENT ROW` Boundary

**Core rule:** `CURRENT ROW` means different things:
- `ROWS CURRENT ROW` = this one physical row.
- `RANGE CURRENT ROW` = all rows whose ORDER BY value equals this row's value (the peer group).

When every row in a partition has a **unique ORDER BY value**, the peer group at any row contains exactly one row — the current row itself. Therefore `RANGE CURRENT ROW = ROWS CURRENT ROW`.

This makes any frame boundary involving `CURRENT ROW` produce identical output when ORDER BY values are unique per partition.

### Case 3a — `UNBOUNDED PRECEDING AND CURRENT ROW`

Rep 102 has unique dates per partition (Jan 1, Jan 4, Jan 7):

```sql
SELECT
    sale_id,
    rep_id,
    sale_date,
    amount,
    SUM(amount) OVER (
        PARTITION BY rep_id ORDER BY sale_date
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ) AS running_rows,
    SUM(amount) OVER (
        PARTITION BY rep_id ORDER BY sale_date
        RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ) AS running_range
FROM sales
ORDER BY rep_id, sale_date, sale_id;
```

Output:

```
sale_id | rep_id | sale_date  | amount | running_rows | running_range
1       | 101    | 2024-01-01 | 100    | 100          | 100
2       | 101    | 2024-01-02 | 150    | 250          | 250
3       | 101    | 2024-01-03 | 200    | 450          | 700   ← RANGE expands: Jan 3 peer group = rows 3,4
4       | 101    | 2024-01-03 | 250    | 700          | 700
5       | 102    | 2024-01-01 | 300    | 300          | 300
6       | 102    | 2024-01-04 | 600    | 900          | 900
7       | 102    | 2024-01-07 | 700    | 1600         | 1600
```

Rep 102 rows are identical (`running_rows = running_range`). Rep 101 diverges at row 3 because the Jan 3 peer group includes both rows 3 and 4, so `RANGE CURRENT ROW` at row 3 already includes row 4's amount.

### Case 3b — `CURRENT ROW AND UNBOUNDED FOLLOWING`

```sql
SELECT
    sale_id,
    rep_id,
    sale_date,
    amount,
    SUM(amount) OVER (
        PARTITION BY rep_id ORDER BY sale_date
        ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    ) AS suffix_rows,
    SUM(amount) OVER (
        PARTITION BY rep_id ORDER BY sale_date
        RANGE BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    ) AS suffix_range
FROM sales
ORDER BY rep_id, sale_date, sale_id;
```

Output:

```
sale_id | rep_id | sale_date  | amount | suffix_rows | suffix_range
1       | 101    | 2024-01-01 | 100    | 700         | 700
2       | 101    | 2024-01-02 | 150    | 600         | 600
3       | 101    | 2024-01-03 | 200    | 450         | 450
4       | 101    | 2024-01-03 | 250    | 250         | 450   ← RANGE: start boundary = Jan 3 peer (rows 3,4)
5       | 102    | 2024-01-01 | 300    | 1600        | 1600
6       | 102    | 2024-01-04 | 600    | 1300        | 1300
7       | 102    | 2024-01-07 | 700    | 700         | 700
```

Rep 102 rows are identical. Rep 101 diverges only at row 4: `ROWS` gives 250 (only row 4 remains), but `RANGE` gives 450 because `CURRENT ROW` at row 4 expands to the Jan 3 peer group, pulling row 3 back into the frame start.

### Case 3c — `CURRENT ROW AND CURRENT ROW`

```sql
SELECT
    sale_id,
    rep_id,
    sale_date,
    amount,
    SUM(amount) OVER (
        PARTITION BY rep_id ORDER BY sale_date
        ROWS BETWEEN CURRENT ROW AND CURRENT ROW
    ) AS single_rows,
    SUM(amount) OVER (
        PARTITION BY rep_id ORDER BY sale_date
        RANGE BETWEEN CURRENT ROW AND CURRENT ROW
    ) AS single_range
FROM sales
ORDER BY rep_id, sale_date, sale_id;
```

Output:

```
sale_id | rep_id | sale_date  | amount | single_rows | single_range
1       | 101    | 2024-01-01 | 100    | 100         | 100
2       | 101    | 2024-01-02 | 150    | 150         | 150
3       | 101    | 2024-01-03 | 200    | 200         | 450   ← RANGE: both Jan 3 rows → 200+250
4       | 101    | 2024-01-03 | 250    | 250         | 450   ← RANGE: both Jan 3 rows → 200+250
5       | 102    | 2024-01-01 | 300    | 300         | 300
6       | 102    | 2024-01-04 | 600    | 600         | 600
7       | 102    | 2024-01-07 | 700    | 700         | 700
```

Rep 102 rows are identical. Rep 101 rows 3 and 4 diverge because `RANGE CURRENT ROW AND CURRENT ROW` at Jan 3 includes both peers (200 + 250 = 450), whereas `ROWS` confines each row to exactly itself.

---

## Case 4 — Single-Row Partitions

When a partition contains exactly one row, any frame under ROWS or RANGE resolves to that single row.
There are no neighboring rows to include or exclude, so peer-group logic has nothing to operate on.

```sql
-- PARTITION BY sale_id: each partition = exactly 1 row (sale_id is unique)
SELECT
    sale_id,
    amount,
    SUM(amount) OVER (
        PARTITION BY sale_id ORDER BY amount
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ) AS sum_ubp_cr_rows,
    SUM(amount) OVER (
        PARTITION BY sale_id ORDER BY amount
        RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ) AS sum_ubp_cr_range,
    SUM(amount) OVER (
        PARTITION BY sale_id ORDER BY amount
        ROWS BETWEEN 2 PRECEDING AND 2 FOLLOWING
    ) AS sum_2_rows,
    SUM(amount) OVER (
        PARTITION BY sale_id ORDER BY amount
        RANGE BETWEEN 2 PRECEDING AND 2 FOLLOWING
    ) AS sum_2_range,
    LAST_VALUE(amount) OVER (
        PARTITION BY sale_id ORDER BY amount
        ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING
    ) AS last_rows,
    LAST_VALUE(amount) OVER (
        PARTITION BY sale_id ORDER BY amount
        RANGE BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING
    ) AS last_range
FROM sales
ORDER BY sale_id;
```

Output:

```
sale_id | amount | sum_ubp_cr_rows | sum_ubp_cr_range | sum_2_rows | sum_2_range | last_rows | last_range
1       | 100    | 100             | 100              | 100        | 100         | 100       | 100
2       | 150    | 150             | 150              | 150        | 150         | 150       | 150
3       | 200    | 200             | 200              | 200        | 200         | 200       | 200
4       | 250    | 250             | 250              | 250        | 250         | 250       | 250
5       | 300    | 300             | 300              | 300        | 300         | 300       | 300
6       | 600    | 600             | 600              | 600        | 600         | 600       | 600
7       | 700    | 700             | 700              | 700        | 700         | 700       | 700
```

Every `_rows = _range` for every frame variant, including `N PRECEDING AND N FOLLOWING`.

**Why:** With one row per partition, the window is `[that row, that row]` regardless of how the frame is specified. Value offsets, physical row counts, and peer group expansion all collapse to the same single-row result.

**Real-world occurrence:** Deduplication intermediate stages; joins that create a surrogate key unique per output row; profiling queries where each metric is isolated in its own partition.

---

## Case 5 — Consecutive Integers + N-Offset Frame

`RANGE BETWEEN N PRECEDING AND N FOLLOWING` is **value-arithmetic**: includes rows where `ORDER BY value BETWEEN (current_value − N) AND (current_value + N)`.

`ROWS BETWEEN N PRECEDING AND N FOLLOWING` is **physical row count**: includes the N rows before and N rows after the current row in sorted order.

These two are equivalent **only when** the ORDER BY column is a sequence of consecutive integers with no gaps and no duplicates, because the value interval `[v−N, v+N]` then contains exactly the same rows as the N physical neighbors.

```sql
-- ORDER BY sale_id: values are 1,2,3,4,5,6,7 — consecutive, no gaps, no duplicates
SELECT
    sale_id,
    amount,
    SUM(amount) OVER (
        ORDER BY sale_id
        ROWS BETWEEN 1 PRECEDING AND 1 FOLLOWING
    ) AS sum_1_rows,
    SUM(amount) OVER (
        ORDER BY sale_id
        RANGE BETWEEN 1 PRECEDING AND 1 FOLLOWING
    ) AS sum_1_range,
    SUM(amount) OVER (
        ORDER BY sale_id
        ROWS BETWEEN 2 PRECEDING AND 2 FOLLOWING
    ) AS sum_2_rows,
    SUM(amount) OVER (
        ORDER BY sale_id
        RANGE BETWEEN 2 PRECEDING AND 2 FOLLOWING
    ) AS sum_2_range
FROM sales
ORDER BY sale_id;
```

Output:

```
sale_id | amount | sum_1_rows | sum_1_range | sum_2_rows | sum_2_range
1       | 100    | 250        | 250         | 450        | 450
2       | 150    | 450        | 450         | 700        | 700
3       | 200    | 600        | 600         | 1000       | 1000
4       | 250    | 750        | 750         | 1500       | 1500
5       | 300    | 1150       | 1150        | 2050       | 2050
6       | 600    | 1600       | 1600        | 1850       | 1850
7       | 700    | 1300       | 1300        | 1600       | 1600
```

All `_rows = _range`. Trace sale_id = 4 (amount = 250) to confirm:

```
N=1:
  ROWS 1 PREC TO 1 FOLL: physical rows 3,4,5 → amounts 200+250+300 = 750
  RANGE 1 PREC TO 1 FOLL: sale_id IN [3, 5] = {3,4,5} → amounts 200+250+300 = 750  ✓

N=2:
  ROWS 2 PREC TO 2 FOLL: physical rows 2,3,4,5,6 → amounts 150+200+250+300+600 = 1500
  RANGE 2 PREC TO 2 FOLL: sale_id IN [2, 6] = {2,3,4,5,6} → amounts 150+200+250+300+600 = 1500  ✓
```

**Why:** With consecutive integers and no gaps, the value interval `[v−N, v+N]` contains exactly the same integers as the N physical neighbors in the sorted sequence. Value arithmetic and physical row counting produce the same set.

### Where this equivalence breaks

**Break 1 — Gap in values.** Rep 102 dates are Jan 1, Jan 4, Jan 7 (gaps of 3 days).

```sql
SELECT
    sale_id, sale_date, amount,
    SUM(amount) OVER (
        PARTITION BY rep_id ORDER BY sale_date
        ROWS BETWEEN 1 PRECEDING AND 1 FOLLOWING
    ) AS sum_1_rows,
    SUM(amount) OVER (
        PARTITION BY rep_id ORDER BY sale_date
        RANGE BETWEEN INTERVAL '1' DAY PRECEDING AND INTERVAL '1' DAY FOLLOWING
    ) AS sum_1d_range
FROM sales
WHERE rep_id = 102
ORDER BY sale_date;
```

Output:

```
sale_id | sale_date  | amount | sum_1_rows | sum_1d_range
5       | 2024-01-01 | 300    | 900        | 300          ← gap: Jan 2,3 absent, RANGE sees only Jan 1
6       | 2024-01-04 | 600    | 1600       | 600          ← gap: Jan 3,5 absent, RANGE sees only Jan 4
7       | 2024-01-07 | 700    | 1300       | 700          ← gap: Jan 6,8 absent, RANGE sees only Jan 7
```

`ROWS` includes physical neighbors; `RANGE` value interval [date−1, date+1] finds no rows in the gaps.

**Break 2 — Duplicate values.** If sale_id were not unique (e.g., two rows with sale_id = 3):

```sql
-- Hypothetical: two rows with sale_id=3
-- RANGE BETWEEN 1 PRECEDING AND 1 FOLLOWING at sale_id=3 value:
--   value interval = [2, 4] = {2, 3a, 3b, 4} — includes both id=3 rows
-- ROWS BETWEEN 1 PRECEDING AND 1 FOLLOWING at physical row 3a:
--   physical = {row 2, row 3a, row 3b} — 1 before, current, 1 after
-- These sets differ when sale_id=3 has more than one row.
```

**Rule:** Case 5 equivalence holds if and only if the ORDER BY column forms a gap-free, duplicate-free integer sequence within the window partition.

---

## Why This Is Asked in Interviews

An interviewer asking "when do RANGE and ROWS give the same result?" is probing whether you understand that:

1. **Most running totals in production have unique timestamps per partition** — which is why using the default RANGE frame often goes undetected. The bug only surfaces when two events land on the exact same timestamp.

2. **The default frame is RANGE, not ROWS** — so understanding when RANGE = ROWS tells you which code you can trust without an explicit frame and which code is silently wrong.

3. **Frame-ignorant functions are a common interview trap** — candidates who do not know that `ROW_NUMBER` ignores the frame will attempt to use the frame to control ROW_NUMBER behavior and be confused when it does nothing.

The practical interview answer:

> "RANGE and ROWS produce identical results in four situations: when the function ignores the frame entirely (ROW_NUMBER, LAG, etc.), when the frame is `UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING`, when the ORDER BY column has no ties and the frame uses `CURRENT ROW` as a boundary, and when the ORDER BY column is a gap-free consecutive integer sequence and you are using an N-offset frame."
