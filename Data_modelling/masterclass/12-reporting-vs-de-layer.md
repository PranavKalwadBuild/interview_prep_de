## 12. Business Logic: DE Layer vs Reporting Layer

> The interview question is never "can the BI tool compute this?" Both layers can technically compute almost anything. The real question: **who owns the answer, who else needs it, what breaks if it's wrong, and how often does the definition change?**

---

### The Core Mental Model

Every piece of business logic lives on a spectrum:

```
DE Layer (dbt / Spark / Warehouse)          BI Layer (Tableau / Power BI / Looker DAX)
─────────────────────────────────────────────────────────────────────────────────────────
Shared, governed, auditable, versioned  ←→  Local, flexible, exploratory, session-specific
Runs once at load time                  ←→  Runs at every render / interaction
Tool-agnostic (SQL)                     ←→  Tool-specific (DAX, LookML, Tableau calc fields)
Tested, lineage tracked                 ←→  Hidden inside .pbix or .twb binary files
```

**Neither layer is universally correct.** The failure mode is applying the wrong layer to a given problem — not the layer itself.

---

### Decision Criteria

**Push logic DOWN into DE layer when:**

| Signal | Why it forces DE layer |
|--------|----------------------|
| More than one team or tool needs the same metric | Logic in one BI tool is invisible to all others. Two reimplementations → two definitions → executive confusion |
| Requires joining 3+ tables across domains | Live multi-source joins in a BI tool collapse at scale — Tableau doing a 500M-row join produces Cartesian product risk and query timeouts |
| Requires point-in-time historical accuracy | SCD Type 2 history doesn't exist in a BI tool's semantic model — it reflects current state unless the warehouse provides the history |
| Deduplication required | A BI calculated field operates on rows already in the dataset — if rows are duplicated at the source, the BI tool has no way to know which row is canonical |
| Compliance / regulatory requirement | A DAX measure computing revenue has no audit trail. A dbt model has git history, lineage, test assertions, and a PR review |
| Pre-aggregation over billions of rows | `COUNT(DISTINCT user_id)` over 50B events is not a live BI query — it is a nightly pipeline job |
| ML feature input | Train/test split enforcement and temporal leakage prevention cannot be expressed in a calculated field |
| Shared definition used by multiple teams | One dbt PR changes one file and the change propagates everywhere. One Tableau calculated field change requires opening 50 workbooks |

**Push logic UP into BI layer when:**

| Signal | Why BI layer is correct |
|--------|------------------------|
| Anchored to today's date (YTD, MTD, rolling-N from NOW) | Pre-materializing these would require a daily pipeline run to produce a number that expires in 24 hours. DAX `TOTALYTD` and Tableau `TODAY()` are purpose-built for this |
| User-controlled scenario / what-if | Power BI What-If Parameters with `GENERATESERIES + SELECTEDVALUE` create real-time sliders. Materializing scenarios in the warehouse requires a pipeline run per scenario |
| Exploratory / single-team / not yet stable | If a metric hasn't survived one quarter and isn't shared, a dbt model is premature engineering. Promote it to DE layer when it earns its place |
| Audience-specific display formatting | Currency symbols, date locales, unit conversions (km vs. miles) are presentation concerns. Warehouse stores canonical values; BI applies the display |
| Visualization-specific aggregation | A KPI card needs "total." A bar chart needs "by region." The warehouse provides the fact grain; BI aggregates to whatever the chart requires |

---

### Case 1: Must Be in DE Layer — Multi-Source Customer Health Score

**Context**: A SaaS company computes customer health score from four source systems: Segment (product engagement events), Zendesk (support ticket volume and severity), Salesforce (contract value and renewal date), Stripe (billing payment history).

**Wrong approach** — logic in Tableau:
- Each dashboard load re-executes a four-way join across systems
- If two analysts define the join conditions slightly differently (different date filters, different NULL handling for missing Zendesk accounts), two dashboards show different health scores for the same customer
- Tableau's Live Connection has no join-key safety net — a Cartesian product on a 500M-event engagement table silently inflates the score

