"""
02-two-pointers.py
Pattern: Two Pointers

Recognition signals:
  - Sorted array + "find pair/triplet that sums to"
  - "remove duplicates in-place"
  - "palindrome check on string"
  - "container with most water" (max area)
  - "move zeros to end while maintaining order"
  - Key tell: the sorted property lets you make greedy left/right decisions
"""

# =============================================================================
# TEMPLATE 1: Opposite-Ends (left/right converging)
# =============================================================================
#
# def opposite_ends(arr, target):
#     left, right = 0, len(arr) - 1
#
#     while left < right:                        # <-- NOT <=, same element twice is wrong
#         current = arr[left] + arr[right]       # <-- CUSTOMIZE: what you compare
#
#         if current == target:
#             return [left, right]               # <-- CUSTOMIZE: what to return on match
#         elif current < target:
#             left += 1                          # sum too small → need bigger left
#         else:
#             right -= 1                         # sum too big → need smaller right
#
#     return []   # not found
#
# When to use: sorted input + find pair where some property of (left, right)
#              matches a target (sum, product, area, etc.)

# =============================================================================
# TEMPLATE 2: Same-Direction (slow/fast — in-place partition)
# =============================================================================
#
# def same_direction(arr):
#     slow = 0   # next write position / boundary of "processed" section
#
#     for fast in range(len(arr)):
#         if <keep_condition>(arr[fast]):    # <-- CUSTOMIZE: which elements survive
#             arr[slow] = arr[fast]
#             slow += 1
#
#     return slow   # new logical length (slow is 0-indexed next-write position)
#
# When to use: remove/filter elements in-place from a sorted (or unsorted)
#              array, maintain relative order, return new length.

# =============================================================================
# TEMPLATE 3: Dutch National Flag / 3-Way Partition
# =============================================================================
#
# def dutch_national_flag(arr):
#     low, mid, high = 0, 0, len(arr) - 1
#
#     while mid <= high:
#         if arr[mid] == 0:
#             arr[low], arr[mid] = arr[mid], arr[low]
#             low += 1
#             mid += 1
#         elif arr[mid] == 1:
#             mid += 1
#         else:   # arr[mid] == 2
#             arr[mid], arr[high] = arr[high], arr[mid]
#             high -= 1
#             # CRITICAL: do NOT increment mid here — the swapped-in value is unexamined
#
# When to use: "sort colors", 3-value partition, "move 0s/1s/2s",
#              "Dutch National Flag". Three-region invariant.

# =============================================================================
# PROBLEM 1 (Canonical): Pair with Target Sum
# =============================================================================
# Problem: Given a sorted array of integers and a target sum, find a pair of
#          numbers that add up to the target. Return their 1-indexed positions.
#
# Pattern: Opposite-ends. Sorted order means: if sum < target → left must
#          increase (move left up). If sum > target → right must decrease.
#          Each element visited at most once → O(n).
#
# Example: arr=[1,2,3,4,6], target=6 → [1,3] (values 2 and 4, 1-indexed)

def pair_with_target_sum(arr, target_sum):
    left, right = 0, len(arr) - 1

    while left < right:
        current_sum = arr[left] + arr[right]

        if current_sum == target_sum:
            return [left + 1, right + 1]   # 1-indexed
        elif current_sum < target_sum:
            left += 1
        else:
            right -= 1

    return []


print("--- Problem 1: Pair with Target Sum ---")
print(f"Input: arr=[1, 2, 3, 4, 6], target=6   →  Output: {pair_with_target_sum([1, 2, 3, 4, 6], 6)}")  # [1, 3]
print(f"Input: arr=[2, 5, 9, 11], target=11     →  Output: {pair_with_target_sum([2, 5, 9, 11], 11)}")   # [1, 2]


# =============================================================================
# PROBLEM 2: Remove Duplicates from Sorted Array
# =============================================================================
# Problem: Given a sorted array, remove duplicate elements in-place and return
#          the count of unique elements. Relative order must be maintained.
#          (Elements beyond the returned count don't matter.)
#
# Pattern: Same-direction. slow = index of last-written unique value.
#          fast scans forward; when arr[fast] != arr[slow], we found a new
#          unique — write it at slow+1 and advance slow.
#
# Gotcha: Return slow + 1 (the count), NOT slow (the 0-indexed last position).

def remove_duplicates(arr):
    if not arr:
        return 0

    slow = 0
    for fast in range(1, len(arr)):
        if arr[fast] != arr[slow]:       # found a new unique element
            slow += 1
            arr[slow] = arr[fast]        # overwrite next position with new unique

    return slow + 1   # +1 because slow is 0-indexed


print("\n--- Problem 2: Remove Duplicates ---")
arr1 = [2, 3, 3, 3, 6, 9, 9]
length1 = remove_duplicates(arr1)
print(f"Input: [2, 3, 3, 3, 6, 9, 9]  →  Output: length={length1}, first {length1} elements={arr1[:length1]}")  # 4, [2,3,6,9]

arr2 = [2, 2, 2, 11]
length2 = remove_duplicates(arr2)
print(f"Input: [2, 2, 2, 11]           →  Output: length={length2}, first {length2} elements={arr2[:length2]}")  # 2, [2,11]


