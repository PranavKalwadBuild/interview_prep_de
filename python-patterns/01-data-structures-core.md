<!-- python-patterns: Data Structures Deep Dive -->

# Data Structures Deep Dive

## Why This File Matters

Data structures are the substrate for almost every Python performance or correctness discussion. In DE work, the difference between list, dict, set, tuple, and deque often decides whether a pipeline is fast, memory-efficient, and easy to reason about.

**Mental model:** choose the structure that matches the access pattern, not the one that looks simplest in the moment. That is the recurring theme of the rest of this repository as well.

## Time Complexity at a Glance

| Operation | list | dict | set | tuple |
|---|---|---|---|---|
| Access by index | O(1) | — | — | O(1) |
| Access by key | — | O(1) avg | — | — |
| Membership (`in`) | O(n) | O(1) avg | O(1) avg | O(n) |
| Append | O(1) amortized | — | — | — |
| Insert at index | O(n) | — | — | — |
| Delete by index | O(n) | — | — | — |
| Delete by key | — | O(1) avg | — | — |
| Iteration | O(n) | O(n) | O(n) | O(n) |
| Sort | O(n log n) | — | — | — |

**The most common interview gotcha:** using `in` on a list when a set would make it O(1).

```python
# BAD — O(n) membership check in a loop → O(n²) total
valid_ids = [1, 2, 3, ...]  # 100,000 items
for row in records:
    if row["id"] in valid_ids:  # linear scan every time
        process(row)

# GOOD — O(1) membership check → O(n) total
valid_ids = {1, 2, 3, ...}  # set
for row in records:
    if row["id"] in valid_ids:
        process(row)
```

---

## list

### How It Works

CPython lists are dynamic arrays. They over-allocate to amortize append cost. Internally a contiguous block of pointers to Python objects.

```python
lst = [1, 2, 3]
lst.append(4)        # O(1) amortized — may trigger realloc
lst.insert(0, 0)     # O(n) — shifts all elements right
lst.pop()            # O(1) — remove from end
lst.pop(0)           # O(n) — shifts all elements left

# Sorting
lst.sort()                          # in-place, O(n log n), stable
sorted_lst = sorted(lst)            # returns new list
lst.sort(key=lambda x: x["score"], reverse=True)  # sort by key
```

### Slicing

```python
lst = [0, 1, 2, 3, 4]
lst[1:3]     # [1, 2]   — new list, not a view
lst[::-1]    # [4, 3, 2, 1, 0]  — reversed copy
lst[::2]     # [0, 2, 4]  — every other element
```

### List as a Stack vs Queue

```python
# Stack (LIFO) — use list
stack = []
stack.append(x)   # push
stack.pop()       # pop — O(1)

# Queue (FIFO) — use collections.deque, NOT list
from collections import deque
queue = deque()
queue.append(x)       # enqueue — O(1)
queue.popleft()       # dequeue — O(1)
# list.pop(0) is O(n) — wrong choice for queues
```

### Mutable Default Argument — The Most Common Bug

```python
# BUG — the list is created ONCE at function definition time, shared across all calls
def add_tag(record, tags=[]):
    tags.append(record["type"])
    return tags

add_tag({"type": "click"})    # ["click"]
add_tag({"type": "view"})     # ["click", "view"]  ← wrong

# FIX — use None as sentinel
def add_tag(record, tags=None):
    if tags is None:
        tags = []
    tags.append(record["type"])
    return tags
```

### list Methods (Complete Reference)

| Method | Signature | Time Complexity | Use Case |
|---|---|---|---|
| `append(x)` | `lst.append(item)` | O(1) amortized | Add single item to end |
| `extend(iterable)` | `lst.extend([1,2,3])` | O(n) | Add multiple items efficiently |
| `insert(index, x)` | `lst.insert(0, item)` | O(n) | Insert at arbitrary position (shifts) |
| `remove(x)` | `lst.remove(item)` | O(n) | Remove first occurrence by value |
| `pop([index])` | `lst.pop()` or `lst.pop(0)` | O(1) if index=-1, O(n) if index=0 | Remove and return by index |
| `clear()` | `lst.clear()` | O(n) | Delete all items |
| `index(x)` | `lst.index(item, [start, end])` | O(n) | Find index of first occurrence |
| `count(x)` | `lst.count(item)` | O(n) | Count occurrences of item |
| `sort()` | `lst.sort(key=None, reverse=False)` | O(n log n) | Sort in-place (Timsort, stable) |
| `reverse()` | `lst.reverse()` | O(n) | Reverse in-place |
| `copy()` | `lst.copy()` | O(n) | Shallow copy of list |

#### list Methods — Practical Examples

