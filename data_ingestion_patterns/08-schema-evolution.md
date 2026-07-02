<!-- data-ingestion-patterns: Schema Evolution in Event-Driven Pipelines -->

# Schema Evolution in Event-Driven Pipelines

> **Domain:** Data Engineering — Event Bus Ingestion
> **Difficulty:** Senior / Staff
> **Category:** Schema Management · Pipeline Resilience · Historical Queryability

---

## Problem Statement

In a microservices architecture with 50+ independent producer services, each team owns its domain events and evolves them on its own release cadence. A team adding a new field to an `OrderPlaced` event has no coordination obligation to the downstream data warehouse pipeline — and in practice, coordination rarely happens. The consumer pipeline must therefore tolerate a stream of structurally heterogeneous messages: the same logical event type may arrive as schema version 1, version 7, and version 12 within the same processing window. Without a robust schema evolution strategy, the pipeline either breaks silently (writing nulls into columns that should have values), breaks noisily (deserialization errors that stall consumers), or degrades over time (manual schema patches applied during incidents).

The delayed-processing constraint makes this significantly harder. A message emitted at noon may not be processed until 10 PM because of backpressure, consumer restarts, or replay from a dead letter queue. The schema the consumer has cached at processing time may not match the schema that was registered when the message was originally produced. Naively refreshing schema caches on startup is insufficient; the consumer must look up the exact schema version that was current at emission time, not the current version.

Full historical queryability compounds the problem further. The data warehouse must answer the question "what did this event look like in Q1 2023?" with the same fidelity as "what does this event look like today." That means the physical storage layer must preserve the original shape of every event version, not just the current schema's projection of it. Most teams discover this constraint only when a data audit request arrives or a backward-incompatible change silently dropped a column that turns out to have been critical for a compliance report — filed six months later.

---

## Clarifying Questions

### Schema Contract and Governance

1. Is there a centralized schema registry today, or are schemas implicit in the producer codebases? Who owns schema registration — each producing team, a central platform team, or both?
2. What serialization format do producers currently use — binary (Avro, Protobuf), text (JSON), or mixed? Is there appetite to migrate formats, or must we work within the existing format?
3. What compatibility mode is enforced at registration time? Is there a CI gate that rejects breaking schema changes before a producer deploys, or can a producer silently break the contract in production?

### Consumer SLA and Processing Model

4. What is the maximum acceptable delay between an event being emitted and it being queryable in the data warehouse? Is there a business SLA (e.g., "events must be queryable within 4 hours of emission") or is best-effort acceptable?
5. Do consumers process events in strict arrival order, or can events be processed out of order? What is the bounded reordering window?
6. If a consumer encounters a deserialization failure, what is the expected behavior — stop the pipeline, skip and log, route to a dead letter queue, or replay after a delay?

### Historical Queryability Requirements

7. When a column is renamed from `customer_id` to `account_id`, what is the expected behavior for historical records that used the old name — are they exposed under the old name, the new name, or both via a view layer?
8. Is full event reconstruction (exact byte-for-byte replay of the original message) required for any compliance or audit use case, or is a structured representation of the data sufficient?
9. How far back must historical events remain queryable with consistent semantics? Are there regulatory retention requirements (e.g., 3 years, 7 years)?

### Operational and Organizational

10. How many distinct event types are in scope on day one, and what is the projected growth rate? Is there a schema proliferation risk (hundreds of event types with small variations)?
11. What is the rollback story if a deployed schema change causes downstream failures? Can producers roll back a schema version, or is the registry append-only?
12. Is there a sunset or deprecation process for old schema versions? Who is responsible for notifying consumers when a version is being retired, and what is the minimum notice window?

---

## Hard Constraints