# =============================================================================
# PROBLEM 3: Squaring a Sorted Array
# =============================================================================
# Problem: Given a sorted array (may contain negatives), return a new array
#          of squares of each number, also sorted in non-decreasing order.
#
# Pattern: Opposite-ends, filling result from the BACK.
#          Negative numbers squared can be larger than squares of positives,
#          so a simple forward pass produces an unsorted result.
#          At each step, compare abs(arr[left]) vs abs(arr[right]) — the larger
#          square goes at the highest unfilled position. Move that pointer inward.
#
# Gotcha: Fill from the back (highest_idx down to 0), not the front — you can
#         only determine the LARGEST square at each step, not the smallest.

def make_squares(arr):
    n = len(arr)
    squares = [0] * n
    highest_idx = n - 1
    left, right = 0, n - 1

    while left <= right:             # <-- <= because we must process the middle element
        left_sq = arr[left] ** 2
        right_sq = arr[right] ** 2

        if left_sq > right_sq:
            squares[highest_idx] = left_sq
            left += 1
        else:
            squares[highest_idx] = right_sq
            right -= 1

        highest_idx -= 1

    return squares


print("\n--- Problem 3: Squaring a Sorted Array ---")
print(f"Input: [-2, -1, 0, 2, 3]  →  Output: {make_squares([-2, -1, 0, 2, 3])}")  # [0, 1, 4, 4, 9]
print(f"Input: [-3, -1, 0, 1, 2]  →  Output: {make_squares([-3, -1, 0, 1, 2])}")  # [0, 1, 1, 4, 9]


# =============================================================================
# PROBLEM 4: 3Sum (Triplet Sum to Zero)
# =============================================================================
# Problem: Given an unsorted array, find all unique triplets that sum to zero.
#          Return a list of triplets (no duplicate triplets in output).
#
# Pattern: Sort first, then for each element arr[i] (the "anchor"), run a
#          two-pointer opposite-ends search on the subarray [i+1 ... end]
#          looking for a pair summing to -arr[i].
#
# Gotchas:
#   1. Skip duplicate anchors: if arr[i] == arr[i-1] (and i > 0), continue.
#   2. After finding a valid triplet, skip duplicate left and right values
#      before the next iteration — otherwise the same triplet appears twice.
#   3. Time: O(n log n + n²) = O(n²). Space: O(1) ignoring the output list.

def search_triplets(arr):
    arr.sort()
    triplets = []

    for i in range(len(arr) - 2):
        if i > 0 and arr[i] == arr[i - 1]:   # skip duplicate anchors
            continue

        left, right = i + 1, len(arr) - 1
        target = -arr[i]

        while left < right:
            current_sum = arr[left] + arr[right]

            if current_sum == target:
                triplets.append([arr[i], arr[left], arr[right]])
                left += 1
                right -= 1
                # Skip duplicates on both sides after a match
                while left < right and arr[left] == arr[left - 1]:
                    left += 1
                while left < right and arr[right] == arr[right + 1]:
                    right -= 1
            elif current_sum < target:
                left += 1
            else:
                right -= 1

    return triplets


print("\n--- Problem 4: 3Sum (Triplet Sum to Zero) ---")
print(f"Input: [-3, 0, 1, 2, -1, 1, -2]  →  Output: {search_triplets([-3, 0, 1, 2, -1, 1, -2])}")
# [[-3, 1, 2], [-2, 0, 2], [-2, 1, 1], [-1, 0, 1]]
print(f"Input: [-5, 2, -1, -2, 3]         →  Output: {search_triplets([-5, 2, -1, -2, 3])}")
# [[-5, 2, 3], [-2, -1, 3]]


# =============================================================================
# PROBLEM 5: Container with Most Water
# =============================================================================
# Problem: Given an array `height` where height[i] represents the height of a
#          vertical line at index i, find two lines that together with the x-axis
#          form a container holding the most water. Return the maximum area.
#
# Pattern: Opposite-ends. Area = min(height[left], height[right]) * (right - left).
#          Greedy choice: always move the pointer with the SHORTER height inward.
#          Reasoning: moving the taller side inward can only decrease width while
#          not guaranteeing a taller minimum — the shorter side is the bottleneck.
#
# Gotcha: Don't move BOTH pointers — only the one with the shorter height.
#         If they're equal, moving either is fine (both are bounded by the same min).

def max_area(height):
    max_water = 0
    left, right = 0, len(height) - 1

    while left < right:
        h = min(height[left], height[right])
        width = right - left
        max_water = max(max_water, h * width)

        if height[left] <= height[right]:
            left += 1    # left is the bottleneck — move it inward
        else:
            right -= 1   # right is the bottleneck — move it inward

    return max_water


print("\n--- Problem 5: Container with Most Water ---")
print(f"Input: height=[1, 8, 6, 2, 5, 4, 8, 3, 7]  →  Output: {max_area([1, 8, 6, 2, 5, 4, 8, 3, 7])}")  # 49
print(f"Input: height=[1, 1]                          →  Output: {max_area([1, 1])}")                        # 1
print(f"Input: height=[4, 3, 2, 1, 4]                →  Output: {max_area([4, 3, 2, 1, 4])}")               # 16
