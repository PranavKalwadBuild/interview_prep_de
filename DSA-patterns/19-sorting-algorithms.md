# 19 — Sorting Algorithms

## One-Line Summary
Know the standard sorts, their trade-offs, and when to use each.

## Recognition Keywords
- "sort in-place"
- "stable sort needed"
- "nearly sorted input"
- "sort strings/objects"
- "external sort" (too large for memory)

## Comparison Table

| Algorithm      | Best       | Average    | Worst      | Space     | Stable | Notes                          |
|----------------|------------|------------|------------|-----------|--------|--------------------------------|
| Bubble Sort    | O(n)       | O(n²)      | O(n²)      | O(1)      | Yes    | Educational only               |
| Selection Sort | O(n²)      | O(n²)      | O(n²)      | O(1)      | No     | Minimum writes                 |
| Insertion Sort | O(n)       | O(n²)      | O(n²)      | O(1)      | Yes    | Best for nearly sorted         |
| Merge Sort     | O(n log n) | O(n log n) | O(n log n) | O(n)      | Yes    | External sort, linked lists    |
| Quick Sort     | O(n log n) | O(n log n) | O(n²)      | O(log n)  | No     | In-place, cache-friendly       |
| Heap Sort      | O(n log n) | O(n log n) | O(n log n) | O(1)      | No     | Guaranteed O(n log n)          |
| Counting Sort  | O(n+k)     | O(n+k)     | O(n+k)     | O(k)      | Yes    | Small integer range only       |
| Radix Sort     | O(nk)      | O(nk)      | O(nk)      | O(n+k)    | Yes    | String/integer digit sort      |

*k = range of values; n = number of elements*

## When to Use Which

| Situation                              | Best Choice          |
|----------------------------------------|----------------------|
| General purpose (Python default)       | Timsort (`.sort()`)  |
| Bounded integers (e.g., 0–1000)        | Counting Sort        |
| Linked list sort                       | Merge Sort           |
| In-place, average-case performance     | Quick Sort           |
| Guaranteed worst-case O(n log n)       | Heap Sort            |
| Nearly sorted input                    | Insertion Sort       |
| Sort strings by characters             | Radix Sort           |
| External sort (disk-based)             | Merge Sort           |

## Canonical Implementation: Merge Sort

```python
def merge_sort(arr):
    if len(arr) <= 1:
        return arr
    mid = len(arr) // 2
    left  = merge_sort(arr[:mid])
    right = merge_sort(arr[mid:])
    return _merge(left, right)

def _merge(left, right):
    result, i, j = [], 0, 0
    while i < len(left) and j < len(right):
        if left[i] <= right[j]:
            result.append(left[i]); i += 1
        else:
            result.append(right[j]); j += 1
    result.extend(left[i:])
    result.extend(right[j:])
    return result
```

## Variations

### Quick Sort
In-place with Lomuto partition (pivot = last element). Worst case O(n²) on sorted input — use random pivot in practice.

### Heap Sort
Build a max-heap in O(n), then repeatedly extract max in O(log n). Uses `heapq` module (min-heap — negate values for max-heap behavior).

### Counting Sort
For integers in range [0, k]: count occurrences, prefix-sum for positions, place elements in output array. O(n+k) time and space.

### Dutch National Flag
3-way partition of array containing only 0, 1, 2. One pass O(n) with three pointers: `lo`, `mid`, `hi`.

## Interview Context

- **Python `.sort()` and `sorted()`**: Timsort — O(n log n) stable sort (merge sort + insertion sort hybrid)
- **Key function**: `arr.sort(key=lambda x: x[1])` — sort by second element
- **Reverse sort**: `arr.sort(reverse=True)` or `sorted(arr, reverse=True)`
- **Custom comparator**: use `functools.cmp_to_key` when you need `cmp(a, b)` style comparison
  ```python
  import functools
  def cmp(a, b):
      return -1 if a < b else (1 if a > b else 0)
  arr.sort(key=functools.cmp_to_key(cmp))
  ```
- **Stability matters**: when sorting objects by one field that are already sorted by another — stable sort preserves secondary order

## Gotchas
1. **Quick sort worst case**: O(n²) on already-sorted input with fixed pivot — always use random pivot for production
2. **Counting sort requires non-negative bounded integers**: does not work for arbitrary values or floats
3. **Merge sort space**: O(n) auxiliary space — not suitable for memory-constrained environments
4. **Heap sort not cache-friendly**: poor cache performance compared to quick sort in practice despite same asymptotic complexity
5. **Python sort is not in-place for `sorted()`**: `sorted(arr)` returns a new list; `arr.sort()` sorts in-place
