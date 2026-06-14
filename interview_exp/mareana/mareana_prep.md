# Mareana Data Engineer — Interview Prep
**Interview Date:** 2026-06-15 (2 days away)  
**Role:** Data Engineer — Bangalore, Full-Time  
**JD File:** `JD_Mareana_Data_Engineer.pdf`

---

## Company Context
- Founded 2015 — AI-powered platform for manufacturing, supply chain, and sustainability
- Core product: "Connected Intelligence Platform" — connects siloed data using AI/ML
- Customers: Life sciences, chemicals, general manufacturing
- Gartner "Cool Vendor in AI"
- Stack likely: Neo4j (graph DB central to product), Python, microservices, cloud

**Why this matters:** Mareana's product IS a data platform built heavily on graph databases. Neo4j is not a "nice to have" — it is core to their product. Frame every answer around data in manufacturing/supply chain context (traceability, lineage, dependency graphs = graph DB sweet spot).

---

## Your Strengths vs. JD — Quick Map

| JD Requirement | Your Coverage | Confidence |
|---|---|---|
| Python, SQL, ETL (3+ years) | Strong — dbt, ADF, Spark, Redshift, Snowflake | HIGH |
| Data transformation (SQL/Pandas) | Strong — complex dbt models, optimization work | HIGH |
| Cloud (Azure / AWS) | Both — ADF, Databricks, Redshift, Glue, S3 | HIGH |
| CI/CD | Strong — dbt Slim CI, Azure DevOps, GitHub | HIGH |
| RDBMS experience | MySQL, Snowflake, Redshift | MEDIUM |
| Data modeling | Data Mesh, warehouse modeling | MEDIUM |
| **Neo4j / Graph Databases** | **None on resume** | **CRITICAL GAP** |
| **CQL, Graph OGM, clustering** | **None on resume** | **CRITICAL GAP** |
| NoSQL | Not mentioned | GAP |
| Microservices / API development | Not mentioned | GAP |
| Linux fundamentals | Implied from shell scripting | LOW |
| 4–7 years experience | ~2 years actual | MISMATCH |

---

## Critical Focus: Neo4j & Graph Databases (Day 1 Priority)

This is the biggest gap and the most role-specific requirement. You need working knowledge of concepts even if you lack production experience. Be honest about your level but demonstrate you understand graphs well enough to ramp quickly.

### Core Concepts to Know

**Graph Model Fundamentals**
- **Nodes** — entities (e.g., Supplier, Product, Batch, Machine)
- **Relationships** — directed, typed edges between nodes (e.g., `SUPPLIED_BY`, `PRODUCED_IN`)
- **Properties** — key-value pairs on nodes or relationships
- **Labels** — categorize nodes (like a type tag, e.g., `:Product`, `:Supplier`)

**Why graph over relational?**
- Many-to-many relationships without expensive JOINs
- Traversal queries (find all connected entities N hops away) are native and fast
- Supply chain traceability: trace a product defect back through 10 supplier tiers — trivial in graph, painful in SQL joins

**Cypher Query Language (CQL) — Must Know**

```cypher
-- Basic match
MATCH (n:Product {name: 'BatchA'}) RETURN n

-- Relationship traversal
MATCH (p:Product)-[:SUPPLIED_BY]->(s:Supplier)
RETURN p.name, s.name

-- Create node and relationship
CREATE (b:Batch {id: 'B001', date: '2026-01-01'})
MERGE (b)-[:PRODUCED_AT]->(m:Machine {id: 'M42'})

-- Variable-depth traversal (key concept in JD)
MATCH (start:Product {id: 'P1'})-[:DEPENDS_ON*1..5]->(dep)
RETURN dep

-- WHERE, aggregation
MATCH (s:Supplier)-[:SUPPLIES]->(p:Product)
WHERE s.country = 'India'
RETURN s.name, count(p) AS product_count
ORDER BY product_count DESC
```

**Indexes in Neo4j**
- Create index on node property for fast lookup: `CREATE INDEX FOR (n:Product) ON (n.id)`
- Full-text indexes for text search
- Without indexes, Neo4j does full graph scan — same performance hit as missing SQL indexes

**neo4j-OGM (Object-Graph Mapping)**
- Maps Java/Python objects to graph nodes/relationships
- Like an ORM but for graphs
- You configure entity classes, and OGM handles serialization to/from graph
- Key concepts: `@NodeEntity`, `@Relationship`, `@Id`, session-based persistence

**Variable-Depth Persistence**
- In OGM, when saving an entity, you specify depth: how many relationship hops to also persist
- `session.save(entity, depth=2)` — saves the entity + all nodes 2 hops away
- Avoids unintentionally wiping relationships by saving a shallow copy

**Graph OLTP vs OLAP**
- **OLTP**: real-time, transactional — e.g., trace one product batch through the supply chain
- **OLAP**: analytical — e.g., find all bottleneck suppliers across all batches last quarter
- Neo4j is primarily OLTP; for OLAP, tools like Neo4j GDS (Graph Data Science) or exporting to a data warehouse

