<!-- PySpark-patterns: Index -->

# PySpark Patterns — Navigation Index

A reference library for writing correct, performant PySpark code.
Each file covers: how it works, how it breaks, how to fix it, and how it behaves at scale.

## Standard Import Block

```python
from pyspark.sql import SparkSession, Window
from pyspark.sql import functions as F
from pyspark.sql.types import StructType, StructField, StringType, IntegerType, LongType, DoubleType, TimestampType, BooleanType, ArrayType, MapType
```

## File Index

| File | Title | What's Covered |
|------|-------|----------------|
| 01-sparksession-and-config.md | SparkSession and Configuration | Session creation, shuffle partitions, AQE toggle, config pitfalls at scale |
| 02-lazy-evaluation-and-dag.md | Lazy Evaluation and DAG | Transformations vs actions, DAG construction, `.count()` in loops, Spark UI |
| 03-dataframe-basics-select-filter.md | DataFrame Basics: Select and Filter | `.select()` vs `.withColumn()` chaining overhead, filter pushdown, column reference styles |
| 04-joins-and-broadcast.md | Joins and Broadcast | All join types, shuffle vs broadcast mechanics, NULL key behavior, skew, salting |
| 05-aggregations.md | Aggregations | `.groupBy().agg()`, countDistinct, collect_list OOM risk, pivot, NULL behavior |
| 06-window-functions.md | Window Functions | Frame spec traps, ROW_NUMBER/RANK/DENSE_RANK, running totals, LAST_VALUE trap, OOM at scale |
| 07-null-handling.md | NULL Handling | NULL filters, NULL in joins/aggs, coalesce vs when, NaN vs NULL, fillna |
| 08-deduplication.md | Deduplication | distinct vs dropDuplicates, ROW_NUMBER dedup, how dups break aggs and joins |
| 09-complex-types-arrays-maps-structs.md | Complex Types: Arrays, Maps, Structs | ArrayType/MapType/StructType, explode vs explode_outer, array/map functions, nested access |
| 10-udfs-and-performance.md | UDFs and Performance | UDF performance hierarchy, Pandas UDF, when to use UDFs, NULL handling inside UDFs |
| 11-date-and-time.md | Date and Time | to_date/to_timestamp, datediff, date_trunc, timezone traps, epoch timestamps |
| 12-string-functions.md | String Functions | regexp_extract/replace, split, concat_ws, trim traps, sha2 fingerprinting, NULL propagation |
| 13-schema-and-types.md | Schema and Types | Schema inference vs explicit, StructType definition, cast, schema evolution, mergeSchema |
| 14-partitioning-and-shuffles.md | Partitioning and Shuffles | Shuffle triggers, repartition vs coalesce, shuffle.partitions tuning, write partitioning, skew |
| 15-broadcast-and-skew-joins.md | Broadcast and Skew Joins | Broadcast mechanics, auto threshold, skew join AQE fix, manual salting pattern |
| 16-caching-and-persistence.md | Caching and Persistence | cache vs persist storage levels, when to cache, unpersist, checkpoint vs cache |
| 17-file-formats-and-io.md | File Formats and IO | Parquet/ORC/JSON/CSV/Avro/Delta trade-offs, read options, write modes, traps |
| 18-delta-lake-patterns.md | Delta Lake Patterns | Table creation, MERGE upsert, time travel, schema enforcement, OPTIMIZE, VACUUM |
| 19-structured-streaming.md | Structured Streaming | Micro-batch vs continuous, sources/triggers/output modes, watermarking, stateful ops |
| 20-scd-patterns.md | SCD Patterns | SCD Type 1 (overwrite), SCD Type 2 (history), Delta MERGE for SCD2, NULL/dup traps |
| 21-aqe-and-performance.md | AQE and Performance | AQE features, partition coalescing, dynamic broadcast, skew join fix, when AQE fails |
| 22-null-deep-dive.md | NULL Deep Dive | Full NULL behavior matrix, three-valued logic, NaN vs NULL, NULL in ORDER BY / GROUP BY |
| 23-duplicate-deep-dive.md | Duplicate Deep Dive | Three duplicate types, detection, fan-out, sources, dedup strategies, propagation |
| 24-performance-optimization.md | Performance Optimization | Ordered checklist, explain plan, Spark UI metrics, common anti-patterns |
| 25-quick-reference.md | Quick Reference | Cheat sheet, templates for window/broadcast/dedup/Delta MERGE, null-safe one-liners |
| 26-explain-deep-dive.md | explain() Deep Dive | All 5 modes, every physical plan operator, AQE plans, codegen, CBO statistics, common misreadings |
| 27-jobs-stages-tasks.md | Jobs, Stages, and Tasks | Full execution model: job lifecycle, ShuffleMapStage vs ResultStage, input vs shuffle partitions, task locality, speculation, failure modes |
| 28-spark-ui-debugging.md | Spark UI Debugging | Every tab and metric, diagnosing skew/spill/GC/OOM/failed tasks, Databricks Photon, History Server |

## Reading Order

**New to PySpark:** 01 -> 02 -> 03 -> 13 -> 07

**Joins and aggregations:** 04 -> 05 -> 06 -> 15

**Performance tuning:** 14 -> 21 -> 16 -> 24 -> 26 -> 27 -> 28

**Data quality:** 07 -> 08 -> 22 -> 23

**Delta / Lakehouse:** 17 -> 18 -> 20 -> 19

**Quick lookup:** 25

**Deep debugging (explain + UI + execution model):** 26 -> 27 -> 28
