<!-- Part of data-modelling-patterns: Navigation Index -->

# Data Modelling Patterns — Navigation Index

A reference library for data modelling concepts, schema design, and pipeline patterns.
Each file covers: what it solves, keywords to spot, DDL examples, gotchas, and business context.
Applicable for data engineering and analytics engineering interviews across fintech, e-commerce, SaaS, logistics, and healthcare.

## File Index

| File | Topic | Approx Lines |
|------|-------|-------------|
| 01-foundations.md | What is Data Modelling, OLTP vs OLAP, ETL vs ELT | 110 |
| 02-extraction-patterns.md | Extraction Patterns — Full, Watermark, CDC, Idempotency | 160 |
| 03-load-and-streaming.md | Load Strategies, Batch vs Micro-Batch vs Streaming | 75 |
| 04-keys-and-cardinality.md | Keys (Natural, Surrogate, Composite, Foreign), Cardinality and Relationships | 85 |
| 05-normalization.md | 1NF, 2NF, 3NF, BCNF, Denormalization | 215 |
| 06-grain-and-star-schema.md | Grain Definition, Star Schema, Snowflake Schema | 185 |
| 07-galaxy-and-fact-types.md | Galaxy Schema, Transaction Fact, Periodic Snapshot, Accumulating Snapshot, Factless Fact | 230 |
| 08-dimension-types.md | Conformed, Junk, Role-Playing, Degenerate, Bridge, Date/Calendar Dimensions | 255 |
| 09-scd-types.md | SCD Types 0, 1, 2, 3, 4, and 6 | 165 |
| 10-modern-stack.md | Medallion Architecture, One Big Table (OBT), Data Vault 2.0 | 260 |
| 11-design-decisions.md | Choosing the Right Model, Fan-out Trap, Many-to-Many Relationships, Hierarchies | 235 |
| 12-edge-cases-and-performance.md | Late Arriving Facts, NULL Handling in Dimensional Models, Performance Considerations | 200 |
| 13-quick-reference.md | Model Selection Decision Tree, Fact/Dimension/SCD Cheat Sheets, Keywords→Pattern Map | 75 |

## Reading Order

**New to data modelling:** 01 -> 04 -> 05 -> 06

**Kimball / dimensional modelling deep dive:** 06 -> 07 -> 08 -> 09

**Pipeline design (extraction, load, freshness):** 02 -> 03

**Modern stack (Medallion, OBT, Data Vault):** 10

**Design decisions and traps:** 11 -> 12

**Interview prep — fast review:** 13 -> 09 -> 07 -> 08

**Full end-to-end (first read):** 01 -> 02 -> 03 -> 04 -> 05 -> 06 -> 07 -> 08 -> 09 -> 10 -> 11 -> 12 -> 13

**Quick lookup:** 13
