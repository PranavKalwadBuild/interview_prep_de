<!-- python-patterns: Context Managers -->

# Context Managers

---

## Understanding Context Managers: Resource Cleanup Guarantee

### The Problem: Resource Leaks

```python
# BAD: Resource leak if exception occurs
f = open("file.txt")
data = f.read()              # If this raises, ...
f.close()                    # ... this never executes!

# BAD: Manual cleanup is error-prone
f = open("file.txt")
try:
    data = f.read()
except Exception as e:
    print(f"Error: {e}")
finally:
    f.close()  # Easy to forget!
```

### The Solution: Context Managers

Context managers guarantee cleanup using the `with` statement:

```python
# GOOD: Cleanup guaranteed
with open("file.txt") as f:
    data = f.read()  # If this raises, ...
# ... f is closed automatically
```

**The with statement does three things:**
1. Calls `__enter__()` to set up the resource
2. Yields the result to the `as` variable
3. Calls `__exit__()` after the block (even if an exception occurs)

### Mental Model

Think of context managers as "automatic cleanup protocols." The context manager says: "I'll set up, you use me in this block, then I'll clean up — guaranteed."

---

## How It Works

The `with` statement is syntactic sugar:

```python
# These are equivalent:

# With context manager
with open("file.txt") as f:
    data = f.read()

# Without context manager (what happens behind scenes)
f = open("file.txt")  # __enter__() called
try:
    data = f.read()
finally:
    f.__exit__(None, None, None)  # Always called
```

The critical point: `__exit__()` always executes, even if an exception occurs inside the `with` block.

```python
# Exception doesn't prevent cleanup
with open("file.txt") as f:
    raise ValueError("Something went wrong")  # Exception raised
# File is STILL closed (by __exit__)
# Exception propagates after cleanup
```

---

## Class-Based Context Manager

Implement `__enter__()` and `__exit__()`:

```python
class ManagedResource:
    """Class-based context manager for database connections."""
    
    def __init__(self, connection_string):
        self.connection_string = connection_string
        self.connection = None
    
    def __enter__(self):
        """
        Called when entering the with block.
        Set up the resource here.
        Return the value to bind to the `as` variable.
        """
        print("Establishing connection...")
        self.connection = connect(self.connection_string)  # Simulated
        return self.connection
    
    def __exit__(self, exc_type, exc_val, exc_tb):
        """
        Called when exiting the with block.
        Always runs, even if an exception occurs.
        
        Parameters:
        - exc_type: Exception class (e.g., ValueError), or None if no exception
        - exc_val: Exception instance
        - exc_tb: Traceback object
        
        Return:
        - False or None: Let exception propagate normally
        - True: Suppress the exception (use carefully!)
        """
        print(f"Cleanup: exc_type={exc_type}")
        
        if exc_type is not None:
            # An exception occurred inside the with block
            print(f"Exception occurred: {exc_val}")
            self.connection.rollback()  # Undo changes on error
        else:
            # No exception, block completed normally
            self.connection.commit()  # Save changes
        
        self.connection.close()  # Always close
        
        return False  # Don't suppress exception (let it propagate)

# Usage:
with ManagedResource("postgresql://localhost/mydb") as conn:
    conn.execute("INSERT INTO events ...")
    # conn is guaranteed to be closed even if execute() raises
```

### `__exit__` Return Value — Critical Distinction

```python
def __exit__(self, exc_type, exc_val, exc_tb):
    # Case 1: Return False (default, most common)
    return False  # or just return / don't return
    # → Exception propagates normally to caller
    # → Caller must handle it

    # Case 2: Return True
    return True
    # → Exception is **suppressed** / caught
    # → Caller sees no exception (dangerous!)

# Example:
class SuppressingContextManager:
    def __enter__(self):
        return self
    
    def __exit__(self, exc_type, exc_val, exc_tb):
        if exc_type is FileNotFoundError:
            print("File not found, but we're okay with it")
            return True  # Suppress this specific exception
        
        return False  # Let other exceptions propagate

# Usage:
with SuppressingContextManager() as mgr:
    raise FileNotFoundError("config.yaml not found")  # Suppressed!
# Execution continues normally, exception is gone
```

