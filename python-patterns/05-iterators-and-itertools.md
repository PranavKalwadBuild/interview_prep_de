<!-- python-patterns: Iterators and itertools -->

# Iterators and itertools

---

## Understanding Iterators: The Protocol

### The Problem: Customizing Loop Behavior

```python
# How does for loop know how to iterate?
for item in [1, 2, 3]:
    print(item)

# For strings?
for char in "hello":
    print(char)

# For dicts?
for key in {"a": 1, "b": 2}:
    print(key)

# How does Python know how to loop over these different types?
```

The answer: The **Iterator Protocol** — a standardized interface that tells Python how to iterate.

### The Mental Model: Two Roles

**Iterable** — Something you can loop over. Asks: "Give me an iterator."

**Iterator** — The actual looper. Asks: "What's the next item?"

Think of it like a book and a bookstore:
- Bookstore (iterable): "Come to me, I'll give you a bookmark"
- Bookmark (iterator): "Here's my current position, I can tell you the next page"

---

## Iterator Protocol Explained

### Iterable: `__iter__()`

An **iterable** must have `__iter__()` method that returns an iterator:

```python
class DateRange:
    """Iterable: represents a range of dates."""
    
    def __init__(self, start_date, end_date):
        self.start_date = start_date
        self.end_date = end_date
    
    def __iter__(self):
        """Return an iterator."""
        return DateRangeIterator(self.start_date, self.end_date)

# DateRange is iterable because it has __iter__
```

### Iterator: `__next__()`

An **iterator** must have:
- `__iter__()` — returns itself
- `__next__()` — returns next item, raises `StopIteration` when exhausted

```python
class DateRangeIterator:
    """Iterator: tracks current position and moves through dates."""
    
    def __init__(self, start_date, end_date):
        self.current = start_date
        self.end = end_date
    
    def __iter__(self):
        """Iterators return themselves."""
        return self
    
    def __next__(self):
        """Return next item, or raise StopIteration when done."""
        if self.current >= self.end:
            raise StopIteration  # Signal that iteration is complete
        
        result = self.current
        self.current += timedelta(days=1)  # Move to next date
        return result

# Usage:
date_range = DateRange(date(2024, 1, 1), date(2024, 1, 5))

for day in date_range:
    print(day)

# Manual iteration (what for loop does internally)
it = iter(date_range)      # Calls __iter__, gets iterator
print(next(it))            # Calls __next__
print(next(it))            # Calls __next__
# ... keep calling next() until StopIteration is raised
```

### What the For Loop Does

```python
for item in iterable:
    # do something

# Is equivalent to:

it = iter(iterable)          # Step 1: Get iterator by calling __iter__()
while True:
    try:
        item = next(it)      # Step 2: Get next item by calling __next__()
    except StopIteration:
        break                # Step 3: Exit when iterator raises StopIteration
    # do something
```

---

## Iterable vs Iterator — Critical Distinction

| Aspect | Iterable | Iterator |
|---|---|---|
| Has `__iter__` | **Yes** | Yes |
| Has `__next__` | No | **Yes** |
| Can iterate multiple times | **Yes** — gets fresh iterator each time | No — exhausts after one pass |
| Example | list, dict, string, generator function | generator, zip, map, file object |

```python
# List is iterable, NOT iterator
lst = [1, 2, 3]
it1 = iter(lst)              # Get new iterator
it2 = iter(lst)              # Get ANOTHER new iterator
next(it1)                    # 1
next(it2)                    # 1 — independent!

# Generator is BOTH iterable AND iterator
def gen():
    yield 1
    yield 2

g = gen()
it = iter(g)                 # iter on a generator returns itself
next(g)                      # 1
next(it)                     # 2 — same object!

# File is an iterator
f = open("file.txt")
iter(f) is f                 # True — returns itself
next(f)                      # Can't call next a second time on fresh file
```

---

## `iter()` with Sentinel Pattern

Reading chunks from a file is a common pattern. `iter(callable, sentinel)` calls the callable repeatedly until it returns the sentinel value.

```python
import functools

def read_file_chunks(filepath, chunk_size=4096):
    """
    Read a file in chunks without loading entire file.
    Uses sentinel pattern: stop when read() returns empty bytes.
    """
    with open(filepath, "rb") as f:
        # functools.partial creates a callable that reads chunk_size bytes
        reader = functools.partial(f.read, chunk_size)
        
        # iter(reader, b"") → calls reader() until it returns b"" (empty)
        for chunk in iter(reader, b""):
            yield chunk

# Usage: Process 100GB file in 1MB chunks
total_bytes = 0
for chunk in read_file_chunks("huge_file.bin", chunk_size=1_000_000):
    total_bytes += len(chunk)  # Process chunk
print(f"Total: {total_bytes} bytes")

# How it works:
# 1. reader = partial(f.read, 4096)
# 2. iter(reader, b"") returns iterator
# 3. For each iteration, iterator calls reader() → f.read(4096)
# 4. If f.read(4096) returns b"" (EOF), iterator stops
# 5. Otherwise, yields the chunk
```

