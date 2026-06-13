<!-- PySpark-patterns: explain() Deep Dive -->

# explain() Deep Dive — All Five Modes, Every Operator

## Overview

`explain()` prints the execution plan Spark will use (or already used) for a query. It is the primary instrument for understanding what the Catalyst optimizer decided. Every performance tuning session should start here.

Both APIs expose the same five modes:

| PySpark | Spark SQL | What It Shows |
|---------|-----------|---------------|
| `df.explain()` | `EXPLAIN SELECT ...` | Physical plan only |
| `df.explain(mode="extended")` | `EXPLAIN EXTENDED SELECT ...` | All 4 plan stages |
| `df.explain(mode="formatted")` | `EXPLAIN FORMATTED SELECT ...` | Physical plan with per-node detail blocks |
| `df.explain(mode="cost")` | `EXPLAIN COST SELECT ...` | Optimized logical plan with statistics |
| `df.explain(mode="codegen")` | `EXPLAIN CODEGEN SELECT ...` | Physical plan + generated Java code |

> `df.explain(extended=True)` is the legacy boolean form, equivalent to `mode="extended"`. In Spark 3.0+ prefer the string form.

---

## Part 1 — The Five Modes in Detail

### 1.1 simple (default)

```python
df.explain()
# or
df.explain(mode="simple")
```

Prints only the physical plan. No logical stages, no statistics, no per-node detail.

**When to use:** Quick sanity checks — "which join strategy did Spark pick?" "Is there a broadcast or a sort-merge?" "How many Exchange nodes are there?"

**What it does NOT show:** Whether predicate pushdown succeeded. CBO statistics. AQE final plan (if called before execution).

Example output:
```
== Physical Plan ==
*(2) HashAggregate(keys=[dept#10], functions=[sum(salary#11)])
+- Exchange hashpartitioning(dept#10, 200), ENSURE_REQUIREMENTS, [id=#15]
   +- *(1) HashAggregate(keys=[dept#10], functions=[partial_sum(salary#11)])
      +- *(1) FileScan parquet [dept#10,salary#11] ...
```

---

### 1.2 extended

```python
df.explain(mode="extended")
```

Prints all four plan stages produced by the Catalyst compiler. This is the most diagnostic mode for understanding *why* the optimizer made specific decisions.

**When to use:** Debugging filter pushdown (did my WHERE clause make it into the scan?). Understanding how Catalyst rewrote your query. Verifying that column pruning worked. Seeing implicit casts the optimizer inserted.

**Output structure:**

```
== Parsed Logical Plan ==     ← raw AST, unresolved names
== Analyzed Logical Plan ==   ← resolved columns and types, expression IDs assigned
== Optimized Logical Plan ==  ← rules applied: predicate pushdown, constant folding, column pruning
== Physical Plan ==            ← join strategy chosen, Exchange nodes inserted
```

**What changes between the four stages:**

| Stage | Key Transformations |
|-------|---------------------|
| Parsed → Analyzed | Unresolved names (`'col`) become typed AttributeReferences (`col#10L`). Types resolved. Implicit casts inserted. AnalysisException raised here if column doesn't exist. |
| Analyzed → Optimized | `Filter` pushed below `Project`. Two consecutive `.filter()` calls collapsed into one `AND` predicate. Unused columns pruned from `Project`. Constant expressions folded. If CBO on, join order may change. |
| Optimized → Physical | Join type chosen (BHJ vs. SMJ vs. BNLJ). `Exchange` nodes inserted by `EnsureRequirements`. `Sort` nodes added before `SortMergeJoin`. Two-phase `HashAggregate` split. |

Example showing predicate pushdown in action — compare Analyzed vs. Optimized:
```
-- Your code:
df.filter(F.col("status") == "active").select("user_id", "amount")

== Analyzed Logical Plan ==
Project [user_id#10, amount#11]
+- Filter (status#12 = active)           ← Filter is ABOVE Project
   +- Relation [user_id#10, amount#11, status#12] parquet

== Optimized Logical Plan ==
Project [user_id#10, amount#11]
+- Filter (status#12 = active)           ← same here, but watch the Physical Plan
   +- Relation [user_id#10, amount#11, status#12] parquet
   -- Column pruning: ReadSchema will only include status for filter, then drop it

== Physical Plan ==
*(1) Project [user_id#10, amount#11]
+- *(1) Filter (status#12 = active)
   +- *(1) FileScan parquet [user_id#10, amount#11, status#12]
          PushedFilters: [IsNotNull(status), EqualTo(status,active)]   ← pushed into scan!
          ReadSchema: struct<user_id:int,amount:decimal,status:string>
```