**Correct approach** — dbt Gold model:
```sql
-- models/marts/dim_customer_health.sql
WITH engagement AS (
    SELECT
        account_id,
        COUNT(DISTINCT user_id) AS active_users_l30d,
        COUNT(CASE WHEN event_name = 'core_action' THEN 1 END) AS core_actions_l30d
    FROM {{ ref('fct_events') }}
    WHERE event_date >= CURRENT_DATE - 30
    GROUP BY account_id
),
support AS (
    SELECT
        account_id,
        COUNT(*) AS open_ticket_count,
        MAX(CASE WHEN severity = 'P1' THEN 1 ELSE 0 END) AS has_open_p1
    FROM {{ ref('fct_support_tickets') }}
    WHERE status = 'open'
    GROUP BY account_id
),
billing AS (
    SELECT
        account_id,
        MAX(days_past_due) AS max_days_past_due,
        SUM(CASE WHEN payment_status = 'failed' THEN 1 ELSE 0 END) AS failed_payments_l90d
    FROM {{ ref('fct_payments') }}
    WHERE payment_date >= CURRENT_DATE - 90
    GROUP BY account_id
)
SELECT
    a.account_id,
    a.contract_value,
    a.renewal_date,
    COALESCE(e.active_users_l30d, 0) AS active_users_l30d,
    COALESCE(e.core_actions_l30d, 0) AS core_actions_l30d,
    COALESCE(s.open_ticket_count, 0) AS open_ticket_count,
    COALESCE(s.has_open_p1, 0) AS has_open_p1,
    COALESCE(b.max_days_past_due, 0) AS max_days_past_due,
    -- Health score logic: one governed definition, consumed by product, CSM, and ML teams
    CASE
        WHEN COALESCE(b.max_days_past_due, 0) > 30 OR COALESCE(s.has_open_p1, 0) = 1 THEN 'RED'
        WHEN COALESCE(e.active_users_l30d, 0) = 0 THEN 'RED'
        WHEN COALESCE(e.core_actions_l30d, 0) < 10 OR COALESCE(s.open_ticket_count, 0) > 3 THEN 'YELLOW'
        ELSE 'GREEN'
    END AS health_status
FROM {{ ref('dim_accounts') }} a
LEFT JOIN engagement e ON a.account_id = e.account_id
LEFT JOIN support s ON a.account_id = s.account_id
LEFT JOIN billing b ON a.account_id = b.account_id
```

The BI tool reads one row per customer from `dim_customer_health`. The four-way join runs once per pipeline cycle. Every downstream consumer — Tableau dashboards, Power BI, the ML churn model, the CSM platform — reads the same number.

**How this breaks without DE layer**: Marketing shows health = GREEN for Account 7890 (their Zendesk query had a date filter). CS shows health = RED for the same account (their query included P2 tickets). The CSM spends 30 minutes on a call apologizing for a non-existent problem. The customer loses confidence. This is documented as a real organizational failure pattern at companies with ungoverned metric definitions.

---

### Case 2: Must Be in DE Layer — Sessionization from Raw Clickstream

**Context**: 200M events/day. Product manager wants funnel conversion rate: `checkout_start → payment_complete`, restricted to sessions where the user entered via a paid marketing campaign.

**Why BI layer fails**:
- Session assignment requires `LAG(event_timestamp) OVER (PARTITION BY anonymous_id ORDER BY event_timestamp)` and a 30-minute inactivity threshold. Tableau's `WINDOW_` functions operate post-aggregation — they cannot be used to assign session IDs to individual rows.
- Power BI's `EARLIER()` function for row context is architecturally not capable of the sequential event-gap logic required for sessionization.
- Even if a BI tool could approximate it, running this over 200M rows per query would take minutes and saturate the warehouse's compute allocation.