**In data engineering:** Almost always return `False` from `__exit__()`. Suppressing exceptions in ETL pipelines hides bugs. Only suppress when the exception is genuinely expected and you've handled it (e.g., optional config files).

---

## Generator-Based Context Manager: `@contextmanager`

For simple cases, decorator-based is cleaner than class-based:

```python
from contextlib import contextmanager

@contextmanager
def db_connection(connection_string):
    """
    Generator-based context manager.
    
    Code before yield → __enter__()
    yield value → returned to `as` variable
    Code after yield → __exit__()
    """
    print("Setting up connection...")
    conn = connect(connection_string)  # Simulated
    
    try:
        yield conn  # Pause here, return conn to caller
        # Execution resumes here when exiting with block normally
        print("Committing...")
        conn.commit()
    
    except Exception as e:
        # If exception occurs inside with block, execution jumps here
        print(f"Exception occurred: {e}, rolling back...")
        conn.rollback()
        raise  # Re-raise the exception (don't suppress)
    
    finally:
        # Always runs, whether exit is normal, exception, or early return
        print("Closing connection...")
        conn.close()

# Usage:
with db_connection("postgresql://localhost/mydb") as conn:
    cursor = conn.cursor()
    cursor.execute("INSERT INTO events VALUES (%s, %s)", (1, "click"))
    # Here: yield paused, connection is active
# Connection closed here (finally block runs)
```

### Generator vs Class Context Manager

| Aspect | Class | Generator |
|---|---|---|
| Setup | `__enter__` method | Before `yield` |
| Cleanup | `__exit__` method | After `yield` + `finally` |
| Return value | Return from `__enter__` | Yield value |
| Suppress exception | Return `True` from `__exit__` | (harder, rarely needed) |
| Simplicity | Verbose | Concise |
| **Use when** | Complex logic needed | Simple setup/cleanup |

---

## Real Data Engineering Patterns

### S3 Temporary File Download

Fetch a large file from S3, process locally, clean up automatically:

```python
import os, boto3
from contextlib import contextmanager
import tempfile

@contextmanager
def s3_temp_file(bucket, key):
    """
    Download S3 file to temp location.
    Yield local path for processing.
    Delete temp file after use.
    """
    s3 = boto3.client("s3")
    
    # Create temp file
    with tempfile.NamedTemporaryFile(delete=False) as tmp:
        local_path = tmp.name
    
    try:
        # Download from S3
        print(f"Downloading s3://{bucket}/{key} to {local_path}...")
        s3.download_file(bucket, key, local_path)
        
        yield local_path  # Caller can process the file
        
    finally:
        # Always delete temp file
        if os.path.exists(local_path):
            print(f"Cleaning up {local_path}...")
            os.remove(local_path)

# Usage:
with s3_temp_file("data-lake", "raw/events/2024-01-01.parquet") as local_file:
    df = pd.read_parquet(local_file)
    process(df)
# local_file is deleted here, even if process() raises an exception
```

### Database Transaction Manager

Commit on success, rollback on exception:

```python
from contextlib import contextmanager
import psycopg2

@contextmanager
def db_transaction(dsn):
    """
    Manage database transaction.
    Commits if no exception, rolls back on exception.
    """
    conn = psycopg2.connect(dsn)
    cursor = conn.cursor()
    
    try:
        yield cursor
        # No exception → commit
        conn.commit()
        print("Transaction committed")
    
    except Exception as e:
        # Exception → rollback
        print(f"Exception: {e}, rolling back...")
        conn.rollback()
        raise  # Let caller handle the exception
    
    finally:
        cursor.close()
        conn.close()

# Usage:
try:
    with db_transaction(DSN) as cursor:
        cursor.execute("INSERT INTO events VALUES (%s, %s)", (1, "click"))
        # More inserts...
        # If any raises an exception, entire transaction rolls back
except Exception as e:
    print(f"Transaction failed: {e}")
```

### Timer Context Manager

Measure execution time of a code block:

