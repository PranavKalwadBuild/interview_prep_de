"""
K-Way Merge — DSA Pattern #13
===============================
Merge k sorted arrays/lists using a min-heap to efficiently track the global minimum.

BOILERPLATE TEMPLATE
--------------------

K-Way Merge (Array Version):
    import heapq

    min_heap = []
    for i, arr in enumerate(arrays):
        if arr:
            heapq.heappush(min_heap, (arr[0], i, 0))
            # tuple: (value, list_idx, element_idx)

    result = []
    while min_heap:
        val, list_idx, elem_idx = heapq.heappop(min_heap)
        result.append(val)
        next_idx = elem_idx + 1
        if next_idx < len(arrays[list_idx]):
            heapq.heappush(min_heap, (arrays[list_idx][next_idx], list_idx, next_idx))

    return result

Key insight: always push the NEXT element from the SAME list that was just popped.
"""

import heapq
from typing import List, Optional


# --------------------------------------------------------------------------- #
# Helper: ListNode for linked list problems
# --------------------------------------------------------------------------- #

class ListNode:
    def __init__(self, val=0, next=None):
        self.val = val
        self.next = next

    def __repr__(self):
        vals = []
        curr = self
        while curr:
            vals.append(str(curr.val))
            curr = curr.next
        return " -> ".join(vals)


def list_to_linked(lst: List[int]) -> Optional[ListNode]:
    if not lst:
        return None
    head = ListNode(lst[0])
    curr = head
    for val in lst[1:]:
        curr.next = ListNode(val)
        curr = curr.next
    return head


# --------------------------------------------------------------------------- #
# 1. Canonical: Merge K Sorted Lists (Linked Lists)
# --------------------------------------------------------------------------- #

def merge_k_sorted_lists(lists: List[Optional[ListNode]]) -> Optional[ListNode]:
    """
    Merge k sorted linked lists into one sorted linked list.
    LeetCode 23.

    Approach: push head of each list into min-heap with (val, list_idx, node).
    Use list_idx as tiebreaker so nodes are never compared directly.
    Time: O(n log k), Space: O(k).
    """
    dummy = ListNode(0)
    curr = dummy
    min_heap = []

    for i, node in enumerate(lists):
        if node:
            heapq.heappush(min_heap, (node.val, i, node))

    while min_heap:
        val, i, node = heapq.heappop(min_heap)
        curr.next = node
        curr = curr.next
        if node.next:
            heapq.heappush(min_heap, (node.next.val, i, node.next))

    return dummy.next


# --------------------------------------------------------------------------- #
# 2. Kth Smallest in M Sorted Lists
# --------------------------------------------------------------------------- #

def kth_smallest_in_m_sorted_lists(lists: List[List[int]], k: int) -> int:
    """
    Find the kth smallest element across all sorted lists.

    Approach: k-way merge, stop after exactly k pops.
    Time: O(k log m), Space: O(m).
    """
    min_heap = []
    for i, lst in enumerate(lists):
        if lst:
            heapq.heappush(min_heap, (lst[0], i, 0))

    count = 0
    result = None
    while min_heap:
        val, list_idx, elem_idx = heapq.heappop(min_heap)
        count += 1
        result = val
        if count == k:
            return result
        next_idx = elem_idx + 1
        if next_idx < len(lists[list_idx]):
            heapq.heappush(min_heap, (lists[list_idx][next_idx], list_idx, next_idx))

    return result  # k > total elements (caller's error)


# --------------------------------------------------------------------------- #
# 3. Find K Pairs with Smallest Sums
# --------------------------------------------------------------------------- #

def find_k_pairs_with_smallest_sums(
    nums1: List[int], nums2: List[int], k: int
) -> List[List[int]]:
    """
    Given two sorted arrays, find k pairs (u, v) with smallest u+v sums.
    LeetCode 373.

    Approach: push (nums1[i] + nums2[0], i, 0) for each i in nums1 (up to k).
    When popping (sum, i, j), push (nums1[i] + nums2[j+1], i, j+1).
    Time: O(k log k), Space: O(k).
    """
    result = []
    if not nums1 or not nums2:
        return result

    min_heap = []
    for i in range(min(k, len(nums1))):
        heapq.heappush(min_heap, (nums1[i] + nums2[0], i, 0))

    while min_heap and len(result) < k:
        total, i, j = heapq.heappop(min_heap)
        result.append([nums1[i], nums2[j]])
        if j + 1 < len(nums2):
            heapq.heappush(min_heap, (nums1[i] + nums2[j + 1], i, j + 1))

    return result