```python
# append — single item O(1) amortized
lst = [1, 2, 3]
lst.append(4)  # [1, 2, 3, 4]

# extend — batch add O(n) for n items (faster than loop + append)
lst = [1, 2, 3]
lst.extend([4, 5, 6])  # [1, 2, 3, 4, 5, 6]
# NOT lst.append([4, 5, 6]) which gives [1, 2, 3, [4, 5, 6]]

# insert — O(n) because shifts elements
lst = [1, 2, 4, 5]
lst.insert(2, 3)  # [1, 2, 3, 4, 5] — shifts [4,5] right

# remove — O(n) linear scan, removes FIRST occurrence
lst = [1, 2, 3, 2, 4]
lst.remove(2)  # [1, 3, 2, 4] — only first 2 removed

# pop — O(1) from end, O(n) from front
lst = [1, 2, 3, 4, 5]
lst.pop()      # 5, list is [1, 2, 3, 4] — O(1)
lst.pop(0)     # 1, list is [2, 3, 4] — O(n) shift all left
lst.pop(1)     # 3, list is [2, 4] — O(n)

# clear — delete all O(n)
lst = [1, 2, 3]
lst.clear()  # [] — same as lst[:] = [] but clearer intent

# index — find position O(n) linear scan
lst = [10, 20, 30, 40]
lst.index(30)  # 2
lst.index(30, 2, 4)  # 2 — search between indices 2 and 4
# lst.index(99)  # ValueError if not found

# count — count occurrences O(n)
lst = [1, 2, 1, 3, 1, 4]
lst.count(1)  # 3
lst.count(99)  # 0

# sort — Timsort O(n log n), stable, in-place
lst = [3, 1, 4, 1, 5, 9]
lst.sort()  # [1, 1, 3, 4, 5, 9]
lst.sort(reverse=True)  # [9, 5, 4, 3, 1, 1]

# sort with key — complex sorting
records = [{"id": 1, "score": 90}, {"id": 2, "score": 85}]
records.sort(key=lambda r: r["score"], reverse=True)
# Sort by multiple fields (tuple key)
records.sort(key=lambda r: (-r["score"], r["id"]))  # score desc, then id asc

# reverse — O(n) in-place
lst = [1, 2, 3, 4]
lst.reverse()  # [4, 3, 2, 1]
# Don't use: lst = lst[::-1] (creates new list)

# copy — shallow copy O(n)
original = [1, 2, [3, 4]]
shallow = original.copy()
shallow[2].append(5)  # mutates original[2] too (nested list shared)
# Use copy.deepcopy for nested structures
```

---

## dict

### How It Works

Hash map under the hood. As of Python 3.7+, insertion order is preserved (guaranteed spec).

```python
d = {"key": "value"}
d["key"]           # O(1) average — hash lookup
d.get("key", 0)    # safe access with default — never KeyError
d.setdefault("key", []).append(1)  # initialize if missing

# Merging dicts
a = {"x": 1}
b = {"y": 2}
merged = {**a, **b}    # Python 3.5+
merged = a | b         # Python 3.9+  — preferred
a |= b                 # in-place merge
```

### Common DE Patterns

```python
# Counting — collections.Counter is better but dict works
freq = {}
for item in items:
    freq[item] = freq.get(item, 0) + 1

# Grouping records
from collections import defaultdict
groups = defaultdict(list)
for row in rows:
    groups[row["region"]].append(row)

# Lookup table (replaces long if/elif chains)
STATUS_MAP = {"A": "active", "I": "inactive", "D": "deleted"}
status = STATUS_MAP.get(raw_status, "unknown")

# Dict comprehension from two lists
headers = ["id", "name", "amount"]
values  = [1, "alice", 99.5]
row = dict(zip(headers, values))
# or: {h: v for h, v in zip(headers, values)}
```

### Deep Copy Trap with Nested Dicts

```python
import copy
config = {"retries": 3, "tags": ["prod"]}

shallow = config.copy()
shallow["tags"].append("us-east-1")  # mutates config["tags"] too!

deep = copy.deepcopy(config)
deep["tags"].append("eu-west-1")     # isolated — config unchanged
```

### dict Methods (Essential for DE)

| Method | Signature | Time Complexity | Use Case |
|---|---|---|---|
| `get(key, [default])` | `d.get("key", None)` | O(1) avg | Safe access with default |
| `keys()` | `d.keys()` | O(1) to create view | Get all keys as view |
| `values()` | `d.values()` | O(1) to create view | Get all values as view |
| `items()` | `d.items()` | O(1) to create view | Get key-value pairs as view |
| `pop(key, [default])` | `d.pop("key", None)` | O(1) avg | Remove and return value |
| `popitem()` | `d.popitem()` | O(1) | Remove and return last LIFO pair |
| `clear()` | `d.clear()` | O(n) | Delete all items |
| `update(other)` | `d.update({"x": 2})` | O(n) | Add/merge items from another dict |
| `setdefault(key, [default])` | `d.setdefault("k", [])` | O(1) avg | Get value or set default if missing |
| `copy()` | `d.copy()` | O(n) | Shallow copy |
| `fromkeys(iterable, [value])` | `dict.fromkeys([1,2,3], 0)` | O(n) | Create dict from keys |

#### dict Methods — Practical Examples

```python
# get — safe access O(1) average
d = {"name": "alice", "age": 30}
d.get("name")      # "alice"
d.get("email")     # None
d.get("email", "N/A")  # "N/A"
# Avoid d["email"] which raises KeyError

# Direct access vs get
# BAD: if d["status"]: raise KeyError if not present
# GOOD: if d.get("status"): safe, None is falsy

# keys, values, items — view objects (not lists, but iterable)
d = {"a": 1, "b": 2, "c": 3}
d.keys()    # dict_keys(['a', 'b', 'c']) — memory efficient, dynamic
d.values()  # dict_values([1, 2, 3])
d.items()   # dict_items([('a', 1), ('b', 2), ('c', 3)])

# Iterate over views efficiently (don't create intermediate lists)
for key in d.keys():           # efficient
    process(d[key])

for key, value in d.items():   # efficient
    process(key, value)

# NOT: for key in list(d.keys()):  # unnecessary conversion

# pop — remove and return O(1) average
d = {"a": 1, "b": 2, "c": 3}
val = d.pop("b")       # 2, dict is now {"a": 1, "c": 3}
val = d.pop("z", -1)   # -1 (default), no KeyError

# pop without default raises KeyError
# d.pop("missing")  # KeyError

# popitem — LIFO removal O(1)
d = {"a": 1, "b": 2, "c": 3}
key, val = d.popitem()  # ("c", 3) — removes last inserted
# Useful for cache eviction, processing queue

# clear — delete all O(n)
d.clear()  # {}

# update — merge dicts O(n)
d1 = {"a": 1, "b": 2}
d2 = {"b": 22, "c": 3}
d1.update(d2)  # d1 is now {"a": 1, "b": 22, "c": 3}
# d2 values override d1 on key collision

# setdefault — initialize if missing O(1) average
# Very useful in DE for grouping
d = {}
d.setdefault("region_US", []).append(row1)
d.setdefault("region_US", []).append(row2)
# Result: {"region_US": [row1, row2]}

# More efficient than:
# if "region_US" not in d:
#     d["region_US"] = []
# d["region_US"].append(row1)

# copy — shallow copy O(n)
original = {"a": 1, "b": [2, 3]}
shallow = original.copy()
shallow["b"].append(4)  # mutates original["b"] too (nested list shared)

# fromkeys — create dict from keys O(n)
keys = ["a", "b", "c"]
d = dict.fromkeys(keys, 0)  # {"a": 0, "b": 0, "c": 0}
# Useful for initializing accumulator dictionaries

# All values share same reference (important!)
d = dict.fromkeys(["a", "b"], [])
d["a"].append(1)
print(d)  # {"a": [1], "b": [1]} — both share same list!
# FIX: d = {k: [] for k in keys}
```

