<!-- python-patterns: Context Managers -->

# Context Managers

## How It Works

The `with` statement calls `__enter__` before the block and `__exit__` after — even if an exception is raised. Guarantees cleanup.

```python
with open("file.txt") as f:
    data = f.read()
# file is closed here regardless of exceptions

# Equivalent without with:
f = open("file.txt")
try:
    data = f.read()
finally:
    f.close()
```

---

## Class-Based Context Manager

```python
class ManagedResource:
    def __init__(self, config):
        self.config = config
        self.resource = None

    def __enter__(self):
        self.resource = connect(self.config)   # setup
        return self.resource                    # value bound to `as` variable

    def __exit__(self, exc_type, exc_val, exc_tb):
        # exc_type is None if no exception occurred
        if exc_type is not None:
            self.resource.rollback()
        else:
            self.resource.commit()
        self.resource.close()
        return False   # False = don't suppress exception; True = swallow it

with ManagedResource(config) as conn:
    conn.execute("INSERT ...")
```

### `__exit__` Return Value — Critical

| Return | Effect |
|---|---|
| `False` / `None` | Exception propagates normally |
| `True` | Exception is **suppressed** — caller sees no exception |

**In DE: almost always return `False`.** Suppressing exceptions in ETL pipelines hides bugs. Only suppress when the exception is genuinely expected and handled (e.g., `FileNotFoundError` for optional config files).

---

## `contextlib.contextmanager` — Generator-Based (Simpler)

```python
from contextlib import contextmanager

@contextmanager
def db_connection(dsn):
    conn = psycopg2.connect(dsn)
    try:
        yield conn          # execution pauses here, conn is bound to `as` variable
        conn.commit()       # runs after the with block exits normally
    except Exception:
        conn.rollback()     # runs if exception raised inside with block
        raise               # re-raise — don't suppress
    finally:
        conn.close()        # always runs

with db_connection(DSN) as conn:
    cursor = conn.cursor()
    cursor.execute("INSERT INTO events VALUES (%s, %s)", (1, "click"))
```

---

## Real DE Patterns

### S3 Temporary File Download

```python
import os, boto3
from contextlib import contextmanager

@contextmanager
def s3_temp_file(bucket, key, suffix=".tmp"):
    """Download S3 file to /tmp, yield local path, delete on exit."""
    local_path = f"/tmp/{key.replace('/', '_')}{suffix}"
    s3 = boto3.client("s3")
    s3.download_file(bucket, key, local_path)
    try:
        yield local_path
    finally:
        if os.path.exists(local_path):
            os.remove(local_path)

with s3_temp_file("my-bucket", "raw/2024/data.csv") as local:
    df = pd.read_csv(local)
    process(df)
# file deleted automatically
```

### Database Cursor with Rollback

```python
@contextmanager
def transaction(conn):
    """Wrap a DB operation in a transaction; rollback on any error."""
    cursor = conn.cursor()
    try:
        yield cursor
        conn.commit()
    except Exception:
        conn.rollback()
        raise
    finally:
        cursor.close()

with transaction(conn) as cur:
    cur.execute("UPDATE accounts SET balance = balance - 100 WHERE id = 1")
    cur.execute("UPDATE accounts SET balance = balance + 100 WHERE id = 2")
```

### Managed Spark Session

```python
from contextlib import contextmanager
from pyspark.sql import SparkSession

@contextmanager
def spark_session(app_name, **configs):
    builder = SparkSession.builder.appName(app_name)
    for k, v in configs.items():
        builder = builder.config(k, v)
    spark = builder.getOrCreate()
    try:
        yield spark
    finally:
        spark.stop()

with spark_session("my-etl", **{"spark.sql.shuffle.partitions": "50"}) as spark:
    df = spark.read.parquet("s3://bucket/data/")
    df.write.mode("overwrite").parquet("s3://bucket/output/")
```

### Timer Context Manager

```python
import time
from contextlib import contextmanager

@contextmanager
def timer(label=""):
    start = time.perf_counter()
    try:
        yield
    finally:
        elapsed = time.perf_counter() - start
        print(f"{label}: {elapsed:.3f}s")

with timer("load step"):
    load_data_to_snowflake(df)
```