**Correct approach** — Spark/dbt ELT:
```sql
-- models/intermediate/int_sessions.sql
WITH event_gaps AS (
    SELECT
        event_id, anonymous_id, tenant_id,
        event_name, received_at, utm_source,
        LAG(received_at) OVER (
            PARTITION BY anonymous_id, tenant_id
            ORDER BY received_at
        ) AS prior_event_at
    FROM {{ ref('stg_events') }}
),
session_starts AS (
    SELECT *,
        CASE
            WHEN prior_event_at IS NULL THEN 1
            WHEN DATEDIFF('minute', prior_event_at, received_at) > 30 THEN 1
            ELSE 0
        END AS is_session_start
    FROM event_gaps
),
sessions AS (
    SELECT *,
        SUM(is_session_start) OVER (
            PARTITION BY anonymous_id, tenant_id
            ORDER BY received_at
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) AS session_seq
    FROM session_starts
)
SELECT
    anonymous_id || '-' || tenant_id || '-' || CAST(session_seq AS VARCHAR) AS session_id,
    anonymous_id, tenant_id,
    MIN(received_at) AS session_start_at,
    MAX(received_at) AS session_end_at,
    -- Attribute the session to the first UTM source seen in the session
    MIN(CASE WHEN utm_source IS NOT NULL THEN utm_source END) AS utm_source,
    MAX(CASE WHEN event_name = 'checkout_start' THEN 1 ELSE 0 END) AS reached_checkout,
    MAX(CASE WHEN event_name = 'payment_complete' THEN 1 ELSE 0 END) AS converted
FROM sessions
GROUP BY anonymous_id, tenant_id, session_seq
```

The BI tool then runs:
```sql
SELECT
    utm_source,
    COUNT(*) AS sessions,
    SUM(converted) AS conversions,
    SUM(converted)::FLOAT / COUNT(*) AS conversion_rate
FROM dim_session
WHERE session_start_at::DATE >= CURRENT_DATE - 30
GROUP BY utm_source
```

**Critically**: the 30-minute session timeout definition is now in one place. When the product team debates whether it should be 20 or 30 minutes, there is one PR to change and one pipeline run to validate — not 15 BI workbooks to audit.

---

### Case 3: Must Be in DE Layer — SCD Type 2 and Point-in-Time Joins

**Context**: Sales commission calculation. Salespeople move between regions. Commission rate varies by region. The question: "What commission does salesperson Alice owe for her January sales?"

Alice was in the East region in January (10% commission) but moved to the West region in February (8% commission). If `dim_salesperson` is loaded with Type 1 (current values), Alice's January sales appear in West at 8% — underpaying her by 2 points on every January order.

**BI tool cannot fix this** because the BI tool only sees current region. It has no access to the January region unless the warehouse provides that history.

**Correct approach** — dbt snapshot:
```yaml
# snapshots/snap_salesperson.yml
snapshots:
  - name: snap_salesperson
    config:
      target_schema: snapshots
      unique_key: salesperson_id
      strategy: check
      check_cols: ['region', 'commission_tier', 'manager_id']
      # dbt generates dbt_valid_from and dbt_valid_to automatically
```

Then in the commission fact model:
```sql
-- models/marts/fct_sales_commission.sql
SELECT
    o.order_id,
    o.order_date,
    o.revenue,
    sp.salesperson_id,
    sp.region,              -- region AS OF order_date (historical, correct)
    sp.commission_tier,
    cr.commission_rate,
    o.revenue * cr.commission_rate AS commission_owed
FROM {{ ref('fct_orders') }} o
JOIN {{ ref('snap_salesperson') }} sp
    ON o.salesperson_id = sp.salesperson_id
    AND o.order_date >= sp.dbt_valid_from
    AND o.order_date < COALESCE(sp.dbt_valid_to, '9999-12-31')
JOIN {{ ref('dim_commission_rates') }} cr
    ON sp.region = cr.region
    AND sp.commission_tier = cr.tier
```

The BI tool reads `fct_sales_commission` with `commission_owed` pre-computed at the correct historical rate. No BI-layer logic needed.

**Scale implication of getting this wrong**: At $500M revenue with 200 salespeople, a 2% commission miscalculation across one quarter is $2.5M in incorrect payments. The error is silent — summaries look correct because the numbers sum to total revenue. Only per-salesperson comparison against payroll records exposes it.

---

### Case 4: Must Be in DE Layer — GDPR/SOX Compliance Logic

**GDPR data masking — why BI layer is structurally wrong**:

A Tableau calculated field `IF [role] = "analyst" THEN "REDACTED" ELSE [email] END` does **not** mask data. The Tableau query still fetches the unmasked email from the warehouse and then applies a display filter in the visualization layer. Anyone with warehouse credentials — or who intercepts the JDBC connection — sees the plaintext PII.

