<!-- python-patterns: Decorators -->

# Decorators

---

## Understanding Decorators: The Core Concept

### What is a Decorator?

A **decorator** is a function that takes another function, modifies it, and returns the modified version. The pattern is:

```
decorator(func) → modified_func
```

**Mental Model:** Decorators are like wrappers. Imagine wrapping a Christmas present:
- Original present (function): `load_data()`
- Wrapper (decorator): `@timer` — adds timing functionality
- Wrapped present: `load_data()` now reports its execution time

### Why Decorators Matter in Data Engineering

Decorators solve the **cross-cutting concerns** problem. In a pipeline, you often need:
- Logging when operations start/end
- Retry logic for unreliable APIs
- Performance timing for bottleneck identification
- Rate limiting for API calls
- Error handling and alerts

Without decorators, you'd add these to every function manually (repetitive, error-prone). Decorators let you extract these concerns once and apply them everywhere:

```python
@timer
@retry(max_attempts=3)
@log_errors
def fetch_data_from_api(url):
    ...

# vs without decorators:
def fetch_data_from_api(url):
    try:
        start = time.time()
        for attempt in range(3):
            try:
                result = actual_fetch(url)
                logger.info(f"Success in {time.time() - start}s")
                return result
            except Exception as e:
                logger.error(f"Attempt {attempt} failed: {e}")
                if attempt == 2: raise
                time.sleep(2**attempt)
    except Exception as e:
        logger.error(f"Fatal error: {e}")
        alert_ops(e)
        raise
```

### Syntax: `@decorator` is Syntactic Sugar

The `@` decorator syntax is a convenient shorthand:

```python
# These are equivalent:

# With @ syntax
@my_decorator
def greet(name):
    print(f"hello {name}")

# Without @ syntax (what actually happens)
def greet(name):
    print(f"hello {name}")
greet = my_decorator(greet)  # The decorator wraps the function
```

---

## How It Works

A decorator is a callable that takes a function and returns a replacement function:

```python
def my_decorator(func):
    """
    This is a decorator.
    It takes a function (func) and returns a wrapper.
    """
    def wrapper(*args, **kwargs):
        print("before")
        result = func(*args, **kwargs)
        print("after")
        return result
    return wrapper

@my_decorator
def greet(name):
    print(f"hello {name}")

# Behind the scenes:
# 1. greet function is defined
# 2. my_decorator(greet) is called, receiving the greet function
# 3. The wrapper function is returned
# 4. greet now refers to wrapper

# Calling greet now runs wrapper:
greet("Alice")
# Output:
# before
# hello Alice
# after
```

### The Wrapper Function

The wrapper function is critical:
- It accepts `*args, **kwargs` to work with any function signature
- It calls the original function with those arguments: `func(*args, **kwargs)`
- It can execute code before and after the function call
- It returns the result of the function call

```python
def simple_decorator(func):
    def wrapper(*args, **kwargs):
        # Code BEFORE calling func
        print(f"Calling {func.__name__} with args={args}, kwargs={kwargs}")
        
        # Call the original function
        result = func(*args, **kwargs)
        
        # Code AFTER calling func
        print(f"Returned: {result}")
        
        # Return the result
        return result
    
    return wrapper

@simple_decorator
def add(x, y):
    return x + y

add(3, 5)
# Output:
# Calling add with args=(3, 5), kwargs={}
# Returned: 8
```

---

## `functools.wraps` — Always Use It

Without `@wraps`, the wrapper replaces the original function's metadata — its name, docstring, module. This breaks introspection, logging, and testing.

```python
import functools

# WITHOUT @wraps — metadata is lost
def bad_decorator(func):
    def wrapper(*args, **kwargs):
        return func(*args, **kwargs)
    return wrapper

@bad_decorator
def load_data():
    """Load data from S3."""
    pass

print(load_data.__name__)   # "wrapper" — WRONG! Should be "load_data"
print(load_data.__doc__)    # None — WRONG! Lost the docstring
# This breaks:
# - Logging (logger.info(f"Calling {func.__name__}"))
# - pytest fixtures and discovery
# - IDE autocomplete
# - Stack traces

# WITH @wraps — metadata is preserved
def good_decorator(func):
    @functools.wraps(func)  # Copies __name__, __doc__, __module__, __qualname__, __annotations__
    def wrapper(*args, **kwargs):
        return func(*args, **kwargs)
    return wrapper

@good_decorator
def load_data():
    """Load data from S3."""
    pass

print(load_data.__name__)   # "load_data" — CORRECT
print(load_data.__doc__)    # "Load data from S3." — CORRECT
```

