# Two Pointers

## One-Line Description
Use when you have a **sorted array (or string)** and need to find a pair, triplet, or subarray satisfying a condition — two indices moving toward each other (or in the same direction) eliminate the need for a nested loop.

---

## Recognition Keywords / Catchphrases (MOST IMPORTANT)

Spot these words/phrases and immediately think Two Pointers:

### Exact trigger words
- `sorted array` or `sorted linked list`
- `pair` / `triplet` / `subarray` that sums to target
- `remove duplicates` from sorted (in-place)
- `palindrome` check on a string
- `squaring a sorted array` (or "squares of sorted array")
- `container with most water` / `max area`
- `move all zeros` / `move all negatives` to one side
- `two numbers that sum to target` / `target sum`

### Problem-type signals
| Problem type | What you see in the prompt |
|---|---|
| **Opposite-ends** | Sorted input + find pair/comparison between smallest and largest |
| **Same-direction (slow/fast)** | Remove in-place, partition, "maintain relative order" |
| **3-way partition** | "Sort colors", "Dutch National Flag", "move 0s and 1s and 2s" |

### High-confidence signal phrases
- "find a pair in a sorted array that adds up to target"
- "remove duplicates from sorted array in-place"
- "given sorted array, return sorted array of squares"
- "find all unique triplets that sum to zero"
- "find triplet closest to target"
- "compare strings with backspaces"
- "two lines on a graph — maximum water container"

---

## Pattern Templates (Python)

### Opposite-Ends (left/right converging)
```python
def opposite_ends(arr, target):
    left, right = 0, len(arr) - 1

    while left < right:
        current = arr[left] + arr[right]   # CUSTOMIZE: the comparison

        if current == target:
            return [left, right]           # FOUND — customize return
        elif current < target:
            left += 1                      # need bigger sum → move left up
        else:
            right -= 1                     # need smaller sum → move right down

    return []   # not found
```
**Customize**: the comparison (`arr[left] + arr[right]`), what "too small" / "too big" means for your problem, and what to return on a match.

### Same-Direction (slow/fast — in-place partition)
```python
def same_direction(arr):
    slow = 0   # marks the boundary of the "processed" section

    for fast in range(len(arr)):
        if <keep_condition>(arr[fast]):    # CUSTOMIZE: which elements to keep
            arr[slow] = arr[fast]
            slow += 1

    return slow   # new logical length
```
**Customize**: `keep_condition` — e.g., `arr[fast] != 0`, `arr[fast] != arr[slow - 1]` for dedup, etc.

### Dutch National Flag / 3-Way Partition
```python
def dutch_national_flag(arr):
    low, mid, high = 0, 0, len(arr) - 1

    while mid <= high:
        if arr[mid] == 0:
            arr[low], arr[mid] = arr[mid], arr[low]
            low += 1
            mid += 1
        elif arr[mid] == 1:
            mid += 1
        else:   # arr[mid] == 2
            arr[mid], arr[high] = arr[high], arr[mid]
            high -= 1
            # DO NOT increment mid here — the swapped-in element is unexamined
```
**Customize**: the three partition values (0/1/2 here), and the invariants for each pointer.

---

## Complexity
| Approach | Time | Space |
|---|---|---|
| Opposite-ends (sorted input) | O(n) | O(1) |
| Opposite-ends (unsorted — must sort first) | O(n log n) | O(1) |
| Same-direction in-place | O(n) | O(1) |
| 3Sum (sort + two-pointer inner loop) | O(n²) | O(1) ignoring output |

---

## Canonical Problem: Pair with Target Sum

**Problem**: Given a sorted array of integers and a target sum, find a pair of numbers that add up to the target. Return the 1-indexed positions of the pair.

**Example**: `arr = [1, 2, 3, 4, 6], target = 6` → `[1, 3]` (1-indexed: values 2 and 4)

**Key insight**: Because the array is sorted, if `arr[left] + arr[right] < target`, we must move left up to increase the sum. If it's too big, move right down. No element is revisited → O(n).

```python
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

# Test
print(pair_with_target_sum([1, 2, 3, 4, 6], 6))   # [1, 3]
print(pair_with_target_sum([2, 5, 9, 11], 11))     # [1, 2]
```

---

## Variations

### 1. Remove Duplicates from Sorted Array

**Problem**: Given a sorted array, remove duplicate elements in-place. Return the length of the array after removing duplicates. The relative order of non-duplicate elements must be maintained.

**Key insight/tweak**: Same-direction template. `slow` points at the last written unique value. Advance `fast`; when `arr[fast] != arr[slow]`, copy it into `arr[slow + 1]` and move slow forward.

```python
def remove_duplicates(arr):
    if not arr:
        return 0

    slow = 0
    for fast in range(1, len(arr)):
        if arr[fast] != arr[slow]:    # found a new unique element
            slow += 1
            arr[slow] = arr[fast]

    return slow + 1   # length (slow is 0-indexed last position)

# Test
arr1 = [2, 3, 3, 3, 6, 9, 9]
print(f"Length: {remove_duplicates(arr1)}, Array: {arr1}")  # 4, [2,3,6,9,...]

arr2 = [2, 2, 2, 11]
print(f"Length: {remove_duplicates(arr2)}, Array: {arr2}")  # 2, [2,11,...]
```

---

### 2. Squaring a Sorted Array

**Problem**: Given a sorted array (may contain negatives), return a new array of the squares of each number, also in sorted order.

**Key insight/tweak**: Squares of negatives can be larger than squares of positives, so a simple forward pass produces an unsorted result. Use opposite-ends: compare `abs(arr[left])` vs `abs(arr[right])`, always place the larger square at the back of the result array, and move that pointer inward.

