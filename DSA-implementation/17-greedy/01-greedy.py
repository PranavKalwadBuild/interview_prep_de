"""
Greedy — Templates and Problems
=================================
Pattern : Make the locally optimal choice at each step.
          Works when local optimum guarantees global optimum.

How to verify: Exchange argument — swapping any two choices makes result
               equal or worse → greedy is correct.

Template: sort by greedy criterion → single pass making greedy choices.

Complexity: typically O(n log n) due to sort + O(n) pass.
"""

from typing import List


# ─────────────────────────────────────────────
# GREEDY TEMPLATE (illustrative)
# ─────────────────────────────────────────────

def greedy_template(items: list) -> int:
    """
    Generic greedy skeleton:
      1. Sort by greedy criterion
      2. Single pass: make greedy choice at each step
      3. Return accumulated result
    """
    items.sort()          # sort by relevant criterion
    result = 0
    state = None
    for item in items:
        if state is None or greedy_condition(item, state):   # type: ignore[name-defined]
            state = item
            result += 1
    return result


# ─────────────────────────────────────────────
# PROBLEM 1: Jump Game I — can you reach the last index? (CANONICAL)
# ─────────────────────────────────────────────

def can_jump(nums: List[int]) -> bool:
    """
    LeetCode 55 — Jump Game
    nums[i] = max jump length from index i.
    Return True if you can reach the last index.

    Greedy: track max_reach. If current index exceeds max_reach, unreachable.

    Exchange argument: always extending max_reach is never worse than a smaller choice.

    Time: O(n)  Space: O(1)
    """
    max_reach = 0
    for i, jump in enumerate(nums):
        if i > max_reach:
            return False         # this index is unreachable
        max_reach = max(max_reach, i + jump)
    return True


# ─────────────────────────────────────────────
# PROBLEM 2: Jump Game II — minimum jumps to reach end
# ─────────────────────────────────────────────

def jump_game_ii(nums: List[int]) -> int:
    """
    LeetCode 45 — Jump Game II
    Return the minimum number of jumps to reach the last index.
    Assume you can always reach the end.

    Greedy: maintain current range [lo, hi] reachable with `jumps` jumps.
            When i reaches hi, we must jump — extend to farthest reachable.

    Time: O(n)  Space: O(1)
    """
    jumps = 0
    current_end = 0     # farthest index reachable with `jumps` jumps
    farthest = 0        # farthest index reachable with `jumps+1` jumps

    for i in range(len(nums) - 1):   # no need to jump from last index
        farthest = max(farthest, i + nums[i])
        if i == current_end:         # exhausted current jump range
            jumps += 1
            current_end = farthest

    return jumps


# ─────────────────────────────────────────────
# PROBLEM 3: Non-overlapping Intervals — minimum removals
# ─────────────────────────────────────────────

def erase_overlap_intervals(intervals: List[List[int]]) -> int:
    """
    LeetCode 435 — Non-overlapping Intervals
    Return the minimum number of intervals to remove so the rest don't overlap.

    Greedy: sort by END time. Greedily keep intervals with earliest end time —
            this maximises room for future intervals (activity selection problem).
            Count overlapping intervals (those that start before prev_end).

    Exchange argument: if we swap a kept interval for one with a later end time,
                       we can only reduce future choices — greedy is optimal.

    Time: O(n log n)  Space: O(1)
    """
    if not intervals:
        return 0

    intervals.sort(key=lambda x: x[1])   # sort by end time
    removed = 0
    prev_end = intervals[0][1]

    for start, end in intervals[1:]:
        if start < prev_end:
            # Overlap: remove the interval with the later end (greedy keeps earlier end)
            removed += 1
            # prev_end stays — we keep the one with the smaller end time
        else:
            # No overlap: update prev_end
            prev_end = end

    return removed


# ─────────────────────────────────────────────
# PROBLEM 4: Gas Station — find valid starting index
# ─────────────────────────────────────────────

def gas_station(gas: List[int], cost: List[int]) -> int:
    """
    LeetCode 134 — Gas Station
    Find the starting gas station index to complete the circular route.
    Return -1 if impossible.

    Greedy insight 1: if total_gas >= total_cost, a solution always exists.
    Greedy insight 2: the valid starting station is right after the last
                      point where the running tank goes negative.

    Time: O(n)  Space: O(1)
    """
    total_tank = 0
    current_tank = 0
    start = 0

    for i in range(len(gas)):
        gain = gas[i] - cost[i]
        total_tank += gain
        current_tank += gain

        if current_tank < 0:
            # Cannot start from anywhere in [start, i]; try starting at i+1
            start = i + 1
            current_tank = 0

    return start if total_tank >= 0 else -1


# ─────────────────────────────────────────────
# PROBLEM 5: Partition Labels — max partitions, each char in one part
# ─────────────────────────────────────────────

def partition_labels(s: str) -> List[int]:
    """
    LeetCode 763 — Partition Labels
    Partition string s so every character appears in at most one part.
    Return a list of partition sizes (maximize number of parts).

    Greedy: record last occurrence of each character.
            Walk the string; track the farthest last-occurrence seen so far.
            When index == farthest, we have a complete partition — cut here.

    Time: O(n)  Space: O(1) — at most 26 characters
    """
    last = {c: i for i, c in enumerate(s)}   # last occurrence of each char

    partitions = []
    start = 0
    end = 0

    for i, c in enumerate(s):
        end = max(end, last[c])   # extend partition to include all occurrences of c
        if i == end:              # all chars in this partition have been seen
            partitions.append(end - start + 1)
            start = i + 1

    return partitions


# ─────────────────────────────────────────────
# TESTS
# ─────────────────────────────────────────────

if __name__ == '__main__':
    # can_jump
    assert can_jump([2, 3, 1, 1, 4]) == True
    assert can_jump([3, 2, 1, 0, 4]) == False
    print("can_jump: PASS")

    # jump_game_ii
    assert jump_game_ii([2, 3, 1, 1, 4]) == 2
    assert jump_game_ii([2, 3, 0, 1, 4]) == 2
    print("jump_game_ii: PASS")

    # erase_overlap_intervals
    assert erase_overlap_intervals([[1,2],[2,3],[3,4],[1,3]]) == 1
    assert erase_overlap_intervals([[1,2],[1,2],[1,2]]) == 2
    assert erase_overlap_intervals([[1,2],[2,3]]) == 0
    print("erase_overlap_intervals: PASS")

    # gas_station
    assert gas_station([1,2,3,4,5], [3,4,5,1,2]) == 3
    assert gas_station([2,3,4], [3,4,3]) == -1
    print("gas_station: PASS")

    # partition_labels
    assert partition_labels("ababcbacadefegdehijhklij") == [9, 7, 8]
    assert partition_labels("eccbbbbdec") == [10]
    print("partition_labels: PASS")

    print("\nAll greedy tests passed.")
