# Pattern 07: Tree BFS (Level-Order Traversal)

## One-Line Summary
Level-order traversal of a tree using a queue — process nodes breadth-first, level by level.

---

## Recognition Keywords
- "level order traversal"
- "level by level"
- "zigzag traversal"
- "minimum depth of tree"
- "connect level order siblings"
- "right/left view of binary tree"
- "average of each level"

**Key Tell**: The word "level" or "breadth" appears in the problem. You need something computed *per level* (average, max, count). You need the *shortest path* in an unweighted graph or tree. You need the *leftmost* or *rightmost* node at each level.

---

## Core Template

```python
from collections import deque

def level_order(root):
    if not root:
        return []

    result = []
    queue = deque([root])

    while queue:
        level_size = len(queue)      # snapshot level width BEFORE inner loop
        current_level = []

        for _ in range(level_size):  # process exactly this level's nodes
            node = queue.popleft()
            current_level.append(node.val)

            if node.left:
                queue.append(node.left)
            if node.right:
                queue.append(node.right)

        result.append(current_level)

    return result
```

**Why snapshot `level_size`?** The queue grows as you enqueue children. Capturing `len(queue)` before the inner loop freezes the count for the current level only.

---

## Complexity
| Dimension | Cost |
|-----------|------|
| Time      | O(n) — every node visited once |
| Space     | O(n) — queue can hold an entire level; widest level of a perfect binary tree is n/2 nodes |

---

## Canonical Problem
**Level Order Traversal** — return a list of lists where each inner list contains node values at one level.

---

## Variations

| Problem | Twist |
|---------|-------|
| Zigzag Level Order | Alternate appending left-to-right vs right-to-left; use a `left_to_right` boolean flag, flip each level |
| Average of Levels | Instead of collecting values, sum them and divide by `level_size` |
| Minimum Depth | Return the first level where a leaf is encountered (no left and no right child) |
| Level Order Successor | BFS normally; as soon as you dequeue the target node, return the next dequeued node |
| Connect Level Order Siblings | During the inner loop, set `node.next = queue[0]` if more nodes remain in this level |
| Right Side View | After the inner loop, append `current_level[-1]` (or capture last node dequeued) |

---

## Gotchas

1. **Use `deque`, not `list`**: `list.pop(0)` is O(n) because it shifts all elements. `deque.popleft()` is O(1). For large inputs this is the difference between O(n) and O(n²).

2. **Snapshot `level_size` before the inner loop**: `len(queue)` changes as you enqueue children inside the loop. If you call `len(queue)` dynamically, you process nodes from the next level in the current iteration.

3. **Zigzag direction flip**: Flip the boolean *after* appending the full level, not inside the inner loop. A common mistake is flipping per node instead of per level.

4. **Minimum depth — leaf check**: A node with only one child is not a leaf. Check `not node.left and not node.right` to confirm a true leaf before returning the depth.

5. **Empty tree**: Always guard with `if not root: return []` before touching the queue.
