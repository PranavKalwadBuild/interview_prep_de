<!-- Part of sql-patterns: Silent Errors — Join and Aggregation Fan-out -->

# Silent Errors — Join and Aggregation Fan-out

The most financially costly SQL bugs tend to live in this category. A SUM that is 2× too large because a JOIN introduced duplicate rows will not raise an error. The query runs. The number looks plausible — it's always a real sum, just of the wrong set of rows. These bugs are most dangerous in financial reporting, billing, and revenue attribution.

---

### One-to-Many JOIN Fan-out — SUM Doubles Silently

**What it looks like:**
```sql
SELECT
    o.customer_id,
    SUM(o.order_amount) AS total_revenue
FROM orders o
JOIN order_items oi ON o.order_id = oi.order_id
GROUP BY o.customer_id;
```

**What actually happens:** Each order row in `orders` has multiple rows in `order_items`. The JOIN multiplies each `order_amount` by the number of items in that order. A $100 order with 3 items appears 3 times. `SUM(order_amount)` returns 3× the actual order value. No error — just inflated revenue.

**Why it's insidious:** The result looks like revenue. It's the right order of magnitude. For orders with 1 item (many orders), the result is exactly correct. The bias only shows up when multi-item orders are included, and the overcount is proportional to order complexity, not order count.

**Minimal repro:**
```sql
WITH orders AS (
    SELECT * FROM (VALUES (1, 100), (2, 200)) t(order_id, amount)
),
order_items AS (
    SELECT * FROM (VALUES (1,'A'),(1,'B'),(1,'C'),(2,'X')) t(order_id, item)
)
SELECT o.order_id,
       SUM(o.amount)                        AS wrong_sum,  -- 300, 200 (order 1 tripled)
       o.amount                             AS correct_amount
FROM orders o
JOIN order_items oi ON o.order_id = oi.order_id
GROUP BY o.order_id, o.amount;
```

**How to catch it:**
```sql
-- Pre-join row count check:
SELECT COUNT(*) FROM orders;           -- baseline
SELECT COUNT(*) FROM orders o JOIN order_items oi ON o.order_id = oi.order_id;
-- If join result > orders baseline, fan-out is occurring.

-- Fix: aggregate in a subquery before joining, or use SUM(DISTINCT amount):
SELECT o.customer_id, SUM(DISTINCT o.order_amount) -- DISTINCT protects against exact-value duplicates
-- Better fix: pre-aggregate order_items before joining
SELECT o.customer_id, SUM(o.order_amount)
FROM orders o
WHERE EXISTS (SELECT 1 FROM order_items oi WHERE oi.order_id = o.order_id)
GROUP BY o.customer_id;
```

**Real-world trigger:** Revenue report for a new product line that ships orders with multiple line items (bundles). Single-item product lines (legacy) show correct revenue. Bundle product lines show 3–5× inflated revenue. Finance team flags the discrepancy 2 months after launch.

---

### Many-to-Many JOIN — Silent Cartesian Row Explosion

**What it looks like:**
```sql
SELECT
    a.campaign_id,
    SUM(a.impressions)      AS total_impressions,
    SUM(b.conversions)      AS total_conversions
FROM ad_impressions a
JOIN ad_conversions b ON a.campaign_id = b.campaign_id
GROUP BY a.campaign_id;
```

**What actually happens:** Both tables have multiple rows per `campaign_id`. The JOIN is many-to-many. If a campaign has 1000 impression rows and 50 conversion rows, the result has 50,000 rows. `SUM(impressions)` is 50,000× the actual impression count (each impression row is duplicated 50 times). `SUM(conversions)` is similarly inflated.

**Why it's insidious:** The ratio `conversions/impressions` may look reasonable (both numerator and denominator are inflated by the same factor, so the ratio appears correct). But the absolute values are astronomically wrong. If downstream logic uses the absolute counts for budget calculations, costs explode.

**Minimal repro:**
```sql
WITH impressions AS (
    SELECT 1 AS cid, 1000 AS imps UNION ALL SELECT 1, 2000
),
conversions AS (
    SELECT 1 AS cid, 50 AS convs UNION ALL SELECT 1, 30
)
SELECT i.cid,
       SUM(i.imps)   AS wrong_impressions,  -- (1000+2000)*2 = 6000 (doubled by 2 conv rows)
       SUM(c.convs)  AS wrong_conversions   -- (50+30)*2    = 160  (doubled by 2 imp rows)
FROM impressions i JOIN conversions c ON i.cid = c.cid
GROUP BY i.cid;
-- Correct: imps=3000, convs=80
```