- **No breaking changes reach consumers without a compatibility gate.** Every schema registration must be validated against the configured compatibility mode before the producing service can deploy.
- **Schema version must be embedded in every message envelope.** Consumers must be able to determine the exact schema version without inspecting the payload content.
- **Raw bytes must be preserved at landing.** The ingestion layer writes the original message payload to immutable object storage before any deserialization or transformation occurs. This is the ultimate recovery path.
- **Deserialization failure must never stall the pipeline.** Failed messages route to a dead letter queue; the main consumer continues processing.
- **Historical queryability is non-negotiable.** Every schema version that ever produced data must remain resolvable. Schema registry entries are immutable — versions are never deleted.
- **NULL backfill for new columns is the only safe default for historical data.** Back-populating inferred values into historical records is prohibited without explicit lineage documentation and review.
- **Column removal requires a minimum tombstone window** (typically 30–90 days) during which the column is marked deprecated in the registry but still written by producers. No column is physically removed before all consumers have confirmed they no longer depend on it.
- **Type narrowing is always a breaking change.** Only type widening (e.g., integer to long, float to double) is permitted without a compatibility review override.
- **The landing zone schema is the source of truth.** Downstream schemas in the transformation and serving layers are derived views of the landing schema, not the other way around.

---

## Architecture Diagram

```mermaid
flowchart TD
    subgraph PRODUCERS["Producer Services (50+)"]
        P1[Service A\nv1 schema]
        P2[Service B\nv3 schema]
        P3[Service C\nv7 schema]
    end

    subgraph REGISTRY["Schema Registry (Centralized)"]
        SR[Versioned Schema Store\nIDs 1..N per event type]
        COMPAT[Compatibility Gate\nBACKWARD / FULL_TRANSITIVE]
        SR --> COMPAT
    end

    subgraph BUS["Message Broker (Event Bus)"]
        T1[Topic: order.events\nschema_id in envelope]
        T2[Topic: payment.events\nschema_id in envelope]
        DLQ[Dead Letter Queue\nfull payload + error code]
    end

    subgraph LANDING["Landing Zone (Immutable Object Storage)"]
        RAW[Raw Bytes Partition\nevent_type / date / hour]
        META[Envelope Metadata\nschema_id, producer_id,\nemission_ts, fingerprint]
    end

    subgraph SCHEMA_RESOLVE["Schema Resolution Layer"]
        CACHE[Schema Cache\n(LRU, TTL-backed)]
        LOOKUP[Registry Lookup\nby schema_id]
        CACHE -->|miss| LOOKUP
    end

    subgraph TRANSFORM["Transformation Layer"]
        DESER[Deserializer\nversion-aware]
        NORM[Schema Normalizer\ncanonical column names]
        WIDE[Wide Table Writer\nsparse columns + schema_version col]
        DESER --> NORM --> WIDE
    end

    subgraph WAREHOUSE["Column-Store Warehouse"]
        HIST[Historical Partition\nall versions co-located]
        VIEW[Semantic View Layer\nunified field names across versions]
        HIST --> VIEW
    end

    subgraph OBSERVABILITY["Observability"]
        MON[Schema Version Monitor\nper producer / consumer group]
        ALERT[Alert: schema_id gap,\nDLQ spike, NULL rate anomaly]
    end

    P1 & P2 & P3 -->|register before deploy| REGISTRY
    P1 & P2 & P3 -->|publish: payload + schema_id| BUS

    T1 & T2 -->|append raw bytes| LANDING
    T1 & T2 -->|failed deserialization| DLQ

    LANDING --> SCHEMA_RESOLVE
    SCHEMA_RESOLVE --> TRANSFORM

    TRANSFORM -->|schema_version + data| WAREHOUSE

    BUS --> MON
    TRANSFORM --> MON
    MON --> ALERT
```

---

## Solution Design

### Layer 1: Schema Registry and Compatibility Enforcement

The schema registry is the single source of truth for every event type's structural contract. It stores versioned schemas indexed by a monotonically increasing integer ID. Each ID is permanently associated with its schema; no ID is ever reused or deleted.

**Registration flow:**

When a producer team adds, removes, or changes a field, they register the new schema against the registry before deploying. The registry evaluates the candidate schema against the configured compatibility mode:

| Compatibility Mode | What It Guarantees | Safe Upgrade Order |
|---|---|---|
| BACKWARD | New consumers can read old messages | Deploy consumers before producers |
| FORWARD | Old consumers can read new messages | Deploy producers before consumers |
| FULL | Both directions simultaneously | Any order safe |
| BACKWARD_TRANSITIVE | New schema valid against every prior version | Deploy consumers first |
| FULL_TRANSITIVE | Full compatibility across all versions | Most restrictive; recommended for shared contracts |
| NONE | No checks | Dev/test only; prohibited on production topics |

