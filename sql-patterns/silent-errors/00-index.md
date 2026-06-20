<!-- Part of sql-patterns: Silent Errors — Index -->

# Silent Errors in SQL — Navigation Index

> These files document SQL bugs that produce no exceptions, no warnings, and incorrect results.
> They surface in production, typically caught only by staff-level engineers or during audit/reconciliation.
> Each file covers 8–15 distinct patterns. Every pattern includes a minimal repro, detection query,
> and the production scenario that first surfaces it.

---

## What Counts as a Silent Error

A silent error satisfies all of the following:
1. The query executes without raising an exception or warning.
2. The result set is populated (not empty by design).
3. The values returned are numerically wrong or logically incorrect.
4. The error is not detectable by inspecting the query alone — it requires knowledge of the data semantics, engine internals, or a comparison baseline.

These are not beginner mistakes (SELECT *, missing index). They are production-grade bugs that have caused real financial miscounts, compliance failures, and incorrect ML features in systems run by experienced engineers.

---

## File Index

| File | Topic | Patterns | Lines |
|---|---|---|---|
| [01-null-silent-errors.md](01-null-silent-errors.md) | NULL Semantics — NOT IN poisoning, COUNT divergence, AVG bias, COALESCE placement, GROUP BY NULL group, IS DISTINCT FROM | 9 | ~377 |
| [02-type-coercion-and-casting.md](02-type-coercion-and-casting.md) | Type Coercion and Casting — VARCHAR lexicographic sort, integer division, timestamp shifts, DECIMAL JOIN key, CAST truncation, boolean-int ambiguity, semi-structured numeric casts | 9 | ~314 |
| [03-window-function-traps.md](03-window-function-traps.md) | Window Function Traps — RANGE frame ties, LAST_VALUE default frame, ROW_NUMBER non-determinism, RANK gaps, NULL offset handling, partition type mismatch, ROWS + non-unique ORDER BY, ratio denominator traps | 8 | ~332 |
| [04-join-and-aggregation-fanout.md](04-join-and-aggregation-fanout.md) | Join and Aggregation Fan-out — one-to-many SUM doubling, many-to-many Cartesian, LEFT JOIN WHERE converts to INNER, pre-dedup aggregation, COUNT DISTINCT undercount, chasm trap, accidental CROSS JOIN, self-join pair counting | 8 | ~363 |
| [05-set-operations-and-ordering.md](05-set-operations-and-ordering.md) | Set Operations and Ordering — UNION ALL positional column swap, UNION silent dedup, EXCEPT NULL equality, ORDER BY in subquery not guaranteed, INTERSECT NULL semantics, DISTINCT ORDER BY portability, EXCEPT branch ORDER BY | 7 | ~272 |
| [06-datetime-and-timezone.md](06-datetime-and-timezone.md) | Datetime and Timezone — BETWEEN timestamp inclusive endpoint, DST gaps, inconsistent current-time functions, epoch integer comparison, boundary counting, week definitions, session settings | 7 | ~282 |
| [07-floating-point-and-numeric.md](07-floating-point-and-numeric.md) | Floating Point and Numeric Precision — float equality, accumulating SUM error, NUMERIC vs FLOAT division, ROUND banker's rounding, integer overflow in SUM, DECIMAL division scale, AVG NUMERIC promotion | 7 | ~273 |
| [08-incremental-and-cdc-patterns.md](08-incremental-and-cdc-patterns.md) | Incremental and CDC Patterns — mutable updated_at watermark, late-arriving data permanent miss, SCD batch window collapses transitions, dbt append_new_columns NULL history, idempotency violation wrong merge key, IS DISTINCT FROM in change detection, partial-column hash dedup collision | 7 | ~340 |
| [09-sql-portability-and-semi-structured.md](09-sql-portability-and-semi-structured.md) | SQL Portability and Semi-Structured Data — numeric casts, optional arrays, file-load column mismatches, function-wrapped predicates, timestamp type mismatch, JSON nulls, session settings | 7 | ~357 |

**Total: ~2,910 lines across 9 files, 70 distinct patterns.**

---

## Cross-Cutting Themes

### NULL is not a value
The single richest source of silent errors. Three-valued logic (TRUE/FALSE/UNKNOWN) means that any predicate, aggregate, or comparison silently changes behavior when NULL is involved. See `01-null-silent-errors.md` and the NULL subsections of `04`, `05`, `08`, `09`.

### Implicit type conversion
SQL engines may convert types on your behalf rather than fail. Because precedence and tolerant parsing rules are implementation-defined, ambiguous casts should be made explicit and validated. See `02-type-coercion-and-casting.md`.

### Frame specification in window functions
Every window function call should include an explicit frame clause. The default frame (`RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW`) is almost never what you want for `LAST_VALUE`, running totals with ties, or any computation requiring the full partition. See `03-window-function-traps.md`.

### Row multiplication from JOINs
A JOIN does not reduce rows — it can only keep or multiply them. Any aggregate after a JOIN that has not been validated for cardinality is potentially wrong. Always count rows before and after each JOIN. See `04-join-and-aggregation-fanout.md`.

### Incremental pipelines accumulate error
Watermark-based incrementals make assumptions about data arrival order. Every assumption can be violated. Late-arriving data, backdated corrections, and within-batch multi-updates are the three most common silent failure modes. See `08-incremental-and-cdc-patterns.md`.

---

## Quick Diagnostic Checklist

Use this list when investigating a "the numbers don't match" incident:

```
□ Are there NULLs in join keys, group-by columns, or aggregate columns?
□ Does the query use NOT IN with a subquery that could contain NULLs?
□ Are implicit casts present in WHERE clauses or JOIN predicates?
□ Do all window functions have explicit frame clauses where needed?
□ Has the cardinality of each JOIN been verified?
□ Are UNION branches aligned by position and type?
□ Are timestamp filters written as half-open ranges?
□ Are all timestamps normalized before joining or comparing?
□ For incremental models: has late-arriving data been tested?
□ For semi-structured data: are numeric values validated before casting?
□ For optional child arrays: are parent rows preserved when no child exists?
```


---

## Related Files in sql-patterns

| File | Relationship |
|---|---|
| [04-null-fundamentals-1.md](../04-null-fundamentals-1.md) | NULL three-valued logic foundation |
| [05-null-fundamentals-2-misc.md](../05-null-fundamentals-2-misc.md) | NULL in set operations |
| [11-window-running-aggs-core.md](../11-window-running-aggs-core.md) | ROWS vs RANGE deep dive |
| [13-window-default-frame.md](../13-window-default-frame.md) | Default frame trap (extended) |
| [34-data-quality.md](../34-data-quality.md) | Data quality detection patterns |
| [36-anti-join.md](../36-anti-join.md) | NOT EXISTS vs NOT IN |
| [43-null-deep-dive-joins-agg-windows.md](../43-null-deep-dive-joins-agg-windows.md) | NULL in joins and aggregations |
| [47-edge-cases-1.md](../47-edge-cases-1.md) | Edge cases including type coercion |
