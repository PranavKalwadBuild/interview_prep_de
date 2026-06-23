# Python Errors and Exception Handling

## Why Exception Handling Matters
In data pipelines, errors are inevitable: network failures, malformed data, resource exhaustion. Proper exception handling ensures pipelines fail gracefully, provide meaningful diagnostics, and can recover or alert appropriately.

## Exception Hierarchy
```text
BaseException
├── SystemExit
├── KeyboardInterrupt
└── Exception
    ├── ArithmeticError
    │   ├── FloatingPointError
    │   ├── OverflowError
    │   └── ZeroDivisionError
    ├── LookupError
    │   ├── IndexError
    │   └── KeyError
    ├── UnicodeError
    │   ├── UnicodeDecodeError
    │   ├── UnicodeEncodeError
    │   └── UnicodeTranslateError
    ├── ValueError
    │   └── UnsupportedOperation
    ├── TypeError
    ├── AttributeError
    ├── ImportError
    │   └── ModuleNotFoundError
    ├── OSError
    │   ├── BlockingIOError
    │   ├── ChildProcessError
    │   ├── ConnectionError
    │   │   ├── BrokenPipeError
    │   │   ├── ConnectionAbortedError
    │   │   ├── ConnectionRefusedError
    │   │   └── ConnectionResetError
    │   ├── FileExistsError
    │   ├── FileNotFoundError
    │   ├── InterruptedError
    │   ├── IsADirectoryError
    │   ├── NotADirectoryError
    │   ├── PermissionError
    │   └── TimeoutError
    ├── RuntimeError
    │   ├── NotImplementedError
    │   └── RecursionError
    ├── NameError
    │   └── UnboundLocalError
    ├── SyntaxError
    │   └── IndentationError
    │       └── TabError
    ├── AssertionError
    ├── MemoryError
    └── ReferenceError
```

## Common Exceptions in Data Engineering
| Exception | When It Occurs |
|-----------|---------------|
| `FileNotFoundError` | Missing input file |
| `PermissionError` | Insufficient file permissions |
| `IsADirectoryError` | Expected file, got directory |
| `ValueError` | Invalid data format/conversion |
| `TypeError` | Wrong data type passed |
| `KeyError` | Missing dictionary key |
| `IndexError` | List index out of range |
| `ConnectionError` | Network/database connection failed |
| `TimeoutError` | Operation timed out |
| `MemoryError` | Out of memory |
| `UnicodeDecodeError` | Invalid character encoding |

## Basic Try/Except
```python
try:
    # risky code
    data = load_file("data.csv")
except FileNotFoundError:
    # handle specific exception
    logger.error("Input file not found")
    raise  # re-raise if needed
except PermissionError as e:
    logger.error(f"Permission denied: {e}")
    # use default data or skip
except Exception as e:
    # catch-all (use cautiously)
    logger.error(f"Unexpected error: {e}")
```

## Multiple Except Clauses
```python
try:
    process_data(data)
except ValueError as ve:
    handle_invalid_data(ve)
except TypeError as te:
    handle_wrong_type(te)
except (IOError, OSError) as ioe:
    handle_io_error(ioe)
except Exception as e:
    logger.critical(f"Unexpected failure: {e}")
    raise
```

## Else Clause
```python
try:
    result = risky_operation()
except SpecificError as e:
    handle_error(e)
else:
    # runs only if no exception occurred
    log_success(result)
    return result
```

## Finally Clause
```python
try:
    resource = acquire_resource()
    # use resource
except SpecificError as e:
    handle_error(e)
finally:
    # always runs, even if exception occurred
    release_resource(resource)
    # or use context manager (with statement)
```

## Try/Except/Else/Finally Together
```python
try:
    connection = open_connection()
    data = fetch_data(connection)
except ConnectionError as e:
    log_connection_failure(e)
    data = get_cached_data()
else:
    log_successful_fetch(len(data))
finally:
    close_connection(connection)
```

