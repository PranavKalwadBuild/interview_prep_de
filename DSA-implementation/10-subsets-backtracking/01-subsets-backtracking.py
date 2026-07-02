"""
Pattern: Subsets / Backtracking
================================
Recognition signals:
  - "all subsets" / "power set"
  - "all permutations"
  - "all combinations"
  - "generate all valid parentheses"
  - "all unique subsets" (with duplicates in input)
  - "letter case permutation"
  - "N-Queens" / "Sudoku solver"
  - Key tell: "all" or "generate all" + combinations/permutations/subsets/arrangements

----------------------------------------------------------------------
BFS SUBSET BOILERPLATE
----------------------------------------------------------------------
Start with [[]]. For each number, expand every existing subset by
appending that number to it. New subsets are added to the result.

  result = [[]]
  for num in nums:
      result += [subset + [num] for subset in result]
  return result

After num=1: [[], [1]]
After num=2: [[], [1], [2], [1,2]]
After num=3: [[], [1], [2], [1,2], [3], [1,3], [2,3], [1,2,3]]

----------------------------------------------------------------------
DFS BACKTRACKING BOILERPLATE
----------------------------------------------------------------------
Choose -> Explore -> Unchoose

  def backtrack(start, current_path):
      result.append(list(current_path))       # record state (copy!)

      for i in range(start, len(nums)):
          if i > start and nums[i] == nums[i-1]:  # skip dups (sort first)
              continue

          current_path.append(nums[i])            # CHOOSE
          backtrack(i + 1, current_path)           # EXPLORE (i+1 = no reuse)
          current_path.pop()                       # UNCHOOSE

  nums.sort()
  backtrack(0, [])

----------------------------------------------------------------------
Complexity:
  Subsets/Combinations: O(2^n)
  Permutations:         O(n!)
  Balanced Parens:      O(4^n / sqrt(n))  — Catalan number
Space: O(n) recursion stack
"""


# ---------------------------------------------------------------------------
# 1. subsets — canonical, BFS approach
# ---------------------------------------------------------------------------

def subsets(nums: list) -> list:
    """
    Return all subsets (power set) of nums. No duplicates in input.
    Uses BFS expansion: start with [[]], expand by each element.

    Time: O(n * 2^n)  Space: O(n * 2^n) for storing all subsets
    """
    result = [[]]
    for num in nums:
        # For every existing subset, create a new subset with num appended
        result += [subset + [num] for subset in result]
    return result


# ---------------------------------------------------------------------------
# 2. subsets_with_dup — handle duplicates, DFS backtracking
# ---------------------------------------------------------------------------

def subsets_with_dup(nums: list) -> list:
    """
    Return all distinct subsets when input may contain duplicates.

    Strategy:
      - Sort the array so duplicates are adjacent.
      - In the backtracking loop, skip a number if it equals the previous
        number at the same recursion level (i > start ensures we only skip
        at the same depth, not across depths).

    Time: O(n * 2^n)  Space: O(n)
    """
    nums.sort()
    result = []

    def backtrack(start, current_path):
        result.append(list(current_path))   # record every state, not just leaves

        for i in range(start, len(nums)):
            # Skip duplicate at same recursion level
            if i > start and nums[i] == nums[i - 1]:
                continue

            current_path.append(nums[i])    # CHOOSE
            backtrack(i + 1, current_path)  # EXPLORE
            current_path.pop()              # UNCHOOSE

    backtrack(0, [])
    return result


# ---------------------------------------------------------------------------
# 3. permutations — DFS backtracking with used[] array
# ---------------------------------------------------------------------------

def permutations(nums: list) -> list:
    """
    Return all permutations of nums (distinct values assumed).

    Strategy: DFS with a boolean used[] array.
    No start index — at each step pick any unused element.
    Backtrack by marking unused again after exploring.

    Time: O(n * n!)  Space: O(n)
    """
    result = []
    used   = [False] * len(nums)

    def backtrack(current_path):
        if len(current_path) == len(nums):
            result.append(list(current_path))
            return

        for i in range(len(nums)):
            if used[i]:
                continue

            used[i] = True
            current_path.append(nums[i])    # CHOOSE
            backtrack(current_path)         # EXPLORE
            current_path.pop()             # UNCHOOSE
            used[i] = False

    backtrack([])
    return result


# ---------------------------------------------------------------------------
# 4. letter_case_permutation
# ---------------------------------------------------------------------------

def letter_case_permutation(s: str) -> list:
    """
    For each letter in s, toggle case to produce all combinations.
    Digits are fixed — no branching at digit positions.

    Strategy: index-based DFS.
    At each index:
      - If digit: move to next index (single branch)
      - If letter: branch into lowercase version and uppercase version

    Since Python strings are immutable, pass s as a list for in-place mutation,
    or build by converting at each branch. We use list-of-chars for clarity.

    Time: O(2^L * n) where L = number of letters  Space: O(n)
    """
    result = []
    chars  = list(s)

    def backtrack(idx):
        if idx == len(chars):
            result.append("".join(chars))
            return

        # Explore as-is (lowercase if letter, or digit unchanged)
        backtrack(idx + 1)

        # If it's a letter, also explore with toggled case
        if chars[idx].isalpha():
            chars[idx] = chars[idx].swapcase()
            backtrack(idx + 1)
            chars[idx] = chars[idx].swapcase()  # restore

    backtrack(0)
    return result


