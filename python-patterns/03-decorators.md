<!-- python-patterns: Decorators -->

# Decorators

## How It Works

A decorator is a callable that takes a function and returns a replacement function. `@decorator` is syntactic sugar for `func = decorator(func)`.

```python
def my_decorator(func):
    def wrapper(*args, **kwargs):
        print("before")
        result = func(*args, **kwargs)
        print("after")
        return result
    return wrapper

@my_decorator
def greet(name):
    print(f"hello {name}")

# Equivalent to:
greet = my_decorator(greet)
```

---

## `functools.wraps` — Always Use It

Without `@wraps`, the wrapper replaces the original function's metadata.

```python
import functools

def my_decorator(func):
    @functools.wraps(func)   # copies __name__, __doc__, __module__, __qualname__
    def wrapper(*args, **kwargs):
        return func(*args, **kwargs)
    return wrapper

@my_decorator
def load_data():
    """Load data from S3."""
    ...

load_data.__name__   # "load_data" — correct with @wraps
load_data.__doc__    # "Load data from S3." — preserved

# Without @wraps:
load_data.__name__   # "wrapper" — breaks logging, introspection, pytest naming
```

---

## Decorator Factory (Decorator with Arguments)

When the decorator itself needs parameters, add one more layer.

```python
import functools, time

def retry(max_attempts=3, delay=1.0, exceptions=(Exception,)):
    """Decorator factory — returns the actual decorator."""
    def decorator(func):
        @functools.wraps(func)
        def wrapper(*args, **kwargs):
            for attempt in range(1, max_attempts + 1):
                try:
                    return func(*args, **kwargs)
                except exceptions as e:
                    if attempt == max_attempts:
                        raise
                    wait = delay * attempt   # linear backoff; use 2**attempt for exponential
                    time.sleep(wait)
        return wrapper
    return decorator

@retry(max_attempts=5, delay=2.0, exceptions=(ConnectionError, TimeoutError))
def fetch_from_api(url):
    ...
```

---

## Real DE Decorators

### Timer

```python
import functools, time, logging

logger = logging.getLogger(__name__)

def timer(func):
    @functools.wraps(func)
    def wrapper(*args, **kwargs):
        start = time.perf_counter()
        result = func(*args, **kwargs)
        elapsed = time.perf_counter() - start
        logger.info(f"{func.__name__} completed in {elapsed:.3f}s")
        return result
    return wrapper

@timer
def run_pipeline():
    ...
```

### Rate Limiter (Class-Based Decorator)

```python
import functools, time, threading

class RateLimit:
    """Limit a function to N calls per second across threads."""

    def __init__(self, calls_per_second):
        self._min_interval = 1.0 / calls_per_second
        self._last_called = 0.0
        self._lock = threading.Lock()

    def __call__(self, func):
        @functools.wraps(func)
        def wrapper(*args, **kwargs):
            with self._lock:
                elapsed = time.monotonic() - self._last_called
                if elapsed < self._min_interval:
                    time.sleep(self._min_interval - elapsed)
                self._last_called = time.monotonic()
            return func(*args, **kwargs)
        return wrapper

@RateLimit(calls_per_second=10)
def call_api(endpoint):
    ...
```

### Retry with Exponential Backoff

```python
import functools, time, logging

def retry_exponential(max_attempts=3, base_delay=1.0, exceptions=(Exception,)):
    def decorator(func):
        @functools.wraps(func)
        def wrapper(*args, **kwargs):
            for attempt in range(1, max_attempts + 1):
                try:
                    return func(*args, **kwargs)
                except exceptions as e:
                    if attempt == max_attempts:
                        logging.error(f"{func.__name__} failed after {max_attempts} attempts: {e}")
                        raise
                    wait = base_delay * (2 ** (attempt - 1))  # 1s, 2s, 4s, 8s...
                    logging.warning(f"{func.__name__} attempt {attempt} failed, retrying in {wait}s")
                    time.sleep(wait)
        return wrapper
    return decorator

@retry_exponential(max_attempts=4, base_delay=2.0, exceptions=(IOError, ConnectionError))
def download_file(s3_key):
    ...
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
