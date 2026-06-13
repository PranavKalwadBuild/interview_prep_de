# PySpark Query Optimization Masterclass

> Focus: How does this break? How does this scale?
> Platform: Databricks (Spark 3.x). Intermediate → production-grade.

## Files

| File | Topic |
|------|-------|
| [01-explain-plans.md](01-explain-plans.md) | Reading explain plans — all 5 modes, every node type, what to look for |
| [02-configs.md](02-configs.md) | Config reference — AQE, joins, memory, skew, spill, Databricks-specific |
| [03-spark-ui-guide.md](03-spark-ui-guide.md) | Spark UI tab-by-tab — where to find what, scenario-driven diagnosis |
| [04-spark-ui-terminal.md](04-spark-ui-terminal.md) | REST API — get Spark UI data as JSON from terminal/curl/jq |
| [05-optimization-patterns.md](05-optimization-patterns.md) | Everything else — partitioning, bucketing, Z-order, caching, UDFs, skew, window funcs |

## Core Mental Model

```
Query executes → Stages (separated by Exchange/shuffle boundaries)
               → Tasks (one per partition per stage)

Bottlenecks live in:
  - Stages: too few tasks (under-parallelism) OR one fat task (skew)
  - Tasks: GC, spill, remote shuffle read, missing pushdown
  - Executors: OOM, GC pressure, dead containers
```

## Optimization Priority Order

1. **Reduce what moves** — predicate pushdown, projection pushdown, DPP
2. **Eliminate shuffles** — broadcast joins, bucketing
3. **Fix skew** — AQE skew join, salting
4. **Size partitions correctly** — AQE coalesce, shuffle.partitions
5. **Cache strategically** — only multi-use DataFrames
6. **Fix small files** — optimizeWrite, autoCompact, OPTIMIZE
