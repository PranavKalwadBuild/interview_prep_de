# PySpark Explain Plans

> How does this break? A wrong plan silently produces correct results 10× slower.
> How does this scale? Every Exchange node is a network shuffle — count them.

---

## The 5 Explain Modes

```python
df.explain()                      # mode="simple"  — physical plan only
df.explain(mode="simple")         # physical plan only
df.explain(mode="extended")       # parsed → analyzed → optimized logical → physical
df.explain(mode="codegen")        # physical plan + generated Java source
df.explain(mode="cost")           # optimized logical + Statistics(sizeInBytes=...)
df.explain(mode="formatted")      # numbered physical plan + per-node detail section
```

| Mode | Output | Best Used For |
|------|--------|---------------|
| `simple` | Physical plan | Quick sanity check |
| `extended` | All 4 plan stages | See what Catalyst optimized away |
| `codegen` | Physical + Java code | Confirm whole-stage codegen fires |
| `cost` | Optimized logical + size stats | Check if Catalyst has column stats |
| `formatted` | Numbered physical + per-node details | Human reading; numbered nodes with metrics |

**Critical caveat**: `explain()` shows the **initial plan**. AQE re-optimizations (join strategy switches, skew splits, partition coalescing) happen at runtime. To see the actual executed plan: **Spark UI → SQL/DataFrame tab**.

---

## The 4 Catalyst Plan Stages (`extended` mode)

```
== Parsed Logical Plan ==
  Raw AST. Column names unresolved. Table refs unresolved.

== Analyzed Logical Plan ==
  All attributes resolved via Catalog. Types assigned.

== Optimized Logical Plan ==
  Catalyst applies: predicate pushdown, projection pushdown,
  constant folding, filter combination, subquery unnesting.
  This is what Catalyst hands to the physical planner.
  `cost` mode adds Statistics(sizeInBytes=...) here.

== Physical Plan ==
  One or more physical plans generated; best selected via cost model.
  This is what actually executes on the cluster.
```

---

## Physical Plan Node Reference

### `Exchange` — THE most important node

```
Exchange hashpartitioning(dept#1, 200)
```

- Every `Exchange` = **stage boundary** = data serialized and shuffled across network
- Count Exchange nodes → predict how many shuffle stages you'll see in Spark UI
- `Exchange` and `BroadcastExchange` always **break whole-stage codegen chains**
- Number in parentheses = partition count produced
- Two types: `Exchange` (shuffle) and `BroadcastExchange` (broadcast)

**Breaking question**: How many exchanges? Each one is a potential OOM / spill / skew point.

---

### `HashAggregate` — always appears in pairs

```
*(1) HashAggregate(keys=[dept#1], functions=[partial_sum(salary#2)])   ← pre-shuffle
Exchange hashpartitioning(dept#1, 200)
*(2) HashAggregate(keys=[dept#1], functions=[sum(salary#2)])           ← post-shuffle
```

- First: **partial aggregate** per partition (pre-shuffle, reduces data volume)
- Second: **final aggregate** across shuffled partitions
- Uses `BytesToBytesMap` (UnsafeRow-based). Can spill to disk if execution memory exhausted.
- Seeing one HashAggregate without a pair is unusual — check for missing shuffle

---

### `BroadcastHashJoin` (BHJ) — fastest join

```
BroadcastHashJoin [key#1], [key#2], Inner, BuildRight
+- BroadcastExchange HashedRelationBroadcastMode(List(key#1))
   +- [small table scan]
+- [large table scan]
```

- `BuildRight` = right side was broadcast
- **No shuffle on either side** — broadcast replaces shuffle for small side
- Triggers when one side < `spark.sql.autoBroadcastJoinThreshold` (10 MB default) OR via `broadcast()` hint
- **Not supported**: full outer joins
- **Breaking scenario**: small side is actually 500 MB → driver OOM when collecting for broadcast

