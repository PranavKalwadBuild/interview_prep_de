<!-- Part of data-modelling-patterns: Load Strategies, Batch vs Micro-Batch vs Streaming -->

# Load Strategies and Processing Patterns

---

## Load Strategies

> **Keywords to spot:** "full refresh", "incremental", "upsert", "append", "truncate and reload", "how often does the pipeline run", "how do you handle updates"

| Strategy | How it works | When to use | Risk |
|---|---|---|---|
| **Full refresh** | Truncate target, reload everything | Small/medium tables, dim tables, when source has no timestamp | Expensive at scale, window of empty table during load |
| **Append-only** | INSERT new rows, never update/delete | Immutable event logs, Bronze/raw layer, transaction facts | Duplicates if pipeline re-runs without deduplication |
| **Incremental (watermark)** | Load rows where `updated_at > last_run` | Large tables with reliable timestamps | Misses hard deletes |
| **Upsert / MERGE** | Update matching rows, insert new rows | Dimension tables, SCD 1, any table with natural key and updates | Requires a join key; slower than append on large tables |
| **Partition replace** | Delete a partition, insert fresh data for that partition | Large partitioned fact tables (e.g., yesterday's data) | Must delete before insert; wrong partition filter = data loss |

**dbt materializations map directly to these strategies:**

| dbt materialization | Load strategy equivalent |
|---|---|
| `table` | Full refresh — recreates the table on every run |
| `view` | No load — queries run through on demand |
| `incremental` | Incremental (watermark or partition replace) |
| `snapshot` | SCD Type 2 — tracks changes using `updated_at` and `strategy: timestamp` or `strategy: check` |

**Gotchas:**
- Full refresh on a 10B-row fact table is not viable. Design incremental from the start for large tables.
- `CREATE OR REPLACE` (full refresh) leaves the table momentarily empty during the build. For production-critical tables, use `CREATE TABLE ... AS SELECT` into a new name then `SWAP` — Snowflake's zero-downtime swap. BigQuery has the same pattern.
- dbt incremental models append new rows by default. To handle updates to existing rows, add a `unique_key` config so dbt generates a MERGE instead.

---

## Batch vs Micro-Batch vs Streaming

> **Keywords to spot:** "real-time", "near real-time", "latency requirements", "Kafka", "Spark Streaming", "Flink", "how fresh is the data", "T+1", "event-driven"

| | Batch | Micro-Batch | Streaming |
|---|---|---|---|
| **Processing interval** | Hours / daily | Seconds to minutes | Milliseconds to seconds |
| **Latency** | T+1 or longer | Near real-time | Real-time |
| **Frameworks** | Spark, dbt, SQL jobs | Spark Structured Streaming, Databricks Auto Loader | Apache Flink, Kafka Streams, Kinesis |
| **Complexity** | Low | Medium | High |
| **State management** | None needed | Managed by framework | Complex (exactly-once, windowing) |
| **Use cases** | Nightly ETL, financial reports, dimensional models | Near-real-time dashboards, fraud scoring with minutes of tolerance | Real-time fraud detection, live dashboards, event-driven pipelines |
| **Cost** | Low (runs once) | Medium (continuous cluster) | High (always-on infrastructure) |

**The nuance with Spark Streaming:** Despite the name, Spark Structured Streaming processes data in micro-batches under the hood — it does not process events one-at-a-time. True event-by-event streaming requires Flink or Kafka Streams. For most analytics use cases, the difference doesn't matter (both feel "near real-time"). It matters for ordering guarantees and exactly-once semantics.

**Data freshness SLAs:**

| Term | What it means |
|---|---|
| **T+1** | Data from today is available by tomorrow morning — batch, nightly run |
| **T+4H** | Data is available within 4 hours of the event — micro-batch |
| **Near real-time** | Data available within minutes — micro-batch or fast batch |
| **Real-time** | Data available within seconds — streaming |

**Gotchas:**
- Don't default to streaming because it sounds impressive. If the business question is answered with yesterday's data, batch is cheaper, simpler, and more reliable. Match the architecture to the SLA.
- Streaming pipelines require handling late-arriving events (watermarks in Flink/Spark), out-of-order events, and exactly-once delivery guarantees. Each adds complexity. Batch has none of these concerns.
- Most data warehouses (Snowflake, BigQuery) are optimized for batch or micro-batch loads, not continuous streaming inserts. Streaming into a warehouse typically goes through a buffer (Kafka → Snowpipe or BigQuery Streaming API) that batches internally anyway.