# ---------------------------------------------------------------------------
# 5. generate_parentheses
# ---------------------------------------------------------------------------

def generate_parentheses(n: int) -> list:
    """
    Generate all valid combinations of n pairs of balanced parentheses.

    Strategy: DFS with open/close counters.
    - Add '(' if open < n
    - Add ')' if close < open
    - Collect at len(current) == 2*n

    Strings are immutable in Python so no backtracking cleanup needed —
    we pass the string by value (concatenation creates a new object).

    Time: O(4^n / sqrt(n))  — number of valid strings is the n-th Catalan number
    Space: O(n) recursion depth
    """
    result = []

    def backtrack(current, open_count, close_count):
        if len(current) == 2 * n:
            result.append(current)
            return

        if open_count < n:
            backtrack(current + "(", open_count + 1, close_count)

        if close_count < open_count:
            backtrack(current + ")", open_count, close_count + 1)

    backtrack("", 0, 0)
    return result


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

if __name__ == "__main__":

    print("=" * 60)
    print("SUBSETS / BACKTRACKING — Test Cases")
    print("=" * 60)

    # --- subsets ---
    print("\n--- subsets (BFS, no duplicates) ---")
    r1 = subsets([1, 2, 3])
    print(f"  subsets([1,2,3]) -> {r1}")
    # Expected: [[], [1], [2], [1,2], [3], [1,3], [2,3], [1,2,3]]
    print(f"  count: {len(r1)}  (expected 8 = 2^3)")

    r2 = subsets([0])
    print(f"  subsets([0]) -> {r2}")
    # Expected: [[], [0]]

    r3 = subsets([])
    print(f"  subsets([]) -> {r3}")
    # Expected: [[]]

    # --- subsets_with_dup ---
    print("\n--- subsets_with_dup (duplicates in input) ---")
    r4 = subsets_with_dup([1, 3, 3])
    print(f"  subsets_with_dup([1,3,3]) -> {r4}")
    # Expected: [[], [1], [1,3], [1,3,3], [3], [3,3]]
    print(f"  count: {len(r4)}  (expected 6, not 8)")

    r5 = subsets_with_dup([1, 2, 2])
    print(f"  subsets_with_dup([1,2,2]) -> {r5}")
    # Expected: [[], [1], [1,2], [1,2,2], [2], [2,2]]

    # --- permutations ---
    print("\n--- permutations ---")
    r6 = permutations([1, 2, 3])
    print(f"  permutations([1,2,3]) -> {r6}")
    print(f"  count: {len(r6)}  (expected 6 = 3!)")

    r7 = permutations([0, 1])
    print(f"  permutations([0,1]) -> {r7}")
    # Expected: [[0,1], [1,0]]

    r8 = permutations([1])
    print(f"  permutations([1]) -> {r8}")
    # Expected: [[1]]

    # --- letter_case_permutation ---
    print("\n--- letter_case_permutation ---")
    r9 = letter_case_permutation("a1b2")
    r9_sorted = sorted(r9)
    print(f"  letter_case_permutation('a1b2') -> {r9_sorted}")
    # Expected (sorted): ['A1B2', 'A1b2', 'a1B2', 'a1b2']
    print(f"  count: {len(r9)}  (expected 4 = 2^2 letters)")

    r10 = letter_case_permutation("3z4")
    r10_sorted = sorted(r10)
    print(f"  letter_case_permutation('3z4') -> {r10_sorted}")
    # Expected: ['3Z4', '3z4']
    print(f"  count: {len(r10)}  (expected 2 = 2^1 letter)")

    r11 = letter_case_permutation("12345")
    print(f"  letter_case_permutation('12345') -> {r11}")
    # Expected: ['12345'] — no letters, single result

    # --- generate_parentheses ---
    print("\n--- generate_parentheses ---")
    r12 = generate_parentheses(3)
    print(f"  generate_parentheses(3) -> {sorted(r12)}")
    # Expected (sorted): ['((()))', '(()())', '(())()', '()(())', '()()()']
    print(f"  count: {len(r12)}  (expected 5 = Catalan(3))")

    r13 = generate_parentheses(1)
    print(f"  generate_parentheses(1) -> {r13}")
    # Expected: ['()']

    r14 = generate_parentheses(2)
    print(f"  generate_parentheses(2) -> {sorted(r14)}")
    # Expected: ['(())', '()()']
    print(f"  count: {len(r14)}  (expected 2 = Catalan(2))")

    print("\n" + "=" * 60)
    print("All Subsets / Backtracking tests complete.")
    print("=" * 60)
