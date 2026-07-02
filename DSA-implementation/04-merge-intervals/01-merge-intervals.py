"""
04-merge-intervals.py
Pattern: Merge Intervals

Recognition signals:
  - Input has [start, end] pairs
  - "merge", "overlap", "conflict", "rooms needed", "free time"
  - Key tell: sort by start, then compare current end with next start
"""

import heapq
from typing import List

# ---------------------------------------------------------------------------
# BOILERPLATE: Sort + Sweep Merge
# ---------------------------------------------------------------------------
#
#   intervals.sort(key=lambda x: x[0])    # sort by start time
#   merged = [intervals[0]]
#
#   for start, end in intervals[1:]:
#       last_end = merged[-1][1]
#       if start <= last_end:             # overlap: start <= previous end (use <=, not <)
#           merged[-1][1] = max(last_end, end)    # extend: take the max of ends
#       else:
#           merged.append([start, end])   # gap: new interval
#
#   return merged
#
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# BOILERPLATE: Min Heap of End Times (count overlapping / rooms needed)
# ---------------------------------------------------------------------------
#
#   intervals.sort(key=lambda x: x[0])
#   min_heap = []   # stores end times of active meetings
#
#   for start, end in intervals:
#       if min_heap and min_heap[0] <= start:
#           heapq.heapreplace(min_heap, end)   # room freed up, reuse it
#       else:
#           heapq.heappush(min_heap, end)      # no room free, add new one
#
#   return len(min_heap)   # number of rooms still occupied = rooms needed
#
# ---------------------------------------------------------------------------


# ---------------------------------------------------------------------------
# 1. CANONICAL: merge_intervals(intervals)
#    Merge all overlapping intervals.
#    LeetCode 56
# ---------------------------------------------------------------------------

def merge_intervals(intervals: List[List[int]]) -> List[List[int]]:
    if not intervals:
        return []

    intervals.sort(key=lambda x: x[0])
    merged = [intervals[0][:]]  # copy to avoid mutating input

    for start, end in intervals[1:]:
        last_end = merged[-1][1]
        if start <= last_end:                     # overlapping (includes adjacent: start == last_end)
            merged[-1][1] = max(last_end, end)    # extend: one interval may fully contain the other
        else:
            merged.append([start, end])

    return merged


# ---------------------------------------------------------------------------
# 2. insert_interval(intervals, new_interval)
#    Insert new_interval into a sorted list of non-overlapping intervals
#    and merge as needed. Return the result sorted and merged.
#    LeetCode 57
#
#    Three-phase walk:
#      Phase 1: collect intervals that end BEFORE new interval starts (left side, no overlap)
#      Phase 2: merge all intervals that overlap with new_interval
#      Phase 3: append all remaining intervals (right side, no overlap)
# ---------------------------------------------------------------------------

def insert_interval(
    intervals: List[List[int]], new_interval: List[int]
) -> List[List[int]]:
    result = []
    i = 0
    n = len(intervals)

    # Phase 1: all intervals that end before new_interval starts
    while i < n and intervals[i][1] < new_interval[0]:
        result.append(intervals[i])
        i += 1

    # Phase 2: merge overlapping intervals into new_interval
    while i < n and intervals[i][0] <= new_interval[1]:
        new_interval[0] = min(new_interval[0], intervals[i][0])
        new_interval[1] = max(new_interval[1], intervals[i][1])
        i += 1
    result.append(new_interval)

    # Phase 3: remaining intervals start after new_interval ends
    while i < n:
        result.append(intervals[i])
        i += 1

    return result


# ---------------------------------------------------------------------------
# 3. intervals_intersection(list1, list2)
#    Find the intersection of two sorted lists of non-overlapping intervals.
#    LeetCode 986
#
#    Two-pointer approach:
#      - Intersection of [a_start, a_end] and [b_start, b_end]:
#          start = max(a_start, b_start)
#          end   = min(a_end,   b_end)
#          if start <= end: it is a valid intersection segment
#      - Advance the pointer whose interval ends first
# ---------------------------------------------------------------------------

def intervals_intersection(
    list1: List[List[int]], list2: List[List[int]]
) -> List[List[int]]:
    result = []
    i, j = 0, 0

    while i < len(list1) and j < len(list2):
        start = max(list1[i][0], list2[j][0])
        end   = min(list1[i][1], list2[j][1])

        if start <= end:
            result.append([start, end])

        # Advance whichever interval ends first
        if list1[i][1] < list2[j][1]:
            i += 1
        else:
            j += 1

    return result


# ---------------------------------------------------------------------------
# 4. min_meeting_rooms(intervals)
#    Find the minimum number of meeting rooms required so all meetings
#    can be held simultaneously.
#    LeetCode 253
#
#    Min heap stores end times of ongoing meetings.
#    When a new meeting starts, if the earliest-ending meeting is done,
#    reuse that room (heapreplace). Otherwise open a new room (heappush).
#    Final heap size = rooms needed.
# ---------------------------------------------------------------------------

