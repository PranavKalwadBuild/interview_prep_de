"""
01-sliding-window.py
Pattern: Sliding Window

Recognition signals:
  - "subarray" or "substring" + "contiguous"
  - "window of size k" (fixed) OR "smallest/largest subarray that..." (variable)
  - "maximum/minimum sum", "longest without repeating", "anagram match"
  - Key tell: you can process [i..j] by extending j right and retracting i left
"""

# =============================================================================
# TEMPLATE 1: Fixed-Size Window
# =============================================================================
#
# def fixed_window(arr, k):
#     window_sum = sum(arr[:k])          # seed the first window
#     result = window_sum                 # <-- CUSTOMIZE: max/min/list/etc.
#
#     for i in range(k, len(arr)):
#         window_sum += arr[i]           # ADD incoming element (right edge)
#         window_sum -= arr[i - k]       # REMOVE outgoing element (left edge)
#         result = max(result, window_sum)  # <-- CUSTOMIZE this update
#
#     return result
#
# When to use: problem says "window of size k", "every k consecutive elements",
#              "k-length subarray". Window size never changes.

# =============================================================================
# TEMPLATE 2: Variable-Size Window (expand right, shrink left)
# =============================================================================
#
# def variable_window(arr, target):
#     left = 0
#     window_state = 0          # <-- CUSTOMIZE: int sum, dict of char counts, set, etc.
#     result = float('inf')     # <-- CUSTOMIZE: float('inf') for min, 0 for max
#
#     for right in range(len(arr)):
#         window_state += arr[right]            # EXPAND: absorb right element
#
#         while <shrink_condition>:             # <-- CUSTOMIZE shrink condition
#             result = min(result, right - left + 1)   # UPDATE inside shrink loop
#             window_state -= arr[left]
#             left += 1
#
#     return result if result != float('inf') else 0
#
# When to use: "find the smallest/longest subarray SUCH THAT [some condition]".
#              The window grows and shrinks dynamically.

# =============================================================================
# PROBLEM 1 (Canonical): Maximum Sum Subarray of Size K
# =============================================================================
# Problem: Given an array of positive numbers and a positive number k,
#          find the maximum sum of any contiguous subarray of size k.
#
# Pattern: Fixed-size window. Seed the first window, then slide: add the
#          incoming right element, drop the outgoing left element.
#          Avoids recomputing the full k-element sum each step → O(n) vs O(n*k).
#
# Example: arr=[2,1,5,1,3,2], k=3 → 9  (subarray [5,1,3])

def max_sum_subarray_of_size_k(arr, k):
    max_sum = 0
    window_sum = 0

    for i in range(len(arr)):
        window_sum += arr[i]               # grow window on the right

        if i >= k - 1:                     # window has reached size k
            max_sum = max(max_sum, window_sum)
            window_sum -= arr[i - (k - 1)]  # shrink window on the left

    return max_sum


print("--- Problem 1: Maximum Sum Subarray of Size K ---")
print(f"Input: arr=[2, 1, 5, 1, 3, 2], k=3  →  Output: {max_sum_subarray_of_size_k([2, 1, 5, 1, 3, 2], 3)}")  # 9
print(f"Input: arr=[2, 3, 4, 1, 5], k=2     →  Output: {max_sum_subarray_of_size_k([2, 3, 4, 1, 5], 2)}")      # 7


# =============================================================================
# PROBLEM 2: Smallest Subarray with Sum >= S
# =============================================================================
# Problem: Find the length of the smallest contiguous subarray whose sum is
#          >= S. Return 0 if no such subarray exists.
#
# Pattern: Variable-size window. Expand right until window_sum >= S, then
#          shrink left as far as possible while condition still holds.
#          Record the minimum length INSIDE the shrink loop (before shrinking).
#
# Gotcha: Record result INSIDE the while loop before decrementing left,
#         not after — otherwise you miss the tightest window.

def smallest_subarray_with_given_sum(arr, s):
    min_length = float('inf')
    window_sum = 0
    left = 0

    for right in range(len(arr)):
        window_sum += arr[right]                    # expand

        while window_sum >= s:                      # shrink as far as possible
            min_length = min(min_length, right - left + 1)
            window_sum -= arr[left]
            left += 1

    return 0 if min_length == float('inf') else min_length


print("\n--- Problem 2: Smallest Subarray with Sum >= S ---")
print(f"Input: arr=[2, 1, 5, 2, 3, 2], s=7  →  Output: {smallest_subarray_with_given_sum([2, 1, 5, 2, 3, 2], 7)}")  # 2
print(f"Input: arr=[2, 1, 5, 2, 8], s=7     →  Output: {smallest_subarray_with_given_sum([2, 1, 5, 2, 8], 7)}")      # 1
print(f"Input: arr=[3, 4, 1, 1, 6], s=8     →  Output: {smallest_subarray_with_given_sum([3, 4, 1, 1, 6], 8)}")      # 3


