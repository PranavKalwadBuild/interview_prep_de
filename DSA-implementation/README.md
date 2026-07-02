# DSA Pattern Implementations — Runnable Python

Runnable Python (`.py`) implementations for all 19 patterns in `../DSA-patterns/`. Each file: recognition signals docstring → boilerplate template → 1 canonical + 4-5 variations with test output.

---

## Run Any File

```bash
python DSA-implementation/01-sliding-window/01-sliding-window.py
```

All files are self-contained: running them prints expected output for every implemented problem directly to stdout. No external dependencies.

---

## Folder Map

| Folder | Patterns Implemented | Canonical Problem | Source Pattern |
|--------|---------------------|-------------------|----------------|
| `01-sliding-window/` | Max sum subarray, longest substring without repeat, smallest subarray with sum ≥ S | Maximum Sum Subarray of Size K | Sliding Window (`01`) |
| `02-two-pointers/` | Pair with target sum, remove duplicates, squaring sorted array, triplet sum to zero | Pair with Target Sum | Two Pointers (`02`) |
| `03-fast-slow-pointers/` | Linked list cycle detection, find cycle start, find middle, happy number | LinkedList Cycle Detection | Fast & Slow Pointers (`03`) |
| `04-merge-intervals/` | Merge overlapping, insert interval, intersection of lists, conflicting appointments | Merge Intervals | Merge Intervals (`04`) |
| `05-cyclic-sort/` | Cyclic sort, find missing number, find all missing, find duplicate, find corrupt pair | Cyclic Sort | Cyclic Sort (`05`) |
| `06-linked-list-reversal/` | Reverse a linked list, reverse a sub-list, reverse every k-group, rotate list | Reverse a LinkedList | Linked List Reversal (`06`) |
| `07-tree-bfs/` | Level order traversal, reverse level order, zigzag, level averages, min depth, right view | Binary Tree Level Order Traversal | Tree BFS (`07`) |
| `08-tree-dfs/` | Path sum, all paths, sum of path numbers, path with max sum, diameter | Binary Tree Path Sum | Tree DFS (`08`) |
| `09-two-heaps/` | Find median from data stream, sliding window median, maximize capital | Find the Median of a Number Stream | Two Heaps (`09`) |
| `10-subsets-backtracking/` | Subsets, subsets with duplicates, permutations, string permutations, generate parentheses | Subsets | Subsets / Backtracking (`10`) |
| `11-binary-search/` | Classic binary search, find in rotated array, find first/last position, peak element, search in infinite array | Binary Search | Binary Search (`11`) |
| `12-top-k-elements/` | Kth largest element, top k frequent numbers, k closest points, sort k-sorted array | Kth Smallest Number | Top K Elements (`12`) |
| `13-k-way-merge/` | Merge k sorted lists, kth smallest in m sorted lists, smallest range covering all lists | Merge K Sorted Lists | K-way Merge (`13`) |
| `14-dynamic-programming/` | 0/1 Knapsack, unbounded knapsack, longest common subsequence, longest increasing subsequence, coin change | 0/1 Knapsack | Dynamic Programming (`14`) |
| `15-topological-sort/` | Topological order, all tasks scheduling orders, alien dictionary, sequence reconstruction | Topological Sort of a Directed Graph | Topological Sort (`15`) |
| `16-graph-bfs-dfs/` | Number of islands, flood fill, shortest path in binary matrix, clone graph, word ladder | Number of Islands | Graph BFS/DFS (`16`) |
| `17-greedy/` | Jump game I & II, gas station, task scheduler, minimum number of arrows | Jump Game | Greedy (`17`) |
| `18-recursion/` | Merge sort, binary search recursive, fast power, tower of hanoi, generate all combos | Merge Sort | Recursion / Divide & Conquer (`18`) |
| `19-sorting-algorithms/` | Bubble sort, selection sort, insertion sort, merge sort, quick sort, heap sort, counting sort | Merge Sort | Sorting Algorithms (`19`) |

---

## Standard File Structure

Every implementation file follows this layout so you can navigate any file instantly:

```python
"""
Pattern: <Pattern Name>
Recognition signals:
  - <signal 1>
  - <signal 2>
  - <signal 3>
Time:  O(...)
Space: O(...)
"""

# ─── BOILERPLATE TEMPLATE ──────────────────────────────────────────────────────
#
#   def solve(arr, ...):
#       left, right = 0, 0          # <-- customize: window / pointer positions
#       result = ...                 # <-- customize: what you're accumulating
#
#       while right < len(arr):
#           # expand window / move pointer
#           # shrink / advance when condition violated
#           # update result
#           right += 1
#
#       return result
#
# ──────────────────────────────────────────────────────────────────────────────


# ─── 1. CANONICAL PROBLEM ─────────────────────────────────────────────────────

def solve_canonical(input_data):
    """Problem statement in one line."""
    ...

test_input = ...
print(f"Canonical: {solve_canonical(test_input)}")


# ─── 2. VARIATION 1 ───────────────────────────────────────────────────────────

def variation_1(input_data):
    """Variation description."""
    ...

print(f"Variation 1: {variation_1(test_input)}")


# ─── 3. VARIATION 2 ───────────────────────────────────────────────────────────
# ... and so on up to variation 4 or 5
```

---

## Key Data Structures

These are the Python building blocks that appear repeatedly across implementations:

| Import | Usage | Why |
|--------|-------|-----|
| `collections.deque` | BFS queue, sliding window | O(1) `popleft()` vs O(n) for list |
| `heapq` | Top K, Two Heaps, K-way Merge | Min-heap; negate values for max-heap |
| `collections.defaultdict(list)` | Graph adjacency list, grouping | No KeyError on first access |
| `functools.lru_cache` | Recursive DP memoization | Decorator; cache on function args |
| `collections.Counter` | Frequency maps, Top K frequent | One-liner frequency counting |
| `bisect` (`bisect_left`, `insort`) | Maintain sorted order, binary search | O(log n) search on sorted list |
| `collections.OrderedDict` | LRU Cache implementation | Maintains insertion order |

### Heap Patterns

```python
import heapq

# Min-heap (default)
heap = []
heapq.heappush(heap, val)
smallest = heapq.heappop(heap)

# Max-heap — negate to simulate
heapq.heappush(heap, -val)
largest = -heapq.heappop(heap)

# Heap of tuples — sorted by first element
heapq.heappush(heap, (priority, item))

# K-way merge — push (value, list_index, element_index)
heapq.heappush(heap, (lists[0][0], 0, 0))
```

---

## Complexity Quick Reference

| # | Pattern | Time | Space | Dominant Factor |
|---|---------|------|-------|-----------------|
| 01 | Sliding Window | O(n) | O(1) / O(k) | Single pass; O(k) if storing window |
| 02 | Two Pointers | O(n log n) | O(1) | Sort dominates; scan is O(n) |
| 03 | Fast & Slow Pointers | O(n) | O(1) | At most 2n steps to meet |
| 04 | Merge Intervals | O(n log n) | O(n) | Sort + linear merge pass |
| 05 | Cyclic Sort | O(n) | O(1) | Each element placed at most once |
| 06 | Linked List Reversal | O(n) | O(1) | In-place pointer swap |
| 07 | Tree BFS | O(n) | O(n) | Queue holds largest level (~n/2) |
| 08 | Tree DFS | O(n) | O(h) | Call stack = tree height |
| 09 | Two Heaps | O(n log n) | O(n) | n heap inserts, each O(log n) |
| 10 | Subsets / Backtracking | O(n · 2^n) | O(n · 2^n) | 2^n subsets; n! permutations |
| 11 | Binary Search | O(log n) | O(1) | Halve search space each step |
| 12 | Top K Elements | O(n log k) | O(k) | Heap capped at k; n insertions |
| 13 | K-way Merge | O(n log k) | O(k) | n elements total; heap size k |
| 14 | Dynamic Programming | O(n²) typical | O(n) / O(n²) | Subproblem table; often space-optimizable |
| 15 | Topological Sort | O(V + E) | O(V + E) | Visit every vertex and edge once |
| 16 | Graph BFS/DFS | O(V + E) | O(V) | Visited set + queue/stack |
| 17 | Greedy | O(n log n) | O(1) / O(n) | Sort + single greedy pass |
| 18 | Recursion / D&C | O(n log n) | O(log n) / O(n) | Log n levels; merge step is O(n) |
| 19 | Sorting Algorithms | O(n log n) avg | O(log n) / O(n) | Quick sort O(n²) worst; counting O(n+k) |

---

*Pattern notes and recognition keywords: `../DSA-patterns/00-index.md`*
