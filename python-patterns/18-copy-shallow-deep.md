<!-- python-patterns: Shallow Copy vs Deep Copy -->

# Shallow Copy vs Deep Copy in Python

## Why Copying Matters in Data Engineering

In DE pipelines, we frequently copy data structures to avoid unintended mutations when processing records, creating backups, or preparing data for different transformations. Understanding the difference between shallow and deep copy is critical to prevent subtle bugs where nested objects are unexpectedly shared.

**Core Problem:** Assignment (`b = a`) doesn't copy - it creates a reference to the same object. Mutating `b` affects `a`.

---

## Shallow Copy

### What It Copies
Shallow copy creates a new collection object but populates it with references to the original elements. Nested objects are shared between copy and original.

### How to Create
```python
import copy

# Method 1: copy.copy()
shallow = copy.copy(original)

# Method 2: For lists - slicing or list()
shallow = original[:]      # works for lists only
shallow = list(original)   # works for any iterable

# Method 3: For dicts - dict() or .copy()
shallow = dict(original)
shallow = original.copy()
```

### Example: List of Lists
```python
original = [[1, 2], [3, 4], [5, 6]]
shallow = copy.copy(original)

# Modifying outer list - safe
shallow.append([7, 8])
print(original)  # [[1, 2], [3, 4], [5, 6]] - unchanged

# Modifying inner list - affects both!
shallow[0][0] = 999
print(original)  # [[999, 2], [3, 4], [5, 6]] - original changed!
print(shallow)   # [[999, 2], [3, 4], [5, 6]]
```

### When Shallow Copy Is Sufficient
- Flat lists of immutable values (numbers, strings, tuples)
- When you only need to modify the top-level structure
- Creating independent lists/where nested objects are read-only
- Performance-critical situations (shallow copy is faster)

### Performance
Shallow copy is O(n) where n is the number of top-level elements - it doesn't recursively copy nested objects.

---

## Deep Copy

### What It Copies
Deep copy creates a completely independent copy of the original object and all objects it references, recursively. No sharing occurs.

### How to Create
```python
import copy

deep = copy.deepcopy(original)
```

### Example: Same Nested List
```python
original = [[1, 2], [3, 4], [5, 6]]
deep = copy.deepcopy(original)

# Modifying inner list - safe
deep[0][0] = 999
print(original)  # [[1, 2], [3, 4], [5, 6]] - unchanged
print(deep)      # [[999, 2], [3, 4], [5, 6]]
```

### When Deep Copy Is Necessary
- Nested mutable objects that will be modified independently
- Complex data structures (trees, graphs, mixed-type containers)
- When you need true isolation between original and copy
- Preparing data for multiple concurrent transformations

### Performance Considerations
Deep copy can be slow and memory-intensive:
- O(n) where n is total number of objects in the entire structure
- May hit recursion limits for very deep structures
- Duplicates all data - potentially doubling memory usage
- Cannot copy certain objects (file handles, sockets, database connections)

### Gotchas with deepcopy
```python
# Cannot copy some objects
import socket
s = socket.socket()
copy.deepcopy(s)  # TypeError: cannot pickle 'socket.socket' object

# Custom __deepcopy__ method needed for complex objects
class DatabaseConnection:
    def __deepcopy__(self, memo):
        # Return new connection instead of copying
        return DatabaseConnection(self.host, self.port)

# Circular references handled automatically (unlike pickle)
class Node:
    def __init__(self, value):
        self.value = value
        self.next = None

a = Node(1)
b = Node(2)
a.next = b
b.next = a  # circular reference

copy.deepcopy(a)  # Works fine!
```

---

## Practical DE Examples

### Scenario 1: Processing Records with Nested Fields
```python
# BAD: shared references cause corruption
def process_records_v1(records):
    processed = []  # Want to collect modified records
    for record in records:
        new_record = record  # SHALLOW COPY - same object!
        new_record['processed'] = True
        new_record['timestamp'] = now()
        processed.append(new_record)
    return processed  # All records point to same mutated object!

# GOOD: shallow copy for flat records
def process_records_v2(records):
    processed = []
    for record in records:
        new_record = record.copy()  # shallow copy - sufficient if no nested mutables
        new_record['processed'] = True
        new_record['timestamp'] = now()
        processed.append(new_record)
    return processed

# BETTER: if records have nested mutable fields
def process_records_v3(records):
    processed = []
    for record in records:
        new_record = copy.deepcopy(record)  # safe but slower
        new_record['processed'] = True
        new_record['timestamp'] = now()
        processed.append(new_record)
    return processed
```

