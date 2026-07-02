"""
Recursion — Templates and Problems
=====================================
Pattern : Break problem into identical smaller subproblems.
          Define base case + recursive case.

Templates:
  - Standard recursion (base + recursive case)
  - Divide and conquer (split → recurse both → merge)
  - Tail recursion / accumulator pattern
  - Memoization via @lru_cache

Call stack note: Python default limit is 1000 frames.
                 Use sys.setrecursionlimit() or convert to iterative for deep recursion.
"""

import sys
from functools import lru_cache
from typing import List

sys.setrecursionlimit(10_000)


# ─────────────────────────────────────────────
# RECURSION TEMPLATES
# ─────────────────────────────────────────────

def standard_recursion_example(n: int) -> int:
    """Template: factorial using standard recursion."""
    # Base case
    if n <= 1:
        return 1
    # Recursive case: reduce problem, combine result
    return n * standard_recursion_example(n - 1)


def tail_recursion_example(n: int, acc: int = 1) -> int:
    """Template: factorial using accumulator (tail-recursive style)."""
    if n <= 1:
        return acc
    return tail_recursion_example(n - 1, acc * n)   # result flows forward


# ─────────────────────────────────────────────
# DIVIDE AND CONQUER TEMPLATE
# ─────────────────────────────────────────────

def divide_and_conquer_template(arr: List[int], lo: int, hi: int) -> List[int]:
    """
    Generic D&C skeleton — splits input, recurses both halves, merges.
    Concrete example: merge sort structure.
    """
    # Base case
    if lo >= hi:
        return [arr[lo]] if lo == hi else []

    # Divide
    mid = (lo + hi) // 2

    # Conquer
    left = divide_and_conquer_template(arr, lo, mid)
    right = divide_and_conquer_template(arr, mid + 1, hi)

    # Combine (placeholder — actual merge in merge_sort below)
    return left + right


# ─────────────────────────────────────────────
# PROBLEM 1: Merge Sort — canonical divide and conquer
# ─────────────────────────────────────────────

def merge_sort(arr: List[int]) -> List[int]:
    """
    Merge Sort — stable O(n log n) sort via divide and conquer.

    Recurrence: T(n) = 2T(n/2) + O(n) → O(n log n) by Master Theorem.

    Time: O(n log n)  Space: O(n) auxiliary
    """
    # Base case: single element or empty
    if len(arr) <= 1:
        return arr

    # Divide
    mid = len(arr) // 2
    left = merge_sort(arr[:mid])
    right = merge_sort(arr[mid:])

    # Conquer + combine
    return _merge(left, right)


def _merge(left: List[int], right: List[int]) -> List[int]:
    """Merge two sorted arrays into one sorted array."""
    result: List[int] = []
    i = j = 0
    while i < len(left) and j < len(right):
        if left[i] <= right[j]:
            result.append(left[i])
            i += 1
        else:
            result.append(right[j])
            j += 1
    result.extend(left[i:])
    result.extend(right[j:])
    return result


# ─────────────────────────────────────────────
# PROBLEM 2: Quick Sort — Lomuto partition scheme
# ─────────────────────────────────────────────

def quick_sort(arr: List[int], lo: int = 0, hi: int = None) -> None:
    """
    Quick Sort — in-place, average O(n log n), worst O(n²) on sorted input.
    Uses Lomuto partition: pivot = arr[hi].

    For production: randomize pivot to avoid worst-case on sorted input.

    Time: O(n log n) avg, O(n²) worst  Space: O(log n) stack
    """
    if hi is None:
        hi = len(arr) - 1

    if lo < hi:
        pivot_idx = _lomuto_partition(arr, lo, hi)
        quick_sort(arr, lo, pivot_idx - 1)
        quick_sort(arr, pivot_idx + 1, hi)


def _lomuto_partition(arr: List[int], lo: int, hi: int) -> int:
    """
    Lomuto partition: place pivot (arr[hi]) at its correct sorted position.
    Elements < pivot go left; elements >= pivot go right.
    Returns final pivot index.
    """
    pivot = arr[hi]
    i = lo - 1   # boundary of elements < pivot

    for j in range(lo, hi):
        if arr[j] <= pivot:
            i += 1
            arr[i], arr[j] = arr[j], arr[i]

    arr[i + 1], arr[hi] = arr[hi], arr[i + 1]
    return i + 1


# ─────────────────────────────────────────────
# PROBLEM 3: Fast Power — x^n in O(log n)
# ─────────────────────────────────────────────

