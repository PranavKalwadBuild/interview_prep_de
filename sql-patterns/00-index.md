# SQL Patterns — Navigation Index

> Split from `sql_patterns.md` (15,947 lines) into 60 topic files.
> Each file is self-contained. Use this index to jump to the right file.

---

## Part 1 — Foundations

| File | Topic | Lines |
|---|---|---|
| [01-basics-ddl-dml-select.md](01-basics-ddl-dml-select.md) | Data Types, DDL, DML, SELECT Fundamentals | ~174 |
| [02-joins-and-join-order.md](02-joins-and-join-order.md) | JOINs — Types, Join Order, Which Table Goes Left | ~293 |
| [03-subqueries-aggregates-case.md](03-subqueries-aggregates-case.md) | Subqueries, CTEs, Aggregates, CASE WHEN | ~147 |
| [04-null-fundamentals-1.md](04-null-fundamentals-1.md) | NULL Fundamentals Part 1 — 3VL through COALESCE | ~222 |
| [05-null-fundamentals-2-misc.md](05-null-fundamentals-2-misc.md) | NULL Fundamentals Part 2 + String, Constraints, Set Ops | ~273 |

## Part 1 — Date & Execution

| File | Topic | Lines |
|---|---|---|
| [06-date-functions-basics.md](06-date-functions-basics.md) | Date Functions — Current Date through Parsing | ~220 |
| [07-date-patterns.md](07-date-patterns.md) | Date Patterns — Transformation Recipes + Quick Reference | ~309 |
| [08-order-of-execution.md](08-order-of-execution.md) | SQL Order of Execution — Written vs Engine Execution | ~205 |

## Part 2 — Window Functions

| File | Topic | Lines |
|---|---|---|
| [09-window-ranking.md](09-window-ranking.md) | Ranking — ROW_NUMBER, RANK, DENSE_RANK | ~324 |
| [10-window-lag-lead.md](10-window-lag-lead.md) | LAG and LEAD | ~332 |
| [11-window-running-aggs-core.md](11-window-running-aggs-core.md) | Running Aggregates + ROWS vs RANGE Deep Dive | ~369 |
| [12-window-running-aggs-edge-scale.md](12-window-running-aggs-edge-scale.md) | Running Aggregates — Edge Cases and At Scale | ~260 |
| [13-window-default-frame.md](13-window-default-frame.md) | Default Frame Trap — RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW | ~362 |
| [14-window-first-last-value.md](14-window-first-last-value.md) | FIRST_VALUE and LAST_VALUE | ~176 |

## Part 2 — Analytics Core Patterns

| File | Topic | Lines |
|---|---|---|
| [15-gap-and-islands.md](15-gap-and-islands.md) | Gap and Islands | ~359 |
| [16-sessionization.md](16-sessionization.md) | Sessionization | ~276 |
| [17-deduplication.md](17-deduplication.md) | Deduplication Patterns | ~293 |
| [18-top-n-per-group.md](18-top-n-per-group.md) | Top-N per Group | ~255 |
| [19-rolling-window.md](19-rolling-window.md) | Rolling Window Aggregations | ~263 |
| [20-period-over-period.md](20-period-over-period.md) | Period-over-Period (MoM, YoY, DoD) | ~254 |

## Part 2 — Time, Cohort & Funnel

| File | Topic | Lines |
|---|---|---|
| [21-date-spine.md](21-date-spine.md) | Date Spine / Calendar Table | ~245 |
| [22-cohort-analysis.md](22-cohort-analysis.md) | Cohort Analysis and Retention | ~286 |
| [23-funnel-analysis.md](23-funnel-analysis.md) | Funnel Analysis | ~93 |

## Part 2 — SCD Patterns

| File | Topic | Lines |
|---|---|---|
| [24-scd-type1-iter0-5.md](24-scd-type1-iter0-5.md) | SCD Type 1 — Iterations 0–5 | ~320 |
| [25-scd-type1-iter6-final.md](25-scd-type1-iter6-final.md) | SCD Type 1 — Iterations 6-7 + Final | ~321 |
| [26-scd-type2-iter0-3.md](26-scd-type2-iter0-3.md) | SCD Type 2 — Core + Iterations 0–3 | ~324 |
| [27-scd-type2-iter4-final.md](27-scd-type2-iter4-final.md) | SCD Type 2 — Iterations 4–7 + Final Production | ~324 |
| [28-scd-type2-iter8-scale.md](28-scd-type2-iter8-scale.md) | SCD Type 2 — Iteration 8 + Edge Cases + Scale | ~378 |

## Part 2 — Advanced Patterns

| File | Topic | Lines |
|---|---|---|
| [29-conditional-aggregation.md](29-conditional-aggregation.md) | Conditional Aggregations | ~232 |
| [30-self-joins.md](30-self-joins.md) | Self Joins and Consecutive Row Comparisons | ~221 |
| [31-recursive-ctes.md](31-recursive-ctes.md) | Recursive CTEs and Hierarchies | ~239 |
| [32-pivoting-unpivoting.md](32-pivoting-unpivoting.md) | Pivoting and Unpivoting | ~194 |
| [33-string-aggregation.md](33-string-aggregation.md) | String Aggregation | ~242 |
| [34-data-quality.md](34-data-quality.md) | Data Quality Patterns | ~286 |
| [35-set-operations.md](35-set-operations.md) | Set Operations — UNION, INTERSECT, EXCEPT | ~222 |
| [36-anti-join.md](36-anti-join.md) | Anti-Join Pattern | ~197 |
| [37-percentiles-histograms.md](37-percentiles-histograms.md) | Percentiles and Histograms | ~268 |
| [38-running-totals-market-basket.md](38-running-totals-market-basket.md) | Running Totals and Market Basket / Co-occurrence | ~271 |
| [39-median-mode-ntile.md](39-median-mode-ntile.md) | Median, Mode, and NTILE Bucketing | ~262 |
| [40-latest-record-gaps-ids.md](40-latest-record-gaps-ids.md) | Latest Record per Entity and Gaps in Sequential IDs | ~423 |
| [41-performance-optimisation.md](41-performance-optimisation.md) | Performance and Query Optimisation Patterns | ~80 |

