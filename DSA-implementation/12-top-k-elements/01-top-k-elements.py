"""
Top K Elements — DSA Pattern #12
==================================
Use a min-heap of size k to efficiently find top-k largest/smallest/frequent elements.

BOILERPLATE TEMPLATES
---------------------

1. Min-Heap of Size K (Top K Largest):
   import heapq
   min_heap = []
   for num in nums:
       heapq.heappush(min_heap, num)
       if len(min_heap) > k:
           heapq.heappop(min_heap)   # evict the current smallest
   # min_heap now holds top-k largest elements

2. Max-Heap in Python (Negate Values):
   heapq.heappush(max_heap, -num)
   top = -heapq.heappop(max_heap)

3. QuickSelect (O(n) Average for Kth Position):
   import random
   def partition(lo, hi):
       pivot_idx = random.randint(lo, hi)
       nums[pivot_idx], nums[hi] = nums[hi], nums[pivot_idx]
       pivot, store = nums[hi], lo
       for i in range(lo, hi):
           if nums[i] >= pivot:
               nums[store], nums[i] = nums[i], nums[store]
               store += 1
       nums[store], nums[hi] = nums[hi], nums[store]
       return store
"""

import heapq
import random
from collections import Counter
from typing import List


# --------------------------------------------------------------------------- #
# 1. Canonical: Kth Largest Element in Array
# --------------------------------------------------------------------------- #

def kth_largest(nums: List[int], k: int) -> int:
    """
    Return the kth largest element in nums (1-indexed).
    LeetCode 215.

    Approach: maintain a min-heap of size k. The root is the kth largest.
    Time: O(n log k), Space: O(k).
    """
    min_heap = []
    for num in nums:
        heapq.heappush(min_heap, num)
        if len(min_heap) > k:
            heapq.heappop(min_heap)
    return min_heap[0]


# --------------------------------------------------------------------------- #
# 2. K Closest Points to Origin
# --------------------------------------------------------------------------- #

def k_closest_points(points: List[List[int]], k: int) -> List[List[int]]:
    """
    Return k closest points to origin (0, 0) by Euclidean distance.
    LeetCode 973.

    Approach: max-heap of size k keyed by distance squared (no sqrt needed).
    Store (-dist_sq, x, y) so Python's min-heap behaves as max-heap on dist_sq.
    Time: O(n log k), Space: O(k).
    """
    max_heap = []
    for x, y in points:
        dist_sq = x * x + y * y
        heapq.heappush(max_heap, (-dist_sq, x, y))
        if len(max_heap) > k:
            heapq.heappop(max_heap)
    return [[x, y] for _, x, y in max_heap]


# --------------------------------------------------------------------------- #
# 3. Top K Frequent Elements
# --------------------------------------------------------------------------- #

def top_k_frequent(nums: List[int], k: int) -> List[int]:
    """
    Return the k most frequent elements in nums.
    LeetCode 347.

    Approach: count frequencies with Counter, then use a min-heap of size k
    keyed by frequency. Evict least frequent when heap exceeds k.
    Time: O(n log k), Space: O(n).
    """
    freq = Counter(nums)
    min_heap = []
    for num, count in freq.items():
        heapq.heappush(min_heap, (count, num))
        if len(min_heap) > k:
            heapq.heappop(min_heap)
    return [num for _, num in min_heap]


# --------------------------------------------------------------------------- #
# 4. Sort Characters by Frequency
# --------------------------------------------------------------------------- #

def sort_chars_by_frequency(s: str) -> str:
    """
    Return string with characters sorted by descending frequency.
    Ties can be broken arbitrarily.
    LeetCode 451.

    Approach: count frequencies, push to max-heap (negate count), rebuild string.
    Time: O(n log n), Space: O(n).
    """
    freq = Counter(s)
    max_heap = [(-count, char) for char, count in freq.items()]
    heapq.heapify(max_heap)

    result = []
    while max_heap:
        neg_count, char = heapq.heappop(max_heap)
        result.append(char * (-neg_count))
    return "".join(result)


# --------------------------------------------------------------------------- #
# 5. Connect Ropes with Minimum Cost
# --------------------------------------------------------------------------- #

def connect_ropes_min_cost(ropes: List[int]) -> int:
    """
    Connect all ropes into one. Cost to connect two ropes = sum of their lengths.
    Return the minimum total cost.
    (Classic greedy / LeetCode 1167 variant)

    Approach: always merge the two shortest ropes (greedy + min-heap).
    Time: O(n log n), Space: O(n).
    """
    if len(ropes) <= 1:
        return 0

    heapq.heapify(ropes)
    total_cost = 0

    while len(ropes) > 1:
        first = heapq.heappop(ropes)
        second = heapq.heappop(ropes)
        cost = first + second
        total_cost += cost
        heapq.heappush(ropes, cost)

    return total_cost


# --------------------------------------------------------------------------- #
# Tests
# --------------------------------------------------------------------------- #

if __name__ == "__main__":
    # 1. Kth Largest
    print("=== Kth Largest Element ===")
    print(kth_largest([3, 2, 1, 5, 6, 4], 2))       # 5
    print(kth_largest([3, 2, 3, 1, 2, 4, 5, 5, 6], 4))  # 4

    # 2. K Closest Points
    print("\n=== K Closest Points to Origin ===")
    print(sorted(k_closest_points([[1, 3], [-2, 2]], 1)))   # [[-2, 2]]
    print(sorted(k_closest_points([[3, 3], [5, -1], [-2, 4]], 2)))  # [[-2,4],[3,3]]

    # 3. Top K Frequent Elements
    print("\n=== Top K Frequent Elements ===")
    print(sorted(top_k_frequent([1, 1, 1, 2, 2, 3], 2)))   # [1, 2]
    print(sorted(top_k_frequent([1], 1)))                    # [1]

    # 4. Sort Characters by Frequency
    print("\n=== Sort Characters by Frequency ===")
    print(sort_chars_by_frequency("tree"))    # "eert" or "eetr"
    print(sort_chars_by_frequency("cccaaa"))  # "cccaaa" or "aaaccc"
    print(sort_chars_by_frequency("Aabb"))    # "bbAa" or "bbaA"

    # 5. Connect Ropes Min Cost
    print("\n=== Connect Ropes Minimum Cost ===")
    print(connect_ropes_min_cost([4, 3, 2, 6]))   # 29
    print(connect_ropes_min_cost([1, 2, 3]))       # 9
    print(connect_ropes_min_cost([5]))             # 0
