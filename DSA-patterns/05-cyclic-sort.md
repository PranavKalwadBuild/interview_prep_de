# Pattern 05: Cyclic Sort

## One-Line Summary
In-place sort when numbers are in range [1..n] or [0..n] — use the index as a hash to place each number at its correct position.

---

## Recognition Keywords
- "array contains numbers in range 1 to n"
- "find the missing number"
- "find the duplicate number"
- "find all duplicates / all missing numbers"
- "first missing positive"

**Key Tell**: Numbers are integers in a bounded range; you can use the index as a hash. If you see a constraint like "array of n integers where each integer is between 1 and n", reach for cyclic sort.

---

## Core Template

```python
def cyclic_sort(nums):
    i = 0
    while i < len(nums):
        correct_idx = nums[i] - 1          # where this number belongs (1-indexed)
        if nums[i] != nums[correct_idx]:   # not already in place (value check, not index!)
            nums[i], nums[correct_idx] = nums[correct_idx], nums[i]   # swap into place
        else:
            i += 1                         # already correct, move on
    return nums
```

**Why value check, not index check?**
If `nums[i] == nums[correct_idx]` but `i != correct_idx`, we have a duplicate. Checking the index would cause an infinite loop — checking the value detects the duplicate and advances `i`.

---

## Complexity
| Dimension | Cost |
|-----------|------|
| Time      | O(n) — each element is moved at most once |
| Space     | O(1) — in-place, no extra data structures |

---

## Canonical Problem
**Find Missing Number** — given n distinct numbers from 0..n, find the one missing.

Cyclic sort into [0..n-1] positions, then scan for the index where `nums[i] != i`.

---

## Variations

| Problem | Twist |
|---------|-------|
| Find All Missing Numbers | Multiple missing; collect all indices where `nums[i] != i+1` |
| Find the Duplicate Number | One extra number; after sort, find index where `nums[i] != i+1` — that value is the dup |
| Find All Duplicates | Multiple duplicates; same scan, collect all mismatched values |
| First Missing Positive | Range is 1..n but array may have negatives/out-of-range values — skip those during sort |
| Find the Corrupt Pair | One missing + one duplicate — one scan gives both |

---

## Gotchas

1. **0-indexed vs 1-indexed range**: If range is [1..n], `correct_idx = nums[i] - 1`. If range is [0..n], `correct_idx = nums[i]`. Get this wrong and you'll access out-of-bounds indices.

2. **Infinite loop on duplicate**: Always swap on value inequality (`nums[i] != nums[correct_idx]`), not index inequality (`i != correct_idx`). When a duplicate sits at the correct index, a value-check breaks the loop; an index-check loops forever.

3. **First Missing Positive — skip out-of-range values**: Numbers <= 0 or > n cannot be placed; check bounds before computing `correct_idx` or you'll index out of bounds.

4. **After the sort, do a second pass**: The sort itself does not answer the question — it just positions the elements. Always follow with a linear scan to collect the answer.