The recommended default for event bus topics with downstream data warehouse consumers is **FULL_TRANSITIVE**. This is the most restrictive mode but provides the strongest guarantees: any consumer at any version can read any producer message at any version without coordination. The cost is that certain schema changes (field removal, type changes) require the expand-and-contract sequence rather than a single deployment.

**Schema normalization:** Before checking compatibility, the registry normalizes the schema (removes extraneous whitespace, sorts properties canonically) to prevent duplicate version registration for semantically identical schemas. Two schemas that differ only in formatting receive the same ID.

**CI/CD enforcement gate:** Schema compatibility is checked in the CI pipeline as a pre-merge step. A breaking schema change fails the build. This is the enforcement point; the registry check at registration time is the safety net, not the primary gate.

---

### Layer 2: Message Envelope Design

Every message on the event bus carries a fixed-format envelope. The envelope fields are written by the producer SDK (not the application code) to ensure consistency:

```
envelope:
  schema_id:        <integer>   # registry-assigned version ID
  schema_fingerprint: <hex>     # SHA-256 of canonical schema text
  event_type:       <string>    # e.g., "order.placed"
  producer_id:      <string>    # service name + instance
  emission_ts:      <ISO-8601>  # wall clock at point of event creation
  sequence:         <long>      # monotonic per-producer counter
payload:            <bytes>     # serialized event body
```

The `schema_id` allows the consumer to look up the exact schema used to serialize this message. The `schema_fingerprint` provides a checksum for detecting registry inconsistencies — if the fingerprint of the schema fetched from the registry does not match the envelope fingerprint, the message routes to the dead letter queue with a `SCHEMA_MISMATCH` error code.

The `emission_ts` is critical for the delayed-processing scenario: when a message is processed hours after emission, the consumer uses `emission_ts` (not the current time) for time-partitioning the landing zone write and for any time-windowed aggregations.

---

### Layer 3: Landing Zone — Raw Bytes as Ultimate Safety Net

Before any deserialization occurs, the ingestion consumer writes the raw message bytes to immutable object storage. This is a synchronous step in the consumer's commit path: the message is only acknowledged to the broker after the raw bytes are confirmed durable.

**Partition structure:**

```
landing/
  event_type=order.placed/
    year=2024/month=01/day=15/hour=14/
      part-00001.raw     # original bytes, newline-delimited
      part-00001.meta    # envelope fields as JSON, parallel structure
```

The `.meta` file contains the envelope fields (schema_id, fingerprint, emission_ts, producer_id, sequence) without the payload, enabling index scans without touching the payload files. The `.raw` file contains the verbatim payload bytes.

**Why raw bytes matter:** If a downstream schema change is applied incorrectly and historical data is corrupted, the raw landing zone is the recovery path. Any historical period can be re-ingested by re-reading the raw files and replaying through the current (corrected) transformation logic. Without this layer, a bad transformation is permanent.

**Immutability:** Landing zone partitions are write-once. Once an hour partition is closed (after a configurable lag window for late arrivals), it is transitioned to an immutable storage tier where no overwrites or deletions are permitted. Retention is governed by the organization's data retention policy, not by downstream convenience.

---

### Layer 4: Schema-Aware Deserialization

The transformation layer fetches schemas from the registry using the `schema_id` from the envelope, not the latest registered schema. This is the critical distinction for correctness: processing a message emitted 8 hours ago with the schema from 8 hours ago, even if the schema has since changed.

**Schema cache:** The registry is queried at most once per schema_id per consumer instance. A bounded LRU cache (keyed by schema_id) avoids repeated network calls. Cache entries are permanent (schema versions are immutable); there is no cache invalidation needed.

**Deserialization error handling:**

```
on deserialization failure:
  1. Log error with: schema_id, event_type, emission_ts, error_class, error_message
  2. Write full original bytes + envelope + error metadata to DLQ partition
  3. Commit offset to broker (do NOT stall the consumer)
  4. Increment DLQ counter metric for alerting
```

The dead letter queue preserves the original payload with enough metadata for an operator to diagnose and replay. DLQ messages are never silently discarded.