**Clustering**
- Neo4j Causal Cluster: one leader (writes), multiple followers (reads), routing tier
- Ensures HA and read scalability
- Core vs. Read Replica distinction

### Talking Points When You Lack Hands-On Neo4j Experience
> "I haven't used Neo4j in production, but I've worked extensively with highly relational data — supply chain traceability and data lineage in Data Mesh are naturally graph problems. The concepts map directly: our entity relationships in Snowflake required complex multi-hop join logic that would be much cleaner as graph traversals. I'm familiar with CQL and the property graph model, and I'm confident I can ramp quickly given my strong Python and SQL foundation."

---

## Day 1 Plan: Neo4j

1. **Read:** Neo4j Cypher Manual basics (40 min) — nodes, rels, MATCH, MERGE, variable-depth `*1..n`
2. **Practice:** Write 10 Cypher queries for a supply chain schema (Supplier → Product → Batch → Machine)
3. **Understand:** OGM concepts, what depth means in persistence
4. **Skim:** Neo4j clustering architecture (leader/follower, causal consistency)
5. **Connect to your work:** Think of 2–3 problems from your resume that graph would solve better than SQL

---

## Day 2 Plan: Consolidate & Behavioral Prep

### Behavioral / Leadership Questions (JD mentions "mentor junior devs")
Prepare STAR answers for:
1. A time you significantly optimized a data pipeline (→ 70% runtime reduction with dbt materialization)
2. A time you led a technical decision or architecture choice (→ TDD paradigm for 600 models)
3. A time you mentored someone or elevated a team (→ documented generic macros reducing 100+ days of work)
4. A time you proactively found a problem and solved it

### ETL & Python Deep Dive (they will ask)
- Be ready to design a Python ETL pipeline end-to-end
- Know Pandas: `groupby`, `merge`, `apply`, handling nulls, chunked reads for large files
- Know SQL window functions cold: `ROW_NUMBER`, `RANK`, `LAG`, `LEAD`, `PARTITION BY`
- Know data transformation patterns: SCD Type 1/2, deduplication, incremental loads

### Microservices / API Awareness
- Know REST API basics — you've consumed APIs (MSAL, OAuth in your Databricks pipeline)
- Know what a microservice boundary means — data isolation, independent deployability
- You don't need deep experience here; acknowledge it as an area to grow into

### NoSQL Awareness
- Key-value: Redis, DynamoDB
- Document: MongoDB
- Column: Cassandra
- Graph: Neo4j (this is what they care about)
- Be able to say when you'd choose NoSQL over relational

---

## Experience Years Gap — How to Frame It

The JD says 4–7 years; you have ~2. You will likely be asked about this.

> "I have 2 years of experience, but I've worked on complex, production-scale systems — data mesh migrations, multi-engine warehouse platforms, CI/CD pipelines for 600+ dbt models. The scope and impact of my work maps to what many engineers take 4–5 years to encounter. I'm a fast ramp — I hold three certifications (Databricks, AWS, Snowflake) and I'm confident in my ability to grow into this role quickly."

---

## Key Stories to Prepare (from your resume)

| Story | JD Angle |
|---|---|
| 100+ days saved with generic dbt macros | Innovative solution, scale, impact |
| 70% runtime reduction via materialization | Optimization, performance tuning |
| TDD for 600 models, data quality | Quality mindset, systematic thinking |
| SHA2 hash validation with Agentic AI | Creative problem-solving, cross-platform integrity |
| Snowflake ↔ Redshift sync utility | Python ETL, integration/import-export (JD requirement) |
| AD group sync → Snowflake roles (Databricks pipeline) | Cloud, automation, security awareness |
| CI/CD with dbt Slim CI | CI/CD pipelines (JD requirement) |

---

## Questions to Ask Them

1. How central is Neo4j to the platform — is it the primary store or one component of a larger architecture?
2. What does the data pipeline look like end-to-end — how does raw manufacturing data get into the graph?
3. What does the onboarding ramp look like for a new data engineer?
4. How does the team approach data quality and testing in graph data?
5. What are the biggest engineering challenges on the platform right now?

---

## Quick Reference Cheat Sheet

**Cypher CRUD:**
```cypher
CREATE (n:Label {prop: val})
MATCH (n:Label) WHERE n.prop = val RETURN n
MERGE (n:Label {prop: val}) SET n.other = val
DELETE n  /  DETACH DELETE n  (removes node + all its relationships)
```

**Variable-depth:**
```cypher
MATCH (a)-[:REL*2..4]->(b)  -- 2 to 4 hops
MATCH (a)-[:REL*]->(b)      -- any depth (careful — can be slow)
```

**Index:**
```cypher
CREATE INDEX product_id FOR (n:Product) ON (n.id)
SHOW INDEXES
```

**OGM depth rule:** Always specify depth when saving to avoid overwriting unloaded relationships with nulls.
