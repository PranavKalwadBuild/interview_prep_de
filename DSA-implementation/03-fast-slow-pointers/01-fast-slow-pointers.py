"""
03-fast-slow-pointers.py
Pattern: Fast & Slow Pointers (Floyd's Tortoise and Hare)

Recognition signals:
  - "linked list cycle" / "detect a loop"
  - "find the middle" of linked list
  - "happy number" (cycle in digit-square sequence)
  - "palindrome linked list"
  - Key tell: if there's a cycle, fast pointer laps slow pointer -> they meet
"""

# ---------------------------------------------------------------------------
# ListNode definition
# ---------------------------------------------------------------------------

class ListNode:
    def __init__(self, val=0, next=None):
        self.val = val
        self.next = next

    def __repr__(self):
        return f"ListNode({self.val})"


# ---------------------------------------------------------------------------
# Helper: build a linked list from a Python list
#         cycle_pos = index where the tail connects back (-1 = no cycle)
# ---------------------------------------------------------------------------

def build_list(values, cycle_pos=-1):
    if not values:
        return None
    nodes = [ListNode(v) for v in values]
    for i in range(len(nodes) - 1):
        nodes[i].next = nodes[i + 1]
    if cycle_pos >= 0:
        nodes[-1].next = nodes[cycle_pos]
    return nodes[0]


# ---------------------------------------------------------------------------
# BOILERPLATE: Cycle detection (Floyd's Tortoise and Hare)
# ---------------------------------------------------------------------------
#
#   slow, fast = head, head
#   while fast and fast.next:          # guard: fast.next prevents AttributeError
#       slow = slow.next
#       fast = fast.next.next
#       if slow == fast:
#           return True   # cycle found
#   return False
#
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# BOILERPLATE: Find cycle start (second phase after meeting)
# ---------------------------------------------------------------------------
#
#   # Phase 1 — find meeting point (same as cycle detection)
#   slow, fast = head, head
#   while fast and fast.next:
#       slow = slow.next
#       fast = fast.next.next
#       if slow == fast:
#           break
#   else:
#       return None   # no cycle
#
#   # Phase 2 — distance from head == distance from meeting point to cycle start
#   pointer = head
#   while pointer != slow:
#       pointer = pointer.next
#       slow = slow.next
#   return slow   # this is the cycle start node
#
# ---------------------------------------------------------------------------


# ---------------------------------------------------------------------------
# 1. CANONICAL: has_cycle(head)
#    Detect whether a linked list contains a cycle.
#    LeetCode 141
# ---------------------------------------------------------------------------

def has_cycle(head: ListNode) -> bool:
    slow, fast = head, head
    while fast and fast.next:
        slow = slow.next
        fast = fast.next.next
        if slow == fast:
            return True
    return False


# ---------------------------------------------------------------------------
# 2. find_cycle_start(head)
#    Return the node where the cycle begins, or None if no cycle.
#    LeetCode 142
#
#    Math insight:
#      Let F = distance from head to cycle start
#          C = cycle length
#          a = distance from cycle start to meeting point
#      When they meet: F + a + k*C = 2*(F + a)  =>  F = C - a
#      So resetting one pointer to head and advancing both one step
#      at a time brings them to the cycle start after exactly F steps.
# ---------------------------------------------------------------------------

def find_cycle_start(head: ListNode):
    slow, fast = head, head

    # Phase 1: detect meeting point
    while fast and fast.next:
        slow = slow.next
        fast = fast.next.next
        if slow == fast:
            break
    else:
        return None  # no cycle

    # Phase 2: reset one pointer to head
    pointer = head
    while pointer != slow:
        pointer = pointer.next
        slow = slow.next

    return slow  # cycle start


# ---------------------------------------------------------------------------
# 3. is_happy_number(n)
#    A happy number eventually reaches 1 under the digit-square sequence.
#    An unhappy number enters a cycle that never includes 1.
#    Apply Floyd's to detect that cycle.
#    LeetCode 202
# ---------------------------------------------------------------------------

def _digit_square_sum(n: int) -> int:
    total = 0
    while n:
        digit = n % 10
        total += digit * digit
        n //= 10
    return total


def is_happy_number(n: int) -> bool:
    slow = n
    fast = _digit_square_sum(n)

    while fast != 1 and slow != fast:
        slow = _digit_square_sum(slow)
        fast = _digit_square_sum(_digit_square_sum(fast))

    return fast == 1