---

### Layer 5: Schema Change Classification and Safe Patterns

Not all schema changes carry the same risk. This table classifies changes by their safety profile:

| Change Type | Breaking for Consumers | Breaking for Producers | Safe Pattern |
|---|---|---|---|
| Add optional field with NULL default | No | No | Register and deploy; consumers receive NULL for old messages |
| Add required field without default | Yes | No | Prohibited in BACKWARD mode; must add default first |
| Remove field | Yes (consumers expecting it) | No | Tombstone period required; see soft deprecation pattern |
| Rename field | Yes (both directions) | Yes | Dual-write transition; see rename pattern |
| Widen type (int to long) | No | No | Safe; register and deploy |
| Narrow type (long to int) | Yes | No | Breaking; prohibited without compatibility override |
| Change semantics without changing structure | Silent | Silent | Document in schema metadata; communicate to consumers |
| Reorder fields (binary formats) | Yes (binary) | Yes | Never reorder; add new fields at end only |
| Add enum value | Depends on consumer | No | Safe only if consumer handles unknown enum values gracefully |
| Remove enum value | Yes | Depends | Treat same as field removal; tombstone period |

**Column addition with NULL backfill:**

When a new field is added to an event schema (e.g., `shipping_tier` added to `OrderPlaced`), the transformation layer must handle two cases:

1. New messages (schema version N): `shipping_tier` is present; write the value.
2. Old messages (schema version < N): `shipping_tier` is absent; write NULL.

The warehouse column exists with NULLs for all historical records before the field was introduced. Downstream analysts must treat this NULL as "not recorded" rather than "absent" — this semantic distinction should be documented in the data catalog entry for the column, including the schema version at which the field was first introduced (`first_version: 7`, `introduced_ts: 2024-03-15`).

Back-populating a non-NULL value into historical records based on assumptions (e.g., "all orders before March 2024 were standard shipping") is prohibited unless the business logic is formally documented, reviewed, and the lineage is captured — the derived nature of the back-populated values must be visible to downstream consumers.

**Column removal with soft deprecation and tombstone period:**

```
Phase 1 — Mark deprecated (Day 0):
  - Add deprecation annotation to field in registry:
      deprecated: true
      deprecated_since: "2024-06-01"
      sunset_date: "2024-09-01"
      replacement: "account_id"
  - Notify all downstream consumer teams via automated alert
  - Producers continue writing the field

Phase 2 — Monitor consumer adoption (Day 0 to Day 90):
  - Track read rate of deprecated field per consumer group
  - Consumer teams migrate to replacement field and confirm in writing
  - No removal until all known consumers confirm zero reads

Phase 3 — Contract (Day 90+):
  - Producer stops writing the deprecated field
  - Field removed from new schema version registration
  - Old schema versions (with the field) remain in registry permanently
  - Warehouse column retained as NULL-only going forward (or archived to cold tier)
```

The tombstone window (90 days in this example) is a policy decision. It should be longer for high-dependency fields and shorter for fields with no confirmed external consumers. The minimum should be at least one full billing or reporting cycle longer than the longest known consumer processing lag.

**Field rename as dual-write transition:**

Field renames cannot be done atomically in a schema-versioned system. The safe sequence is:

```
Step 1 — Expand:
  Register new schema version with BOTH old_name and new_name as separate fields.
  Both carry defaults (NULL). Producer begins writing both fields with identical values.

Step 2 — Consumer migration:
  Each consumer team updates their reader to use new_name.
  Teams confirm migration complete.

Step 3 — Contract:
  Mark old_name as deprecated per the tombstone procedure above.
  After tombstone window, producer stops writing old_name.
  Register schema version with only new_name.
```

In the warehouse, a view layer can expose `new_name` as the canonical column, unioning the old and new physical columns:

```sql
-- semantic view handling rename transition
SELECT
    COALESCE(new_name, old_name) AS canonical_name,
    -- other columns
FROM events_physical
```

The view makes the rename transparent to BI tools and analysts without altering the physical storage.

---

### Layer 6: Wide Table Storage with Schema Version Tracking

The warehouse physical layer uses a wide table pattern. Every field that has ever appeared in any schema version is a column in the physical table. Columns introduced by newer schema versions are NULL for rows produced by older schema versions.

