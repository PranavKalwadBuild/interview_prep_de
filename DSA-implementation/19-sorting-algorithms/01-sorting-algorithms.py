"""
Sorting Algorithms — All Standard Implementations
===================================================
Implementations: Merge Sort, Quick Sort, Heap Sort, Counting Sort,
                 Dutch National Flag (3-way partition)

Each algorithm includes:
  - Clean implementation with inline comments
  - Time/space complexity
  - Stable/unstable note

Timing comparison at bottom uses n=10,000 random integers.

Quick reference:
  Merge Sort     — O(n log n), stable, O(n) space
  Quick Sort     — O(n log n) avg, in-place, NOT stable
  Heap Sort      — O(n log n), in-place, NOT stable
  Counting Sort  — O(n+k), stable, for bounded non-negative integers
  Dutch Flag     — O(n), for [0,1,2] arrays only
"""

import heapq
import random
import time
from typing import List


# ─────────────────────────────────────────────
# 1. MERGE SORT — stable, O(n log n), O(n) space
# ─────────────────────────────────────────────

def merge_sort(arr: List[int]) -> List[int]:
    """
    Stable divide-and-conquer sort.
    Creates new arrays (not in-place). Preferred for linked lists and external sort.

    Time : O(n log n) — all cases
    Space: O(n) auxiliary
    Stable: YES
    """
    if len(arr) <= 1:
        return arr[:]

    mid = len(arr) // 2
    left = merge_sort(arr[:mid])
    right = merge_sort(arr[mid:])

    return _merge(left, right)


def _merge(left: List[int], right: List[int]) -> List[int]:
    """Merge two sorted arrays."""
    result: List[int] = []
    i = j = 0
    while i < len(left) and j < len(right):
        # <= ensures stability: left element preferred when equal
        if left[i] <= right[j]:
            result.append(left[i]); i += 1
        else:
            result.append(right[j]); j += 1
    result.extend(left[i:])
    result.extend(right[j:])
    return result


# ─────────────────────────────────────────────
# 2. QUICK SORT — avg O(n log n), in-place, NOT stable
# ─────────────────────────────────────────────

def quick_sort(arr: List[int], lo: int = 0, hi: int = None) -> None:
    """
    In-place partition-based sort using Lomuto scheme with random pivot.
    Modifies arr in-place.

    Random pivot avoids O(n²) worst case on sorted/reverse-sorted input.

    Time : O(n log n) avg, O(n²) worst (rare with random pivot)
    Space: O(log n) stack
    Stable: NO
    """
    if hi is None:
        hi = len(arr) - 1

    if lo < hi:
        # Randomize pivot: swap random element to end before partitioning
        rand_idx = random.randint(lo, hi)
        arr[rand_idx], arr[hi] = arr[hi], arr[rand_idx]

        pivot_idx = _lomuto_partition(arr, lo, hi)
        quick_sort(arr, lo, pivot_idx - 1)
        quick_sort(arr, pivot_idx + 1, hi)


def _lomuto_partition(arr: List[int], lo: int, hi: int) -> int:
    """
    Lomuto partition scheme.
    Pivot = arr[hi]. After partition, pivot is at its final sorted position.
    Elements to its left are <= pivot; elements to its right are > pivot.
    Returns pivot's final index.
    """
    pivot = arr[hi]
    i = lo - 1   # right boundary of elements <= pivot

    for j in range(lo, hi):
        if arr[j] <= pivot:
            i += 1
            arr[i], arr[j] = arr[j], arr[i]

    # Place pivot at correct position
    arr[i + 1], arr[hi] = arr[hi], arr[i + 1]
    return i + 1


# ─────────────────────────────────────────────
# 3. HEAP SORT — O(n log n), in-place, NOT stable
# ─────────────────────────────────────────────

