# Pattern 10: Subsets / Backtracking

## One-Line Summary

Generate all subsets, permutations, or combinations using BFS expansion or DFS backtracking.

---

## Recognition Keywords

| Signal | Example Problem Phrasing |
|--------|--------------------------|
| "all subsets" / "power set" | "Return all possible subsets of a set" |
| "all permutations" | "Find every permutation of the input array" |
| "all combinations" | "Find all combinations that sum to target" |
| "generate all valid parentheses" | "Generate all balanced parentheses for n pairs" |
| "all unique subsets" | "Input has duplicates; return distinct subsets only" |
| "letter case permutation" | "Swap case of each letter — return all strings" |
| "N-Queens" / "Sudoku solver" | "Place N queens so no two attack each other" |

### Key Tell

> The words **"all"** or **"generate all"** appear alongside **combinations / permutations / subsets / arrangements**.
> The answer space is exponential — you must enumerate it.

---

## Templates

### BFS Subset Template

Start with `[[]]`. For each number, create new subsets by appending that number to every existing subset.

```python
def subsets_bfs(nums):
    result = [[]]
    for num in nums:
        result += [subset + [num] for subset in result]
    return result
```

### DFS Backtracking Template

Choose → Explore → Unchoose (the classic backtracking frame).

```python
def backtrack(start, current_path):
    result.append(list(current_path))      # record current state

    for i in range(start, len(nums)):
        # Skip duplicate at same level
        if i > start and nums[i] == nums[i - 1]:
            continue

        current_path.append(nums[i])       # CHOOSE
        backtrack(i + 1, current_path)     # EXPLORE (i+1 prevents reuse)
        current_path.pop()                 # UNCHOOSE

backtrack(0, [])
```

---

## Complexity

| Problem Type | Time | Space |
|--------------|------|-------|
| Subsets | O(2^n) | O(n) recursion stack |
| Permutations | O(n!) | O(n) |
| Combinations | O(2^n) worst | O(n) |
| Balanced Parentheses | O(4^n / sqrt(n)) — Catalan number | O(n) |

---

## Canonical Problem

**Subsets (Power Set)** — return all subsets of a set with no duplicates.

```
Input:  [1, 2, 3]
Output: [[], [1], [2], [1,2], [3], [1,3], [2,3], [1,2,3]]
```

BFS trace:
```
Start:           [[]]
After num=1:     [[], [1]]
After num=2:     [[], [1], [2], [1,2]]
After num=3:     [[], [1], [2], [1,2], [3], [1,3], [2,3], [1,2,3]]
```

---

## Variations

| Variation | Key Change from Canonical |
|-----------|--------------------------|
| **Subsets with Duplicates** | Sort first; inside loop, `if i > start and nums[i] == nums[i-1]: continue` |
| **Permutations** | DFS with a `used[]` boolean array; no `start` index — pick any unused element |
| **String Permutations** | Same as above; check for duplicate characters to prune |
| **Letter Case Permutation** | At each letter, branch into two: lowercase and uppercase; digits are fixed |
| **Generate Balanced Parentheses** | DFS with open/close counts; add `(` if `open < n`; add `)` if `close < open` |

---

## Gotchas

1. **Sort before processing duplicates** — Deduplication skipping (`nums[i] == nums[i-1]`) only works if equal elements are adjacent, which requires sorting first.

2. **Backtracking = append a copy, not a reference** — Always do `result.append(list(current_path))` or `result.append(current_path[:])`. If you append the path object directly, all entries in `result` will reflect the final (empty) state of the path when the recursion unwinds.

3. **The `start` index prevents re-using earlier elements** — For subsets and combinations, `backtrack(i + 1, ...)` ensures elements are not reused and order is fixed (avoids `[1,2]` and `[2,1]` as duplicates). For permutations, drop `start` and use a `used` array instead.

4. **Parentheses constraint** — `open < n` allows opening; `close < open` allows closing. Both branches only if the constraint is met — this naturally prunes invalid states without explicit backtrack cleanup of strings (strings in Python are immutable, so no pop needed).

5. **Letter case permutation** — Only branch at letters; skip branching for digits. Use index-based recursion, not a loop, because you branch on each character independently.
