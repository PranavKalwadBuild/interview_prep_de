<!-- Part of PySpark-patterns: Silent Errors — UDF and Pandas UDF Traps -->

# Silent Errors — UDF and Pandas UDF Traps

Python UDFs opt out of Catalyst optimization and Arrow serialization. Pandas UDFs use Arrow
but impose strict alignment requirements that are easy to violate. Both are critical performance
bottlenecks, but the silent correctness bugs — type truncation, None handling, Series index
misalignment — are far more dangerous than the performance costs.

---

### 1. Python UDF Return Type Truncates Without Exception

**What it looks like:**
```python
@F.udf(returnType=IntegerType())
def extract_count(text):
    import re
    match = re.search(r"(\d+\.?\d*)", text)
    return float(match.group(1)) if match else 0.0

df.withColumn("count", extract_count(F.col("text"))).show()
```

**What actually happens:**
The UDF is declared to return `IntegerType` but actually returns a Python `float`. Spark silently
truncates the float to int: `1.9` becomes `1`, `2.7` becomes `2`. There is no rounding — it's
truncation (floor toward zero). No exception is raised. The downstream aggregation of "count"
is systematically lower than the true value.

**Why it's insidious:**
The truncation is silent and consistent — every float is truncated in the same direction (toward
zero). Small errors (1.9→1) look like precision differences. Aggregated over millions of rows,
the systematic undercount is significant.

**Minimal repro:**
```python
@F.udf(returnType=IntegerType())
def my_udf(x):
    return 1.9   # returns float

df = spark.createDataFrame([(1,)], ["x"])
df.withColumn("result", my_udf(F.col("x"))).show()
# result: 1  ← truncated, not 2
```

**How to catch it:**
```python
# Use the correct return type — or cast explicitly inside the UDF
@F.udf(returnType=DoubleType())
def extract_count_safe(text):
    import re
    match = re.search(r"(\d+\.?\d*)", text)
    return float(match.group(1)) if match else 0.0

# Then cast to int explicitly outside:
df.withColumn("count", F.round(extract_count_safe(F.col("text"))).cast(IntegerType()))
```

**Real-world trigger:**
A content scoring UDF that extracts fractional engagement scores from log strings, declared as
`IntegerType` to match the downstream schema. All fractional scores are truncated to whole
numbers. The engagement model is trained on integer-truncated features, losing all sub-unit
signal.

---

### 2. UDF Receiving `None` Input Silently Produces Wrong Output

**What it looks like:**
```python
@F.udf(returnType=StringType())
def format_name(first, last):
    return f"{last.upper()}, {first.capitalize()}"

df.withColumn("full_name", format_name(F.col("first"), F.col("last"))).show()
```

**What actually happens:**
When `last` is NULL in the DataFrame, Python receives `None`. `None.upper()` raises
`AttributeError` — but Spark catches exceptions inside UDFs and converts them to NULL in the
output column by default. No exception propagates to the driver. The row silently gets
`full_name = NULL`.

The more insidious case: `str(None)` returns the string `"None"`, not NULL:
```python
@F.udf(returnType=StringType())
def concat_fields(a, b):
    return str(a) + "|" + str(b)   # None becomes the string "None"
```

**Why it's insidious:**
The first pattern silently produces NULL (data loss). The second pattern silently produces the
string `"None"` (data corruption). Both pass without exception. The string `"None"` is
particularly dangerous because it looks like valid data and passes string filters and joins.

**Minimal repro:**
```python
@F.udf(returnType=StringType())
def bad_concat(a, b):
    return str(a) + b   # None → "None" if a is null

df = spark.createDataFrame([(None, "xyz")], ["a", "b"])
df.withColumn("result", bad_concat("a", "b")).show()
# result: "Nonexyz"  ← wrong, looks valid
```

**How to catch it:**
```python
# Always handle None explicitly in UDFs
@F.udf(returnType=StringType())
def safe_concat(a, b):
    if a is None or b is None:
        return None
    return str(a) + b

# Or use null-safe Spark functions instead of UDFs:
df.withColumn("result", F.concat_ws("|", "a", "b"))   # F.concat_ws returns NULL on NULL inputs
```

