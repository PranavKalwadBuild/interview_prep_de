<!-- python-patterns: Error Handling in Pipelines -->

# Error Handling in Pipelines

---

## Understanding Exception Handling: Why It Matters in DE

### The Problem: Failing Silently

```python
# BAD: Error is silently ignored
def load_data(filepath):
    try:
        df = pd.read_csv(filepath)
    except:  # Bare except — catches EVERYTHING
        pass  # Ignore and continue
    return df  # May be None or empty

# In production: silently corrupts downstream processes
result = load_data("wrong_path.csv")  # Returns None silently
processed = result.groupby("user_id").sum()  # AttributeError: 'NoneType' object has no attribute 'groupby'
# Error propagates downstream, making root cause hard to find
```

**Mental Model:** In data pipelines, every error must be visible. Hiding errors means corrupted data in the warehouse.

### The Solution: Explicit Exception Handling

```python
# GOOD: Errors are visible
def load_data(filepath):
    try:
        df = pd.read_csv(filepath)
    except FileNotFoundError:
        logging.error(f"File not found: {filepath}")
        raise  # Fail fast, don't hide errors
    except pd.errors.ParserError as e:
        logging.error(f"Failed to parse {filepath}: {e}")
        raise
    return df

# In production: error is visible, can be debugged and fixed
```

---

## try / except / else / finally — Complete Flow

```python
def process_with_cleanup(filepath):
    try:
        # Execution starts here
        print("STEP 1: Opening file")
        f = open(filepath)
        
        print("STEP 2: Reading data")
        data = f.read()  # If this raises, jump to except
        
        print("STEP 3: Processing")
        result = transform(data)
        
        # If we reach here, no exception — execute else block
        
    except FileNotFoundError as e:
        # Exception was raised in try block
        print(f"STEP EXCEPTION: File not found: {e}")
        # Can log, retry, or re-raise
        # If we don't re-raise, execution continues after finally
        
    except ValueError as e:
        print(f"STEP EXCEPTION: Invalid data: {e}")
        raise  # Re-raise to caller
        
    else:
        # ONLY runs if no exception in try block
        print("STEP ELSE: Success, processing result")
        save_result(result)
        
    finally:
        # ALWAYS runs (before returning/raising)
        print("STEP FINALLY: Cleanup")
        if f:
            f.close()  # Guaranteed cleanup

# Execution flows:
# Case 1 (no exception): TRY → ELSE → FINALLY
# Case 2 (FileNotFoundError): TRY → EXCEPT → FINALLY
# Case 3 (ValueError, re-raised): TRY → EXCEPT → FINALLY → RAISE
```

### Key Points

- **try** — risky code goes here
- **except** — runs if specific exception occurs; can catch multiple types: `except (ValueError, TypeError):`
- **else** — runs ONLY if no exception in try; use for success-path logic (logging, notifications, success handlers)
- **finally** — ALWAYS runs; use for cleanup (close files, connections, rollback transactions)

```python
# Bad: using finally for success logic
try:
    data = fetch_data()
except Exception as e:
    log_error(e)
finally:
    save_data(data)  # Runs even if fetch failed! data may be None

# Good: using else for success logic
try:
    data = fetch_data()
except Exception as e:
    log_error(e)
else:
    save_data(data)  # Runs only if fetch succeeded

finally:
    cleanup_temp_files()  # Cleanup runs regardless
```

---

## Exception Hierarchy — Catch Specific, Never Catch All

```python
BaseException                 # Never catch this (includes SystemExit, Ctrl+C)
├── SystemExit               # Ctrl+C — should exit
├── KeyboardInterrupt        # Ctrl+C — should exit
├── GeneratorExit
└── Exception                # Safe to catch
    ├── StopIteration
    ├── ValueError           # convert("abc") → invalid value
    ├── TypeError            # Add string + int → wrong type
    ├── KeyError             # dict["missing_key"] → key not found
    ├── IndexError           # list[999] → index out of range
    ├── AttributeError       # obj.missing_attr → attribute not found
    ├── NameError            # undefined_var → variable not defined
    ├── IOError / OSError    # File operations fail (parent of FileNotFoundError)
    ├── RuntimeError         # Generic runtime problem
    ├── ZeroDivisionError    # x / 0
    └── ... many others
```

### What to Catch

```python
# BAD: Catches everything, including bugs you should see
try:
    data = complex_operation()
except Exception:
    return None  # Hides bugs — you can't see what went wrong

# BAD: Catches everything including Ctrl+C
try:
    run_pipeline()
except:  # Bare except catches BaseException — can't kill process!
    pass

# GOOD: Catch only what you expect and can handle
try:
    data = fetch_from_api(url)
except ConnectionError:
    logging.error(f"Network error, retrying...")
    retry_later()
except TimeoutError:
    logging.error(f"Timeout, aborting this attempt")
    raise  # Let caller decide what to do
except json.JSONDecodeError as e:
    logging.error(f"Invalid JSON response: {e}")
    raise
# If other exceptions occur, they propagate immediately (good!)
```

