<!-- pyspark-implementation: PySpark Pattern Implementations — Navigation Index -->

# PySpark Pattern Implementations

Runnable PySpark implementations of every pattern in `../PySpark-patterns/`, using the same employee/department dataset as `../sql-implementation/` with identical intentional data flaws.

**Run any script directly:**
```bash
python pyspark-implementation/01-sparksession-config/01-sparksession-and-config.py
```
Each script keeps SparkSession alive at the end — browse **http://localhost:4040** then press Enter to stop.

**Install dependencies:**
```bash
pip install pyspark
pip install delta-spark   # only for 18-delta-lake/
```

---

## Schema Overview

**9 shared DataFrames** — created by `00-setup/seed_data.py`.

| Table | Rows | Key Flaws Embedded |
|---|---|---|
| `departments` | 8 | `budget=None` for Executive dept |
| `employees` | 41 | NULL salary (emp 10, 15), NULL email (emp 22), salary=0.0 (emp 19 soft-dup), future hire_date (emp 41), Terminated (emp 35) |
| `salary_history` | 33 | Exact duplicate row for emp 5 on 2022-04-01 |
| `projects` | 12 | NULL budget (proj 7), end_date < start_date (proj 11) |
| `project_assignments` | 26 | Exact duplicate row (emp 9 / proj 9), NULL hours_billed |
| `performance_reviews` | 20 | NULL rating, NULL reviewer_id |
| `emp_events` | 40 | NULL session_id (emp 14), missing logout events |
| `purchase_orders` | 25 | Exact duplicate rows (19-20), NULL dept_id orphan (25) |
| `leave_requests` | 20 | Overlapping dates (emp 12 req 1-2), NULL leave_type (req 11) |

**Skew:** Engineering has 14/41 employees (34%).

---

## Folder Map

| Folder | Patterns Covered | Source File |
|---|---|---|
| [00-setup/](00-setup/) | SparkSession builder + seed DataFrames | `spark_session.py`, `seed_data.py` |
| [01-sparksession-config/](01-sparksession-config/) | SparkSession creation, configs, app name, log level | PySpark-patterns 01 |
| [02-lazy-evaluation/](02-lazy-evaluation/) | Lazy eval, DAG, transformations vs actions, lineage | PySpark-patterns 02 |
| [03-dataframe-basics/](03-dataframe-basics/) | select, filter, withColumn, alias, drop, orderBy | PySpark-patterns 03 |
| [04-joins/](04-joins/) | INNER/LEFT/RIGHT/FULL join, broadcast join | PySpark-patterns 04 |
| [05-aggregations/](05-aggregations/) | groupBy, agg, pivot, rollup, cube | PySpark-patterns 05 |
| [06-window-functions/](06-window-functions/) | ranking, lag/lead, running aggs, ROWS/RANGE frames | PySpark-patterns 06 |
| [07-null-handling/](07-null-handling/) | isNull, fillna, dropna, coalesce, when/otherwise | PySpark-patterns 07 |
| [08-deduplication/](08-deduplication/) | distinct, dropDuplicates, ROW_NUMBER dedup | PySpark-patterns 08 |
| [09-complex-types/](09-complex-types/) | arrays, maps, structs, explode, collect_list | PySpark-patterns 09 |
| [10-udfs/](10-udfs/) | Python UDF, pandas UDF, UDF performance | PySpark-patterns 10 |
| [11-date-time/](11-date-time/) | date_diff, date_add, date_format, to_date, trunc | PySpark-patterns 11 |
| [12-string-functions/](12-string-functions/) | concat, split, regexp_replace, trim, like | PySpark-patterns 12 |
| [13-schema-and-types/](13-schema-and-types/) | StructType, DDL strings, schema inference, casting | PySpark-patterns 13 |
| [14-partitioning-shuffles/](14-partitioning-shuffles/) | repartition, coalesce, shuffle, partition skew | PySpark-patterns 14 |
| [15-broadcast-skew-joins/](15-broadcast-skew-joins/) | broadcast hint, skew join, salting | PySpark-patterns 15 |
| [16-caching-persistence/](16-caching-persistence/) | cache, persist, StorageLevel, unpersist | PySpark-patterns 16 |
| [17-file-formats-io/](17-file-formats-io/) | read/write Parquet, CSV, ORC, JSON, schema-on-read | PySpark-patterns 17 |
| [18-delta-lake/](18-delta-lake/) | DeltaTable, ACID, time travel, merge, vacuum | PySpark-patterns 18 |
| [20-scd-patterns/](20-scd-patterns/) | SCD Type 1 (overwrite), SCD Type 2 (window-based) | PySpark-patterns 20 |
| [21-aqe-performance/](21-aqe-performance/) | AQE configs, skewJoin, coalescePartitions, broadcastJoin | PySpark-patterns 21 |
| [22-null-deep-dive/](22-null-deep-dive/) | NULL in joins, aggs, windows, anti-joins, SCD2 | PySpark-patterns 22 |
| [23-duplicate-deep-dive/](23-duplicate-deep-dive/) | exact dups, soft dups, dedup in windows/sessions/SCD | PySpark-patterns 23 |
| [24-performance-optimization/](24-performance-optimization/) | explain plan, predicate pushdown, column pruning, skew | PySpark-patterns 24 |
| [26-explain-deep-dive/](26-explain-deep-dive/) | explain modes, physical/logical plan reading | PySpark-patterns 26 |
| [27-jobs-stages-tasks/](27-jobs-stages-tasks/) | job/stage/task model, shuffle boundaries, task slots | PySpark-patterns 27 |
| [28-spark-ui-debugging/](28-spark-ui-debugging/) | UI tabs, DAG, GC metrics, spill detection, skew | PySpark-patterns 28 |
| [29-data-cleaning-workflow/](29-data-cleaning-workflow/) | end-to-end cleaning pipeline on flawed dataset | PySpark-patterns 29 |
| [30-statistical-eda/](30-statistical-eda/) | describe, percentiles, correlation, skewness, profiling | PySpark-patterns 30 |
| [data/output/](data/output/) | All file writes land here (parquet/, csv/, delta/, orc/) | — |

*(19-structured-streaming skipped — requires live source)*

---

## How Each Script Is Structured

```python
import sys, os
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '00-setup'))
from spark_session import get_spark, output_path, stop_and_wait
from seed_data import load_all, register_views

spark = get_spark("script-name")
dfs = register_views(spark)          # also registers Spark SQL temp views
emp = dfs["employees"]
dept = dfs["departments"]

# ... pattern code ...

stop_and_wait(spark)                 # keeps UI alive; blocks until Enter pressed
```

## Spark UI Tips

- **Jobs tab:** see which actions triggered jobs; track skipped stages (cached data)
- **Stages tab:** look for shuffle read/write bytes; spill to disk indicators
- **SQL tab:** see full query plan for DataFrame operations; check pushed filters
- **Storage tab:** check fraction cached after `.cache()` calls
- **Environment tab:** verify config values (shuffle.partitions, AQE settings)
