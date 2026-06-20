<!-- python-patterns: Lambda Functions -->

# Lambda Functions in Python

## Why Lambda Functions Matter in Data Engineering

Lambda functions (anonymous functions) enable concise inline transformations in DE pipelines, particularly useful with map(), filter(), sorted(), and other higher-order functions. They reduce boilerplate for simple operations but can hurt readability when overused.

**Core Idea:** Create small, throwaway functions without formal definition: `lambda arguments: expression`

---

## Basic Syntax and Usage

### Simple Lambda
```python
# Instead of:
def square(x):
    return x**2

# Use lambda:
square = lambda x: x**2
print(square(5))  # 25
```

### In map/filter/sorted
```python
numbers = [1, 2, 3, 4, 5]

# map with lambda
squared = list(map(lambda x: x**2, numbers))

# filter with lambda
evens = list(filter(lambda x: x % 2 == 0, numbers))

# sorted with lambda (sort by second tuple element)
pairs = [(1, 'apple'), (3, 'banana'), (2, 'cherry')]
sorted_by_fruit = sorted(pairs, key=lambda x: x[1])
```

### Multi-line Logic (Avoid!)
```python
# DON'T do this - hard to read and debug
complex_op = lambda x: (x * 2 if x > 10 else x // 2) + 5 if x % 2 == 0 else x - 3

# DO this instead - extract to named function
def complex_operation(x):
    if x % 2 == 0:
        return (x * 2 if x > 10 else x // 2) + 5
    else:
        return x - 3
```

---

## When to Use Lambda Functions

### Appropriate Uses
1. **Simple, one-line transformations**
   ```python
   # Clear and concise
   lengths = list(map(lambda s: len(s), strings))
   ```

2. **Passing simple functions to higher-order functions**
   ```python
   # Common in sorting and grouping
   events.sort(key=lambda e: e.timestamp)
   grouped = itertools.groupby(data, key=lambda x: x.category)
   ```

3. **Creating callback functions for frameworks**
   ```python
   # In testing or configuration
   mock.side_effect = lambda x: process_input(x)
   scheduler.add_job(lambda: cleanup_task(), interval='1hour')
   ```

4. **Temporary functions in interactive work/Jupyter notebooks**
   ```python
   # Quick exploration
   df['category'] = df['value'].apply(lambda x: 'high' if x > 100 else 'low')
   ```

### When NOT to Use Lambda
1. **Complex logic (>1 line)**
   ```python
   # BAD: hurts readability
   discount = lambda price, customer_type, loyalty_points: \
       price * 0.9 if customer_type == 'premium' else \
       price * 0.95 if loyalty_points > 1000 else price
   
   # GOOD: clear, testable, reusable
   def calculate_discount(price, customer_type, loyalty_points):
       if customer_type == 'premium':
           return price * 0.9
       elif loyalty_points > 1000:
           return price * 0.95
       else:
           return price
   ```

2. **When you need a docstring**
   ```python
   # BAD: no way to document
   process = lambda data: # complex operation
   
   # GOOD: self-documenting
   def process_data(data):
       """
       Clean and validate incoming data.
       
       Steps:
       1. Remove records with missing IDs
       2. Validate email format
       3. Normalize timestamps to UTC
       4. Flag potential duplicates
       """
       # implementation
   ```

3. **When reused multiple times**
   ```python
   # BAD: recreates same function each time
   records = [clean_record(r, lambda x: x.strip()) for r in raw]
   
   # GOOD: define once, reuse
   strip_whitespace = lambda x: x.strip()
   records = [clean_record(r, strip_whitespace) for r in raw]
   
   # BETTER: named function
   def strip_whitespace(s):
       return s.strip()
   ```

4. **In exception handling (reduces clarity)**
   ```python
   # BAD: hides intent
   try:
       process_data()
   except Exception as e:
       logger.error(lambda: f"Failed: {e}")  # Creates lambda unnecessarily
   
   # GOOD: direct string or proper logging
   try:
       process_data()
   except Exception as e:
       logger.error("Failed: %s", e)
   ```

