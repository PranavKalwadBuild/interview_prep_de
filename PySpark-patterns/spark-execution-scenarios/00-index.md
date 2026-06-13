# Spark Execution Scenarios — Navigation Index

> Math-first execution tracing scenarios for Apache Spark.
> Each scenario derives partition counts, task counts, stage counts, memory budgets, shuffle bytes, and wave counts from first principles.
> No code. No vendor names. Pure execution model math.

---

## How to Use This Index

- **Interview prep**: Read the Key Numbers Summary and Interview Takeaways sections.
- **Cluster sizing**: Start with Scenario 15, then work backwards through relevant patterns.
- **Debugging slow jobs**: Match your symptom to the Bottleneck Identification sections.
- **Understanding a concept**: Find the scenario where that concept is PRIMARY.

---

## Scenario Library

### Tier 1 — Standard

| File | Scenario | Domain | Primary Concepts |
|---|---|---|---|
| [01-narrow-transformation-etl.md](01-narrow-transformation-etl.md) | Narrow Transformation ETL | E-commerce Orders | Narrow ops, input partitions, task waves, single-stage job |
| [02-groupby-aggregation-shuffle.md](02-groupby-aggregation-shuffle.md) | GroupBy Aggregation + Shuffle | Retail Sales Analytics | Map-side combine, shuffle partitions, 2-stage job, partial agg math |
| [03-sort-merge-join-two-large-tables.md](03-sort-merge-join-two-large-tables.md) | Sort Merge Join: Two Large Tables | Financial Transactions | SMJ stages, exchange operators, sort memory, spill risk |

### Tier 2 — Intermediate

| File | Scenario | Domain | Primary Concepts |
|---|---|---|---|
| [04-broadcast-join-fact-dimension.md](04-broadcast-join-fact-dimension.md) | Broadcast Join: Fact + Dimension | DW Enrichment | Broadcast memory per executor, no-shuffle savings, OOM threshold |
| [05-skewed-groupby-hot-key.md](05-skewed-groupby-hot-key.md) | Skewed GroupBy: Hot Key | Social Media Analytics | Skew factor math, AQE splitting, straggler time, collect_list OOM |
| [06-window-function-sessionization.md](06-window-function-sessionization.md) | Window Function: Sessionization | Clickstream Analytics | Window partition memory, sort cost, OOM conditions, shuffle tuning |
| [07-multi-stage-wide-transformation-chain.md](07-multi-stage-wide-transformation-chain.md) | Multi-Stage: 3 Joins + 2 Aggs | Healthcare Claims | Full DAG trace, cumulative shuffle bytes, stage count, broadcast savings |

### Tier 3 — Complex

| File | Scenario | Domain | Primary Concepts |
|---|---|---|---|
| [08-caching-dag-reuse.md](08-caching-dag-reuse.md) | Caching for DAG Reuse | ML Feature Engineering | Cache memory math, eviction, MEMORY_AND_DISK, checkpoint vs cache |
| [09-write-partitioning-small-file-problem.md](09-write-partitioning-small-file-problem.md) | Write Partitioning: Small File Explosion | IoT Data Lake | File count math, repartition vs coalesce, ideal file size, partition explosion |
| [10-spill-scenario-sort-memory.md](10-spill-scenario-sort-memory.md) | Spill to Disk: Under-Provisioned Sort | Fraud Detection Sort | Spill threshold, disk I/O cost, correct cluster sizing to eliminate spill |
| [11-structured-streaming-microbatch.md](11-structured-streaming-microbatch.md) | Structured Streaming Micro-Batch | Payment Fraud Detection | Batch size math, state store sizing, watermark, checkpoint overhead |

### Tier 4 — Pathological

| File | Scenario | Domain | Primary Concepts |
|---|---|---|---|
| [12-aqe-dynamic-partition-coalescing.md](12-aqe-dynamic-partition-coalescing.md) | AQE: Dynamic Partition Coalescing | Log Analytics | AQE algorithm math, targetPostShuffleInputSize, before vs after partition counts |
| [13-extreme-skew-salting-pattern.md](13-extreme-skew-salting-pattern.md) | Extreme Skew: Manual Salting | Marketplace Join | Salt factor derivation, data amplification cost, straggler time before vs after |
| [14-full-pipeline-bronze-silver-gold.md](14-full-pipeline-bronze-silver-gold.md) | End-to-End: Bronze→Silver→Gold | Insurance Claims | Total jobs/stages/tasks/shuffle across all hops, critical path, bottleneck |
| [15-cluster-sizing-from-scratch.md](15-cluster-sizing-from-scratch.md) | Cluster Sizing from First Principles | Regulatory Reporting | Throughput constraint, memory constraint, parallelism constraint, which dominates |

---

## Cross-Reference: By Concept

| Concept | Primary Scenario | Also In |
|---|---|---|
| Input partition count derivation | 01 | All |
| Memory per task calculation | 01, 03 | 05, 06, 10, 13 |
| Task waves (parallelism utilization) | 01 | All |
| Shuffle boundary = new stage | 02 | 03, 07 |
| Partial aggregation (map-side combine) | 02 | 12 |
| Sort merge join stages | 03 | 07, 13 |
| Spill to disk math | 03, 10 | 06, 13 |
| Broadcast variable memory | 04 | 07 |
| Data skew + AQE auto-fix | 05 | 12 |
| Manual salting | 13 | — |
| Window function memory | 06 | 14 |
| DAG with multiple shuffle stages | 07 | 14 |
| Cache memory and eviction | 08 | — |
| Small file problem | 09 | 14 |
| repartition vs coalesce | 09 | 14 |
| Streaming state store sizing | 11 | — |
| AQE coalescing algorithm | 12 | — |
| Full pipeline job/stage/task count | 14 | — |
| Cluster sizing from SLA | 15 | — |

---

## Core Math Formulas Quick Reference

### Partition Count
```
input_partitions = ceil(total_data_size_MB / maxPartitionBytes_MB)
default maxPartitionBytes = 128 MB
tasks_in_stage = partitions_in_stage
```

### Parallelism Waves
```
total_cores = num_executors x cores_per_executor
waves = ceil(tasks_in_stage / total_cores)
utilization = (tasks_in_stage % total_cores) / total_cores  [last wave utilization]
```

### Memory Per Task
```
available_executor_memory = executor_memory x (1 - overhead_fraction)  [overhead default 10%]
unified_memory = available_executor_memory x spark.memory.fraction  [default 0.6]
execution_memory = unified_memory x spark.memory.storageFraction complement
memory_per_task = execution_memory / cores_per_executor
```

### Shuffle Partition Tuning
```
ideal_shuffle_partitions = total_shuffle_data_MB / target_partition_size_MB
target_partition_size = 128-200 MB (rule of thumb)
minimum = total_cores x 2  (ensure at least 2 waves)
```

### Spill Prediction
```
data_per_task = shuffle_write_bytes / shuffle_partitions
memory_needed = data_per_task x sort_factor  [sort_factor = 2-3x]
spill_occurs if memory_needed > memory_per_task
spill_volume = memory_needed - memory_per_task  [per task]
```

### Broadcast Threshold
```
in_memory_size = on_disk_size x deserialization_factor  [~2-3x for columnar]
broadcast_memory_per_cluster = in_memory_size x num_executors
safe if in_memory_size < executor_memory x 0.10  [rule of thumb]
```