---

### 1.3 formatted

```python
df.explain(mode="formatted")
```

Splits output into two sections: (1) a numbered physical plan tree and (2) a separate detail block for each numbered node. Introduced in Spark 3.0 as the most human-readable mode for complex plans.

**When to use:** Deep physical plan analysis. Checking `PushedFilters`, `PartitionFilters`, and `ReadSchema` on `FileScan`. Confirming `BuildRight` vs. `BuildLeft` on broadcast joins. Checking partition count on `Exchange`.

**Output structure:**

```
== Physical Plan ==
* HashAggregate (4)
+- Exchange (3)
   +- * HashAggregate (2)
      +- * FileScan parquet (1)

(1) FileScan parquet [dept#10, salary#11]
    Batched: true
    DataFilters: []
    Format: Parquet
    Location: InMemoryFileIndex[hdfs://warehouse/employees/...]
    PartitionFilters: [isnotnull(dt#12), (dt#12 = 2024-01-01)]
    PushedFilters: [IsNotNull(dept)]
    ReadSchema: struct<dept:string,salary:bigint>

(2) HashAggregate
    Input [2]: [dept#10, salary#11]
    Keys [1]: [dept#10]
    Functions [1]: [partial_sum(salary#11)]
    Aggregate Attributes [1]: [sum#20L]
    Results [2]: [dept#10, sum#20L]

(3) Exchange
    Input [2]: [dept#10, sum#20L]
    Arguments: hashpartitioning(dept#10, 200), ENSURE_REQUIREMENTS, [id=#42]

(4) HashAggregate
    Input [2]: [dept#10, sum#20L]
    Keys [1]: [dept#10]
    Functions [1]: [sum(salary#11)]
    Results [2]: [dept#10, sum(salary#11)#12L AS total#12L]
```

---

### 1.4 cost

```python
df.explain(mode="cost")
```

Prints the Optimized Logical Plan annotated with statistics: `sizeInBytes`, `rowCount`, and per-column `AttributeStats`. Does NOT show the Physical Plan.

**When to use:** Verifying that Cost-Based Optimization (CBO) has table statistics. Confirming whether a table's estimated size is below `autoBroadcastJoinThreshold`. Diagnosing why Spark chose SortMergeJoin instead of BroadcastHashJoin.

**Prerequisites:**
```sql
-- Statistics must be collected or CBO is blind
ANALYZE TABLE employees COMPUTE STATISTICS FOR COLUMNS salary, dept;

-- CBO must be enabled
SET spark.sql.cbo.enabled = true;
SET spark.sql.cbo.joinReorder.enabled = true;  -- also enables multi-table join reorder
```

**Output with statistics present:**
```
== Optimized Logical Plan ==
Aggregate [dept#10], [dept#10, sum(salary#11) AS total#12L],
    Statistics(sizeInBytes=5.9 KB, rowCount=8, hints=none)
+- Filter (salary#11 > 50000),
       Statistics(sizeInBytes=88.4 KB, rowCount=503, hints=none)
   +- Relation employees parquet,
          Statistics(sizeInBytes=119.2 MB, rowCount=500000, hints=none)
```

**What to look for:** If a large table shows only `sizeInBytes` with no `rowCount`, CBO cannot estimate filter selectivity — run `ANALYZE TABLE`. If a filtered table still shows a large `sizeInBytes` (bigger than `autoBroadcastJoinThreshold`), the optimizer will conservatively choose SortMergeJoin — either increase the threshold or add column statistics so selectivity can be computed.

---

### 1.5 codegen

```python
df.explain(mode="codegen")
```

Prints the physical plan followed by the generated Java source code for each WholeStageCodegen stage. This is the lowest-level mode.

**When to use:** Confirming that WholeStageCodegen (WSCG) fired. Debugging codegen being silently disabled (e.g., schema too wide). Understanding the exact JVM loop executing your query.