---

## Common Lambda Patterns in DE

### 1. Field Extraction/Transformation
```python
# Extract nested field
user_ids = list(map(lambda x: x['user']['id'], api_response))

# Convert timestamp
timestamps = list(map(lambda ts: int(ts.timestamp()), datetime_objects))

# Normalize text
cleaned = list(map(lambda s: s.strip().lower(), raw_strings))
```

### 2. Filtering Conditions
```python
# Filter by date range
recent = list(filter(
    lambda x: start_date <= x['timestamp'] <= end_date,
    events
))

# Filter by multiple conditions
valid = list(filter(
    lambda r: r['amount'] > 0 and 
              r['currency'] in ['USD', 'EUR', 'GBP'] and
              r['status'] != 'cancelled',
    transactions
))
```

### 3. Sorting and Ordering
```python
# Sort by multiple fields
sorted_orders = sorted(orders, key=lambda o: (o['priority'], o['timestamp']))

# Sort by computed value
sorted_by_value = sorted(items, key=lambda i: i['price'] * i['quantity'])

# Reverse alphabetical, case-insensitive
sorted_names = sorted(names, key=lambda s: s.lower(), reverse=True)
```

### 4. Grouping Keys
```python
# Group by month
from itertools import groupby
by_month = groupby(sorted_events, key=lambda e: e.timestamp.month)

# Group by composite key
by_region_and_type = groupby(
    sorted_data,
    key=lambda x: (x['region'], x['event_type'])
)
```

### 5. Reducing/Aggregating
```python
from functools import reduce

# Calculate total with filter
total_sales = reduce(
    lambda acc, t: acc + t['amount'] if t['status'] == 'completed' else acc,
    transactions,
    0
)

# Find most frequent item
from collections import Counter
most_common = reduce(
    lambda acc, x: acc if acc[1] > Counter([acc[0], x])[x] else x,
    items,
    (items[0], 1)
)  # Note: This is convoluted - usually Counter.most_common(1) is better
```

---

## Gotchas and Pitfalls

### 1. Late Binding in Closures
```python
# BAD: All lambdas reference the same variable 'i'
functions = [lambda: i for i in range(5)]
print([f() for f in functions])  # [4, 4, 4, 4, 4] - all return 4!

# GOOD: Capture current value with default argument
functions = [lambda i=i: i for i in range(5)]
print([f() for f in functions])  # [0, 1, 2, 3, 4]

# Alternative: use functools.partial
from functools import partial
functions = [partial(lambda i: i, i) for i in range(5)]
```

### 2. Lambda vs def Performance
```python
# Negligible difference for simple cases
import timeit

# Lambda
lambda_time = timeit.timeit(
    lambda: list(map(lambda x: x**2, range(1000))),
    number=10000
)

# Named function
def square(x):
    return x**2

def_time = timeit.timeit(
    lambda: list(map(square, range(1000))),
    number=10000
)

# lambda_time ≈ def_time (difference is in function creation, not execution)
```

### 3. Debugging Difficulties
```python
# BAD: Hard to trace - lambda shows as <lambda> in traceback
process = lambda x: complex_operation(x)  # If complex_operation fails...

# GOOD: Named function shows in traceback
def process(x):
    return complex_operation(x)
```

### 4. Overly Complex Lambdas
```python
# BAD: Violates "simple transformation" principle
transform = lambda x: (
    x.upper() if len(x) > 5 else
    x.lower() if x.isdigit() else
    x.title() if x[0].islower() else
    x
)

# GOOD: Clear, testable steps
def transform_string(s):
    if len(s) > 5:
        return s.upper()
    elif s.isdigit():
        return s.lower()
    elif s[0].islower():
        return s.title()
    else:
        return s
```

