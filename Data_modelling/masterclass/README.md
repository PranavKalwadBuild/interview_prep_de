# Data Modeling Masterclass

> A practitioner's reference covering schema design, scale mechanics, incremental patterns, and failure modes across six industry verticals.

---

## Contents

| File | Section | Description |
|------|---------|-------------|
| [01-retail-ecommerce.md](01-retail-ecommerce.md) | 1. Retail / E-Commerce | Product catalog with variants, order management (header + line grain), pricing SCD, promotions with bridge tables, inventory snapshot vs movement, Customer 360, and Black Friday / late-arrival hard problems |
| [02-healthcare.md](02-healthcare.md) | 2. Healthcare | Patient dimension with row-level security, encounter facts, separate diagnosis/procedure/medication child facts, bi-temporal modeling for valid vs transaction time, HIPAA audit trail, and late-arriving lab result watermarks |
| [03-manufacturing-supply-chain.md](03-manufacturing-supply-chain.md) | 3. Manufacturing / Supply Chain | Recursive BOM hierarchy, query-time vs materialized BOM explosion, work orders, manufacturing inventory movements, quality events, and BOM version control for historical costing |
| [04-financial-services.md](04-financial-services.md) | 4. Financial Services | Double-entry accounting ledger, account dimension with SCD Type 2, transaction fact + daily position snapshot, three options for point-in-time balance reconstruction, credit exposure modeling, and rate change audit trails |
| [05-saas-product-analytics.md](05-saas-product-analytics.md) | 5. SaaS / Product Analytics | Segment-style event stream, VARIANT vs typed sub-tables, user identity resolution, pre-computed sessionization with window functions, multi-tenant isolation strategies, and pre-computed funnel completion facts |
| [06-telecommunications.md](06-telecommunications.md) | 6. Telecommunications | CDR schema with date+hour partitioning, subscriber lifecycle SCD Type 2, service plan history, network topology hierarchy, churn prediction feature store, streaming ingestion two-layer architecture, and dual hot/cold path for NOC vs analytics |
| [07-schema-architectures.md](07-schema-architectures.md) | 7. Dimensional vs Data Vault vs OBT | Decision matrix for when each architecture wins, and the same e-commerce order line query expressed three ways (Kimball star, Data Vault hub/link/sat, One Big Table) with tradeoff commentary |
| [08-scd-types.md](08-scd-types.md) | 8. SCD Types in Depth | Type 1 (overwrite), Type 2 (new row + COUNT DISTINCT pitfall), Type 3 (prior value column), Type 4 (mini-dimension), Type 6 (hybrid 1+2+3), and bi-temporal modeling for when Type 2 is insufficient |
| [09-partitioning-clustering.md](09-partitioning-clustering.md) | 9. Partitioning and Clustering Strategy | Three partition key selection rules, cardinality traps in clustering, and platform-specific behavior comparison table for Snowflake, BigQuery, and Redshift |
| [10-incremental-patterns.md](10-incremental-patterns.md) | 10. Incremental Patterns | Append-only, upsert (MERGE), delete + reinsert (partition replacement), full refresh, and CDC modeling for source deletes — each with how late-arriving data breaks it and the fix |
| [11-anti-patterns.md](11-anti-patterns.md) | 11. Anti-Patterns with Autopsy | Five anti-patterns with root cause and fix: God Fact Table, over-normalized analytics models (12-table join), missing SCD handling (silent corruption), sparse fact tables, and premature aggregation |
| [12-reporting-vs-de-layer.md](12-reporting-vs-de-layer.md) | 12. Business Logic: DE Layer vs Reporting Layer | Decision framework for when logic belongs in dbt/Spark vs BI tools; eight worked cases (health score, sessionization, SCD joins, GDPR/SOX, MAU definition, YTD, conversion rate, what-if scenarios); decision matrix; Medallion architecture; real-world failure modes |