**The `*(n)` notation — what it means:**

Any physical plan operator prefixed with `*(n)` is part of WholeStageCodegen stage `n`. All adjacent `*(n)` operators with the same number have been fused into a single generated Java class — a tight inner loop that avoids virtual dispatch and JVM object allocation between operators. Without WSCG, the Volcano iterator model calls `next()` at every operator boundary for every row.

**Operators that SUPPORT codegen** (can have `*(n)` prefix):
`Filter`, `Project`, `HashAggregate`, `BroadcastHashJoin`, `SortMergeJoin`, `Sort`, `Range`, `Expand`, `Generate`, `ColumnarToRow`

**Operators that BREAK codegen chains** (never have `*(n)`, always a boundary):
`Exchange`, `BroadcastExchange`, `WindowExec`, `SortAggregate`, `ObjectHashAggregate`

**Codegen limits that silently disable WSCG:**
```python
# If any operator's input/output schema has > 200 fields, codegen is disabled for that stage
spark.conf.set("spark.sql.codegen.maxFields", "200")   # default

# If generated method exceeds 65535 bytes, codegen falls back to interpreted path
spark.conf.set("spark.sql.codegen.hugeMethodLimit", "65535")  # default

# Master switch
spark.conf.set("spark.sql.codegen.wholeStage", "true")  # default
```

**Reading codegen output:**
```
== Subtree 2 / 3 ==
*(2) BroadcastHashJoin [user_id#10], [user_id#20], Inner, BuildRight
:- *(2) Filter isnotnull(user_id#10)
:  +- *(2) FileScan parquet [user_id#10, amount#11]
+- BroadcastExchange HashedRelationBroadcastMode(...)
   +- *(1) FileScan parquet [user_id#20, name#21]    ← separate codegen stage 1

Generated code:
/* 001 */ public Object generate(Object[] references) {
/* 002 */   return new GeneratedIteratorForCodegenStage2(references);
/* 003 */ }
...
```

Stage 1 (right side of join) and Stage 2 (left side + join itself) are separate because `BroadcastExchange` breaks the chain. Within stage 2, `Filter + FileScan + BroadcastHashJoin` are fused into one generated class.

---

## Part 2 — Physical Plan Operators in Detail (formatted mode)

Read plans **bottom-to-top**: leaf nodes (FileScan, Range) feed upward.

### 2.1 FileScan

```
FileScan parquet [col_a#10, col_b#11]
  Batched: true
  DataFilters: [isnotnull(col_a#10), (col_a#10 = 100)]
  Format: Parquet
  Location: InMemoryFileIndex[hdfs://warehouse/tbl/dt=2024-01-01]
  PartitionFilters: [isnotnull(dt#12), (dt#12 = 2024-01-01)]
  PushedFilters: [IsNotNull(col_a), EqualTo(col_a,100)]
  ReadSchema: struct<col_a:int,col_b:string>
```

| Field | Meaning | Red Flag |
|-------|---------|---------|
| `PartitionFilters` | Filters applied to partition **directory metadata** before any file is opened. Free — Spark never opens non-matching partition directories. | Empty despite a date filter in WHERE → type mismatch or function on partition col |
| `PushedFilters` | Row-level filters pushed **inside the Parquet/ORC reader**, evaluated in columnar batches before JVM row creation. Cheap. | Empty despite a simple equality filter → column type unsupported, or UDF in filter chain |
| `DataFilters` | Filters applied **after** read, as fallback when pushdown failed. Full row materialization still happens. | Populated with predicates you expected to be pushed → Parquet reader can't push this predicate type |
| `ReadSchema` | Columns actually read from files. Should be narrow (only what you selected). | Shows all 50 columns when you selected 3 → projection pruning failed, usually due to SELECT * |
| `Batched: true` | Vectorized Parquet reader active (batches of up to 4096 rows). | `false` → row-by-row fallback; check complex nested types |

**Dynamic Partition Pruning (DPP):**
When a join key is also a partition column, Spark can prune fact table partitions at runtime using the dimension table filter:

```
FileScan parquet fact_sales [product_id#10, amount#11]
  PartitionFilters: [isnotnull(product_id#10),
                     dynamicpruningexpression(product_id#10 IN dynamicpruning#210)]
```