```python
def make_squares(arr):
    n = len(arr)
    squares = [0] * n
    highest_idx = n - 1
    left, right = 0, n - 1

    while left <= right:
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

# Test
print(make_squares([-2, -1, 0, 2, 3]))  # [0, 1, 4, 4, 9]
print(make_squares([-3, -1, 0, 1, 2]))  # [0, 1, 1, 4, 9]
```

---

### 3. Triplet Sum to Zero (3Sum)

**Problem**: Given an array of unsorted numbers, find all unique triplets that sum to zero.

**Key insight/tweak**: Sort first. For each element `arr[i]` (the "anchor"), run a two-pointer opposite-ends search on the subarray to its right for a pair summing to `-arr[i]`. Skip duplicate anchors and duplicate pairs to avoid returning the same triplet twice.

```python
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
                while left < right and arr[left] == arr[left - 1]:   # skip dup left
                    left += 1
                while left < right and arr[right] == arr[right + 1]: # skip dup right
                    right -= 1
            elif current_sum < target:
                left += 1
            else:
                right -= 1

    return triplets

# Test
print(search_triplets([-3, 0, 1, 2, -1, 1, -2]))  # [[-3,1,2],[-2,0,2],[-2,1,1],[-1,0,1]]
print(search_triplets([-5, 2, -1, -2, 3]))         # [[-5,2,3],[-2,-1,3]]
```

---

### 4. Triplet Sum Close to Target

**Problem**: Given an unsorted array and a target sum, find a triplet whose sum is closest to the target. Return the sum of that triplet.

**Key insight/tweak**: Same structure as 3Sum, but instead of checking for exact equality, track the minimum absolute difference. Update `smallest_diff` whenever you find a closer sum. Move pointers based on whether current sum is above or below target.

```python
def triplet_sum_close_to_target(arr, target_sum):
    arr.sort()
    smallest_diff = float('inf')
    closest_sum = float('inf')

    for i in range(len(arr) - 2):
        left, right = i + 1, len(arr) - 1

        while left < right:
            current_sum = arr[i] + arr[left] + arr[right]
            diff = abs(target_sum - current_sum)

            if diff < smallest_diff:
                smallest_diff = diff
                closest_sum = current_sum

            if current_sum < target_sum:
                left += 1
            else:
                right -= 1

    return closest_sum

# Test
print(triplet_sum_close_to_target([-2, 0, 1, 2], 2))   # 1
print(triplet_sum_close_to_target([-3, -1, 1, 2], 1))  # 0
print(triplet_sum_close_to_target([1, 0, 1, 1], 100))  # 3
```

---

### 5. Comparing Strings Containing Backspaces

**Problem**: Given two strings with `#` representing a backspace, check if they are equal after processing backspaces.

**Key insight/tweak**: Walk both strings backwards simultaneously (opposite-ends variant). Maintain a `backspace_count` per string; when you see `#`, increment it and skip; when you see a regular char and `backspace_count > 0`, skip it (it gets deleted) and decrement. Compare the first undeleted char from each string.

```python
def backspace_compare(str1, str2):
    def next_valid_char_index(s, index):
        backspace_count = 0
        while index >= 0:
            if s[index] == '#':
                backspace_count += 1
                index -= 1
            elif backspace_count > 0:
                backspace_count -= 1
                index -= 1
            else:
                break
        return index

    i1, i2 = len(str1) - 1, len(str2) - 1

    while i1 >= 0 or i2 >= 0:
        i1 = next_valid_char_index(str1, i1)
        i2 = next_valid_char_index(str2, i2)

        if i1 < 0 and i2 < 0:          # both exhausted — equal
            return True
        if i1 < 0 or i2 < 0:           # one exhausted, other not — unequal
            return False
        if str1[i1] != str2[i2]:
            return False

        i1 -= 1
        i2 -= 1

    return True

# Test
print(backspace_compare("xy#z", "xzz#"))    # True  (both → "xz")
print(backspace_compare("xy#z", "xyz#"))    # False ("xz" vs "xy")
print(backspace_compare("xp#", "xyz##"))    # True  (both → "x")
print(backspace_compare("xywrrmp", "xywrrmu#p"))  # True
```

---

## Gotchas

1. **When the array isn't sorted — sort first**: Two-pointer only works because the sorted property gives you a direction ("too small → move left up, too big → move right down"). If the array isn't sorted, sort it first. This changes time complexity to O(n log n).

2. **Handling duplicates in 3Sum**: After finding a valid triplet, advance both pointers AND then skip over any repeated values by checking `arr[left] == arr[left - 1]` and `arr[right] == arr[right + 1]`. Forgetting this is the most common bug that produces duplicate triplets.

3. **The "squeeze" termination condition**: The while loop condition must be `while left < right`, not `while left <= right`. If `left == right`, both pointers are on the same element, and you'd be using it twice.

4. **Dutch National Flag — don't advance mid after swap with high**: When `arr[mid] == 2`, you swap with `arr[high]` and decrement `high`, but do NOT increment `mid`. The newly swapped-in element at `mid` hasn't been examined yet.

5. **Same-direction dedup — the slow pointer is the last valid index, not the count**: After the loop, return `slow + 1` (not `slow`) as the new length, because `slow` is 0-indexed.

6. **Squaring sorted array — always fill from the back**: It's tempting to fill from the front (smallest square first), but you can only determine the largest square at each step (by comparing absolute values at both ends). Build the result from right to left.
