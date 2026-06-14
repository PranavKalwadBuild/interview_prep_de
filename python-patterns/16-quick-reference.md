<!-- python-patterns: Quick Reference -->

# Quick Reference

## Gotcha Table — The Interview Traps

| Gotcha | What breaks | Fix |
|---|---|---|
| Mutable default arg `def f(lst=[])` | Shared list across all calls | Use `lst=None`, init inside |
| Late binding in closures `[lambda: i for i in range(5)]` | All return `4` | Capture with `lambda i=i: i` |
| Generator exhaustion | Silent empty second pass | Materialize with `list()` if needed |
| `list_objects_v2` no pagination | Only first 1,000 S3 keys | Always use `paginator` |
| `groupby()` drops NaN keys | Silent data loss | `groupby(..., dropna=False)` |
| `df.apply(axis=1)` on large frame | 100–1000x slower than vectorized | `np.where`, `.str` accessor, vectorized ops |
| `logger.addHandler` without guard | Duplicate logs in Airflow | `if not logger.handlers:` |
| Threading for CPU-bound | No speedup (GIL blocks) | `ProcessPoolExecutor` |
| `requests.get` no retry | One failure kills the run | `HTTPAdapter + Retry` |
| `copy()` on nested dict | Mutates shared nested objects | `copy.deepcopy()` |
| `ABC` without `@abstractmethod` | Interface not enforced | Decorate every required method |
| `__exit__` returning `True` | Swallows exceptions silently | Return `False` unless intentional |
| `except:` bare | Catches `KeyboardInterrupt`, `SystemExit` | `except Exception:` |
| `str +=` in loop | O(n²) string copies | `parts.append()` then `"".join(parts)` |
| `pd.concat` inside loop | O(n²) DataFrame copies | Collect list, concat once at end |
| `iterrows()` for transforms | Python loop speed | Vectorized ops, `.apply()` at worst |
| `json.load()` vs `json.loads()` | Wrong arg type | `load(file_obj)`, `loads(string)` |
| `yaml.load()` without Loader | Arbitrary code execution | Always `yaml.safe_load()` |
| `lru_cache` with mutable args | `TypeError: unhashable` | Hashable args only (str, int, tuple) |

---

## Decision Matrices

### Concurrency

```
Is work I/O bound (network, disk, DB)?
  → ThreadPoolExecutor  (GIL releases on I/O)

Is work CPU bound (parse, compute, transform)?
  → ProcessPoolExecutor  (true parallelism, separate GIL)

Using async-native library (aiohttp, asyncpg, aiobotocore)?
  → asyncio  (event loop, minimal overhead)

Is it simple and fast enough as a loop?
  → Just a loop  (concurrency adds complexity)
```

### Data Structure

```
Membership check in hot loop?
  → set  (O(1) vs list O(n))

Need ordered, mutable sequence?
  → list

Need immutable, hashable sequence?
  → tuple  (use as dict key, set member)

Key-value with fast lookup?
  → dict  (O(1) average)

Counting occurrences?
  → collections.Counter

Grouping records by key?
  → collections.defaultdict(list)

Fixed set of fields, no methods?
  → typing.NamedTuple  (tuple + field names)

Mutable structured config?
  → @dataclass

FIFO queue?
  → collections.deque  (never list — pop(0) is O(n))
```

### File Format

```
Tabular data, production pipelines?
  → Parquet  (columnar, compressed, typed, splittable)

Large text data, human-readable, streaming?
  → JSONL  (one JSON object per line, append-friendly)

Config files?
  → YAML  (yaml.safe_load only)

Data exchange with external systems?
  → CSV  (universal) or JSON  (structured)

Schema evolution required?
  → Avro  (schema in file) or Delta Lake  (versioned Parquet)
```

### When to Use apply() in Pandas

```
Can I vectorize with NumPy/pandas built-ins?
  → Do that instead

Is it a string operation?
  → Use .str accessor instead

Is it a date operation?
  → Use .dt accessor instead

Multiple columns, complex logic, small DataFrame?
  → apply(axis=1) is acceptable

Large DataFrame, performance matters?
  → Refactor to vectorized — profile first
```

---

## Cheat Sheets

### Generator Pattern

```python
# Generator function
def read_chunks(path, size=10_000):
    with open(path) as f:
        header = next(f).strip().split(",")
        chunk = []
        for line in f:
            chunk.append(dict(zip(header, line.strip().split(","))))
            if len(chunk) >= size:
                yield chunk
                chunk = []
        if chunk:
            yield chunk

# Generator pipeline
pipeline = transform(filter_valid(parse(source)))
for batch in batch_records(pipeline, 1000):
    db.bulk_insert(batch)
```