**Rule:** Always use `@functools.wraps(func)` in your decorator's wrapper. No exceptions.

---

## Decorator Factory (Decorator with Arguments)

When the decorator itself needs parameters, add one more layer:

```
decorator_factory(args) → decorator → wrapper → function
```

The pattern is three nested functions:

```python
import functools, time

def retry(max_attempts=3, delay=1.0, exceptions=(Exception,)):
    """
    Decorator FACTORY — returns the actual decorator.
    Parameters control the retry behavior.
    """
    def decorator(func):
        """
        This is the actual DECORATOR.
        It wraps the function.
        """
        @functools.wraps(func)
        def wrapper(*args, **kwargs):
            """
            This is the WRAPPER.
            It executes the retry logic.
            """
            last_exception = None
            
            for attempt in range(1, max_attempts + 1):
                try:
                    return func(*args, **kwargs)
                except exceptions as e:
                    last_exception = e
                    if attempt == max_attempts:
                        raise
                    wait = delay * attempt  # Linear backoff: 1s, 2s, 3s, ...
                    # For exponential: wait = delay * (2 ** (attempt - 1))
                    print(f"Attempt {attempt} failed. Retrying in {wait}s...")
                    time.sleep(wait)
        
        return wrapper
    
    return decorator

# Usage:
@retry(max_attempts=5, delay=2.0, exceptions=(ConnectionError, TimeoutError))
def fetch_from_api(url):
    # Will retry up to 5 times with 2s, 4s, 6s, 8s delays
    ...
```

### Understanding the Three Levels

```python
# Level 1: Factory function — creates the decorator
# Called once at class definition time
def retry(max_attempts=3):
    print(f"Creating decorator with max_attempts={max_attempts}")
    
    # Level 2: Decorator function — wraps the target function
    # Called once when @retry decorator is applied
    def decorator(func):
        print(f"Decorating function: {func.__name__}")
        
        # Level 3: Wrapper function — executes the retry logic
        # Called every time the decorated function is called
        @functools.wraps(func)
        def wrapper(*args, **kwargs):
            print(f"Executing {func.__name__} with args={args}")
            # Actual retry logic here
            return func(*args, **kwargs)
        
        return wrapper
    
    return decorator

# Execution order:
print("Defining decorated function...")
@retry(max_attempts=3)  # Level 1 called HERE
def my_func():          # Level 2 called HERE
    print("Inside my_func")
    return "result"

print("\nCalling decorated function...")
my_func()               # Level 3 called HERE
```

---

## Real Data Engineering Decorators

### Timer Decorator — Identify Performance Bottlenecks

In data pipelines, knowing where time is spent is critical. A timer decorator logs execution time automatically.

```python
import functools, time, logging

logger = logging.getLogger(__name__)

def timer(func):
    """Measure and log function execution time."""
    @functools.wraps(func)
    def wrapper(*args, **kwargs):
        start = time.perf_counter()
        result = func(*args, **kwargs)
        elapsed = time.perf_counter() - start
        
        # Log with function name and timing
        logger.info(f"{func.__name__} completed in {elapsed:.3f}s")
        return result
    
    return wrapper

# Usage in pipeline:
@timer
def extract_from_s3(bucket, prefix):
    # If this logs 45s, you found a bottleneck
    pass

@timer
def transform_data(df):
    # Compare times to understand where time is spent
    pass

@timer
def load_to_db(records):
    # Track bulk insert performance
    pass

# Calling pipeline logs each stage's timing automatically
extract_from_s3("data-lake", "clickstream/")
transform_data(df)
load_to_db(records)
```

### Retry Decorator with Exponential Backoff — Handle Transient Failures

APIs fail temporarily. Retry logic is essential but tedious to code. A decorator encapsulates this pattern.

