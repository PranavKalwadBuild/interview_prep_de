# Merge Intervals

**One-line description**: Process a set of overlapping intervals — sort by start time, then sweep.

---

## Recognition Keywords

- "overlapping intervals"
- "merge intervals"
- "meeting rooms" / "conflicting appointments"
- "minimum number of platforms/rooms"
- "insert interval into sorted list"
- "employee free time"
- "interval intersection"

**Key tell**: Input has `[start, end]` pairs; you are asked to merge, count conflicts, find gaps, or find intersections.

---

## Pattern Templates

### 1. Sort + Sweep Merge

```python
def merge_intervals(intervals):
    intervals.sort(key=lambda x: x[0])   # sort by start
    merged = [intervals[0]]

    for start, end in intervals[1:]:
        last_end = merged[-1][1]
        if start <= last_end:            # overlap condition: start <= previous end
            merged[-1][1] = max(last_end, end)   # extend end
        else:
            merged.append([start, end])  # no overlap, new interval

    return merged
```

### 2. Count Overlapping — Min Heap of End Times

```python
import heapq

def min_meeting_rooms(intervals):
    intervals.sort(key=lambda x: x[0])
    min_heap = []   # stores end times of active meetings

    for start, end in intervals:
        if min_heap and min_heap[0] <= start:
            heapq.heapreplace(min_heap, end)   # reuse the room that freed up earliest
        else:
            heapq.heappush(min_heap, end)      # need a new room

    return len(min_heap)
```

### 3. Interval Intersection

```python
def intervals_intersection(list1, list2):
    result = []
    i, j = 0, 0
    while i < len(list1) and j < len(list2):
        start = max(list1[i][0], list2[j][0])
        end   = min(list1[i][1], list2[j][1])
        if start <= end:
            result.append([start, end])
        # advance the interval that ends first
        if list1[i][1] < list2[j][1]:
            i += 1
        else:
            j += 1
    return result
```

---

## Complexity

| Step | Time | Space |
|---|---|---|
| Sort | O(n log n) | O(n) for sort output |
| Sweep | O(n) | O(n) for result |
| Min heap (meeting rooms) | O(n log n) | O(n) heap |

---

## Canonical Problem: Merge Intervals (LeetCode 56)

Given a list of intervals, merge all overlapping intervals.

```python
intervals.sort(key=lambda x: x[0])
merged = [intervals[0]]
for start, end in intervals[1:]:
    if start <= merged[-1][1]:
        merged[-1][1] = max(merged[-1][1], end)
    else:
        merged.append([start, end])
```

---

## Variations

| Variation | Core Idea |
|---|---|
| **Insert Interval** (LC 57) | Walk sorted non-overlapping list; skip non-overlapping left, merge overlapping middle, append remaining right |
| **Intervals Intersection** (LC 986) | Two-pointer on both sorted lists; take max of starts, min of ends; advance whichever ends first |
| **Conflicting Appointments** (LC 252) | Sort by start; if any `intervals[i].start < intervals[i-1].end`, return False |
| **Minimum Meeting Rooms** (LC 253) | Min heap of end times; size of heap at the end = rooms needed |
| **Employee Free Time** (LC 759) | Flatten all employee intervals, sort, merge, then gaps between merged intervals are free time |

---

## Gotchas

1. **Sort by start, not end**: The entire sweep logic depends on the invariant that intervals are ordered by start time. Sorting by end breaks the merge condition.

2. **Overlap condition is `a.end >= b.start`, not `>`**: Intervals `[1,2]` and `[2,3]` share the point 2 — they are adjacent and must be merged. Using strict `>` misses this case.

3. **Merging takes the max of ends**: When two intervals overlap, the merged end is `max(a.end, b.end)`, not `b.end`. The new interval could be fully contained inside the previous one (e.g., `[1,10]` and `[2,5]`).

4. **Insert Interval — three phases**: (1) Collect all intervals that end before the new interval starts (no overlap on left). (2) Merge all intervals that overlap with the new interval. (3) Append the rest. Track the merged new interval separately.

5. **Adjacent vs. overlapping**: "Adjacent" means they share exactly one point (end == start). Whether to merge them depends on the problem. Read carefully — most problems treat them as overlapping (use `>=`).

6. **Employee Free Time**: Flatten first. Do not try to find free time per employee and intersect — flatten all intervals, sort, merge, then read the gaps.
