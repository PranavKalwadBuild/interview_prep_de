# 18 — Recursion

## One-Line Summary
Break problem into identical smaller subproblems; define base case + recursive case.

## Recognition Keywords
- "divide and conquer"
- "merge sort" / "quick sort"
- "tree traversal" (inherently recursive)
- "calculate nth fibonacci/factorial"
- "generate all combinations/permutations" (+ backtracking)
- "tower of hanoi"
- "flatten nested structure"

**Key tell:** the problem can be defined in terms of itself on a smaller input.

## Templates

### Standard Recursion
```python
def solve(problem):
    # 1. Base case — smallest version with known answer
    if base_condition(problem):
        return base_answer

    # 2. Recursive case — reduce problem, combine results
    smaller = reduce(problem)
    result = combine(solve(smaller))
    return result
```

### Divide and Conquer
```python
def divide_and_conquer(arr, lo, hi):
    # Base case
    if lo >= hi:
        return

    # Divide
    mid = (lo + hi) // 2

    # Conquer
    left_result  = divide_and_conquer(arr, lo, mid)
    right_result = divide_and_conquer(arr, mid + 1, hi)

    # Combine
    return merge(left_result, right_result)
```

### Tail Recursion (accumulator pattern)
```python
def factorial_tail(n, acc=1):
    if n == 0:
        return acc
    return factorial_tail(n - 1, acc * n)   # result passed forward, not backward
```

### Memoization Add-on
```python
from functools import lru_cache

@lru_cache(maxsize=None)
def solve_memo(n):
    if n <= 1:
        return n
    return solve_memo(n - 1) + solve_memo(n - 2)
```

## Call Stack Intuition
Each recursive call pushes a **stack frame** containing local variables and the return address. For `merge_sort([3,1,2])`:
```
merge_sort([3,1,2])
  merge_sort([3])       → returns [3]
  merge_sort([1,2])
    merge_sort([1])     → returns [1]
    merge_sort([2])     → returns [2]
    merge([1],[2])      → returns [1,2]
  merge([3],[1,2])      → returns [1,2,3]
```

**Stack overflow risk**: Python default recursion limit is 1000. For n > ~10^4 without memoization or tail-call optimization, use iteration or increase limit with `sys.setrecursionlimit`.

## Complexity
- Depends on structure; use the **Master Theorem** for D&C recurrences
- T(n) = aT(n/b) + f(n): merge sort is T(n) = 2T(n/2) + O(n) → O(n log n)

## Canonical Problem: Merge Sort

```python
def merge_sort(arr):
    if len(arr) <= 1:
        return arr
    mid = len(arr) // 2
    left  = merge_sort(arr[:mid])
    right = merge_sort(arr[mid:])
    return merge(left, right)

def merge(left, right):
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

### Quick Sort — partition-based
Lomuto partition scheme: pick last element as pivot, place it at correct index in one pass.

### Power Function — fast exponentiation x^n in O(log n)
If n is even: x^n = (x^(n//2))^2; if odd: x^n = x * x^(n-1)

### Regular Expression Matching
Recursive definition with `.` (any char) and `*` (zero or more of preceding). Optimize with memoization via `@lru_cache`.

### Decode Ways
Number of ways to decode a digit string (1→A, ..., 26→Z). Recursive: at each position, try 1-digit and 2-digit decode if valid.

### Flatten Nested List Iterator
Recursively unwrap nested lists. Base: element is an integer → yield it. Recursive: element is a list → recurse.

## Gotchas
1. **Define base case first** — missing or wrong base case causes infinite recursion
2. **Python recursion limit**: `sys.setrecursionlimit(10**6)` for deep recursion; better to convert to iterative
3. **Tail recursion not optimized in Python**: CPython does not perform tail-call optimization — accumulator pattern still creates stack frames
4. **Mutable default arguments**: never use `def f(memo={})` — use `@lru_cache` or pass `None` and initialize inside
5. **Slicing creates copies**: `arr[:mid]` is O(n) and creates a new list — for performance, pass indices instead
