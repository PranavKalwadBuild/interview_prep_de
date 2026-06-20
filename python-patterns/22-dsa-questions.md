# Extensive DSA Questions for Data Engineering Interviews

## Array & Hashing

**Q1: Two Sum**  
Given an array of integers `nums` and an integer `target`, return indices of the two numbers such that they add up to `target`.  
A: Use a hash map to store value->index while iterating. For each num, check if target-num exists in map. O(n) time, O(n) space.

```python
def two_sum(nums, target):
    seen = {}
    for i, num in enumerate(nums):
        complement = target - num
        if complement in seen:
            return [seen[complement], i]
        seen[num] = i
    return []
```

**Q2: Contains Duplicate**  
Given an integer array `nums`, return true if any value appears at least twice.  
A: Use a set to track seen numbers. If a number is already in set, return True. O(n) time, O(n) space.

```python
def contains_duplicate(nums):
    seen = set()
    for num in nums:
        if num in seen:
            return True
        seen.add(num)
    return False
```

**Q3: Top K Frequent Elements**  
Given an integer array `nums` and an integer `k`, return the k most frequent elements.  
A: Count frequencies with hash map, then use a min-heap of size k to keep top k frequent. O(n log k) time, O(n) space.

```python
import heapq
from collections import Counter

def top_k_frequent(nums, k):
    freq = Counter(nums)
    heap = []
    for num, count in freq.items():
        heapq.heappush(heap, (count, num))
        if len(heap) > k:
            heapq.heappop(heap)
    return [num for count, num in heap]
```

**Q4: Longest Consecutive Sequence**  
Given an unsorted array of integers `nums`, return the length of the longest consecutive elements sequence.  
A: Put all numbers in a set. For each num, if num-1 not in set, start of sequence; count upward. O(n) time, O(n) space.

```python
def longest_consecutive(nums):
    num_set = set(nums)
    longest = 0
    for num in num_set:
        if num - 1 not in num_set:
            length = 1
            while num + length in num_set:
                length += 1
            longest = max(longest, length)
    return longest
```

## Two Pointers

**Q5: Container With Most Water**  
Given n non-negative integers representing heights of lines, find two lines that together with x-axis form a container holding the most water.  
A: Use two pointers at ends, move the pointer pointing to shorter line inward. O(n) time, O(1) space.

```python
def max_area(height):
    left, right = 0, len(height) - 1
    max_water = 0
    while left < right:
        h = min(height[left], height[right])
        max_water = max(max_water, h * (right - left))
        if height[left] < height[right]:
            left += 1
        else:
            right -= 1
    return max_water
```

**Q6: 3Sum**  
Given an integer array nums, return all triplets [nums[i], nums[j], nums[k]] such that i != j, i != k, j != k, and nums[i] + nums[j] + nums[k] == 0.  
A: Sort array, fix one element, use two pointers for remaining part. Skip duplicates. O(n^2) time, O(1) or O(n) space for output.

```python
def three_sum(nums):
    nums.sort()
    res = []
    for i in range(len(nums)-2):
        if i > 0 and nums[i] == nums[i-1]:
            continue
        l, r = i+1, len(nums)-1
        while l < r:
            s = nums[i] + nums[l] + nums[r]
            if s < 0:
                l += 1
            elif s > 0:
                r -= 1
            else:
                res.append([nums[i], nums[l], nums[r]])
                while l < r and nums[l] == nums[l+1]:
                    l += 1
                while l < r and nums[r] == nums[r-1]:
                    r -= 1
                l += 1
                r -= 1
    return res
```

**Q7: Valid Palindrome**  
Given a string s, determine if it is a palindrome, considering only alphanumeric characters and ignoring cases.  
A: Two pointers from ends, skip non-alnum, compare lowercased chars. O(n) time, O(1) space.

```python
import re
def is_palindrome(s):
    l, r = 0, len(s)-1
    while l < r:
        while l < r and not s[l].isalnum():
            l += 1
        while l < r and not s[r].isalnum():
            r -= 1
        if s[l].lower() != s[r].lower():
            return False
        l += 1
        r -= 1
    return True
```

## Sliding Window

**Q8: Best Time to Buy and Sell Stock**  
Given an array prices where prices[i] is price on day i, find max profit from one transaction.  
A: Keep track of min price so far and compute profit at each day. O(n) time, O(1) space.

```python
def max_profit(prices):
    min_price = float('inf')
    max_profit = 0
    for price in prices:
        if price < min_price:
            min_price = price
        elif price - min_price > max_profit:
            max_profit = price - min_price
    return max_profit
```

**Q9: Longest Substring Without Repeating Characters**  
Given a string s, find length of longest substring without repeating characters.  
A: Sliding window with set of chars in window. Expand right, shrink left when duplicate. O(n) time, O(min(m,n)) space.

```python
def length_of_longest_substring(s):
    char_set = set()
    left = 0
    max_len = 0
    for right, ch in enumerate(s):
        while ch in char_set:
            char_set.remove(s[left])
            left += 1
        char_set.add(ch)
        max_len = max(max_len, right - left + 1)
    return max_len
```

