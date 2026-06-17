<!-- python-patterns: Comprehensions and Generators -->

# Comprehensions and Generators

---

## Part 1: Comprehensions (List, Dict, Set)

### Understanding the Problem: Why Comprehensions Exist

Traditionally, building lists required boilerplate: create empty list, loop, append. Comprehensions solve this by condensing the pattern into a single, readable expression.

**The mental model:** A comprehension is a declarative statement: "Give me X for each Y in Z where W is true." It reads like a mathematical set notation: {x | x ∈ Z, W(x)}.

Why they matter:
- **Performance**: CPython compiles comprehensions to optimized bytecode. A for loop + append generates many bytecode instructions; a comprehension generates fewer, specialized ones. ~10-20% faster.
- **Readability**: Intent is clear at a glance. `[x*2 for x in numbers]` immediately communicates "double each number."
- **Scope**: Comprehensions have their own local scope in Python 3. Loop variables don't leak into the outer scope.

```python
# The Traditional Way (verbose, scope leakage)
squares = []
for x in range(10):
    squares.append(x**2)
print(x)  # 9 — x leaked into outer scope!

# The Comprehension Way (concise, scoped)
squares = [x**2 for x in range(10)]
print(x)  # NameError — x doesn't exist in outer scope
```

---

## List Comprehensions

### How It Works

Single-expression loop that builds a list in one statement. Faster than equivalent `for` loop + `append` because CPython optimizes the bytecode.

```python
# Basic — transform each element
squares = [x**2 for x in range(10)]
# Mental model: FOR each x IN range(10) → x**2

# With filter — keep only matching elements
evens = [x for x in range(20) if x % 2 == 0]
# Mental model: FOR each x IN range(20) IF x is even → x

# Nested — reads left to right like nested for loops
pairs = [(x, y) for x in [1, 2, 3] for y in ["a", "b"] if x != 2]
# Mental model:
#   FOR x IN [1, 2, 3]:
#     FOR y IN ["a", "b"]:
#       IF x != 2:
#         yield (x, y)
# Result: [(1, 'a'), (1, 'b'), (3, 'a'), (3, 'b')]

# Transform dicts — common DE pattern
normalized = [
    {"id": r["ID"], "amount": float(r["AMOUNT"]), "ts": r["TIMESTAMP"]}
    for r in raw_records
    if r.get("AMOUNT") is not None
]
```

### Data Engineering Scenarios

**Scenario 1: Batch Processing with Filtering**
```python
# ETL pipeline: extract, clean, flatten in one pass
events = [
    {
        "user_id": event["uid"],
        "timestamp": int(event["ts"]),
        "event_type": event["type"].upper(),
    }
    for event in raw_events
    if event.get("uid") and event.get("ts") and event.get("type")
]
```

**Scenario 2: Deduplication with Set Comprehension**
```python
# Remove duplicate IDs while preserving order (post-processing)
seen = set()
unique_records = [
    r for r in records
    if r["id"] not in seen and not seen.add(r["id"])
]
# Note: seen.add() returns None, not seen.add(r["id"]) is truthy
```

**Scenario 3: Conditional Transformation**
```python
# Different logic for different cases
normalized = [
    (
        "premium" if r["status"] == "A" else
        "trial" if r["status"] == "T" else
        "free"
    )
    for r in users
]
```

### When NOT to Use Comprehensions

```python
# BAD — comprehension for side effects (confusing, not idiomatic)
[print(x) for x in items]
[db.insert(x) for x in batch]

# GOOD — use a plain loop for side effects
for x in items:
    print(x)

for x in batch:
    db.insert(x)

# BAD — deeply nested comprehension (unreadable after 2 levels)
result = [[cell for cell in row if cell] for row in matrix if row]

# GOOD — break it into steps or use a function
def clean_row(row):
    return [cell for cell in row if cell]
result = [clean_row(row) for row in matrix if row]

# BAD — comprehension with multiple conditional paths (hard to reason about)
result = [
    x * 2 if x > 10
    else x + 1 if x > 5
    else x
    for x in data
]

# GOOD — extract into a helper function
def normalize(x):
    if x > 10:
        return x * 2
    elif x > 5:
        return x + 1
    else:
        return x

result = [normalize(x) for x in data]
```

### Performance: Comprehension vs Loop