---

## tuple

### When to Use

- Immutable sequences — safe as dict keys, set members
- Returning multiple values from a function
- Named fixed-position records (namedtuple for readability)
- Slightly faster than list for iteration (no mutation overhead)

```python
# Unpacking — pythonic and clear
x, y, z = (1, 2, 3)
first, *rest = (1, 2, 3, 4)   # first=1, rest=[2, 3, 4]
*init, last = (1, 2, 3, 4)    # init=[1, 2, 3], last=4

# Function returning multiple values
def get_stats(data):
    return min(data), max(data), sum(data) / len(data)

lo, hi, avg = get_stats([1, 2, 3, 4, 5])

# namedtuple — tuple with field names
from collections import namedtuple
Point = namedtuple("Point", ["x", "y"])
p = Point(x=3, y=4)
p.x     # 3
p._asdict()  # OrderedDict
```

### tuple Methods (Limited)

Tuples are immutable, so they have minimal methods:

| Method | Signature | Time Complexity | Use Case |
|---|---|---|---|
| `index(x)` | `tpl.index(item, [start, end])` | O(n) | Find index of first occurrence |
| `count(x)` | `tpl.count(item)` | O(n) | Count occurrences of item |

#### tuple Methods — Practical Examples

```python
# index — find position O(n)
tpl = (10, 20, 30, 40)
tpl.index(30)  # 2
tpl.index(30, 2, 4)  # 2 — search in range
# tpl.index(99)  # ValueError if not found

# count — count occurrences O(n)
tpl = (1, 2, 1, 3, 1, 4)
tpl.count(1)  # 3
tpl.count(99)  # 0

# No sort, reverse, append, etc. — use tuple() to convert if needed
tpl = (3, 1, 2)
sorted_tpl = tuple(sorted(tpl))  # (1, 2, 3)
reversed_tpl = tuple(reversed(tpl))  # (2, 1, 3)
```

---

## set

### How It Works

Hash set — same hash table as dict, stores only keys, no duplicates, no order.

```python
s = {1, 2, 3}
s.add(4)
s.discard(99)  # no error if missing (vs remove() which raises KeyError)

# Set operations — essential for DE reconciliation work
a = {1, 2, 3, 4}
b = {3, 4, 5, 6}

a & b    # {3, 4}        — intersection: rows in both
a | b    # {1,2,3,4,5,6} — union: all rows
a - b    # {1, 2}        — difference: in a not b (source-only rows)
b - a    # {5, 6}        — difference: in b not a (target-only rows)
a ^ b    # {1,2,5,6}     — symmetric difference: not in both

# Deduplication while preserving order (Python 3.7+)
seen = set()
unique = [x for x in items if not (x in seen or seen.add(x))]
```

### set Methods (Essential for Data Reconciliation)

| Method | Signature | Time Complexity | Use Case |
|---|---|---|---|
| `add(x)` | `s.add(item)` | O(1) avg | Add single item |
| `remove(x)` | `s.remove(item)` | O(1) avg | Remove item (error if missing) |
| `discard(x)` | `s.discard(item)` | O(1) avg | Remove item (no error if missing) |
| `pop()` | `s.pop()` | O(1) avg | Remove and return arbitrary item |
| `clear()` | `s.clear()` | O(n) | Delete all items |
| `copy()` | `s.copy()` | O(n) | Shallow copy |
| `union(*others)` | `s.union(s2)` or `s \| s2` | O(len(s) + len(s2)) | All items in either set |
| `intersection(*others)` | `s.intersection(s2)` or `s & s2` | O(min(len(s), len(s2))) | Items in both sets |
| `difference(*others)` | `s.difference(s2)` or `s - s2` | O(len(s)) | Items in s but not in s2 |
| `symmetric_difference(other)` | `s.symmetric_difference(s2)` or `s ^ s2` | O(len(s) + len(s2)) | Items in either but not both |
| `issubset(other)` | `s.issubset(s2)` or `s <= s2` | O(len(s)) | Check if s is subset |
| `issuperset(other)` | `s.issuperset(s2)` or `s >= s2` | O(len(s2)) | Check if s is superset |
| `isdisjoint(other)` | `s.isdisjoint(s2)` | O(min(len(s), len(s2))) | Check if no common items |
| In-place variants | `s.update()`, `s.intersection_update()`, `s.difference_update()`, `s.symmetric_difference_update()` | O(n) | Modify set in-place |

#### set Methods — Practical Examples

