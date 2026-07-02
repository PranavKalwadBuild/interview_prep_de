"""
14-dynamic-programming.py
Pattern: Dynamic Programming

Recognition signals:
  - "minimum/maximum ways"  → optimization DP
  - "count the number of ways" → counting DP
  - "is it possible"        → boolean DP
  - "longest/shortest"      → LCS/LIS family
  - "overlapping subproblems + optimal substructure" → DP applies

Sub-patterns by trigger:
  0/1 Knapsack     : "include or exclude"       → dp[i][w] (2D)
  Unbounded Knapsack: "items can repeat"         → dp[w] (1D)
  Fibonacci        : "depends on prev 1-2 items" → O(n) with 2 vars
  LCS              : "two strings"               → dp[i][j] (2D)
  LIS              : "increasing subsequence"    → dp[i] = longest ending at i
"""

# ─────────────────────────────────────────────────────────────────────────────
# BOILERPLATE TEMPLATES
# ─────────────────────────────────────────────────────────────────────────────

# ── TEMPLATE 1: Top-down Memoization (lru_cache) ──────────────────────────
#
# from functools import lru_cache
#
# def solve(input_data):
#     @lru_cache(maxsize=None)
#     def dp(state):
#         # 1. Base case
#         if state == 0:
#             return BASE_VALUE
#         # 2. Recurrence: express dp(state) in terms of smaller states
#         return COMBINE(dp(state - 1), dp(state - 2))
#     return dp(len(input_data))
#
# Pros: easiest to write; mirrors the recurrence directly.
# Cons: Python call-stack overhead; recursion depth limit (~1000 default).
# Tip: add sys.setrecursionlimit(10**6) for large inputs.

# ── TEMPLATE 2: Bottom-up Tabulation ─────────────────────────────────────
#
# 1D version:
# def solve(n):
#     dp = [INITIAL] * (n + 1)
#     dp[0] = BASE_CASE
#     for i in range(1, n + 1):
#         dp[i] = RECURRENCE using dp[i-1], dp[i-2], ...
#     return dp[n]
#
# 2D version:
# def solve(s1, s2):
#     m, n = len(s1), len(s2)
#     dp = [[0] * (n + 1) for _ in range(m + 1)]
#     for i in range(1, m + 1):
#         for j in range(1, n + 1):
#             if MATCH:
#                 dp[i][j] = dp[i-1][j-1] + 1
#             else:
#                 dp[i][j] = COMBINE(dp[i-1][j], dp[i][j-1])
#     return dp[m][n]
#
# Pros: faster (no call overhead), better cache behavior, no stack risk.

# ── TEMPLATE 3: Space-optimized (Rolling Array) ───────────────────────────
#
# Replace the full 2D table with 2 rows (prev + curr):
#
# def solve(s1, s2):
#     m, n = len(s1), len(s2)
#     prev = [0] * (n + 1)
#     for i in range(1, m + 1):
#         curr = [0] * (n + 1)
#         for j in range(1, n + 1):
#             if s1[i-1] == s2[j-1]:
#                 curr[j] = prev[j-1] + 1
#             else:
#                 curr[j] = max(prev[j], curr[j-1])
#         prev = curr
#     return prev[n]
#
# Reduces O(m*n) space to O(n).
# For 0/1 Knapsack space optimization: iterate w from capacity DOWN to weight
# (prevents counting same item twice in the same row).

# ─────────────────────────────────────────────────────────────────────────────
# IMPLEMENTATIONS
# ─────────────────────────────────────────────────────────────────────────────

from functools import lru_cache
import bisect


# 1. 0/1 Knapsack — full recursive → memoized → tabulated progression
# ─────────────────────────────────────────────────────────────────────────────
# Problem: given item weights and values + capacity W,
# pick items (each at most once) to maximize total value.