def heap_sort(arr: List[int]) -> None:
    """
    In-place heap sort using manual max-heap implementation.
    Modifies arr in-place.

    Time : O(n log n) — all cases
    Space: O(1) — true in-place
    Stable: NO

    Algorithm:
      1. Build max-heap in O(n): heapify from last non-leaf to root
      2. Extract max n times: swap arr[0] with arr[end], sift down, shrink heap
    """
    n = len(arr)

    # Build max-heap in-place
    for i in range(n // 2 - 1, -1, -1):
        _sift_down(arr, i, n)

    # Extract elements one by one: swap max to end, restore heap property
    for end in range(n - 1, 0, -1):
        arr[0], arr[end] = arr[end], arr[0]   # move current max to sorted position
        _sift_down(arr, 0, end)               # restore max-heap for remaining elements


def _sift_down(arr: List[int], root: int, end: int) -> None:
    """
    Sift down element at `root` in the max-heap defined by arr[0:end].
    Ensures the subtree rooted at `root` satisfies the max-heap property.
    """
    while True:
        largest = root
        left = 2 * root + 1
        right = 2 * root + 2

        if left < end and arr[left] > arr[largest]:
            largest = left
        if right < end and arr[right] > arr[largest]:
            largest = right

        if largest == root:
            break   # heap property satisfied

        arr[root], arr[largest] = arr[largest], arr[root]
        root = largest


# ─────────────────────────────────────────────
# 4. COUNTING SORT — O(n+k), stable, bounded non-negative integers
# ─────────────────────────────────────────────

def counting_sort(arr: List[int]) -> List[int]:
    """
    Counting sort for non-negative integers with bounded range.
    k = max(arr); O(n+k) time and space.

    Algorithm:
      1. Count occurrences of each value → count[v]
      2. Prefix sum → count[v] = number of elements <= v (final positions)
      3. Iterate arr in REVERSE (for stability) and place each element

    Time : O(n + k) where k = max value
    Space: O(n + k)
    Stable: YES

    NOT suitable for: floating point, negative numbers (without offset), large k
    """
    if not arr:
        return []

    max_val = max(arr)
    count = [0] * (max_val + 1)

    # Step 1: count occurrences
    for val in arr:
        count[val] += 1

    # Step 2: prefix sum (cumulative count = position after last occurrence)
    for i in range(1, len(count)):
        count[i] += count[i - 1]

    # Step 3: build output array (iterate in reverse for stability)
    output = [0] * len(arr)
    for val in reversed(arr):
        count[val] -= 1
        output[count[val]] = val

    return output


# ─────────────────────────────────────────────
# 5. DUTCH NATIONAL FLAG — O(n), one-pass, for [0,1,2] arrays
# ─────────────────────────────────────────────

def dutch_national_flag(arr: List[int]) -> None:
    """
    LeetCode 75 — Sort Colors (Dutch National Flag Problem)
    Sort an array containing only 0, 1, 2 in O(n) time, O(1) space, one pass.

    Three-pointer approach:
      lo  : boundary — everything before lo is 0
      mid : current element under examination
      hi  : boundary — everything after hi is 2

    Invariant:
      arr[0..lo-1]  = 0s  (sorted 0 section)
      arr[lo..mid-1] = 1s  (sorted 1 section)
      arr[mid..hi]  = unsorted
      arr[hi+1..n-1] = 2s  (sorted 2 section)

    Time : O(n)  Space: O(1)
    Stable: NO (relative order of equal elements not preserved)
    """
    lo, mid, hi = 0, 0, len(arr) - 1

    while mid <= hi:
        if arr[mid] == 0:
            arr[lo], arr[mid] = arr[mid], arr[lo]
            lo += 1
            mid += 1   # arr[lo..mid-1] is now confirmed 1, advance both
        elif arr[mid] == 1:
            mid += 1   # 1 is already in the middle zone
        else:          # arr[mid] == 2
            arr[mid], arr[hi] = arr[hi], arr[mid]
            hi -= 1    # DON'T advance mid — swapped element from hi is unexamined


# ─────────────────────────────────────────────
# TEST CASES
# ─────────────────────────────────────────────

def run_tests() -> None:
    test_cases = [
        [],
        [1],
        [2, 1],
        [5, 3, 1, 4, 2],
        [3, 3, 3],
        [1, 2, 3, 4, 5],       # already sorted
        [5, 4, 3, 2, 1],       # reverse sorted
        [random.randint(0, 100) for _ in range(50)],
    ]

    print("=== Correctness Tests ===\n")

    for tc in test_cases:
        expected = sorted(tc)

        # merge_sort
        assert merge_sort(tc) == expected, f"merge_sort failed on {tc}"

        # quick_sort
        qs = tc[:]
        quick_sort(qs)
        assert qs == expected, f"quick_sort failed on {tc}"

        # heap_sort
        hs = tc[:]
        heap_sort(hs)
        assert hs == expected, f"heap_sort failed on {tc}"

        # counting_sort (only non-negative integers)
        if all(x >= 0 for x in tc):
            assert counting_sort(tc) == expected, f"counting_sort failed on {tc}"

    print("merge_sort:     PASS")
    print("quick_sort:     PASS")
    print("heap_sort:      PASS")
    print("counting_sort:  PASS")

    # dutch_national_flag — only [0,1,2]
    dnf_cases = [
        [2, 0, 2, 1, 1, 0],
        [2, 0, 1],
        [0],
        [1, 0, 2, 0, 1],
        [],
    ]
    for tc in dnf_cases:
        arr = tc[:]
        dutch_national_flag(arr)
        assert arr == sorted(tc), f"dutch_national_flag failed on {tc}"
    print("dutch_national_flag: PASS")


# ─────────────────────────────────────────────
# TIMING COMPARISON
# ─────────────────────────────────────────────

def timing_comparison(n: int = 10_000) -> None:
    """Compare wall-clock time of each sort on n random integers."""
    base = [random.randint(0, n) for _ in range(n)]

    algorithms = {
        "merge_sort":    lambda a: merge_sort(a),
        "quick_sort":    lambda a: (quick_sort(a), a)[1],
        "heap_sort":     lambda a: (heap_sort(a), a)[1],
        "counting_sort": lambda a: counting_sort(a),
        "python_timsort": lambda a: sorted(a),
    }

    print(f"\n=== Timing Comparison (n={n:,}) ===\n")
    results = {}

    for name, sort_fn in algorithms.items():
        arr = base[:]
        start = time.time()
        sort_fn(arr)
        elapsed = time.time() - start
        results[name] = elapsed
        print(f"  {name:<20}: {elapsed * 1000:.2f} ms")

    fastest = min(results, key=results.get)
    print(f"\n  Fastest: {fastest}")
    print("\nNote: Python's Timsort is highly optimized C code — pure-Python")
    print("      implementations will always be significantly slower.")


# ─────────────────────────────────────────────
# MAIN
# ─────────────────────────────────────────────

if __name__ == '__main__':
    run_tests()
    timing_comparison(n=10_000)