# ---------------------------------------------------------------------------
# 4. find_middle(head)
#    Return the middle node of a linked list.
#    For even-length lists, returns the SECOND of the two middle nodes.
#    LeetCode 876
# ---------------------------------------------------------------------------

def find_middle(head: ListNode) -> ListNode:
    slow, fast = head, head
    while fast and fast.next:
        slow = slow.next
        fast = fast.next.next
    return slow  # slow is at the middle


# ---------------------------------------------------------------------------
# 5. is_palindrome_linked_list(head)
#    Check whether a linked list is a palindrome.
#    Approach:
#      1. Find middle with fast/slow
#      2. Reverse the second half in-place
#      3. Compare first half and reversed second half
#      4. (Optionally restore — not done here for brevity)
#    LeetCode 234
# ---------------------------------------------------------------------------

def _reverse_list(head: ListNode) -> ListNode:
    prev = None
    current = head
    while current:
        next_node = current.next
        current.next = prev
        prev = current
        current = next_node
    return prev


def is_palindrome_linked_list(head: ListNode) -> bool:
    if not head or not head.next:
        return True

    # Step 1: Find middle
    slow, fast = head, head
    while fast and fast.next:
        slow = slow.next
        fast = fast.next.next
    # slow is now at the start of the second half

    # Step 2: Reverse second half
    second_half_head = _reverse_list(slow)

    # Step 3: Compare
    left, right = head, second_half_head
    result = True
    while right:  # second half may be shorter or same length
        if left.val != right.val:
            result = False
            break
        left = left.next
        right = right.next

    return result


# ---------------------------------------------------------------------------
# TESTS
# ---------------------------------------------------------------------------

if __name__ == "__main__":

    # --- has_cycle ---
    print("=== has_cycle ===")
    head = build_list([3, 2, 0, -4], cycle_pos=1)
    print(f"[3->2->0->-4, cycle at index 1]: {has_cycle(head)}")   # True

    head = build_list([1, 2], cycle_pos=0)
    print(f"[1->2, cycle at index 0]:        {has_cycle(head)}")   # True

    head = build_list([1])
    print(f"[1, no cycle]:                   {has_cycle(head)}")   # False

    head = build_list([1, 2])
    print(f"[1->2, no cycle]:                {has_cycle(head)}")   # False

    # --- find_cycle_start ---
    print("\n=== find_cycle_start ===")
    nodes = [ListNode(v) for v in [3, 2, 0, -4]]
    nodes[0].next = nodes[1]
    nodes[1].next = nodes[2]
    nodes[2].next = nodes[3]
    nodes[3].next = nodes[1]   # cycle back to index 1 (val=2)
    print(f"[3->2->0->-4->2...] cycle start val: {find_cycle_start(nodes[0]).val}")  # 2

    head = build_list([1, 2, 3])
    print(f"[1->2->3, no cycle] cycle start:     {find_cycle_start(head)}")          # None

    # --- is_happy_number ---
    print("\n=== is_happy_number ===")
    print(f"19 is happy: {is_happy_number(19)}")   # True  (1^2+9^2=82->68->100->1)
    print(f"2  is happy: {is_happy_number(2)}")    # False
    print(f"1  is happy: {is_happy_number(1)}")    # True
    print(f"7  is happy: {is_happy_number(7)}")    # True

    # --- find_middle ---
    print("\n=== find_middle ===")
    head = build_list([1, 2, 3, 4, 5])
    print(f"[1,2,3,4,5] middle val: {find_middle(head).val}")   # 3

    head = build_list([1, 2, 3, 4, 5, 6])
    print(f"[1,2,3,4,5,6] middle val: {find_middle(head).val}") # 4 (second middle)

    head = build_list([1])
    print(f"[1] middle val: {find_middle(head).val}")            # 1

    # --- is_palindrome_linked_list ---
    print("\n=== is_palindrome_linked_list ===")
    head = build_list([1, 2, 2, 1])
    print(f"[1,2,2,1] is palindrome: {is_palindrome_linked_list(head)}")  # True

    head = build_list([1, 2])
    print(f"[1,2] is palindrome:     {is_palindrome_linked_list(head)}")  # False

    head = build_list([1, 2, 3, 2, 1])
    print(f"[1,2,3,2,1] is palindrome: {is_palindrome_linked_list(head)}")# True

    head = build_list([1])
    print(f"[1] is palindrome:       {is_palindrome_linked_list(head)}")  # True
