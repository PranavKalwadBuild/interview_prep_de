"""
Pattern: Two Heaps
==================
Recognition signals:
  - "median of a stream" / "running median"
  - "find median from data stream"
  - "sliding window median"
  - "maximize capital" / "IPO problem"
  - "scheduling tasks with cooldown"
  - Key tell: repeatedly finding the median under dynamic inserts/deletes;
    balancing two groups by a ranked property

Core idea:
  - max_heap (lower half): stores elements <= median; Python: negate values
  - min_heap (upper half): stores elements >= median
  - Invariant: every element in max_heap <= every element in min_heap
  - Size rule: max_heap can be at most 1 larger than min_heap
  - Median: if sizes equal -> average of tops; else -> top of max_heap

Complexity: O(log n) insert, O(1) find_median
"""

import heapq
from collections import defaultdict


# ---------------------------------------------------------------------------
# 1. MedianFinder — canonical
# ---------------------------------------------------------------------------

class MedianFinder:
    """
    Find Median from Data Stream.
    Supports add_num(int) and find_median() in O(log n) and O(1) respectively.
    """

    def __init__(self):
        self.max_heap = []   # lower half; negate for max-heap behavior
        self.min_heap = []   # upper half; standard min-heap

    def add_num(self, num: int) -> None:
        # Step 1: push to max_heap first (always)
        heapq.heappush(self.max_heap, -num)

        # Step 2: enforce value invariant (max of lower <= min of upper)
        if self.min_heap and (-self.max_heap[0]) > self.min_heap[0]:
            heapq.heappush(self.min_heap, -heapq.heappop(self.max_heap))

        # Step 3: enforce size invariant
        if len(self.max_heap) > len(self.min_heap) + 1:
            heapq.heappush(self.min_heap, -heapq.heappop(self.max_heap))
        elif len(self.min_heap) > len(self.max_heap):
            heapq.heappush(self.max_heap, -heapq.heappop(self.min_heap))

    def find_median(self) -> float:
        if len(self.max_heap) == len(self.min_heap):
            return (-self.max_heap[0] + self.min_heap[0]) / 2.0
        return float(-self.max_heap[0])


# ---------------------------------------------------------------------------
# 2. SlidingWindowMedian
# ---------------------------------------------------------------------------

class SlidingWindowMedian:
    """
    Median of every k-size sliding window.

    Lazy deletion: when an element leaves the window, mark it in a removal
    dict. Before reading the top of a heap, discard any marked elements.
    Re-balance after each removal.
    """

    def __init__(self):
        self.max_heap = []   # lower half (negated)
        self.min_heap = []   # upper half
        self.to_remove = defaultdict(int)

    def _balance(self):
        """Ensure size invariant: |max_heap| == |min_heap| or |max_heap| == |min_heap|+1."""
        # Prune tops
        while self.max_heap and self.to_remove[-self.max_heap[0]] > 0:
            self.to_remove[-self.max_heap[0]] -= 1
            heapq.heappop(self.max_heap)
        while self.min_heap and self.to_remove[self.min_heap[0]] > 0:
            self.to_remove[self.min_heap[0]] -= 1
            heapq.heappop(self.min_heap)

    def _rebalance_size(self, max_size, min_size):
        if max_size > min_size + 1:
            heapq.heappush(self.min_heap, -heapq.heappop(self.max_heap))
        elif min_size > max_size:
            heapq.heappush(self.max_heap, -heapq.heappop(self.min_heap))

    def medians(self, nums: list, k: int) -> list:
        result = []
        max_size = 0
        min_size = 0

        for i, num in enumerate(nums):
            # Add new element
            if not self.max_heap or num <= -self.max_heap[0]:
                heapq.heappush(self.max_heap, -num)
                max_size += 1
            else:
                heapq.heappush(self.min_heap, num)
                min_size += 1

            # Rebalance sizes
            if max_size > min_size + 1:
                heapq.heappush(self.min_heap, -heapq.heappop(self.max_heap))
                max_size -= 1
                min_size += 1
            elif min_size > max_size:
                heapq.heappush(self.max_heap, -heapq.heappop(self.min_heap))
                min_size -= 1
                max_size += 1

            # Window is full starting at index k-1
            if i >= k - 1:
                # Record median
                if max_size == min_size:
                    result.append((-self.max_heap[0] + self.min_heap[0]) / 2.0)
                else:
                    result.append(float(-self.max_heap[0]))

                # Remove the outgoing element (lazy deletion)
                outgoing = nums[i - k + 1]
                self.to_remove[outgoing] += 1

                if outgoing <= -self.max_heap[0]:
                    max_size -= 1
                else:
                    min_size -= 1

                # Prune lazy-deleted tops and rebalance
                self._balance()

                if max_size > min_size + 1:
                    heapq.heappush(self.min_heap, -heapq.heappop(self.max_heap))
                    max_size -= 1
                    min_size += 1
                elif min_size > max_size:
                    heapq.heappush(self.max_heap, -heapq.heappop(self.min_heap))
                    min_size -= 1
                    max_size += 1

                self._balance()

        return result