**Correct approach** — Snowflake Dynamic Data Masking:
```sql
CREATE OR REPLACE MASKING POLICY email_mask AS (val STRING) RETURNS STRING ->
    CASE
        WHEN CURRENT_ROLE() IN ('DATA_ENGINEER', 'COMPLIANCE_ADMIN') THEN val
        WHEN CURRENT_ROLE() = 'ANALYST' THEN SHA2(val)      -- pseudonymized, not plaintext
        ELSE '***REDACTED***'
    END;

ALTER TABLE dim_customer MODIFY COLUMN email_address
    SET MASKING POLICY email_mask;
```

Now the masking is enforced at the storage layer. No BI tool, no Python notebook, no SQL client sees plaintext PII unless the role explicitly permits it. The Tableau calculated field approach is a compliance liability, not a solution.

**SOX revenue recognition — the audit trail argument**:

Under ASC 606, multi-element software arrangements require allocating transaction price across performance obligations (license, support, professional services) using relative standalone selling prices. This allocation involves:
1. Identifying performance obligations per contract
2. Estimating standalone selling price for each obligation
3. Allocating total contract value proportionally
4. Recognizing each obligation's revenue when (or as) the obligation is satisfied

A DAX measure doing this allocation has no git commit history, no test coverage, no documented lineage from the source contract record to the recognized revenue figure. An auditor asking "show me how you computed Q3 license revenue for contract #12345" cannot be answered from a `.pbix` file.

A dbt model doing the same allocation:
- Has a git commit per change with author, timestamp, and PR description
- Has `dbt test` assertions: total allocated revenue = contract value (within rounding tolerance)
- Has documented lineage: `source contract` → `stg_contracts` → `int_performance_obligations` → `fct_recognized_revenue`
- Has a deterministic run log: re-running the model on the same data produces byte-identical output

The SOX auditor signs off on the dbt lineage DAG. There is no equivalent artifact from a BI layer calculation.

---

### Case 5: Must Be in DE Layer — Shared Metric: "Active User" Definition

**The fragmentation failure**: At a growth-stage SaaS company, five teams each define "Monthly Active User" in their own BI workbook:

| Team | Definition | Tool |
|------|-----------|------|
| Product | Triggered `core_action` event in last 28 days, excluding internal users | Tableau calculated field |
| Marketing | Logged in at least once in the calendar month | Looker measure |
| Growth | Completed onboarding AND triggered any event in last 30 days | Power BI DAX measure |
| Finance | Any account with at least one active seat on any day in the month | Spreadsheet formula |
| Customer Success | Has an assigned CSM AND has been active in the last 14 days | Salesforce report |

Each definition is defensible in isolation. Combined, they generate five different MAU numbers presented to the CEO in the same weekly review. The CEO cannot make a resource allocation decision because the growth team shows 12% MAU growth while the marketing team shows 3% growth — for the same month.

**Correct approach** — one dbt model, one PR to change the definition:
```sql
-- models/marts/dim_user_activity.sql
-- Governed definition: active = triggered a 'core_action' event in last 28 days,
-- is not an internal user (email not @company.com),
-- and account is not on a free trial.
SELECT
    u.user_id,
    u.account_id,
    u.email,
    u.account_type,
    MAX(e.event_date) AS last_active_date,
    CASE
        WHEN MAX(e.event_date) >= CURRENT_DATE - 27
             AND u.email NOT LIKE '%@ourcompany.com'
             AND u.account_type != 'TRIAL'
        THEN TRUE
        ELSE FALSE
    END AS is_active_user
FROM {{ ref('dim_users') }} u
LEFT JOIN {{ ref('fct_events') }} e
    ON u.user_id = e.user_id
    AND e.event_name = 'core_action'
    AND e.event_date >= CURRENT_DATE - 27
GROUP BY u.user_id, u.account_id, u.email, u.account_type
```

When the growth team argues that trial users should be included in MAU for their funnel analysis, they open a PR. The PR triggers a discussion about whether the official company definition should change — not whether one team's dashboard should show a different number. When the PR merges, all five teams' dashboards update simultaneously on the next refresh. No team is maintaining a divergent definition in a BI workbook.

---

### Case 6: Belongs in BI Layer — Relative Time Calculations

**Why YTD belongs in DAX/Tableau, not the warehouse**:

If you materialize "YTD revenue as of today" in a dbt model, you must run the pipeline every day to produce a number that expires at midnight. Any report opened before the pipeline finishes shows yesterday's YTD. The materialized YTD for a date in 2023 is now permanently frozen — if a correction is applied to a January transaction in November, the frozen YTD is wrong but there is no automatic mechanism to re-trigger its recalculation.

