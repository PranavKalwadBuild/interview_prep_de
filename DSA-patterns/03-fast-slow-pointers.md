# Fast & Slow Pointers

**One-line description**: Two pointers moving at different speeds through a linked list or array.

---

## Recognition Keywords

- "linked list cycle" / "detect cycle"
- "find the middle of linked list"
- "happy number" / "cycle in number sequence"
- "palindrome linked list"
- "find the start of cycle"
- "circular array loop"

**Key tell**: The sequence eventually repeats or forms a loop; you need to find a meeting point or midpoint. If there is a cycle, the fast pointer will eventually lap the slow pointer — they must meet.

---

## Pattern Templates

### 1. Cycle Detection (Floyd's Tortoise and Hare)

```python
def has_cycle(head):
    slow, fast = head, head
    while fast and fast.next:
        slow = slow.next
        fast = fast.next.next
        if slow == fast:
            return True   # cycle detected
    return False
```

### 2. Find Middle of Linked List

```python
def find_middle(head):
    slow, fast = head, head
    while fast and fast.next:
        slow = slow.next
        fast = fast.next.next
    return slow   # slow is at the middle
```

### 3. Find Cycle Start (second phase after meeting)

```python
def find_cycle_start(head):
    slow, fast = head, head
    # Phase 1: detect meeting point
    while fast and fast.next:
        slow = slow.next
        fast = fast.next.next
        if slow == fast:
            break
    else:
        return None   # no cycle

    # Phase 2: distance from head == distance from meeting point to cycle start
    pointer = head
    while pointer != slow:
        pointer = pointer.next
        slow = slow.next
    return slow   # cycle start node
```

---

## Complexity

| | Time | Space |
|---|---|---|
| All variants | O(n) | O(1) |

---

## Canonical Problem: Linked List Cycle (LeetCode 141)

Detect if a cycle exists in a linked list.

```python
def has_cycle(head):
    slow, fast = head, head
    while fast and fast.next:
        slow = slow.next
        fast = fast.next.next
        if slow == fast:
            return True
    return False
```

---

## Variations

| Variation | Core Idea |
|---|---|
| **Start of Linked List Cycle** (LC 142) | After meeting, reset one pointer to head; advance both one step at a time — they meet at cycle start |
| **Happy Number** (LC 202) | Apply Floyd's to the digit-square sequence: n → sum of squares of digits; if slow == fast and != 1, it's a cycle (not happy) |
| **Middle of Linked List** (LC 876) | When fast reaches end, slow is at middle |
| **Palindrome Linked List** (LC 234) | Find middle, reverse second half in-place, compare both halves |
| **Reorder List** (LC 143) | Find middle, reverse second half, merge first and reversed-second alternately |

---

## Gotchas

1. **Null checks**: Always guard with `while fast and fast.next` before calling `fast.next.next`. Forgetting the `fast.next` guard causes `AttributeError` on the last node of an odd-length list.

2. **Two-phase cycle start math**: After phase 1, the distance from `head` to the cycle start equals the distance from the meeting point to the cycle start (going around the cycle). This is why resetting one pointer to head and advancing both one step at a time finds the start. Trust the math — do not try to derive it live in an interview.

3. **Even vs. odd length for middle**: When the list has even length, `slow` stops at the second of the two middle nodes. For palindrome checks, that is correct (compare second half against first). For split problems, you may want the first middle — subtract one step or track `prev`.

4. **Happy number termination**: The non-happy cycle never includes 1; it cycles through a fixed set of numbers. So `while n != 1` with Floyd's on the digit-square function terminates correctly.

5. **Palindrome reverse in-place**: Remember to restore the list if the problem requires it (some interviewers ask).
