"""
Pattern: Tree DFS
=================
Recognition signals:
  - "path sum" / "path that sums to target"
  - "root to leaf paths" / "all paths"
  - "diameter of tree"
  - "max/min path sum"
  - "count paths" (anywhere in tree, not just root-to-leaf)
  - Key tell: tracking a running value along a root-to-leaf path;
    recursive DFS with accumulation; the word "all" before paths in a tree

DFS Boilerplate (preorder, path tracking):
------------------------------------------
  def dfs(node, current_sum, current_path):
      if node is None:
          return
      current_sum   += node.val
      current_path.append(node.val)
      if node.left is None and node.right is None:   # leaf
          if current_sum == target:
              result.append(list(current_path))       # copy!
      else:
          dfs(node.left,  current_sum, current_path)
          dfs(node.right, current_sum, current_path)
      current_path.pop()                              # backtrack

Complexity: O(n) time, O(n) space (stack + path storage)
"""

from collections import defaultdict


# ---------------------------------------------------------------------------
# Data Structure
# ---------------------------------------------------------------------------

class TreeNode:
    def __init__(self, val=0, left=None, right=None):
        self.val   = val
        self.left  = left
        self.right = right

    def __repr__(self):
        return f"TreeNode({self.val})"


def build_tree(values):
    """Build a binary tree from a level-order list (None = missing node)."""
    if not values:
        return None
    root  = TreeNode(values[0])
    queue = [root]
    i     = 1
    while queue and i < len(values):
        node = queue.pop(0)
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
# 1. has_path_sum
# ---------------------------------------------------------------------------

def has_path_sum(root: TreeNode, target: int) -> bool:
    """
    Canonical: does any root-to-leaf path sum to target?

    Strategy: preorder DFS, subtract node value from remaining target.
    At a leaf, check if remaining == 0.

    Time: O(n)  Space: O(n)
    """
    if root is None:
        return False

    # Leaf node
    if root.left is None and root.right is None:
        return root.val == target

    remaining = target - root.val
    return has_path_sum(root.left, remaining) or has_path_sum(root.right, remaining)


# ---------------------------------------------------------------------------
# 2. all_paths_for_sum
# ---------------------------------------------------------------------------

def all_paths_for_sum(root: TreeNode, target: int) -> list:
    """
    Return all root-to-leaf paths whose node values sum to target.

    Strategy: preorder DFS carrying current path; at each leaf check sum.
    Always append a COPY of current_path to avoid mutation.

    Time: O(n * h) where h = tree height (copying path at each leaf)
    Space: O(n)
    """
    result = []

    def dfs(node, current_sum, current_path):
        if node is None:
            return

        current_sum += node.val
        current_path.append(node.val)

        # Leaf: check condition
        if node.left is None and node.right is None:
            if current_sum == target:
                result.append(list(current_path))  # copy, not reference
        else:
            dfs(node.left,  current_sum, current_path)
            dfs(node.right, current_sum, current_path)

        current_path.pop()  # backtrack

    dfs(root, 0, [])
    return result


# ---------------------------------------------------------------------------
# 3. sum_of_path_numbers
# ---------------------------------------------------------------------------

def sum_of_path_numbers(root: TreeNode) -> int:
    """
    Each root-to-leaf path represents a number formed by concatenating node
    values (e.g., 1 -> 2 -> 3 forms 123). Return the sum of all such numbers.

    Strategy: preorder DFS, build number as current_number * 10 + node.val.
    At a leaf, add to running total.

    Time: O(n)  Space: O(n)
    """
    total = [0]

    def dfs(node, current_number):
        if node is None:
            return

        current_number = current_number * 10 + node.val

        if node.left is None and node.right is None:
            total[0] += current_number
        else:
            dfs(node.left,  current_number)
            dfs(node.right, current_number)

    dfs(root, 0)
    return total[0]


# ---------------------------------------------------------------------------
# 4. count_paths_for_sum
# ---------------------------------------------------------------------------

def count_paths_for_sum(root: TreeNode, target: int) -> int:
    """
    Count all paths anywhere in the tree (not necessarily root-to-leaf)
    that sum to target. Paths must go downward (parent to child).

    Strategy: prefix sum technique.
    - Maintain a running prefix sum from root to current node.
    - At each node, check how many previous prefix sums equal
      (current_sum - target). Those correspond to paths ending at this node.
    - Use a dict to track prefix sum frequencies; increment on enter,
      decrement on exit (backtrack).

    Time: O(n)  Space: O(n)
    """
    count      = [0]
    path_count = defaultdict(int)
    path_count[0] = 1   # empty path (sum = 0) seen once at start

    def dfs(node, current_sum):
        if node is None:
            return

        current_sum += node.val

        # Paths ending at this node that sum to target
        count[0] += path_count[current_sum - target]

        path_count[current_sum] += 1   # mark this prefix sum

        dfs(node.left,  current_sum)
        dfs(node.right, current_sum)

        path_count[current_sum] -= 1   # backtrack: unmark

    dfs(root, 0)
    return count[0]