**Real-world trigger:**
A CRM pipeline formats user display names with a UDF. Users missing a last name get
`full_name = "None, John"` — the string "None" is stored in the database. Customer-facing
emails address users as "Dear None, John" for an entire batch before the bug is caught.

---

### 3. Pandas UDF `SCALAR` Type Ignores Series Index — Row Misalignment

**What it looks like:**
```python
@F.pandas_udf(DoubleType())
def normalize(series: pd.Series) -> pd.Series:
    return (series - series.mean()) / series.std()

df.withColumn("normalized", normalize(F.col("value"))).show()
```

**What actually happens:**
This specific UDF is safe because it doesn't modify the index. The dangerous case is when
the UDF sorts, filters, or resamples the Series:

```python
@F.pandas_udf(DoubleType())
def bad_normalize(series: pd.Series) -> pd.Series:
    sorted_series = series.sort_values()   # changes index order
    normalized = (sorted_series - sorted_series.mean()) / sorted_series.std()
    return normalized   # returned with sorted index, not input index
```

**What actually happens:**
Spark passes the Series with an integer index corresponding to the partition's row positions.
When the UDF returns a Series with a *different* index (e.g., after `sort_values()`), Spark
ignores the index and aligns the output by position. The normalized value for the smallest input
(index 0 in the sorted series) is assigned to whatever row was position 0 in the original partition,
not the row that had the smallest value. All values are silently assigned to wrong rows.

**Why it's insidious:**
The UDF computes correct statistics (mean, std, normalized values are numerically right) but
assigns them to wrong rows. If the input is already sorted, the bug is invisible. Only on
unsorted data does the misalignment appear — and the values still look plausible.

**Minimal repro:**
```python
@F.pandas_udf(DoubleType())
def sort_and_return(s: pd.Series) -> pd.Series:
    return s.sort_values().reset_index(drop=True)   # positional realignment after sort

df = spark.createDataFrame([(3,), (1,), (2,)], ["x"])
df.withColumn("sorted_x", sort_and_return("x")).show()
# x=3 gets sorted_x=1, x=1 gets sorted_x=2, x=2 gets sorted_x=3  ← misaligned
```

**How to catch it:**
Never sort, filter, or reset the index inside a scalar Pandas UDF. The output Series must have
the same index as the input Series:
```python
@F.pandas_udf(DoubleType())
def safe_normalize(series: pd.Series) -> pd.Series:
    result = (series - series.mean()) / series.std()
    assert result.index.equals(series.index), "Index changed — values will be misaligned"
    return result
```

**Real-world trigger:**
A geospatial feature UDF sorts coordinates within each partition to use a spatial index for
distance computation. The distances are computed correctly but assigned to wrong rows. The
feature store has each user's distance metric from the wrong location. The location model learns
an inverted distance-to-conversion relationship.

---

### 4. `mapInPandas` Schema Mismatch Silently Fills Missing Columns With NULL

**What it looks like:**
```python
def process(iterator):
    for df in iterator:
        yield df[["id", "score"]]   # drops "category" column

schema = StructType([
    StructField("id", LongType()),
    StructField("score", DoubleType()),
    StructField("category", StringType()),   # declared but not yielded
])
df.mapInPandas(process, schema=schema).show()
```

**What actually happens:**
The declared schema includes `category`, but the function yields DataFrames without it. Spark
does not raise an error; it silently fills the `category` column with NULL for all rows. The
output has the declared schema with a column that is entirely NULL — invisible unless the caller
checks for unexpected NULL rates.

**Why it's insidious:**
The job succeeds. The schema looks correct. Only a null-check or a downstream join on `category`
reveals the empty column. If `category` was intended for partitioning or filtering, all rows
land in the same partition or pass all filters.

