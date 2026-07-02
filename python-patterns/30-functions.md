<!-- python-patterns: Python Functions (User-Defined) -->

# Python Functions (User-Defined)

## Why Functions Matter
Functions are the building blocks of reusable, maintainable, and testable code. In data engineering, they encapsulate ETL steps, transformations, validation, and utility operations.

## Defining Functions
```python
def function_name(parameters):
    """Docstring explaining the function."""
    # function body
    return result
```

## Function Parameters
### Positional Arguments
```python
def greet(name, greeting):
    return f"{greeting}, {name}!"
```

### Keyword Arguments
```python
greet(name="Alice", greeting="Hello")
```

### Default Arguments
```python
def connect(host, port=5432, user="admin"):
    return f"Connecting to {host}:{port} as {user}"
```
- Defaults are evaluated **once** at function definition time.
- Use immutable defaults or `None` sentinel for mutable defaults.

### Variable-Length Arguments
```python
def sum_all(*args):
    return sum(args)

def configure(**kwargs):
    for key, value in kwargs.items():
        print(f"{key}: {value}")
```
- `*args` collects positional arguments into a tuple.
- `**kwargs` collects keyword arguments into a dictionary.

### Keyword-Only Arguments (Python 3+)
```python
def process(data, *, delimiter=",", header=True):
    # delimiter and header must be passed as keywords
    pass
```

### Positional-Only Arguments (Python 3.8+)
```python
def divide(a, b, /, *, round_result=False):
    # a and b are positional-only
    # round_result is keyword-only
    result = a / b
    return round(result) if round_result else result
```

## Return Values
- Functions return `None` by default.
- Can return multiple values as a tuple.
- Can return generators using `yield`.