## Raising Exceptions
```python
def validate_age(age):
    if not isinstance(age, int):
        raise TypeError("Age must be an integer")
    if age < 0:
        raise ValueError("Age cannot be negative")
    if age > 150:
        raise ValueError("Age seems unrealistically high")
    return True
```

## Chaining Exceptions
```python
try:
    raw_data = parse_json(raw_string)
except json.JSONDecodeError as e:
    raise ValueError("Invalid JSON payload") from e
```

## Custom Exceptions
```bash
# Custom exception hierarchy for data pipeline
class PipelineError(Exception):
    """Base class for all pipeline exceptions."""
    pass

class ValidationError(PipelineError):
    """Raised when data validation fails."""
    def __init__(self, message, field=None, value=None):
        super().__init__(message)
        self.field = field
        self.value = value

class ExtractionError(PipelineError):
    """Raised when data extraction fails."""
    pass

class TransformationError(PipelineError):
    """Raised when data transformation fails."""
    pass

class LoadingError(PipelineError):
    """Raised when data loading fails."""
    pass
```

### Using Custom Exceptions
```python
def extract_from_api(url):
    try:
        response = requests.get(url, timeout=30)
        response.raise_for_status()
        return response.json()
    except requests.RequestException as e:
        raise ExtractionError(f"Failed to extract from {url}") from e

def validate_email(email):
    if not isinstance(email, str):
        raise ValidationError("Email must be a string", field="email", value=email)
    if "@" not in email:
        raise ValidationError("Email missing @ symbol", field="email", value=email)
    return email.lower()
```

## Exception Context and Chaining
### Implicit Chaining
When an exception is raised inside an `except` or `finally` block, the original exception is automatically chained.

### Explicit Chaining with `raise ... from ...`
- `raise NewException() from original` sets `__cause__`
- `raise NewException()` without `from` sets `__context__` (if another exception is being handled)
- Use `from None` to suppress chaining

```python
try:
    risky_operation()
except SomeError as e:
    raise ProcessingError("Processing failed") from e
```

## Handling Exceptions in Data Pipelines

### Batch Processing with Error Isolation
```python
def process_batch(records):
    results = []
    errors = []
    
    for i, record in enumerate(records):
        try:
            processed = process_record(record)
            results.append(processed)
        except ValidationError as ve:
            errors.append({
                'index': i,
                'record': record,
                'error': str(ve),
                'type': 'validation'
            })
            log_warning(f"Record {i} failed validation: {ve}")
        except ProcessingError as pe:
            errors.append({
                'index': i,
                'record': record,
                'error': str(pe),
                'type': 'processing'
            })
            log_error(f"Record {i} processing failed: {pe}")
        except Exception as e:
            errors.append({
                'index': i,
                'record': record,
                'error': str(e),
                'type': 'unexpected'
            })
            log_critical(f"Unexpected error processing record {i}: {e}")
    
    return results, errors
```

### Retry Logic with Exponential Backoff
```python
import time
import random

def retry_operation(operation, max_attempts=3, base_delay=1, max_delay=60):
    """
    Retry an operation with exponential backoff and jitter.
    
    Args:
        operation: Callable that performs the operation
        max_attempts: Maximum number of attempts
        base_delay: Initial delay in seconds
        max_delay: Maximum delay in seconds
    
    Returns:
        Result of operation
    
    Raises:
        Last exception if all attempts fail
    """
    for attempt in range(max_attempts):
        try:
            return operation()
        except Exception as e:
            if attempt == max_attempts - 1:
                raise  # last attempt, re-raise
            
            # Calculate delay with exponential backoff and jitter
            delay = min(base_delay * (2 ** attempt), max_delay)
            jitter = random.uniform(0, delay * 0.1)  # 10% jitter
            total_delay = delay + jitter
            
            logger.warning(
                f"Attempt {attempt + 1} failed: {e}. "
                f"Retrying in {total_delay:.2f}s..."
            )
            time.sleep(total_delay)
```

