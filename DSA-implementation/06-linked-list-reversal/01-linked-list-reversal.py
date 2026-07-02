"""
PATTERN: In-Place Linked List Reversal
=======================================
RECOGNITION SIGNALS:
  - "reverse a linked list" (full or partial)
  - "reverse a sublist from position p to q"
  - "reverse every k-group"
  - "rotate a linked list"
  - "reverse alternating k elements"
  - Key tell: O(1) space constraint + need to change link direction

CORE IDEA:
  Three-pointer dance: prev, curr, next_node.
  Save next before overwriting curr.next, then reverse the link, then advance.

BOILERPLATE TEMPLATE (full reversal):
  prev = None
  curr = head
  while curr:
      next_node = curr.next   # save FIRST — overwriting curr.next loses the rest
      curr.next = prev        # reverse the link
      prev = curr             # advance prev
      curr = next_node        # advance curr
  return prev                 # new head

COMPLEXITY: O(n) time | O(1) space
"""


# ---------------------------------------------------------------------------
# NODE DEFINITION
# ---------------------------------------------------------------------------
class ListNode:
    def __init__(self, val=0, next=None):
        self.val = val
        self.next = next


# ---------------------------------------------------------------------------
# HELPERS
# ---------------------------------------------------------------------------
def build_list(values):
    """Build a linked list from a Python list; return head."""
    if not values:
        return None
    head = ListNode(values[0])
    curr = head
    for v in values[1:]:
        curr.next = ListNode(v)
        curr = curr.next
    return head


def list_to_array(head):
    """Convert linked list to Python list for easy printing."""
    result = []
    while head:
        result.append(head.val)
        head = head.next
    return result


# ---------------------------------------------------------------------------
# PROBLEM 1: Reverse a Linked List (full reversal)
# Example: 1->2->3->4->5 -> 5->4->3->2->1
# ---------------------------------------------------------------------------
def reverse_list(head):
    prev = None
    curr = head
    while curr:
        next_node = curr.next   # save next BEFORE overwriting
        curr.next = prev        # reverse the link
        prev = curr
        curr = next_node
    return prev                 # prev is the new head


# ---------------------------------------------------------------------------
# PROBLEM 2: Reverse a Sub-list (positions p to q, 1-indexed)
# Example: 1->2->3->4->5, p=2, q=4 -> 1->4->3->2->5
# GOTCHA: track before_sublist and sublist_tail for reconnection
# ---------------------------------------------------------------------------
def reverse_sublist(head, p, q):
    if not head or p == q:
        return head

    dummy = ListNode(0)
    dummy.next = head
    before_sublist = dummy

    # advance to node just before position p
    for _ in range(p - 1):
        before_sublist = before_sublist.next

    # sublist_tail will become the tail after reversal
    sublist_tail = before_sublist.next

    # reverse p..q nodes
    prev = None
    curr = sublist_tail
    for _ in range(q - p + 1):
        next_node = curr.next
        curr.next = prev
        prev = curr
        curr = next_node

    # reconnect: before_sublist -> new head of reversed segment
    #            old head (now tail) -> node after q
    before_sublist.next = prev          # prev is new head of reversed segment
    sublist_tail.next = curr            # curr is the node after position q

    return dummy.next


# ---------------------------------------------------------------------------
# PROBLEM 3: Reverse Every K-element Sub-list
# Example: 1->2->3->4->5->6->7->8, k=3 -> 3->2->1->6->5->4->8->7
# GOTCHA: if fewer than k nodes remain, leave them as-is
# ---------------------------------------------------------------------------
def reverse_every_k_group(head, k):
    curr = head
    prev_tail = None            # tail of the last reversed group

    while curr:
        group_head = curr       # will become the tail of this group after reversal

        # check if k nodes remain
        check = curr
        for _ in range(k):
            if not check:
                # fewer than k nodes left — attach remaining as-is and stop
                if prev_tail:
                    prev_tail.next = group_head
                return head
            check = check.next

        # reverse k nodes
        prev = None
        for _ in range(k):
            next_node = curr.next
            curr.next = prev
            prev = curr
            curr = next_node

        # connect previous group's tail to new head of this group
        if prev_tail:
            prev_tail.next = prev
        else:
            head = prev         # first group: update head

        prev_tail = group_head  # group_head is now the tail of this reversed group

    return head


