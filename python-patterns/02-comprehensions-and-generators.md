<!-- python-patterns: Comprehensions and Generators -->

# Comprehensions and Generators

## List Comprehensions

### How It Works

Single-expression loop that builds a list. Faster than equivalent `for` loop + `append` because CPython optimizes the bytecode.

```python
# Basic
squares = [x**2 for x in range(10)]

# With filter
evens = [x for x in range(20) if x % 2 == 0]

# Nested — reads left to right like nested for loops
pairs = [(x, y) for x in [1, 2, 3] for y in ["a", "b"] if x != 2]
# equivalent to:
# for x in [1,2,3]:
#   for y in ["a","b"]:
#     if x != 2: pairs.append((x,y))

# Transform dicts
normalized = [
    {"id": r["ID"], "amount": float(r["AMOUNT"]), "ts": r["TIMESTAMP"]}
    for r in raw_records
    if r.get("AMOUNT") is not None
]
```

### When NOT to Use

```python
# BAD — comprehension for side effects (confusing, not idiomatic)
[print(x) for x in items]

# GOOD — use a plain loop for side effects
for x in items:
    print(x)

# BAD — deeply nested comprehension (unreadable after 2 levels)
result = [[cell for cell in row if cell] for row in matrix if row]

# GOOD — break it into steps or use a function
def clean_row(row):
    return [cell for cell in row if cell]
result = [clean_row(row) for row in matrix if row]
```

---

## Dict and Set Comprehensions

```python
# Dict comprehension
word_lengths = {word: len(word) for word in ["apple", "banana", "cherry"]}

# Invert a dict
original = {"a": 1, "b": 2, "c": 3}
inverted = {v: k for k, v in original.items()}

# Filter a dict
active = {k: v for k, v in users.items() if v["status"] == "active"}

# Set comprehension
unique_regions = {row["region"] for row in records}

# Dedup while transforming
seen_ids = set()
unique_records = [
    r for r in records
    if r["id"] not in seen_ids and not seen_ids.add(r["id"])
]
```

---

## Generator Expressions

### How It Works

Same syntax as list comprehension but with `()`. Returns a **generator object** — lazy, produces one item at a time, does NOT build the whole list in memory.

```python
# List comprehension — all 1M items in memory at once
squares_list = [x**2 for x in range(1_000_000)]  # ~8MB

# Generator expression — one item at a time, ~constant memory
squares_gen = (x**2 for x in range(1_000_000))

# Use directly in functions that accept iterables
total = sum(x**2 for x in range(1_000_000))     # no extra () needed inside sum()
maximum = max(len(line) for line in open("file.txt"))
filtered = list(filter(None, (row.strip() for row in lines)))
```

### Generator Exhaustion — Silent Data Loss

```python
gen = (x * 2 for x in range(5))
first_pass = list(gen)   # [0, 2, 4, 6, 8]
second_pass = list(gen)  # [] — generator is exhausted, cannot rewind

# In DE — reading a file generator twice:
rows = (line.strip() for line in open("data.csv"))
count = sum(1 for _ in rows)  # consumes it
data  = list(rows)            # EMPTY — silent data loss

# Fix: materialize if you need multiple passes
rows = list(line.strip() for line in open("data.csv"))
```

---

## Generator Functions with `yield`

### How It Works

A function with `yield` is a generator function. Calling it returns a generator object without executing the body. Each `next()` call executes until the next `yield`, then suspends.

```python
def count_up(n):
    i = 0
    while i < n:
        yield i   # suspend here, return i to caller
        i += 1    # resume here on next call

gen = count_up(3)
next(gen)  # 0
next(gen)  # 1
next(gen)  # 2
next(gen)  # StopIteration

# Use in for loop — StopIteration handled automatically
for val in count_up(3):
    print(val)
```

### Real DE Pattern — Chunked File Reading

```python
def read_csv_chunks(filepath, chunk_size=10_000):
    """Read a large CSV in chunks without loading it all into memory."""
    with open(filepath, encoding="utf-8") as f:
        header = next(f).strip().split(",")
        chunk = []
        for line in f:
            chunk.append(dict(zip(header, line.strip().split(","))))
            if len(chunk) >= chunk_size:
                yield chunk
                chunk = []
        if chunk:           # don't forget the last partial chunk
            yield chunk

for batch in read_csv_chunks("events.csv", chunk_size=5_000):
    load_to_db(batch)
```

### Real DE Pattern — Generator Pipeline

Each stage is lazy — memory stays flat regardless of data size.

```python
def parse_lines(lines):
    for line in lines:
        yield json.loads(line)

def filter_valid(records):
    for r in records:
        if r.get("event_type") and r.get("user_id"):
            yield r

def enrich(records):
    for r in records:
        r["date"] = r["timestamp"][:10]
        yield r

def batch(records, size=1000):
    buf = []
    for r in records:
        buf.append(r)
        if len(buf) >= size:
            yield buf
            buf = []
    if buf:
        yield buf

# Compose pipeline — no intermediate lists created
with open("events.jsonl") as f:
    pipeline = batch(enrich(filter_valid(parse_lines(f))))
    for batch_records in pipeline:
        db.executemany("INSERT INTO events ...", batch_records)
```

### `yield from` — Delegate to Sub-Generator

```python
def chain_files(filepaths):
    for path in filepaths:
        yield from open(path)   # delegates to file iterator line by line

def flatten(nested):
    for item in nested:
        if isinstance(item, list):
            yield from flatten(item)  # recursive delegation
        else:
            yield item

list(flatten([1, [2, [3, 4]], 5]))  # [1, 2, 3, 4, 5]
```

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

## Interview Questions

**Q: What's the difference between a list comprehension and a generator expression?**
List comprehension evaluates immediately and stores all results in memory. Generator expression is lazy — produces one item at a time. Use generator when data is large or you only need to iterate once.

**Q: What is `yield` vs `return`?**
`return` exits the function and discards local state. `yield` suspends the function, preserving all local state, and returns a value to the caller. Next `next()` call resumes from where it left off.

**Q: What does `yield from` do?**
Delegates iteration to a sub-generator. Equivalent to `for x in sub: yield x` but more efficient and propagates `send()` / `throw()` / `close()` calls correctly.

**Q: You need to process a 50 GB CSV file. What's your Python approach?**
Generator function that reads and yields chunks (e.g., 10K rows at a time). Never `pd.read_csv("file.csv")` without `chunksize`. Each chunk is processed and discarded — memory stays flat.

**Q: A colleague wrote `total = sum([x**2 for x in range(1_000_000)])`. What's wrong?**
The list comprehension builds all 1M values in memory before summing. Fix: `sum(x**2 for x in range(1_000_000))` — the generator expression feeds one value at a time into `sum()`.
