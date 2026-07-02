<!-- sql-patterns: Silent Errors — NULL Semantics -->

# Silent Errors — NULL Semantics

NULLs are not a value. They are the absence of a value — and SQL's three-valued logic (TRUE / FALSE / UNKNOWN) is the single richest source of silent wrong results in production. Every comparison, every predicate, every aggregate silently changes behavior when NULL is involved. None of these bugs raise an error.

---

### NOT IN (subquery) NULL-Poisoning

**What it looks like:**
```sql
SELECT customer_id
FROM orders
WHERE customer_id NOT IN (SELECT blacklisted_id FROM blacklist);
```

**What actually happens:** If `blacklist` contains even one NULL row, the result is 0 rows — not the expected "customers who are not blacklisted." The entire result set is silently empty.

**Why it's insidious:** `NOT IN` expands to `col != v1 AND col != v2 AND ... AND col != NULL`. Any comparison against NULL yields UNKNOWN. UNKNOWN AND TRUE = UNKNOWN. The WHERE clause only passes TRUE rows. Every row evaluates to UNKNOWN and is rejected. No error, no warning.

**Minimal repro:**
```sql
WITH cte(id) AS (SELECT * FROM (VALUES (1),(2),(3)) t(id)),
     bl(id)  AS (SELECT * FROM (VALUES (1),(NULL)) t(id))
SELECT * FROM cte WHERE cte.id NOT IN (SELECT id FROM bl);
-- 0 rows returned. Expected: rows 2 and 3.
```

**How to catch it:**
```sql
-- Always verify the subquery is NULL-free before using NOT IN
SELECT COUNT(*) FROM blacklist WHERE blacklisted_id IS NULL;
-- Or rewrite the query entirely:
SELECT customer_id
FROM orders o
WHERE NOT EXISTS (
    SELECT 1 FROM blacklist b WHERE b.blacklisted_id = o.customer_id
);
```

**Real-world trigger:** Blacklist / exclusion tables populated by LEFT JOIN pattern that introduced NULLs for unmatched rows. Pipeline runs fine for weeks, then a single NULL in the exclusion list makes every customer pass the filter — or blocks every customer, depending on direction. Downstream fraud report goes to zero or explodes.

---

### COUNT(*) vs COUNT(col) Divergence in Ratio Calculations

**What it looks like:**
```sql
SELECT
    COUNT(*) AS total_rows,
    COUNT(revenue) AS revenue_rows,
    SUM(revenue) / COUNT(*) AS avg_revenue   -- the bug
FROM orders;
```

**What actually happens:** `COUNT(*)` counts all rows including those where `revenue IS NULL`. `COUNT(revenue)` counts only non-NULL values. Dividing `SUM(revenue)` by `COUNT(*)` produces a mean that is lower than the true mean of non-NULL revenue because the denominator includes NULL rows.

**Why it's insidious:** The query returns a number. It looks like an average. It is mathematically wrong but plausible — slightly lower than the real average, which is exactly the direction you'd expect if revenue were lower.

**Minimal repro:**
```sql
CREATE TABLE t (id INT, revenue NUMERIC);
INSERT INTO t VALUES (1, 100), (2, 200), (3, NULL);

SELECT
    AVG(revenue)           AS correct_avg,      -- 150.0
    SUM(revenue)/COUNT(*)  AS wrong_avg          -- 100.0 (divides by 3 not 2)
FROM t;
```

**How to catch it:**
```sql
-- Invariant: these two should be equal when no NULLs exist
SELECT
    COUNT(*) - COUNT(revenue) AS null_revenue_rows
FROM orders;
-- If > 0, SUM/COUNT(*) ratios are silently wrong
```

**Real-world trigger:** Revenue-per-order metric in a BI dashboard. Orders table has NULLs for cancelled orders where revenue was never set. Dashboard shows lower-than-actual average revenue for 6 months before someone cross-checks against accounting totals.

---

### AVG() Silently Excludes NULLs — Mean Over Fewer Rows Than Expected

**What it looks like:**
```sql
SELECT
    event_date,
    AVG(response_time_ms) AS avg_response_time
FROM api_logs
GROUP BY event_date;
```