**Schema version column:** Every row in the warehouse carries the `schema_version` integer from the envelope. This column is not for filtering in normal use — it exists for diagnostics and for version-specific query slices when needed.

**Column naming conventions for renamed fields:** When a rename transition is complete and the old physical column has passed its tombstone window, the old column is retained in the physical table as a NULL column (never dropped). Dropping a column from a historical warehouse table is a data destruction operation. Instead, the column is marked deprecated in the data catalog and excluded from semantic views.

**Partitioning:** Physical table is partitioned by `emission_date` (derived from `emission_ts` in the envelope, not the processing timestamp). This ensures that late-arriving messages land in the correct historical partition and that time-range queries remain efficient.

**Schema version metadata table:** A separate metadata table tracks the full history of schema registrations:

```sql
CREATE TABLE schema_version_registry (
    event_type          VARCHAR NOT NULL,
    schema_version      INTEGER NOT NULL,
    schema_fingerprint  VARCHAR NOT NULL,
    registered_ts       TIMESTAMP NOT NULL,
    compatibility_mode  VARCHAR NOT NULL,
    is_deprecated       BOOLEAN NOT NULL DEFAULT FALSE,
    deprecated_ts       TIMESTAMP,
    sunset_ts           TIMESTAMP,
    change_summary      VARCHAR,   -- human-readable description of what changed
    PRIMARY KEY (event_type, schema_version)
);
```

This table is queryable by analysts to understand when fields were introduced or removed, and by the pipeline itself to validate that a schema_id in an arriving message is known.

---

### Layer 7: Semantic View Layer for Historical Queryability

The semantic view layer is the public interface for BI tools and analysts. It abstracts over the physical wide table, handling:

1. **Rename transparency:** `COALESCE(new_name, old_name)` patterns for renamed fields.
2. **Deprecated column exclusion:** Views do not expose columns past their sunset date.
3. **Type widening transparency:** If a field was narrowed in a bad schema change (which should not happen but might in legacy systems), the view casts uniformly to the widest observed type.
4. **Backfill documentation:** Columns that have been back-populated with derived values carry a `_is_derived` boolean companion column set to TRUE for back-populated rows.

Views are version-controlled in the transformation layer repository. Any change to a view that alters the output of an existing column is treated as a breaking change and requires a new view name (e.g., `v_order_events_v2`) while the prior view remains for a deprecation window.

---

## Trade-offs

| Decision | Option A | Option B | Recommendation | Why |
|---|---|---|---|---|
| **Compatibility mode** | BACKWARD (new reader reads old data) | FULL_TRANSITIVE (both directions, all versions) | FULL_TRANSITIVE | With 50+ producers on independent release cadences and delayed processing, you cannot guarantee consumer-before-producer deploy order. FULL_TRANSITIVE eliminates the coordination requirement entirely, at the cost of restricting which schema changes are self-service. |
| **Schema format** | JSON Schema (human-readable, flexible) | Binary schema (Avro / Protobuf) | Binary schema with deterministic serialization | Binary schemas provide compact wire format, strict type enforcement, and field-order-sensitive encoding that prevents accidental structural drift. JSON Schema is easier to adopt but allows type coercion at deserialization that masks problems until they reach the warehouse. |
| **Landing zone content** | Deserialized rows only (structured Parquet) | Raw bytes + parallel metadata | Raw bytes + parallel metadata | Raw bytes are the only recovery path if deserialization logic has a bug or a schema change is applied retroactively. Structured-only landing means any pipeline error requires re-emission from producers — which is not always possible for historical events. |
| **Wide table vs. per-version tables** | One physical table per schema version | Single wide table with schema_version column | Single wide table | Per-version tables fragment historical queries and require UNION ALL across versions. Wide tables are sparse but support time-range queries without version awareness in the query. At extreme scale (thousands of schema versions with hundreds of unique columns) this tradeoff may reverse. |
| **NULL backfill policy** | Allow inferred backfill with documentation | Strict NULL-only for missing historical values | Strict NULL-only as default; inferred backfill as explicit opt-in with lineage metadata | Inferred backfills are easy to introduce and nearly impossible to audit later. The strict default prevents silent data quality degradation; the opt-in path preserves business flexibility when the logic is genuinely known and stable. |
| **Consumer DLQ behavior** | Stop consumer on first deserialization failure | Route to DLQ, continue processing | Route to DLQ, continue processing | Stopping the consumer on failure means a single malformed message (e.g., from a rogue producer) blocks all subsequent events indefinitely. DLQ routing preserves progress for the healthy message stream while preserving the failed message for inspection and replay. |
| **Schema tombstone window** | 7 days (fast iteration) | 90 days (conservative) | 90 days minimum, configurable per event type | 7 days is insufficient for organizations where quarterly reporting cycles mean a consumer may not read a deprecated field for 45–60 days. 90 days provides buffer for at least one full reporting cycle plus response time. High-traffic event types with confirmed consumer lists may negotiate shorter windows. |

