"""
15-topological-sort.py
Pattern: Topological Sort

Recognition signals:
  - "dependencies", "prerequisites", "must come before"
  - "build order", "task ordering"
  - "detect cycle in directed graph"
  - "alien dictionary" (derive ordering from sorted word list)

Key facts:
  - Only valid on DAGs (Directed Acyclic Graphs)
  - If a cycle exists, no valid topological order is possible
  - Output length < num_nodes after Kahn's → cycle detected
  - Both algorithms run in O(V + E) time
"""

# ─────────────────────────────────────────────────────────────────────────────
# BOILERPLATE TEMPLATES
# ─────────────────────────────────────────────────────────────────────────────

# ── TEMPLATE 1: Kahn's BFS Algorithm (in-degree based) ───────────────────
#
# from collections import deque, defaultdict
#
# def kahn(n, edges):
#     adj = defaultdict(list)
#     in_degree = [0] * n
#
#     for u, v in edges:           # u must come before v
#         adj[u].append(v)
#         in_degree[v] += 1
#
#     # Seed queue with all nodes that have no prerequisites
#     queue = deque(i for i in range(n) if in_degree[i] == 0)
#     order = []
#
#     while queue:
#         node = queue.popleft()
#         order.append(node)
#         for neighbor in adj[node]:
#             in_degree[neighbor] -= 1
#             if in_degree[neighbor] == 0:
#                 queue.append(neighbor)
#
#     # Cycle check: if we couldn't visit all nodes, a cycle exists
#     return order if len(order) == n else []
#
# When to use: straightforward ordering; cycle detection; sequence uniqueness.
# Cycle signal: len(order) != n

# ── TEMPLATE 2: DFS-based Topological Sort ───────────────────────────────
#
# def dfs_topo(n, edges):
#     adj = defaultdict(list)
#     for u, v in edges:
#         adj[u].append(v)
#
#     # 0 = unvisited, 1 = in current DFS path (visiting), 2 = fully done
#     state = [0] * n
#     stack = []
#     has_cycle = [False]
#
#     def dfs(node):
#         if has_cycle[0]:
#             return
#         state[node] = 1
#         for neighbor in adj[node]:
#             if state[neighbor] == 1:     # back edge → cycle
#                 has_cycle[0] = True
#                 return
#             if state[neighbor] == 0:
#                 dfs(neighbor)
#         state[node] = 2
#         stack.append(node)              # push AFTER all descendants
#
#     for i in range(n):
#         if state[i] == 0:
#             dfs(i)
#
#     return [] if has_cycle[0] else stack[::-1]
#
# When to use: post-order processing needed; Alien Dictionary derivation.
# Cycle signal: state[neighbor] == 1 (back edge to node still on stack)

# ─────────────────────────────────────────────────────────────────────────────
# IMPLEMENTATIONS
# ─────────────────────────────────────────────────────────────────────────────

from collections import deque, defaultdict


# 1. Course Schedule I — Cycle Detection
# ─────────────────────────────────────────────────────────────────────────────
# Problem: n courses [0..n-1], prerequisites[i] = [a, b] means "take b before a".
# Return True if all courses can be finished (no cycle), else False.

def can_finish_courses(n, prerequisites):
    adj = defaultdict(list)
    in_degree = [0] * n

    for course, prereq in prerequisites:
        adj[prereq].append(course)
        in_degree[course] += 1

    queue = deque(i for i in range(n) if in_degree[i] == 0)
    completed = 0

    while queue:
        node = queue.popleft()
        completed += 1
        for neighbor in adj[node]:
            in_degree[neighbor] -= 1
            if in_degree[neighbor] == 0:
                queue.append(neighbor)

    return completed == n   # False if cycle prevented visiting some nodes


# 2. Course Schedule II — Return Valid Order
# ─────────────────────────────────────────────────────────────────────────────
# Same setup; return the actual ordering or [] if impossible.

def find_order(n, prerequisites):
    adj = defaultdict(list)
    in_degree = [0] * n

    for course, prereq in prerequisites:
        adj[prereq].append(course)   # prereq → course
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


# 3. Alien Dictionary
# ─────────────────────────────────────────────────────────────────────────────
# Problem: given a sorted list of words in an alien language, derive the
# character ordering. Return "" if impossible (cycle or invalid prefix).
#
# Approach:
#   1. Compare adjacent word pairs character by character to find ordering edges.
#   2. Special case: if word[i] is a prefix of word[i-1] but comes after → invalid.
#   3. Run Kahn's on all unique characters.

def alien_dictionary(words):
    # Collect all unique characters
    chars = set(c for word in words for c in word)
    adj = defaultdict(set)
    in_degree = {c: 0 for c in chars}

    # Extract ordering edges from adjacent word pairs
    for i in range(len(words) - 1):
        w1, w2 = words[i], words[i + 1]
        min_len = min(len(w1), len(w2))
        found_diff = False
        for j in range(min_len):
            if w1[j] != w2[j]:
                if w2[j] not in adj[w1[j]]:   # avoid duplicate edges
                    adj[w1[j]].add(w2[j])
                    in_degree[w2[j]] += 1
                found_diff = True
                break
        # Edge case: longer word is a prefix of shorter word but appears first
        if not found_diff and len(w1) > len(w2):
            return ""   # invalid ordering

    # Kahn's BFS
    queue = deque(c for c in chars if in_degree[c] == 0)
    result = []

    while queue:
        c = queue.popleft()
        result.append(c)
        for neighbor in adj[c]:
            in_degree[neighbor] -= 1
            if in_degree[neighbor] == 0:
                queue.append(neighbor)

    # Cycle check
    return "".join(result) if len(result) == len(chars) else ""


