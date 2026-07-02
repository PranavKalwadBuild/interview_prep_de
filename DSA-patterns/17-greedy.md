# 17 — Greedy

## One-Line Summary
Make the locally optimal choice at each step — works when local optimum leads to global optimum.

## Recognition Keywords
- "minimum number of jumps/moves"
- "can you reach the end" (Jump Game)
- "activity selection" / "maximum non-overlapping intervals"
- "assign tasks to minimize max completion time"
- "fractional knapsack"
- "minimum platforms"
- "gas station" / "can you complete circuit"

**Key tell:** sorting by a greedy criterion + single-pass decision; problems where picking the "best available" is never wrong.

**How to verify greedy applies — exchange argument:**
Assume an optimal solution differs from your greedy choice at step k. Show that swapping the greedy choice in makes the solution equally good or better. If that holds for all k, greedy is correct.

## Template

```python
# Greedy template
def greedy_template(items):
    # 1. Sort by greedy criterion
    items.sort(key=lambda x: x.some_attribute)

    result = initial_value
    for item in items:
        # 2. Make greedy choice — pick item if it improves/maintains result
        if greedy_condition(item, result):
            result = update(result, item)

    return result
```

## Complexity
- Typically O(n log n) due to sorting step, then O(n) for the pass

## Canonical Problem: Jump Game I

Given an array `nums` where `nums[i]` is your max jump length from index `i`, return `True` if you can reach the last index.

```python
def can_jump(nums):
    max_reach = 0
    for i, jump in enumerate(nums):
        if i > max_reach:
            return False        # can't reach this index
        max_reach = max(max_reach, i + jump)
    return True
```

## Variations

### Jump Game II — minimum jumps to reach end
Greedily extend the current jump range; increment jumps when you exhaust the current range.

### Non-overlapping Intervals — remove minimum intervals to eliminate overlaps
Sort by end time; greedily keep intervals with earliest end time (maximizes room for future intervals).

### Task Scheduler — minimum time with cooldown
Greedy: schedule the most frequent task first; fill gaps with other tasks or idle slots.
Key insight: `result = max(len(tasks), (max_freq - 1) * (n + 1) + count_of_max_freq_tasks)`

### Gas Station — find valid starting point for circular route
Total gas >= total cost guarantees a solution exists. The valid start is after the last place where running total goes negative.

### Partition Labels
Find last occurrence of each character. Walk the string; whenever index == last occurrence of all chars seen so far, cut a partition.

## Gotchas
1. **Greedy ≠ DP**: greedy fails for coin change with arbitrary denominations (e.g., coins=[1,3,4], amount=6 — greedy picks 4+1+1=3 coins but optimal is 3+3=2 coins)
2. **Always sort first**: greedy almost always needs a sort step — choose the criterion carefully (start time vs end time matters in interval problems)
3. **Exchange argument**: if you cannot prove the exchange argument, use DP instead
4. **Off-by-one in ranges**: in jump game problems, be careful whether index `i` is reachable before checking its jump