# ---------------------------------------------------------------------------
# 5. diameter_of_tree
# ---------------------------------------------------------------------------

def diameter_of_tree(root: TreeNode) -> int:
    """
    Longest path between any two nodes in the tree, measured in number of edges.
    The path may or may not pass through the root.

    Strategy: postorder DFS.
    - At each node, compute height of left and right subtrees.
    - Diameter through this node = left_height + right_height.
    - Track the global maximum across all nodes.
    - Return 1 + max(left_height, right_height) up to parent.

    Time: O(n)  Space: O(n)
    """
    diameter = [0]

    def height(node):
        if node is None:
            return 0

        left_h  = height(node.left)
        right_h = height(node.right)

        # Path through this node spans left_h edges + right_h edges
        diameter[0] = max(diameter[0], left_h + right_h)

        return 1 + max(left_h, right_h)

    height(root)
    return diameter[0]


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

if __name__ == "__main__":

    # Tree 1:
    #         1
    #        / \
    #       7   9
    #      / \ / \
    #     4  5 2  7
    t1 = build_tree([1, 7, 9, 4, 5, 2, 7])

    print("=" * 60)
    print("TREE 1:  1 -> (7 -> 4, 7 -> 5) | (9 -> 2, 9 -> 7)")
    print("=" * 60)

    # has_path_sum
    print("\n--- has_path_sum ---")
    print(f"Target=12: {has_path_sum(t1, 12)}")   # 1+7+4=12  -> True
    print(f"Target=23: {has_path_sum(t1, 23)}")   # 1+7+5+...? no -> False
    print(f"Target=17: {has_path_sum(t1, 17)}")   # 1+9+7=17  -> True
    print(f"Target=15: {has_path_sum(t1, 15)}")   # no path   -> False

    # all_paths_for_sum
    print("\n--- all_paths_for_sum ---")
    print(f"Target=12: {all_paths_for_sum(t1, 12)}")  # [[1,7,4]]
    print(f"Target=17: {all_paths_for_sum(t1, 17)}")  # [[1,9,7]]

    # sum_of_path_numbers
    # Tree 2:
    #       1
    #      / \
    #     2   3
    # paths: 1->2 = 12, 1->3 = 13; sum = 25
    t2 = build_tree([1, 2, 3])
    print("\n--- sum_of_path_numbers ---")
    print(f"Tree [1,2,3] -> {sum_of_path_numbers(t2)}")  # 12 + 13 = 25

    # Tree 3: 1->0->1 = 101, 1->1 = 11? wait: [1,0,1]
    #       1
    #      / \
    #     0   1
    # paths: 1->0=10, 1->1=11; sum=21
    t3 = build_tree([1, 0, 1])
    print(f"Tree [1,0,1] -> {sum_of_path_numbers(t3)}")  # 10 + 11 = 21

    # count_paths_for_sum
    # Tree 4:
    #           1
    #          / \
    #         7   9
    #        /   / \
    #       6   2   3
    #       \    \
    #        5    1
    # target = 12
    # Paths summing to 12: [7,5], [1,9,2], [1,9,3-...no], [1,2-...no]
    # Let's build manually
    t4 = TreeNode(1)
    t4.left            = TreeNode(7)
    t4.right           = TreeNode(9)
    t4.left.left       = TreeNode(6)
    t4.left.left.right = TreeNode(5)
    t4.right.left      = TreeNode(2)
    t4.right.right     = TreeNode(3)
    t4.right.left.right = TreeNode(1)

    print("\n--- count_paths_for_sum ---")
    # Paths summing to 12 in t4:
    # 7+5=12, 1+2+9=12, 9+3=12... let's check:
    # 1+7+6-... no; 7+5=12 yes; 1+9+2=12 yes; 9+3=12 yes
    print(f"Tree4 target=12: {count_paths_for_sum(t4, 12)}")  # 3

    # Also test with t1 (simpler)
    print(f"Tree1 target=12: {count_paths_for_sum(t1, 12)}")  # 1+7+4=12 and 7+5? no, 7+5=12 yes
    # 1->7->4=12, 7->5=12 -> 2

    # diameter_of_tree
    print("\n--- diameter_of_tree ---")
    # Tree 1: longest path: 4->7->1->9->7 = 4 edges
    print(f"Tree1 diameter: {diameter_of_tree(t1)}")  # 4

    # Single node
    single = TreeNode(1)
    print(f"Single node diameter: {diameter_of_tree(single)}")  # 0

    # Line tree: 1->2->3->4->5
    line = TreeNode(1,
             TreeNode(2,
               TreeNode(3,
                 TreeNode(4,
                   TreeNode(5)))))
    print(f"Line tree [1-2-3-4-5] diameter: {diameter_of_tree(line)}")  # 4

    # Tree with width:
    #       1
    #      / \
    #     2   3
    #    / \
    #   4   5
    wide = build_tree([1, 2, 3, 4, 5])
    print(f"Wide tree diameter: {diameter_of_tree(wide)}")  # 3 (4->2->1->3 or 5->2->1->3)

    print("\n" + "=" * 60)
    print("All Tree DFS tests complete.")
    print("=" * 60)