# 4. Sequence Reconstruction
# ─────────────────────────────────────────────────────────────────────────────
# Problem: given original sequence org and a list of subsequences seqs,
# determine if org is the ONLY shortest supersequence reconstructable from seqs.
#
# Key insight: at every Kahn's step the queue must have exactly 1 choice.
# If queue has 2+ nodes at any point, the ordering is ambiguous → not unique.

def sequence_reconstruction(org, seqs):
    # Build graph from seqs
    all_nodes = set()
    adj = defaultdict(set)
    in_degree = defaultdict(int)

    for seq in seqs:
        for node in seq:
            all_nodes.add(node)
        for i in range(len(seq) - 1):
            u, v = seq[i], seq[i + 1]
            if v not in adj[u]:
                adj[u].add(v)
                in_degree[v] += 1
        if len(seq) == 1:
            in_degree.setdefault(seq[0], 0)

    # All nodes in org must appear in seqs
    if set(org) != all_nodes:
        return False

    queue = deque(node for node in all_nodes if in_degree.get(node, 0) == 0)
    idx = 0  # pointer into org

    while queue:
        # Uniqueness requirement: exactly one node with in-degree 0 at each step
        if len(queue) > 1:
            return False
        node = queue.popleft()
        # Node must match the next element in org
        if idx >= len(org) or org[idx] != node:
            return False
        idx += 1
        for neighbor in adj[node]:
            in_degree[neighbor] -= 1
            if in_degree[neighbor] == 0:
                queue.append(neighbor)

    return idx == len(org)


# 5. Minimum Height Trees
# ─────────────────────────────────────────────────────────────────────────────
# Problem: undirected tree with n nodes; find all roots that produce minimum
# height trees. Return list of such root nodes.
#
# Approach: iteratively prune leaf nodes (degree 1) inward — like reverse BFS.
# The last 1 or 2 remaining nodes are the answer (always ≤ 2 roots for a tree).

def minimum_height_trees(n, edges):
    if n == 1:
        return [0]
    if n == 2:
        return [0, 1]

    # Build undirected adjacency using sets (for O(1) removal)
    adj = defaultdict(set)
    for u, v in edges:
        adj[u].add(v)
        adj[v].add(u)

    # Seed with all leaf nodes (degree 1)
    leaves = deque(node for node in range(n) if len(adj[node]) == 1)
    remaining = n

    while remaining > 2:
        remaining -= len(leaves)
        next_leaves = deque()
        while leaves:
            leaf = leaves.popleft()
            # The leaf's only neighbor loses a connection
            neighbor = adj[leaf].pop()
            adj[neighbor].remove(leaf)
            if len(adj[neighbor]) == 1:
                next_leaves.append(neighbor)
        leaves = next_leaves

    return list(leaves)


# ─────────────────────────────────────────────────────────────────────────────
# TEST PRINTS
# ─────────────────────────────────────────────────────────────────────────────

if __name__ == "__main__":

    # 1. Course Schedule I
    print("=== Course Schedule I ===")
    print(can_finish_courses(2, [[1, 0]]))           # True  (0→1, no cycle)
    print(can_finish_courses(2, [[1, 0], [0, 1]]))   # False (cycle: 0↔1)
    print(can_finish_courses(5, [[1,0],[2,1],[3,2],[4,3]]))  # True (linear chain)

    # 2. Course Schedule II
    print("\n=== Course Schedule II ===")
    print(find_order(4, [[1,0],[2,0],[3,1],[3,2]]))  # e.g. [0,1,2,3] or [0,2,1,3]
    print(find_order(2, [[0,1]]))                     # [1, 0]
    print(find_order(2, [[1,0],[0,1]]))               # [] (cycle)

    # 3. Alien Dictionary
    print("\n=== Alien Dictionary ===")
    words1 = ["wrt", "wrf", "er", "ett", "rftt"]
    print(f"words1: '{alien_dictionary(words1)}'")   # some ordering containing t<f, w<e, r<t, e<r

    words2 = ["z", "x"]
    print(f"words2: '{alien_dictionary(words2)}'")   # "zx" (z < x)

    words3 = ["z", "x", "z"]       # cycle z<x and x<z
    print(f"words3 (cycle): '{alien_dictionary(words3)}'")  # ""

    words4 = ["abc", "ab"]          # longer before shorter prefix → invalid
    print(f"words4 (invalid prefix): '{alien_dictionary(words4)}'")  # ""

    # 4. Sequence Reconstruction
    print("\n=== Sequence Reconstruction ===")
    print(sequence_reconstruction([1,2,3], [[1,2],[1,3],[2,3]]))   # True  (unique)
    print(sequence_reconstruction([1,2,3], [[1,2],[1,3]]))          # False (ambiguous: 2 vs 3 order)
    print(sequence_reconstruction([4,1,5,2,6,3], [[5,2,6,3],[4,1,5,2]]))  # True

    # 5. Minimum Height Trees
    print("\n=== Minimum Height Trees ===")
    print(minimum_height_trees(4, [[1,0],[1,2],[1,3]]))   # [1]
    print(minimum_height_trees(6, [[3,0],[3,1],[3,2],[3,4],[5,4]]))  # [3, 4]
    print(minimum_height_trees(1, []))                     # [0]