---

## Custom Exception Hierarchy for Pipelines

In production, create domain-specific exception hierarchies to communicate errors clearly:

```python
class PipelineError(Exception):
    """Base exception for all pipeline-related errors."""
    pass

class ExtractionError(PipelineError):
    """Failed to extract data from source."""
    def __init__(self, source, reason, original_exception=None):
        self.source = source
        self.reason = reason
        self.original_exception = original_exception
        super().__init__(f"Extraction from {source} failed: {reason}")

class TransformationError(PipelineError):
    """Failed to transform data."""
    def __init__(self, step, reason, row_sample=None):
        self.step = step
        self.reason = reason
        self.row_sample = row_sample
        super().__init__(f"Transform step {step} failed: {reason}\nSample: {row_sample}")

class LoadError(PipelineError):
    """Failed to load data to destination."""
    def __init__(self, destination, rows_count, reason):
        self.destination = destination
        self.rows_count = rows_count
        self.reason = reason
        super().__init__(f"Failed to load {rows_count} rows to {destination}: {reason}")

# Usage:
try:
    data = extract_from_s3(bucket, key)
except Exception as e:
    raise ExtractionError(
        source=f"s3://{bucket}/{key}",
        reason=f"Connection timeout after 3 retries",
        original_exception=e
    )

try:
    transformed = transform_data(data)
except KeyError as e:
    raise TransformationError(
        step="feature_engineering",
        reason=f"Missing required column: {e}",
        row_sample=data.iloc[0].to_dict()
    )

try:
    load_to_db(transformed)
except Exception as e:
    raise LoadError(
        destination="warehouse.fact_table",
        rows_count=len(transformed),
        reason=str(e)
    )
```

---

## Real DE Patterns: Resilient Pipelines

### Retry with Exponential Backoff

Transient failures (network blips, temporary API downtime) should retry, not fail:

```python
import time, logging

def fetch_with_retry(url, max_retries=3, base_delay=1.0):
    """Fetch URL with exponential backoff."""
    last_exception = None
    
    for attempt in range(1, max_retries + 1):
        try:
            logging.info(f"Attempt {attempt}/{max_retries}: fetching {url}")
            response = requests.get(url, timeout=10)
            response.raise_for_status()
            return response.json()
        
        except requests.exceptions.Timeout as e:
            last_exception = e
            logging.warning(f"Timeout on attempt {attempt}")
            
        except requests.exceptions.ConnectionError as e:
            last_exception = e
            logging.warning(f"Connection error on attempt {attempt}")
        
        except requests.exceptions.HTTPError as e:
            if response.status_code >= 500:
                # Server error — retry
                last_exception = e
                logging.warning(f"HTTP {response.status_code} on attempt {attempt}")
            else:
                # Client error (4xx) — don't retry
                raise
        
        if attempt < max_retries:
            wait = base_delay * (2 ** (attempt - 1))  # 1s, 2s, 4s
            logging.info(f"Retrying in {wait}s...")
            time.sleep(wait)
    
    raise ExtractionError(
        source=url,
        reason=f"Failed after {max_retries} retries",
        original_exception=last_exception
    )
```

### Early Validation — Fail Fast

Validate data quality before expensive processing:

```python
def validate_data_schema(df, required_columns, min_rows=0):
    """Validate dataframe meets minimum expectations."""
    
    # Check columns
    missing_cols = set(required_columns) - set(df.columns)
    if missing_cols:
        raise TransformationError(
            step="schema_validation",
            reason=f"Missing required columns: {missing_cols}",
            row_sample=None
        )
    
    # Check row count
    if len(df) < min_rows:
        raise TransformationError(
            step="schema_validation",
            reason=f"Expected >= {min_rows} rows, got {len(df)}",
            row_sample=None
        )
    
    # Check for nulls in key columns
    null_counts = df[required_columns].isna().sum()
    if null_counts.any():
        logging.warning(f"Null values found: {null_counts[null_counts > 0].to_dict()}")

# Usage: Fail immediately if data looks wrong
try:
    raw_data = extract_from_s3(...)
    validate_data_schema(raw_data, required_columns=["user_id", "event_type"], min_rows=1000)
    transformed = transform(raw_data)  # Only process if validation passed
except TransformationError as e:
    logging.critical(f"Data validation failed: {e}")
    raise
```

### Partial Success Handling