```python
import functools, time, logging
import random

logger = logging.getLogger(__name__)

def retry_exponential(max_attempts=3, base_delay=1.0, exceptions=(Exception,), jitter=True):
    """
    Retry with exponential backoff.
    
    base_delay=1.0, max_attempts=3 → delays: 1s, 2s, 4s
    jitter=True adds random noise to prevent thundering herd
    """
    def decorator(func):
        @functools.wraps(func)
        def wrapper(*args, **kwargs):
            last_exception = None
            
            for attempt in range(1, max_attempts + 1):
                try:
                    return func(*args, **kwargs)
                except exceptions as e:
                    last_exception = e
                    
                    if attempt == max_attempts:
                        logger.error(f"{func.__name__} failed after {max_attempts} attempts: {e}")
                        raise
                    
                    # Exponential backoff: 2^(attempt-1) * base_delay
                    wait = base_delay * (2 ** (attempt - 1))
                    
                    # Optional jitter to prevent synchronized retries
                    if jitter:
                        wait += random.uniform(0, wait * 0.1)
                    
                    logger.warning(f"{func.__name__} attempt {attempt} failed. Retrying in {wait:.2f}s...")
                    time.sleep(wait)
        
        return wrapper
    
    return decorator

# Usage:
@retry_exponential(
    max_attempts=5,
    base_delay=2.0,
    exceptions=(ConnectionError, TimeoutError, IOError)
)
def fetch_from_api(url):
    """
    Will retry up to 5 times with delays: 2s, 4s, 8s, 16s.
    Gives external APIs time to recover.
    """
    # Actual API call
    pass

@retry_exponential(max_attempts=3, base_delay=1.0)
def query_database(sql):
    """Handle temporary database connection issues."""
    pass
```

### Rate Limiter Decorator — Respect API Quotas

APIs enforce rate limits. A rate limiter decorator prevents exceeding them.

```python
import functools, time, threading, logging

logger = logging.getLogger(__name__)

class RateLimit:
    """
    Thread-safe rate limiter.
    Ensures decorated function is called at most N times per second.
    """
    
    def __init__(self, calls_per_second):
        self._min_interval = 1.0 / calls_per_second  # e.g., 10/sec → 0.1s per call
        self._last_called = 0.0
        self._lock = threading.Lock()
    
    def __call__(self, func):
        @functools.wraps(func)
        def wrapper(*args, **kwargs):
            with self._lock:
                elapsed = time.monotonic() - self._last_called
                
                if elapsed < self._min_interval:
                    # Wait until min_interval has passed since last call
                    wait = self._min_interval - elapsed
                    logger.debug(f"Rate limit: sleeping {wait:.3f}s")
                    time.sleep(wait)
                
                self._last_called = time.monotonic()
            
            return func(*args, **kwargs)
        
        return wrapper

# Usage:
@RateLimit(calls_per_second=10)  # Max 10 calls/second
def call_external_api(endpoint):
    """
    Automatically throttled to 10 calls/second.
    No manual sleep() needed in the function.
    """
    pass

# In a loop:
urls = [f"api.example.com/data/{i}" for i in range(100)]
for url in urls:
    call_external_api(url)  # Automatically throttled to 10/sec
    # Without the decorator, would bombard the API
```

### Validation Decorator — Ensure Data Quality

Validate inputs before processing to fail fast and log issues.

```python
import functools, logging

logger = logging.getLogger(__name__)

def validate_dataframe(required_columns, min_rows=0):
    """Validate that a DataFrame meets expectations."""
    def decorator(func):
        @functools.wraps(func)
        def wrapper(df, *args, **kwargs):
            # Check columns
            missing = set(required_columns) - set(df.columns)
            if missing:
                raise ValueError(f"Missing columns: {missing}")
            
            # Check row count
            if len(df) < min_rows:
                raise ValueError(f"Expected {min_rows} rows, got {len(df)}")
            
            # Check for nulls
            nulls = df[required_columns].isna().sum()
            if nulls.any():
                logger.warning(f"Null values found: {nulls[nulls > 0].to_dict()}")
            
            logger.info(f"DataFrame validated: {len(df)} rows, {len(df.columns)} columns")
            return func(df, *args, **kwargs)
        
        return wrapper
    
    return decorator

# Usage:
@validate_dataframe(required_columns=["user_id", "event_type", "timestamp"], min_rows=1000)
def process_events(df):
    """
    Guaranteed to receive DataFrame with:
    - Columns: user_id, event_type, timestamp
    - At least 1000 rows
    """
    pass
```