---

## `itertools` — Comprehensive Reference for Data Engineering

### Creating Iterators

```python
import itertools

# count(start, step) — infinite sequence
for i in itertools.count(1, 2):  # 1, 3, 5, 7, ...
    if i > 10:
        break

# cycle(iterable) — cycle through iterable forever
pattern = itertools.cycle(["r", "w", "b"])
colors = [next(pattern) for _ in range(5)]  # ["r", "w", "b", "r", "w"]

# repeat(value, times) — repeat a value N times
list(itertools.repeat("x", 3))  # ["x", "x", "x"]
```

### Combining/Chaining

```python
# chain(*iterables) — concatenate iterables
list(itertools.chain([1, 2], [3, 4], [5]))      # [1, 2, 3, 4, 5]

# chain.from_iterable(iterable_of_iterables) — flatten one level
list(itertools.chain.from_iterable([[1, 2], [3, 4]]))  # [1, 2, 3, 4]

# Real DE scenario: process multiple log files in sequence
def process_all_logs(log_files):
    """Read all log files as one continuous stream."""
    log_iterators = (open(f) for f in log_files)  # Generator of open files
    for line in itertools.chain.from_iterable(log_iterators):
        yield line.strip()  # Lazy iteration through all files
```

### Filtering/Selecting

```python
# takewhile(predicate, iterable) — yield while predicate is true
list(itertools.takewhile(lambda x: x < 5, [1, 2, 3, 4, 5, 1]))  # [1, 2, 3, 4]

# dropwhile(predicate, iterable) — skip while predicate is true
list(itertools.dropwhile(lambda x: x < 5, [1, 2, 3, 4, 5, 1]))  # [5, 1]

# filterfalse(predicate, iterable) — opposite of filter()
list(itertools.filterfalse(lambda x: x % 2, [1, 2, 3, 4, 5]))  # [2, 4]

# Real DE scenario: skip header rows, process data rows
def process_csv_skipheader(f):
    """Skip CSV header, yield data rows."""
    lines = (l.strip() for l in f)
    # Skip until first data row (not starting with #)
    data = itertools.dropwhile(lambda l: l.startswith("#"), lines)
    for row in data:
        yield row.split(",")
```

### Slicing

```python
# islice(iterable, start, stop, step) — lazy slice (like range)
list(itertools.islice([10, 20, 30, 40, 50], 1, 4))      # [20, 30, 40]
list(itertools.islice(range(10), 0, 10, 2))             # [0, 2, 4, 6, 8]

# Real DE scenario: paginate through query results
def get_page(records, page_size, page_num):
    """Get page N of results without loading all."""
    start = (page_num - 1) * page_size
    return itertools.islice(records, start, start + page_size)

# Usage: fetch 1000-1100 from database
for record in get_page(all_records, page_size=100, page_num=11):
    print(record)
```

### Grouping/Batching

```python
# groupby(iterable, key) — group consecutive items by key
data = [("a", 1), ("a", 2), ("b", 1), ("b", 2), ("a", 3)]
for key, group in itertools.groupby(data, key=lambda x: x[0]):
    print(key, list(group))  # a [(a,1), (a,2)], then b [...], then a [...]

# batched(iterable, n) — yield n-sized chunks (Python 3.12+)
list(itertools.batched([1, 2, 3, 4, 5], 2))  # [[1, 2], [3, 4], [5]]

# Real DE scenario: batch database inserts
def batch_inserts(records, batch_size=1000):
    """Batch records for efficient bulk insert."""
    for batch in itertools.batched(records, batch_size):
        db.bulk_insert(batch)
```

### Combining Multiple Iterables

```python
# zip_longest(*iterables, fillvalue) — zip unequal lengths
list(itertools.zip_longest([1, 2], ["a", "b", "c"], fillvalue=None))
# [(1, "a"), (2, "b"), (None, "c")]

# product(*iterables) — Cartesian product
list(itertools.product([1, 2], ["a", "b"]))  # [(1,a), (1,b), (2,a), (2,b)]

# combinations(iterable, r) — r-length combinations
list(itertools.combinations([1, 2, 3], 2))   # [(1,2), (1,3), (2,3)]

# permutations(iterable, r) — r-length permutations
list(itertools.permutations([1, 2, 3], 2))   # [(1,2), (1,3), (2,1), ...]
```