# ---------------------------------------------------------------------------
# 3. maximize_capital (IPO)
# ---------------------------------------------------------------------------

def maximize_capital(k: int, w: int, profits: list, capital: list) -> int:
    """
    IPO / Maximize Capital.
    Given n projects each with profit[i] and required capital[i],
    start with capital w, pick at most k projects to maximize final capital.
    Can only start a project if current capital >= capital[i].

    Strategy:
      1. Min-heap sorted by capital: (capital[i], profit[i])
      2. Max-heap of profits of affordable projects (negate for Python)
      Repeat k times:
        - Push all projects affordable with current capital into max-heap
        - Pick the project with highest profit

    Time: O(n log n + k log n)  Space: O(n)
    """
    # Build min-heap on capital
    projects = list(zip(capital, profits))
    heapq.heapify(projects)          # (capital, profit) min-heap

    available = []                   # max-heap for profits (negated)

    for _ in range(k):
        # Unlock all affordable projects
        while projects and projects[0][0] <= w:
            cap, prof = heapq.heappop(projects)
            heapq.heappush(available, -prof)

        if not available:
            break   # no project affordable; stop early

        # Pick most profitable available project
        w += -heapq.heappop(available)

    return w


# ---------------------------------------------------------------------------
# 4. find_next_interval
# ---------------------------------------------------------------------------

def find_next_interval(intervals: list) -> list:
    """
    For each interval, find the interval with the smallest start >= current end.
    Return an array of indices (-1 if no such interval exists).

    intervals[i] = [start, end]

    Strategy:
      - Max-heap on start times: (-start, original_index)
      - Max-heap on end   times: (-end,   original_index)
      Process each interval in order of descending end:
        For this end, find the smallest start >= end.
        Pop all starts from start_heap that are >= end; the last valid one is the answer.
        Push back all popped starts except the chosen minimum.

    Simpler approach: two max-heaps, process greedily.
    Actually clearest: iterate ends largest-first; for each end walk starts.

    Cleaner O(n log n) approach used here:
      - start_heap: max-heap of (start, idx)
      - end_heap:   max-heap of (end, idx)
      For each pop from end_heap:
        Pop starts that are >= this end, keep the minimum one (last popped
        since we're going largest-to-smallest). Re-push the rest.
    """
    n = len(intervals)
    result = [-1] * n

    # Max-heap on start (negate); (start, original_index)
    start_heap = [(-intervals[i][0], i) for i in range(n)]
    heapq.heapify(start_heap)

    # Max-heap on end (negate); (end, original_index)
    end_heap = [(-intervals[i][1], i) for i in range(n)]
    heapq.heapify(end_heap)

    for _ in range(n):
        _, end_idx = heapq.heappop(end_heap)
        end_val    = intervals[end_idx][1]

        # Find smallest start >= end_val
        # Pop starts that qualify (start >= end_val); keep the minimum start
        best_start_idx = -1
        temp = []

        while start_heap and (-start_heap[0][0]) >= end_val:
            neg_start, s_idx = heapq.heappop(start_heap)
            # Keep track of minimum qualifying start
            if best_start_idx == -1 or intervals[s_idx][0] < intervals[best_start_idx][0]:
                if best_start_idx != -1:
                    temp.append((-intervals[best_start_idx][0], best_start_idx))
                best_start_idx = s_idx
            else:
                temp.append((neg_start, s_idx))

        # Push back all except chosen
        for item in temp:
            heapq.heappush(start_heap, item)

        result[end_idx] = best_start_idx

    return result


# ---------------------------------------------------------------------------
# 5. least_interval
# ---------------------------------------------------------------------------