## Part 3 — Deep Dives

| File | Topic | Lines |
|---|---|---|
| [42-deep-dives-intro.md](42-deep-dives-intro.md) | Part 3 Introduction and Overview | ~260 |
| [43-null-deep-dive-joins-agg-windows.md](43-null-deep-dive-joins-agg-windows.md) | NULL Deep Dive — JOINs, Aggregates, Window Functions | ~335 |
| [44-null-deep-dive-antijoins-scd.md](44-null-deep-dive-antijoins-scd.md) | NULL Deep Dive — Anti-Joins, Gap/Island, Dedup, SCD2, Period-over-Period | ~283 |
| [45-null-deep-dive-cond-agg-to-dq.md](45-null-deep-dive-cond-agg-to-dq.md) | NULL Deep Dive — Conditional Agg through Data Quality | ~311 |
| [46-null-deep-dive-percentiles-final.md](46-null-deep-dive-percentiles-final.md) | NULL Deep Dive — Percentiles through Quick Reference Card | ~264 |
| [47-edge-cases-1.md](47-edge-cases-1.md) | Edge Case Detection — Part 1 | ~271 |
| [48-edge-cases-2-scale-joins.md](48-edge-cases-2-scale-joins.md) | Edge Cases Part 2 + At Scale — JOINs | ~329 |
| [49-at-scale-patterns.md](49-at-scale-patterns.md) | Breaking at Scale — Pattern Fixes + Readiness Checklist | ~234 |
| [50-partition-sort-keys-1.md](50-partition-sort-keys-1.md) | Partition/Sort Keys — Mental Model and Partition Key | ~278 |
| [51-partition-sort-keys-2.md](51-partition-sort-keys-2.md) | Partition/Sort Keys — Sort, Distribution, Cloud Platforms, Decision Framework | ~251 |
| [52-partition-sort-keys-examples.md](52-partition-sort-keys-examples.md) | Partition/Sort Keys — Code Examples and Skew | ~268 |
| [53-partition-sort-keys-syntax.md](53-partition-sort-keys-syntax.md) | Partition/Sort Keys — Anti-Patterns, Syntax Reference, Cheat Sheet | ~144 |
| [54-dup-handling-window-funcs.md](54-dup-handling-window-funcs.md) | Duplicate Handling — Root Causes + Window Function Patterns | ~284 |
| [55-dup-handling-analytics.md](55-dup-handling-analytics.md) | Duplicate Handling — Sessionization through Cohort Analysis | ~297 |
| [56-dup-handling-scd-misc.md](56-dup-handling-scd-misc.md) | Duplicate Handling — Funnel through Anti-Join | ~299 |
| [57-dup-handling-final.md](57-dup-handling-final.md) | Duplicate Handling — Latest Record, End-to-End Example, Quick Reference | ~221 |

## Part 4 — Quick Reference

| File | Topic | Lines |
|---|---|---|
| [58-quick-reference-1.md](58-quick-reference-1.md) | Interview Questions Q1–Q9 | ~295 |
| [59-quick-reference-2.md](59-quick-reference-2.md) | Interview Questions Q10–Q20 | ~250 |
| [60-quick-reference-cheatsheets.md](60-quick-reference-cheatsheets.md) | Q21–Q24 + Keyword→Pattern + Window Cheat Sheet | ~197 |

## Part 5 — Query Plans & Execution Deep Dive

| File | Topic | Lines |
|---|---|---|
| [61-query-plans-explain.md](61-query-plans-explain.md) | EXPLAIN, EXPLAIN ANALYZE, Reading Query Plans — PostgreSQL, Snowflake, BigQuery, Databricks, Redshift | ~450 |

## Part 6 — NoSQL Systems (DE Perspective)

| File | Topic | Lines |
|---|---|---|
| [62-nosql-foundations.md](62-nosql-foundations.md) | CAP Theorem, PACELC, ACID vs BASE, 4 Data Models, SQL vs NoSQL Decision, Schema-on-Read vs Write | ~160 |
| [63-nosql-key-systems.md](63-nosql-key-systems.md) | DynamoDB (partition design, hot partitions, STD, GSI/LSI, Streams, CDC), MongoDB (aggregation pipeline, change streams, Debezium), Cassandra (CQL rules, compaction, pitfalls) | ~220 |
| [64-nosql-redis-and-ingestion.md](64-nosql-redis-and-ingestion.md) | Redis (data structures, persistence, Streams vs Pub/Sub, DE use cases), Ingestion patterns from DynamoDB/MongoDB/Cassandra/Redis, semi-structured JSON handling | ~220 |
| [65-nosql-quick-reference.md](65-nosql-quick-reference.md) | Interview Q&A (10 questions), Numbers cheat sheet, PACELC table, Managed services map, Decision tree, Red flags | ~150 |

---

*Original file: `sql_patterns.md` | Total: ~15,947 lines | Split into 60 files*
*NoSQL section added 2026-06-13 — files 62–65*
