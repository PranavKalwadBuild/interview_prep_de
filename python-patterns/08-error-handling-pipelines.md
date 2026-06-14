<!-- python-patterns: Error Handling in Pipelines -->

# Error Handling in Pipelines

## try / except / else / finally

```python
try:
    result = risky_operation()
except ValueError as e:
    # handle specific exception
    logging.error(f"Bad value: {e}")
except (IOError, OSError) as e:
    # handle multiple exception types
    logging.error(f"IO error: {e}")
except Exception as e:
    # catch-all — use sparingly
    logging.exception(f"Unexpected error: {e}")  # includes traceback
    raise   # re-raise — don't silently swallow in pipelines
else:
    # runs ONLY if no exception was raised
    log_success(result)
finally:
    # ALWAYS runs — cleanup goes here
    cleanup_temp_files()
```

**`else` vs `finally`:**
- `else`: runs when try block completes without exception — use for success-path logic
- `finally`: always runs — use for resource cleanup

---

## Exception Hierarchy

```python
BaseException
├── SystemExit
├── KeyboardInterrupt
├── GeneratorExit
└── Exception
    ├── ValueError
    ├── TypeError
    ├── KeyError
    ├── IndexError
    ├── AttributeError
    ├── IOError / OSError
    ├── RuntimeError
    └── ... (most catchable exceptions)
```

**Never catch `BaseException`** — it catches `KeyboardInterrupt` and `SystemExit`, making your pipeline impossible to stop.

```python
# BAD
try:
    run_forever()
except BaseException:   # catches Ctrl+C — process can't be killed
    pass

# GOOD — catch only what you can handle
try:
    run_forever()
except Exception as e:
    handle_error(e)
```

---

## Custom Exceptions for Pipelines

```python
class PipelineError(Exception):
    """Base for all pipeline exceptions."""
    pass

class ExtractionError(PipelineError):
    """Failed to pull data from source."""
    def __init__(self, source, message, cause=None):
        self.source = source
        self.cause = cause
        super().__init__(f"[{source}] {message}")

class TransformationError(PipelineError):
    """Data transformation failed."""
    def __init__(self, step, row_count, message):
        self.step = step
        self.row_count = row_count
        super().__init__(f"[{step}] failed on {row_count} rows: {message}")

class LoadError(PipelineError):
    """Failed to write to destination."""
    def __init__(self, target, rows_attempted, message):
        self.target = target
        self.rows_attempted = rows_attempted
        super().__init__(f"[{target}] load of {rows_attempted} rows failed: {message}")

class DataQualityError(PipelineError):
    """Data doesn't meet quality expectations."""
    def __init__(self, check_name, details):
        self.check_name = check_name
        super().__init__(f"Quality check failed [{check_name}]: {details}")

# Usage
try:
    df = read_from_s3(bucket, key)
except Exception as e:
    raise ExtractionError(source=f"s3://{bucket}/{key}", message="Read failed") from e
```

---

## Exception Chaining — Always Use `from`

```python
try:
    conn = connect_to_db(config)
except ConnectionError as e:
    raise PipelineError("Database unavailable") from e
    # Preserves the original exception in __cause__
    # Traceback shows: "The above exception was the direct cause of..."

# Suppress chaining (rare — usually not in DE)
raise PipelineError("...") from None
```

**Why `from e` matters:** Without it, the original exception is attached as `__context__` (implicit chaining). With `from e`, it's `__cause__` (explicit). The distinction shows in tracebacks and tells future debuggers that the chaining was intentional.

---

## Pipeline-Safe Error Patterns

### Fail Fast vs Continue on Error

```python
# Pattern 1: Fail fast — stop on first error (default for most pipelines)
def run_pipeline(tables):
    for table in tables:
        process_table(table)   # raises on error, stops everything

# Pattern 2: Continue on error — process all, collect failures
def run_pipeline_tolerant(tables):
    results = []
    failures = []
    for table in tables:
        try:
            result = process_table(table)
            results.append(result)
        except PipelineError as e:
            logging.error(f"Table {table} failed: {e}")
            failures.append({"table": table, "error": str(e)})

    if failures:
        send_alert(failures)     # alert but don't crash
    return results, failures

# Pattern 3: Fail at end — process all, then raise if any failed
def run_pipeline_collect(tables):
    failures = []
    for table in tables:
        try:
            process_table(table)
        except Exception as e:
            failures.append((table, e))

    if failures:
        error_summary = "\n".join(f"  {t}: {e}" for t, e in failures)
        raise PipelineError(f"{len(failures)} tables failed:\n{error_summary}")
```