### Decorator Pattern

```python
import functools, time, logging

def timer(func):
    @functools.wraps(func)
    def wrapper(*args, **kwargs):
        t = time.perf_counter()
        r = func(*args, **kwargs)
        logging.info(f"{func.__name__}: {time.perf_counter()-t:.3f}s")
        return r
    return wrapper

def retry(n=3, delay=1.0, exc=(Exception,)):
    def dec(func):
        @functools.wraps(func)
        def wrapper(*args, **kwargs):
            for i in range(1, n+1):
                try: return func(*args, **kwargs)
                except exc as e:
                    if i == n: raise
                    time.sleep(delay * i)
        return wrapper
    return dec
```

### Context Manager Pattern

```python
from contextlib import contextmanager

@contextmanager
def db_transaction(conn):
    cursor = conn.cursor()
    try:
        yield cursor
        conn.commit()
    except Exception:
        conn.rollback()
        raise
    finally:
        cursor.close()
```

### Dataclass Config Pattern

```python
from dataclasses import dataclass, field
import os

@dataclass
class Config:
    bucket: str
    schema: str = "public"
    batch_size: int = 10_000
    tags: list[str] = field(default_factory=list)

    def __post_init__(self):
        assert self.batch_size > 0

    @classmethod
    def from_env(cls):
        return cls(
            bucket=os.environ["BUCKET"],
            schema=os.environ.get("SCHEMA", "public"),
            batch_size=int(os.environ.get("BATCH_SIZE", 10_000)),
        )
```

### ABC + Template Method Pattern

```python
from abc import ABC, abstractmethod

class ETLStep(ABC):
    @abstractmethod
    def extract(self) -> pd.DataFrame: ...

    @abstractmethod
    def transform(self, df) -> pd.DataFrame: ...

    @abstractmethod
    def load(self, df) -> int: ...

    def run(self) -> int:   # template method
        df = self.extract()
        df = self.transform(df)
        return self.load(df)
```

### ThreadPoolExecutor with Error Handling

```python
from concurrent.futures import ThreadPoolExecutor, as_completed

def run_parallel(items, func, max_workers=16):
    futures = {executor.submit(func, item): item for item in items}
    results, errors = [], []
    with ThreadPoolExecutor(max_workers=max_workers) as pool:
        futures = {pool.submit(func, item): item for item in items}
        for future in as_completed(futures):
            item = futures[future]
            try:
                results.append(future.result())
            except Exception as e:
                errors.append((item, str(e)))
    return results, errors
```

### boto3 S3 Paginator

```python
def list_keys(bucket, prefix=""):
    paginator = s3.get_paginator("list_objects_v2")
    for page in paginator.paginate(Bucket=bucket, Prefix=prefix):
        yield from (obj["Key"] for obj in page.get("Contents", []))
```

### requests Retry Session

```python
from requests.adapters import HTTPAdapter
from urllib3.util.retry import Retry

def session():
    s = requests.Session()
    r = Retry(total=5, backoff_factor=1.0, status_forcelist=(429,500,502,503,504))
    s.mount("https://", HTTPAdapter(max_retries=r))
    return s
```

### Pandas Key Operations

```python
# groupby — preserve NaN
df.groupby("col", dropna=False)["val"].sum()

# merge with validation
pd.merge(fact, dim, on="id", how="left", validate="many_to_one")

# transform — add group stat to original rows
df["group_avg"] = df.groupby("region")["sales"].transform("mean")

# vectorized conditional
df["tier"] = np.where(df["amount"] > 1000, "high", "low")

# multiple conditions
df["tier"] = np.select(
    [df["amount"] > 10_000, df["amount"] > 1_000],
    ["premium", "standard"],
    default="basic"
)

# memory optimization
df["status"] = df["status"].astype("category")
df["id"] = pd.to_numeric(df["id"], downcast="integer")
```

---

## interview_prep_de File Index (All Folders)

```
python-patterns/
  01-data-structures-core.md
  02-comprehensions-and-generators.md
  03-decorators.md
  04-context-managers.md
  05-iterators-and-itertools.md
  06-oop-fundamentals.md
  07-oop-advanced-patterns.md
  08-error-handling-pipelines.md
  09-file-and-io-patterns.md
  10-concurrency-patterns.md
  11-de-scripting-boto3-requests.md
  12-config-and-logging.md
  13-pandas-for-de.md
  14-testing-with-pytest.md
  15-performance-patterns.md
  16-quick-reference.md  ← you are here
```