Sometimes partial failures are acceptable (e.g., processing 5000 rows, 10 fail):

```python
def batch_load_with_error_handling(records, batch_size=1000):
    """Load records, handling failures gracefully."""
    failed_records = []
    loaded_count = 0
    
    for i in range(0, len(records), batch_size):
        batch = records[i:i+batch_size]
        
        try:
            db.bulk_insert(batch)
            loaded_count += len(batch)
            logging.info(f"Loaded batch: {i+1}-{min(i+batch_size, len(records))}")
        
        except Exception as e:
            # If batch fails, try individual inserts to find the bad row
            logging.warning(f"Batch insert failed, retrying individually: {e}")
            
            for record in batch:
                try:
                    db.insert(record)
                    loaded_count += 1
                except Exception as row_error:
                    logging.error(f"Failed to insert record {record}: {row_error}")
                    failed_records.append((record, str(row_error)))
    
    # Report results
    logging.info(f"Loaded: {loaded_count}, Failed: {len(failed_records)}")
    
    if failed_records:
        # Save failed records for review
        with open("failed_records.json", "w") as f:
            json.dump(failed_records, f, indent=2)
        
        if len(failed_records) > 0.05 * len(records):  # > 5% failure
            raise LoadError(
                destination="warehouse",
                rows_count=len(records),
                reason=f"Too many failures: {len(failed_records)} rows"
            )
```

---

## Interview Questions

**Q: What's the difference between `except Exception` and bare `except`?**
`except Exception` catches all recoverable exceptions but lets SystemExit and KeyboardInterrupt propagate (can still Ctrl+C). Bare `except` catches BaseException — including Ctrl+C and SystemExit — making your process unkillable. Always use `except Exception` or specific exception types, never bare `except`.

**Q: When would you use `else` vs `finally` in try/except?**
- `else`: Runs ONLY if no exception in try block. Use for success-path logic (saving results, notifications, logging success).
- `finally`: ALWAYS runs (success or exception). Use for cleanup (closing files, rolling back transactions, releasing resources).

Bad: `finally: save_data(data)` — runs even if fetch failed, data may be None. Good: `else: save_data(data)` — runs only on success.

**Q: How would you design a custom exception hierarchy for an ETL pipeline?**
Create a base PipelineError, then specialized subclasses: ExtractionError (source, reason), TransformationError (step, reason, row_sample), LoadError (destination, rows, reason). Include context in __init__ so the exception carries debugging info. This makes error handling specific and traceable.

**Q: A batch load of 10,000 records fails partway through. How would you handle partial success?**
Try the batch insert first. If it fails, retry individual records, collecting failures. Log how many loaded vs failed. Save failed records to a file for manual review. If failure rate > threshold (e.g., 5%), raise an error. This allows recovery and transparency.

**Q: Should you catch and suppress exceptions in a data pipeline? When?**
Rarely. Suppressing exceptions hides bugs and creates silent data corruption. Only suppress when you've genuinely handled the error (e.g., optional config file missing — use defaults). In most cases, log the error and re-raise (using `raise`) so it propagates upstream where it can be debugged.

**Q: Why is custom exception information (source, reason, sample) important in pipelines?**
Standard exceptions (ValueError, IOError) don't provide context. A custom exception with source=S3 bucket, reason=timeout, row_sample=["user_id:123..."] makes debugging fast. Without context, you chase ghosts trying to find which step failed and why.

**Q: What's the difference between transient vs permanent failures? How do you handle each?**
- Transient (temporary): NetworkError, Timeout, 503 Service Unavailable. Retry with exponential backoff.
- Permanent (won't change): FileNotFoundError, JSONDecodeError, 400 Bad Request. Log and fail immediately — retrying won't help.

Code the difference: `except ConnectionError: retry()` vs `except KeyError: raise`.

**Q: You're fetching from an API with a 10-second timeout. It fails 3 times before succeeding. Should you catch and suppress the exceptions?**
No. Catch and retry: `except Timeout: wait then retry`. Only suppress if you have a fallback (e.g., use cached data). Suppressing without action loses visibility. Log each failure so ops knows the API is flaky.

**Q: What does logging.exception() do vs logging.error()?**
`logging.error()` logs the message. `logging.exception()` logs the message PLUS the full traceback. Use `logging.exception()` in except blocks so you have stack trace for debugging. Use `logging.error()` for non-exception errors.

**Q: Your transformation step encounters a row with a missing required field. How do you handle it?**
Fail fast with a detailed error:
```python
raise TransformationError(
    step="required_fields_validation",
    reason=f"Row missing 'user_id' field",
    row_sample=row.to_dict()
)
```
This tells you exactly which row failed and why, making debugging easy.

---
```

---
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
