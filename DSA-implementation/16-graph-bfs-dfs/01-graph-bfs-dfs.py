"""
Graph BFS & DFS — Templates and Problems
=========================================
Pattern : BFS for shortest path / level-based traversal
          DFS for connectivity / all-paths / flood fill

Templates
---------
BFS  : queue (deque) + visited set; mark visited BEFORE enqueue
DFS  : recursive flood-fill OR iterative stack
Graph: defaultdict(list) from edge list

Complexity: O(V + E) time, O(V) space for visited
"""

from collections import deque, defaultdict
from typing import List, Optional, Dict


# ─────────────────────────────────────────────
# GRAPH BUILDER UTILITY
# ─────────────────────────────────────────────

def build_graph(edges: List[List[int]], directed: bool = False) -> Dict[int, List[int]]:
    """Build adjacency list from edge list."""
    graph = defaultdict(list)
    for u, v in edges:
        graph[u].append(v)
        if not directed:
            graph[v].append(u)
    return graph


# ─────────────────────────────────────────────
# BFS TEMPLATE
# ─────────────────────────────────────────────

def bfs_template(graph: Dict, start: int) -> List[int]:
    """
    BFS traversal — returns nodes in BFS order.
    KEY: mark visited BEFORE pushing to queue to prevent duplicate processing.
    """
    visited = {start}
    queue = deque([start])
    order = []
    while queue:
        node = queue.popleft()
        order.append(node)
        for neighbor in graph[node]:
            if neighbor not in visited:
                visited.add(neighbor)    # mark here, not after popping
                queue.append(neighbor)
    return order


# ─────────────────────────────────────────────
# DFS TEMPLATES
# ─────────────────────────────────────────────

def dfs_iterative(graph: Dict, start: int) -> List[int]:
    """DFS using explicit stack."""
    visited = {start}
    stack = [start]
    order = []
    while stack:
        node = stack.pop()
        order.append(node)
        for neighbor in graph[node]:
            if neighbor not in visited:
                visited.add(neighbor)
                stack.append(neighbor)
    return order


def dfs_recursive(graph: Dict, node: int, visited: set = None) -> set:
    """DFS recursive — returns visited set."""
    if visited is None:
        visited = set()
    visited.add(node)
    for neighbor in graph[node]:
        if neighbor not in visited:
            dfs_recursive(graph, neighbor, visited)
    return visited


# ─────────────────────────────────────────────
# PROBLEM 1: Number of Islands — DFS flood fill (CANONICAL)
# ─────────────────────────────────────────────

def num_islands(grid: List[List[str]]) -> int:
    """
    LeetCode 200 — Number of Islands
    Given a 2D grid of '1' (land) and '0' (water), count islands.

    Approach: DFS flood fill — for each unvisited '1', DFS and mark all
              connected land as visited ('#'). Increment count each start.

    Time : O(m * n)  Space: O(m * n) recursion stack in worst case
    """
    if not grid:
        return 0

    rows, cols = len(grid), len(grid[0])
    count = 0
    DIRS = [(0, 1), (0, -1), (1, 0), (-1, 0)]

    def dfs(r: int, c: int) -> None:
        if r < 0 or r >= rows or c < 0 or c >= cols or grid[r][c] != '1':
            return
        grid[r][c] = '#'   # mark visited in-place (avoids separate visited set)
        for dr, dc in DIRS:
            dfs(r + dr, c + dc)

    for r in range(rows):
        for c in range(cols):
            if grid[r][c] == '1':
                dfs(r, c)
                count += 1

    return count


# ─────────────────────────────────────────────
# PROBLEM 2: Word Ladder — BFS shortest transformation
# ─────────────────────────────────────────────

def word_ladder(begin_word: str, end_word: str, word_list: List[str]) -> int:
    """
    LeetCode 127 — Word Ladder
    Return length of shortest transformation sequence from begin_word to end_word,
    changing one letter at a time; each intermediate word must be in word_list.
    Return 0 if no such sequence exists.

    Approach: BFS where each node is a word; neighbors differ by exactly 1 char.
              Try replacing each position with a-z — avoids building full adjacency list.

    Time : O(M^2 * N) where M = word length, N = word list size
    Space: O(M^2 * N)
    """
    word_set = set(word_list)
    if end_word not in word_set:
        return 0

    queue = deque([(begin_word, 1)])   # (current_word, steps)
    visited = {begin_word}

    while queue:
        word, steps = queue.popleft()
        if word == end_word:
            return steps

        for i in range(len(word)):
            for c in 'abcdefghijklmnopqrstuvwxyz':
                candidate = word[:i] + c + word[i+1:]
                if candidate in word_set and candidate not in visited:
                    visited.add(candidate)
                    queue.append((candidate, steps + 1))

    return 0


# ─────────────────────────────────────────────
# PROBLEM 3: Pacific Atlantic Water Flow — DFS from both borders
# ─────────────────────────────────────────────