`dynamicpruning#210` is a `SubqueryBroadcast` node that evaluates the dimension filter and reuses the same BroadcastExchange built for the join. DPP works when: fact table is partitioned on the join key; join type is Inner/LeftOuter/RightOuter; dimension side can be broadcast.

### 2.2 Filter (standalone node)

A `Filter` node **above** a `FileScan` means predicate pushdown failed — Spark read every row then discarded non-matching ones.

```
*(1) Filter (category#10 = Electronics)     ← bad: above the scan
+- *(1) FileScan parquet [category#10, price#11]
         PushedFilters: []                   ← empty = not pushed
```

Why pushdown can fail:
- Column is a complex type (`ArrayType`, `MapType`, `StructType`)
- Predicate involves a Python UDF
- Format doesn't support pushdown (CSV, text)
- Type mismatch requiring a cast (`cast(int_col as string) = '5'`)

Fix: Remove UDF from filter. Match literal type to column type (`WHERE int_col = 5` not `WHERE int_col = '5'`). For complex types, explode first then filter.

### 2.3 Exchange (Shuffle)

Every `Exchange` node is a **stage boundary**: upstream tasks must fully finish and write shuffle files to disk before any downstream task starts. This is the most expensive operator category.

```
Exchange hashpartitioning(dept#10, 200), ENSURE_REQUIREMENTS, [id=#42]
```

| Partitioning Type | Used By | Notes |
|---|---|---|
| `hashpartitioning(key, N)` | `groupBy`, `join` | All rows with same hash(key) go to same output partition. N = `spark.sql.shuffle.partitions` (default 200) |
| `rangepartitioning(key ASC, N)` | `orderBy`, `sort` | Global range-based ordering. A `Sort` node always follows this. |
| `SinglePartition` | Global aggregates (`df.count()`, `df.agg()` without groupBy) | All data into one reducer. Dangerous on large data. |
| `RoundRobinPartitioning(N)` | `repartition(N)` with no column | Even distribution, no grouping guarantee. |

`ENSURE_REQUIREMENTS` = inserted by the `EnsureRequirements` physical preparation rule because upstream distribution didn't satisfy what the downstream operator needed.