DAX's time-intelligence pattern:
```dax
YTD Revenue =
CALCULATE(
    SUM(fct_orders[revenue]),
    DATESYTD(dim_date[date])
)
```

This measure recalculates at render time using the current filter context. It is always correct relative to today because it executes at query time, not at load time. The warehouse provides the historical fact grain; the BI tool applies the temporal window.

**The boundary**: Rolling historical windows ("rolling 7-day MAU as of each date, for the last 2 years") belong in the DE layer. These require computing a correct historical series — the definition of "last 7 days" changes at each historical point, and materializing the series once is far cheaper than computing it live for every chart render. YTD/MTD anchored to today belong in the BI layer. Historical rolling windows belong in the DE layer.

---

### Case 7: The Genuinely Grey Area — Conversion Rate

**Symptom of the problem**: `conversion_rate = orders / sessions`. Two numbers divided. Looks simple. You put it in a Tableau calculated field in 15 minutes.

**Why it belongs in the DE layer despite its apparent simplicity**:

Within one quarter, different teams define it differently without realizing it:

| Question | Implicit decision | Each team answers differently |
|----------|------------------|-------------------------------|
| Which sessions? | All sessions, or only paid-acquisition sessions? | Marketing: paid only. Product: all. |
| Which orders? | Completed only, or including pending? | Finance: completed only. Growth: all. |
| Date attribution | Session date, or order date? | Marketing: session date. Finance: order date. |
| Bot filtering | Exclude bot traffic? | Engineering: yes. Everyone else: forgot. |
| Mobile vs desktop | Separate rates or blended? | Product: blended. Channel analytics: separate. |

When the CMO sees 3.2% conversion in the marketing dashboard and the CPO sees 2.8% in the product dashboard, the 0.4-point difference is not analytical noise. It is the aggregated effect of five implicit decisions made independently. At $50M ARR, it is the difference between celebrating a campaign as successful and investigating a product funnel issue.

**The rule**: the arithmetic complexity is irrelevant. The governing question is: **does the metric have edge cases that require a decision, and is more than one team depending on the answer?** If yes, it belongs in a dbt model with those decisions explicitly encoded and documented:

```sql
-- models/marts/fct_conversion.sql
-- Definition: sessions → completed orders. Excludes bots. Attributes to session date.
-- Change history: 2024-03-01 — excluded trial accounts per Finance request (PR #412)
SELECT
    DATE_TRUNC('day', s.session_start_at) AS session_date,
    s.channel,
    s.device_type,
    COUNT(DISTINCT s.session_id) AS sessions,
    COUNT(DISTINCT o.order_id) AS completed_orders,
    COUNT(DISTINCT o.order_id)::FLOAT / NULLIF(COUNT(DISTINCT s.session_id), 0) AS conversion_rate
FROM {{ ref('dim_session') }} s
LEFT JOIN {{ ref('fct_orders') }} o
    ON s.session_id = o.attributed_session_id
    AND o.order_status = 'COMPLETED'
WHERE s.is_bot = FALSE
  AND s.account_type != 'TRIAL'   -- excluded per Finance (PR #412)
GROUP BY 1, 2, 3
```

The PR comment on line 3 is the audit trail. The BI tool reads `fct_conversion` and aggregates to whatever granularity the chart needs. The definition is in one place.

---

### Case 8: Belongs in BI Layer — What-If Scenario Analysis

**Context**: A CFO wants to model three revenue scenarios for the board: base case, bull case (15% above base), bear case (20% below base). The "base" is the historical actuals from the warehouse.

**Why this belongs in Power BI, not the warehouse**:
- Scenarios are session-specific, user-driven parameters. They are not facts.
- Materializing three scenario versions in the warehouse requires three pipeline runs per scenario revision. The CFO will revise the assumptions six times before the board meeting.
- The scenarios are not the company's official record — they are exploratory projections used internally.

```dax
// Power BI What-If Parameter
GrowthMultiplier = GENERATESERIES(-0.30, 0.30, 0.05)
GrowthValue = SELECTEDVALUE(GrowthMultiplier[GrowthMultiplier], 0)

// Measure using the slider
Projected Revenue =
CALCULATE(
    SUM(fct_orders[revenue]),
    DATESYTD(dim_date[date])
) * (1 + [GrowthValue])
```