def least_interval(tasks: list, n: int) -> int:
    """
    CPU Scheduling: given tasks (letters) and a cooldown n between same tasks,
    find the minimum number of intervals (including idle) to finish all tasks.

    Strategy: always schedule the most frequent remaining task.
    Use a max-heap of (count, task). After scheduling, cooldown period of n.
    Use a queue to track tasks on cooldown: (count_remaining, available_at_time).

    Time: O(m * n) where m = number of distinct tasks  Space: O(m)
    """
    from collections import Counter, deque

    freq    = Counter(tasks)
    heap    = [-count for count in freq.values()]
    heapq.heapify(heap)

    time    = 0
    cooldown_queue = deque()   # (neg_count, available_at_time)

    while heap or cooldown_queue:
        time += 1

        if heap:
            neg_count = heapq.heappop(heap)
            remaining = neg_count + 1    # neg_count is negative; add 1 = reduce count
            if remaining < 0:            # still has remaining executions
                cooldown_queue.append((remaining, time + n))
        # If heap is empty, CPU is idle (time still increments)

        # Re-add tasks whose cooldown has expired
        if cooldown_queue and cooldown_queue[0][1] == time:
            heapq.heappush(heap, cooldown_queue.popleft()[0])

    return time


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

if __name__ == "__main__":

    print("=" * 60)
    print("TWO HEAPS — Test Cases")
    print("=" * 60)

    # --- MedianFinder ---
    print("\n--- MedianFinder (running median) ---")
    mf = MedianFinder()
    for num in [3, 1, 5, 4]:
        mf.add_num(num)
        print(f"  add({num:2d}) -> median = {mf.find_median()}")
    # Expected: 3.0, 2.0, 3.0, 3.5

    print()
    mf2 = MedianFinder()
    for num in [2, 3, 4]:
        mf2.add_num(num)
        print(f"  add({num:2d}) -> median = {mf2.find_median()}")
    # Expected: 2.0, 2.5, 3.0

    # --- SlidingWindowMedian ---
    print("\n--- SlidingWindowMedian ---")
    swm = SlidingWindowMedian()
    nums = [1, 3, -1, -3, 5, 3, 6, 7]
    k    = 3
    print(f"  nums={nums}, k={k}")
    print(f"  medians={swm.medians(nums, k)}")
    # Expected: [1.0, -1.0, -1.0, 3.0, 5.0, 6.0]

    swm2 = SlidingWindowMedian()
    print(f"  nums=[1,2,3,4,5], k=2 -> {swm2.medians([1,2,3,4,5], 2)}")
    # Expected: [1.5, 2.5, 3.5, 4.5]

    # --- maximize_capital (IPO) ---
    print("\n--- maximize_capital (IPO) ---")
    # k=2, w=0, profits=[1,2,3], capital=[0,1,1]
    # Round1: affordable={project0 (cap=0)}, pick profit=1 -> w=1
    # Round2: affordable={project1,project2 (cap=1)}, pick profit=3 -> w=4
    result = maximize_capital(k=2, w=0, profits=[1, 2, 3], capital=[0, 1, 1])
    print(f"  k=2, w=0, profits=[1,2,3], capital=[0,1,1] -> {result}")  # 4

    result2 = maximize_capital(k=3, w=0, profits=[1, 2, 3], capital=[0, 1, 2])
    print(f"  k=3, w=0, profits=[1,2,3], capital=[0,1,2] -> {result2}")  # 6

    # --- find_next_interval ---
    print("\n--- find_next_interval ---")
    # intervals = [[2,3],[3,4],[5,6]]
    # end=3 -> smallest start>=3 is interval[1] start=3 -> idx=1
    # end=4 -> smallest start>=4 is interval[2] start=5 -> idx=2
    # end=6 -> no interval with start>=6 -> -1
    iv1 = [[2, 3], [3, 4], [5, 6]]
    print(f"  intervals={iv1} -> {find_next_interval(iv1)}")  # [1, 2, -1]

    iv2 = [[3, 4], [1, 5], [4, 6]]
    print(f"  intervals={iv2} -> {find_next_interval(iv2)}")  # [2, -1, -1]

    # --- least_interval ---
    print("\n--- least_interval (CPU scheduling) ---")
    tasks1 = ["A", "A", "A", "B", "B", "B"]
    print(f"  tasks={tasks1}, n=2 -> {least_interval(tasks1, 2)}")  # 8

    tasks2 = ["A", "A", "A", "B", "B", "B"]
    print(f"  tasks={tasks2}, n=0 -> {least_interval(tasks2, 0)}")  # 6

    tasks3 = ["A", "A", "A", "A", "A", "A", "B", "C", "D", "E", "F", "G"]
    print(f"  tasks={tasks3}, n=2 -> {least_interval(tasks3, 2)}")  # 16

    print("\n" + "=" * 60)
    print("All Two Heaps tests complete.")
    print("=" * 60)