### Accumulating/Reducing

```python
# accumulate(iterable, func, initial) — running total/product
list(itertools.accumulate([1, 2, 3, 4], lambda x, y: x + y))  # [1, 3, 6, 10]
list(itertools.accumulate([1, 2, 3, 4], lambda x, y: x * y))  # [1, 2, 6, 24]

# Real DE scenario: running sum of metrics
for timestamp, metric_value in data:
    for cumsum in itertools.accumulate([metric_value], lambda x, y: x + y):
        print(f"{timestamp}: cumulative {cumsum}")
```

---

## Interview Questions

**Q: What's the difference between an iterable and an iterator?**
An iterable has `__iter__()` and can be looped over. It returns an iterator when `iter()` is called. An iterator has both `__iter__()` (returns self) and `__next__()`, and tracks position. You can iterate an iterable multiple times (fresh iterator each). An iterator exhausts after one pass. Example: list is iterable, generators are iterators.

**Q: What does `for item in iterable:` do internally?**
It's equivalent to: `it = iter(iterable)` (calls `__iter__()`) → `while True: item = next(it)` (calls `__next__()`) → `except StopIteration: break` (catch when exhausted). Understanding this is critical for debugging iteration issues.

**Q: Explain the `iter(callable, sentinel)` pattern. Where is it used?**
`iter(callable, sentinel)` calls the callable repeatedly until it returns the sentinel. Use for reading chunks: `iter(functools.partial(f.read, 4096), b"")` calls `f.read(4096)` repeatedly until it returns empty bytes. Critical for reading huge files without loading all into memory.

**Q: You're reading a 50GB binary file. Which approach uses less memory: loading chunks into a list or using a generator with sentinel?**
Generator with sentinel: `iter(functools.partial(f.read, chunk), b"")` → memory is constant (bounded by chunk size). List approach: saves all chunks in memory simultaneously, potentially GB. Generator is always better for streaming.

**Q: What does `itertools.chain()` do? How is it different from concatenating lists?**
`itertools.chain(iter1, iter2)` lazily concatenates iterators without creating intermediate lists. `list(iter1) + list(iter2)` materializes both completely in memory first. Chain is memory-efficient for large iterators. Scenario: `chain.from_iterable(open(f) for f in log_files)` processes multiple files as one stream without loading all.

**Q: Explain `itertools.groupby()` with an example.**
`groupby(iterable, key_func)` groups consecutive items with the same key. It does NOT sort — items must already be sorted by key. Example: `groupby([("a",1), ("a",2), ("b",1)], lambda x: x[0])` groups by first element. Gotcha: if items are not pre-sorted, grouping misses items. Use `sorted(..., key=...)` first if needed.

**Q: When would you use `itertools.batched()` in a data pipeline?**
When you need to process data in chunks for efficiency (e.g., bulk database inserts). `batched(records, 1000)` yields 1000-item batches. More efficient than inserting one record at a time. Alternative in older Python: `itertools.zip_longest()` or manual chunking with deque.

**Q: Write a generator that reads a CSV file and yields batches of rows (use sentinel pattern).**
```python
import csv, functools

def csv_batch_reader(filepath, batch_size=100):
    with open(filepath) as f:
        reader = csv.DictReader(f)
        for batch in itertools.batched(reader, batch_size):
            yield batch
```

**Q: Contrast list comprehension vs generator expression vs itertools. When use each?**
- List comprehension `[x for x in data]` — eager, all results in memory, simple logic
- Generator expression `(x for x in data)` — lazy, constant memory, one-time iteration
- itertools — specialized patterns (chain, groupby, accumulate). Use when you need specific combining/grouping logic that's not a simple comprehension.

---

# zip_longest — zip with fill value for unequal lengths
list(itertools.zip_longest([1,2,3], ["a","b"], fillvalue=None))
# [(1,'a'), (2,'b'), (3,None)]

# ── Slicing / selecting ───────────────────────────────────────────
# islice — slice any iterator (no random access needed)
list(itertools.islice(range(100), 5, 15, 2))   # [5, 7, 9, 11, 13]
first10 = list(itertools.islice(huge_gen(), 10))

# takewhile / dropwhile
list(itertools.takewhile(lambda x: x < 5, [1, 3, 5, 2, 7]))  # [1, 3]
list(itertools.dropwhile(lambda x: x < 5, [1, 3, 5, 2, 7]))  # [5, 2, 7]

# filterfalse — opposite of filter
list(itertools.filterfalse(lambda x: x % 2, range(10)))  # [0, 2, 4, 6, 8]

