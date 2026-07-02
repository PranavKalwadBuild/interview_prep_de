# 14 — Dynamic Programming

## One-line
Break problem into overlapping subproblems; memoize or tabulate solutions so each subproblem is solved only once.

---

## Recognition Keywords (THE MOST CRITICAL SECTION)

If the problem contains any of these phrases, try DP first:

- "minimum / maximum number of ways"
- "count the number of ways"
- "is it possible to reach"
- "longest common subsequence / substring"
- "coin change" / "minimum coins"
- "0/1 knapsack" / "subset sum" / "partition equal subset"
- "climbing stairs" / "fibonacci-like"
- "edit distance" / "string matching"
- "longest increasing subsequence"
- "maximum profit" / "buy and sell stock"

**Key tell**: choices at each step AND prior choices affect future choices; overlapping subproblems exist (same smaller problem recurs many times).

---

## Sub-pattern Recognition Table

| Sub-pattern | Trigger words | Classic example |
|---|---|---|
| 0/1 Knapsack | "include or exclude each item", "can we pick a subset" | Subset Sum, Equal Partition |
| Unbounded Knapsack | "items can repeat", "unlimited supply" | Coin Change, Rod Cutting |
| Fibonacci / Linear | "depends on previous 1–2 steps", "staircase" | Climbing Stairs, House Robber |
| LCS family | "two strings", "alignment", "common subsequence" | LCS, Edit Distance, Min Deletions |
| LIS | "increasing subsequence", "subsequence length" | LIS, Max Envelopes |
| Matrix / Grid | "grid path", "rectangle", "unique paths" | Unique Paths, Minimum Path Sum |
| Palindrome | "palindromic subsequence", "palindromic substring" | Longest Palindromic Subsequence |

---

## Templates

### Top-down (Memoization with `lru_cache`)

```python
from functools import lru_cache

def solve(n):
    @lru_cache(maxsize=None)
    def dp(state):
        # base case
        if state == 0:
            return 0
        # recurrence
        return min(dp(state - 1), dp(state - 2)) + cost[state]
    return dp(n)
```

- Easiest to write; just translate the recurrence directly.
- Stack overflow risk on very deep recursion (Python default limit ~1000).
- Use `sys.setrecursionlimit` or convert to iterative if needed.

---

### Bottom-up (Tabulation — 1D dp array)

```python
def solve(n):
    dp = [float('inf')] * (n + 1)
    dp[0] = 0          # base case
    for i in range(1, n + 1):
        dp[i] = min(dp[i-1], dp[i-2]) + cost[i]
    return dp[n]
```

---

### Bottom-up (Tabulation — 2D dp array)

```python
def solve(s1, s2):
    m, n = len(s1), len(s2)
    dp = [[0] * (n + 1) for _ in range(m + 1)]
    for i in range(1, m + 1):
        for j in range(1, n + 1):
            if s1[i-1] == s2[j-1]:
                dp[i][j] = dp[i-1][j-1] + 1
            else:
                dp[i][j] = max(dp[i-1][j], dp[i][j-1])
    return dp[m][n]
```

---

### Space-optimized (Rolling array — 2 rows instead of n rows)

```python
def solve(s1, s2):
    m, n = len(s1), len(s2)
    prev = [0] * (n + 1)
    for i in range(1, m + 1):
        curr = [0] * (n + 1)
        for j in range(1, n + 1):
            if s1[i-1] == s2[j-1]:
                curr[j] = prev[j-1] + 1
            else:
                curr[j] = max(prev[j], curr[j-1])
        prev = curr
    return prev[n]
```

---

## Complexity

| Sub-pattern | Time | Space |
|---|---|---|
| 0/1 Knapsack | O(n × W) | O(n × W) → O(W) optimized |
| Unbounded Knapsack | O(n × W) | O(W) |
| LCS | O(m × n) | O(m × n) → O(n) optimized |
| LIS (naive) | O(n²) | O(n) |
| LIS (patience sort) | O(n log n) | O(n) |
| Grid DP | O(m × n) | O(m × n) → O(n) optimized |

---

## Canonical Problem: 0/1 Knapsack

**Problem**: Given weights and values of n items and a knapsack capacity W, find the maximum value you can carry.

**Full progression — recursive → memoized → tabulated**:

```python
# 1. Pure recursive (exponential — for understanding only)
def knapsack_recursive(weights, values, capacity, n):
    if n == 0 or capacity == 0:
        return 0
    if weights[n-1] > capacity:
        return knapsack_recursive(weights, values, capacity, n-1)
    return max(
        values[n-1] + knapsack_recursive(weights, values, capacity - weights[n-1], n-1),
        knapsack_recursive(weights, values, capacity, n-1)
    )

# 2. Memoized (top-down)
from functools import lru_cache
def knapsack_memo(weights, values, capacity):
    @lru_cache(maxsize=None)
    def dp(i, cap):
        if i == 0 or cap == 0:
            return 0
        if weights[i-1] > cap:
            return dp(i-1, cap)
        return max(values[i-1] + dp(i-1, cap - weights[i-1]), dp(i-1, cap))
    return dp(len(weights), capacity)

# 3. Tabulated (bottom-up)
def knapsack_tab(weights, values, capacity):
    n = len(weights)
    dp = [[0] * (capacity + 1) for _ in range(n + 1)]
    for i in range(1, n + 1):
        for w in range(capacity + 1):
            dp[i][w] = dp[i-1][w]
            if weights[i-1] <= w:
                dp[i][w] = max(dp[i][w], values[i-1] + dp[i-1][w - weights[i-1]])
    return dp[n][capacity]
```

---

## Variations

### Equal Subset Sum Partition
Can you split array into two subsets with equal sum?
- If total sum is odd → impossible.
- Reduce to: can you find subset summing to `total // 2`? (0/1 knapsack boolean variant)

### Minimum Coin Change
Fewest coins to make amount (coins are reusable → unbounded knapsack).
- `dp[a] = min(dp[a], dp[a - coin] + 1)` for each coin.

### Longest Common Subsequence
- `dp[i][j] = dp[i-1][j-1] + 1` if chars match, else `max(dp[i-1][j], dp[i][j-1])`.
- Reconstruct path by backtracking the table.

### Longest Increasing Subsequence
- O(n²): `dp[i] = max(dp[j] + 1)` for all j < i where `nums[j] < nums[i]`.
- O(n log n): patience sorting with `bisect_left` to maintain a tails array.

### Word Break
Boolean DP: `dp[i] = True` if `s[:i]` can be segmented.
- For each end index i, try all start indices j where `dp[j]` is True and `s[j:i]` is in the dictionary.

### House Robber
Max non-adjacent sum: `dp[i] = max(dp[i-1], dp[i-2] + nums[i])`.
- Space optimize to two variables: `prev2, prev1`.

---

## Gotchas

- **Top-down is easier to write; bottom-up is faster** (no function call overhead, better cache behavior).
- **The state definition is everything** — if you define state wrong, the recurrence will be wrong. Always ask: "what information do I need to fully describe a subproblem?"
- **Forgetting the base case** — off-by-one in array sizing (`dp` of size `n+1` vs `n`) is a very common bug.
- **LCS vs LIS confusion** — LCS uses two strings and a 2D table; LIS uses one array and 1D dp.
- **0/1 Knapsack inner loop direction** — when space-optimizing to 1D, iterate `w` from `capacity` down to `weights[i]` (prevents using same item twice).
- **Unbounded Knapsack inner loop direction** — iterate `w` from `coins[i]` up to `amount` (allows reuse).
