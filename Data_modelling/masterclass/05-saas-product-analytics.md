<!-- data-modelling-patterns: SaaS / Product Analytics -->

# SaaS / Product Analytics

## When to Use This Design

SaaS analytics is event-first: the raw material is a stream of user actions. The business questions:

- What is the 30-day retention rate for users who signed up in January?
- What percentage of users complete the onboarding funnel within 7 days of signup?
- What features correlate with customers who expand from Starter to Growth tier?
- Which anonymous sessions from last month can we now match to identified users?

The fundamental modeling tension in SaaS analytics: the raw event stream is the source of truth, but answering funnel, session, and cohort questions from raw events requires expensive aggregations. The model must pre-compute enough to make standard questions fast without discarding the raw grain that enables ad-hoc analysis.

## The Schema

### Event Stream (Segment-Style)

Segment's track/identify/page model is the de facto standard. The warehouse representation:

```sql
-- Core event table (one row per user action)
CREATE TABLE events (
    event_id                VARCHAR(80)     NOT NULL,   -- UUID from client
    received_at             TIMESTAMP       NOT NULL,   -- when Segment/server received it
    sent_at                 TIMESTAMP,                  -- when client sent it (may differ)
    original_timestamp      TIMESTAMP,                  -- client-side timestamp
    event_name              VARCHAR(200)    NOT NULL,   -- 'Page Viewed','Button Clicked','Form Submitted'
    event_category          VARCHAR(100),
    anonymous_id            VARCHAR(80)     NOT NULL,   -- pre-login identifier (cookie/device)
    user_id                 VARCHAR(80),                -- NULL until identified
    session_id              VARCHAR(80),                -- pre-computed or NULL
    tenant_id               VARCHAR(50)     NOT NULL,   -- for multi-tenant SaaS
    -- Context
    page_url                VARCHAR(2000),
    page_title              VARCHAR(500),
    referrer_url            VARCHAR(2000),
    utm_source              VARCHAR(200),
    utm_medium              VARCHAR(200),
    utm_campaign            VARCHAR(200),
    -- Device context
    device_type             VARCHAR(20),               -- 'desktop','mobile','tablet'
    os_name                 VARCHAR(50),
    browser_name            VARCHAR(50),
    ip_address              VARCHAR(45),               -- IPv4 or IPv6
    -- Properties (event-specific, stored as JSON)
    properties              VARIANT,                   -- Snowflake VARIANT / BQ JSON
    -- Processing metadata
    dw_inserted_at          TIMESTAMP       NOT NULL,
    PRIMARY KEY (event_id)
)
PARTITION BY DATE(received_at)
CLUSTER BY (tenant_id, user_id, event_name);
```

**Why VARIANT/JSON for properties?**: Event-specific properties (a `Button Clicked` event has `button_label`, `button_position`; a `Form Submitted` event has `form_name`, `field_count`, `validation_errors`) vary per event type. Encoding these as top-level columns requires 200+ sparse columns on the events table. VARIANT avoids this at the cost of query-time parsing overhead. The mitigation is to create typed sub-tables for high-cardinality events:

```sql
-- Typed table for Page Viewed events (high volume, structured properties)
CREATE TABLE events_page_viewed (
    event_id                VARCHAR(80)     NOT NULL,
    received_at             TIMESTAMP       NOT NULL,
    user_id                 VARCHAR(80),
    anonymous_id            VARCHAR(80)     NOT NULL,
    tenant_id               VARCHAR(50)     NOT NULL,
    page_url                VARCHAR(2000),
    page_path               VARCHAR(500),
    page_title              VARCHAR(500),
    time_on_page_seconds    INT,
    scroll_depth_pct        INT,
    PRIMARY KEY (event_id)
)
PARTITION BY DATE(received_at)
CLUSTER BY (tenant_id, user_id);
```

### User Identity Resolution

The hardest problem in product analytics: a user starts as `anonymous_id = anon_abc123`, creates an account, and becomes `user_id = user_456`. Their pre-signup events are associated with the anonymous ID. Post-signup events have both IDs. How do you stitch the journey?