### 5. Lambda in Class Definitions
```python
# BAD: Shared lambda across all instances (class attribute)
class Processor:
    transform = lambda self, x: x * self.factor  # self is first arg!
    
# GOOD: Proper method
class Processor:
    def __init__(self, factor):
        self.factor = factor
    
    def transform(self, x):
        return x * self.factor

# ALTERNATIVE: If you need configurable strategy
class Processor:
    def __init__(self, transform_func):
        self.transform = transform_func

# Usage:
processor = Processor(lambda x: x * 2)  # Lambda as strategy
```

---

## Best Practices for DE Pipelines

1. **Keep lambdas to one line** - if it needs multiple lines, use def
2. **Prefer named functions for reusable logic** - testability and documentation
3. **Use lambdas only with higher-order functions** (map, filter, sorted, etc.)
4. **Capture loop variables correctly** - use default arguments to avoid late binding
5. **Consider operator module** for common operations:
   ```python
   import operator
   
   # Instead of lambda x, y: x + y
   total = reduce(operator.add, numbers, 0)
   
   # Instead of lambda x: x['value']
   values = list(map(operator.itemgetter('value'), records))
   
   # Instead of lambda x: x.name
   names = list(map(attrgetter('name'), objects))
   ```
6. **Name complex lambdas** when used multiple times:
   ```python
   # BAD: repeated complex lambda
   data1 = list(map(lambda x: x['nested']['value'] * 2, dataset1))
   data2 = list(map(lambda x: x['nested']['value'] * 2, dataset2))
   
   # GOOD: named lambda
   extract_and_double = lambda x: x['nested']['value'] * 2
   data1 = list(map(extract_and_double, dataset1))
   data2 = list(map(extract_and_double, dataset2))
   
   # BETTER: named function
   def extract_and_double_value(record):
       return record['nested']['value'] * 2
   ```
7. **Avoid lambda in exception handling** - it adds unnecessary complexity
8. **Use lambda sparingly in production code** - favor explicit functions for maintainability
9. **Remember lambdas cannot contain statements** - only expressions (no try/except, loops, etc.)
10. **When debugging fails**, temporarily replace lambda with named function to get better traceback

## Interview Angles for DE Roles

**Common Questions:**
1. "What's wrong with `[lambda: i for i in range(5)]` and how do you fix it?"
2. "When would you prefer a lambda over a list comprehension?"
3. "How do you debug a lambda function in a pipeline?"
4. "What are the limitations of lambda functions in Python?"
5. "Show me how to use lambda with sorted() to sort by multiple criteria."

**Key Points to Mention:**
- Lambdas are expressions, not statements - limited to single expression
- Late binding closure issue is a common gotcha
- Lambdas excel at simple transformations in functional pipelines
- Readability often suffers with complex lambdas - named functions preferred for reuse
- Toolbox functions (operator.itemgetter, attrgetter) often clearer than lambda
- In DE, lambdas are most useful for ad-hoc transformations in exploratory work

## Alternatives to Consider

### 1. List/Dict Comprehensions
```python
# Often clearer than map/filter with lambda
squared = [x**2 for x in numbers]
evens = [x for x in numbers if x % 2 == 0]
```

### 2. functools.partial
```python
from functools import partial

# Instead of lambda x: multiply(x, factor)
multiply_by_factor = partial(multiply, factor=2)

# Instead of lambda x, y: x.get(y, default)
get_with_default = partial(dict.get, default='N/A')
```

### 3. operator module
```python
import operator

# Instead of lambda x, y: x + y
total = reduce(operator.add, numbers)

# Instead of lambda x: x['field']
values = list(map(operator.itemgetter('field'), records))
```

### 4. Named Functions
```python
# Always an option - often clearer
def get_timestamp(record):
    return record['metadata']['timestamp']

timestamps = list(map(get_timestamp, records))
```

## Performance Notes
- Lambda creation has tiny overhead (function object creation)
- Execution speed is identical to named functions
- Memory overhead: one function object per lambda vs shared named function
- In tight loops with thousands of lambda creations, consider named function
- For most DE pipelines, lambda overhead is negligible compared to I/O/network