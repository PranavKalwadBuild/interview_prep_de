<!-- python-patterns: Performance Patterns -->

# Performance Patterns

## Profiling — Measure Before Optimizing

```python
# cProfile — find where time is spent
import cProfile, pstats

profiler = cProfile.Profile()
profiler.enable()
run_pipeline()
profiler.disable()

stats = pstats.Stats(profiler)
stats.sort_stats("cumulative")
stats.print_stats(20)   # top 20 functions by cumulative time

# Line profiler (pip install line-profiler) — per-line timing
# @profile decorator added by line_profiler; run with: kernprof -l -v script.py

# timeit — micro-benchmark
import timeit
timeit.timeit("','.join(str(n) for n in range(100))", number=10_000)

# Quick comparison
from timeit import timeit
t1 = timeit(lambda: [x**2 for x in range(1000)], number=1000)
t2 = timeit(lambda: list(map(lambda x: x**2, range(1000))), number=1000)
print(f"List comp: {t1:.4f}s, map: {t2:.4f}s")
```

---

## Memory Profiling

```python
# tracemalloc — built-in memory allocation tracing
import tracemalloc

tracemalloc.start()
run_heavy_operation()
current, peak = tracemalloc.get_traced_memory()
tracemalloc.stop()
print(f"Peak memory: {peak / 1e6:.1f} MB")

# Snapshot comparison — find what's growing
snapshot1 = tracemalloc.take_snapshot()
run_something()
snapshot2 = tracemalloc.take_snapshot()

top_stats = snapshot2.compare_to(snapshot1, "lineno")
for stat in top_stats[:10]:
    print(stat)

# sys.getsizeof — size of a single object (shallow)
import sys
sys.getsizeof([1, 2, 3])      # 120 bytes — just the list object, not element sizes
sys.getsizeof("hello world")  # includes string data

# Deep object size (recursive)
def deep_size(obj, seen=None):
    size = sys.getsizeof(obj)
    if seen is None:
        seen = set()
    obj_id = id(obj)
    if obj_id in seen:
        return 0
    seen.add(obj_id)
    if isinstance(obj, dict):
        size += sum(deep_size(k, seen) + deep_size(v, seen) for k, v in obj.items())
    elif hasattr(obj, "__dict__"):
        size += deep_size(obj.__dict__, seen)
    elif hasattr(obj, "__iter__") and not isinstance(obj, (str, bytes)):
        size += sum(deep_size(i, seen) for i in obj)
    return size
```

---

## String Building — The Classic Interview Trap

```python
# BAD — O(n²) — each += creates a new string
result = ""
for record in records:
    result += f"{record['id']},{record['name']}\n"

# GOOD — O(n) — build list, join once
parts = []
for record in records:
    parts.append(f"{record['id']},{record['name']}")
result = "\n".join(parts)

# Best — generator expression into join
result = "\n".join(f"{r['id']},{r['name']}" for r in records)
```

---

## Loop Optimization

```python
# Avoid repeated attribute lookup in hot loops
import math

# BAD — looks up math.sqrt on every iteration
for x in big_list:
    result = math.sqrt(x)

# GOOD — bind to local variable (faster name lookup)
sqrt = math.sqrt
for x in big_list:
    result = sqrt(x)

# Avoid method calls in loops
# BAD
for item in items:
    results.append(item.value)   # append looked up each iteration

# GOOD — bind method
append = results.append
for item in items:
    append(item.value)

# Use built-ins over manual loops
# BAD
total = 0
for x in numbers:
    total += x

# GOOD — built-in runs in C
total = sum(numbers)

# map/filter — sometimes faster for simple transforms
squares = list(map(lambda x: x**2, numbers))
positives = list(filter(lambda x: x > 0, numbers))
```

---

## `__slots__` — Memory for Many Small Objects

```python
import sys

class RegularRow:
    def __init__(self, id, name, amount):
        self.id = id
        self.name = name
        self.amount = amount

class SlottedRow:
    __slots__ = ("id", "name", "amount")   # no __dict__

    def __init__(self, id, name, amount):
        self.id = id
        self.name = name
        self.amount = amount

# Memory comparison
r = RegularRow(1, "alice", 99.5)
s = SlottedRow(1, "alice", 99.5)

sys.getsizeof(r.__dict__)  # ~232 bytes per instance
# SlottedRow has no __dict__ — ~40-50% smaller

# For 1M row objects: slots can save ~100MB+
rows = [SlottedRow(i, f"name_{i}", i * 1.5) for i in range(1_000_000)]

# Tradeoffs:
# - Cannot add arbitrary attributes
# - Cannot use __weakref__ unless explicitly added to __slots__
# - Inheritance with __slots__ is tricky (parent must also use slots)
```