**How to catch it:**
```sql
-- Pre-aggregate each table before joining:
WITH imp_agg AS (SELECT campaign_id, SUM(impressions) AS impressions FROM ad_impressions GROUP BY campaign_id),
     conv_agg AS (SELECT campaign_id, SUM(conversions) AS conversions FROM ad_conversions GROUP BY campaign_id)
SELECT i.campaign_id, i.impressions, c.conversions
FROM imp_agg i LEFT JOIN conv_agg c ON i.campaign_id = c.campaign_id;
```

**Real-world trigger:** Marketing attribution model JOINs two separate event streams at the campaign level. Both streams have multiple rows per campaign per day. Model has run for a year before a new analyst checks absolute impression counts and finds them 40× higher than the ad platform reports.

---

### LEFT JOIN with WHERE on Right-Side Column — Silently Becomes INNER JOIN

**What it looks like:**
```sql
SELECT u.user_id, u.name, o.order_id
FROM users u
LEFT JOIN orders o ON u.user_id = o.user_id
WHERE o.status = 'completed';
```

**What actually happens:** `LEFT JOIN` generates NULLs for users with no orders. `WHERE o.status = 'completed'` filters out all rows where `o.status IS NULL` — which includes all users with no orders. The LEFT JOIN is silently converted to an INNER JOIN. Users with no completed orders disappear from the result entirely.

**Why it's insidious:** The query looks like "all users plus their completed orders." It behaves like "only users who have at least one completed order." The visual structure (LEFT JOIN) implies preserving all users. The logical effect (WHERE on right column) destroys that preservation. No error.

**Minimal repro:**
```sql
WITH users AS (SELECT * FROM (VALUES (1,'Alice'),(2,'Bob'),(3,'Carol')) t(id, name)),
     orders AS (SELECT * FROM (VALUES (1,'completed'),(1,'pending')) t(uid, status))
SELECT u.id, u.name, o.status
FROM users u
LEFT JOIN orders o ON u.id = o.uid
WHERE o.status = 'completed';
-- Returns: only Alice with 'completed'. Bob and Carol vanish.
-- Expected: Alice(completed), Bob(NULL), Carol(NULL) with filter applied.
```

**How to catch it:**
```sql
-- Move the filter to the ON clause:
SELECT u.user_id, u.name, o.order_id
FROM users u
LEFT JOIN orders o ON u.user_id = o.user_id AND o.status = 'completed';
-- OR: keep WHERE but add OR IS NULL
WHERE o.status = 'completed' OR o.status IS NULL;
```

**Real-world trigger:** User retention report. "Active users this month" defined as users LEFT JOIN orders WHERE status = 'completed'. Users who signed up but never ordered are silently excluded. Retention rate is overstated because the denominator only includes users who have ordered at least once.

---

### Aggregating After a JOIN Before Deduplication — Wrong Aggregate Values

**What it looks like:**
```sql
SELECT
    u.segment,
    AVG(t.transaction_amount) AS avg_transaction
FROM users u
JOIN transactions t ON u.user_id = t.user_id
JOIN promotions p ON u.user_id = p.user_id
GROUP BY u.segment;
```

**What actually happens:** If `promotions` has multiple rows per user (multiple promotion enrollments), the JOIN introduces duplicate transaction rows for each promotion enrollment. `AVG(transaction_amount)` is computed over the duplicated rows. A user with 3 promotions and 2 transactions contributes 6 rows to the average, not 2. Their transaction amounts are over-weighted.

**Why it's insidious:** The AVG looks reasonable — it's in the right ballpark. The over-representation is proportional to promotion enrollment count, not transaction amount, so there's no obvious direction of bias to detect.

**Minimal repro:**
```sql
WITH users AS (SELECT 1 AS uid, 'premium' AS seg),
     txns AS (SELECT 1 AS uid, 100 AS amt UNION ALL SELECT 1, 200),
     promos AS (SELECT 1 AS uid, 'X' AS code UNION ALL SELECT 1, 'Y' UNION ALL SELECT 1, 'Z')
SELECT u.seg,
       COUNT(*) AS row_count,   -- 6 (2 txns * 3 promos)
       AVG(t.amt) AS avg_amt    -- 150 (correct by coincidence: symmetric values)
FROM users u
JOIN txns t ON u.uid = t.uid
JOIN promos p ON u.uid = p.uid
GROUP BY u.seg;
-- Try with asymmetric txns (100, 900) to see bias:
-- Duplicated rows pull average toward whichever value appears more often
```

