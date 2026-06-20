<!-- Part of sql-patterns: Funnel Analysis -->
<!-- Source: sql_patterns.md lines 5980–6072 -->

## 13. Funnel Analysis

### What it solves

Track what % of users complete each step of a multi-step process (signup → KYC → first deposit → first trade).

### Keywords to spot

> "funnel", "conversion", "drop-off", "how many users reached step X",
> "out of users who did A, how many did B",
> "conversion rate", "step completion",
> "abandonment rate", "where do users fall off", "completion rate",
> "progression", "step-by-step", "what % made it to", "pipeline",
> "how many completed all steps", "pass-through rate"

### Business Context

- **Fintech:** Onboarding funnel (signup → email verify → KYC → deposit → first trade); payment funnel (initiate → OTP → bank redirect → success/failure); loan application funnel (apply → document upload → credit check → approval)
- **E-commerce:** Purchase funnel (visit → product view → add to cart → checkout → purchase); identify highest drop-off step to prioritise UX improvement investment
- **SaaS:** Signup-to-activation funnel; feature adoption funnel (discover → try → activate → habitual use); paid conversion funnel (free trial → upgrade page → payment → active subscriber)
- **Mobile:** App install → permission grant → account create → first core action (aha moment); identify which permission requests cause the highest abandonment
- **Marketplace:** Seller onboarding funnel (register → list first product → first sale → 10th sale); buyer trust funnel (browse → save → first purchase → repeat purchase)
- **HR/Recruitment:** Hiring funnel (applied → screened → interviewed → offered → accepted); identify which interview stage has the highest drop-off rate by role

### Boilerplate — CASE WHEN + MAX approach (cleanest)

```sql
-- Each step is a flag; MAX() collapses per user
WITH user_funnel AS (
    SELECT
        user_id,
        MAX(CASE WHEN event_type = 'signup'        THEN 1 ELSE 0 END) AS did_signup,
        MAX(CASE WHEN event_type = 'kyc_complete'  THEN 1 ELSE 0 END) AS did_kyc,
        MAX(CASE WHEN event_type = 'first_deposit' THEN 1 ELSE 0 END) AS did_deposit,
        MAX(CASE WHEN event_type = 'first_trade'   THEN 1 ELSE 0 END) AS did_trade
    FROM user_events
    GROUP BY user_id
)

SELECT
    COUNT(*)                                          AS total_users,
    SUM(did_signup)                                   AS step1_signup,
    SUM(did_kyc)                                      AS step2_kyc,
    SUM(did_deposit)                                  AS step3_deposit,
    SUM(did_trade)                                    AS step4_trade,
    ROUND(SUM(did_kyc)      * 100.0 / SUM(did_signup),  2) AS signup_to_kyc_pct,
    ROUND(SUM(did_deposit)  * 100.0 / SUM(did_kyc),     2) AS kyc_to_deposit_pct,
    ROUND(SUM(did_trade)    * 100.0 / SUM(did_deposit),  2) AS deposit_to_trade_pct
FROM user_funnel;
```

### Boilerplate — Ordered funnel (step must happen AFTER previous step)

```sql
WITH ordered_events AS (
    SELECT user_id, event_type, event_at,
        ROW_NUMBER() OVER (PARTITION BY user_id, event_type ORDER BY event_at) AS rn
    FROM user_events
),

first_events AS (
    SELECT user_id, event_type, event_at
    FROM ordered_events
    WHERE rn = 1
),

pivoted AS (
    SELECT
        user_id,
        MAX(CASE WHEN event_type = 'signup'        THEN event_at END) AS signup_at,
        MAX(CASE WHEN event_type = 'kyc_complete'  THEN event_at END) AS kyc_at,
        MAX(CASE WHEN event_type = 'first_deposit' THEN event_at END) AS deposit_at,
        MAX(CASE WHEN event_type = 'first_trade'   THEN event_at END) AS trade_at
    FROM first_events
    GROUP BY user_id
)

SELECT
    COUNT(*)                                                          AS signups,
    COUNT(CASE WHEN kyc_at > signup_at THEN 1 END)                   AS completed_kyc,
    COUNT(CASE WHEN deposit_at > kyc_at THEN 1 END)                  AS made_deposit,
    COUNT(CASE WHEN trade_at > deposit_at THEN 1 END)                AS made_trade
FROM pivoted;
```

### Gotchas

- Simple funnel (CASE WHEN MAX) does not enforce ordering — a user who did KYC before signup would still count
- Ordered funnel enforces sequence by comparing timestamps
- Choose based on whether order matters for the business question

---


