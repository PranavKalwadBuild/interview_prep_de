# 16 — Graph BFS & DFS

## One-Line Summary
BFS for shortest path/level-based; DFS for connectivity/all-paths in general graphs.

## Recognition Keywords

**BFS triggers:**
- "shortest path in unweighted graph"
- "minimum steps/moves"
- "word ladder"
- "number of islands (BFS variant)"
- "bipartite check"
- "01 matrix (distance to nearest 0)"

**DFS triggers:**
- "number of islands"
- "connected components"
- "can you reach from A to B"
- "all paths from source to target"
- "clone graph"
- "flood fill"
- "count regions"

**Key tell:** BFS = shortest/minimum; DFS = existence/count/all

## Templates

### BFS — Adjacency List (queue + visited set)
```python
from collections import deque

def bfs(graph, start):
    visited = {start}
    queue = deque([start])
    while queue:
        node = queue.popleft()
        for neighbor in graph[node]:
            if neighbor not in visited:
                visited.add(neighbor)   # mark BEFORE pushing, not after popping
                queue.append(neighbor)
```

### DFS — Iterative (stack + visited)
```python
def dfs_iterative(graph, start):
    visited = {start}
    stack = [start]
    while stack:
        node = stack.pop()
        for neighbor in graph[node]:
            if neighbor not in visited:
                visited.add(neighbor)
                stack.append(neighbor)
```

### DFS — Recursive
```python
def dfs_recursive(graph, node, visited=None):
    if visited is None:
        visited = set()
    visited.add(node)
    for neighbor in graph[node]:
        if neighbor not in visited:
            dfs_recursive(graph, neighbor, visited)
    return visited
```

### Graph Builder from Edge List
```python
from collections import defaultdict

def build_graph(edges, directed=False):
    graph = defaultdict(list)
    for u, v in edges:
        graph[u].append(v)
        if not directed:
            graph[v].append(u)
    return graph
```

## Complexity
- **Time:** O(V + E) — visit every vertex and edge once
- **Space:** O(V) — visited set + queue/stack

## Canonical Problem: Number of Islands (DFS flood fill)

Given a 2D grid of '1's (land) and '0's (water), count the number of islands.

```python
def num_islands(grid):
    if not grid:
        return 0
    rows, cols = len(grid), len(grid[0])
    count = 0

    def dfs(r, c):
        if r < 0 or r >= rows or c < 0 or c >= cols or grid[r][c] != '1':
            return
        grid[r][c] = '#'   # mark visited in-place
        for dr, dc in [(0,1),(0,-1),(1,0),(-1,0)]:
            dfs(r + dr, c + dc)

    for r in range(rows):
        for c in range(cols):
            if grid[r][c] == '1':
                dfs(r, c)
                count += 1
    return count
```

## Variations

### Word Ladder — BFS shortest transformation sequence
Find the length of the shortest transformation from `begin_word` to `end_word`, changing one letter at a time (each intermediate word must be in `word_list`).
- Use BFS; each level = one transformation step
- Mark visited by removing from word_set (or using a separate set)

### Clone Graph
Deep-copy a graph where each node has a `val` and `neighbors` list.
- BFS or DFS with an `old → new` node mapping dict

### Pacific Atlantic Water Flow
Find all cells from which water can flow to both the Pacific and Atlantic oceans.
- DFS from all Pacific-border cells; DFS from all Atlantic-border cells; return intersection

### Course Schedule — DFS cycle detection
Given `n` courses and prerequisites, determine if you can finish all courses.
- Build directed graph; DFS with 3-state coloring (0=unvisited, 1=visiting, 2=done)
- If you encounter a node in state 1 (currently visiting), there is a cycle

### Surrounded Regions — DFS from border
Given a board of 'X' and 'O', capture all 'O' regions not connected to the border.
- DFS from border 'O' cells, mark them safe ('T')
- Flip remaining 'O' → 'X', restore 'T' → 'O'

## Gotchas
1. **BFS visited marking**: mark visited **before pushing to queue**, not after popping — prevents duplicate entries in the queue
2. **Grid neighbors**: always use 4-directional offsets `[(0,1),(0,-1),(1,0),(-1,0)]`
3. **Word Ladder**: mark visited by removing word from the word set (or a separate visited set) to avoid revisiting
4. **Grid bounds check**: always validate `0 <= r < rows` and `0 <= c < cols` before accessing
5. **Directed vs undirected**: be explicit about whether the graph is directed when building it
