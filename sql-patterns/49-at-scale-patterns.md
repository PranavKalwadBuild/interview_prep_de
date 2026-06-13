<!-- Part of sql-patterns: Breaking at Scale — Window Functions through Performance Patterns + Scale Readiness Checklist -->
<!-- Source: sql_patterns.md lines 12930–13163 -->

### 34-1. Window Functions — Ranking at Scale

> Full detail in [Pattern 1 — Window Functions Ranking → At Scale](#1-window-functions--ranking).
> Critical: add CLUSTER/SORT key on partition + order columns to avoid full sort.

---

### 34-2. LAG / LEAD at Scale

> Full detail in [Pattern 2 — LAG / LEAD → At Scale](#2-window-functions--lag--lead).
> Critical: LAG over 1B+ rows with no partition key = full sort; partition on low-cardinality column first.

---

### 34-3. Running Aggregates at Scale

> Full detail in [Pattern 3 — Running Aggregates → At Scale](#3-window-functions--running-aggregates).
> Critical: `RANGE` frame causes sort-merge on all ties — switch to `ROWS BETWEEN`.

---

### 34-4. FIRST_VALUE / LAST_VALUE at Scale

> Full detail in [Pattern 4 — FIRST_VALUE / LAST_VALUE → At Scale](#4-window-functions--first_value--last_value).
> Critical: full-range frame reads all rows in partition — cap partition size or use CTE filter.

---

### 34-5. Gap and Islands at Scale

> Full detail in [Pattern 5 — Gap and Islands → At Scale](#5-gap-and-islands).
> Critical: requires two sorts — pre-sort once with CTE; partition pruning essential.

---

### 34-6. Sessionization at Scale

> Full detail in [Pattern 6 — Sessionization → At Scale](#6-sessionization).
> Critical: LAG over 1B+ events requires global sort by user+time; use approximate session IDs at extreme scale.

---

### 34-7. Deduplication at Scale

> Full detail in [Pattern 7 — Deduplication → At Scale](#7-deduplication-patterns).
> Critical: ROW_NUMBER dedup requires full sort per partition — pre-filter to reduce cardinality first.

---

### 34-8. Top-N per Group at Scale

> Full detail in [Pattern 8 — Top-N per Group → At Scale](#8-top-n-per-group).
> Critical: RANK scans full table then filters — use QUALIFY + LIMIT or pre-filter with subquery.

---

### 34-9. Rolling Window Aggregations at Scale

> Full detail in [Pattern 9 — Rolling Window → At Scale](#9-rolling-window-aggregations).
> Critical: rolling window forces sort + frame evaluation per row — pre-aggregate to daily first.

---

### 34-10. Period-over-Period Comparisons at Scale

> Full detail in [Pattern 10 — Period-over-Period → At Scale](#10-period-over-period-comparisons-mom-yoy-dod).
> Critical: LAG(12) requires 12-month lookback in memory — materialized period table avoids re-scan.

---

### 34-11. Date Spine at Scale

> Full detail in [Pattern 11 — Date Spine → At Scale](#11-date-spine--calendar-table).
> Critical: date spine CROSS JOIN explodes to billions of rows — pre-build calendar table.

---

### 34-12. Cohort Analysis at Scale

> Full detail in [Pattern 12 — Cohort Analysis → At Scale](#12-cohort-analysis--retention).
> Critical: cohort join on user_id × date = massive fan-out — pre-aggregate before joining.

---

### 34-13. Funnel Analysis at Scale

> Full detail in [Pattern 13 — Funnel Analysis → At Scale](#13-funnel-analysis).
> Critical: funnel multi-JOIN = N full scans of event table — pivot events to one row per user first.

---

### 34-14. SCD Type 2 at Scale

> Full detail in [Pattern 14 — SCD Type 2 → At Scale](#14-slowly-changing-dimensions-scd-type-2).
> Critical: range join falls back to O(N×M) nested loop — use date bucketing to convert to equi-join.

---

### 34-15. Conditional Aggregation at Scale

> Full detail in [Pattern 15 — Conditional Aggregation → At Scale](#15-conditional-aggregations).
> Critical: CASE WHEN reads full table even with filters — push filter into WHERE or use partial index.

---

### 34-16. Self Joins at Scale

> Full detail in [Pattern 16 — Self Joins → At Scale](#16-self-joins--consecutive-row-comparisons).
> Critical: self-join on large table = O(N²) — add strict inequality + index on join key.

---

### 34-17. Recursive CTEs at Scale

> Full detail in [Pattern 17 — Recursive CTEs → At Scale](#17-recursive-ctes-hierarchies).
> Critical: depth limit hit on deep hierarchies — flatten to adjacency list or use CONNECT BY.

---

### 34-18. Pivoting at Scale

> Full detail in [Pattern 18 — Pivoting → At Scale](#18-pivoting--unpivoting).
> Critical: dynamic PIVOT requires two-pass query — consider pre-aggregation instead.

---

### 34-19. String Aggregation at Scale

> Full detail in [Pattern 19 — String Aggregation → At Scale](#19-string-aggregation).
> Critical: LISTAGG/GROUP_CONCAT in GROUP BY = one sort per group — pre-aggregate in CTE.

---

### 34-20. Data Quality Patterns at Scale

> Full detail in [Pattern 20 — Data Quality → At Scale](#20-data-quality-patterns).
> Critical: `COUNT(DISTINCT ...)` is expensive — use approximate COUNT_DISTINCT for large tables.

---

### 34-21. Set Operations (UNION / INTERSECT / EXCEPT) at Scale

> Full detail in [Pattern 21 — Set Operations → At Scale](#21-set-operations-union--intersect--except).
> Critical: UNION dedup = implicit DISTINCT on full result — use UNION ALL + explicit dedup.

---

### 34-22. Anti-Join at Scale

> Full detail in [Pattern 22 — Anti-Join → At Scale](#22-anti-join-pattern).
> Critical: `NOT IN` with large subquery = correlated scan — rewrite as `LEFT JOIN ... IS NULL`.

---

### 34-23. Percentiles and Histograms at Scale

> Full detail in [Pattern 23 — Percentiles → At Scale](#23-percentiles--histograms).
> Critical: PERCENTILE_CONT requires full sort — pre-sort and materialize for repeated queries.

---

### 34-25. Market Basket / Co-occurrence at Scale

> Full detail in [Pattern 25 — Market Basket → At Scale](#25-market-basket--co-occurrence).
> Critical: self-join = O(N²) item pairs — pre-filter rare items; use approximate co-occurrence.

---

### 34-26. Latest Record per Entity at Scale

> Full detail in [Pattern 28 — Latest Record per Entity → At Scale](#28-latest-record-per-entity-point-in-time).
> Critical: MAX + rejoin = two full scans — use ROW_NUMBER window once and filter rn=1.

---

### 34-27. Gaps in Sequential IDs at Scale

> Full detail in [Pattern 29 — Gaps in Sequential IDs → At Scale](#29-gaps-in-sequential-ids).
> Critical: NOT IN gap detection is O(N²) — use LAG window function instead.

---

### 34-30. Performance and Query Optimisation at Scale — Master Reference

> Full detail in [Pattern 30 — Performance → At Scale](#30-performance--query-optimisation-patterns).
> Critical: missing partition key causes full table scan — always check EXPLAIN plan first.

---

### 34-99. Scale Readiness Checklist

Before deploying any SQL pattern on a table with > 50M rows:

```

TABLE DESIGN
□ Is the table partitioned on the most common filter column? (usually a date column)
□ Is the partition granularity appropriate? (day for high-volume; month for low-volume)
□ Is there a second-level clustering key for the most common join/filter column?
□ Will the partition count stay bounded? (high-cardinality partition key → file explosion)
□ Is the file size in the right range? (128MB–512MB per file; not 1KB or 10GB)
□ Are bloom filters enabled for high-selectivity lookup columns? (txn_id, user_id, account_id)

QUERY DESIGN
□ Does every query include a partition column filter in WHERE? (no full table scan)
□ Is the join order correct? (smaller filtered table on the left/broadcast side)
□ Is COUNT(DISTINCT) on a > 100M row column? → replace with APPROX_COUNT_DISTINCT
□ Is PERCENTILE_CONT on > 100M rows? → replace with PERCENTILE_APPROX / t-digest
□ Is there a self-join or recursive CTE? → replace with LAG/LEAD or pre-computed closure table
□ Is a CTE referenced multiple times? (Spark: re-executes each reference) → cache/materialise

AGGREGATION DESIGN
□ Is the GROUP BY producing > 10M output rows? → pre-aggregate to coarser granularity
□ Is there a GROUP BY + window function in the same query? → profile for double shuffle
□ Is the result of the query used repeatedly? → materialise it as a summary table

WRITE DESIGN
□ Are new rows being inserted in small batches from streaming? → enable auto-compaction
□ Is MERGE being used on a large table? → ensure bloom filter on the merge key
□ Is the SCD2 table receiving many small updates? → OPTIMIZE/VACUUM weekly

MONITORING
□ Is query execution time tracked? → alert on > 5 min for interactive queries
□ Is data skew monitored? → alert when one Spark partition > 10× average size
□ Is partition count monitored? → alert when table has > 10,000 partitions
□ Is file count monitored? → alert when table has > 100,000 files
□ Is the scan ratio tracked? → (bytes scanned / bytes total) < 5% = well-partitioned

```

*Guide authored: 14 March 2026 | Universal SQL Interview Preparation Guide for Data Engineers*

---