# ---------------------------------------------------------------------------
# PROBLEM 4: Reverse Alternating K Elements
# Reverse k nodes, skip k nodes, repeat.
# Example: 1->2->3->4->5->6->7->8, k=2 -> 2->1->3->4->6->5->7->8
# ---------------------------------------------------------------------------
def reverse_alternating_k_elements(head, k):
    curr = head
    prev_tail = None

    while curr:
        group_head = curr       # will be the tail after reversal

        # --- reverse k nodes ---
        prev = None
        i = 0
        while curr and i < k:
            next_node = curr.next
            curr.next = prev
            prev = curr
            curr = next_node
            i += 1

        # connect previous group's tail to new head of reversed segment
        if prev_tail:
            prev_tail.next = prev
        else:
            head = prev

        # group_head is now the tail of the reversed segment;
        # point it at curr (start of skip region) so the list stays connected
        group_head.next = curr
        prev_tail = group_head

        # --- skip k nodes (advance prev_tail through the kept nodes) ---
        i = 0
        while curr and i < k:
            prev_tail = curr
            curr = curr.next
            i += 1

    return head


# ---------------------------------------------------------------------------
# PROBLEM 5: Rotate a Linked List (right by k)
# Example: 1->2->3->4->5, k=2 -> 4->5->1->2->3
# GOTCHA: k >= n is handled by k = k % n
# ---------------------------------------------------------------------------
def rotate_list(head, k):
    if not head or not head.next or k == 0:
        return head

    # find length and tail
    length = 1
    tail = head
    while tail.next:
        tail = tail.next
        length += 1

    k = k % length
    if k == 0:
        return head             # rotating by n is a no-op

    # make the list circular
    tail.next = head

    # new tail is at position (length - k - 1) from original head (0-indexed)
    steps_to_new_tail = length - k - 1
    new_tail = head
    for _ in range(steps_to_new_tail):
        new_tail = new_tail.next

    new_head = new_tail.next
    new_tail.next = None        # break the circle

    return new_head


# ---------------------------------------------------------------------------
# TEST PRINTS
# ---------------------------------------------------------------------------
if __name__ == "__main__":
    print("=== Linked List Reversal Problems ===\n")

    print("1. Reverse a Linked List")
    head = build_list([1, 2, 3, 4, 5])
    print(list_to_array(reverse_list(head)))            # [5, 4, 3, 2, 1]

    head = build_list([1, 2])
    print(list_to_array(reverse_list(head)))            # [2, 1]
    print()

    print("2. Reverse a Sub-list (p=2, q=4)")
    head = build_list([1, 2, 3, 4, 5])
    print(list_to_array(reverse_sublist(head, 2, 4)))   # [1, 4, 3, 2, 5]

    head = build_list([1, 2, 3, 4, 5])
    print(list_to_array(reverse_sublist(head, 1, 5)))   # [5, 4, 3, 2, 1]
    print()

    print("3. Reverse Every K-element Sub-list (k=3)")
    head = build_list([1, 2, 3, 4, 5, 6, 7, 8])
    print(list_to_array(reverse_every_k_group(head, 3)))  # [3, 2, 1, 6, 5, 4, 8, 7]

    head = build_list([1, 2, 3, 4, 5])
    print(list_to_array(reverse_every_k_group(head, 2)))  # [2, 1, 4, 3, 5]
    print()

    print("4. Reverse Alternating K Elements (k=2)")
    head = build_list([1, 2, 3, 4, 5, 6, 7, 8])
    print(list_to_array(reverse_alternating_k_elements(head, 2)))  # [2, 1, 3, 4, 6, 5, 7, 8]
    print()

    print("5. Rotate List (k=2)")
    head = build_list([1, 2, 3, 4, 5])
    print(list_to_array(rotate_list(head, 2)))          # [4, 5, 1, 2, 3]

    head = build_list([0, 1, 2])
    print(list_to_array(rotate_list(head, 4)))          # [2, 0, 1]  (4 % 3 = 1)