```python
# add — insert single item O(1) average
s = {1, 2, 3}
s.add(4)  # {1, 2, 3, 4}
s.add(2)  # {1, 2, 3, 4} — duplicates ignored

# remove — delete item, error if missing O(1) average
s = {1, 2, 3}
s.remove(2)  # {1, 3}
# s.remove(99)  # KeyError

# discard — delete item, no error if missing O(1) average
s = {1, 2, 3}
s.discard(2)  # {1, 3}
s.discard(99)  # {1, 3} — no error (safer in loops)

# pop — remove arbitrary item O(1) average
s = {1, 2, 3}
item = s.pop()  # removes arbitrary item (order not guaranteed)
# {2, 3} (or could be any pair)

# clear — delete all O(n)
s.clear()  # set()

# copy — shallow copy O(n)
original = {1, 2, frozenset([3, 4])}
shallow = original.copy()

# union — combine sets O(len(s1) + len(s2))
s1 = {1, 2, 3}
s2 = {3, 4, 5}
s1.union(s2)  # {1, 2, 3, 4, 5}
s1 | s2       # same
s1 |= s2      # in-place union

# intersection — common items O(min(len(s1), len(s2)))
s1 = {1, 2, 3}
s2 = {3, 4, 5}
s1.intersection(s2)  # {3}
s1 & s2              # same
s1 &= s2             # in-place

# difference — in s1 not in s2 O(len(s1))
s1 = {1, 2, 3}
s2 = {3, 4, 5}
s1.difference(s2)  # {1, 2}
s1 - s2            # same
s1 -= s2           # in-place

# symmetric_difference — in either but not both O(len(s1) + len(s2))
s1 = {1, 2, 3}
s2 = {3, 4, 5}
s1.symmetric_difference(s2)  # {1, 2, 4, 5}
s1 ^ s2                       # same
s1 ^= s2                      # in-place

# issubset — s1 ⊆ s2 O(len(s1))
s1 = {1, 2}
s2 = {1, 2, 3}
s1.issubset(s2)  # True
s1 <= s2         # same
s1 < s2          # proper subset (strict)

# issuperset — s1 ⊇ s2 O(len(s2))
s1 = {1, 2, 3}
s2 = {1, 2}
s1.issuperset(s2)  # True
s1 >= s2           # same
s1 > s2            # proper superset (strict)

# isdisjoint — no common items O(min(len(s1), len(s2)))
s1 = {1, 2, 3}
s2 = {4, 5, 6}
s1.isdisjoint(s2)  # True — no overlap

s1 = {1, 2, 3}
s2 = {3, 4, 5}
s1.isdisjoint(s2)  # False — 3 is common

# Data reconciliation example using methods
source = {1, 2, 3, 4, 5}
target = {3, 4, 5, 6, 7}

missing_in_target = source - target  # {1, 2}
extra_in_target = target - source    # {6, 7}
common = source & target             # {3, 4, 5}
divergence = source ^ target         # {1, 2, 6, 7}

# Check if migration is complete
is_complete = source <= target  # False
is_complete = source == target  # False

# In-place operations for memory efficiency
s = {1, 2, 3}
s.update({4, 5})                        # s |= {4, 5}
s.intersection_update({2, 3, 4})        # s &= {2, 3, 4}
s.difference_update({2})                # s -= {2}
s.symmetric_difference_update({5, 6})   # s ^= {5, 6}
```

### frozenset — Immutable Set

```python
fs = frozenset({1, 2, 3})
# Can be used as dict key or set member
cache = {frozenset(cols): result for cols, result in computed}

# frozenset — immutable set, usable as dict key
fs = frozenset([1, 2, 3])

# All set operations work, return frozenset
result = fs & {2, 3, 4}  # frozenset({2, 3})

# Use as dict key
config_by_cols = {
    frozenset(["date", "region"]): "daily_regional_config",
    frozenset(["customer_id"]): "per_customer_config",
}

key = frozenset(["date", "region"])
config = config_by_cols[key]  # works

# frozenset from comprehension
fs = frozenset(x**2 for x in range(5))  # frozenset({0, 1, 4, 9, 16})
```

---

## collections Module — The Hidden Gems

```python
from collections import Counter, defaultdict, OrderedDict, deque, ChainMap

# Counter — frequency counting in one line
from collections import Counter
freq = Counter(["a", "b", "a", "c", "a"])  # Counter({'a': 3, 'b': 1, 'c': 1})
freq.most_common(2)   # [('a', 3), ('b', 1)]
freq["z"]             # 0, not KeyError

# Two Counters can be added/subtracted
daily = Counter({"clicks": 100, "views": 500})
weekly = daily * 7

# defaultdict — cleaner than dict.setdefault
from collections import defaultdict
inverted = defaultdict(set)
for word, doc_id in word_doc_pairs:
    inverted[word].add(doc_id)

# ChainMap — layered config (env overrides defaults)
from collections import ChainMap
defaults = {"timeout": 30, "retries": 3}
env_overrides = {"retries": 5}
config = ChainMap(env_overrides, defaults)
config["retries"]   # 5 — env takes priority
config["timeout"]   # 30 — falls through to defaults

# deque — O(1) append/pop from both ends (use for queues, sliding windows)
from collections import deque
dq = deque([1, 2, 3])
dq.appendleft(0)     # O(1) — efficient prepend
dq.popleft()         # O(1) — efficient pop from front
dq.extend([4, 5])    # O(n)
dq.maxlen = 100      # automatic eviction of oldest if > maxlen
```

---

## Advanced List Operations & Patterns

### Comprehensions & Generator Expressions

```python
# List comprehension — O(n) but more Pythonic and faster than loop + append
squares = [x**2 for x in range(1000)]

# With filter
evens = [x for x in items if x % 2 == 0]

# Nested comprehension — creates a flat list
flattened = [x for sublist in matrix for x in sublist]  # O(n*m)
# Same as: [x for sublist in [[1,2],[3,4]] for x in sublist] → [1,2,3,4]

# Dictionary from list comprehension
id_to_name = {row["id"]: row["name"] for row in records}

# Set comprehension — removes duplicates
unique_types = {row["type"] for row in records}

# Generator expression — lazy, memory efficient for large datasets
# Don't use parentheses like a tuple; no square brackets
gen = (x**2 for x in range(1000000))  # doesn't compute until iteration
for val in gen:
    if val > threshold:
        process(val)
```