**Supported join types**:
- `BuildRight` (right side broadcast): inner, left semi, left anti, left outer
- `BuildLeft` (left side broadcast): inner, right outer, left semi, left anti

---

### `SortMergeJoin` (SMJ) — default large-to-large

```
SortMergeJoin [key#1], [key#2], Inner
:- *(2) Sort [key#1 ASC]
:  +- Exchange hashpartitioning(key#1, 200)
:     +- *(1) [left scan]
+- *(4) Sort [key#2 ASC]
   +- Exchange hashpartitioning(key#2, 200)
      +- *(3) [right scan]
```

- Both sides: Exchange → Sort → Merge
- 2 Exchanges = 2 shuffles. Robust (can spill). Supports all join types.
- AQE can convert planned SMJ to BHJ at runtime if one side turns out small
- `spark.sql.join.preferSortMergeJoin=true` (default) — SMJ is always the fallback

---

### `ShuffledHashJoin` (SHJ) — faster than SMJ but risky

- Both sides shuffled on join key, then **hash table built on smaller partition** (no sort step)
- **No spill fallback** — if partition doesn't fit in memory → job **fails**
- Conditions: `preferSortMergeJoin=false` AND one side ≥ 3× smaller AND avg partition fits in memory
- AQE can convert SMJ → SHJ via `spark.sql.adaptive.maxShuffledHashJoinLocalMapThreshold`

---

### `Filter` — predicate pushdown indicator

```
FileScan parquet [col1#1, col2#2]
  PushedFilters: [IsNotNull(status), EqualTo(status,active)]   ← pushed down ✓
  ReadSchema: struct<col1:string, col2:int>
```

- `PushedFilters` in `FileScan` = filter evaluated at storage layer ✓
- `Filter` node appearing **above** `FileScan` without PushedFilters = filter applied after reading all data ✗

**When pushdown fails**:
```python
# Bad — UDF on filter column kills pushdown
df.filter(my_udf(col("status")) == "active")

# Bad — transformation before filter
df.filter(upper(col("status")) == "ACTIVE")

# Good — literal filter on raw column
df.filter(col("status") == "active")
```

---

### `Project` — projection pushdown indicator

```
*(1) Project [col1#1, col2#2]
FileScan parquet [col1#1, col2#2]
  ReadSchema: struct<col1:string, col2:int>   ← only 2 columns read from file
```

- `ReadSchema` shows exactly which columns Spark read from Parquet/ORC
- If ReadSchema shows 50 columns but you only need 5: add `.select()` earlier in the chain

---

### `Sort` — when it adds overhead

```
*(2) Sort [key#1 ASC NULLS FIRST], false, 0
```

- `false` = not a global sort (per-partition only)
- `true` = global sort (`df.orderBy()`) → requires an additional Exchange before Sort
- Every `SortMergeJoin` adds **2 Sort nodes** — expected and correct

---

### `Window` — always expensive

- Always triggers a shuffle (on `PARTITION BY` columns) + sort (on `ORDER BY`)
- **No whole-stage codegen** for Window operators
- No `*` prefix on Window nodes in the plan

---

### `BroadcastNestedLoopJoin` — performance warning

- Used for cross joins or non-equi joins with no equi-condition
- O(n×m) per partition
- Seeing this on a multi-billion row table → query is likely broken

---

### `CartesianProduct` — almost always a bug

- Full cross join
- At production scale: essentially infinite unless both inputs are tiny

---

## Whole-Stage Codegen Indicators

```
*(1) HashAggregate(...)    ← * prefix = codegen ACTIVE, (1) = codegen region ID
    HashAggregate(...)     ← no * = codegen OFF for this operator
```

- `*` prefix = whole-stage codegen active (operators fused into single JVM method)
- Operators that **always break codegen**: `Exchange`, `Window`, `Sort` (in some cases)
- Schema > 100 columns → codegen deactivated (see `spark.sql.codegen.maxFields`)

---