def fast_power(x: float, n: int) -> float:
    """
    LeetCode 50 — Pow(x, n)
    Compute x^n in O(log n) using recursive fast exponentiation.

    Key recurrence:
      x^n = (x^(n//2))^2        if n is even
      x^n = x * (x^(n//2))^2   if n is odd
      x^(-n) = 1 / x^n

    Time: O(log n)  Space: O(log n) stack
    """
    def helper(base: float, exp: int) -> float:
        if exp == 0:
            return 1.0
        half = helper(base, exp // 2)
        if exp % 2 == 0:
            return half * half
        else:
            return base * half * half

    if n < 0:
        return 1.0 / helper(x, -n)
    return helper(x, n)


# ─────────────────────────────────────────────
# PROBLEM 4: Count Inversions — modified merge sort
# ─────────────────────────────────────────────

def count_inversions(arr: List[int]) -> int:
    """
    Count the number of inversions in arr: pairs (i, j) where i < j but arr[i] > arr[j].
    Classic application of modified merge sort.

    Key insight: during merge, whenever we pick from the right half (arr[j] < arr[i]),
                 all remaining elements in the left half form inversions with arr[j].

    Time: O(n log n)  Space: O(n)
    """
    def merge_count(arr: List[int]) -> tuple:
        if len(arr) <= 1:
            return arr, 0

        mid = len(arr) // 2
        left, left_inv = merge_count(arr[:mid])
        right, right_inv = merge_count(arr[mid:])

        merged = []
        inversions = left_inv + right_inv
        i = j = 0

        while i < len(left) and j < len(right):
            if left[i] <= right[j]:
                merged.append(left[i])
                i += 1
            else:
                # left[i..end] are all > right[j] — each is an inversion
                inversions += len(left) - i
                merged.append(right[j])
                j += 1

        merged.extend(left[i:])
        merged.extend(right[j:])
        return merged, inversions

    _, total_inversions = merge_count(arr)
    return total_inversions


# ─────────────────────────────────────────────
# PROBLEM 5: Decode Ways — recursive + memoization
# ─────────────────────────────────────────────

def decode_ways(s: str) -> int:
    """
    LeetCode 91 — Decode Ways
    A digit string can be decoded: '1'→A, '2'→B, ..., '26'→Z.
    Return the number of ways to decode the string.

    Recursive definition:
      ways(i) = ways(i+1)                         if s[i] is valid single digit
              + ways(i+2)                         if s[i:i+2] is valid two-digit (10-26)

    Memoized with @lru_cache for O(n) time.

    Time: O(n)  Space: O(n) memo + O(n) stack
    """
    n = len(s)

    @lru_cache(maxsize=None)
    def dp(i: int) -> int:
        # Base cases
        if i == n:
            return 1   # successfully decoded entire string
        if s[i] == '0':
            return 0   # leading zero — invalid

        # Single digit decode
        result = dp(i + 1)

        # Two digit decode
        if i + 1 < n:
            two_digit = int(s[i:i+2])
            if 10 <= two_digit <= 26:
                result += dp(i + 2)

        return result

    return dp(0)


# ─────────────────────────────────────────────
# TESTS
# ─────────────────────────────────────────────

if __name__ == '__main__':
    # merge_sort
    assert merge_sort([5, 3, 1, 4, 2]) == [1, 2, 3, 4, 5]
    assert merge_sort([]) == []
    assert merge_sort([1]) == [1]
    print("merge_sort: PASS")

    # quick_sort
    arr = [5, 3, 1, 4, 2]
    quick_sort(arr)
    assert arr == [1, 2, 3, 4, 5]
    arr2 = [1]
    quick_sort(arr2)
    assert arr2 == [1]
    print("quick_sort: PASS")

    # fast_power
    assert abs(fast_power(2.0, 10) - 1024.0) < 1e-9
    assert abs(fast_power(2.0, -2) - 0.25) < 1e-9
    assert abs(fast_power(2.0, 0) - 1.0) < 1e-9
    print("fast_power: PASS")

    # count_inversions
    assert count_inversions([2, 4, 1, 3, 5]) == 3   # (2,1),(4,1),(4,3)
    assert count_inversions([1, 2, 3, 4, 5]) == 0
    assert count_inversions([5, 4, 3, 2, 1]) == 10
    print("count_inversions: PASS")

    # decode_ways
    assert decode_ways("12") == 2    # "AB" or "L"
    assert decode_ways("226") == 3   # "BZ", "VF", "BBF"
    assert decode_ways("06") == 0    # leading zero
    assert decode_ways("10") == 1    # "J"
    print("decode_ways: PASS")

    print("\nAll recursion tests passed.")