**How to catch it:**
```sql
-- Always check row count before and after each JOIN:
SELECT COUNT(*) FROM users u JOIN transactions t ON u.user_id = t.user_id;
SELECT COUNT(*) FROM users u JOIN transactions t ON u.user_id = t.user_id
                              JOIN promotions p ON u.user_id = p.user_id;
-- If second > first, fanout introduced by promotions join.
```

**Real-world trigger:** A/B test analysis. Treatment group users enrolled in multiple experiments simultaneously. Transaction amounts are double/triple-counted silently. Treatment appears to have higher average revenue than control — a false positive that drives a $2M product decision.

---

### COUNT(DISTINCT) on Post-JOIN Data — Undercounts When Keys Collide

**What it looks like:**
```sql
SELECT
    COUNT(DISTINCT u.user_id) AS distinct_users
FROM users u
JOIN events e ON u.user_id = e.user_id;
```

**What actually happens:** `COUNT(DISTINCT)` is correct here — it deduplicates after the join. But consider the subtler case where the join key is not truly unique in the dimension:

```sql
SELECT COUNT(DISTINCT e.session_id)
FROM events e
JOIN users u ON e.email = u.email;  -- email is not unique in users (historical addresses)
```

If a user has two rows in `users` with the same email (historical duplicates), each session row in `events` is joined to two user rows. `COUNT(DISTINCT session_id)` still returns the correct session count. But `COUNT(DISTINCT u.user_id)` returns more unique user IDs than expected because the same email maps to multiple IDs — silently inflating the user count.

**Why it's insidious:** The DISTINCT makes you think deduplication is handled. But DISTINCT deduplicates the column you specify, not the logical entity you intend. If the join created new combinations, those combinations are distinct even if the underlying entity is not.

**Minimal repro:**
```sql
WITH events AS (SELECT 'a@b.com' AS email, 'sess1' AS sid),
     users AS (SELECT 1 AS uid, 'a@b.com' AS email  -- user 1
               UNION ALL SELECT 2, 'a@b.com')        -- duplicate email = user 2
SELECT COUNT(DISTINCT e.sid) AS sessions,   -- 1 (correct)
       COUNT(DISTINCT u.uid) AS users        -- 2 (wrong: 1 person, 2 user IDs)
FROM events e JOIN users u ON e.email = u.email;
```

**How to catch it:**
```sql
-- Verify dimension uniqueness before joining:
SELECT email, COUNT(*) FROM users GROUP BY email HAVING COUNT(*) > 1;
```

**Real-world trigger:** User engagement analysis joins event log to user table on email. Customer merged two accounts with the same email during an acquisition. Every metric involving that customer's sessions now double-counts their activity.

---

### Chasm Trap — Two Fact Tables Through a Shared Dimension

**What it looks like:**
```sql
-- Star schema: dimension = customer, facts = orders + support_tickets
SELECT
    c.customer_id,
    SUM(o.order_amount)     AS total_orders,
    COUNT(st.ticket_id)     AS ticket_count
FROM customers c
LEFT JOIN orders o         ON c.customer_id = o.customer_id
LEFT JOIN support_tickets st ON c.customer_id = st.customer_id
GROUP BY c.customer_id;
```

**What actually happens:** This is the chasm trap. A customer with 3 orders and 2 support tickets produces a result with 6 rows (3 × 2 Cartesian product). `SUM(order_amount)` triples each order amount. `COUNT(ticket_id)` doubles each ticket count. Both aggregates are wrong. No error.

**Why it's insidious:** The LEFT JOINs look correct individually. The issue is joining two fact tables simultaneously through a shared dimension — a classic data modeling mistake. The result has more rows than either fact table.

**Minimal repro:**
```sql
WITH cust AS (SELECT 1 AS cid),
     orders AS (SELECT 1 AS cid, 100 AS amt UNION ALL SELECT 1, 200 UNION ALL SELECT 1, 300),
     tickets AS (SELECT 1 AS cid, 'T1' AS tid UNION ALL SELECT 1, 'T2')
SELECT c.cid,
       SUM(o.amt)      AS total,        -- 1800 (should be 600: tripled because 3*2=6 rows)
       COUNT(t.tid)    AS ticket_count  -- 6 (should be 2: same reason)
FROM cust c
LEFT JOIN orders o ON c.cid = o.cid
LEFT JOIN tickets t ON c.cid = t.cid
GROUP BY c.cid;
```

