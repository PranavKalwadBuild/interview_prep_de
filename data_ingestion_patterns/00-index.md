
<!-- data-ingestion-patterns: Data Ingestion Patterns — Navigation Index -->

# Data Ingestion Patterns — Navigation Index

> Production-grade, tech-stack-agnostic data ingestion patterns for data engineers.
> Covers batch, streaming, CDC, compliance, and advanced architectural patterns.
> Each file includes: problem statement, clarifying questions, Mermaid architecture diagrams, solution design, trade-offs, failure modes, observability, and interview templates.

---

## How to Use This Index

- **Interview prep**: Start with "Clarifying Questions" and "Interview Answer Template" sections.
- **Design reference**: Go straight to "Architecture Diagram" + "Solution Design".
- **Production debugging**: Check "Failure Modes & Recovery".
- **New to a pattern**: Read top-to-bottom.

---

## Pattern Library

### Tier 1 — Standard

| File | Pattern | Domain | Category |
|---|---|---|---|
| [01-batch-full-load-large-oltp.md](01-batch-full-load-large-oltp.md) | Batch Full Load — Large OLTP | Financial Transactions | Batch / Full Load |
| [02-incremental-high-watermark.md](02-incremental-high-watermark.md) | Incremental — High Watermark | E-commerce Orders | Batch / Incremental |
| [03-cdc-log-based.md](03-cdc-log-based.md) | CDC — Log-Based | Retail Inventory | CDC / Near Real-Time |

### Tier 2 — Intermediate

| File | Pattern | Domain | Category |
|---|---|---|---|
| [04-streaming-clickstream.md](04-streaming-clickstream.md) | Streaming Event Ingestion | Web / Mobile Analytics | Streaming |
| [05-api-pagination-rate-limited.md](05-api-pagination-rate-limited.md) | API Ingestion — Rate Limited + Cursor Pagination | CRM / SaaS | API Pull |
| [06-file-drop-sftp.md](06-file-drop-sftp.md) | File Drop Ingestion — SFTP | B2B / EDI | File-Based |
| [07-multi-source-merge-mdm.md](07-multi-source-merge-mdm.md) | Multi-Source Merge — Master Data | Customer MDM | Multi-Source |

### Tier 3 — Complex

| File | Pattern | Domain | Category |
|---|---|---|---|
| [08-schema-evolution.md](08-schema-evolution.md) | Schema Evolution Handling | Microservices Events | Schema Management |
| [09-late-arriving-data.md](09-late-arriving-data.md) | Late-Arriving / Out-of-Order Data | Mobile Transactions | Event Time |
| [10-iot-high-frequency-timeseries.md](10-iot-high-frequency-timeseries.md) | IoT High-Frequency Time Series | Industrial IoT | High-Throughput |

### Tier 4 — Hard / Regulated

| File | Pattern | Domain | Category |
|---|---|---|---|
| [11-healthcare-compliance-ingestion.md](11-healthcare-compliance-ingestion.md) | Healthcare Compliance Ingestion | Clinical / PHI | Regulated |
| [12-financial-regulatory-ingestion.md](12-financial-regulatory-ingestion.md) | Financial Regulatory Reporting | Trade Reporting | Zero Data Loss |
| [13-bi-temporal-ingestion.md](13-bi-temporal-ingestion.md) | Bi-Temporal Data Ingestion | Insurance Policies | Temporal Modeling |

### Tier 5 — Pathological / Architectural

| File | Pattern | Domain | Category |
|---|---|---|---|
| [14-zero-downtime-live-migration.md](14-zero-downtime-live-migration.md) | Zero-Downtime Live Migration | Legacy DW Migration | Migration |
| [15-hybrid-lambda-kappa.md](15-hybrid-lambda-kappa.md) | Hybrid Lambda/Kappa Architecture | Fraud Detection + Analytics | Streaming + Batch |

---

## Cross-Reference: By Constraint

| Constraint | Relevant Patterns |
|---|---|
| Read-only source access | 01, 03, 10 |
| Hard deletes must be captured | 01, 03, 12 |
| Zero data loss | 12, 15 |
| Compliance / audit trail | 11, 12, 13 |
| Schema changes from source | 03, 08 |
| Late / out-of-order data | 04, 09, 15 |
| High throughput > 10K events/sec | 04, 10, 15 |
| Multi-source same entity | 07, 11 |
| Historical reprocessing required | 09, 15 |
| Cost-constrained storage | 10, 15 |
| Rollback / reversibility required | 14 |
| Sub-second latency required | 04, 15 |
| Right-to-erasure / GDPR | 11 |
| Bi-temporal / AS OF queries | 13 |

---

## The SCOPED Framework

Use for every design question in interviews before proposing a solution.

| Letter | Question |
|---|---|
| **S**cale | How much data? Growth rate? TPS? |
| **C**onstraints | Read-only? Network limits? Latency SLA? Access level? |
| **O**perations | One-time or recurring? Full load + incremental? |
| **P**atterns | Extract → Land → Transform → Serve |
| **E**dge cases | Deletes, schema drift, failures, duplicates, late data |
| **D**ependencies | What already exists? CDC infra? Existing pipelines? |

## Constraint Elimination Technique

State constraints then explicitly eliminate invalid options before proposing:

- "Read-only access → trigger-based CDC eliminated"
- "No updated_at column → watermark approach cannot detect all changes"
- "Sub-second latency → batch processing eliminated, streaming required"
- "Zero data loss → at-most-once delivery eliminated"
- "No log access → log-based CDC eliminated, must use polling or snapshot diff"
