<!-- Part of PySpark-patterns: Silent Errors — Index -->

# Silent Errors — Index

A reference library for production-grade silent bugs in PySpark: errors that produce no exceptions,
no warnings, and incorrect results. These are the bugs staff-level engineers find in post-mortems —
not in unit tests.

## What Makes a Silent Error Different

A silent error does **not** raise an exception. The job succeeds, the SLA is met, the pipeline
shows green — but the data is wrong. These bugs surface as:
- KPI drift detected by a downstream analyst weeks later
- A data audit that reveals a 0.3% revenue discrepancy
- A model trained on subtly corrupt features that underperforms in production
- A reconciliation job that reveals row counts don't match the source system

The patterns here are non-obvious, version-sensitive, and distribution-specific. Many have open
JIRA tickets in the Apache Spark issue tracker; others are emergent from the interaction of
correct-in-isolation components.

## Standard Import Block

```python
from pyspark.sql import SparkSession, Window
from pyspark.sql import functions as F
from pyspark.sql.types import (
    StructType, StructField, StringType, IntegerType, LongType,
    DoubleType, FloatType, TimestampType, BooleanType, ArrayType,
    MapType, DecimalType
)
import pandas as pd
import numpy as np
```

## File Index

| File | Title | What's Covered |
|------|-------|----------------|
| 01-lazy-evaluation-and-closures.md | Lazy Evaluation and Closures | Closure capture, accumulator timing, withColumn duplicate names, count() re-execution, foreach retry |
| 02-schema-and-type-coercion.md | Schema and Type Coercion | inferSchema sampling traps, mergeSchema column duplication, integer overflow, UNION type widening, Parquet positional read, timestamp precision |
| 03-null-and-nan-traps.md | NULL and NaN Traps | NaN != NaN filter, dropna() missing NaN, fillna on NaN, mean/min/max NaN propagation, countDistinct NULL, when() missing otherwise |
| 04-join-and-aggregation-silent-bugs.md | Join and Aggregation Silent Bugs | Fan-out joins, union() column-position alignment, approx_count_distinct error bounds, cross join from missing condition, distinct() after union() |
| 05-window-function-traps.md | Window Function Traps | No orderBy non-determinism, default frame RANGE vs ROWS, rowsBetween vs rangeBetween ties, first()/last() without ignorenulls, partition explosion |
| 06-nondeterminism-and-ordering.md | Nondeterminism and Ordering | show()/first() instability, sort within partition not preserved, repartition non-determinism, randomSplit reproducibility, speculative execution duplication |
| 07-udf-and-pandas-udf-traps.md | UDF and Pandas UDF Traps | Python UDF type truncation, None input silent coercion, Pandas UDF Series index misalignment, mapInPandas schema mismatch, UDF non-determinism reuse |
| 08-delta-lake-silent-errors.md | Delta Lake Silent Errors | MERGE non-unique source, VACUUM breaking time travel, mergeSchema adding NULLs to history, overwriteSchema dropping columns, checkpoint gap replay |
| 09-cluster-and-execution-model-bugs.md | Cluster and Execution Model Bugs | Driver OOM from silent filter no-op, broadcast variable staleness, task retry idempotency, GC heartbeat timeout duplicate write, shuffle partition config confusion |

## Severity Classification

| Severity | Meaning |
|----------|---------|
| **P0 — Data Corruption** | Wrong values written to permanent storage; downstream queries read bad data |
| **P1 — Silent Incorrectness** | Computation is wrong but job succeeds; detected only by validation |
| **P2 — Non-Determinism** | Results vary across runs; breaks reproducibility and model training |
| **P3 — Performance Trap** | Silently runs N× slower than expected; not wrong but operationally dangerous |

## Reading Order

**Debugging a production incident:** 04 → 03 → 01 → 06

**Reviewing a new pipeline for silent bugs:** 02 → 04 → 05 → 07

**Delta Lake pipeline audit:** 08 → 02 → 04

**Cluster stability review:** 09 → 06 → 01

**ML pipeline data quality:** 03 → 06 → 07 → 04

## Relationship to the Main Index

These files complement the main PySpark-patterns library. Each silent-error pattern maps to
a foundational concept in the main files:

| Silent Error File | Related Main Files |
|-------------------|--------------------|
| 01 (Lazy/Closures) | 02-lazy-evaluation-and-dag.md |
| 02 (Schema/Types) | 13-schema-and-types.md, 17-file-formats-and-io.md |
| 03 (NULL/NaN) | 07-null-handling.md, 22-null-deep-dive.md |
| 04 (Joins/Aggs) | 04-joins-and-broadcast.md, 05-aggregations.md, 23-duplicate-deep-dive.md |
| 05 (Window) | 06-window-functions.md |
| 06 (Nondeterminism) | 14-partitioning-and-shuffles.md, 27-jobs-stages-tasks.md |
| 07 (UDF) | 10-udfs-and-performance.md |
| 08 (Delta Lake) | 18-delta-lake-patterns.md, 20-scd-patterns.md |
| 09 (Cluster) | 21-aqe-and-performance.md, 28-spark-ui-debugging.md |
