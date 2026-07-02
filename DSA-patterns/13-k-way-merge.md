# K-Way Merge

## One-Line Summary
Merge k sorted arrays/lists using a min-heap to efficiently track the global minimum.

## Recognition Keywords
- "k sorted arrays/lists"
- "merge k sorted linked lists"
- "find kth smallest from k sorted lists"
- "smallest range covering elements from k lists"
- **Key tell**: you have multiple sorted sequences; need to produce one sorted sequence or find global kth

## Template

### K-Way Merge (Array Version)
```python
import heapq

def k_way_merge(arrays):
    result = []
    min_heap = []

    # Push first element from each array: (value, array_idx, element_idx)
    for i, arr in enumerate(arrays):
        if arr:
            heapq.heappush(min_heap, (arr[0], i, 0))

    while min_heap:
        val, arr_idx, elem_idx = heapq.heappop(min_heap)
        result.append(val)
        next_idx = elem_idx + 1
        if next_idx < len(arrays[arr_idx]):
            heapq.heappush(min_heap, (arrays[arr_idx][next_idx], arr_idx, next_idx))

    return result
```

## Complexity
- **Time**: O(n log k) where n = total elements across all lists, k = number of lists
- **Space**: O(k) for the heap

## Canonical Problem
**Merge K Sorted Lists** — merge k sorted linked lists into one sorted linked list.

## Variations
| Problem | Twist |
|---|---|
| Kth Smallest in M Sorted Lists | Stop after k pops instead of draining heap |
| Smallest Range Covering Elements from K Lists | Track max in heap; range = (heap_min, current_max) |
| Find K Pairs with Smallest Sums | Two arrays; push (a[0]+b[j], 0, j) for all j initially, or expand row-wise |
| Merge K Sorted Arrays | Same as template above with index tracking |
| External Sort Simulation | How databases merge sorted runs from disk |

## Gotchas
- **Always push the next element from the same list** after popping — not from any list
- **Handle empty lists** before the first push to avoid index errors
- **Tie-breaking in heap tuple**: if values are equal, Python compares the next element in the tuple; store a tiebreaker (like list index) to avoid comparing incomparable objects (e.g., ListNode)
- For linked lists: store `(node.val, list_idx, node)` — use list_idx as tiebreaker so node is never compared
- Kth Smallest variant: count pops; return value on the kth pop
