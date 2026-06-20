<!-- python-patterns: Functional Programming with map, filter, reduce -->

# Functional Programming in Python: map, filter, reduce

## Why Functional Programming Matters in Data Engineering

Functional programming concepts help create declarative, side-effect-free data transformations that are easier to test, reason about, and parallelize. In DE pipelines, these patterns enable clean streaming operations and functional composition.

**Core Idea:** Treat data transformations as mathematical functions: input → transformation → output, without mutating state.

---

## map(): Apply Function to Each Element

### Basic Usage
```python
# Transform each element using a function
numbers = [1, 2, 3, 4, 5]
squared = list(map(lambda x: x**2, numbers))
print(squared)  # [1, 4, 9, 16, 25]

# With named function (often clearer)
def convert_to_miles(kilometers):
    return kilometers * 0.621371

distances_km = [10, 25, 50, 100]
distances_miles = list(map(convert_to_miles, distances_km))
```

### When to Use map
- Applying the same transformation to every element in a collection
- Converting units, data types, or formats across a dataset
- Preparing features for machine learning models

### Performance Note
`map()` returns an iterator in Python 3 (lazy evaluation). Use `list()` only when you need all results immediately. For chaining operations, keep it as iterator:
```python
# Memory-efficient chaining for large datasets
processed_data = (
    map(clean_record, raw_data)           # lazy cleaning
    .__mul__(filter(valid_record))        # lazy filtering
    .__mul__(transform_record)            # lazy transformation
)
```

### Gotcha: map Stops at Shortest Iterable
```python
list(map(lambda x, y: x + y, [1, 2, 3], [10, 20]))  # [11, 22] - stops at shortest
```

---

## filter(): Select Elements Based on Condition

### Basic Usage
```python
# Keep only elements that satisfy predicate
numbers = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]
even_numbers = list(filter(lambda x: x % 2 == 0, numbers))
print(even_numbers)  # [2, 4, 6, 8, 10]

# With named function for complex logic
def is_valid_transaction(amount, status):
    return amount > 0 and status in ['completed', 'settled']

valid_transactions = list(
    filter(
        lambda t: is_valid_transaction(t['amount'], t['status']),
        transactions
    )
)
```

### When to Use filter
- Removing invalid or unwanted records from datasets
- Selecting subsets based on business rules
- Pre-aggregation filtering to reduce data volume

### Performance Note
Like `map()`, `filter()` returns an iterator. Chain with `map()` for efficient pipelines:
```python
# Efficient: filter then transform
active_user_purchases = map(
    extract_purchase_amount,
    filter(is_active_user, all_transactions)
)
```

### Gotcha: filter(None, iterable) Removes Falsy Values
```python
list(filter(None, [0, 1, '', 'hello', None, [], [1, 2]]))  # [1, 'hello', [1, 2]]
```
Useful for removing empty strings, None, zeros, empty lists - but be intentional!

---

## reduce(): Cumulative Aggregation (from functools)

### Basic Usage
```python
from functools import reduce

# Sum all elements
numbers = [1, 2, 3, 4, 5]
total = reduce(lambda acc, x: acc + x, numbers, 0)  # 15
# Third argument (0) is initial value

# Find maximum
maximum = reduce(lambda acc, x: acc if acc > x else x, numbers, float('-inf'))

# Concatenate strings with separator
words = ['data', 'engineering', 'pipeline']
sentence = reduce(lambda acc, w: acc + '-' + w if acc else w, words)
```

### When to Use reduce
- Cumulative aggregations: running totals, products, concatenations
- Computing statistics that require sequential processing
- Implementing custom aggregation logic not covered by built-ins

### Performance Note
`reduce()` is often less readable than explicit loops for complex logic. Consider:
```python
# Often clearer than reduce for simple sums
total = sum(numbers)

# For complex logic, explicit loop may be clearer
def calculate_risk_score(factors):
    score = 1.0
    for factor in factors:
        score *= factor['weight'] * factor['value']
    return score
```

### Gotcha: Always Provide Initial Value
```python
# Dangerous: reduce on empty list throws exception
reduce(lambda x, y: x + y, [])  # TypeError: reduce() of empty sequence

# Safe: provide initial value
reduce(lambda x, y: x + y, [], 0)  # Returns 0
```

### Functional Alternative: itertools.accumulate
For running totals without final reduction:
```python
from itertools import accumulate

numbers = [1, 2, 3, 4, 5]
running_total = list(accumulate(numbers, lambda acc, x: acc + x))
# [1, 3, 6, 10, 15]
```

---

## Functional Composition Patterns

### Pipeline Pattern (map → filter → transform)
```python
def process_pipeline(raw_data):
    return (
        map(parse_json_line, raw_data)           # Step 1: Parse
        .__mul__(filter(is_valid_record, _))     # Step 2: Filter
        .__mul__(normalize_fields, _)            # Step 3: Transform
        .__mul__(enrich_with_lookup, _)          # Step 4: Enrich
    )
```

### Advantages of Functional Approach
1. **Testability**: Each function is pure and testable in isolation
2. **Reusability**: Transform functions can be reused across pipelines
3. **Debugging**: Easy to insert inspection points between steps
4. **Parallelization**: Pure functions can be mapped across processes

### When to Prefer Loops Over Functional
- Complex stateful logic requiring multiple variables
- Early termination conditions (break/continue)
- When performance profiling shows function call overhead is significant
- When working with very large datasets where intermediate iterators cause overhead

## Interview Angles for DE Roles

**Common Questions:**
1. "How would you rewrite this for-loop using map/filter?"
2. "What's the difference between map() and list comprehension?"
3. "When would you use reduce() vs a simple loop?"
4. "How do you handle errors in functional pipelines?"
5. "Explain lazy evaluation in Python 3 map/filter."

**Key Points to Mention:**
- Functional patterns reduce mutable state and side effects
- Lazy evaluation saves memory for large datasets
- Comprehensions are often more Pythonic than map/filter for simple cases
- reduce() should be used sparingly; prefer built-in aggregates (sum, max, etc.) when available
- Toolz or functools libraries provide additional functional utilities

## Best Practices
1. Prefer list/dict comprehensions for simple transformations
2. Use map/filter when applying existing functions (avoid lambda when possible)
3. Always provide initial value to reduce()
4. Chain map/filter operations for lazy evaluation benefits
5. Consider toolz or itertools for advanced functional patterns
6. Document complex lambda functions - extract to named functions when logic >1 line