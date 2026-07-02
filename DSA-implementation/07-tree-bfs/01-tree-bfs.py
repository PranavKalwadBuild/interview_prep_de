"""
PATTERN: Tree BFS (Level-Order Traversal)
==========================================
RECOGNITION SIGNALS:
  - "level order traversal", "level by level", "zigzag traversal"
  - "minimum depth of tree", "average of each level"
  - "connect level order siblings", "right/left view of binary tree"
  - Key tell: word "level" or "breadth" in the problem; need shortest path
    in unweighted graph/tree; need something computed per level

CORE IDEA:
  Use a deque as a queue. At the start of each level, snapshot len(queue)
  so the inner loop processes exactly that level's nodes before moving on.

BOILERPLATE TEMPLATE:
  from collections import deque
  queue = deque([root])
  while queue:
      level_size = len(queue)          # snapshot BEFORE inner loop
      for _ in range(level_size):
          node = queue.popleft()       # O(1) with deque
          # process node
          if node.left:  queue.append(node.left)
          if node.right: queue.append(node.right)

COMPLEXITY: O(n) time | O(n) space (queue holds up to n/2 nodes at widest level)
"""

from collections import deque


# ---------------------------------------------------------------------------
# NODE DEFINITION
# ---------------------------------------------------------------------------
class TreeNode:
    def __init__(self, val=0, left=None, right=None):
        self.val = val
        self.left = left
        self.right = right


# ---------------------------------------------------------------------------
# HELPER
# ---------------------------------------------------------------------------
def build_tree(values):
    """
    Build a binary tree from a level-order list (None = missing node).
    Example: [1, 2, 3, 4, 5, None, 7]
    """
    if not values or values[0] is None:
        return None
    root = TreeNode(values[0])
    queue = deque([root])
    i = 1
    while queue and i < len(values):
        node = queue.popleft()
        if i < len(values) and values[i] is not None:
            node.left = TreeNode(values[i])
            queue.append(node.left)
        i += 1
        if i < len(values) and values[i] is not None:
            node.right = TreeNode(values[i])
            queue.append(node.right)
        i += 1
    return root


# ---------------------------------------------------------------------------
# PROBLEM 1: Level Order Traversal
# Return a list of lists; each inner list has node values at one level.
# Example: [1,2,3,4,5] -> [[1], [2,3], [4,5]]
# ---------------------------------------------------------------------------
def level_order_traversal(root):
    if not root:
        return []

    result = []
    queue = deque([root])

    while queue:
        level_size = len(queue)
        current_level = []

        for _ in range(level_size):
            node = queue.popleft()
            current_level.append(node.val)
            if node.left:
                queue.append(node.left)
            if node.right:
                queue.append(node.right)

        result.append(current_level)

    return result


# ---------------------------------------------------------------------------
# PROBLEM 2: Zigzag Level Order Traversal
# Alternate direction: left-to-right for even levels, right-to-left for odd.
# Example: [1,2,3,4,5,6,7] -> [[1], [3,2], [4,5,6,7]]
# GOTCHA: flip left_to_right flag AFTER appending the full level
# ---------------------------------------------------------------------------
def zigzag_traversal(root):
    if not root:
        return []

    result = []
    queue = deque([root])
    left_to_right = True

    while queue:
        level_size = len(queue)
        current_level = []

        for _ in range(level_size):
            node = queue.popleft()
            current_level.append(node.val)
            if node.left:
                queue.append(node.left)
            if node.right:
                queue.append(node.right)

        if left_to_right:
            result.append(current_level)
        else:
            result.append(current_level[::-1])

        left_to_right = not left_to_right   # flip direction after each full level

    return result


# ---------------------------------------------------------------------------
# PROBLEM 3: Average of Levels
# Return a list of averages, one per level.
# Example: [1,2,3,4,5,6,7] -> [1.0, 2.5, 5.5]
# ---------------------------------------------------------------------------
def average_of_levels(root):
    if not root:
        return []

    result = []
    queue = deque([root])

    while queue:
        level_size = len(queue)
        level_sum = 0

        for _ in range(level_size):
            node = queue.popleft()
            level_sum += node.val
            if node.left:
                queue.append(node.left)
            if node.right:
                queue.append(node.right)

        result.append(level_sum / level_size)

    return result


# ---------------------------------------------------------------------------
# PROBLEM 4: Minimum Depth
# Depth of the shallowest leaf node.
# GOTCHA: a node with one child is NOT a leaf -- check both children are None
# Example: [1,2,3,4,5] -> 2 (node 3 is at depth 2 and has no children)
# ---------------------------------------------------------------------------
def minimum_depth(root):
    if not root:
        return 0

    depth = 0
    queue = deque([root])

    while queue:
        depth += 1
        level_size = len(queue)

        for _ in range(level_size):
            node = queue.popleft()

            # true leaf: no children at all
            if not node.left and not node.right:
                return depth

            if node.left:
                queue.append(node.left)
            if node.right:
                queue.append(node.right)

    return depth


# ---------------------------------------------------------------------------
# PROBLEM 5: Right Side View
# Return the rightmost node value at each level (what you see from the right).
# Example: [1,2,3,4,5,None,7] -> [1, 3, 7]
# ---------------------------------------------------------------------------
def right_side_view(root):
    if not root:
        return []

    result = []
    queue = deque([root])

    while queue:
        level_size = len(queue)
        rightmost = None

        for _ in range(level_size):
            node = queue.popleft()
            rightmost = node.val        # overwrite each time; last value = rightmost
            if node.left:
                queue.append(node.left)
            if node.right:
                queue.append(node.right)

        result.append(rightmost)

    return result


# ---------------------------------------------------------------------------
# TEST PRINTS
# ---------------------------------------------------------------------------
if __name__ == "__main__":
    print("=== Tree BFS Problems ===\n")

    print("1. Level Order Traversal")
    root = build_tree([1, 2, 3, 4, 5])
    print(level_order_traversal(root))          # [[1], [2, 3], [4, 5]]

    root = build_tree([12, 7, 1, None, None, 10, 5])
    print(level_order_traversal(root))          # [[12], [7, 1], [10, 5]]
    print()

    print("2. Zigzag Level Order")
    root = build_tree([1, 2, 3, 4, 5, 6, 7])
    print(zigzag_traversal(root))               # [[1], [3, 2], [4, 5, 6, 7]]

    root = build_tree([3, 9, 20, None, None, 15, 7])
    print(zigzag_traversal(root))               # [[3], [20, 9], [15, 7]]
    print()

    print("3. Average of Levels")
    root = build_tree([1, 2, 3, 4, 5, 6, 7])
    print(average_of_levels(root))              # [1.0, 2.5, 5.5]

    root = build_tree([3, 9, 20, None, None, 15, 7])
    print(average_of_levels(root))              # [3.0, 14.5, 11.0]
    print()

    print("4. Minimum Depth")
    root = build_tree([1, 2, 3, 4, 5])
    print(minimum_depth(root))                  # 2  (node 3 is a leaf at depth 2)
    print()

    print("5. Right Side View")
    root = build_tree([1, 2, 3, 4, 5, None, 7])
    print(right_side_view(root))                # [1, 3, 7]

    root = build_tree([1, 2, 3, None, 5, None, 4])
    print(right_side_view(root))                # [1, 3, 4]
