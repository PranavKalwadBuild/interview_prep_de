# 15 — Topological Sort

## One-line
Order vertices of a DAG such that for every directed edge u → v, u appears before v in the ordering.

---

## Recognition Keywords (THE MOST CRITICAL SECTION)

If the problem contains any of these phrases, try Topological Sort first:

- "course prerequisite" / "courses with dependencies"
- "task scheduling with dependencies"
- "build order" / "compilation order"
- "alien dictionary" / "character ordering"
- "find if circular dependency exists"
- "sequence reconstruction"

**Key tell**: directed dependencies where one thing must happen before another; or you need to detect a cycle in a directed graph.

> Topological sort only works on a **DAG** (Directed Acyclic Graph). If a cycle is detected during the sort, no valid ordering exists.

---

## Templates

### Kahn's Algorithm (BFS, in-degree based)

```python
from collections import deque, defaultdict

def topological_sort_kahn(n, edges):
    # Build adjacency list and in-degree map
    adj = defaultdict(list)
    in_degree = [0] * n
    for u, v in edges:
        adj[u].append(v)
        in_degree[v] += 1

    # Start with all nodes that have no prerequisites
    queue = deque(i for i in range(n) if in_degree[i] == 0)
    order = []

    while queue:
        node = queue.popleft()
        order.append(node)
        for neighbor in adj[node]:
            in_degree[neighbor] -= 1
            if in_degree[neighbor] == 0:
                queue.append(neighbor)

    # If order doesn't contain all nodes, a cycle exists
    return order if len(order) == n else []
```

**Why Kahn's**: intuitive BFS, naturally detects cycles (output length < n means cycle), easy to reason about.

---

### DFS-based Topological Sort

```python
def topological_sort_dfs(n, edges):
    adj = defaultdict(list)
    for u, v in edges:
        adj[u].append(v)

    # States: 0 = unvisited, 1 = visiting (in stack), 2 = visited
    state = [0] * n
    stack = []
    has_cycle = [False]

    def dfs(node):
        if has_cycle[0]:
            return
        state[node] = 1  # mark as being visited
        for neighbor in adj[node]:
            if state[neighbor] == 1:
                has_cycle[0] = True  # back edge → cycle
                return
            if state[neighbor] == 0:
                dfs(neighbor)
        state[node] = 2  # fully processed
        stack.append(node)  # add to result AFTER all descendants

    for i in range(n):
        if state[i] == 0:
            dfs(i)

    return [] if has_cycle[0] else stack[::-1]  # reverse for correct order
```

**Why DFS**: useful when you need post-order processing; also the basis for Alien Dictionary.

---

## Complexity

| | Time | Space |
|---|---|---|
| Both algorithms | O(V + E) | O(V + E) |

V = number of vertices, E = number of edges.

---

## Canonical Problem: Course Schedule II

**Problem**: Given n courses (0 to n-1) and prerequisites `[a, b]` meaning "must take b before a", return a valid course order. Return `[]` if impossible.

```python
from collections import deque, defaultdict

def find_order(n, prerequisites):
    adj = defaultdict(list)
    in_degree = [0] * n
    for course, prereq in prerequisites:
        adj[prereq].append(course)
        in_degree[course] += 1

    queue = deque(i for i in range(n) if in_degree[i] == 0)
    order = []

    while queue:
        node = queue.popleft()
        order.append(node)
        for neighbor in adj[node]:
            in_degree[neighbor] -= 1
            if in_degree[neighbor] == 0:
                queue.append(neighbor)

    return order if len(order) == n else []
```

---

## Variations

### Course Schedule I (Cycle Detection Only)
Same as Course Schedule II but just return `True/False`. Check `len(order) == n`.

### Alien Dictionary
Derive character ordering from a sorted word list.
- Compare adjacent words character by character to extract ordering edges.
- Run topological sort on those edges.
- **Edge case**: if a longer word appears before a shorter prefix (e.g., `"abc"` before `"ab"`), the ordering is invalid — return `""`.

### Sequence Reconstruction
Check if `org` is the **only** shortest supersequence that can be reconstructed from `seqs`.
- Build a graph from `seqs`, run topological sort.
- At every step, the BFS queue must have exactly 1 node (no ambiguity). If queue ever has 2+ nodes, reconstruction is not unique.

### Task Scheduler with Dependencies
Given tasks and dependency pairs, find a valid execution order respecting all dependencies. Straightforward Kahn's application.

### Minimum Height Trees
Find root nodes that minimize tree height.
- Reverse topo approach: repeatedly prune leaf nodes (degree 1) inward.
- The last 1–2 nodes remaining are the roots of minimum height trees.

---

## Gotchas

- **Cycle detection**: if `len(output) != num_nodes`, a cycle exists and no valid topological order is possible. Always check this.
- **Building adjacency list + in-degree map**: for prerequisites `[a, b]` ("b before a"), the edge is `b → a`, so `adj[b].append(a)` and `in_degree[a] += 1`. Getting the direction backwards is the #1 bug.
- **Alien Dictionary edge case**: `"abc"` before `"ab"` in the sorted word list is an impossible ordering — detect this when the shorter word is a prefix of the longer word but comes after it.
- **Disconnected graphs**: always seed the queue with ALL nodes where `in_degree == 0`, not just node 0.
- **DFS state tracking**: use 3 states (unvisited / visiting / visited) not just 2. Two states cannot distinguish a back edge (cycle) from a cross edge.
- **Sequence Reconstruction queue size check**: the uniqueness constraint requires exactly one choice at every step — check `len(queue) == 1` inside the while loop, not just the final output.