**Multiple Exchange nodes = multiple shuffles.** Each one = full network transfer. Look for opportunities to: broadcast a small table (eliminates one Exchange), cache after first shuffle (so subsequent ops don't re-shuffle), or restructure aggregations to reduce shuffle count.

`ReusedExchange`: When two branches of the plan shuffle on the same key and partition count, Spark's `ReuseExchange` rule computes the shuffle once and marks the second reference as `ReusedExchange`. Look for this node to confirm deduplication.

### 2.4 HashAggregate (two-phase pattern)

Always appears in pairs — this is the map-side combine pattern:

```
*(2) HashAggregate(keys=[dept#10], functions=[sum(salary#11)])   ← Final: merges partial results
+- Exchange hashpartitioning(dept#10, 200)
   +- *(1) HashAggregate(keys=[dept#10], functions=[partial_sum(salary#11)])  ← Partial: pre-agg per partition
```

**Partial phase (Stage 1):** Each task pre-aggregates its local partition. Only `partial_sum` results (one per dept per input partition) are shuffled — not all raw rows. This is crucial: if you have 100M rows but 50 departments, the shuffle sends 50 × N_partitions rows, not 100M rows.

**Final phase (Stage 2):** Each task merges all partial results for its assigned dept keys.

**Fallback variants:**
- `ObjectHashAggregate`: Fallback when aggregate buffer can't fit in fixed-size hash table (e.g., `collect_list`, `collect_set`). Slower.
- `SortAggregate`: Used by aggregations that require ordering (e.g., `percentile_approx`). Slower.

**Memory spill signal:**
```
HashAggregate(...)
  Batches: 8    ← "Batches: 1" = fit in memory; > 1 = spilled to disk N times
  Memory Usage: 640kB
```
`Batches > 1` means the hash table overflowed. Fix: increase `spark.executor.memory`, pre-filter to reduce cardinality, or use `APPROX_COUNT_DISTINCT` for approximate aggregations.

### 2.5 BroadcastHashJoin

The most performant join strategy. Small side is collected on driver, broadcast to all executors as an in-memory hash table. The large side streams through and probes the table. No shuffle on either side.

```
*(2) BroadcastHashJoin [order_id#10], [order_id#20], Inner, BuildRight
:- *(2) Project [order_id#10, amount#11]
:  +- *(2) FileScan parquet orders [...]
+- BroadcastExchange HashedRelationBroadcastMode(List(order_id#20)), [id=#42]
   +- *(1) FileScan parquet products [...]
```

- `BuildRight` = right DataFrame was broadcast (the smaller one). `BuildLeft` = left was broadcast.
- Join types: `Inner`, `LeftOuter`, `RightOuter`, `LeftSemi` (EXISTS subqueries), `LeftAnti` (NOT EXISTS).
- Auto-broadcast threshold: `spark.sql.autoBroadcastJoinThreshold` (default 10 MB). Set `-1` to disable auto-broadcast.
- Force broadcast manually: `large_df.join(F.broadcast(small_df), "key")`

**Key signal:** Only one `Exchange` (the `BroadcastExchange`, which is not a shuffle in the shuffle-write-to-disk sense). No `Sort` nodes. One stage instead of two.

### 2.6 SortMergeJoin

Used when both sides are too large to broadcast. Both sides are shuffled by join key (two `Exchange` nodes), sorted within each partition, then merged. O(N log N) due to sort.

```
SortMergeJoin [customer_id#10], [customer_id#20], Inner
:- Sort [customer_id#10 ASC NULLS FIRST], false, 0
:  +- Exchange hashpartitioning(customer_id#10, 200)
:     +- FileScan parquet orders [...]
+- Sort [customer_id#20 ASC NULLS FIRST], false, 0
   +- Exchange hashpartitioning(customer_id#20, 200)
      +- FileScan parquet customers [...]
```

Two `Exchange` nodes = two shuffles = two stage boundaries = most expensive join. When you see this and one side should be broadcast:
1. Check `EXPLAIN COST` — if one side's `sizeInBytes` is below `autoBroadcastJoinThreshold`, statistics are wrong. Run `ANALYZE TABLE`.
2. If statistics are right but threshold is too low, raise it: `spark.conf.set("spark.sql.autoBroadcastJoinThreshold", str(200 * 1024 * 1024))`
3. Force with hint: `df.join(F.broadcast(small_df), "key")`

**Skewed SortMergeJoin in AQE final plan:**
```
AdaptiveSparkPlan isFinalPlan=true
+- SortMergeJoin [customer_id#10], [customer_id#20], Inner
   :- CustomShuffleReader    ← AQE coalesced or split partitions
   :  +- ShuffleQueryStage  ← materialized shuffle; stats collected here
   +- CustomShuffleReader
      +- ShuffleQueryStage
```
`CustomShuffleReader` replacing `Exchange` = AQE changed partition count post-shuffle. `ShuffleQueryStage` = shuffle already completed and stats are available.

### 2.7 BroadcastNestedLoopJoin (BNLJ)

Triggered when **no equality condition** exists in the join predicate. Every outer row is compared against every broadcast inner row. O(N × M) — catastrophic on large data.

```
BroadcastNestedLoopJoin BuildRight, Inner, (date#10 BETWEEN start#20 AND end#21)
:- FileScan parquet large_table [...]   ← 1B rows
+- BroadcastExchange IdentityBroadcastMode
   +- FileScan parquet promotions [...]
```

**Common triggers:**
- Range condition: `a.date BETWEEN b.start AND b.end`
- `NOT IN` with potential NULLs (Spark can't safely rewrite as LeftAnti BHJ due to SQL NULL semantics)
- Accidentally omitted ON clause (Cartesian product)

**What to do:**
- Rewrite `NOT IN` → `NOT EXISTS`: `WHERE NOT EXISTS (SELECT 1 FROM b WHERE b.id = a.id)`
- Add equality condition: `ON a.key = b.key AND a.date BETWEEN b.start AND b.end` — equality drives BHJ, range is a post-join filter
- For true range joins: bucket both tables by a discrete range bucket key, join on bucket, filter by exact range

### 2.8 AdaptiveSparkPlan

Root wrapper node when AQE is enabled (default since Spark 3.2).

```python
# isFinalPlan=false: initial static plan (before execution)
# isFinalPlan=true:  final plan after AQE re-optimizations (after execution)

AdaptiveSparkPlan isFinalPlan=false
+- == Initial Plan ==
   SortMergeJoin [...]   ← may be replaced by BHJ at runtime

AdaptiveSparkPlan isFinalPlan=true
+- == Final Plan ==
   BroadcastHashJoin [...]   ← AQE converted SMJ → BHJ because one side was small
   :- CustomShuffleReader
   :  +- ShuffleQueryStage
   +- BroadcastExchange
```

**Critical limitation:** Calling `explain()` before running the query ALWAYS shows `isFinalPlan=false`. You cannot see AQE decisions before they happen. To see the final plan:

```python
# Method 1: Execute first, then explain
df.write.mode("overwrite").parquet("/tmp/output")
df.explain(mode="formatted")  # now shows isFinalPlan=true

# Method 2: Access programmatically after execution
df.collect()
print(df.queryExecution.executedPlan)
```

---

## Part 3 — Reading the Extended Mode: The Four Plan Stages

### Parsed Logical Plan

Raw abstract syntax tree (AST). Column references are `UnresolvedAttribute` (marked with leading `'`). Table names are `UnresolvedRelation`. No schema validation yet. Syntactically valid but semantically wrong queries (bad column name) get past this stage.

### Analyzed Logical Plan

Analyzer validates against the Spark catalog. Key changes:
- `UnresolvedAttribute` → typed `AttributeReference` with expression ID (`salary#11L`)
- `UnresolvedRelation` → `SubqueryAlias` wrapping a concrete `Relation`
- Types resolved; implicit casts inserted (e.g., `cast(5 as bigint)` for comparing int literal to long column)
- `AnalysisException` raised here if column does not exist

The expression IDs (`#nn`) assigned here are stable and track columns through the rest of the plan.

### Optimized Logical Plan

Catalyst's rule-based optimizer applies batches of rules. Key rules:

| Rule | Effect |
|------|--------|
| Predicate Pushdown | `Filter` moved as close to source as possible; partition filters + data filters separated |
| Column Pruning | `Project` pushed down; only referenced columns appear in `ReadSchema` |
| Constant Folding | `2 + 3` → `5` at plan time |
| Filter Merging | Two sequential `.filter()` calls → one `Filter` with `AND` predicate |
| Join Reordering (CBO) | With `spark.sql.cbo.joinReorder.enabled=true` and stats, multi-table joins reordered to minimize intermediate size |

**Diagnostic use:** Compare Analyzed vs. Optimized. Did your `Filter` move closer to the source? Did two `Filter` nodes collapse into one? Did a `Project [*]` become a narrower `Project [col_a, col_b]`?

### Physical Plan

The Planner applies `SparkStrategy` rules to produce candidate physical plans. `JoinSelection` decides BHJ vs. SMJ vs. BNLJ. `Aggregation` decides HashAggregate vs. ObjectHashAggregate vs. SortAggregate. `EnsureRequirements` inserts `Exchange` and `Sort` nodes wherever distribution/ordering doesn't match.

Every `Exchange` in the physical plan = one stage boundary in the Spark UI.

---

## Part 4 — cost Mode: Statistics and CBO

```
== Optimized Logical Plan ==
Aggregate [dept#10], [...], Statistics(sizeInBytes=5.9 KB, rowCount=8, hints=none)
+- Filter (salary#11 > 50000), Statistics(sizeInBytes=88.4 KB, rowCount=503, hints=none)
   +- Relation employees parquet, Statistics(sizeInBytes=119.2 MB, rowCount=500000, hints=none)
```

**`sizeInBytes`**: Estimated output size. Propagated bottom-up from catalog statistics. When no stats exist, Spark uses a conservative formula that often overestimates, biasing toward SortMergeJoin.

**`rowCount`**: Only present when `spark.sql.cbo.enabled=true` AND `ANALYZE TABLE ... COMPUTE STATISTICS FOR COLUMNS` has been run. Without this, CBO cannot estimate filter selectivity.

**How missing stats causes wrong join strategy:**
```
-- Filter reduces 500K rows → 5K rows (1% selectivity)
-- Without stats: Spark sees sizeInBytes=119.2 MB → chooses SortMergeJoin
-- With stats on 'salary': Spark knows rowCount=5000 → sizeInBytes=2.3 MB → chooses BroadcastHashJoin
```

**Enabling CBO:**
```python
spark.conf.set("spark.sql.cbo.enabled", "true")
spark.conf.set("spark.sql.cbo.joinReorder.enabled", "true")
```
```sql
ANALYZE TABLE employees COMPUTE STATISTICS FOR COLUMNS salary, dept, status;
```

---

## Part 5 — SQL Equivalents

```sql
-- Physical plan only
EXPLAIN SELECT dept, SUM(salary) FROM employees GROUP BY dept;

-- All four plan stages
EXPLAIN EXTENDED SELECT dept, SUM(salary) FROM employees GROUP BY dept;

-- Per-node detail blocks
EXPLAIN FORMATTED SELECT dept, SUM(salary) FROM employees GROUP BY dept;

-- Optimized logical plan with statistics
EXPLAIN COST SELECT dept, SUM(salary) FROM employees GROUP BY dept;

-- Physical plan + generated Java code
EXPLAIN CODEGEN SELECT dept, SUM(salary) FROM employees GROUP BY dept;
```

---

## Part 6 — Common Misreadings and Fixes

### Filter ABOVE FileScan

```
*(1) Filter (category#10 = Electronics)    ← bad: above the scan
+- *(1) FileScan parquet [...]
         PushedFilters: []                  ← empty
```
Full table scan, then in-JVM filter. Fix: check for UDF in filter chain, column type mismatch, or data format that doesn't support pushdown.

### Multiple Exchange Nodes

Three or more `Exchange` nodes = expensive pipeline. Each one is a serialize-write-transfer-deserialize cycle.
- Can any join side be broadcast? (check `EXPLAIN COST` for `sizeInBytes`)
- Is a CTE referenced multiple times causing duplicate shuffles? (check for `ReusedExchange`)
- Can two adjacent `groupBy` steps be combined into one?

### BroadcastNestedLoopJoin on Large Tables

```
BroadcastNestedLoopJoin BuildRight, Inner, (complex_condition)
:- FileScan large_table [...]   ← O(N × M) is catastrophic here
```
Add an equality condition to drive BHJ. Rewrite `NOT IN` as `NOT EXISTS`.

### AdaptiveSparkPlan isFinalPlan=false — Don't Trust It

Called before execution: always shows initial static plan. AQE decisions (SMJ → BHJ conversion, partition coalescing) are invisible. Execute first, then call `explain()` to see the real plan.

### Codegen Silently Disabled

If operators are missing the `*(n)` prefix and you expect them to be fused:
```python
# Check schema width
print(len(df.schema.fields))  # > 200 = codegen disabled for that stage

# Check if master switch is on
spark.conf.get("spark.sql.codegen.wholeStage")  # should be "true"
```
Also: `ObjectHashAggregate`, `SortAggregate`, `WindowExec` never participate in WSCG — any plan containing them will have an uncoasced boundary.

---

## Quick Reference: Which Mode for Which Problem?

| Problem | Mode |
|---------|------|
| Which join strategy was chosen? | `simple` |
| Did predicate pushdown succeed? | `extended` or `formatted` |
| What are `PushedFilters` / `PartitionFilters` exactly? | `formatted` |
| Did DPP fire? | `formatted` (look for `dynamicpruningexpression`) |
| Why is Spark using SortMergeJoin instead of broadcast? | `cost` (check `sizeInBytes` on both sides) |
| Did AQE change the plan at runtime? | `simple` or `formatted` (after query runs, `isFinalPlan=true`) |
| Did WholeStageCodegen fire? | `codegen` (or check for `*(n)` prefix in any mode) |
| Why is there a `BroadcastNestedLoopJoin`? | `extended` (look at Analyzed plan for non-equality condition) |

*See also: [02-lazy-evaluation-and-dag.md](02-lazy-evaluation-and-dag.md) for DAG basics | [21-aqe-and-performance.md](21-aqe-and-performance.md) for AQE configuration | [28-spark-ui-debugging.md](28-spark-ui-debugging.md) for reading plans in the SQL tab*