---

## Generator vs List — Memory Trade-offs

```python
# List — all data in memory at once, O(n) memory, O(1) repeated access
data = [transform(x) for x in raw]
len(data)      # works
data[5]        # works
data[5]        # works again — data still in memory

# Generator — one item at a time, O(1) memory, single pass only
data = (transform(x) for x in raw)
# len(data)   # TypeError — no len
# data[5]     # TypeError — no indexing
for item in data:  # consumes generator
    process(item)
for item in data:  # EMPTY — exhausted

# When to use each:
# Generator: streaming large data, feeding to a loop, writing to file/DB, composition
# List: multiple passes needed, random access, passing to functions expecting sequences
```

---

## Caching — `functools.lru_cache`

```python
import functools

@functools.lru_cache(maxsize=512)
def get_table_schema(table_name: str) -> dict:
    """Expensive DB call — cache results."""
    return fetch_from_catalog(table_name)

# All args must be hashable
# Returns same object for same args (not a copy — don't mutate!)
schema = get_table_schema("orders")  # DB call
schema = get_table_schema("orders")  # cache hit — no DB call

# Cache info
get_table_schema.cache_info()
# CacheInfo(hits=10, misses=2, maxsize=512, currsize=2)

# Clear cache
get_table_schema.cache_clear()

# Python 3.9+ — unbounded cache
@functools.cache
def get_region_mapping(region_code: str) -> str:
    ...

# TTL cache (lru_cache doesn't expire — use cachetools for TTL)
from cachetools import TTLCache, cached

schema_cache = TTLCache(maxsize=100, ttl=300)   # expires after 5 minutes

@cached(cache=schema_cache)
def get_fresh_schema(table: str) -> dict:
    return fetch_from_catalog(table)
```

---

## Vectorization vs Python Loops — Real Comparison

```python
import numpy as np, time

data = list(range(1_000_000))

# Python loop
start = time.perf_counter()
result = [x**2 for x in data]
python_time = time.perf_counter() - start

# NumPy vectorized
arr = np.array(data)
start = time.perf_counter()
result = arr**2
numpy_time = time.perf_counter() - start

print(f"Python: {python_time:.3f}s")   # ~0.15s
print(f"NumPy:  {numpy_time:.4f}s")   # ~0.003s  — 50x faster
```

---

## Common Performance Anti-Patterns in DE

```python
# 1. Loading entire file into memory when streaming would work
df = pd.read_csv("50gb_file.csv")   # OOM

# 2. Using df.iterrows() for transforms
for idx, row in df.iterrows():   # Python loop — 1000x slower than vectorized
    df.at[idx, "total"] = row["qty"] * row["price"]

# 3. Repeated DataFrame creation in a loop
dfs = []
for file in files:
    dfs.append(pd.read_csv(file))
    result = pd.concat(dfs)   # WRONG — concat inside loop → O(n²) copies

# Fix: concat once at the end
dfs = [pd.read_csv(file) for file in files]
result = pd.concat(dfs, ignore_index=True)

# 4. String concatenation in loops (see string building section)

# 5. Unneeded .copy() on large DataFrames
def bad_transform(df):
    df = df.copy()   # unnecessary if you're not mutating the input
    df["x"] = df["a"] + df["b"]   # pandas copy-on-write (pandas 2.0) handles this
    return df

# 6. .apply() on large DataFrames when vectorization is possible
```

---

## Interview Questions

**Q: How do you identify what's slow in a Python script?**
Use `cProfile` to find which functions consume the most time. Then `line_profiler` to drill into specific functions. Measure before and after any optimization.

**Q: String concatenation in a loop — what's wrong and how do you fix it?**
Each `str +=` creates a new string object, copying all previous content — O(n²) total. Fix: collect parts in a list, then `"".join(parts)` — O(n).

**Q: When should you use `__slots__`?**
When creating millions of instances of a small class. Eliminates `__dict__` per instance (~40-50% memory savings). Trade-off: no dynamic attribute assignment, harder with inheritance.

**Q: `lru_cache` — what breaks it?**
Mutable arguments (lists, dicts) — they're not hashable and will raise `TypeError`. The cache stores references not copies — mutating the returned object corrupts the cache. No TTL — stale data for long-running processes (use `cachetools.TTLCache`).

**Q: You have a function called 1M times in a pipeline. What quick optimizations do you consider?**
1. Can the result be cached? (`lru_cache` if args are hashable)
2. Can the loop be vectorized with NumPy/pandas?
3. Is the function I/O bound? (parallelize with ThreadPoolExecutor)
4. Are there repeated attribute/method lookups that can be bound to locals?
5. Can you batch calls instead of per-item calls?