def knapsack_01(weights, values, capacity):
    n = len(weights)

    # ── Stage 1: Pure recursive (exponential, for understanding only) ──
    def recursive(i, cap):
        if i == 0 or cap == 0:
            return 0
        if weights[i - 1] > cap:
            return recursive(i - 1, cap)
        include = values[i - 1] + recursive(i - 1, cap - weights[i - 1])
        exclude = recursive(i - 1, cap)
        return max(include, exclude)

    # ── Stage 2: Memoized (top-down) ──
    @lru_cache(maxsize=None)
    def memo(i, cap):
        if i == 0 or cap == 0:
            return 0
        if weights[i - 1] > cap:
            return memo(i - 1, cap)
        return max(
            values[i - 1] + memo(i - 1, cap - weights[i - 1]),
            memo(i - 1, cap)
        )

    # ── Stage 3: Tabulated (bottom-up) — preferred in interviews ──
    # dp[i][w] = max value using first i items with capacity w
    dp = [[0] * (capacity + 1) for _ in range(n + 1)]
    for i in range(1, n + 1):
        for w in range(capacity + 1):
            dp[i][w] = dp[i - 1][w]  # exclude item i
            if weights[i - 1] <= w:
                dp[i][w] = max(dp[i][w],
                               values[i - 1] + dp[i - 1][w - weights[i - 1]])

    result_tab = dp[n][capacity]

    # All three should agree
    result_rec = recursive(n, capacity)
    result_memo = memo(n, capacity)
    return result_rec, result_memo, result_tab


# 2. Equal Subset Sum Partition
# ─────────────────────────────────────────────────────────────────────────────
# Problem: can you split nums into two subsets with equal sum?
# Key insight: find subset summing to total // 2  (0/1 knapsack boolean variant)
# Space-optimized: 1D dp, iterate w from target DOWN to nums[i].

def equal_subset_sum(nums):
    total = sum(nums)
    if total % 2 != 0:
        return False
    target = total // 2

    # dp[w] = True if subset summing to w is achievable
    dp = [False] * (target + 1)
    dp[0] = True  # empty subset sums to 0

    for num in nums:
        # iterate backwards to avoid using same item twice (0/1 constraint)
        for w in range(target, num - 1, -1):
            dp[w] = dp[w] or dp[w - num]

    return dp[target]


# 3. Minimum Coin Change
# ─────────────────────────────────────────────────────────────────────────────
# Problem: fewest coins to make amount; coins are reusable (unbounded knapsack).
# Key: iterate w FORWARD so same coin can be reused in same pass.

def min_coin_change(coins, amount):
    dp = [float('inf')] * (amount + 1)
    dp[0] = 0  # 0 coins needed to make amount 0

    for coin in coins:
        for a in range(coin, amount + 1):  # forward = unbounded reuse
            if dp[a - coin] != float('inf'):
                dp[a] = min(dp[a], dp[a - coin] + 1)

    return dp[amount] if dp[amount] != float('inf') else -1


# 4. Longest Common Subsequence
# ─────────────────────────────────────────────────────────────────────────────
# Problem: length of LCS of s1 and s2 + reconstruct the actual subsequence.
# dp[i][j] = LCS length of s1[:i] and s2[:j]

def longest_common_subsequence(s1, s2):
    m, n = len(s1), len(s2)
    dp = [[0] * (n + 1) for _ in range(m + 1)]

    for i in range(1, m + 1):
        for j in range(1, n + 1):
            if s1[i - 1] == s2[j - 1]:
                dp[i][j] = dp[i - 1][j - 1] + 1
            else:
                dp[i][j] = max(dp[i - 1][j], dp[i][j - 1])

    # Reconstruct the actual LCS by backtracking the table
    lcs_chars = []
    i, j = m, n
    while i > 0 and j > 0:
        if s1[i - 1] == s2[j - 1]:
            lcs_chars.append(s1[i - 1])
            i -= 1
            j -= 1
        elif dp[i - 1][j] > dp[i][j - 1]:
            i -= 1
        else:
            j -= 1
    lcs_str = ''.join(reversed(lcs_chars))

    return dp[m][n], lcs_str


# 5. Longest Increasing Subsequence
# ─────────────────────────────────────────────────────────────────────────────
# Problem: length of LIS in nums.
# O(n²) approach: dp[i] = length of LIS ending at index i.
# O(n log n) patience sort: maintain a 'tails' array where tails[i] is the
#   smallest tail of all increasing subsequences of length i+1.

def longest_increasing_subsequence(nums):
    n = len(nums)
    if n == 0:
        return 0, 0

    # ── O(n²) ──
    dp = [1] * n
    for i in range(1, n):
        for j in range(i):
            if nums[j] < nums[i]:
                dp[i] = max(dp[i], dp[j] + 1)
    lis_n2 = max(dp)

    # ── O(n log n) patience sorting ──
    # tails[i] = smallest ending element of any IS of length i+1
    tails = []
    for num in nums:
        pos = bisect.bisect_left(tails, num)  # find insertion point
        if pos == len(tails):
            tails.append(num)   # extend LIS
        else:
            tails[pos] = num    # replace with smaller tail (greedy)
    lis_nlogn = len(tails)

    return lis_n2, lis_nlogn


