# Pattern 08: Tree DFS

## One-Line Summary

Recursive or iterative depth-first traversal of a tree, tracking path or cumulative values.

---

## Recognition Keywords

| Signal | Example Problem Phrasing |
|--------|--------------------------|
| "path sum" / "path that sums to target" | "Does any root-to-leaf path sum to 22?" |
| "root to leaf paths" | "Return all root-to-leaf paths" |
| "all paths" | "Find all paths from root to leaf" |
| "diameter of tree" | "What is the diameter of this binary tree?" |
| "max/min path sum" | "Find the path with maximum sum" |
| "lowest common ancestor" | "Find LCA of nodes p and q" |
| "count paths" | "Count paths that sum to target" |

### Key Tell

> You need to track something along a **ROOT-TO-LEAF path**; recursion with a **running value**; the word **"all"** appears before paths/combinations in a tree problem.

If the problem says "path" but does **not** require it to start at root — that's still DFS, but you run DFS from every node (see Count Paths for Sum).

---

## Template

```python
def dfs(node, current_sum, current_path):
    if node is None:
        return

    # Preorder: process node before children
    current_sum += node.val
    current_path.append(node.val)

    # Check at leaf
    if node.left is None and node.right is None:
        if current_sum == target:
            result.append(list(current_path))  # copy, not reference
    else:
        dfs(node.left,  current_sum, current_path)
        dfs(node.right, current_sum, current_path)

    # Backtrack: undo before returning to parent
    current_path.pop()

dfs(root, 0, [])
```

### For Diameter (Postorder — need subtree info first)

```python
def height(node):
    if node is None:
        return 0
    left_h  = height(node.left)
    right_h = height(node.right)
    diameter = max(diameter, left_h + right_h)   # update global
    return 1 + max(left_h, right_h)
```

---

## Complexity

| Dimension | Value |
|-----------|-------|
| Time      | O(n) — visit every node once |
| Space     | O(n) — recursion stack (skewed tree) + path storage |

For balanced trees, space is O(log n) for the stack.

---

## Canonical Problem

**Binary Tree Path Sum** — does any root-to-leaf path sum to a given target?

```
Tree:       1
           / \
          7   9
         / \ / \
        4  5 2  7

Target = 12
Answer: True  (path 1->9->2 = 12 or 1->7->4 = 12)
```

---

## Variations

| Variation | Key Change from Canonical |
|-----------|--------------------------|
| **All Paths for a Sum** | Collect every path (not just True/False) — append `list(path)` at leaf |
| **Count Paths for a Sum** | Paths need not start at root — use prefix sum dict; DFS at every node |
| **Sum of Path Numbers** | Each root-to-leaf path represents a number (e.g., 1→2→3 = 123); sum all |
| **Path with Maximum Sum** | Track `left + right + node.val` at each node; postorder |
| **Diameter of Binary Tree** | Longest path between any two nodes; postorder using heights |
| **Lowest Common Ancestor** | Classic: if both p and q found in subtrees, current node is LCA |

---

## Gotchas

1. **Path not required to start at root** — Use a running prefix-sum dict (`path_count`). At each node: `path_count[current_sum - target]` gives paths ending here. Remember to decrement `path_count[current_sum]` on backtrack.

2. **Postorder for diameter** — Diameter uses height of subtrees, so children must be evaluated before the parent.

3. **"Path" vs "Node" distinction** — Diameter counts **edges** (not nodes). Adjust: `return 1 + max(left_h, right_h)` counts edges; remove the `1` to count nodes.

4. **Always append a copy of the path** — `result.append(list(path))` not `result.append(path)`. Otherwise all entries in result point to the same mutable list.

5. **Leaf check** — `node.left is None and node.right is None` is the correct leaf condition. Do not use `if not node` to check leaf — that triggers on `None` nodes (which are not leaves).
