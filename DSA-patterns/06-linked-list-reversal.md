# Pattern 06: In-Place Linked List Reversal

## One-Line Summary
Reverse part or all of a linked list using iterative pointer manipulation — no extra space, no recursion stack.

---

## Recognition Keywords
- "reverse a linked list"
- "reverse a sublist from position p to q"
- "reverse every k-group"
- "rotate a linked list"
- "reverse alternating k elements"

**Key Tell**: The problem requires changing link direction. If you need O(1) space and cannot copy nodes into an array, you must do in-place pointer rewiring. The phrase "in-place" or an O(1) space constraint is the clearest signal.

---

## Core Template

```python
def reverse_list(head):
    prev = None
    curr = head
    while curr:
        next_node = curr.next   # save next before overwriting
        curr.next = prev        # reverse the link
        prev = curr             # advance prev
        curr = next_node        # advance curr
    return prev                 # prev is the new head
```

**Three-pointer dance**: `prev`, `curr`, `next_node`. You always need to save `curr.next` before you overwrite it.

---

## Complexity
| Dimension | Cost |
|-----------|------|
| Time      | O(n) — single pass (or O(L) for sublist of length L) |
| Space     | O(1) — pointer variables only |

---

## Canonical Problem
**Reverse a Linked List** — full reversal of a singly linked list.

Walk with `prev=None, curr=head`; at each step reverse the link, then advance both pointers; return `prev` at the end.

---

## Variations

| Problem | Twist |
|---------|-------|
| Reverse a Sub-list (p to q) | Advance to node p-1 first; save `before_sublist` and `tail_of_sublist`; reverse p..q; reconnect |
| Reverse Every K-element Sub-list | Repeat the sublist reversal in chunks of k across the whole list |
| Reverse Alternating K Elements | Reverse k, skip k, repeat — track a `skip` flag |
| Rotate a Linked List (right by k) | Find length, make circular, break at position `n - k % n` |

---

## Gotchas

1. **Reconnecting the reversed segment**: After reversing a sublist, the node that was head of the sublist is now its tail. You must connect `tail_of_sublist.next = node_after_sublist` and `before_sublist.next = new_sublist_head`. Missing either connection silently drops part of the list.

2. **Tracking `before_sublist`**: You need the node just *before* position p. Walk `p-1` steps, not `p` steps. Off-by-one here causes a wrong reconnection.

3. **k larger than remaining list**: In k-group reversal, if fewer than k nodes remain you may want to leave them unreversed (LeetCode 25 behavior). Check remaining length before reversing.

4. **Rotate by k >= n**: Always take `k = k % n` first; rotating by n is a no-op.

5. **Saving `next_node` first**: The very first thing inside the loop must be `next_node = curr.next`. Overwriting `curr.next = prev` before saving `next_node` loses the rest of the list permanently.