---

## Failure Modes and Recovery

| Failure Scenario | Detection Method | Recovery Strategy |
|---|---|---|
| **Producer deploys breaking schema change without registry gate** | DLQ spike on affected topic; deserialization error rate alert; schema_id not found in registry | Roll back producer deployment. Re-process DLQ messages after producer rollback. Post-mortem to identify CI gate gap. |
| **Schema registry unavailable** | Consumer schema cache miss rate spike; registry health check alert | Consumers continue processing using local schema cache for previously seen schema_ids. Messages with unseen schema_ids route to DLQ (not discard). Registry HA / replica failover should make this window < 30 seconds. |
| **Late-arriving message references sunset schema version** | DLQ message with SCHEMA_SUNSET error code | Schema versions are never deleted from registry. If the schema was sunset in the registry metadata but the entry still exists, re-open the entry for the replay window. This is why registry entries must be immutable even for sunset versions. |
| **Field removal without tombstone window** | NULL rate anomaly on previously non-NULL column; alert on columns transitioning from <1% NULL to >50% NULL within one day | Mark field as deprecated retroactively. Query raw landing zone to reconstruct values from messages emitted before the removal. File incident with producing team to restore dual-write during remainder of tombstone window. |
| **Type narrowing causes silent data truncation** | Data quality check: value range validation on affected column; compare max observed values against column type max | Route affected messages to DLQ with TRUNCATION_DETECTED error. Produce compatibility override report. Producer must widen type in next deployment. Re-ingest from raw landing zone using correct type after schema correction. |
| **Rename transition abandoned mid-flight (consumers still reading old name)** | Read rate metric on deprecated old_name column does not reach zero before sunset date | Extend tombstone window. Alert consuming teams individually. Do not proceed to contract phase until all consumer groups confirm zero reads. |
| **Schema fingerprint mismatch (registry returns different bytes than envelope claims)** | Fingerprint validation step at deserialization; alert on SCHEMA_MISMATCH error code | Route to DLQ. Investigate registry data integrity. Compare envelope fingerprint against raw schema bytes in registry. If registry was partially corrupted, restore from backup and re-validate. |
| **Wide table column count explosion (schema proliferation across 50+ services)** | Column count alert on physical table; schema catalog audit showing unique column count rate of growth | Enforce event type review gate: new event types require platform team approval. Evaluate namespace partitioning (one wide table per event domain, not per event type). Review whether several low-volume event types can be merged into a structured variant type. |

---

## Observability Checklist

### Schema Registry Metrics

- [ ] Registration rate per event type per time window (spike = unplanned schema churn)
- [ ] Compatibility check failure rate (leading indicator of breaking change attempts)
- [ ] Active schema IDs per consumer group (stale consumer groups stuck on old versions)
- [ ] Schema version lag per consumer group: `max_registered_version - consumer_active_version`
- [ ] Registry read latency p50 / p95 / p99 (schema lookup in hot path)
- [ ] Cache hit rate per consumer instance (near-zero miss rate expected in steady state)

### Message Processing Metrics

- [ ] DLQ message rate per topic, classified by error code (DESER_ERROR, SCHEMA_MISMATCH, SCHEMA_NOT_FOUND, SCHEMA_SUNSET)
- [ ] Deserialization success rate per event type per schema version
- [ ] Message processing lag: `processing_ts - emission_ts` distribution (watch for delayed-processing tail)
- [ ] NULL rate per column per day (alert on step-change increase, indicating field removal or producer bug)
- [ ] Schema version distribution of processed messages per event type (unexpected bimodal distribution = mid-migration state)