def pacific_atlantic(heights: List[List[int]]) -> List[List[int]]:
    """
    LeetCode 417 — Pacific Atlantic Water Flow
    Find all cells from which water can flow to both Pacific and Atlantic oceans.
    Pacific touches top/left border; Atlantic touches bottom/right border.

    Approach: Reverse-DFS from border cells (water flows UP — to equal/higher cells).
              pacific_reach = set of cells reachable from Pacific border (going up)
              atlantic_reach = same from Atlantic border
              Answer = intersection.

    Time : O(m * n)  Space: O(m * n)
    """
    if not heights:
        return []

    rows, cols = len(heights), len(heights[0])
    DIRS = [(0, 1), (0, -1), (1, 0), (-1, 0)]

    def dfs(r: int, c: int, visited: set) -> None:
        visited.add((r, c))
        for dr, dc in DIRS:
            nr, nc = r + dr, c + dc
            if (0 <= nr < rows and 0 <= nc < cols
                    and (nr, nc) not in visited
                    and heights[nr][nc] >= heights[r][c]):   # water flows up (reverse)
                dfs(nr, nc, visited)

    pacific = set()
    atlantic = set()

    # Pacific: top row + left column
    for c in range(cols):
        dfs(0, c, pacific)
    for r in range(rows):
        dfs(r, 0, pacific)

    # Atlantic: bottom row + right column
    for c in range(cols):
        dfs(rows - 1, c, atlantic)
    for r in range(rows):
        dfs(r, cols - 1, atlantic)

    return [[r, c] for r, c in pacific & atlantic]


# ─────────────────────────────────────────────
# NODE DEFINITION FOR CLONE GRAPH
# ─────────────────────────────────────────────

class GraphNode:
    def __init__(self, val: int = 0, neighbors: List = None):
        self.val = val
        self.neighbors = neighbors if neighbors is not None else []


# ─────────────────────────────────────────────
# PROBLEM 4: Clone Graph — BFS with old→new mapping
# ─────────────────────────────────────────────

def clone_graph(node: Optional[GraphNode]) -> Optional[GraphNode]:
    """
    LeetCode 133 — Clone Graph
    Return a deep copy of an undirected connected graph.

    Approach: BFS; maintain a dict {original_node: cloned_node}.
              When visiting a node's neighbors, clone them if not yet seen.

    Time : O(V + E)  Space: O(V)
    """
    if not node:
        return None

    clones: Dict[GraphNode, GraphNode] = {}
    clones[node] = GraphNode(node.val)
    queue = deque([node])

    while queue:
        curr = queue.popleft()
        for neighbor in curr.neighbors:
            if neighbor not in clones:
                clones[neighbor] = GraphNode(neighbor.val)
                queue.append(neighbor)
            clones[curr].neighbors.append(clones[neighbor])

    return clones[node]


# ─────────────────────────────────────────────
# PROBLEM 5: Surrounded Regions — DFS from border
# ─────────────────────────────────────────────

def surrounded_regions(board: List[List[str]]) -> None:
    """
    LeetCode 130 — Surrounded Regions
    Flip all 'O' regions not connected to the border to 'X'. Modifies board in-place.

    Approach:
      1. DFS from every border 'O', mark safe cells as 'T'
      2. Scan entire board: 'O' → 'X' (surrounded), 'T' → 'O' (restore safe)

    Time : O(m * n)  Space: O(m * n) recursion stack
    """
    if not board:
        return

    rows, cols = len(board), len(board[0])
    DIRS = [(0, 1), (0, -1), (1, 0), (-1, 0)]

    def dfs(r: int, c: int) -> None:
        if r < 0 or r >= rows or c < 0 or c >= cols or board[r][c] != 'O':
            return
        board[r][c] = 'T'   # temporarily mark as safe
        for dr, dc in DIRS:
            dfs(r + dr, c + dc)

    # Step 1: mark all border-connected 'O' cells as safe
    for r in range(rows):
        dfs(r, 0)
        dfs(r, cols - 1)
    for c in range(cols):
        dfs(0, c)
        dfs(rows - 1, c)

    # Step 2: finalize
    for r in range(rows):
        for c in range(cols):
            if board[r][c] == 'O':
                board[r][c] = 'X'   # surrounded — capture
            elif board[r][c] == 'T':
                board[r][c] = 'O'   # safe — restore


# ─────────────────────────────────────────────
# TESTS
# ─────────────────────────────────────────────

if __name__ == '__main__':
    # Test: num_islands
    grid1 = [
        ['1','1','0','0','0'],
        ['1','1','0','0','0'],
        ['0','0','1','0','0'],
        ['0','0','0','1','1'],
    ]
    assert num_islands(grid1) == 3, "num_islands failed"
    print("num_islands: PASS")

    # Test: word_ladder
    assert word_ladder("hit", "cog", ["hot","dot","dog","lot","log","cog"]) == 5
    assert word_ladder("hit", "cog", ["hot","dot","dog","lot","log"]) == 0
    print("word_ladder: PASS")

    # Test: pacific_atlantic
    heights = [
        [1,2,2,3,5],
        [3,2,3,4,4],
        [2,4,5,3,1],
        [6,7,1,4,5],
        [5,1,1,2,4],
    ]
    result = pacific_atlantic(heights)
    assert sorted(result) == sorted([[0,4],[1,3],[1,4],[2,2],[3,0],[3,1],[4,0]])
    print("pacific_atlantic: PASS")

    # Test: surrounded_regions
    board = [
        ['X','X','X','X'],
        ['X','O','O','X'],
        ['X','X','O','X'],
        ['X','O','X','X'],
    ]
    surrounded_regions(board)
    expected = [
        ['X','X','X','X'],
        ['X','X','X','X'],
        ['X','X','X','X'],
        ['X','O','X','X'],
    ]
    assert board == expected, "surrounded_regions failed"
    print("surrounded_regions: PASS")

    print("\nAll graph BFS/DFS tests passed.")