```sql
-- Identity stitching map
CREATE TABLE dim_identity_map (
    identity_map_key        BIGINT          NOT NULL,
    canonical_user_id       VARCHAR(80)     NOT NULL,   -- the "winning" user_id
    anonymous_id            VARCHAR(80)     NOT NULL,
    device_id               VARCHAR(80),
    email_address           VARCHAR(200),
    first_seen_at           TIMESTAMP       NOT NULL,
    identified_at           TIMESTAMP,                  -- when anon -> identified linkage happened
    is_active               BOOLEAN         NOT NULL    DEFAULT TRUE,
    tenant_id               VARCHAR(50)     NOT NULL,
    PRIMARY KEY (identity_map_key)
)
CLUSTER BY (tenant_id, canonical_user_id, anonymous_id);
```

The resolution query pattern — joining events to the identity map to get a canonical user journey — is expensive because it requires non-equi-join logic for pre-identification events. The practical solution is to materialize a `events_resolved` table or view that has `canonical_user_id` populated for all events, including retroactively applying the identity to pre-signup events. This materialization runs on a schedule (nightly or hourly) and is never strictly real-time.

### Session Modeling

Sessions are a computed concept. The two approaches:

**Pre-computed sessions table** (recommended for volume > 100M events/day):

```sql
CREATE TABLE dim_session (
    session_id              VARCHAR(80)     NOT NULL,
    user_id                 VARCHAR(80),
    anonymous_id            VARCHAR(80)     NOT NULL,
    tenant_id               VARCHAR(50)     NOT NULL,
    session_start_at        TIMESTAMP       NOT NULL,
    session_end_at          TIMESTAMP,
    session_duration_seconds INT,
    page_view_count         INT             NOT NULL    DEFAULT 0,
    event_count             INT             NOT NULL    DEFAULT 0,
    entry_page_url          VARCHAR(2000),
    exit_page_url           VARCHAR(2000),
    utm_source              VARCHAR(200),
    utm_medium              VARCHAR(200),
    utm_campaign            VARCHAR(200),
    device_type             VARCHAR(20),
    is_bounce               BOOLEAN         NOT NULL    DEFAULT FALSE,  -- single page view
    PRIMARY KEY (session_id)
)
PARTITION BY DATE(session_start_at)
CLUSTER BY (tenant_id, user_id);
```

Session boundaries are defined by a configurable inactivity timeout (typically 30 minutes). The sessionization logic runs as a window function in the ELT pipeline:

```sql
-- Sessionization via window function in dbt/ELT
WITH event_gaps AS (
    SELECT
        event_id,
        anonymous_id,
        tenant_id,
        received_at,
        LAG(received_at) OVER (
            PARTITION BY anonymous_id, tenant_id
            ORDER BY received_at
        ) AS prior_event_at,
        DATEDIFF('minute',
            LAG(received_at) OVER (
                PARTITION BY anonymous_id, tenant_id
                ORDER BY received_at
            ),
            received_at
        ) AS minutes_since_last_event
    FROM events
),
session_starts AS (
    SELECT
        *,
        CASE
            WHEN prior_event_at IS NULL THEN 1         -- first event = new session
            WHEN minutes_since_last_event > 30 THEN 1  -- 30-min gap = new session
            ELSE 0
        END AS is_session_start
    FROM event_gaps
),
session_ids AS (
    SELECT
        *,
        SUM(is_session_start) OVER (
            PARTITION BY anonymous_id, tenant_id
            ORDER BY received_at
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) AS session_sequence_num
    FROM session_starts
)
SELECT
    anonymous_id || '-' || tenant_id || '-' || session_sequence_num AS session_id,
    *
FROM session_ids;
```

**Query-time sessionization**: Works for ad-hoc exploration but is catastrophically slow at 100M+ events/day. The window function scan must process the entire event table. Pre-computation is the only production-viable option.

### Multi-Tenant Isolation Strategies

This is an architectural decision with profound data modeling implications.

| Strategy | Schema Design | Query Isolation | Data Volume | Operational Cost |
|----------|--------------|----------------|-------------|-----------------|
| Row-level (shared tables) | `tenant_id` column on every table | Row Access Policy / WHERE clause | Efficient at scale | Low |
| Schema-per-tenant | Each tenant gets own schema | Schema-level | Moderate per tenant | Medium |
| Database-per-tenant | Each tenant gets own database | Database-level | Max isolation | Very High |