```python
import timeit

# Comprehension
comp_time = timeit.timeit(
    "[x**2 for x in range(10000)]",
    number=10000
)

# For loop + append
loop_time = timeit.timeit(
    """
result = []
for x in range(10000):
    result.append(x**2)
""",
    number=10000
)

# Comprehension is ~10-20% faster due to optimized bytecode
# For small lists: negligible difference
# For large lists: comprehension becomes obviously faster
```

---

## Dict and Set Comprehensions

### Understanding Dict Comprehensions

Dict comprehensions follow the same pattern but produce key-value pairs: `{key_expr: value_expr for item in items}`

```python
# Dict comprehension — transform and index
word_lengths = {word: len(word) for word in ["apple", "banana", "cherry"]}
# {"apple": 5, "banana": 6, "cherry": 6}

# Invert a dict (swap keys and values)
original = {"a": 1, "b": 2, "c": 3}
inverted = {v: k for k, v in original.items()}
# {1: "a", 2: "b", 3: "c"}

# Filter a dict (keep only matching items)
active = {k: v for k, v in users.items() if v["status"] == "active"}
# Only active users

# Transform dict values
doubled = {k: v * 2 for k, v in prices.items()}
# All prices doubled

# Create lookup table
lookup = {item["id"]: item for item in records}
# O(1) lookup by ID instead of O(n) search
```

### Understanding Set Comprehensions

Set comprehensions are like list comprehensions but produce sets (unique, unordered):

```python
# De-duplicate regions
unique_regions = {row["region"] for row in records}
# Automatic deduplication

# Transform while de-duplicating
user_domains = {email.split("@")[1] for email in email_list}
# Unique domains from email list

# Conditional set
premium_ids = {row["id"] for row in records if row["plan"] == "premium"}
# Set of premium user IDs for fast O(1) membership checks
```

---

## Part 2: Generators and Lazy Evaluation

### Understanding Generators: Why They Matter

Generators solve the **memory problem**: processing large data. Without generators, you'd load entire datasets into memory before processing. Generators stream data one item at a time.

**The Mental Model:** Think of a generator as a "lazy producer" that computes values on-demand, pauses, resumes, and never stores all values in memory.

Why they're critical in data engineering:
- **Memory efficiency**: Process a 100GB file with constant memory (limited by chunk size)
- **Streaming**: Connect to infinite sources (Kafka, APIs, network streams)
- **Pipeline composition**: Chain transformations without intermediate lists
- **Backpressure**: Natural throttling — slow consumer limits fast producer

---

## Generator Expressions

### Understanding the Problem: List vs Generator

Imagine loading a 1M-row CSV file:

```python
# List comprehension — ALL 1M rows in memory at once
rows_list = [parse(line) for line in open("huge.csv")]  # ~500MB for 1M rows

# Generator expression — ONE row at a time, constant memory
rows_gen = (parse(line) for line in open("huge.csv"))   # ~1KB memory

# Practical scenario in DE:
# Processing raw clickstream data
total_clicks = sum(1 for line in open("clicks.log"))    # Constant memory
# vs.
all_clicks = [1 for line in open("clicks.log")]         # Entire file in memory!
```

### How Generator Expressions Work

**Syntax**: Same as list comprehension but with `()` instead of `[]`. Returns a generator object (lazy), not a list (eager).

```python
# List comprehension — evaluates immediately
squares_list = [x**2 for x in range(1_000_000)]  # ~8MB, takes seconds to create
print(type(squares_list))                         # <class 'list'>
total = sum(squares_list)                         # iterate the list

# Generator expression — deferred evaluation
squares_gen = (x**2 for x in range(1_000_000))   # instant, no computation yet
print(type(squares_gen))                          # <class 'generator'>
total = sum(squares_gen)                          # NOW computation happens, during iteration

# Key insight: generator doesn't compute values until you iterate
gen = (x**2 for x in range(5))
print(gen)                                         # <generator object ...>
# No computation has happened yet!

# Iteration triggers computation
for val in gen:
    print(val)  # NOW each x**2 is computed, yielded, then discarded
```

### Generator Expression in Function Calls

```python
# In functions that iterate, generators are ideal
total = sum(x**2 for x in range(1_000_000))        # no extra () needed
maximum = max(len(line) for line in open("file.txt"))
count = len(list(x for x in huge_data if x > 0))  # must convert to list for len()

# Nested generators
counts = (len(line) for line in open("file.txt"))
max_length = max(counts)                           # one pass, constant memory
```