### Circuit Breaker Pattern
```python
import time
from enum import Enum

class CircuitState(Enum):
    CLOSED = 0      # Normal operation
    OPEN = 1        # Failing, reject calls
    HALF_OPEN = 2   # Testing if service recovered

class CircuitBreaker:
    def __init__(self, failure_threshold=5, timeout=60):
        self.failure_threshold = failure_threshold
        self.timeout = timeout
        self.failure_count = 0
        self.last_failure_time = None
        self.state = CircuitState.CLOSED
    
    def call(self, func, *args, **kwargs):
        if self.state == CircuitState.OPEN:
            if time.time() - self.last_failure_time > self.timeout:
                self.state = CircuitState.HALF_OPEN
            else:
                raise Exception("Circuit breaker is OPEN")
        
        try:
            result = func(*args, **kwargs)
            self.on_success()
            return result
        except Exception as e:
            self.on_failure()
            raise e
    
    def on_success(self):
        self.failure_count = 0
        self.state = CircuitState.CLOSED
    
    def on_failure(self):
        self.failure_count += 1
        self.last_failure_time = time.time()
        if self.failure_count >= self.failure_threshold:
            self.state = CircuitState.OPEN
```

## Logging Exception Details
```python
import traceback
import logging

logger = logging.getLogger(__name__)

try:
    risky_operation()
except Exception as e:
    # Log just the exception message
    logger.error(f"Operation failed: {e}")
    
    # Log with traceback (includes stack trace)
    logger.error("Operation failed", exc_info=True)
    
    # Or manually format traceback
    tb_lines = traceback.format_exc().splitlines()
    for line in tb_lines:
        logger.debug(line)
```

## Best Practices
1. **Catch specific exceptions**: Avoid bare `except:` unless you're re-raising.
2. **Don't suppress exceptions**: At least log them before continuing.
3. **Use finally for cleanup**: Ensure resources are released.
4. **Prefer context managers**: Use `with` statement for automatic cleanup.
5. **Create meaningful custom exceptions**: Include relevant context.
6. **Chain exceptions appropriately**: Use `raise ... from ...` to preserve traceback.
7. **Fail fast**: Validate inputs early and fail with clear messages.
8. **Log at appropriate levels**: Use WARNING for recoverable errors, ERROR for failures.
9. **Don't use exceptions for control flow**: Exceptions are for exceptional conditions.
10. **Test error paths**: Write unit tests that verify exception handling.

## Common Gotchas
1. **Bare except**: `except:` catches `BaseException`, including `KeyboardInterrupt` and `SystemExit`.
2. **Swallowing exceptions**: Catching and not logging/handling hides problems.
3. **Incorrect exception ordering**: More specific exceptions must come before general ones.
4. **Lost exception context**: Not using `from` when raising new exceptions loses original traceback.
5. **Cleanup in wrong place**: Putting cleanup in `except` instead of `finally` misses success path.
6. **Mutable default arguments in exception handlers**: Similar to function defaults issue.
7. **Overly broad exception catching**: Catching `Exception` when you should catch specific types.

## Interview Questions
**Q: What's the difference between `except Exception` and `except BaseException`?**
A: `Exception` catches most errors you want to handle. `BaseException` also includes `SystemExit`, `KeyboardInterrupt`, and `GeneratorExit` which usually shouldn't be caught.

**Q: How do you correctly clean up resources in the presence of exceptions?**
A: Use a `try/finally` block or, preferably, a context manager (`with` statement) which guarantees cleanup.

**Q: What is exception chaining and when would you use it?**
A: Exception chaining preserves the original traceback when raising a new exception. Use it when translating low-level exceptions to higher-level domain-specific exceptions.

**Q: What's the difference between `raise` and `raise e`?**
A: `raise` (without arguments) re-raises the current exception preserving the original traceback. `raise e` creates a new exception object, losing the original traceback unless chained with `from e`.

**Q: When would you create a custom exception class?**
A: When you need to convey specific domain errors that aren't covered by built-in exceptions, or when you want to attach additional context (like field names, values) to the error.