**How to catch it:**
```python
def process_safe(iterator):
    for pdf in iterator:
        output = process_logic(pdf)
        expected_cols = {"id", "score", "category"}
        assert set(output.columns) == expected_cols, f"Missing columns: {expected_cols - set(output.columns)}"
        yield output
```

**Real-world trigger:**
A batch scoring pipeline uses `mapInPandas` to run a scikit-learn model. After a model update,
the model's `predict_proba` output no longer includes a class label column. The schema still
declares it; the output's label column is entirely NULL. All downstream segments based on the
predicted class label silently send all users to the NULL-class bucket.

---

### 5. UDF Declared as `deterministic=True` But Has Non-Deterministic Behavior

**What it looks like:**
```python
import random

@F.udf(returnType=StringType())
def add_noise_id(user_id):
    return f"{user_id}_{random.randint(0, 1000)}"

df.withColumn("noisy_id", add_noise_id(F.col("user_id"))).cache()
# Use noisy_id twice
df.filter(F.col("noisy_id").startswith("12345")).count()
df.groupBy("noisy_id").count().show()
```

**What actually happens:**
By default, Spark UDFs are marked as `deterministic=True`. The Catalyst optimizer may evaluate
a deterministic UDF only once and reuse the result (CSE — Common Subexpression Elimination).
A non-deterministic UDF declared as deterministic may be evaluated once per row or once per
action, silently producing inconsistent values when the UDF is referenced multiple times in
the same plan.

**Why it's insidious:**
The UDF appears to work. In local mode, it evaluates per-row consistently. In cluster mode with
CSE, the result is cached and reused. Different invocations of `noisy_id` in the same query see
the same value; different queries see different values. The "noisy" ID is not random at all.

**Minimal repro:**
```python
import random
@F.udf(returnType=IntegerType())
def get_random(_):
    return random.randint(0, 100)

df = spark.range(5)
# With deterministic=True (default), both columns may show the same values
df.withColumn("r1", get_random("id")).withColumn("r2", get_random("id")).show()
```

**How to catch it:**
```python
# Explicitly declare non-deterministic UDFs
@F.udf(returnType=StringType(), deterministic=False)
def add_noise_id(user_id):
    return f"{user_id}_{random.randint(0, 1000)}"
```

**Real-world trigger:**
An A/B test assignment UDF uses a hash function with a random salt, declared as deterministic.
Catalyst's CSE caches the result; the same user gets the same assignment if queried twice in
one job, but a different assignment across jobs. Users appear in both test and control groups
depending on when they are queried.

---

### 6. Pandas UDF Receiving Batch That Straddles Partition Boundary

**What it looks like:**
```python
@F.pandas_udf(DoubleType(), F.PandasUDFType.GROUPED_AGG)
def weighted_avg(value: pd.Series, weight: pd.Series) -> float:
    return (value * weight).sum() / weight.sum()

df.groupBy("segment").agg(weighted_avg("revenue", "weight"))
```

**What actually happens:**
Grouped aggregate Pandas UDFs receive all rows for one group in a single Pandas DataFrame call.
If the group is very large (millions of rows in one segment), the entire group must fit in memory
on one executor. Spark does not split groups across batches for grouped UDFs. If memory is
insufficient, the task OOMs silently (or after a long GC pause). With task retry, the segment
may be processed on a different executor with more available memory — or the job fails after
retries.

**Why it's insidious:**
Small segments work perfectly. The largest segment (which may be 100× larger than average) silently
exhausts executor memory and triggers retries. If the retry is on a fresh executor, it succeeds;
if it fails all retries, the job fails — but the error message is `OutOfMemoryError`, not a
data correctness error.

**How to catch it:**
```python
# Check group cardinality before using GROUPED_AGG Pandas UDF
group_sizes = df.groupBy("segment").count().orderBy(F.desc("count"))
max_group_size = group_sizes.first()["count"]
executor_memory_gb = 8  # adjust to cluster
estimated_memory_gb = max_group_size * df.schema.json().__len__() / 1e9
assert estimated_memory_gb < executor_memory_gb * 0.7, f"Group too large for Pandas UDF: {max_group_size} rows"
```