**What actually happens:** `AVG()` ignores NULL values in both numerator and denominator. If `response_time_ms` is NULL for timeout events (the slowest ones!), `AVG()` silently computes the average of only successful calls, excluding the very data that would raise the average.

**Why it's insidious:** The documented behavior is correct — but the semantic implication is that your average is computed over a biased sample. The bias is systematic: NULLs often represent the worst-case events.

**Minimal repro:**
```sql
WITH logs AS (
    SELECT * FROM (VALUES (200),(500),(NULL),(NULL)) t(ms)
)
SELECT
    AVG(ms)                           AS biased_avg,    -- 350 (over 2 rows)
    SUM(ms) / COUNT(*)                AS manual_avg_all, -- 175 (over 4 rows, treats NULLs as 0 — also wrong)
    SUM(COALESCE(ms, 99999)) / COUNT(*) AS timeout_aware  -- 25449 (correct business intent)
FROM logs;
```

**How to catch it:**
```sql
SELECT
    COUNT(*) AS total,
    COUNT(response_time_ms) AS non_null,
    COUNT(*) - COUNT(response_time_ms) AS excluded_from_avg
FROM api_logs
WHERE event_date = CURRENT_DATE;
```

**Real-world trigger:** SLA reporting for an API. Timeouts stored as NULL (never set by the logging framework). Average latency report looks acceptable. Engineers miss that 15% of calls are timing out and being excluded from the average entirely.

---

### COALESCE Placement in Aggregate Context

**What it looks like:**
```sql
-- Variant A: outer COALESCE
SELECT COALESCE(SUM(discount_amount), 0) AS total_discount

-- Variant B: inner COALESCE
SELECT SUM(COALESCE(discount_amount, 0)) AS total_discount
```

**What actually happens:** They are NOT equivalent.
- Variant A: `SUM(NULL, NULL, NULL)` → NULL → COALESCE gives 0.
- Variant B: `SUM(0, 0, 0)` → 0. Same result here, but the semantics diverge when mixing NULLs and real values.

The dangerous case is in windowed/conditional context:
```sql
SUM(COALESCE(col, 0)) OVER (PARTITION BY ...)  -- treats NULL as zero, inflates sum
COALESCE(SUM(col) OVER (...), 0)               -- only replaces NULL if ALL are NULL
```

**Why it's insidious:** Both compile. Both return numbers. In the case where some rows are NULL and some are non-zero, Variant B silently changes the sum by substituting zeros for NULLs.

**Minimal repro:**
```sql
WITH t AS (SELECT * FROM (VALUES (10),(NULL),(NULL)) s(v))
SELECT
    COALESCE(SUM(v), 0)     AS outer_coalesce,  -- 10 (correct: sum of non-nulls)
    SUM(COALESCE(v, 0))     AS inner_coalesce   -- 10 (happens to match here)
FROM t;

-- But in GROUP BY context with an all-NULL group:
WITH t AS (SELECT grp, v FROM (VALUES ('A',10),('B',NULL),('B',NULL)) s(grp,v))
SELECT
    grp,
    COALESCE(SUM(v), 0)     AS outer_c,    -- A:10, B:0
    SUM(COALESCE(v, 0))     AS inner_c     -- A:10, B:0 (same here, but see below)
FROM t GROUP BY grp;

-- Now with division:
-- outer_c / COUNT(*) for B = 0/2 = 0
-- inner_c / COUNT(*) for B = 0/2 = 0 -- still 0, but if v=5 and NULL:
-- outer: 5/1 = 5  vs  inner: (5+0)/2 = 2.5 — SILENT DIVERGENCE
```

**How to catch it:** Build a test case with a group that has both NULL and non-NULL values and verify the aggregate result matches the expected business definition.

**Real-world trigger:** Discount reporting model. Analyst switches from outer COALESCE to inner COALESCE to "simplify" code. Total discounts for product lines with partial NULL entries silently become lower. Margin report looks better than reality.

---

### NULL in GROUP BY — NULLs Form Their Own Silent Group

**What it looks like:**
```sql
SELECT region, COUNT(*) AS orders
FROM orders
GROUP BY region;
```