### The Generator Exhaustion Problem — Silent Data Loss

**Critical gotcha:** Generators can only be iterated once. Iterating twice produces no results on the second pass.

```python
# DANGEROUS: Iterator exhaustion
gen = (x * 2 for x in range(5))
first_pass = list(gen)   # [0, 2, 4, 6, 8] — exhausts the generator
second_pass = list(gen)  # [] — EMPTY! Generator is done

# In data pipelines — subtle bugs:
file_lines = (line.strip() for line in open("data.csv"))
row_count = sum(1 for _ in file_lines)  # iterates, exhausts
data = [dict(zip(headers, line.split(","))) for line in file_lines]  # EMPTY!

# Fix 1: Materialize if you need multiple passes
file_lines = [line.strip() for line in open("data.csv")]  # Convert to list

# Fix 2: Or re-create the generator
def get_file_lines():
    return (line.strip() for line in open("data.csv"))

for line in get_file_lines():
    print(line)
# ... later ...
for line in get_file_lines():  # Fresh generator
    process(line)
```

---

## Generator Functions with `yield`

### Understanding `yield`: Suspension and Resumption

A generator function is a function with `yield` statements. When called, it doesn't execute the body — it returns a generator object. Each `next()` call executes until the next `yield`, pauses, then resumes from that point.

**Mental Model:** A generator function is like a machine that pauses and stores its entire state (local variables, instruction pointer). `next()` resumes it, it runs until `yield`, returns a value, then pauses again.

```python
# CRITICAL: Generator function returns generator object without executing
def count_up(n):
    print("Starting")  # NOT executed yet
    i = 0
    while i < n:
        print(f"Before yield {i}")
        yield i
        print(f"After yield {i}")
        i += 1

# Calling the function — body doesn't execute!
gen = count_up(3)
print(f"Gen created: {gen}")  # <generator object count_up>
# "Starting" hasn't printed yet!

# First next() — runs until first yield
print(next(gen))  # Prints: "Starting", "Before yield 0" → returns 0

# Second next() — resumes from last yield, runs until next yield
print(next(gen))  # Prints: "After yield 0", "Before yield 1" → returns 1

# Third next()
print(next(gen))  # Prints: "After yield 1", "Before yield 2" → returns 2

# Fourth next() — exhausts generator
print(next(gen))  # Prints: "After yield 2" → raises StopIteration
```

### Generator State Preservation

The key feature: generators preserve local state across `yield` calls.

```python
def counting_statistics(values):
    """Generator that maintains running statistics."""
    total = 0
    count = 0
    
    for value in values:
        total += value  # State persists across yields
        count += 1
        average = total / count  # Computed from preserved state
        yield average

# All state variables persist!
stats = counting_statistics([10, 20, 30, 40])
print(next(stats))  # 10/1 = 10.0
print(next(stats))  # 30/2 = 15.0
print(next(stats))  # 60/3 = 20.0
print(next(stats))  # 100/4 = 25.0
```

### Real DE Pattern — Chunked File Reading

Reading 100GB CSV without loading it all:

```python
def read_csv_chunks(filepath, chunk_size=10_000):
    """
    Read a large CSV in chunks without loading all into memory.
    Returns generator of batches.
    """
    with open(filepath, encoding="utf-8") as f:
        header = next(f).strip().split(",")
        chunk = []
        
        for line in f:
            record = dict(zip(header, line.strip().split(",")))
            chunk.append(record)
            
            if len(chunk) >= chunk_size:
                yield chunk  # Yield batch, pause here
                chunk = []   # Reset for next batch
        
        if chunk:  # Don't forget the last partial chunk
            yield chunk

# Processing 100GB file in 10K-row chunks
total_rows = 0
for batch in read_csv_chunks("huge_events.csv", chunk_size=10_000):
    # Each batch is 10K rows, ~ 5MB
    processed = [transform(r) for r in batch]
    db.bulk_insert(processed)
    total_rows += len(batch)
    print(f"Processed {total_rows} rows so far...")
# Memory never exceeds ~50MB regardless of file size!
```

### Real DE Pattern — Generator Pipeline Composition

Multiple lazy stages chained together:

```python
import json

def parse_jsonl(lines):
    """Parse JSON lines."""
    for line in lines:
        try:
            yield json.loads(line)
        except json.JSONDecodeError:
            continue

def filter_valid(records):
    """Filter records with required fields."""
    for r in records:
        if r.get("event_type") and r.get("user_id") and r.get("timestamp"):
            yield r

def enrich(records):
    """Add derived fields."""
    for r in records:
        r["date"] = r["timestamp"][:10]
        r["hour"] = int(r["timestamp"][11:13])
        yield r

def batch(records, size=1000):
    """Batch records."""
    buf = []
    for r in records:
        buf.append(r)
        if len(buf) >= size:
            yield buf
            buf = []
    if buf:
        yield buf

# Entire pipeline is lazy — no intermediate lists!
# Memory usage is bounded by chunk_size
with open("events.jsonl") as f:
    lines = f  # File iterator
    parsed = parse_jsonl(lines)
    valid = filter_valid(parsed)
    enriched = enrich(valid)
    batches = batch(enriched, size=5000)
    
    for batch_records in batches:
        # Process only current batch (~5000 * record_size)
        db.executemany("INSERT INTO events ...", batch_records)

# Pipeline visualization (no actual list created):
# f → parse_jsonl() → filter_valid() → enrich() → batch() → db
```

### `yield from` — Delegate to Sub-Generator

`yield from` is syntactic sugar for "iterate over sub-generator and yield each value."

```python
# Reading multiple files line-by-line
def chain_files(filepaths):
    for path in filepaths:
        yield from open(path)  # Equivalent to: for line in open(path): yield line

# Usage
for line in chain_files(["file1.csv", "file2.csv", "file3.csv"]):
    process(line)

# Recursive flattening
def flatten(nested):
    """Flatten arbitrarily nested lists."""
    for item in nested:
        if isinstance(item, list):
            yield from flatten(item)  # Recursive delegation
        else:
            yield item

list(flatten([1, [2, [3, [4, 5]]], 6]))  # [1, 2, 3, 4, 5, 6]

# Data transformation delegation
def load_all_tables(table_generators):
    """Load from multiple data sources."""
    for table_gen in table_generators:
        yield from table_gen  # Delegate to each source's generator
```

---

### `send()` — Two-Way Communication with Generator

```python
def running_average():
    total = 0
    count = 0
    avg = None
    while True:
        value = yield avg         # yield current avg, receive next value via send()
        total += value
        count += 1
        avg = total / count

gen = running_average()
next(gen)          # prime the generator (must call before send)
gen.send(10)       # 10.0
gen.send(20)       # 15.0
gen.send(30)       # 20.0
```

---

## `itertools` — Lazy Iteration Tools for DE

```python
import itertools

# chain — iterate multiple iterables as one
from itertools import chain
all_rows = list(chain(table_a_rows, table_b_rows, table_c_rows))

# chain.from_iterable — flatten one level
nested = [[1, 2], [3, 4], [5]]
flat = list(chain.from_iterable(nested))  # [1, 2, 3, 4, 5]

# islice — take first N from any iterable (works on infinite generators)
from itertools import islice
first_100 = list(islice(huge_generator(), 100))

# batched (Python 3.12+) — chunk an iterable into fixed-size batches
from itertools import batched
for batch in batched(records, 1000):
    db.bulk_insert(batch)

# groupby — group consecutive identical keys (MUST be pre-sorted by key)
from itertools import groupby
data = sorted(records, key=lambda r: r["region"])
for region, group in groupby(data, key=lambda r: r["region"]):
    region_rows = list(group)

# product — cartesian product (replaces nested loops)
from itertools import product
for schema, table in product(["raw", "staging"], ["orders", "users"]):
    validate(schema, table)

# combinations / permutations
from itertools import combinations
for col_a, col_b in combinations(columns, 2):
    check_correlation(col_a, col_b)

# accumulate — running totals
from itertools import accumulate
import operator
running_total = list(accumulate([10, 20, 30, 40], operator.add))  # [10, 30, 60, 100]

# takewhile / dropwhile
from itertools import takewhile, dropwhile
valid = list(takewhile(lambda x: x > 0, [5, 3, 1, -1, 2]))  # [5, 3, 1]
after_header = list(dropwhile(lambda line: line.startswith("#"), file_lines))
```

---

---

## Interview Questions

