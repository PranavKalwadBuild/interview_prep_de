# Top K Elements

## One-Line Summary
Use a min-heap of size k to efficiently find top-k largest/smallest/frequent elements.

## Recognition Keywords
- "kth largest element"
- "kth smallest element"
- "top k most frequent"
- "k closest points to origin"
- "k largest in a stream"
- "k-th largest in sorted matrix"
- "frequency-based selection"
- **Key tell**: "k" + "largest/smallest/frequent/closest"; you don't need ALL elements sorted, just top k

## Templates

### Min-Heap of Size K (Top K Largest)
```python
import heapq

def top_k_largest(nums, k):
    min_heap = []
    for num in nums:
        heapq.heappush(min_heap, num)
        if len(min_heap) > k:
            heapq.heappop(min_heap)   # evict smallest
    return list(min_heap)             # these are top k largest
```

### Max-Heap (Negate Values in Python)
```python
import heapq

def top_k_smallest(nums, k):
    max_heap = []
    for num in nums:
        heapq.heappush(max_heap, -num)
        if len(max_heap) > k:
            heapq.heappop(max_heap)
    return [-x for x in max_heap]
```

### QuickSelect (O(n) Average for Kth Largest)
```python
import random

def quickselect(nums, k):
    # Returns kth largest (1-indexed)
    def partition(lo, hi):
        pivot_idx = random.randint(lo, hi)
        nums[pivot_idx], nums[hi] = nums[hi], nums[pivot_idx]
        pivot = nums[hi]
        store = lo
        for i in range(lo, hi):
            if nums[i] >= pivot:   # descending for kth largest
                nums[store], nums[i] = nums[i], nums[store]
                store += 1
        nums[store], nums[hi] = nums[hi], nums[store]
        return store

    lo, hi = 0, len(nums) - 1
    while lo <= hi:
        p = partition(lo, hi)
        if p == k - 1:
            return nums[p]
        elif p < k - 1:
            lo = p + 1
        else:
            hi = p - 1
```

## Complexity
- **Heap approach**: O(n log k) time, O(k) space
- **QuickSelect**: O(n) average, O(n²) worst time; O(1) space

## Canonical Problem
**Kth Largest Element in Array** — find the kth largest element without full sort.

## Variations
| Problem | Twist |
|---|---|
| K Closest Points to Origin | Heap key = x²+y² (distance squared, no sqrt needed) |
| Top K Frequent Elements | Counter first, then heap on frequency |
| Sort Characters by Frequency | heapq with counts, rebuild string |
| Kth Smallest in a Sorted Matrix | Binary search on value OR min-heap with matrix traversal |
| Connect Ropes with Minimum Cost | Always pick 2 smallest — classic greedy with min-heap |

## Gotchas
- **Counter-intuitive**: use **min-heap** for "top k **largest**" (heap root is the smallest of the top-k; evict anything smaller)
- `heapq.nlargest(k, nums)` is O(n log k) — fine for one-shot but not streaming
- QuickSelect is **not stable** — does not preserve relative order of equal elements
- For tuples in heap: Python compares element by element; `(freq, val)` works; `(freq, obj)` may break if obj is not comparable — add a tiebreaker index