**What actually happens:** All rows where `region IS NULL` are grouped together into a single group with key NULL. This group appears in the result with a NULL label. Any downstream JOIN on `region` to a dimension table will lose these rows (since NULL != NULL in JOIN conditions).

**Why it's insidious:** The GROUP BY runs without error. The NULL group appears in the output. But subsequent JOINs to a regions dimension silently drop the NULL group entirely.

**Minimal repro:**
```sql
WITH orders AS (
    SELECT region, amount FROM (VALUES ('West',100),('East',200),(NULL,150)) t(region,amount)
),
regions AS (SELECT region, label FROM (VALUES ('West','Western'),('East','Eastern')) t(region,label))
SELECT r.label, SUM(o.amount)
FROM orders o
JOIN regions r ON o.region = r.region
GROUP BY r.label;
-- NULL group (150 in revenue) silently vanishes. No error.
```

**How to catch it:**
```sql
SELECT COUNT(*) FROM orders WHERE region IS NULL;
-- If > 0, any JOIN to a region dimension will silently drop these rows.
```

**Real-world trigger:** Revenue attribution model. Orders without a region assignment (B2B direct, internal test orders) are silently excluded from every regional report for 18 months.

---

### WHERE col != 'value' Silently Excludes NULL Rows

**What it looks like:**
```sql
SELECT * FROM events WHERE status != 'cancelled';
```

**What actually happens:** Rows where `status IS NULL` are also excluded. `NULL != 'cancelled'` evaluates to UNKNOWN, which fails the WHERE clause.

**Why it's insidious:** The developer intends "give me everything except cancelled." They get "give me everything that is confirmed to be not-cancelled." These are different sets when NULL exists. No error — just missing rows.

**Minimal repro:**
```sql
WITH events AS (
    SELECT * FROM (VALUES ('active'),('cancelled'),(NULL)) t(status)
)
SELECT * FROM events WHERE status != 'cancelled';
-- Returns only 'active'. NULL row silently excluded.
-- Expected by most developers: 'active' + NULL row.
```

**How to catch it:**
```sql
-- Correct pattern:
SELECT * FROM events WHERE status != 'cancelled' OR status IS NULL;

-- Detection query:
SELECT COUNT(*) FROM events WHERE status IS NULL;
```

**Real-world trigger:** User churn analysis. Users who never completed their profile have NULL status. Query to find "non-churned users" silently excludes all users without a status, understating the active user base.

---

### CASE WHEN col = NULL THEN ... — Always Takes ELSE

**What it looks like:**
```sql
SELECT
    CASE WHEN priority = NULL THEN 'unset'
         WHEN priority = 'high' THEN 'urgent'
         ELSE 'normal'
    END AS priority_label
FROM tickets;
```

**What actually happens:** `col = NULL` always evaluates to UNKNOWN, never TRUE. The `'unset'` branch is unreachable. All NULL-priority tickets fall into `'normal'`. No error.

**Why it's insidious:** Syntactically valid. Logically correct-looking. Wrong output for every NULL row, with no indication of the problem.

**Minimal repro:**
```sql
WITH t AS (SELECT NULL::VARCHAR AS priority)
SELECT
    CASE WHEN priority = NULL  THEN 'unset'    -- never fires
         WHEN priority IS NULL THEN 'correctly_unset'
         ELSE 'other' END
FROM t;
-- Must use IS NULL, not = NULL
```

**How to catch it:** Code review grep: `WHEN \w+ = NULL` in any CASE expression is always wrong. The correct form is always `WHEN \w+ IS NULL`.

**Real-world trigger:** Ticket prioritization dashboard. All tickets with no priority set are classified as "normal" and routed to a standard queue instead of a triage queue. High-urgency tickets with no explicit priority get delayed.

---

### NULLIF Edge Case: NULLIF(a, a) Returns NULL Even for Non-NULL a

**What it looks like:**
```sql
SELECT total / NULLIF(total - baseline, total - baseline) AS ratio
-- developer intended: return NULL only when denominator would be zero
```

**What actually happens:** `NULLIF(expr, expr)` compares the two arguments using SQL equality. If they are equal, it returns NULL. When the same expression is passed twice, it always returns NULL — so the division always returns NULL. No error.