### Retry Pattern

```python
import time, logging

def with_retry(func, max_attempts=3, delay=1.0, backoff=2.0, exceptions=(Exception,)):
    """Execute func with retry and exponential backoff."""
    last_exc = None
    for attempt in range(1, max_attempts + 1):
        try:
            return func()
        except exceptions as e:
            last_exc = e
            if attempt == max_attempts:
                break
            wait = delay * (backoff ** (attempt - 1))
            logging.warning(f"Attempt {attempt}/{max_attempts} failed: {e}. Retrying in {wait:.1f}s")
            time.sleep(wait)
    raise last_exc

# Usage
result = with_retry(
    lambda: requests.get(url, timeout=10),
    max_attempts=5,
    delay=1.0,
    exceptions=(ConnectionError, TimeoutError)
)
```

### Dead Letter Queue Pattern (Batch Processing)

```python
def process_records(records):
    successful = []
    dead_letters = []

    for record in records:
        try:
            result = transform_record(record)
            successful.append(result)
        except Exception as e:
            dead_letters.append({
                "record": record,
                "error": str(e),
                "error_type": type(e).__name__,
                "ts": datetime.utcnow().isoformat(),
            })

    logging.info(f"Processed: {len(successful)} success, {len(dead_letters)} dead letters")

    if dead_letters:
        write_to_dead_letter_queue(dead_letters)   # persist for investigation/reprocessing

    return successful
```

### Context Manager for Transaction Safety

```python
from contextlib import contextmanager

@contextmanager
def atomic_write(target_path):
    """Write to a temp path, rename on success, delete on failure."""
    import tempfile, os, pathlib
    tmp = target_path + ".tmp"
    try:
        yield tmp
        os.rename(tmp, target_path)   # atomic on most filesystems
    except Exception:
        if os.path.exists(tmp):
            os.remove(tmp)
        raise
```

---

## Logging Best Practices for DE

```python
import logging, sys

def get_pipeline_logger(name: str, level=logging.INFO) -> logging.Logger:
    logger = logging.getLogger(name)
    if logger.handlers:   # prevent duplicate handlers in Airflow workers
        return logger
    handler = logging.StreamHandler(sys.stdout)
    handler.setFormatter(logging.Formatter(
        "%(asctime)s | %(name)s | %(levelname)s | %(message)s",
        datefmt="%Y-%m-%dT%H:%M:%S"
    ))
    logger.addHandler(handler)
    logger.setLevel(level)
    return logger

# Use exc_info=True to include traceback in error logs
logger.error(f"Load failed for {table}", exc_info=True)

# Use extra to add structured context
logger.info("Loaded %d rows", row_count, extra={"table": table, "run_id": run_id})
```

---

## Warning: Silent Failures to Avoid

```python
# SILENT FAILURE 1 — bare except
try:
    process()
except:          # catches EVERYTHING including SystemExit, KeyboardInterrupt
    pass

# SILENT FAILURE 2 — catching and not re-raising
try:
    process()
except Exception:
    logging.error("Something went wrong")  # logs but swallows — caller sees success

# SILENT FAILURE 3 — returning None on error
def load(df):
    try:
        do_load(df)
        return len(df)
    except Exception:
        return None   # caller can't tell success from failure without checking

# FIX — always re-raise unless you have a specific reason not to
try:
    process()
except SpecificException as e:
    logging.error(f"Expected failure: {e}")
    raise   # always re-raise unexpected errors
```

---

## Interview Questions

**Q: What's the difference between `except Exception` and `except BaseException`?**
`Exception` catches most recoverable errors. `BaseException` also catches `SystemExit`, `KeyboardInterrupt`, and `GeneratorExit` — which should never be caught casually. Always use `except Exception` unless you specifically need to intercept process termination.

**Q: What does `raise X from Y` do?**
Chains exceptions explicitly. The original exception `Y` becomes `__cause__` of `X`. Traceback shows "The above exception was the direct cause of the following exception". Use it whenever you catch one exception and raise a different one so the original cause is never lost.

**Q: When would you use `else` in a try block?**
The `else` block runs only if no exception was raised in `try`. Useful for logic that should only happen on success and shouldn't be in `try` (to avoid accidentally catching exceptions from the success path itself).

**Q: Design error handling for a pipeline that processes 100 tables. Some may fail — what's your strategy?**
Continue-on-error with a dead letter queue: catch exceptions per table, log the failure with full context (table name, error type, traceback), store failed records/metadata for reprocessing, collect all failures, and raise a summary error at the end if any table failed. Never silently swallow.
