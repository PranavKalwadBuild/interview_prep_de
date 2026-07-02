# DSA Interview Patterns — Master Index

Pattern-first DSA reference following the Grokking Coding Interview curriculum. Each file: recognition keywords → boilerplate → 1 canonical + 4-5 variations.

---

## Section 1 — Pattern File Index

| # | Pattern | File | Key Recognition Words |
|---|---------|------|-----------------------|
| 01 | Sliding Window | [01-sliding-window.md](01-sliding-window.md) | subarray, substring, window of k, contiguous, longest without |
| 02 | Two Pointers | [02-two-pointers.md](02-two-pointers.md) | sorted array, pair sum, triplet, palindrome, remove duplicates |
| 03 | Fast & Slow Pointers | [03-fast-slow-pointers.md](03-fast-slow-pointers.md) | linked list cycle, find middle, happy number |
| 04 | Merge Intervals | [04-merge-intervals.md](04-merge-intervals.md) | overlapping intervals, meeting rooms, minimum platforms |
| 05 | Cyclic Sort | [05-cyclic-sort.md](05-cyclic-sort.md) | numbers in range 1..n, missing number, find duplicate |
| 06 | Linked List Reversal | [06-linked-list-reversal.md](06-linked-list-reversal.md) | reverse sublist, reverse k-group, rotate list |
| 07 | Tree BFS | [07-tree-bfs.md](07-tree-bfs.md) | level order, zigzag, minimum depth, right view |
| 08 | Tree DFS | [08-tree-dfs.md](08-tree-dfs.md) | path sum, root-to-leaf paths, diameter, count paths |
| 09 | Two Heaps | [09-two-heaps.md](09-two-heaps.md) | median of stream, sliding window median, IPO |
| 10 | Subsets / Backtracking | [10-subsets-backtracking.md](10-subsets-backtracking.md) | all subsets, all permutations, generate parentheses |
| 11 | Binary Search | 11-binary-search.md | sorted array, rotated array, peak, binary search on answer |
| 12 | Top K Elements | 12-top-k-elements.md | kth largest, top k frequent, k closest |
| 13 | K-way Merge | 13-k-way-merge.md | k sorted lists, merge k sorted, kth from k sorted |
| 14 | Dynamic Programming | [14-dynamic-programming.md](14-dynamic-programming.md) | min/max ways, count ways, is it possible, longest |
| 15 | Topological Sort | 15-topological-sort.md | dependencies, prerequisites, build order, alien dict |
| 16 | Graph BFS/DFS | 16-graph-bfs-dfs.md | number of islands, shortest path, connected components |
| 17 | Greedy | 17-greedy.md | jump game, minimum intervals to remove, gas station |
| 18 | Recursion | 18-recursion.md | divide and conquer, merge sort, fast power |
| 19 | Sorting Algorithms | 19-sorting-algorithms.md | merge sort, quick sort, heap sort, counting sort |

> Files 11–13, 15–19 are implemented in `../DSA-implementation/` but pattern notes not yet written — see implementation files for inline comments.

---

## Section 2 — "Which Pattern?" Decision Flowchart

Work through the questions in order. Stop at the first match.

1. Does the problem involve a **linked list**?
   - Detect a cycle / find middle → **Fast & Slow Pointers** (`03`)
   - Reverse it (fully or partially) → **Linked List Reversal** (`06`)

2. Does the problem involve a **tree**?
   - Level-by-level, minimum depth, right view → **Tree BFS** (`07`)
   - Path sum, root-to-leaf paths, diameter, count paths → **Tree DFS** (`08`)

3. Does the problem involve an **array or string with a contiguous region**?
   - Contiguous window (max sum, longest substring) → **Sliding Window** (`01`)
   - Two indices moving toward each other (pair sum, palindrome) → **Two Pointers** (`02`)

4. Does the problem involve **intervals `[start, end]`**?
   → **Merge Intervals** (`04`)

5. Does the problem say **"numbers in range 1..n"** or ask for missing / duplicate?
   → **Cyclic Sort** (`05`)

6. Does the problem involve **k sorted lists or arrays**?
   → **K-way Merge** (`13`)

7. Does the problem ask for **"kth largest / smallest / most frequent"**?
   → **Top K Elements** (heap) (`12`)

8. Does the problem ask for **minimum or maximum** with **choices** at each step?
   - Overlapping subproblems / optimal substructure → **Dynamic Programming** (`14`)
   - Local optimal always yields global optimal → **Greedy** (`17`)

9. Does the problem ask for **all subsets / permutations / combinations**?
   → **Subsets / Backtracking** (`10`)

10. Does the problem involve **dependencies or ordering** (prerequisites, build order)?
    → **Topological Sort** (`15`)

11. Does the problem involve **graph traversal**?
    - Shortest path, minimum steps → **Graph BFS** (`16`)
    - Connectivity, number of islands, flood fill → **Graph DFS** (`16`)

12. Does the problem say **"sorted"** + **"find element or position"**?
    → **Binary Search** (`11`)

13. Does the problem say **"find median"** or **"balance two halves"**?
    → **Two Heaps** (`09`)