### Performance-Critical List Patterns

```python
# Batch processing — avoid repeated reallocation
items = []
BATCH_SIZE = 1000
for row in big_dataset:
    items.append(process(row))
    if len(items) == BATCH_SIZE:
        write_to_storage(items)
        items = []  # reset
if items:
    write_to_storage(items)  # flush remainder

# Pre-allocation when size is known — avoids reallocation
result = [None] * 10000
for i, val in enumerate(expensive_iter):
    result[i] = val

# Using extend vs append for multiple items
# SLOW: appending one by one
for item in batch:
    result.append(item)  # O(n) amortized × m items = O(n*m)

# FAST: extend batches
result.extend(batch)  # O(m)

# Slicing creates a new list — use slice() for advanced patterns
sublist = items[100:200]  # new list, O(n)
# Gotcha: items[::1000000] on 1M items creates a huge list even for 1 element
```

### List Sorting & Stability

```python
# Timsort is stable — equal elements preserve relative order
records = [{"name": "alice", "score": 90}, {"name": "bob", "score": 90}]
records.sort(key=lambda r: r["score"])  # alice still before bob

# Multi-key sort using tuple keys
# Sort by region, then by score descending
records.sort(key=lambda r: (r["region"], -r["score"]))

# Using sorted() vs .sort()
sorted_items = sorted(items, reverse=True)  # returns new list
items.sort()  # in-place, None return
# sorted() works on any iterable; sort() only on lists

# heapq for partial sorting (top-k)
import heapq
top_10 = heapq.nlargest(10, records, key=lambda r: r["score"])  # O(n log k)
# Better than sort() when k << n
```

---

## Advanced Dict Operations & Patterns

### Performance-Critical Dict Patterns for DE

```python
# Accumulation — most common DE pattern
from collections import defaultdict

# Counting occurrences by dimension
daily_counts = defaultdict(int)
for event in events:
    daily_counts[(event["date"], event["region"])] += 1
# Result: {("2024-01-01", "US"): 500, ("2024-01-01", "EU"): 300, ...}

# Grouping records by key
from collections import defaultdict
groups = defaultdict(list)
for row in rows:
    groups[row["customer_id"]].append(row)
# Result: {customer_1: [row1, row2, ...], customer_2: [row3, ...], ...}

# Multi-level grouping (nested dicts)
nested = defaultdict(lambda: defaultdict(list))
for row in events:
    nested[row["region"]][row["date"]].append(row)

# Aggregation with statistics
from collections import defaultdict
stats = defaultdict(lambda: {"sum": 0, "count": 0, "min": float("inf"), "max": float("-inf")})
for order in orders:
    key = order["region"]
    stats[key]["sum"] += order["amount"]
    stats[key]["count"] += 1
    stats[key]["min"] = min(stats[key]["min"], order["amount"])
    stats[key]["max"] = max(stats[key]["max"], order["amount"])
# Calculate averages
for key in stats:
    stats[key]["avg"] = stats[key]["sum"] / stats[key]["count"] if stats[key]["count"] > 0 else 0
```

### Memory-Efficient Dict Patterns

```python
# Using dict.__slots__ in classes to reduce memory (not dict itself, but related)
class Event:
    __slots__ = ["timestamp", "user_id", "event_type"]  # fixed attrs, less memory per instance

# For large datasets, use dict.keys(), dict.values(), dict.items() as iterators
large_dict = {i: i**2 for i in range(1000000)}
for key in large_dict.keys():  # iterator, not list
    if should_process(key):
        process(large_dict[key])

# popitem() — LIFO in Python 3.7+, useful for cache eviction
cache = {"a": 1, "b": 2, "c": 3}
key, val = cache.popitem()  # removes ("c", 3), O(1)
# Use for LRU cache-like structures

# setdefault() with computation — efficient single-pass initialization
def compute_expensive():
    return [expensive_operation() for _ in range(100)]

cache = {}
result = cache.setdefault("key", compute_expensive())  # compute only if missing
# Note: always evaluates the default, so use defaultdict or manual check for lazy eval
```

### Dict Merge Patterns

```python
# Python 3.9+ — merge operator (recommended)
config = {**defaults, **env_overrides, **user_config}
# Priority: user_config > env_overrides > defaults

# In-place merge (Python 3.9+)
all_events = {}
all_events |= daily_events
all_events |= legacy_events

# Manual merge with conflict detection
def merge_with_conflict_check(d1, d2):
    conflicts = set(d1.keys()) & set(d2.keys())
    if conflicts:
        raise ValueError(f"Conflicting keys: {conflicts}")
    return {**d1, **d2}
```

---

## Advanced Tuple Patterns

### Tuple Unpacking in Enterprise Code

```python
# Flexible unpacking
a, b, c = (1, 2, 3)
first, *middle, last = (1, 2, 3, 4, 5)  # first=1, middle=[2,3,4], last=5
a, *_, z = range(100)  # a=0, z=99, ignore middle with _

# Swapping without temp variable
x, y = y, x  # creates tuple, unpacks

# Returning multiple values cleanly
def get_partition_stats(df):
    return (
        df["target"].min(),
        df["target"].max(),
        df["target"].mean(),
        len(df),
    )

min_val, max_val, mean_val, count = get_partition_stats(df)

# Destructuring in loops
for key, (min_val, max_val) in dimension_ranges.items():
    if value < min_val or value > max_val:
        flag_anomaly(key, value)
```

### namedtuple & dataclass for Readability

```python
from collections import namedtuple
from dataclasses import dataclass

# namedtuple — lightweight, immutable records
Event = namedtuple("Event", ["timestamp", "user_id", "event_type", "value"])
event = Event(timestamp="2024-01-01", user_id=123, event_type="click", value=1)
event.timestamp  # access by name, clearer than event[0]
event._asdict()  # convert to dict

# dataclass — more flexible (mutable by default, supports inheritance, methods)
@dataclass
class Event:
    timestamp: str
    user_id: int
    event_type: str
    value: float
    
    def is_significant(self):
        return self.value > 100

event = Event("2024-01-01", 123, "click", 150.5)
event.value = 200  # mutable, unlike namedtuple
```