## Key Patterns to Look For

### Pattern 1: Missing predicate pushdown

```
Filter (status = active)           ← Filter ABOVE scan = full table read then filter
+- FileScan parquet [...]
     PushedFilters: []             ← nothing pushed
```

**Cause**: UDF or transformation applied to filter column before the filter.
**Fix**: Filter on raw columns before any transformation.

---

### Pattern 2: Wrong join strategy (SMJ on small table)

```
SortMergeJoin [dim_id#1], [id#2]   ← dimension table gets shuffled
:- Exchange hashpartitioning(dim_id#1, 200)
   +- FileScan parquet dim_table    ← 5 MB table — should be broadcast
```

**Fix**: Increase `spark.sql.autoBroadcastJoinThreshold` or use `broadcast()` hint.

---

### Pattern 3: AQE join conversion (visible in UI only)

```
# explain() shows:
SortMergeJoin [key#1], [key#2]

# Spark UI SQL tab shows (after AQE):
BroadcastHashJoin [key#1], [key#2]   ← AQE converted at runtime
```

This is expected and correct — AQE measured actual data sizes and switched strategies.

---

### Pattern 4: Missing statistics (cost mode)

```
== Optimized Logical Plan ==
+- Join Inner, (key#1 = key#2)
   Statistics(sizeInBytes=8.0 EiB)   ← 8 EiB = unknown/default estimate
```

`8 EiB` = Catalyst has no real statistics. AQE runtime stats will override this.
**Fix**: Run `ANALYZE TABLE` or collect statistics, or rely on AQE.

---

### Pattern 5: Data explosion

```
Exchange hashpartitioning(key#1, 200)
+- Generate explode(array_col#1)    ← each row becomes N rows
   +- FileScan parquet [...]         ← small input, massive output
```

Check the Exchange's shuffle write in Spark UI — if shuffle bytes >> input bytes, you have data explosion.

---

### Pattern 6: Dynamic Partition Pruning active

```
FileScan parquet [...]
  PartitionFilters: [isnotnull(date#3), dynamicpruningexpression(date#3 IN ...)]
```

`dynamicpruningexpression` in `PartitionFilters` = DPP is working.
**Verify effectiveness**: Check "number of partitions read" in SQL tab — should be << total partitions.

---

## Reading `formatted` Mode

```python
df.explain(mode="formatted")
```

Output structure:
```
== Physical Plan ==
*(3) SortMergeJoin [key#1], [key#2], Inner                     ← node 3
:- *(2) Sort [key#1 ASC NULLS FIRST], false, 0                 ← node 2
:  +- Exchange hashpartitioning(key#1, 200), ENSURE_REQUIREMENTS, [plan_id=1]
:     +- *(1) Filter (isnotnull(key#1))                        ← node 1
:        +- Scan parquet db.table [key#1, val#2]
...

===== Details for Query Plan Nodes =====

(3) SortMergeJoin
Input [2]: [key#1, val#2]
Join type: Inner
Join condition: None
Left keys [1]: [key#1]
Right keys [1]: [key#2]

(1) Filter
Input [2]: [key#1, val#2]
Condition : isnotnull(key#1)
```

The numbered nodes in the header correspond to detailed sections below — easier to read than `extended` for large plans.

---

## Practical Workflow

```python
# Step 1: Quick structural check — count Exchange nodes
df.explain(mode="simple")

# Step 2: Verify pushdown
df.explain(mode="formatted")
# Look for: PushedFilters, PartitionFilters, ReadSchema, dynamicpruningexpression

# Step 3: Check statistics availability
df.explain(mode="cost")
# Look for: Statistics(sizeInBytes=...) — if 8 EiB, no stats

# Step 4: Confirm codegen fires
df.explain(mode="codegen")
# Look for * prefixes on major operators

# Step 5: See what actually ran (post-AQE)
# Spark UI → SQL/DataFrame tab → click the query
# This is the ground truth
```