### Common Gotchas with Decorators

```python
# GOTCHA 1: Forgetting @functools.wraps
def bad_decorator(func):
    def wrapper(*args, **kwargs):
        print("Before")
        return func(*args, **kwargs)
    return wrapper  # No @wraps!

@bad_decorator
def my_func():
    """My docstring."""
    pass

my_func.__name__   # "wrapper" — broke logging and introspection

# GOTCHA 2: Decorator modifies arguments (side effects)
def bad_decorator(func):
    def wrapper(arg):
        arg.append("modified")  # Mutates the argument!
        return func(arg)
    return wrapper

@bad_decorator
def process(data):
    return data

original = [1, 2, 3]
result = process(original)
print(original)  # [1, 2, 3, "modified"] — Unexpected mutation!

# GOTCHA 3: Decorator doesn't handle exceptions properly
def bad_decorator(func):
    def wrapper(*args, **kwargs):
        print("Starting")
        result = func(*args, **kwargs)
        print("Finished")  # Never executes if func raises!
        return result
    return wrapper

# FIX: Use try/finally
def good_decorator(func):
    @functools.wraps(func)
    def wrapper(*args, **kwargs):
        print("Starting")
        try:
            result = func(*args, **kwargs)
            return result
        finally:
            print("Finished")  # Always executes, even on exception
    return wrapper

# GOTCHA 4: Stacking decorators — order matters
@timer
@retry(max_attempts=3)
def my_func():
    pass

# Timing includes retries!
# If you want to time only the successful call:
@retry(max_attempts=3)
@timer
def my_func():
    pass
```

---

## Interview Questions

**Q: What is a decorator? Why use them?**
A decorator is a function that wraps another function and modifies its behavior without changing its source code. Decorators solve the cross-cutting concerns problem — logging, timing, retries, rate limiting, validation. Instead of adding these to every function manually, you apply a decorator once and it applies everywhere.

**Q: What does `@functools.wraps` do? Why is it critical?**
`@functools.wraps(func)` copies metadata from the original function to the wrapper: `__name__`, `__doc__`, `__module__`, `__annotations__`. Without it, `my_func.__name__` returns `"wrapper"` instead of `"my_func"`, breaking logging, pytest discovery, IDE autocomplete, and stack traces.

**Q: What's the difference between `@decorator` and `@decorator(args)`?**
`@decorator` applies a simple decorator directly. `@decorator(args)` uses a decorator factory — a function that takes parameters and returns the actual decorator. The pattern is three nested functions: factory → decorator → wrapper. Called at the right times:
1. Factory called once at function definition
2. Decorator called once when @decorator applied
3. Wrapper called every time the decorated function runs

**Q: How would you write a retry decorator with exponential backoff?**
See the example above: retry_exponential with base_delay, max_attempts, exceptions. Key points: (1) retry loop with exponential wait: `wait = base_delay * (2 ** (attempt - 1))`. (2) Only catch specific exceptions to avoid hiding bugs. (3) Log each attempt for debugging. (4) Add jitter to prevent thundering herd.

**Q: Your pipeline has 5 functions. You want to time each one. What's the decorator approach?**
Apply `@timer` to each function:
```python
@timer
def extract(): ...
@timer
def transform(): ...
@timer
def load(): ...
```
Now each logs its execution time automatically. You can see which stage is the bottleneck. Without decorators, you'd add timing code to each function manually.

**Q: A decorator for retries is being stacked with a decorator for timing: `@timer @retry(...) def my_func()`. What's happening?**
The decorators apply bottom-up: first `@retry` wraps `my_func`, then `@timer` wraps the result of retry. So timing includes the retry delays. If a function fails 3 times before succeeding, timing captures all the sleep() calls and retries. If you want to time only successful calls, reverse the order: `@retry(...) @timer`.