# --------------------------------------------------------------------------- #
# 4. Merge K Sorted Arrays (Array Version)
# --------------------------------------------------------------------------- #

def merge_k_sorted_arrays(arrays: List[List[int]]) -> List[int]:
    """
    Merge k sorted arrays into a single sorted array.

    Approach: classic k-way merge with (value, array_idx, element_idx) tuples.
    Time: O(n log k), Space: O(k).
    """
    result = []
    min_heap = []

    for i, arr in enumerate(arrays):
        if arr:
            heapq.heappush(min_heap, (arr[0], i, 0))

    while min_heap:
        val, arr_idx, elem_idx = heapq.heappop(min_heap)
        result.append(val)
        next_idx = elem_idx + 1
        if next_idx < len(arrays[arr_idx]):
            heapq.heappush(min_heap, (arrays[arr_idx][next_idx], arr_idx, next_idx))

    return result


# --------------------------------------------------------------------------- #
# 5. Smallest Range Covering Elements from K Lists
# --------------------------------------------------------------------------- #

def smallest_range_k_lists(lists: List[List[int]]) -> List[int]:
    """
    Find the smallest range [a, b] such that at least one element from each
    of the k lists lies in [a, b].
    LeetCode 632.

    Approach: use min-heap to track current minimum; track current maximum
    explicitly. Range = [heap_min, current_max]. Pop minimum, push next from
    same list. Stop when any list is exhausted.
    Time: O(n log k), Space: O(k).
    """
    min_heap = []
    current_max = float('-inf')

    for i, lst in enumerate(lists):
        if lst:
            heapq.heappush(min_heap, (lst[0], i, 0))
            current_max = max(current_max, lst[0])

    best_range = [float('-inf'), float('inf')]

    while min_heap:
        current_min, list_idx, elem_idx = heapq.heappop(min_heap)

        # Update best range if current window is smaller
        if current_max - current_min < best_range[1] - best_range[0]:
            best_range = [current_min, current_max]

        # Push next element from same list
        next_idx = elem_idx + 1
        if next_idx >= len(lists[list_idx]):
            break   # this list is exhausted; can't cover all lists anymore
        next_val = lists[list_idx][next_idx]
        heapq.heappush(min_heap, (next_val, list_idx, next_idx))
        current_max = max(current_max, next_val)

    return best_range


# --------------------------------------------------------------------------- #
# Tests
# --------------------------------------------------------------------------- #

if __name__ == "__main__":
    # 1. Merge K Sorted Lists
    print("=== Merge K Sorted Lists ===")
    lists = [
        list_to_linked([1, 4, 5]),
        list_to_linked([1, 3, 4]),
        list_to_linked([2, 6]),
    ]
    print(merge_k_sorted_lists(lists))   # 1 -> 1 -> 2 -> 3 -> 4 -> 4 -> 5 -> 6
    print(merge_k_sorted_lists([]))      # None
    print(merge_k_sorted_lists([list_to_linked([])]))  # None

    # 2. Kth Smallest in M Sorted Lists
    print("\n=== Kth Smallest in M Sorted Lists ===")
    print(kth_smallest_in_m_sorted_lists([[1, 3, 5], [2, 4, 6], [0, 7, 8]], 4))  # 3
    print(kth_smallest_in_m_sorted_lists([[1, 2], [3, 4]], 3))                   # 3

    # 3. Find K Pairs with Smallest Sums
    print("\n=== Find K Pairs with Smallest Sums ===")
    print(find_k_pairs_with_smallest_sums([1, 7, 11], [2, 4, 6], 3))
    # [[1,2],[1,4],[1,6]]
    print(find_k_pairs_with_smallest_sums([1, 1, 2], [1, 2, 3], 2))
    # [[1,1],[1,1]]

    # 4. Merge K Sorted Arrays
    print("\n=== Merge K Sorted Arrays ===")
    print(merge_k_sorted_arrays([[1, 4, 7], [2, 5, 8], [3, 6, 9]]))
    # [1, 2, 3, 4, 5, 6, 7, 8, 9]
    print(merge_k_sorted_arrays([[1], [0]]))
    # [0, 1]

    # 5. Smallest Range Covering K Lists
    print("\n=== Smallest Range Covering Elements from K Lists ===")
    print(smallest_range_k_lists([[4, 10, 15, 24, 26], [0, 9, 12, 20], [5, 18, 22, 30]]))
    # [20, 24]
    print(smallest_range_k_lists([[1, 2, 3], [1, 2, 3], [1, 2, 3]]))
    # [1, 1]