## Docstrings
```python
def calculate_average(numbers):
    """
    Calculate the arithmetic mean of a list of numbers.
    
    Args:
        numbers (list): List of numeric values.
        
    Returns:
        float: The arithmetic mean.
        
    Raises:
        ValueError: If the list is empty.
        
    Example:
        >>> calculate_average([1, 2, 3, 4])
        2.5
    """
    if not numbers:
        raise ValueError("Cannot compute average of empty list")
    return sum(numbers) / len(numbers)
```
- Follow [PEP 257](https://peps.python.org/pep-0257/) for docstring conventions.
- Accessible via `__doc__` attribute or `help()` function.

## Annotations (Type Hints)
```python
from typing import List, Optional, Union

def process_data(items: List[str], threshold: int = 10) -> List[str]:
    """Filter items longer than threshold."""
    return [item for item in items if len(item) > threshold]

def maybe_process(item: Optional[str]) -> Union[str, None]:
    if item is None:
        return None
    return item.upper()
```
- Annotations are accessible via `__annotations__`.
- Used by static analyzers (mypy, pyright) and IDEs.

## Scope and Namespaces
- **Local scope**: Variables defined inside function.
- **Enclosing scope**: Variables in outer functions (closures).
- **Global scope**: Variables at module level.
- **Built-in scope**: Built-in functions and exceptions.
- Use `global` to modify global variable (rarely needed).
- Use `nonlocal` to modify enclosing scope variable (in nested functions).

## Lambda Functions (Anonymous Functions)
```python
# Simple lambda
double = lambda x: x * 2

# With multiple parameters
add = lambda x, y: x + y

# Used with higher-order functions
numbers = [1, 2, 3, 4, 5]
squared = list(map(lambda x: x**2, numbers))
evens = list(filter(lambda x: x % 2 == 0, numbers))
```
- Limited to single expression.
- Cannot contain statements or annotations.

## Decorators (Function Wrappers)
```python
def timer(func):
    import time, functools
    @functools.wraps(func)
    def wrapper(*args, **kwargs):
        start = time.perf_counter()
        result = func(*args, **kwargs)
        end = time.perf_counter()
        print(f"{func.__name__} took {end-start:.4f} seconds")
        return result
    return wrapper

@timer
def extract_data():
    # ... extraction logic
    pass
```
- Decorators are applied bottom-up.
- Use `functools.wraps` to preserve metadata.

## Generators and Yield
```python
def read_large_file(file_path):
    """Yield lines from a large file without loading everything into memory."""
    with open(file_path, 'r') as f:
        for line in f:
            yield line.strip()

# Usage
for line in read_large_file('huge_log.txt'):
    process(line)
```
- Generators are lazy and memory-efficient.
- Can use `yield from` to delegate to subgenerators.

## Closures
```python
def make_multiplier(factor):
    def multiplier(number):
        return number * factor
    return multiplier

double = make_multiplier(2)
triple = make_multiplier(3)
```
- Inner function remembers the environment where it was created.

## Recursion
```python
def factorial(n):
    if n <= 1:
        return 1
    return n * factorial(n-1)
```
- Be careful of recursion limits (`sys.getrecursionlimit()`).
- Consider iterative solutions for deep recursion.

## Functional Programming Tools
```python
from functools import reduce, partial
from operator import add

# reduce
sum_of_list = reduce(add, [1, 2, 3, 4, 5])

# partial (partial application)
def power(base, exponent):
    return base ** exponent

square = partial(power, exponent=2)
cube = partial(power, exponent=3)
```
- `partial` fixes some arguments of a function.

## Best Practices
1. **Single Responsibility**: Each function should do one thing well.
2. **Descriptive Names**: Use verbs for actions, nouns for data.
3. **Limit Arguments**: Ideally fewer than 5; use objects or dicts for more.
4. **Early Returns**: Handle edge cases early to reduce nesting.
5. **Avoid Side Effects**: Prefer pure functions when possible.
6. **Document**: Use docstrings for public functions.
7. **Type Hints**: Add annotations for better IDE support.
8. **Testing**: Write unit tests for functions with complex logic.

## Common Gotchas
1. **Mutable Default Arguments**: 
   ```python
   # BAD
   def append_to_list(item, my_list=[]):
       my_list.append(item)
       return my_list
   
   # GOOD
   def append_to_list(item, my_list=None):
       if my_list is None:
           my_list = []
       my_list.append(item)
       return my_list
   ```
2. **Closure Variable Capture in Loops**:
   ```python
   # BAD - all functions return 9
   funcs = []
   for i in range(10):
       funcs.append(lambda: i)
   
   # GOOD - use default argument to capture value
   funcs = []
   for i in range(10):
       funcs.append(lambda x=i: x)
   ```
3. **Returning Mutable Objects**: Callers can modify internal state.
4. **Ignoring Return Values**: Functions that return values should generally be used.

## Data Engineering Patterns

### Transformation Functions
```python
def clean_phone_number(phone):
    """Standardize phone number format."""
    if not phone:
        return None
    # Remove non-digits
    digits = ''.join(c for c in phone if c.isdigit())
    # Add country code if missing
    if len(digits) == 10:
        digits = '1' + digits
    return digits
```

### Validation Functions
```python
def validate_email(email):
    """Basic email validation."""
    if not isinstance(email, str):
        return False
    return '@' in email and '.' in email.split('@')[-1]
```

### Configuration Functions
```python
def get_db_config(env):
    """Return database configuration based on environment."""
    configs = {
        'dev': {'host': 'localhost', 'port': 5432},
        'prod': {'host': 'prod-db.example.com', 'port': 5432}
    }
    return configs.get(env, configs['dev'])
```

### Reusable ETL Steps
```python
def extract_csv(file_path, delimiter=',', encoding='utf-8'):
    import csv
    with open(file_path, 'r', encoding=encoding) as f:
        reader = csv.DictReader(f, delimiter=delimiter)
        return list(reader)

def transform_to_dict(data, key_field):
    """Convert list of dicts to dict keyed by key_field."""
    return {item[key_field]: item for item in data if key_field in item}

def load_to_database(records, table_name, connection):
    # Implementation specific to database
    pass
```

## Interview Questions
**Q: What is the difference between `*args` and `**kwargs`?**
A: `*args` collects positional arguments into a tuple. `**kwargs` collects keyword arguments into a dictionary.

**Q: Why is using a mutable default argument dangerous?**
A: The default value is created once at function definition time, so all calls share the same object.

**Q: How do you create a function that accepts both positional and keyword-only arguments?**
A: Use `*` to separate positional-only/positional-or-keyword from keyword-only: `def func(a, b, *, c, d):`

**Q: What is a closure and when is it useful?**
A: A closure is a function that captures variables from its enclosing scope. Useful for creating specialized versions of functions (e.g., multipliers).

**Q: How does a decorator work?**
A: A decorator is a function that takes another function and returns a new function, usually adding functionality before/after the original function runs.

**Q: What is the purpose of `functools.wraps` in a decorator?**
A: It preserves the original function's metadata (name, docstring, annotations) in the wrapper function.