**How to catch it:**
```sql
-- Fix: aggregate each fact independently before joining to dimension:
WITH order_agg AS (
    SELECT customer_id, SUM(order_amount) AS total_orders
    FROM orders GROUP BY customer_id
),
ticket_agg AS (
    SELECT customer_id, COUNT(*) AS ticket_count
    FROM support_tickets GROUP BY customer_id
)
SELECT c.customer_id, oa.total_orders, ta.ticket_count
FROM customers c
LEFT JOIN order_agg oa ON c.customer_id = oa.customer_id
LEFT JOIN ticket_agg ta ON c.customer_id = ta.customer_id;
```

**Real-world trigger:** Executive dashboard showing "total revenue per customer and their support load." Both metrics appear reasonable. Finance reconciliation finds total revenue in the dashboard is 3× the actual total. Root cause: customers with both orders and tickets had their revenue multiplied by ticket count.

---

### Accidental CROSS JOIN — Omitted JOIN Condition

**What it looks like:**
```sql
SELECT
    u.user_id,
    p.product_name,
    SUM(o.amount) AS revenue
FROM users u,
     orders o,
     products p
WHERE o.user_id = u.user_id  -- forgot: AND o.product_id = p.product_id
GROUP BY u.user_id, p.product_name;
```

**What actually happens:** The omitted `AND o.product_id = p.product_id` means every order row is joined to every product row — a Cartesian product. A warehouse with 10,000 products and 1M orders generates 10B rows. The query either runs for hours or returns an astronomically large result. Revenue is multiplied by the number of products. No error.

**Why it's insidious:** In the comma-separated FROM syntax (old-style join), missing a WHERE condition is syntactically valid. The result is massive but not obviously wrong if you only look at a small LIMIT sample.

**Minimal repro:**
```sql
WITH users AS (SELECT 1 AS uid),
     orders AS (SELECT 1 AS uid, 100 AS amt),
     products AS (SELECT 'A' AS pname UNION ALL SELECT 'B' UNION ALL SELECT 'C')
SELECT u.uid, p.pname, SUM(o.amt)
FROM users u, orders o, products p
WHERE o.uid = u.uid           -- missing: AND condition linking orders to products
GROUP BY u.uid, p.pname;
-- Returns 3 rows (one per product) each with amt=100 — Cartesian product silently applied
```

**How to catch it:**
```sql
-- Always use explicit JOIN ... ON syntax rather than comma-separated FROM:
FROM users u
JOIN orders o ON o.user_id = u.user_id
JOIN products p ON o.product_id = p.product_id   -- explicit, hard to miss
```


---

### Self-Join Pair Counting — Strict vs Non-Strict Inequality

**What it looks like:**
```sql
-- "Count all pairs of users in the same cohort who both converted"
SELECT COUNT(*) AS converting_pairs
FROM users t1
JOIN users t2 ON t1.cohort_id = t2.cohort_id
WHERE t1.converted = TRUE AND t2.converted = TRUE
  AND t1.user_id != t2.user_id;
```

**What actually happens:** `t1.user_id != t2.user_id` generates *ordered* pairs: `(A,B)` and `(B,A)` are both counted. The count is exactly 2× the number of unordered pairs. If the intent was "unique pairs," use `t1.user_id < t2.user_id`. The confusion between `!=` and `<` silently doubles (or halves) the count depending on which was intended.

**Why it's insidious:** The count is always a real count of real combinations — just the wrong combinations. It's off by exactly 2×, which might match intuition ("2× seems like double-counting, not wrong math") but might also just look like "twice as many pairs as expected, interesting."

**Minimal repro:**
```sql
WITH users AS (
    SELECT * FROM (VALUES ('A','c1',TRUE),('B','c1',TRUE),('C','c1',FALSE)) t(uid,cohort,conv)
)
SELECT COUNT(*) AS pairs_neq,
       (SELECT COUNT(*) FROM users t1 JOIN users t2
        ON t1.cohort = t2.cohort AND t1.conv AND t2.conv AND t1.uid < t2.uid) AS pairs_lt
FROM users t1 JOIN users t2
ON t1.cohort = t2.cohort AND t1.conv AND t2.conv AND t1.uid != t2.uid;
-- pairs_neq = 2 (A-B and B-A counted), pairs_lt = 1 (only A-B, the unique pair)
```

**How to catch it:** Every self-join should explicitly document whether it counts ordered or unordered pairs. Use `<` for unordered pairs, `!=` for ordered pairs (or to exclude self-pairs in ordered context). Include the expected pair count in comments.

**Real-world trigger:** Network analysis of referred users. "Referral pairs" counted using `!=`. The referral network appears 2× larger than it actually is. A partnership deal is structured around reaching "10,000 referral pairs" — a milestone that was actually hit at 5,000 unique pairs.