**Real-world trigger:**
A financial portfolio aggregation UDF computes weighted returns across all positions. The
"global" segment contains all positions across all portfolios. The GROUPED_AGG UDF receives all
50M rows in one batch. The executor OOMs; the task retries 3 times on increasingly overloaded
executors; eventually the stage succeeds on the 4th attempt — taking 10× longer than expected
with no clear error logged.

---

### 7. UDF Serializes Entire Enclosing Class When Defined as a Method

**What it looks like:**
```python
class FeatureExtractor:
    def __init__(self, model_path):
        self.model = load_large_model(model_path)   # 2GB model
        self.threshold = 0.5

    def extract(self, text):
        return self.model.predict(text) > self.threshold

extractor = FeatureExtractor("/models/nlp_v3")
extract_udf = F.udf(extractor.extract, BooleanType())
df.withColumn("is_relevant", extract_udf(F.col("text")))
```

**What actually happens:**
Python's pickle serializes the bound method `extractor.extract` along with its `self` — which is
the entire `FeatureExtractor` instance, including the 2GB model. This 2GB object is serialized
and sent to every executor for every task. The network overhead is massive; executors may
deserialize a 2GB object per task rather than once. Worse: if the model contains a DB connection
or file handle, it cannot be pickled, and the UDF silently fails or produces wrong results by
falling back to a default behavior.

**Why it's insidious:**
The UDF appears to work on small data. On large data with many tasks, the serialization overhead
dominates. If the class contains unserializable state, the fallback behavior (typically returning
None or an empty result) is silent.

**How to catch it:**
```python
# Use a module-level function with a lazily initialized global, not a method
_extractor = None

def get_extractor():
    global _extractor
    if _extractor is None:
        _extractor = FeatureExtractor("/models/nlp_v3")
    return _extractor

@F.udf(returnType=BooleanType())
def extract_udf(text):
    return get_extractor().extract(text)
# Model is initialized once per executor, not serialized from driver
```

**Real-world trigger:**
A content moderation pipeline wraps a 500MB BERT model in a UDF as a method. Each task
deserializes 500MB from the driver's serialized closure. The cluster runs 1000 concurrent tasks;
500GB of model data is transferred per batch. The pipeline runs 20× slower than the baseline
naive implementation, but produces correct results — until someone upgrades the model to 2GB
and the executors OOM.

---

### 8. Pandas UDF `SCALAR_ITER` Processes Fewer Batches Than Expected Without Error

**What it looks like:**
```python
from pyspark.sql.functions import pandas_udf, PandasUDFType

@pandas_udf("double", PandasUDFType.SCALAR_ITER)
def running_normalizer(iterator):
    first = True
    for batch in iterator:
        if first:
            baseline = batch.mean()
            first = False
        yield batch / baseline

df.withColumn("normalized", running_normalizer(F.col("value")))
```

**What actually happens:**
`SCALAR_ITER` UDFs receive an iterator of Pandas Series batches. The UDF must yield exactly one
output Series for every input Series received. If the UDF yields fewer Series than it receives
(e.g., skipping empty batches), Spark raises a vague error or produces truncated output. If
the UDF initializes state from the first batch but the first batch is empty (which can happen
with uneven partitions), `baseline` is `NaN` and all downstream rows are normalized to `NaN`.

**How to catch it:**
```python
@pandas_udf("double", PandasUDFType.SCALAR_ITER)
def safe_normalizer(iterator):
    baseline = None
    for batch in iterator:
        if baseline is None and len(batch) > 0:
            baseline = batch.mean()
        if baseline is None or baseline == 0:
            yield pd.Series([float('nan')] * len(batch), index=batch.index)
        else:
            yield batch / baseline
```

**Real-world trigger:**
A time-series normalization UDF initializes from the first non-empty batch. After a data
partitioning change, some partitions become empty (no data for certain segments). The iterator's
first batch is empty; baseline initializes to NaN; all values for that partition are NaN.
The pipeline produces correct output for large partitions and silently corrupts small ones.
