<!-- PySpark-patterns: SparkSession and Configuration -->

# SparkSession and Configuration

## How It Works

SparkSession is the single entry point for all Spark functionality since Spark 2.0.
It wraps SparkContext, SQLContext, and HiveContext.

### Basic Creation

```python
from pyspark.sql import SparkSession

spark = SparkSession.builder \
    .appName("my-job") \
    .getOrCreate()
```

`getOrCreate()` returns the existing session if one already exists in the JVM.
In notebooks (Databricks, EMR notebooks), `spark` is pre-created — do not create a new one.

### Creating with Config

```python
spark = SparkSession.builder \
    .appName("my-job") \
    .config("spark.sql.shuffle.partitions", "100") \
    .config("spark.sql.adaptive.enabled", "true") \
    .config("spark.executor.memory", "4g") \
    .config("spark.executor.cores", "4") \
    .getOrCreate()
```

### Modifying Config at Runtime

```python
# After session is created
spark.conf.set("spark.sql.shuffle.partitions", "50")

# Read a config value
spark.conf.get("spark.sql.shuffle.partitions")
```

---

## The Number One Tuning Knob: shuffle.partitions

```python
spark.conf.set("spark.sql.shuffle.partitions", "200")  # default
```

This controls how many partitions are created after a shuffle operation (groupBy, join, orderBy, distinct).

| Data Size | Recommended shuffle.partitions |
|-----------|-------------------------------|
| < 1 GB    | 10–20                         |
| 1–10 GB   | 50–100                        |
| 10–100 GB | 200–400                       |
| > 100 GB  | 400–1000+                     |

**Why default 200 breaks small jobs:**
- A 100 MB groupBy with 200 partitions creates 200 tasks, each processing 0.5 MB.
- Task scheduling overhead dominates actual computation time.

**Why default 200 breaks large jobs:**
- A 1 TB join with 200 partitions creates partitions of ~5 GB each.
- Executors spill to disk, jobs slow down dramatically or OOM.

---

## AQE: Adaptive Query Execution

```python
spark.conf.set("spark.sql.adaptive.enabled", "true")   # default since Spark 3.2
spark.conf.set("spark.sql.adaptive.coalescePartitions.enabled", "true")
spark.conf.set("spark.sql.adaptive.skewJoin.enabled", "true")
```

AQE re-optimizes the query plan at runtime using actual shuffle statistics.
See `21-aqe-and-performance.md` for full details.

**With AQE on:** `shuffle.partitions` becomes a ceiling, not a fixed value.
AQE coalesces small post-shuffle partitions automatically.

**With AQE off:** `shuffle.partitions` is exactly what you get. Set it carefully.

---

## Key Config Options Reference

```python
# Memory
"spark.executor.memory"              # heap per executor (e.g., "4g")
"spark.executor.memoryOverhead"      # off-heap per executor (e.g., "512m")
"spark.driver.memory"                # driver heap (e.g., "2g")

# Parallelism
"spark.executor.cores"               # cores per executor (2–5 is typical)
"spark.default.parallelism"          # default partitions for RDD operations
"spark.sql.shuffle.partitions"       # partitions after SQL shuffle

# Joins
"spark.sql.autoBroadcastJoinThreshold"  # default 10MB; -1 to disable auto broadcast

# AQE
"spark.sql.adaptive.enabled"                          # default true (Spark 3.2+)
"spark.sql.adaptive.coalescePartitions.enabled"       # default true
"spark.sql.adaptive.skewJoin.enabled"                 # default true
"spark.sql.adaptive.skewJoin.skewedPartitionFactor"  # default 5x median

# Delta Lake
"spark.databricks.delta.retentionDurationCheck.enabled"  # set false to VACUUM < 7 days (dangerous)

# IO
"spark.sql.files.maxPartitionBytes"  # default 128MB; controls file split size on read
"spark.sql.files.openCostInBytes"    # cost to open a file; affects partition planning
```

---

## How Wrong Config Breaks Things at Scale

### Too few shuffle partitions (e.g., 10 for 500 GB join)
- Each post-shuffle partition is 50 GB
- Executor runs out of memory trying to build hash table
- Job fails with `OutOfMemoryError` or spills heavily to disk

### Too many shuffle partitions (e.g., 2000 for 1 GB groupBy)
- 2000 tiny files written and read for each shuffle stage
- Task scheduler overhead exceeds compute time
- Job takes 10x longer than it should

### Driver memory too low
- `.collect()`, `.toPandas()`, `broadcast()` of large table all pull data to driver
- Driver OOM kills the entire application

### Executor memory too low with collect_list / pivot
- Aggregations that accumulate large collections per group build in executor memory
- Large groups OOM individual executors mid-task

---

## SparkSession in Tests

```python
import pytest
from pyspark.sql import SparkSession

@pytest.fixture(scope="session")
def spark():
    return SparkSession.builder \
        .master("local[2]") \
        .appName("test") \
        .config("spark.sql.shuffle.partitions", "4") \
        .getOrCreate()
```

Always set `shuffle.partitions` low in tests. Default 200 adds unnecessary overhead
when your test data has 100 rows.

---

## Stopping the Session

```python
spark.stop()
```

Only call this in standalone scripts. In notebooks, never call `spark.stop()` —
it kills the entire notebook kernel's Spark context.
