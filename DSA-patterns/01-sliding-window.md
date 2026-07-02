# Sliding Window

## One-Line Description
Use when you need to find or optimize something over a **contiguous subarray or substring** — slide a window across the input instead of recalculating from scratch each step.

---

## Recognition Keywords / Catchphrases (MOST IMPORTANT)

Spot these words in a problem and immediately think Sliding Window:

### Exact trigger words
- `subarray`, `substring`, `contiguous`, `consecutive`
- `window of size k` / `exactly k elements`
- `longest` / `shortest` subarray or substring
- `maximum` / `minimum` sum of k elements
- `characters in a string` (frequency / distinct count)

### Problem-type signals
| Problem type | What you see in the prompt |
|---|---|
| **Fixed-size window** | "…of size k", "…k consecutive elements", "…average of every subarray of size k" |
| **Variable-size window** | "smallest / longest subarray **that** …", "minimum length subarray with sum ≥ S" |

### High-confidence signal phrases
- "find the smallest / largest subarray such that …"
- "find the longest substring **without** repeating characters"
- "find all anagrams of pattern P in string S"
- "fruits into baskets" (longest subarray with at most 2 distinct values)
- "maximum sum of any contiguous subarray of size k"

---

## Pattern Templates (Python)

### Fixed-Size Window
```python
def fixed_window(arr, k):
    window_sum = sum(arr[:k])          # seed the first window
    result = window_sum

    for i in range(k, len(arr)):
        window_sum += arr[i]           # ADD incoming element (right edge)
        window_sum -= arr[i - k]       # REMOVE outgoing element (left edge)
        result = max(result, window_sum)  # UPDATE answer — customize this line

    return result
```
**Customize**: the `result` update line — could be `max`, `min`, average, a condition, etc.

### Variable-Size Window (expand right, shrink left)
```python
def variable_window(arr, target):
    left = 0
    window_state = 0      # could be a sum, a dict of char counts, etc.
    result = float('inf') # or 0, or [], depending on what you track

    for right in range(len(arr)):
        window_state += arr[right]            # EXPAND: absorb right element

        while <shrink_condition>:             # SHRINK: tighten left edge
            result = min(result, right - left + 1)  # UPDATE inside shrink
            window_state -= arr[left]
            left += 1

    return result if result != float('inf') else 0
```
**Customize**: `window_state` type (int vs dict), `shrink_condition`, and where you record `result` (inside or outside the while loop).

---

## Complexity
| | Fixed window | Variable window |
|---|---|---|
| Time | O(n) | O(n) — each element enters and exits at most once |
| Space | O(1) | O(1) or O(k) if using a frequency map |

---

## Canonical Problem: Maximum Sum Subarray of Size K

**Problem**: Given an array of positive numbers and a positive number k, find the maximum sum of any contiguous subarray of size k.

**Example**: `arr = [2, 1, 5, 1, 3, 2], k = 3` → `9` (subarray `[5, 1, 3]`)

**Key insight**: Instead of recomputing the sum of k elements from scratch each step (O(n·k)), slide the window — add the new right element and drop the old left element in O(1).

```python
def max_sum_subarray_of_size_k(arr, k):
    max_sum = 0
    window_sum = 0

    for i in range(len(arr)):
        window_sum += arr[i]           # grow the window on the right

        if i >= k - 1:                 # window has reached size k
            max_sum = max(max_sum, window_sum)
            window_sum -= arr[i - (k - 1)]  # shrink the window on the left

    return max_sum

# Test
print(max_sum_subarray_of_size_k([2, 1, 5, 1, 3, 2], 3))  # 9
print(max_sum_subarray_of_size_k([2, 3, 4, 1, 5], 2))     # 7
```

---

## Variations

### 1. Smallest Subarray with Sum >= S (variable window)

**Problem**: Find the length of the smallest contiguous subarray whose sum is greater than or equal to S. Return 0 if no such subarray exists.

**Key insight/tweak**: Window is variable. Expand right until `window_sum >= S`, then shrink left as far as possible while condition still holds — record the min length each time you shrink.

```python
def smallest_subarray_with_given_sum(arr, s):
    min_length = float('inf')
    window_sum = 0
    left = 0

    for right in range(len(arr)):
        window_sum += arr[right]

        while window_sum >= s:                        # shrink as much as possible
            min_length = min(min_length, right - left + 1)
            window_sum -= arr[left]
            left += 1

    return 0 if min_length == float('inf') else min_length

# Test
print(smallest_subarray_with_given_sum([2, 1, 5, 2, 3, 2], 7))  # 2
print(smallest_subarray_with_given_sum([2, 1, 5, 2, 8], 7))      # 1
print(smallest_subarray_with_given_sum([3, 4, 1, 1, 6], 8))      # 3
```

---

### 2. Longest Substring with K Distinct Characters

**Problem**: Given a string, find the length of the longest substring in it with no more than K distinct characters.

**Key insight/tweak**: Use a `dict` as window state to track character frequencies. Shrink from the left when `len(char_freq) > k`, decrementing the count and removing the key when count hits 0.

