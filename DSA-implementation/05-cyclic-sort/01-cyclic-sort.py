"""
PATTERN: Cyclic Sort
====================
RECOGNITION SIGNALS:
  - Array contains integers in a bounded range (1..n or 0..n)
  - "find missing number", "find duplicate", "find all missing/duplicates"
  - "first missing positive"
  - Key tell: you can use the array index itself as the correct position for each value

CORE IDEA:
  Place each number at its correct index (nums[i] - 1 for 1-indexed range).
  Swap until every number is home, then scan for anomalies.

BOILERPLATE TEMPLATE:
  i = 0
  while i < len(nums):
      correct_idx = nums[i] - 1              # where this number belongs
      if nums[i] != nums[correct_idx]:       # value check — not index check!
          nums[i], nums[correct_idx] = nums[correct_idx], nums[i]
      else:
          i += 1

COMPLEXITY: O(n) time | O(1) space
"""


# ---------------------------------------------------------------------------
# PROBLEM 1: Find Missing Number
# Given an array of n distinct numbers in range [0, n], find the missing one.
# Example: [3, 0, 1] -> 2
# ---------------------------------------------------------------------------
def find_missing_number(nums):
    i = 0
    n = len(nums)
    while i < n:
        correct_idx = nums[i]               # range is [0..n], so no -1 offset
        if nums[i] < n and nums[i] != nums[correct_idx]:
            nums[i], nums[correct_idx] = nums[correct_idx], nums[i]
        else:
            i += 1
    # scan: first index where nums[i] != i is the missing number
    for i in range(n):
        if nums[i] != i:
            return i
    return n                                # missing number is n itself


# ---------------------------------------------------------------------------
# PROBLEM 2: Find All Missing Numbers
# Array of n integers in range [1, n]; some numbers appear twice, find all missing.
# Example: [2, 3, 1, 8, 2, 3, 5, 1] -> [4, 6, 7]
# ---------------------------------------------------------------------------
def find_all_missing_numbers(nums):
    i = 0
    n = len(nums)
    while i < n:
        correct_idx = nums[i] - 1           # 1-indexed: correct position is value - 1
        if nums[i] != nums[correct_idx]:
            nums[i], nums[correct_idx] = nums[correct_idx], nums[i]
        else:
            i += 1
    # every index where nums[i] != i+1 reveals a missing number
    missing = []
    for i in range(n):
        if nums[i] != i + 1:
            missing.append(i + 1)
    return missing


# ---------------------------------------------------------------------------
# PROBLEM 3: Find the Duplicate Number
# Array of n+1 integers in range [1, n]; exactly one number is duplicated.
# Example: [1, 4, 4, 3, 2] -> 4
# ---------------------------------------------------------------------------
def find_duplicate(nums):
    i = 0
    n = len(nums)
    while i < n:
        correct_idx = nums[i] - 1
        if nums[i] != i + 1:                # not yet in correct position
            if nums[i] != nums[correct_idx]:
                nums[i], nums[correct_idx] = nums[correct_idx], nums[i]
            else:
                return nums[i]              # duplicate found: same value at two positions
        else:
            i += 1
    return -1


# ---------------------------------------------------------------------------
# PROBLEM 4: Find All Duplicates
# Array of n integers in range [1, n]; each integer appears once or twice.
# Example: [3, 4, 4, 5, 5] -> [4, 5]
# ---------------------------------------------------------------------------
def find_all_duplicates(nums):
    i = 0
    n = len(nums)
    while i < n:
        correct_idx = nums[i] - 1
        if nums[i] != nums[correct_idx]:
            nums[i], nums[correct_idx] = nums[correct_idx], nums[i]
        else:
            i += 1
    # every index where nums[i] != i+1 means nums[i] is a duplicate
    duplicates = []
    for i in range(n):
        if nums[i] != i + 1:
            duplicates.append(nums[i])
    return duplicates


# ---------------------------------------------------------------------------
# PROBLEM 5: First Missing Positive
# Unsorted array; find the smallest missing positive integer.
# Example: [3, -3, 1, 5] -> 2
# GOTCHA: skip numbers <= 0 or > n (out of range for cyclic sort)
# ---------------------------------------------------------------------------
def first_missing_positive(nums):
    i = 0
    n = len(nums)
    while i < n:
        correct_idx = nums[i] - 1
        # only sort positives that fit in [1..n]
        if 1 <= nums[i] <= n and nums[i] != nums[correct_idx]:
            nums[i], nums[correct_idx] = nums[correct_idx], nums[i]
        else:
            i += 1
    # first index where value != index+1 gives the answer
    for i in range(n):
        if nums[i] != i + 1:
            return i + 1
    return n + 1                            # all of [1..n] present; answer is n+1


# ---------------------------------------------------------------------------
# TEST PRINTS
# ---------------------------------------------------------------------------
if __name__ == "__main__":
    print("=== Cyclic Sort Problems ===\n")

    print("1. Find Missing Number")
    print(find_missing_number([3, 0, 1]))       # 2
    print(find_missing_number([9,6,4,2,3,5,7,0,1]))  # 8
    print()

    print("2. Find All Missing Numbers")
    print(find_all_missing_numbers([2, 3, 1, 8, 2, 3, 5, 1]))  # [4, 6, 7]
    print(find_all_missing_numbers([2, 4, 1, 2]))               # [3]
    print()

    print("3. Find Duplicate Number")
    print(find_duplicate([1, 4, 4, 3, 2]))      # 4
    print(find_duplicate([2, 1, 3, 3, 5, 4]))   # 3
    print()

    print("4. Find All Duplicates")
    print(find_all_duplicates([3, 4, 4, 5, 5])) # [4, 5]
    print(find_all_duplicates([5, 4, 7, 2, 3, 5, 3]))  # [3, 5]
    print()

    print("5. First Missing Positive")
    print(first_missing_positive([3, -3, 1, 5]))    # 2
    print(first_missing_positive([1, 2, 0]))         # 3
    print(first_missing_positive([7, 8, 9, 11, 12])) # 1