def min_meeting_rooms(intervals: List[List[int]]) -> int:
    if not intervals:
        return 0

    intervals.sort(key=lambda x: x[0])
    min_heap = []  # end times of active meetings

    for start, end in intervals:
        if min_heap and min_heap[0] <= start:
            # The room that ends earliest is now free; reuse it
            heapq.heapreplace(min_heap, end)
        else:
            # No room is free; open a new one
            heapq.heappush(min_heap, end)

    return len(min_heap)


# ---------------------------------------------------------------------------
# 5. find_free_time(schedules)
#    Given a list of employee schedules (each a list of [start, end] intervals,
#    already sorted per employee), find all free time slots that exist across
#    ALL employees.
#    LeetCode 759
#
#    Approach:
#      1. Flatten all employee intervals into one list
#      2. Sort by start time
#      3. Merge overlapping intervals (same as canonical merge)
#      4. Gaps between consecutive merged intervals are the free time slots
# ---------------------------------------------------------------------------

def find_free_time(schedules: List[List[List[int]]]) -> List[List[int]]:
    # Step 1: flatten
    all_intervals = [interval for employee in schedules for interval in employee]

    if not all_intervals:
        return []

    # Step 2: sort by start
    all_intervals.sort(key=lambda x: x[0])

    # Step 3: merge
    merged = [all_intervals[0][:]]
    for start, end in all_intervals[1:]:
        if start <= merged[-1][1]:
            merged[-1][1] = max(merged[-1][1], end)
        else:
            merged.append([start, end])

    # Step 4: gaps between merged intervals = free time
    free_time = []
    for i in range(1, len(merged)):
        free_start = merged[i - 1][1]
        free_end   = merged[i][0]
        if free_start < free_end:
            free_time.append([free_start, free_end])

    return free_time


# ---------------------------------------------------------------------------
# TESTS
# ---------------------------------------------------------------------------

if __name__ == "__main__":

    # --- merge_intervals ---
    print("=== merge_intervals ===")
    print(merge_intervals([[1,3],[2,6],[8,10],[15,18]]))   # [[1,6],[8,10],[15,18]]
    print(merge_intervals([[1,4],[4,5]]))                  # [[1,5]]  (adjacent, <=)
    print(merge_intervals([[1,4],[2,3]]))                  # [[1,4]]  (fully contained)
    print(merge_intervals([[1,2],[3,4],[5,6]]))            # [[1,2],[3,4],[5,6]]  (no overlap)
    print(merge_intervals([[1,4]]))                        # [[1,4]]  (single)

    # --- insert_interval ---
    print("\n=== insert_interval ===")
    print(insert_interval([[1,3],[6,9]], [2,5]))           # [[1,5],[6,9]]
    print(insert_interval([[1,2],[3,5],[6,7],[8,10],[12,16]], [4,8]))  # [[1,2],[3,10],[12,16]]
    print(insert_interval([], [5,7]))                      # [[5,7]]
    print(insert_interval([[1,5]], [2,3]))                 # [[1,5]]  (new fully inside)
    print(insert_interval([[1,5]], [6,8]))                 # [[1,5],[6,8]]  (no overlap)

    # --- intervals_intersection ---
    print("\n=== intervals_intersection ===")
    A = [[0,2],[5,10],[13,23],[24,25]]
    B = [[1,5],[8,12],[15,24],[25,26]]
    print(intervals_intersection(A, B))
    # [[1,2],[5,5],[8,10],[15,23],[24,24],[25,25]]

    print(intervals_intersection([[1,3],[5,9]], []))       # []
    print(intervals_intersection([[1,7]], [[3,10]]))       # [[3,7]]

    # --- min_meeting_rooms ---
    print("\n=== min_meeting_rooms ===")
    print(min_meeting_rooms([[0,30],[5,10],[15,20]]))      # 2
    print(min_meeting_rooms([[7,10],[2,4]]))               # 1  (no overlap)
    print(min_meeting_rooms([[1,5],[2,6],[3,7]]))          # 3  (all overlap)
    print(min_meeting_rooms([[9,10],[4,9],[4,17]]))        # 2
    print(min_meeting_rooms([]))                           # 0

    # --- find_free_time ---
    print("\n=== find_free_time ===")
    schedules1 = [[[1,3],[6,7]], [[2,4]], [[2,5],[9,12]]]
    print(find_free_time(schedules1))   # [[5,6],[7,9]]

    schedules2 = [[[1,3],[9,12]], [[2,4]], [[6,8]]]
    print(find_free_time(schedules2))   # [[4,6],[8,9]]

    schedules3 = [[[1,2],[3,4]], [[2,3],[4,5]]]
    print(find_free_time(schedules3))   # []  (fully covered 1-5)