```python
def longest_substring_with_k_distinct(s, k):
    char_freq = {}
    max_length = 0
    left = 0

    for right in range(len(s)):
        char = s[right]
        char_freq[char] = char_freq.get(char, 0) + 1    # add right char

        while len(char_freq) > k:                        # too many distinct chars
            left_char = s[left]
            char_freq[left_char] -= 1
            if char_freq[left_char] == 0:
                del char_freq[left_char]
            left += 1

        max_length = max(max_length, right - left + 1)  # update OUTSIDE shrink

    return max_length

# Test
print(longest_substring_with_k_distinct("araaci", 2))  # 4  ("araa")
print(longest_substring_with_k_distinct("araaci", 1))  # 2  ("aa")
print(longest_substring_with_k_distinct("cbbebi", 3))  # 5  ("cbbeb")
```

---

### 3. Fruits into Baskets (Longest Subarray with 2 Distinct)

**Problem**: You have two baskets and an array of fruit types (integers). Each basket can hold one type of fruit. Find the longest subarray where you use at most 2 distinct fruit types.

**Key insight/tweak**: Identical to "K distinct characters" with k=2. The thematic wrapper is the only difference — recognize it as the same pattern.

```python
def fruits_into_baskets(fruits):
    basket = {}    # fruit_type → count in current window
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

# Test
print(fruits_into_baskets([1, 2, 1]))          # 3
print(fruits_into_baskets([0, 1, 2, 2]))       # 3
print(fruits_into_baskets([1, 2, 3, 2, 2]))   # 4
```

---

### 4. No-Repeat Substring (Longest Without Repeating Chars)

**Problem**: Given a string, find the length of the longest substring without any repeating characters.

**Key insight/tweak**: Use a `dict` to track `char → last seen index`. When you encounter a repeated character, jump `left` to `last_seen[char] + 1` (don't just decrement by 1 — this is a key gotcha). Update the stored index each visit.

```python
def non_repeat_substring(s):
    char_index = {}    # char → most recent index seen
    max_length = 0
    left = 0

    for right in range(len(s)):
        char = s[right]
        if char in char_index and char_index[char] >= left:
            left = char_index[char] + 1    # jump left past the duplicate
        char_index[char] = right
        max_length = max(max_length, right - left + 1)

    return max_length

# Test
print(non_repeat_substring("aabccbb"))  # 3  ("abc")
print(non_repeat_substring("abbbb"))    # 2  ("ab")
print(non_repeat_substring("abccde"))  # 3  ("cde")
```

---

### 5. Permutation in String (Anagram Check in Window)

**Problem**: Given a string and a pattern, find whether any permutation of the pattern exists as a substring of the string. Return True/False.

**Key insight/tweak**: Fixed window of size `len(pattern)`. Maintain a frequency map of pattern chars and a `matched` counter. As you slide, add/remove chars and track how many chars are fully matched. When `matched == len(pattern_freq)`, a permutation window is found.

```python
def find_permutation(s, pattern):
    pattern_freq = {}
    for char in pattern:
        pattern_freq[char] = pattern_freq.get(char, 0) + 1

    left = 0
    matched = 0

    for right in range(len(s)):
        char = s[right]
        if char in pattern_freq:
            pattern_freq[char] -= 1
            if pattern_freq[char] == 0:    # this char is fully satisfied
                matched += 1

        if matched == len(pattern_freq):   # all chars matched → found permutation
            return True

        if right >= len(pattern) - 1:      # window at full size — slide it
            left_char = s[left]
            left += 1
            if left_char in pattern_freq:
                if pattern_freq[left_char] == 0:   # was fully matched, now losing one
                    matched -= 1
                pattern_freq[left_char] += 1

    return False

# Test
print(find_permutation("oidbcaf", "abc"))  # True  ("bca")
print(find_permutation("odicf", "dc"))     # False
print(find_permutation("bcdxabcdy", "bcdyabcdx"))  # True
```

---

## Gotchas

1. **Off-by-one on window shrink**: The window length is `right - left + 1`. Record the result *before* shrinking left (or inside the while condition, depending on what you're measuring).

2. **When to reset vs. shrink**: Never reset `left = 0` mid-loop. Always increment `left` one step at a time inside the while loop — even if it feels slow. Each element enters and exits at most once, so it's still O(n).

3. **Handling duplicates in char frequency maps**: When decrementing a char's count to 0, `del` it from the dict (don't leave 0-count entries). Leaving them breaks `len(dict)` comparisons for distinct-character problems.

4. **The "jump" vs. "slide" gotcha in no-repeat substring**: When you hit a repeated char, set `left = last_seen[char] + 1` directly — don't walk left one step at a time. BUT also guard with `char_index[char] >= left` before jumping, to avoid moving left backwards when a char appeared before the current window.

5. **Fixed window — check size before updating result**: Update `max/min` only after the window reaches size k (`if i >= k - 1`), not on every iteration.
