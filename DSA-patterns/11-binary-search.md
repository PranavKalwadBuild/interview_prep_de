# Binary Search

## One-Line Summary
Apply binary search not just on sorted arrays but on answer spaces and rotated arrays.

## Recognition Keywords
- "sorted array" + "find position/element"
- "search in rotated sorted array"
- "find minimum in rotated array"
- "find peak element"
- "kth smallest in matrix/sorted lists"
- "minimum days to complete", "minimum capacity" (binary search on answer)
- "find first/last position of element"
- **Key tell**: monotonic condition exists; can eliminate half the search space each step; "minimum X such that condition holds"

## Templates

### Standard Binary Search
```python
def binary_search(nums, target):
    lo, hi = 0, len(nums) - 1
    while lo <= hi:
        mid = lo + (hi - lo) // 2
        if nums[mid] == target:
            return mid
        elif nums[mid] < target:
            lo = mid + 1
        else:
            hi = mid - 1
    return -1
```

### Left-Boundary (First Occurrence)
```python
def left_boundary(nums, target):
    lo, hi = 0, len(nums) - 1
    result = -1
    while lo <= hi:
        mid = lo + (hi - lo) // 2
        if nums[mid] == target:
            result = mid
            hi = mid - 1   # keep going left
        elif nums[mid] < target:
            lo = mid + 1
        else:
            hi = mid - 1
    return result
```

### Right-Boundary (Last Occurrence)
```python
def right_boundary(nums, target):
    lo, hi = 0, len(nums) - 1
    result = -1
    while lo <= hi:
        mid = lo + (hi - lo) // 2
        if nums[mid] == target:
            result = mid
            lo = mid + 1   # keep going right
        elif nums[mid] < target:
            lo = mid + 1
        else:
            hi = mid - 1
    return result
```

### Binary Search on Answer (Feasibility)
```python
def binary_search_on_answer(lo, hi):
    # lo = minimum possible answer, hi = maximum possible answer
    result = hi
    while lo <= hi:
        mid = lo + (hi - lo) // 2
        if is_feasible(mid):
            result = mid
            hi = mid - 1   # try smaller
        else:
            lo = mid + 1
    return result
```

## Complexity
- **Time**: O(log n)
- **Space**: O(1) iterative, O(log n) recursive

## Canonical Problem
**Binary Search** — find index of target in sorted array; return -1 if not found.

## Variations
| Problem | Twist |
|---|---|
| Find First and Last Position of Element | Left + right boundary search |
| Search in Rotated Sorted Array | Find pivot logic, two sorted halves |
| Find Minimum in Rotated Sorted Array | Identify which half is sorted |
| Kth Smallest Number in Multiplication Table | Binary search on answer (value space) |
| Minimum Capacity to Ship Packages in D Days | Binary search on capacity with feasibility check |

## Gotchas
- **Overflow**: use `lo + (hi - lo) // 2`, not `(lo + hi) // 2`
- **Loop condition**: `lo <= hi` for exact match; `lo < hi` when converging to a boundary
- **Update rule**: `lo = mid + 1` and `hi = mid - 1` for standard; `lo = mid` when mid could be the answer (use `lo < hi` variant)
- **Off-by-one**: when `hi = len(nums)` instead of `len(nums) - 1`, adjust accordingly