## Stack

**Q10: Valid Parentheses**  
Given a string s containing just '(', ')', '{', '}', '[' and ']', determine if input string is valid.  
A: Use stack; push opening brackets, pop when closing matches. O(n) time, O(n) space.

```python
def is_valid_parentheses(s):
    stack = []
    mapping = {')': '(', '}': '{', ']': '['}
    for ch in s:
        if ch in mapping:
            top = stack.pop() if stack else '#'
            if mapping[ch] != top:
                return False
        else:
            stack.append(ch)
    return not stack
```

## Linked List

**Q11: Reverse Linked List**  
Reverse a singly linked list.  
A: Iterative with prev, curr, next pointers. O(n) time, O(1) space.

```python
class ListNode:
    def __init__(self, val=0, next=None):
        self.val = val
        self.next = next

def reverse_list(head):
    prev = None
    curr = head
    while curr:
        nxt = curr.next
        curr.next = prev
        prev = curr
        curr = nxt
    return prev
```

**Q12: Linked List Cycle**  
Given head of linked list, determine if it has a cycle.  
A: Floyd’s tortoise and hare (slow/fast pointers). O(n) time, O(1) space.

```python
def has_cycle(head):
    slow = fast = head
    while fast and fast.next:
        slow = slow.next
        fast = fast.next.next
        if slow == fast:
            return True
    return False
```

**Q13: Merge Two Sorted Lists**  
Merge two sorted linked lists and return as a new sorted list.  
A: Dummy head, compare nodes, attach smaller. O(n+m) time, O(1) space.

```python
def merge_two_lists(l1, l2):
    dummy = tail = ListNode()
    while l1 and l2:
        if l1.val < l2.val:
            tail.next, l1 = l1, l1.next
        else:
            tail.next, l2 = l2, l2.next
        tail = tail.next
    tail.next = l1 or l2
    return dummy.next
```

## Tree

**Q14: Invert Binary Tree**  
Invert a binary tree.  
A: Recursively swap left and right children. O(n) time, O(h) space.

```python
class TreeNode:
    def __init__(self, val=0, left=None, right=None):
        self.val = val
        self.left = left
        self.right = right

def invert_tree(root):
    if root:
        root.left, root.right = invert_tree(root.right), invert_tree(root.left)
    return root
```

**Q15: Maximum Depth of Binary Tree**  
Find max depth.  
A: Recursively compute max(depth(left), depth(right)) + 1. O(n) time, O(h) space.

```python
def max_depth(root):
    if not root:
        return 0
    return max(max_depth(root.left), max_depth(root.right)) + 1
```

**Q16: Lowest Common Ancestor of BST**  
Given BST and two nodes, find LCA.  
A: Use BST property: traverse, both nodes on same side? else root is LCA. O(h) time, O(1) space.

```python
def lowest_common_ancestor(root, p, q):
    while root:
        if p.val < root.val and q.val < root.val:
            root = root.left
        elif p.val > root.val and q.val > root.val:
            root = root.right
        else:
            return root
```

## Heap

**Q17: Find Median from Data Stream**  
Implement MedianFinder: addNum(num) and findMedian().  
A: Two heaps: max-heap for lower half, min-heap for upper half. Balance sizes. O(log n) add, O(1) find.

```python
import heapq

class MedianFinder:
    def __init__(self):
        self.small = []  # max-heap via neg values
        self.large = []  # min-heap

    def addNum(self, num):
        if not self.small or num <= -self.small[0]:
            heapq.heappush(self.small, -num)
        else:
            heapq.heappush(self.large, num)
        # rebalance
        if len(self.small) > len(self.large) + 1:
            heapq.heappush(self.large, -heapq.heappop(self.small))
        elif len(self.large) > len(self.small):
            heapq.heappush(self.small, -heapq.heappop(self.large))

    def findMedian(self):
        if len(self.small) > len(self.large):
            return -self.small[0]
        return (-self.small[0] + self.large[0]) / 2.0
```

## Graph

**Q18: Number of Islands**  
Given m x n grid of '1's (land) and '0's (water), count islands.  
A: BFS/DFS flood fill. O(mn) time, O(min(m,n)) space for queue/stack.

```python
from collections import deque

def num_islands(grid):
    if not grid:
        return 0
    rows, cols = len(grid), len(grid[0])
    visited = [[False]*cols for _ in range(rows)]
    def bfs(r, c):
        q = deque([(r,c)])
        visited[r][c] = True
        while q:
            x,y = q.popleft()
            for dx,dy in [(1,0),(-1,0),(0,1),(0,-1)]:
                nx, ny = x+dx, y+dy
                if 0 <= nx < rows and 0 <= ny < cols and not visited[nx][ny] and grid[nx][ny] == '1':
                    visited[nx][ny] = True
                    q.append((nx,ny))
    islands = 0
    for r in range(rows):
        for c in range(cols):
            if grid[r][c] == '1' and not visited[r][c]:
                bfs(r,c)
                islands += 1
    return islands
```

