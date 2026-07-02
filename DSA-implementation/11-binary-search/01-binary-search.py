"""
Binary Search — DSA Pattern #11
================================
Apply binary search not just on sorted arrays but on answer spaces and rotated arrays.

BOILERPLATE TEMPLATES
---------------------

1. Standard Binary Search:
   lo, hi = 0, len(nums) - 1
   while lo <= hi:
       mid = lo + (hi - lo) // 2
       if nums[mid] == target: return mid
       elif nums[mid] < target: lo = mid + 1
       else: hi = mid - 1

2. Left-Boundary (First Occurrence):
   result = -1
   while lo <= hi:
       mid = lo + (hi - lo) // 2
       if nums[mid] == target: result = mid; hi = mid - 1
       elif nums[mid] < target: lo = mid + 1
       else: hi = mid - 1

3. Binary Search on Answer:
   lo, hi = min_possible, max_possible
   while lo <= hi:
       mid = lo + (hi - lo) // 2
       if is_feasible(mid): result = mid; hi = mid - 1
       else: lo = mid + 1
"""

from typing import List


# --------------------------------------------------------------------------- #
# 1. Canonical: Binary Search
# --------------------------------------------------------------------------- #

def binary_search(nums: List[int], target: int) -> int:
    """
    Return the index of target in sorted array nums, or -1 if not found.
    LeetCode 704.
    """
    lo, hi = 0, len(nums) - 1
    while lo <= hi:
        mid = lo + (hi - lo) // 2
        if nums[mid] == target:
            return mid
        elif nums[mid] < target:
            lo = mid + 1
        else:
            hi = mid - 1
    return -1


# --------------------------------------------------------------------------- #
# 2. Find First and Last Position of Element in Sorted Array
# --------------------------------------------------------------------------- #

def find_first_last_position(nums: List[int], target: int) -> List[int]:
    """
    Return [first_index, last_index] of target in sorted nums.
    Return [-1, -1] if target not found.
    LeetCode 34.

    Approach: left-boundary search + right-boundary search.
    """
    def left_boundary(nums, target):
        lo, hi = 0, len(nums) - 1
        result = -1
        while lo <= hi:
            mid = lo + (hi - lo) // 2
            if nums[mid] == target:
                result = mid
                hi = mid - 1   # keep going left to find first occurrence
            elif nums[mid] < target:
                lo = mid + 1
            else:
                hi = mid - 1
        return result

    def right_boundary(nums, target):
        lo, hi = 0, len(nums) - 1
        result = -1
        while lo <= hi:
            mid = lo + (hi - lo) // 2
            if nums[mid] == target:
                result = mid
                lo = mid + 1   # keep going right to find last occurrence
            elif nums[mid] < target:
                lo = mid + 1
            else:
                hi = mid - 1
        return result

    return [left_boundary(nums, target), right_boundary(nums, target)]


# --------------------------------------------------------------------------- #
# 3. Search in Rotated Sorted Array
# --------------------------------------------------------------------------- #

def search_rotated_array(nums: List[int], target: int) -> int:
    """
    Search for target in a rotated sorted array (no duplicates).
    Return index or -1.
    LeetCode 33.

    Approach: at each mid, one half is always sorted. Determine which half
    and check if target falls in it; discard the other half.
    """
    lo, hi = 0, len(nums) - 1
    while lo <= hi:
        mid = lo + (hi - lo) // 2
        if nums[mid] == target:
            return mid
        # Left half is sorted
        if nums[lo] <= nums[mid]:
            if nums[lo] <= target < nums[mid]:
                hi = mid - 1
            else:
                lo = mid + 1
        # Right half is sorted
        else:
            if nums[mid] < target <= nums[hi]:
                lo = mid + 1
            else:
                hi = mid - 1
    return -1


# --------------------------------------------------------------------------- #
# 4. Find Minimum in Rotated Sorted Array
# --------------------------------------------------------------------------- #

def find_minimum_rotated(nums: List[int]) -> int:
    """
    Find the minimum element in a rotated sorted array (no duplicates).
    LeetCode 153.

    Approach: if nums[mid] > nums[hi], minimum is in right half;
    otherwise it's in left half (including mid).
    Use lo < hi so loop exits with lo == hi == answer.
    """
    lo, hi = 0, len(nums) - 1
    while lo < hi:
        mid = lo + (hi - lo) // 2
        if nums[mid] > nums[hi]:
            lo = mid + 1        # min must be to the right of mid
        else:
            hi = mid            # mid could be the minimum; don't exclude it
    return nums[lo]


# --------------------------------------------------------------------------- #
# 5. Ship Within D Days (Binary Search on Answer)
# --------------------------------------------------------------------------- #

def ship_packages(weights: List[int], days: int) -> int:
    """
    Find minimum ship capacity to ship all packages within 'days' days.
    Packages must be shipped in order; each day's load <= capacity.
    LeetCode 1011.

    Approach: binary search on capacity.
    - lo = max(weights)  (must carry heaviest package)
    - hi = sum(weights)  (carry everything in one day)
    - Feasibility: simulate days needed with given capacity.
    """
    def can_ship(capacity: int) -> bool:
        days_needed, current_load = 1, 0
        for w in weights:
            if current_load + w > capacity:
                days_needed += 1
                current_load = 0
            current_load += w
        return days_needed <= days

    lo, hi = max(weights), sum(weights)
    result = hi
    while lo <= hi:
        mid = lo + (hi - lo) // 2
        if can_ship(mid):
            result = mid
            hi = mid - 1   # try smaller capacity
        else:
            lo = mid + 1
    return result


# --------------------------------------------------------------------------- #
# Tests
# --------------------------------------------------------------------------- #

if __name__ == "__main__":
    # 1. Binary Search
    print("=== Binary Search ===")
    print(binary_search([-1, 0, 3, 5, 9, 12], 9))   # 4
    print(binary_search([-1, 0, 3, 5, 9, 12], 2))   # -1
    print(binary_search([5], 5))                      # 0

    # 2. Find First and Last Position
    print("\n=== Find First and Last Position ===")
    print(find_first_last_position([5, 7, 7, 8, 8, 10], 8))   # [3, 4]
    print(find_first_last_position([5, 7, 7, 8, 8, 10], 6))   # [-1, -1]
    print(find_first_last_position([], 0))                     # [-1, -1]

    # 3. Search in Rotated Sorted Array
    print("\n=== Search in Rotated Sorted Array ===")
    print(search_rotated_array([4, 5, 6, 7, 0, 1, 2], 0))   # 4
    print(search_rotated_array([4, 5, 6, 7, 0, 1, 2], 3))   # -1
    print(search_rotated_array([1], 0))                       # -1

    # 4. Find Minimum in Rotated Sorted Array
    print("\n=== Find Minimum in Rotated Sorted Array ===")
    print(find_minimum_rotated([3, 4, 5, 1, 2]))   # 1
    print(find_minimum_rotated([4, 5, 6, 7, 0, 1, 2]))   # 0
    print(find_minimum_rotated([11, 13, 15, 17]))   # 11

    # 5. Ship Packages
    print("\n=== Ship Packages Within D Days ===")
    print(ship_packages([1, 2, 3, 4, 5, 6, 7, 8, 9, 10], 5))   # 15
    print(ship_packages([3, 2, 2, 4, 1, 4], 3))                  # 6
    print(ship_packages([1, 2, 3, 1, 1], 4))                     # 3