**Q: What's the difference between a list comprehension and a generator expression?**
List comprehension evaluates immediately and stores all results in memory — `[x**2 for x in range(1M)]` creates all 1M values at once (~8MB). Generator expression is lazy — `(x**2 for x in range(1M))` produces values one at a time on demand, constant memory. Use generators for large datasets, one-time iterations. Use lists when you need multiple iterations or immediate access.

**Q: When would you NOT use a generator?**
When you need to: (1) iterate the data multiple times — generators exhaust after one pass. (2) Know the length upfront (`len(gen)` fails). (3) Access by index (`gen[0]` fails). (4) Perform operations like sorting that need all data. In these cases, materialize to a list: `data = list(generator)`.

**Q: What is `yield` vs `return`? What's the key difference?**
`return` exits the function permanently, discarding all local state. `yield` pauses the function, preserving all local variables and the instruction pointer. Calling `next()` resumes from where it left off. So a function with `yield` can be resumed multiple times, one value at a time. `return` in a generator function exits the generator and raises `StopIteration`.

**Q: Explain generator exhaustion. How do you avoid it?**
Generators can only be iterated once. After iteration completes, the generator is "exhausted" — subsequent iterations produce nothing. Example: `gen = (x for x in data); list(gen); list(gen)` — second list is empty. Fix: (1) Materialize to list if needed multiple times. (2) Re-create the generator. (3) Use `itertools.tee()` to create independent copies (but uses memory).

**Q: What does `yield from` do? Why use it?**
`yield from sub_gen` is equivalent to `for value in sub_gen: yield value` but more efficient. It delegates to a sub-generator, preserving all its semantics (including `send()`, `throw()`, `close()`). Use it for recursive generators, chaining file iterators, or delegating to sub-generators in pipelines.

**Q: You need to process a 50 GB CSV file with pandas in production. What's your approach?**
Never `pd.read_csv("file.csv")` — it loads all 50GB into memory. Use chunked reading: `pd.read_csv("file.csv", chunksize=10000)` which returns an iterator. Process each 10K-row chunk, then discard it. Memory stays bounded by chunk size (~50MB). Example:
```python
for chunk in pd.read_csv("huge.csv", chunksize=10000):
    processed = transform(chunk)
    db.bulk_insert(processed)
```

**Q: A colleague wrote `total = sum([x**2 for x in range(1_000_000)])`. What's the performance problem?**
The list comprehension `[x**2 ...]` builds all 1M values in memory before summing. The `sum()` then iterates the entire list. Fix: `sum(x**2 for x in range(1_000_000))` — the generator expression feeds values one at a time to `sum()`, never storing all 1M in memory.

**Q: What's the memory complexity of a generator vs list comprehension for processing N items?**
- List: O(N) — all N items stored in memory simultaneously
- Generator: O(1) — only current item in memory (assuming bounded chunk size)
  
In practice: generator reading a 1GB file uses ~constant memory (chunk size limited); list would attempt to load 1GB into RAM.

**Q: Explain how a generator pipeline (map → filter → transform) works. Why is this pattern powerful?**
Each stage in the pipeline is a generator:
```python
data = [1, 2, 3, 4, 5]
doubled = (x * 2 for x in data)                 # Stage 1: lazy
evens = (x for x in doubled if x % 4 == 0)     # Stage 2: lazy
transformed = (f"num_{x}" for x in evens)      # Stage 3: lazy

result = list(transformed)  # Only HERE do computations happen, in order
# Value 1 → 2 → even? no
# Value 2 → 4 → even? yes → "num_4"
# Value 3 → 6 → even? no
# Value 4 → 8 → even? yes → "num_8"
# Value 5 → 10 → even? yes → "num_10"
```
Powerful because: (1) No intermediate lists created. (2) Processing can start before entire source is available (streaming). (3) Natural backpressure — slow consumer throttles fast producer.

**Q: What's a gotcha with nested comprehensions and variable scope?**
In Python 3, comprehensions have their own local scope. Variables inside don't leak:
```python
result = [x * 2 for x in range(5)]
print(x)  # NameError — x doesn't exist!
```
But in traditional for loops, they do:
```python
for x in range(5):
    result = x * 2
print(x)  # 4 — x leaked into outer scope
```
Comprehensions are safer. But in nested comprehensions, the outer loop's variable can reference the inner:
```python
nested = [[y for y in range(x)] for x in range(3)]  # x is visible to inner comprehension
# [[],  [0], [0, 1]]
```

---