The slider moves from -30% to +30%. All calculations update in real time. The warehouse never stores any projected values — it holds only historical actuals. The board presentation can show multiple scenarios without triggering a single pipeline run.

---

### Decision Matrix

| Logic Type | DE Layer | BI Layer | Why |
|-----------|----------|----------|-----|
| Multi-source join (CRM + billing + events) | ✓ | | Live join in BI tool collapses at scale, produces inconsistent results across workbooks |
| Sessionization from raw events | ✓ | | Requires sequential window functions over billions of rows; BI tools cannot express this |
| SCD Type 2 / point-in-time attribute | ✓ | | BI tools reflect current state; history must come from the warehouse |
| GDPR/PII masking | ✓ | | BI-layer masking is a display filter; data is still unmasked in the warehouse |
| SOX-auditable revenue recognition | ✓ | | DAX/calculated fields have no audit trail, no lineage, no version history |
| ML feature engineering | ✓ | | Train/test split enforcement, temporal leakage prevention impossible in BI layer |
| Shared metric definition (MAU, conversion rate) | ✓ | | More than one team → each reimplements differently → metric divergence |
| Pre-aggregation over billions of rows | ✓ | | `COUNT(DISTINCT user_id)` over 50B rows is not a live BI query |
| Event stream deduplication | ✓ | | BI tool has no way to identify which duplicate is canonical |
| YTD / MTD / rolling-N from TODAY() | | ✓ | Expires every day; DAX/Tableau time-intelligence functions are purpose-built |
| What-if / scenario modeling | | ✓ | Session-specific, user-driven; pipeline per scenario is operationally absurd |
| Exploratory, single-team, unstable metric | | ✓ | Promote to DE layer when it earns its place after one quarter of stability |
| Audience-specific display formatting | | ✓ | Presentation layer concern; canonical values stored in warehouse |
| Conditional formatting / color thresholds | | ✓ | Purely visual; has no place in a fact table |

---

### The Medallion Architecture Formalization

The Databricks Bronze/Silver/Gold model makes the boundary explicit:

```
Bronze (Raw)   → Exact copy of source. No logic. Ingestion metadata only.
Silver (Clean) → Structural cleanup: dedup, type cast, null handling, schema normalization.
                 No domain business logic.
Gold (Mart)    → ALL business logic lives here: joins, metric definitions, KPIs,
                 compliance transformations, shared definitions.
                 BI tools connect ONLY to Gold.
```

**The diagnostic test**: If you find a SQL join inside a BI tool's data model, that join belongs in Gold. If you find a business definition inside a BI calculated field that is used by more than one consumer, that definition belongs in Gold.

The dbt Semantic Layer (MetricFlow) extends this further: metrics are defined as YAML alongside models and exposed via a query API consumed by Tableau, Power BI, Looker, Python notebooks, and AI agents from a single authoritative definition. When `conversion_rate` is a MetricFlow metric, it is guaranteed to return the same number regardless of which tool queries it. The organizational consequence: the executive review never again devolves into a debate about whose number is right.

---

### Real-World Failure Modes Summary

| Getting it wrong | What breaks | How badly |
|-----------------|-------------|-----------|
| Sessionization in BI tool | 15-minute query renders; wrong session counts when session definition differs by analyst | Data trust collapse within 2 quarters |
| SCD Type 2 skipped; commission calculation in warehouse uses Type 1 | Historical commission reports show wrong territories | Legal liability for underpaid commissions |
| GDPR masking in BI calculated field | Regulation violation; PII still readable via direct warehouse query | Regulatory fine + reputational damage |
| "Simple" conversion rate defined in 50 Tableau workbooks | 0.4-point discrepancy in executive review; 30% of analytics time spent on reconciliation | Metric credibility lost; gut instinct overrides dashboards |
| YTD/MTD materialized in warehouse | Number expires every 24 hours; stale if pipeline delayed; correction to historical data doesn't propagate | Stale KPI cards; stakeholder distrust |
| Customer health score joined in BI tool | Different join conditions in different dashboards produce different scores for same customer | CSM team acts on wrong signals; customer trust damaged |
