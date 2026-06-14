<!-- python-patterns: Data Structures Deep Dive -->

# Data Structures Deep Dive

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

### frozenset — Immutable Set

```python
fs = frozenset({1, 2, 3})
# Can be used as dict key or set member
cache = {frozenset(cols): result for cols, result in computed}
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
```

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