### Suppress Specific Exceptions

```python
from contextlib import suppress

# contextlib.suppress — intentional suppression (be explicit about which exceptions)
with suppress(FileNotFoundError):
    os.remove("/tmp/optional_cache.tmp")

# Equivalent to:
try:
    os.remove("/tmp/optional_cache.tmp")
except FileNotFoundError:
    pass
```

### `ExitStack` — Dynamic Number of Context Managers

```python
from contextlib import ExitStack

files = ["a.csv", "b.csv", "c.csv"]

with ExitStack() as stack:
    handles = [stack.enter_context(open(f)) for f in files]
    # all files open; all closed on exit regardless of which one fails
    for handle in handles:
        process(handle)

# Also useful for conditionally adding context managers
with ExitStack() as stack:
    if debug_mode:
        stack.enter_context(timer("pipeline"))
    run_pipeline()
```

---

## Connection Pool Pattern

```python
from queue import Queue, Empty
from contextlib import contextmanager
import threading

class ConnectionPool:
    def __init__(self, factory, size=5):
        self._pool = Queue(maxsize=size)
        self._factory = factory
        for _ in range(size):
            self._pool.put(factory())

    @contextmanager
    def acquire(self, timeout=30):
        try:
            conn = self._pool.get(timeout=timeout)
        except Empty:
            raise TimeoutError("No available connections in pool")
        try:
            yield conn
        except Exception:
            conn = self._factory()   # replace broken connection
            raise
        finally:
            self._pool.put(conn)

pool = ConnectionPool(lambda: psycopg2.connect(DSN), size=10)

def worker(table_name):
    with pool.acquire() as conn:
        with transaction(conn) as cur:
            cur.execute(f"SELECT COUNT(*) FROM {table_name}")
            return cur.fetchone()[0]
```

---

## How It Breaks

### Exception in `__enter__` — `__exit__` is NOT Called

```python
@contextmanager
def broken():
    conn = connect()          # raises ConnectionError here
    try:
        yield conn
    finally:
        conn.close()           # never reached if connect() fails

# The finally block in @contextmanager IS called if the exception is inside the try/yield block.
# But if connect() fails BEFORE yield, finally still runs because try wraps it.
# Rule: put all setup INSIDE the try block if cleanup depends on it.

@contextmanager
def safe():
    conn = None
    try:
        conn = connect()
        yield conn
    finally:
        if conn:             # guard against partially initialized state
            conn.close()
```

### Swallowing Exceptions — Hard to Debug

```python
class SilentFailure:
    def __exit__(self, exc_type, exc_val, exc_tb):
        return True   # swallows ALL exceptions — pipeline fails silently

# Never do this in production ETL
# If you must suppress, be specific:
    def __exit__(self, exc_type, exc_val, exc_tb):
        if exc_type is FileNotFoundError:
            return True   # suppress only this
        return False      # re-raise everything else
```

---

## Interview Questions

**Q: What does `__exit__` returning `True` do?**
Suppresses the exception — the caller sees no error. Returning `False` or `None` allows the exception to propagate. In DE pipelines, almost always return `False`.

**Q: What's the difference between class-based and `@contextmanager` generator-based context managers?**
Both work identically from the caller's perspective. `@contextmanager` is simpler for stateless resources. Class-based is better when the context manager is complex or needs to be reused across methods (shared state).

**Q: What happens if an exception is raised inside the `with` block?**
`__exit__` is called with the exception info. If `__exit__` returns `False`, the exception propagates. If it returns `True`, the exception is suppressed.

**Q: You need to open 10 files and process them together. How do you manage their lifetimes?**
`contextlib.ExitStack` — dynamically enter each file as a context manager. All are closed on exit regardless of which one errors.

**Q: Why use a context manager for a DB connection instead of just `conn = connect()` ... `conn.close()`?**
`conn.close()` is not called if an exception occurs between connect and close. Context manager guarantees cleanup in the `finally` block even if the body raises.