**Row-level** is correct for B2C SaaS with hundreds or thousands of tenants generating relatively small individual volumes. The `tenant_id` column must be on every table and must be the first clustering column. Without it as a cluster key, queries filter by row access policy but still scan the entire partition.

**Schema-per-tenant** is appropriate for B2B enterprise SaaS with 10–100 large customers who have strict data isolation contractual requirements but volume is manageable per schema.

**Database-per-tenant** is appropriate when tenants have dramatically different schemas (extensible platforms) or regulatory requirements mandating physical separation (government SaaS, healthcare).

### Funnel Modeling

Funnel analysis is the most common SaaS product analytics query. The naive approach is a correlated subquery for each funnel step — which becomes N full table scans for an N-step funnel.

The correct pattern is a single-pass pivoted model:

```sql
-- Funnel completion fact (pre-computed, grain: one row per user per funnel)
CREATE TABLE fact_funnel_completion (
    funnel_completion_key   BIGINT          NOT NULL,
    user_id                 VARCHAR(80),
    anonymous_id            VARCHAR(80)     NOT NULL,
    tenant_id               VARCHAR(50)     NOT NULL,
    funnel_name             VARCHAR(100)    NOT NULL,  -- 'ONBOARDING','CHECKOUT','UPGRADE'
    cohort_date             DATE            NOT NULL,  -- date of funnel entry (step 1)
    step_1_completed_at     TIMESTAMP       NOT NULL,
    step_2_completed_at     TIMESTAMP,
    step_3_completed_at     TIMESTAMP,
    step_4_completed_at     TIMESTAMP,
    step_5_completed_at     TIMESTAMP,
    max_step_reached        INT             NOT NULL   DEFAULT 1,
    converted               BOOLEAN         NOT NULL   DEFAULT FALSE,  -- reached final step
    days_to_convert         INT,
    PRIMARY KEY (funnel_completion_key)
)
PARTITION BY (cohort_date)
CLUSTER BY (tenant_id, funnel_name, converted);
```

With this model, funnel drop-off rates are simple aggregations:

```sql
SELECT
    COUNT(*) AS entered_funnel,
    COUNT(step_2_completed_at) AS reached_step_2,
    COUNT(step_3_completed_at) AS reached_step_3,
    COUNT(step_4_completed_at) AS reached_step_4,
    COUNT(step_5_completed_at) AS converted,
    COUNT(step_5_completed_at)::FLOAT / COUNT(*) AS conversion_rate
FROM fact_funnel_completion
WHERE tenant_id = 'tenant_abc'
  AND funnel_name = 'ONBOARDING'
  AND cohort_date BETWEEN '2024-01-01' AND '2024-01-31';
```

This query runs in milliseconds regardless of event volume because it scans the pre-aggregated funnel fact, not the raw events.

## The Hard Problems

**Event Volume and Sessionization at Scale**: At 500M events/day (realistic for a mid-size SaaS company), sessionizing the full event stream nightly is a 30–60 minute job. The incremental sessionization challenge: sessions can span midnight boundaries, and new events arriving for an in-progress session must update the session's end time and event count without a full recomputation. The solution is a **two-phase approach**: (1) close sessions where the last event was > 30 minutes ago; (2) accumulate active sessions in a staging table updated throughout the day.

**User Merges**: When two user accounts are merged (duplicate accounts), all historical events associated with the merged account must be re-attributed to the canonical account. This retroactively invalidates any pre-computed funnel and session models that used the old user ID. The identity map table handles real-time queries, but pre-computed aggregates require a recomputation trigger on any identity merge event.

## Scale Mechanics

| Event Volume | Sessionization | Funnel | Identity Resolution |
|-------------|---------------|--------|-------------------|
| < 10M/day | Query-time acceptable | Query-time acceptable | Nightly full |
| 10M–100M/day | Nightly incremental | Pre-computed fact | Nightly incremental |
| 100M–1B/day | Real-time stream (Flink/Spark Streaming) | Pre-computed + streaming | Event-time streaming |
| > 1B/day | Purpose-built event store (Kafka + ClickHouse) | ClickHouse materialized views | Streaming identity graph |