---
```

### Validate Input Types

```python
def validate_types(**type_map):
    """Decorator that validates argument types at runtime."""
    def decorator(func):
        @functools.wraps(func)
        def wrapper(*args, **kwargs):
            import inspect
            sig = inspect.signature(func)
            bound = sig.bind(*args, **kwargs)
            bound.apply_defaults()
            for param, expected_type in type_map.items():
                if param in bound.arguments:
                    val = bound.arguments[param]
                    if not isinstance(val, expected_type):
                        raise TypeError(
                            f"{func.__name__}: {param} must be {expected_type.__name__}, "
                            f"got {type(val).__name__}"
                        )
            return func(*args, **kwargs)
        return wrapper
    return decorator

@validate_types(df=pd.DataFrame, batch_size=int)
def load_chunk(df, batch_size=1000):
    ...
```

### Cache / Memoize

```python
import functools

# Built-in — lru_cache for pure functions
@functools.lru_cache(maxsize=128)
def get_schema(table_name: str) -> dict:
    return fetch_schema_from_catalog(table_name)

# Cache is keyed on arguments — only works for hashable args
# Clear cache: get_schema.cache_clear()
# Inspect: get_schema.cache_info()

# Python 3.9+ — @cache (unbounded lru_cache)
@functools.cache
def get_table_metadata(table: str) -> dict:
    ...
```

---

## Stacking Decorators

Decorators apply bottom-up (innermost first).

```python
@timer
@retry_exponential(max_attempts=3)
@validate_types(table=str)
def load_table(table):
    ...

# Equivalent to:
load_table = timer(retry_exponential(max_attempts=3)(validate_types(table=str)(load_table)))

# Execution order:
# validate_types checks args → retry wraps the call → timer measures the whole thing
```

---

## Class-Based Decorator (Stateful)

```python
class CountCalls:
    """Decorator that counts how many times a function is called."""

    def __init__(self, func):
        functools.update_wrapper(self, func)   # equivalent of @wraps for class
        self.func = func
        self.count = 0

    def __call__(self, *args, **kwargs):
        self.count += 1
        return self.func(*args, **kwargs)

@CountCalls
def fetch_page(url):
    ...

fetch_page("https://...")
fetch_page("https://...")
print(fetch_page.count)   # 2
```

---

## How It Breaks

### Forgetting `@wraps`

```python
# Breaks logging, pytest output, introspection, Airflow task naming
def bad_decorator(func):
    def wrapper(*args, **kwargs):    # no @wraps
        return func(*args, **kwargs)
    return wrapper

@bad_decorator
def my_task():
    """Important docstring."""
    ...

my_task.__name__  # "wrapper" — not "my_task"
my_task.__doc__   # None — docstring lost
```

### Returning `None` from Wrapper

```python
def broken_decorator(func):
    @functools.wraps(func)
    def wrapper(*args, **kwargs):
        func(*args, **kwargs)   # forgot to return!
    return wrapper

@broken_decorator
def compute():
    return 42

compute()  # None — silent bug
```

### Decorator on a Method That Doesn't Account for `self`

```python
# This works because *args captures self
def timer(func):
    @functools.wraps(func)
    def wrapper(*args, **kwargs):  # *args includes self for methods
        start = time.perf_counter()
        result = func(*args, **kwargs)
        ...
        return result
    return wrapper

class Pipeline:
    @timer
    def run(self):   # self passed through *args correctly
        ...
```

---

## Interview Questions

**Q: What does `@decorator` actually do?**
It's syntactic sugar for `func = decorator(func)`. The decorator is called at function definition time, not at call time.

**Q: What does `functools.wraps` do and why does it matter?**
Copies metadata (`__name__`, `__doc__`, `__module__`, `__qualname__`) from the original function to the wrapper. Without it, all decorated functions appear as "wrapper" in logs, tracebacks, and test output.

**Q: What's a decorator factory?**
A function that takes configuration arguments and returns a decorator. Required when your decorator needs parameters: `@retry(max_attempts=3)` calls `retry(3)` first, which returns the actual decorator.

**Q: When would you use a class-based decorator over a function-based one?**
When the decorator needs to maintain state across calls (call count, cache, circuit breaker state). Class decorators implement `__call__` and can hold instance variables.

**Q: Write a decorator that logs the execution time of any function.**
See `timer` above. Key points: `@functools.wraps(func)`, `time.perf_counter()`, return the result.