**Q19: Course Schedule**  
Given numCourses and prerequisites list, determine if possible to finish all courses (detect cycle in directed graph).  
A: Topological sort via Kahn's algorithm (indegree). O(V+E) time, O(V) space.

```python
def can_finish(numCourses, prerequisites):
    indeg = [0]*numCourses
    adj = [[] for _ in range(numCourses)]
    for dest, src in prerequisites:
        adj[src].append(dest)
        indeg[dest] += 1
    q = deque([i for i in range(numCourses) if indeg[i]==0])
    count = 0
    while q:
        node = q.popleft()
        count += 1
        for nei in adj[node]:
            indeg[nei] -= 1
            if indeg[nei]==0:
                q.append(nei)
    return count == numCourses
```

## Dynamic Programming

**Q20: Coin Change**  
Given coins array and amount, return fewest coins needed to make up that amount; -1 if impossible.  
A: DP where dp[i] = min coins for amount i. dp[0]=0, dp[i] = min(dp[i-coin]+1). O(amount*len(coins)) time, O(amount) space.

```python
def coin_change(coins, amount):
    dp = [float('inf')]*(amount+1)
    dp[0] = 0
    for coin in coins:
        for x in range(coin, amount+1):
            dp[x] = min(dp[x], dp[x-coin]+1)
    return dp[amount] if dp[amount]!=float('inf') else -1
```

**Q21: House Robber**  
Given nums array representing money in each house, max amount without robbing adjacent houses.  
A: DP: dp[i] = max(dp[i-1], dp[i-2]+nums[i]). O(n) time, O(1) space.

```python
def rob(nums):
    prev1 = prev2 = 0
    for n in nums:
        tmp = prev1
        prev1 = max(prev1, prev2 + n)
        prev2 = tmp
    return prev1
```

## Design / Data Structures

**Q22: LRU Cache**  
Design LRU cache with get and put operations O(1).  
A: Use hashmap + doubly linked list. OrderedDict in Python also works.

```python
class Node:
    def __init__(self, key=0, val=0):
        self.key = key
        self.val = val
        self.prev = self.next = None

class LRUCache:
    def __init__(self, capacity):
        self.cap = capacity
        self.cache = {}
        self.head = Node()  # dummy head
        self.tail = Node()  # dummy tail
        self.head.next = self.tail
        self.tail.prev = self.head

    def _remove(self, node):
        p, n = node.prev, node.next
        p.next, n.prev = n, p

    def _add(self, node):  # add right after head
        node.prev = self.head
        node.next = self.head.next
        self.head.next.prev = node
        self.head.next = node

    def get(self, key):
        if key in self.cache:
            node = self.cache[key]
            self._remove(node)
            self._add(node)
            return node.val
        return -1

    def put(self, key, value):
        if key in self.cache:
            self._remove(self.cache[key])
        node = Node(key, value)
        self._add(node)
        self.cache[key] = node
        if len(self.cache) > self.cap:
            lru = self.tail.prev
            self._remove(lru)
            del self.cache[lru.key]
```

**Q23: Circular Queue**  
Implement circular queue (MyCircularQueue) with enFront, rear, etc.  
A: Use fixed-size array + head/tail pointers + size count.

```python
class MyCircularQueue:
    def __init__(self, k):
        self.cap = k
        self.queue = [0]*k
        self.head = self.tail = 0
        self.size = 0

    def enQueue(self, value):
        if self.isFull():
            return False
        self.queue[self.tail] = value
        self.tail = (self.tail + 1) % self.cap
        self.size += 1
        return True

    def deQueue(self):
        if self.isEmpty():
            return False
        self.head = (self.head + 1) % self.cap
        self.size -= 1
        return True

    def Front(self):
        return -1 if self.isEmpty() else self.queue[self.head]

    def Rear(self):
        return -1 if self.isEmpty() else self.queue[(self.tail-1)%self.cap]

    def isEmpty(self):
        return self.size == 0

    def isFull(self):
        return self.size == self.cap
```

## Miscellaneous

**Q24: Find The Duplicate Number**  
Given array nums of n+1 integers where each integer in [1,n], find duplicate.  
A: Floyd’s cycle detection (tortoise hare) on indices as next pointer. O(n) time, O(1) space.

```python
def find_duplicate(nums):
    slow = fast = 0
    while True:
        slow = nums[slow]
        fast = nums[nums[fast]]
        if slow == fast:
            break
    slow2 = 0
    while True:
        slow = nums[slow]
        slow2 = nums[slow2]
        if slow == slow2:
            return slow
```

**Q25: Leaders in Array**  
An element is leader if it’s greater than all elements to its right. Return all leaders.  
A: Scan from right, keep max_so_far. O(n) time, O(1) extra.

```python
def leaders(arr):
    leaders_list = []
    max_from_right = float('-inf')
    for x in reversed(arr):
        if x > max_from_right:
            leaders_list.append(x)
            max_from_right = x
    return list(reversed(leaders_list))
```