### Landing Zone Metrics

- [ ] Raw bytes written per partition per hour (alert on unexpected zero-write partitions)
- [ ] Landing confirmation lag: time between broker offset commit and object storage write confirmation
- [ ] Landing partition immutability enforcement: alert on any write attempt to a closed partition

### Data Quality Metrics

- [ ] Column-level completeness rate (non-NULL percentage) tracked as a time series
- [ ] Value range violations on numeric columns (type narrowing detection)
- [ ] Schema version metadata table freshness: alert if a schema_id seen in messages is absent from the metadata table

### Alerts

| Alert | Threshold | Severity | Response |
|---|---|---|---|
| DLQ rate spike | >1% of messages on any topic in 5-min window | Critical | On-call page; investigate error code distribution |
| Schema version lag | Consumer >3 versions behind current | Warning | Notify consumer team; may indicate abandoned service |
| NULL rate step-change | Column NULL rate increases >20 percentage points in 1 day | Warning | Compare schema versions before/after; check for field removal |
| Compatibility gate failure | Any failure in CI schema check | Info | Block deployment; require producer team review |
| Registry unavailable | Health check failure >30 seconds | Critical | Failover to replica; escalate if both unavailable |
| Wide table column count | >500 columns on a single physical table | Warning | Schedule schema consolidation review |

---

## Interview Answer Template

### Framing the Problem (30 seconds)

"The core challenge is that you have 50+ independent producers evolving schemas on their own cadence, a consumer that may process messages hours after emission, and a requirement for full historical queryability. Those three constraints together mean you can't use simple 'latest schema wins' logic — you need to know exactly what schema was used when each message was produced."

### Constraint Elimination Technique

Start with the constraints that most directly eliminate naive solutions:

1. **"No vendor lock-in"** eliminates the urge to name specific products and forces you to describe the pattern: "a centralized schema registry with versioned schemas and a compatibility enforcement gate."
2. **"Delayed processing"** eliminates the assumption that schema lookups use current state: "you must embed the schema version in the message envelope and resolve at processing time, not at consumer startup."
3. **"Full historical queryability"** eliminates schema migration that overwrites history: "you need a wide table that preserves every field that ever existed, plus raw bytes as a recovery path."
4. **"Never break the consumer"** eliminates synchronous schema coupling: "deserialization failures must route to a dead letter queue — the consumer can never stall waiting for a schema fix."

### Structuring the Verbal Answer

1. **Start with the safety net** — land raw bytes first, parse second. This buys you recovery from any downstream mistake.
2. **Then explain the envelope** — schema fingerprint and version ID embedded by the producer SDK, not application code, ensures every message is self-describing.
3. **Then explain compatibility modes** — FULL_TRANSITIVE is the recommended default for shared event bus contracts; it eliminates producer/consumer deploy coordination.
4. **Then explain the warehouse design** — wide table with schema_version column, NULL for fields not present in older messages, semantic view layer for transparency.
5. **Then explain the change procedures** — field addition with NULL backfill, field removal with tombstone window, rename as dual-write transition.
6. **Close with observability** — NULL rate anomaly detection is the leading indicator that something changed upstream without going through the proper gate.

### Common Follow-Up Hooks

- *"What if a producer never registers their schema?"* — The producer SDK fails to serialize if the schema is not registered; registration is a required step, not optional. Unregistered schemas cannot produce messages.
- *"How do you handle truly incompatible changes?"* — You version the event type itself: `order.placed.v2` is a new topic. Both topics run in parallel during a migration window, then `order.placed.v1` is sunset.
- *"What about performance — doesn't the registry lookup add latency?"* — The schema cache means the registry is queried at most once per schema_id per consumer instance lifetime. In steady state (producers not deploying), the cache hit rate is near 100% and registry calls are negligible.
- *"What's the operational cost of the wide table over time?"* — Column count can explode if schema proliferation is not governed. The mitigation is a platform gate on new event type registration and periodic schema consolidation reviews, not a technical one.