---

## Advanced Set Operations & Patterns

### Set Operations for Data Reconciliation

```python
# Reconciliation — most common DE use case
source_ids = {1, 2, 3, 4, 5}
target_ids = {3, 4, 5, 6, 7}

# Missing in target (source-only)
missing = source_ids - target_ids  # {1, 2}

# Extra in target (target-only)
extra = target_ids - source_ids    # {6, 7}

# Common (should match if no transformation)
common = source_ids & target_ids   # {3, 4, 5}

# All unique across both
all_unique = source_ids | target_ids  # {1,2,3,4,5,6,7}

# Symmetric difference (not in both)
divergence = source_ids ^ target_ids  # {1, 2, 6, 7}

# Quality checks
reconciliation_report = {
    "missing_in_target": len(missing),
    "extra_in_target": len(extra),
    "coverage": len(common) / len(source_ids) * 100,
    "divergence_pct": len(divergence) / len(source_ids | target_ids) * 100,
}
```

### Set Operations for Membership Filtering

```python
# Efficient filtering — use set membership
ALLOWED_STATUSES = {"ACTIVE", "PENDING", "ON_HOLD"}
EXCLUDED_REGIONS = {"INTERNAL_TEST", "STAGING"}

# Filter records
valid_records = [r for r in records if r["status"] in ALLOWED_STATUSES]
production_records = [r for r in records if r["region"] not in EXCLUDED_REGIONS]

# Combining filters
valid_and_prod = [
    r for r in records 
    if r["status"] in ALLOWED_STATUSES 
    and r["region"] not in EXCLUDED_REGIONS
]
```

### frozenset for Immutable Collections

```python
# Use frozenset as dict key (sets are not hashable)
partition_configs = {
    frozenset(["date", "region"]): config_daily_regional,
    frozenset(["customer_id"]): config_per_customer,
}

key = frozenset(["date", "region"])
config = partition_configs[key]  # works because frozenset is hashable

# Comparing sets (find similar column sets in different tables)
cols_table_a = frozenset(["id", "name", "email", "created_at"])
cols_table_b = frozenset(["id", "name", "email", "updated_at"])
common_cols = cols_table_a & cols_table_b  # {"id", "name", "email"}
```

---

## Performance Comparison & Benchmarking

### When to Use Which Data Structure

```python
# Scenario 1: Frequent membership checks against large collection
# WRONG: items = [1, 2, 3, ..., 1000000]
#        if x in items:  # O(n) × millions of times = billions of ops
# RIGHT: items = {1, 2, 3, ..., 1000000}
#        if x in items:  # O(1) × millions = millions of ops

# Scenario 2: Insertion order matters, fast lookup
# Use dict (Python 3.7+) — O(1) insert, O(1) lookup, order preserved
event_by_id = {}
event_by_id[event_id] = event_data

# Scenario 3: Need to access by multiple keys
# Use multiple dicts or create a composite key
events_by_user = defaultdict(list)
events_by_timestamp = defaultdict(list)
for event in events:
    events_by_user[event["user_id"]].append(event)
    events_by_timestamp[event["ts"]].append(event)

# Scenario 4: Immutable configuration or hashable collection
# Use tuple or frozenset
config = (host, port, timeout)  # can be dict key
enabled_features = frozenset(["feature_a", "feature_b"])

# Scenario 5: FIFO queue or sliding window
# Use collections.deque, NOT list
from collections import deque
window = deque(maxlen=100)
window.append(new_value)  # auto-evicts oldest when full
```

### Rough Benchmark (Order of Magnitude)

```
Data Structure | Access | Insert | Delete | Membership Check | Iteration
---|---|---|---|---|---
list | O(1) | O(n) | O(n) | O(n) | O(n)
tuple | O(1) | N/A | N/A | O(n) | O(n)
dict | O(1) avg | O(1) avg | O(1) avg | O(1) avg | O(n)
set | N/A | O(1) avg | O(1) avg | O(1) avg | O(n)
deque | O(1) both ends | O(1) both ends | O(1) both ends | O(n) | O(n)

* "avg" = average case; worst case hash collisions can degrade to O(n)
* For 1M items, O(n) membership check on list ≈ 1M operations
           O(1) membership check on set ≈ 1 operation (1M× speedup)
```

---

## Common Enterprise Patterns

### Data Pipeline Patterns

```python
# Pattern 1: Batch aggregation
from collections import defaultdict

def aggregate_events(events, batch_size=10000):
    """Aggregate events by region and date."""
    aggregated = defaultdict(lambda: {"count": 0, "total_value": 0})
    
    for event in events:
        key = (event["date"], event["region"])
        aggregated[key]["count"] += 1
        aggregated[key]["total_value"] += event["value"]
    
    return dict(aggregated)

# Pattern 2: Deduplication with ranking
def deduplicate_keep_latest(records):
    """Keep only the latest record per key."""
    latest = {}
    for record in records:
        key = record["id"]
        if key not in latest or record["updated_at"] > latest[key]["updated_at"]:
            latest[key] = record
    return list(latest.values())

# Pattern 3: Slowly Changing Dimension (SCD Type 2)
def track_dimension_changes(old_records, new_records, key_cols):
    """Identify new, updated, and unchanged records."""
    from collections import defaultdict
    
    old_dict = {tuple(r[c] for c in key_cols): r for r in old_records}
    new_dict = {tuple(r[c] for c in key_cols): r for r in new_records}
    
    old_keys = set(old_dict.keys())
    new_keys = set(new_dict.keys())
    
    new = [new_dict[k] for k in new_keys - old_keys]  # inserts
    deleted = [old_dict[k] for k in old_keys - new_keys]  # deletes
    updated = [new_dict[k] for k in new_keys & old_keys if new_dict[k] != old_dict[k]]
    
    return {"new": new, "deleted": deleted, "updated": updated}

# Pattern 4: Windowed aggregation
from collections import deque
from datetime import datetime, timedelta

def windowed_aggregation(events, window_minutes=60):
    """Compute rolling aggregate over time windows."""
    results = []
    window = deque()
    window_end = datetime.now()
    
    for event in sorted(events, key=lambda e: e["timestamp"]):
        # Remove events outside window
        while window and window[0]["timestamp"] < window_end - timedelta(minutes=window_minutes):
            window.popleft()
        
        window.append(event)
        
        # Compute metric for current window
        results.append({
            "timestamp": event["timestamp"],
            "window_size": len(window),
            "window_sum": sum(e["value"] for e in window),
        })
    
    return results
```

