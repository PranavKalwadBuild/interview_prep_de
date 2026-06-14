<!-- python-patterns: Iterators and itertools -->

# Iterators and itertools

## Iterator Protocol

An **iterable** is anything you can pass to `for`. An **iterator** is an object that implements both `__iter__` and `__next__`.

```python
# Iterable — has __iter__ that returns an iterator
class NumberRange:
    def __init__(self, start, stop):
        self.start = start
        self.stop = stop

    def __iter__(self):
        return NumberRangeIterator(self.start, self.stop)

# Iterator — has __iter__ (returns self) and __next__
class NumberRangeIterator:
    def __init__(self, current, stop):
        self.current = current
        self.stop = stop

    def __iter__(self):
        return self   # iterators are their own iterables

    def __next__(self):
        if self.current >= self.stop:
            raise StopIteration
        val = self.current
        self.current += 1
        return val

for n in NumberRange(1, 4):
    print(n)   # 1, 2, 3

# Manual iteration
r = NumberRange(1, 4)
it = iter(r)         # calls __iter__
next(it)             # calls __next__ → 1
next(it)             # → 2
next(it)             # → 3
next(it)             # raises StopIteration
```

### Iterable vs Iterator — Key Distinction

| | Iterable | Iterator |
|---|---|---|
| Has `__iter__` | Yes | Yes |
| Has `__next__` | No | Yes |
| Can restart | Yes (new iterator each time) | No (exhausted is exhausted) |
| Example | `list`, `str`, `dict`, custom | `file`, `zip`, generator, `map` |

```python
lst = [1, 2, 3]           # iterable — not an iterator
it = iter(lst)            # iterator
next(it)                  # 1
# lst can be iterated again; it cannot

# Files are iterators
f = open("file.txt")
next(f)                   # first line
iter(f) is f              # True — file is its own iterator
```

---

## `iter()` with Sentinel

```python
# iter(callable, sentinel) — calls callable repeatedly until it returns sentinel
# Useful for reading fixed-size chunks from a binary file

import functools

def read_binary_chunks(path, chunk_size=4096):
    with open(path, "rb") as f:
        reader = functools.partial(f.read, chunk_size)
        for chunk in iter(reader, b""):   # stops when read() returns b""
            yield chunk
```

---

## `itertools` — Full DE Reference

```python
import itertools

# ── Infinite iterators ────────────────────────────────────────────
itertools.count(10, 2)         # 10, 12, 14, 16, ...
itertools.cycle([1, 2, 3])     # 1, 2, 3, 1, 2, 3, ...
itertools.repeat(0, 5)         # 0, 0, 0, 0, 0

# ── Chaining / combining ──────────────────────────────────────────
# chain — concatenate iterables
list(itertools.chain([1, 2], [3, 4], [5]))      # [1, 2, 3, 4, 5]
list(itertools.chain.from_iterable([[1,2],[3]])) # [1, 2, 3]

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