14. Nothing matched? Consider **Recursion / Divide & Conquer** (`18`) or review recognition words in Section 1.

---

## Section 3 — Complexity Cheat Sheet

| # | Pattern | Typical Time | Typical Space | Notes |
|---|---------|-------------|---------------|-------|
| 01 | Sliding Window | O(n) | O(1) or O(k) | O(k) space when storing window elements |
| 02 | Two Pointers | O(n) or O(n log n) | O(1) | Sort first if unsorted — adds O(n log n) |
| 03 | Fast & Slow Pointers | O(n) | O(1) | Constant space; no extra DS needed |
| 04 | Merge Intervals | O(n log n) | O(n) | Dominated by sort; output list is O(n) |
| 05 | Cyclic Sort | O(n) | O(1) | Despite nested loop, each element moves at most once |
| 06 | Linked List Reversal | O(n) | O(1) | In-place pointer manipulation |
| 07 | Tree BFS | O(n) | O(n) | Queue holds up to one full level (~n/2 nodes) |
| 08 | Tree DFS | O(n) | O(h) | h = height; O(n) worst case for skewed tree |
| 09 | Two Heaps | O(n log n) | O(n) | Each insert/remove is O(log n) |
| 10 | Subsets / Backtracking | O(n · 2^n) | O(n · 2^n) | Exponential — all subsets; permutations are O(n · n!) |
| 11 | Binary Search | O(log n) | O(1) | "Binary search on answer" is O(n log(range)) |
| 12 | Top K Elements | O(n log k) | O(k) | Min-heap of size k; better than full sort when k << n |
| 13 | K-way Merge | O(n log k) | O(k) | n total elements across k lists; heap size = k |
| 14 | Dynamic Programming | O(n²) typical | O(n) or O(n²) | Varies widely; 1D DP often reduces space to O(n) |
| 15 | Topological Sort | O(V + E) | O(V + E) | V = vertices, E = edges |
| 16 | Graph BFS/DFS | O(V + E) | O(V) | BFS queue / DFS stack / visited set each O(V) |
| 17 | Greedy | O(n log n) | O(1) or O(n) | Sort step dominates; selection itself is O(n) |
| 18 | Recursion | O(n log n) typical | O(log n) to O(n) | Call stack depth drives space; merge sort is O(n) |
| 19 | Sorting Algorithms | O(n log n) avg | O(n) or O(log n) | Quick sort O(n²) worst; counting sort O(n + k) |

---

## Section 4 — Problem Count by Pattern (Interview Frequency)

Approximate LeetCode problem counts, ranked by how often each pattern appears in real interviews.

| Rank | Pattern | Approx. LeetCode Problems | Interview Frequency |
|------|---------|--------------------------|---------------------|
| 1 | Dynamic Programming (`14`) | 600+ | Very High |
| 2 | Graph BFS/DFS (`16`) | 300+ | Very High |
| 3 | Binary Search (`11`) | 250+ | Very High |
| 4 | Tree DFS (`08`) | 200+ | High |
| 5 | Tree BFS (`07`) | 150+ | High |
| 6 | Sliding Window (`01`) | 100+ | High |
| 7 | Two Pointers (`02`) | 100+ | High |
| 8 | Subsets / Backtracking (`10`) | 100+ | High |
| 9 | Top K Elements (`12`) | 80+ | Medium-High |
| 10 | Topological Sort (`15`) | 60+ | Medium-High |
| 11 | Merge Intervals (`04`) | 50+ | Medium |
| 12 | Greedy (`17`) | 200+ | Medium |
| 13 | Linked List Reversal (`06`) | 40+ | Medium |
| 14 | K-way Merge (`13`) | 30+ | Medium |
| 15 | Fast & Slow Pointers (`03`) | 30+ | Medium |
| 16 | Two Heaps (`09`) | 20+ | Low-Medium |
| 17 | Recursion / D&C (`18`) | 50+ | Low-Medium |
| 18 | Cyclic Sort (`05`) | 15+ | Low |
| 19 | Sorting Algorithms (`19`) | 20+ | Low (theory) |

> DP and Graph dominate FAANG-style interviews. If time is limited, prioritize those two plus Binary Search and Trees.

---

## Section 5 — Reading Order

### Absolute Beginner
Get comfortable with the most common building blocks first:

```
01 Sliding Window → 02 Two Pointers → 11 Binary Search → 07 Tree BFS → 08 Tree DFS → 14 Dynamic Programming
```

### Interview in 1 Week
Cover the highest-frequency patterns in a week-long sprint:

```
01 Sliding Window → 02 Two Pointers → 04 Merge Intervals →
07 Tree BFS → 08 Tree DFS → 11 Binary Search →
12 Top K Elements → 14 Dynamic Programming → 16 Graph BFS/DFS
```

### Full Mastery
Work through all 19 patterns in order — each builds on prior concepts:

```
01 → 02 → 03 → 04 → 05 → 06 → 07 → 08 → 09 →
10 → 11 → 12 → 13 → 14 → 15 → 16 → 17 → 18 → 19
```

---

*See `../DSA-implementation/` for runnable Python code for every pattern.*