---

## Thread Safety & Concurrency (Important for DE)

```python
# Python GIL makes individual dict/list operations thread-safe (but not compound ops)
# For thread-safe collections, use queue.Queue or threading.Lock

from queue import Queue
from threading import Lock
from collections import defaultdict

# Unsafe compound operation
counter = defaultdict(int)
counter[key] += 1  # NOT thread-safe (read-modify-write)

# Make it thread-safe
lock = Lock()
counter = defaultdict(int)
with lock:
    counter[key] += 1  # now atomic

# Better: use queue.Queue for thread-safe communication
from queue import Queue
task_queue = Queue()
task_queue.put(task)  # thread-safe
task = task_queue.get()  # blocks until available
```

---

## Interview Questions (Advanced)

**Q: You have 10M rows. Column A has 1000 unique values. You need to filter by Column A values from a client-supplied list of 500 allowed values. How do you structure this?**
A: Use a set for allowed values (O(1) lookup). `filtered = [r for r in rows if r["A"] in allowed_set]` is O(10M), not O(10M × 500) = O(5B).

**Q: What's the memory difference between `[1] * 1000000` and `{1}` repeated 1M times?**
A: List: ~8-9 MB (pointers to int objects). Set with 1 element: ~240 bytes (hash table with 1 entry). Sets don't duplicate the value.

**Q: Design a cache that evicts the least-recently-used item when full.**
A: Use `collections.OrderedDict()` (preserves insertion order) + manual eviction, or `functools.lru_cache` decorator. Modern: `from functools import cached_property`.

**Q: Given two 1M-row tables, find rows in Table A not in Table B (by primary key).**
A: Convert B's PKs to set: `b_keys = {row["pk"] for row in table_b}`. Filter: `missing = [r for r in table_a if r["pk"] not in b_keys]`. O(1M + 1M) not O(1M²).

**Q: Why would you use `defaultdict` over `dict.setdefault()` in a loop?**
A: `defaultdict` doesn't re-evaluate the factory on each access; `setdefault` checks every time. Cleaner code + less overhead.

---

## Interview Questions on Data Structures

**Q: Why is `in` O(1) for sets and O(n) for lists?**
Sets hash the element and look up a slot directly. Lists scan linearly.

**Q: Are Python dicts ordered?**
Yes, as of Python 3.7+ insertion order is preserved and guaranteed by the language spec.

**Q: What's the difference between `dict.get()` and `dict[]`?**
`dict[key]` raises `KeyError` on missing key. `dict.get(key, default)` returns the default (None if not provided).

**Q: When would you use a tuple over a list?**
When the data shouldn't change (configuration, DB column names, return values), as dict keys, or when you want to signal "this collection is fixed" to readers.

**Q: What's wrong with `freq = {}; freq[word] += 1`?**
Raises `KeyError` on first occurrence. Fix: `freq.get(word, 0) + 1` or `defaultdict(int)`.

**Q: You have 1M rows to process and need to check each against a 50K-item allowlist. How do you structure the allowlist?**
Convert to a `set`. `in` on a set is O(1) vs O(n) on a list. 50K-item list `in` check × 1M rows = 50B operations. Set version = 1M.
| `issuperset(other)` | `s.issuperset(s2)` or `s >= s2` | O(len(s2)) | Check if s is superset |
| `isdisjoint(other)` | `s.isdisjoint(s2)` | O(min(len(s), len(s2))) | Check if no common items |
| In-place variants | `s.update()`, `s.intersection_update()`, `s.difference_update()`, `s.symmetric_difference_update()` | O(n) | Modify set in-place |

### set Methods — Practical Examples