# =============================================================================
# PROBLEM 3: Longest Substring with K Distinct Characters
# =============================================================================
# Problem: Given a string, find the length of the longest substring with
#          no more than K distinct characters.
#
# Pattern: Variable-size window with a dict as window state.
#          window state = {char: count_in_window}.
#          Shrink condition: len(char_freq) > k (too many distinct chars).
#          When a char's count hits 0, DELETE it — don't leave 0-count entries
#          or len(char_freq) will be wrong (key gotcha).
#
# Record result OUTSIDE the shrink loop (update after every right expansion).

def longest_substring_with_k_distinct(s, k):
    char_freq = {}       # char → frequency in current window
    max_length = 0
    left = 0

    for right in range(len(s)):
        char = s[right]
        char_freq[char] = char_freq.get(char, 0) + 1   # add right char

        while len(char_freq) > k:                       # too many distinct chars
            left_char = s[left]
            char_freq[left_char] -= 1
            if char_freq[left_char] == 0:
                del char_freq[left_char]                # IMPORTANT: remove 0-count keys
            left += 1

        max_length = max(max_length, right - left + 1)  # update OUTSIDE shrink

    return max_length


print("\n--- Problem 3: Longest Substring with K Distinct Characters ---")
print(f"Input: s='araaci', k=2  →  Output: {longest_substring_with_k_distinct('araaci', 2)}")  # 4
print(f"Input: s='araaci', k=1  →  Output: {longest_substring_with_k_distinct('araaci', 1)}")  # 2
print(f"Input: s='cbbebi', k=3  →  Output: {longest_substring_with_k_distinct('cbbebi', 3)}")  # 5


# =============================================================================
# PROBLEM 4: Fruits into Baskets (Longest Subarray with 2 Distinct)
# =============================================================================
# Problem: You have two baskets (each holds one fruit type) and an array of
#          fruit types. Find the length of the longest subarray you can pick
#          from, using at most 2 distinct fruit types.
#
# Pattern: Identical to Problem 3 with k=2. Recognize the disguise:
#          "two baskets" = "at most 2 distinct values". The implementation
#          is identical — only the variable names change for clarity.
#
# Key insight: If you've solved Problem 3, this is free — just call it with k=2.

def fruits_into_baskets(fruits):
    basket = {}     # fruit_type → count in current window
    max_fruits = 0
    left = 0

    for right in range(len(fruits)):
        fruit = fruits[right]
        basket[fruit] = basket.get(fruit, 0) + 1

        while len(basket) > 2:
            left_fruit = fruits[left]
            basket[left_fruit] -= 1
            if basket[left_fruit] == 0:
                del basket[left_fruit]
            left += 1

        max_fruits = max(max_fruits, right - left + 1)

    return max_fruits


print("\n--- Problem 4: Fruits into Baskets ---")
print(f"Input: fruits=[1, 2, 1]          →  Output: {fruits_into_baskets([1, 2, 1])}")         # 3
print(f"Input: fruits=[0, 1, 2, 2]       →  Output: {fruits_into_baskets([0, 1, 2, 2])}")      # 3
print(f"Input: fruits=[1, 2, 3, 2, 2]    →  Output: {fruits_into_baskets([1, 2, 3, 2, 2])}")  # 4


# =============================================================================
# PROBLEM 5: No-Repeat Substring (Longest Without Repeating Characters)
# =============================================================================
# Problem: Given a string, find the length of the longest substring that has
#          no repeating characters.
#
# Pattern: Variable-size window with a dict tracking char → last seen index.
#
# Key gotcha (different from problems 3 & 4): Don't walk left one step at a
# time. When you hit a repeat, JUMP left to last_seen[char] + 1 directly.
# BUT guard with `char_index[char] >= left` before jumping — a char might be
# in the dict from before the current window; don't jump left backward.
#
# No shrink loop needed here — just a direct left pointer update.

def non_repeat_substring(s):
    char_index = {}    # char → most recent index
    max_length = 0
    left = 0

    for right in range(len(s)):
        char = s[right]
        # Only jump left if the previous occurrence is WITHIN the current window
        if char in char_index and char_index[char] >= left:
            left = char_index[char] + 1    # jump past the duplicate

        char_index[char] = right           # always update to latest index
        max_length = max(max_length, right - left + 1)

    return max_length


print("\n--- Problem 5: No-Repeat Substring ---")
print(f"Input: s='aabccbb'  →  Output: {non_repeat_substring('aabccbb')}")  # 3  ("abc")
print(f"Input: s='abbbb'    →  Output: {non_repeat_substring('abbbb')}")    # 2  ("ab")
print(f"Input: s='abccde'   →  Output: {non_repeat_substring('abccde')}")  # 3  ("cde")