**Why it's insidious:** `NULLIF` is used as a zero-guard. Passing the same derived expression twice (e.g., when copy-pasting) silently zeros out every calculation using it.

**Minimal repro:**
```sql
SELECT
    NULLIF(5, 5),       -- NULL (equal)
    NULLIF(5, 4),       -- 5   (not equal)
    NULLIF(0, 0),       -- NULL
    100 / NULLIF(5, 5)  -- NULL (not a divide-by-zero, but still wrong)
```

**How to catch it:** Never pass the same expression to both arguments of NULLIF unless you want "return NULL when the expression equals itself" (which is almost never the intent). The correct zero-guard is `NULLIF(denominator, 0)`.

**Real-world trigger:** Copy-paste in a metric calculation. Ratio metric silently returns NULL for all rows. Dashboard shows blank cells. Engineer assumes data quality issue, spends two days investigating upstream sources.

---

### HAVING COUNT(*) > 0 Passes for All-NULL Aggregate Groups

**What it looks like:**
```sql
SELECT account_id, SUM(amount) AS total
FROM transactions
GROUP BY account_id
HAVING COUNT(*) > 0;
```

**What actually happens:** `COUNT(*) > 0` is always true for any group that was formed by GROUP BY — the group exists because it has at least one row. But if every `amount` in that group is NULL, `SUM(amount)` returns NULL, not 0. The HAVING clause does not prevent NULL sums from appearing in results.

**Why it's insidious:** Developer intended to filter "accounts with real transactions." They got "accounts with any rows, even if all values are NULL." The SUM of a group with only NULLs is NULL, not zero.

**Minimal repro:**
```sql
WITH t AS (
    SELECT acct, amount FROM (VALUES ('A',100),('B',NULL),('B',NULL)) s(acct,amount)
)
SELECT acct, SUM(amount)
FROM t
GROUP BY acct
HAVING COUNT(*) > 0;
-- Returns: A=100, B=NULL
-- B should be excluded if the intent was "accounts with measurable activity"
```

**How to catch it:**
```sql
-- Correct filter for "accounts with non-NULL transactions":
HAVING COUNT(amount) > 0
-- or:
HAVING SUM(amount) IS NOT NULL
```

**Real-world trigger:** Account activity report. Accounts with only cancelled (NULL-amount) transactions appear in the "active accounts" report with a NULL revenue figure. Monthly active user count is overstated.

---

### IS DISTINCT FROM vs = in Change Detection

**What it looks like:**
```sql
-- Change detection in SCD pipeline
WHERE old.email != new.email
```

**What actually happens:** If both `old.email` and `new.email` are NULL, `NULL != NULL` evaluates to UNKNOWN — the row is treated as "changed" when it isn't. If `old.email = 'a@b.com'` and `new.email IS NULL`, `'a@b.com' != NULL` is also UNKNOWN — the real change is silently missed.

**Why it's insidious:** `!=` works for all non-NULL comparisons. It only breaks at the NULL boundary, and NULL transitions are exactly the ones that represent real data quality events (an email being deleted, a field being reset).

**Minimal repro:**
```sql
WITH changes AS (
    SELECT * FROM (VALUES
        ('a@b.com', 'a@b.com'),   -- no change, = correctly identifies
        ('a@b.com', NULL),         -- real change, != misses it
        (NULL, NULL),              -- no change, != incorrectly fires
        (NULL, 'new@b.com')        -- real change, != misses it
    ) t(old_email, new_email)
)
SELECT
    old_email, new_email,
    old_email != new_email          AS wrong_change_detected,
    old_email IS DISTINCT FROM new_email AS correct_change_detected
FROM changes;
```

**How to catch it:** Replace all `!=` in change-detection WHERE clauses with `IS DISTINCT FROM`. Replace all `=` comparisons in merge keys with `IS NOT DISTINCT FROM` when NULLable join keys are possible.

**Real-world trigger:** Customer master SCD pipeline. Email-unsubscribe events (NULL email) never trigger a dimension update. Customers remain in "active" segment for years after opting out of communications.