# 6. House Robber
# ─────────────────────────────────────────────────────────────────────────────
# Problem: max money robbing houses; cannot rob two adjacent houses.
# dp[i] = max(dp[i-1], dp[i-2] + nums[i])
# Space-optimized to two variables.

def house_robber(nums):
    if not nums:
        return 0
    if len(nums) == 1:
        return nums[0]

    prev2 = 0          # dp[i-2]
    prev1 = 0          # dp[i-1]

    for num in nums:
        curr = max(prev1, prev2 + num)
        prev2 = prev1
        prev1 = curr

    return prev1


# 7. Word Break
# ─────────────────────────────────────────────────────────────────────────────
# Problem: can string s be segmented into words all in word_dict?
# dp[i] = True if s[:i] can be segmented.
# For each end index i, try all start indices j where dp[j] is True
# and s[j:i] is in the dictionary.

def word_break(s, word_dict):
    word_set = set(word_dict)  # O(1) lookup
    n = len(s)
    dp = [False] * (n + 1)
    dp[0] = True  # empty prefix is always valid

    for i in range(1, n + 1):
        for j in range(i):
            if dp[j] and s[j:i] in word_set:
                dp[i] = True
                break  # no need to check other j once True

    return dp[n]


# ─────────────────────────────────────────────────────────────────────────────
# TEST PRINTS
# ─────────────────────────────────────────────────────────────────────────────

if __name__ == "__main__":

    # 1. 0/1 Knapsack
    weights = [1, 3, 4, 5]
    values  = [1, 4, 5, 7]
    capacity = 7
    rec, memo_res, tab = knapsack_01(weights, values, capacity)
    print(f"Knapsack 0/1 — recursive: {rec}, memo: {memo_res}, tabulated: {tab}")
    # Expected: 9 (items 2+3: weight 3+4=7, value 4+5=9)

    # 2. Equal Subset Sum
    print(f"\nEqual subset sum [1,5,11,5]: {equal_subset_sum([1, 5, 11, 5])}")  # True
    print(f"Equal subset sum [1,2,3,5]: {equal_subset_sum([1, 2, 3, 5])}")      # False

    # 3. Min Coin Change
    print(f"\nMin coins (coins=[1,5,6,9], amount=11): {min_coin_change([1,5,6,9], 11)}")  # 2 (5+6)
    print(f"Min coins (coins=[2], amount=3): {min_coin_change([2], 3)}")                   # -1

    # 4. LCS
    length, lcs = longest_common_subsequence("abcde", "ace")
    print(f"\nLCS('abcde','ace') — length: {length}, subsequence: '{lcs}'")  # 3, 'ace'

    length2, lcs2 = longest_common_subsequence("abc", "abc")
    print(f"LCS('abc','abc') — length: {length2}, subsequence: '{lcs2}'")    # 3, 'abc'

    # 5. LIS
    n2, nlogn = longest_increasing_subsequence([10, 9, 2, 5, 3, 7, 101, 18])
    print(f"\nLIS [10,9,2,5,3,7,101,18] — O(n²): {n2}, O(n log n): {nlogn}")  # 4

    n2b, nlognb = longest_increasing_subsequence([0, 1, 0, 3, 2, 3])
    print(f"LIS [0,1,0,3,2,3] — O(n²): {n2b}, O(n log n): {nlognb}")          # 4

    # 6. House Robber
    print(f"\nHouse robber [2,7,9,3,1]: {house_robber([2, 7, 9, 3, 1])}")  # 12 (2+9+1)
    print(f"House robber [2,1,1,2]:   {house_robber([2, 1, 1, 2])}")        # 4  (2+2)

    # 7. Word Break
    print(f"\nWord break ('leetcode', ['leet','code']): {word_break('leetcode', ['leet', 'code'])}")           # True
    print(f"Word break ('applepenapple', ['apple','pen']): {word_break('applepenapple', ['apple','pen'])}")    # True
    print(f"Word break ('catsandog', ['cats','dog','sand','and','cat']): {word_break('catsandog', ['cats','dog','sand','and','cat'])}")  # False