```python
import time
from contextlib import contextmanager

@contextmanager
def timer(label):
    """Measure execution time of a with block."""
    start = time.perf_counter()
    try:
        yield
    finally:
        elapsed = time.perf_counter() - start
        print(f"{label} took {elapsed:.3f}s")

# Usage:
with timer("Data extraction"):
    df = extract_from_database(query)

with timer("Data transformation"):
    df = transform(df)

with timer("Data load"):
    load_to_warehouse(df)

# Output:
# Data extraction took 12.345s
# Data transformation took 3.456s
# Data load took 5.678s
```

### Multiple Resource Manager

Sometimes you need multiple resources:

```python
from contextlib import contextmanager, ExitStack

@contextmanager
def read_and_write_files(input_path, output_path):
    """Open input for reading and output for writing, with cleanup."""
    with ExitStack() as stack:
        # ExitStack manages multiple context managers
        input_file = stack.enter_context(open(input_path, "r"))
        output_file = stack.enter_context(open(output_path, "w"))
        
        yield input_file, output_file
        # Both files are closed when exiting, even if exception occurs

# Usage:
with read_and_write_files("input.csv", "output.csv") as (input_f, output_f):
    for line in input_f:
        processed = transform(line)
        output_f.write(processed)
    # Both files closed here
```

---

## Interview Questions

**Q: What is a context manager? Why use them?**
A context manager is a protocol that guarantees cleanup, even if an exception occurs. The `with` statement calls `__enter__()` before the block and `__exit__()` after. This eliminates resource leaks from forgotten cleanup. In DE, context managers are critical for databases (commit/rollback), files (close), API connections, temporary files, etc.

**Q: What happens inside a with statement?**
(1) `__enter__()` is called to set up the resource. (2) Its return value is bound to the `as` variable. (3) The with block executes. (4) `__exit__()` is called after the block, even if an exception occurs. (5) If `__exit__()` returns True, the exception is suppressed. If False or None, it propagates.

**Q: What does return True vs False from `__exit__()` mean?**
- Return False (or don't return): Exception propagates normally to the caller. Most common.
- Return True: Exception is suppressed / caught. Caller sees no exception. Dangerous in ETL — only use when you've genuinely handled the exception (e.g., optional config files).

**Q: Explain `@contextmanager` decorator. When would you use it vs a class?**
`@contextmanager` is a decorator for generator-based context managers. Code before `yield` is `__enter__()`, code after is `__exit__()`. Use it for simple setup/cleanup. Use class-based when logic is complex or you need to store state. Generator-based is more concise and Pythonic for straightforward cases.

**Q: You need to fetch a 5GB file from S3, process it locally, and delete it afterward. How would you structure this?**
Use a context manager to download to a temp file and guarantee cleanup:
```python
@contextmanager
def s3_temp_file(bucket, key):
    with tempfile.NamedTemporaryFile(delete=False) as tmp:
        local_path = tmp.name
    try:
        boto3.client("s3").download_file(bucket, key, local_path)
        yield local_path
    finally:
        os.remove(local_path) if os.path.exists(local_path)
```
This guarantees the file is deleted even if processing fails.

**Q: In a database transaction context manager, should you return True or False from `__exit__()` if an exception occurs?**
Return False (don't suppress). The context manager already rolls back the transaction, but the exception should still propagate to the caller so they can handle it (log it, alert ops, retry, etc.). If you suppress the exception, the caller doesn't know the transaction failed.

**Q: You have 3 context managers to open: input file, output file, database connection. How would you manage all 3?**
Use `ExitStack`:
```python
from contextlib import ExitStack

with ExitStack() as stack:
    input_f = stack.enter_context(open("input.txt"))
    output_f = stack.enter_context(open("output.txt", "w"))
    conn = stack.enter_context(db_connection(DSN))
    # All 3 are available
# All 3 are closed automatically
```

**Q: Contrast with and try/finally for resource cleanup. When would you use each?**
- `with` + context manager: Preferred. Automatic cleanup, cleaner syntax, cannot forget.
- `try`/`finally`: Manual, verbose, easy to forget. Only use if context manager doesn't exist (rare) or for cases where `with` doesn't fit.

**Q: What's a gotcha with context managers in exception handling?**
If `__exit__()` returns True to suppress an exception, the exception is gone — no traceback, no error message. This silently hides bugs in ETL pipelines. Almost always return False so exceptions propagate and are logged.

---
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