```python
# add — insert single item O(1) average
s = {1, 2, 3}
s.add(4)  # {1, 2, 3, 4}
s.add(2)  # {1, 2, 3, 4} — duplicates ignored

# remove — delete item, error if missing O(1) average
s = {1, 2, 3}
s.remove(2)  # {1, 3}
# s.remove(99)  # KeyError

# discard — delete item, no error if missing O(1) average
s = {1, 2, 3}
s.discard(2)  # {1, 3}
s.discard(99)  # {1, 3} — no error (safer in loops)

# pop — remove arbitrary item O(1) average
s = {1, 2, 3}
item = s.pop()  # removes arbitrary item (order not guaranteed)
# {2, 3} (or could be any pair)

# clear — delete all O(n)
s.clear()  # set()

# copy — shallow copy O(n)
original = {1, 2, {3, 4}}  # TypeError — sets can't contain mutable items
# But if had: original = {1, 2, frozenset([3, 4])}
shallow = original.copy()

# union — combine sets O(len(s1) + len(s2))
s1 = {1, 2, 3}
s2 = {3, 4, 5}
s1.union(s2)  # {1, 2, 3, 4, 5}
s1 | s2       # same
s1 |= s2      # in-place union

# intersection — common items O(min(len(s1), len(s2)))
s1 = {1, 2, 3}
s2 = {3, 4, 5}
s1.intersection(s2)  # {3}
s1 & s2              # same
s1 &= s2             # in-place

# difference — in s1 not in s2 O(len(s1))
s1 = {1, 2, 3}
s2 = {3, 4, 5}
s1.difference(s2)  # {1, 2}
s1 - s2            # same
s1 -= s2           # in-place

# symmetric_difference — in either but not both O(len(s1) + len(s2))
s1 = {1, 2, 3}
s2 = {3, 4, 5}
s1.symmetric_difference(s2)  # {1, 2, 4, 5}
s1 ^ s2                       # same
s1 ^= s2                      # in-place

# issubset — s1 ⊆ s2 O(len(s1))
s1 = {1, 2}
s2 = {1, 2, 3}
s1.issubset(s2)  # True
s1 <= s2         # same
s1 < s2          # proper subset (strict)

# issuperset — s1 ⊇ s2 O(len(s2))
s1 = {1, 2, 3}
s2 = {1, 2}
s1.issuperset(s2)  # True
s1 >= s2           # same
s1 > s2            # proper superset (strict)

# isdisjoint — no common items O(min(len(s1), len(s2)))
s1 = {1, 2, 3}
s2 = {4, 5, 6}
s1.isdisjoint(s2)  # True — no overlap

s1 = {1, 2, 3}
s2 = {3, 4, 5}
s1.isdisjoint(s2)  # False — 3 is common

# Data reconciliation example using methods
source = {1, 2, 3, 4, 5}
target = {3, 4, 5, 6, 7}

missing_in_target = source - target  # {1, 2}
extra_in_target = target - source    # {6, 7}
common = source & target             # {3, 4, 5}
divergence = source ^ target         # {1, 2, 6, 7}

# Check if migration is complete
is_complete = source <= target  # False
is_complete = source == target  # False

# In-place operations for memory efficiency
s = {1, 2, 3}
s.update({4, 5})                        # s |= {4, 5}
s.intersection_update({2, 3, 4})        # s &= {2, 3, 4}
s.difference_update({2})                # s -= {2}
s.symmetric_difference_update({5, 6})   # s ^= {5, 6}
```

---

## frozenset Methods

`frozenset` is immutable, so no add/remove methods. Only read operations:

| Method | Signature | Time Complexity | Use Case |
|---|---|---|---|
| `copy()` | `fs.copy()` | O(n) | Shallow copy |
| Set operations | `fs.union()`, `fs.intersection()`, etc. | Same as set | All return frozenset |

### frozenset Examples

```python
# frozenset — immutable set, usable as dict key
fs = frozenset([1, 2, 3])

# All set operations work, return frozenset
result = fs & {2, 3, 4}  # frozenset({2, 3})

# Use as dict key
config_by_cols = {
    frozenset(["date", "region"]): "daily_regional_config",
    frozenset(["customer_id"]): "per_customer_config",
}

key = frozenset(["date", "region"])
config = config_by_cols[key]  # works

# frozenset from comprehension
fs = frozenset(x**2 for x in range(5))  # frozenset({0, 1, 4, 9, 16})
```

---

## Quick Method Selection Guide

```python
# When do I use which method?

# LIST SELECTION
lst.append(x)        # → add single item to end
lst.extend(items)    # → add multiple items (faster than loop + append)
lst.insert(i, x)     # → add at specific position (slow for start)
lst.remove(x)        # → remove by value (only first occurrence)
lst.pop()            # → remove from end (O(1))
lst.pop(0)           # → remove from start (O(n), use deque instead)
lst.sort()           # → sort in-place
sorted(lst)          # → return sorted copy

# DICT SELECTION
d.get(key, default)  # → safe access (always do this, not d[key])
d.setdefault(k, [])  # → initialize if missing (use in grouping loops)
d.pop(key, default)  # → remove and get value
d.update(other)      # → merge with another dict
d.items()            # → iterate key-value pairs efficiently
d[key] = value       # → set value (only if key exists, or use setdefault)

# SET SELECTION FOR RECONCILIATION
s1 - s2              # → source-only rows (missing in target)
s2 - s1              # → target-only rows (extra in target)
s1 & s2              # → common rows
s1 | s2              # → all rows
s1 <= s2             # → is migration complete?
s1.isdisjoint(s2)    # → do two sources conflict?
```

---

## Performance Tips for Production Code

```python
# 1. Use extend() not repeated append() for batch inserts
# SLOW O(n*m)
result = []
for item in batch:
    result.append(item)

# FAST O(n)
result.extend(batch)

# 2. Use setdefault or defaultdict for grouping, not get() + if checks
# SLOW
groups = {}
for row in rows:
    if row["key"] not in groups:
        groups[row["key"]] = []
    groups[row["key"]].append(row)

# FAST
groups = defaultdict(list)
for row in rows:
    groups[row["key"]].append(row)

# 3. Use set for membership, not list
# SLOW O(n*m)
valid_ids = [1, 2, 3, ..., 50000]
for row in rows:  # 1M rows
    if row["id"] in valid_ids:  # O(50k) × 1M = 50B ops

# FAST O(n)
valid_ids = {1, 2, 3, ..., 50000}
for row in rows:
    if row["id"] in valid_ids:  # O(1) × 1M = 1M ops

# 4. Use dict.items() not dict.keys() if you need values
# SLOW — two lookups
for key in d.keys():
    value = d[key]  # extra lookup

# FAST — one pass
for key, value in d.items():
    process(key, value)

# 5. Avoid shallow copy pitfalls with nested structures
# WRONG — nested objects shared
original = {"data": [1, 2, 3]}
copy = original.copy()
copy["data"].append(4)  # mutates original too

# RIGHT
import copy
deep_copy = copy.deepcopy(original)
deep_copy["data"].append(4)  # original unchanged
```