### Scenario 2: Configuration Templates
```python
# Template for pipeline configurations
BASE_CONFIG = {
    'retries': 3,
    'timeout': 30,
    'filters': ['remove_nulls', 'dedupe'],
    'destinations': ['s3://bucket/path/']  # mutable list!
}

# BAD: all pipelines share same destinations list
def create_pipeline_config_v1(overrides):
    config = BASE_CONFIG  # Reference!
    config.update(overrides)
    return config

# GOOD: shallow copy of top-level dict
def create_pipeline_config_v2(overrides):
    config = BASE_CONFIG.copy()  # shallow copy
    config.update(overrides)
    return config

# BETTER: if overrides might modify nested lists
def create_pipeline_config_v3(overrides):
    config = copy.deepcopy(BASE_CONFIG)  # safe but overkill for simple case
    config.update(overrides)
    return config
```

### Scenario 3: Batch Processing with Snapshots
```python
def take_snapshot(data_batch):
    """Create isolated copy for audit/recovery"""
    # Depends on data structure:
    # - List of dicts with immutable values: .copy() or list() is sufficient
    # - Dicts with nested lists/dicts: need deepcopy
    # - Mixed or unknown structure: deepcopy is safest
    
    return copy.deepcopy(data_batch)  # Safe choice when unsure
```

---

## Performance Comparison
```python
import timeit
import copy

# Test data: list of 1000 dicts, each with 5 nested lists
data = [[{'values': [i]*10} for _ in range(5)] for i in range(1000)]

# Timing (approximate)
shallow_time = timeit.timeit(lambda: [d.copy() for d in data], number=100)
deep_time = timeit.timeit(lambda: copy.deepcopy(data), number=100)

# shallow_time << deep_time (often 10-100x faster)
```

## Decision Framework

```
Do you need to modify nested objects?
    ↓
NO → Shallow copy (.copy(), [:], list(), dict())
     │
     ├── Flat structure? → Use type-specific copy (fastest)
     └── Nested but immutable? → Shallow copy is safe
YES → 
    ↓
Are nested objects large or numerous?
    ↓
NO → Deep copy (copy.deepcopy)
     │
     ├── Simple structure? → Consider manual reconstruction
     └── Performance critical? → Profile both approaches
YES →
    ↓
Can you avoid copying entirely?
    ↓
YES → Restructure to use immutable data or functional transformations
      (tuples, frozenset, namedtuple, dataclass(frozen=True))
    NO → Deep copy with performance monitoring
```

## Special Cases

### 1. Copying pandas DataFrames
```python
import pandas as pd

df = pd.DataFrame({'A': [1, 2, 3], 'B': [4, 5, 6]})

# Shallow copy (same underlying data)
df_copy = df.copy(deep=False)

# Deep copy (independent data)
df_deep = df.copy(deep=True)  # default is deep=True

# Gotcha: shallow copy still shares index/columns objects
```

### 2. Copying numpy arrays
```python
import numpy as np

arr = np.array([1, 2, 3, 4, 5])

# Shallow copy (view)
arr_view = arr.view()
arr_view[0] = 999  # modifies original!

# Deep copy
arr_copy = arr.copy()
arr_copy[0] = 888  # safe - independent copy
```

### 3. Copying sets and frozensets
```python
# Sets are mutable but contain only immutables
original = {1, 2, 3, [4, 5]}  # ERROR: unhashable type: 'list'
correct = {1, 2, 3, frozenset([4, 5])}

shallow = correct.copy()  # Actually deep for frozenset elements
# But: if elements were mutable custom objects, would be shallow
```

## Interview Angles for DE Roles

**Common Questions:**
1. "What happens when you modify a nested list in a copied list?"
2. "How would you copy a list of dictionaries safely?"
3. "When would deepcopy cause problems in a data pipeline?"
4. "What's the difference between assignment, shallow copy, and deep copy?"
5. "How do you copy a pandas DataFrame without sharing data?"

**Key Points to Mention:**
- Assignment creates references, not copies
- Shallow copy duplicates top-level container, shares nested objects
- Deep copy creates fully independent copy (use with caution on performance)
- Always consider if copying is necessary - sometimes immutable data structures are better
- Performance implications matter in DE with large datasets

## Best Practices
1. **Default to shallow copy** unless you know nested objects will be modified
2. **Use Type-specific methods**: `.copy()` for dict/list, `list()` for iterables, `.view()`/`copy()` for numpy
3. **Profile deepcopy usage** in production pipelines - it can be a hidden bottleneck
4. **Consider immutable alternatives**: tuples, frozenset, dataclass(frozen=True) when appropriate
5. **Always test copy behavior** with nested mutable structures
6. **Document assumptions** about data structure mutability in your code
7. **For complex objects**, implement `__copy__` and `__deepcopy__` methods
8. **When in doubt, start with deepcopy** then optimize to shallow copy after profiling