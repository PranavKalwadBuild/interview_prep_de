# Pattern 09: Two Heaps

## One-Line Summary

Maintain two heaps (max-heap for lower half, min-heap for upper half) to get median or balance two groups.

---

## Recognition Keywords

| Signal | Example Problem Phrasing |
|--------|--------------------------|
| "median of a stream" / "running median" | "Find the median after each insertion" |
| "find median from data stream" | "Design a class to add numbers and find median" |
| "sliding window median" | "Median of every k-size window in array" |
| "scheduling to maximize profit" | "Pick at most k tasks with profit constraints" |
| "maximize capital" / "IPO problem" | "Given projects with capital/profit, pick k to maximize wealth" |

### Key Tell

> You need to **repeatedly find the median** of a growing/sliding set, OR you need to **balance two groups** by some property (e.g., available vs. locked by capital constraint).

If the problem asks for a **rank-based statistic** (median = rank n/2) under dynamic inserts/deletes — Two Heaps.

---

## Template

```python
import heapq

class MedianFinder:
    def __init__(self):
        self.max_heap = []   # lower half — store negated for max-heap behavior
        self.min_heap = []   # upper half — standard min-heap

    def add_num(self, num):
        # Always push to max_heap first
        heapq.heappush(self.max_heap, -num)

        # Balance: top of max_heap must be <= top of min_heap
        if self.min_heap and (-self.max_heap[0]) > self.min_heap[0]:
            heapq.heappush(self.min_heap, -heapq.heappop(self.max_heap))

        # Size balance: max_heap can be at most 1 larger
        if len(self.max_heap) > len(self.min_heap) + 1:
            heapq.heappush(self.min_heap, -heapq.heappop(self.max_heap))
        elif len(self.min_heap) > len(self.max_heap):
            heapq.heappush(self.max_heap, -heapq.heappop(self.min_heap))

    def find_median(self):
        if len(self.max_heap) == len(self.min_heap):
            return (-self.max_heap[0] + self.min_heap[0]) / 2.0
        return float(-self.max_heap[0])
```

---

## Complexity

| Operation    | Complexity |
|--------------|------------|
| Insert       | O(log n)   |
| Find median  | O(1)       |
| Space        | O(n)       |

---

## Canonical Problem

**Find Median from Data Stream** — design a data structure that supports `add_num(int)` and `find_median()`.

```
add_num(3) → median = 3.0
add_num(1) → median = 2.0
add_num(5) → median = 3.0
add_num(4) → median = 3.5
```

---

## Variations

| Variation | Key Change from Canonical |
|-----------|--------------------------|
| **Sliding Window Median** | Must also remove elements leaving the window; use lazy deletion with a counter dict |
| **Maximize Capital / IPO** | Use min-heap on capital; unlock projects as capital grows; max-heap on profit to pick best |
| **Next Interval** | Two heaps: one on interval end, one on interval start; match greedily |
| **Scheduling Tasks (Least Interval)** | Count task frequencies; always schedule the most frequent remaining task; use max-heap |

---

## Gotchas

1. **Python only has min-heap** — simulate max-heap by negating values: push `-x`, peek at `-heap[0]`.

2. **Re-balancing rule** — `max_heap` can be at most 1 element larger than `min_heap`. Never the other way around. This ensures `find_median` is clean: if sizes differ, the median is the top of the larger heap; if equal, average the tops.

3. **Value-order invariant** — Every element in `max_heap` must be ≤ every element in `min_heap`. After each push, check and potentially swap tops.

4. **Sliding window removal** — Standard heaps do not support O(log n) arbitrary removal. Use lazy deletion: mark removed elements in a dict; when the top of a heap is a marked element, pop and discard it.

5. **IPO pattern** — Two separate heaps, not one. Heap 1: `(capital, profit)` sorted by capital (min-heap). Heap 2: `profit` of affordable projects (max-heap, negate). Repeat k times: move all affordable projects to heap 2, pick max profit.