# compress — select items where mask is True
data = ["a", "b", "c", "d"]
mask = [True, False, True, False]
list(itertools.compress(data, mask))   # ["a", "c"]

# ── Grouping ──────────────────────────────────────────────────────
# groupby — MUST be pre-sorted by key
data = sorted([
    {"region": "US", "sales": 100},
    {"region": "EU", "sales": 200},
    {"region": "US", "sales": 150},
], key=lambda r: r["region"])

for region, group in itertools.groupby(data, key=lambda r: r["region"]):
    rows = list(group)
    print(region, sum(r["sales"] for r in rows))

# ── Combinatorics ─────────────────────────────────────────────────
# product — cartesian product
list(itertools.product([1,2], ["a","b"]))
# [(1,'a'), (1,'b'), (2,'a'), (2,'b')]

# combinations — no repetition, order doesn't matter
list(itertools.combinations([1,2,3], 2))
# [(1,2), (1,3), (2,3)]

# combinations_with_replacement
list(itertools.combinations_with_replacement([1,2], 2))
# [(1,1), (1,2), (2,2)]

# permutations — order matters
list(itertools.permutations([1,2,3], 2))
# [(1,2), (1,3), (2,1), (2,3), (3,1), (3,2)]

# ── Accumulation ─────────────────────────────────────────────────
import operator
list(itertools.accumulate([1, 2, 3, 4], operator.add))   # [1, 3, 6, 10]
list(itertools.accumulate([1, 2, 3, 4], operator.mul))   # [1, 2, 6, 24]
list(itertools.accumulate([3, 1, 4, 1, 5], max))         # [3, 3, 4, 4, 5]

# ── Batching (Python 3.12+) ───────────────────────────────────────
# batched — split iterable into fixed-size chunks
for batch in itertools.batched(range(10), 3):
    print(list(batch))
# [0,1,2], [3,4,5], [6,7,8], [9]

# Pre-3.12 batching — write your own
def batched_compat(iterable, n):
    it = iter(iterable)
    while chunk := list(itertools.islice(it, n)):
        yield chunk
```

---

## Practical DE Patterns with itertools

### Multi-file Union (memory-efficient)

```python
import itertools, csv

def read_all_csvs(filepaths):
    """Stream all CSV rows from multiple files without loading all into memory."""
    def rows_from_file(path):
        with open(path) as f:
            reader = csv.DictReader(f)
            yield from reader   # yield from to handle StopIteration correctly

    return itertools.chain.from_iterable(rows_from_file(p) for p in filepaths)

for row in read_all_csvs(["jan.csv", "feb.csv", "mar.csv"]):
    process(row)
```

### Windowed / Sliding Iteration

```python
from collections import deque

def sliding_window(iterable, n):
    """Yield overlapping windows of size n."""
    it = iter(iterable)
    window = deque(itertools.islice(it, n), maxlen=n)
    if len(window) == n:
        yield tuple(window)
    for item in it:
        window.append(item)
        yield tuple(window)

list(sliding_window([1, 2, 3, 4, 5], 3))
# [(1,2,3), (2,3,4), (3,4,5)]
```

### Round-Robin Distribution (Load Balancing)

```python
def round_robin(*iterables):
    """Interleave items from multiple iterables."""
    nexts = itertools.cycle(iter(it).__next__ for it in iterables)
    pending = len(iterables)
    while pending:
        try:
            for next_fn in nexts:
                yield next_fn()
        except StopIteration:
            pending -= 1
            nexts = itertools.cycle(
                itertools.islice(nexts, pending)
            )
```

### Deduplication with Seen Set

```python
def unique_everseen(iterable, key=None):
    seen = set()
    for element in iterable:
        k = key(element) if key else element
        if k not in seen:
            seen.add(k)
            yield element

# Usage: deduplicate records by id while preserving order
unique_records = list(unique_everseen(records, key=lambda r: r["id"]))
```

---

## Interview Questions

**Q: What's the difference between an iterable and an iterator?**
An iterable has `__iter__` and can produce a fresh iterator each time. An iterator has both `__iter__` and `__next__`, maintains state, and is exhausted after one full pass. Lists are iterable but not iterators; files and generators are both.

**Q: Why must `groupby` data be pre-sorted?**
`itertools.groupby` groups **consecutive** elements with the same key. Unsorted data produces multiple groups for the same key value instead of one.

**Q: What does `iter(callable, sentinel)` do?**
Calls the callable repeatedly until it returns the sentinel value, then raises `StopIteration`. Useful for reading fixed-size chunks from binary files or sockets.

**Q: How do you iterate over a large multi-file dataset without loading everything into memory?**
`itertools.chain.from_iterable` with generator expressions per file. Each file is opened, yielded from, and closed before the next opens.
