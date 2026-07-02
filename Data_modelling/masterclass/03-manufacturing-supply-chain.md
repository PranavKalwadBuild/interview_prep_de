<!-- data-modelling-patterns: Manufacturing / Supply Chain -->

# Manufacturing / Supply Chain

## When to Use This Design

Manufacturing analytics is driven by operational efficiency and traceability questions:

- What is the total material cost to produce product X, including all subassemblies?
- Which work orders are behind schedule and what is the downstream impact?
- How much of component Y do I need to order to fulfill 1,000 units of finished good Z?
- Was the quality event on Line 3 caused by a specific batch of raw material?

The domain-specific challenge is **recursive hierarchy**: a finished product is built from subassemblies, which are built from sub-subassemblies, which consume raw materials. The Bill of Materials (BOM) can be 8–12 levels deep. Queries that must traverse this hierarchy (cost rollup, requirements explosion) are fundamentally recursive — and recursive queries have different performance characteristics in different warehouse platforms.

## The Schema

### Bill of Materials (Recursive Hierarchy)

```sql
-- BOM Item master: every part, whether purchased or manufactured
CREATE TABLE dim_bom_item (
    item_key                BIGINT          NOT NULL,
    item_id                 VARCHAR(50)     NOT NULL,   -- Part Number
    item_description        VARCHAR(300)    NOT NULL,
    item_type               VARCHAR(20)     NOT NULL,   -- 'RAW_MATERIAL','SUBASSEMBLY','FINISHED_GOOD','PHANTOM'
    unit_of_measure         VARCHAR(10)     NOT NULL,
    unit_cost               NUMERIC(14,6),
    lead_time_days          INT,
    make_or_buy             CHAR(3)         NOT NULL,   -- 'MFG' or 'BUY'
    preferred_supplier_key  BIGINT,
    is_active               BOOLEAN         NOT NULL    DEFAULT TRUE,
    PRIMARY KEY (item_key)
);

-- BOM structure: recursive parent-child relationship
CREATE TABLE fact_bom_structure (
    bom_structure_key       BIGINT          NOT NULL,
    parent_item_id          VARCHAR(50)     NOT NULL,
    child_item_id           VARCHAR(50)     NOT NULL,
    bom_level               INT             NOT NULL,   -- depth from root: 1 = top-level component
    quantity_per            NUMERIC(14,6)   NOT NULL,   -- qty of child needed per 1 parent
    scrap_factor            NUMERIC(6,4)    NOT NULL    DEFAULT 0,  -- 0.02 = 2% expected scrap
    eff_start_date          DATE            NOT NULL,
    eff_end_date            DATE            NOT NULL    DEFAULT '9999-12-31',
    is_current              BOOLEAN         NOT NULL    DEFAULT TRUE,
    bom_version             VARCHAR(20),
    PRIMARY KEY (bom_structure_key)
)
CLUSTER BY (parent_item_id, child_item_id);

-- Flattened BOM (materialized for query performance)
CREATE TABLE fact_bom_flattened (
    bom_flat_key            BIGINT          NOT NULL,
    root_item_id            VARCHAR(50)     NOT NULL,   -- finished good
    component_item_id       VARCHAR(50)     NOT NULL,   -- any-level component
    component_level         INT             NOT NULL,
    path_string             VARCHAR(1000),              -- "FG001 > SA010 > RM045"
    extended_quantity       NUMERIC(18,8)   NOT NULL,   -- total qty per 1 root unit
    eff_start_date          DATE            NOT NULL,
    eff_end_date            DATE            NOT NULL    DEFAULT '9999-12-31',
    PRIMARY KEY (bom_flat_key)
)
PARTITION BY (eff_start_date)
CLUSTER BY (root_item_id, component_item_id);
```

### BOM Explosion: Query-Time vs Materialized

This is the central design tradeoff in manufacturing analytics.

**Query-time recursive CTE** (appropriate for < 500K BOM nodes, OLAP on interactive queries):

```sql
WITH RECURSIVE bom_explosion AS (
    -- Anchor: start from the finished good
    SELECT
        parent_item_id          AS root_item_id,
        child_item_id           AS component_item_id,
        quantity_per            AS extended_qty,
        bom_level,
        CAST(parent_item_id || ' > ' || child_item_id AS VARCHAR(1000)) AS path
    FROM fact_bom_structure
    WHERE parent_item_id = 'FG001'
      AND is_current = TRUE

    UNION ALL

    -- Recursive step: traverse deeper levels
    SELECT
        b.root_item_id,
        s.child_item_id,
        b.extended_qty * s.quantity_per * (1 + s.scrap_factor),
        b.bom_level + 1,
        b.path || ' > ' || s.child_item_id
    FROM bom_explosion b
    JOIN fact_bom_structure s
        ON b.component_item_id = s.parent_item_id
        AND s.is_current = TRUE
)
SELECT
    component_item_id,
    SUM(extended_qty) AS total_qty_needed,
    i.unit_cost,
    SUM(extended_qty) * i.unit_cost AS total_material_cost
FROM bom_explosion be
JOIN dim_bom_item i ON be.component_item_id = i.item_id
GROUP BY component_item_id, i.unit_cost;
```

**Why materialization wins at scale**: At 1M+ BOM nodes (common in aerospace or automotive), the recursive CTE spawns thousands of joins. Query time degrades from seconds to minutes. The `fact_bom_flattened` table is rebuilt nightly by the ELT pipeline running the above CTE — the cost is paid once at load time, not at every analyst query. The tradeoff is that the flattened table is stale relative to BOM changes made today. For most manufacturing analytics workloads, T+1 latency is acceptable. For real-time MRP systems, the recursive query is preferred or the flattened table is invalidated and rebuilt on every BOM change.

### Work Orders

```sql
CREATE TABLE fact_work_order (
    work_order_key          BIGINT          NOT NULL,
    work_order_id           VARCHAR(50)     NOT NULL,
    finished_item_key       BIGINT          NOT NULL,
    planned_start_date_key  INT             NOT NULL,
    planned_end_date_key    INT             NOT NULL,
    actual_start_datetime   TIMESTAMP,
    actual_end_datetime     TIMESTAMP,
    plant_key               BIGINT          NOT NULL,
    work_center_key         BIGINT,
    planned_quantity        NUMERIC(14,3)   NOT NULL,
    completed_quantity      NUMERIC(14,3)   NOT NULL    DEFAULT 0,
    scrapped_quantity       NUMERIC(14,3)   NOT NULL    DEFAULT 0,
    order_status            VARCHAR(20)     NOT NULL,   -- 'PLANNED','RELEASED','IN_PROGRESS','COMPLETE','CANCELLED'
    priority_level          INT,
    sales_order_id          VARCHAR(50),               -- if MTO (Make-to-Order)
    scheduled_hours         NUMERIC(10,2),
    actual_hours            NUMERIC(10,2),
    PRIMARY KEY (work_order_key)
)
PARTITION BY (planned_start_date_key)
CLUSTER BY (plant_key, order_status, finished_item_key);
```

### Inventory Movements in Manufacturing

Manufacturing inventory movements are significantly more complex than retail — they include production issues, scrap, rework, quality holds, and WIP transfers that have no retail equivalent.

```sql
CREATE TABLE fact_mfg_inventory_movement (
    movement_key            BIGINT          NOT NULL,
    movement_datetime       TIMESTAMP       NOT NULL,
    movement_date_key       INT             NOT NULL,
    item_key                BIGINT          NOT NULL,
    from_location_key       BIGINT,                    -- NULL for receipts
    to_location_key         BIGINT,                    -- NULL for issues to production
    work_order_key          BIGINT,                    -- NULL for non-production movements
    movement_type           VARCHAR(30)     NOT NULL,  -- 'RECEIPT','ISSUE','RETURN','SCRAP','TRANSFER','QC_HOLD','QC_RELEASE','ADJUSTMENT'
    quantity                NUMERIC(14,4)   NOT NULL,  -- always positive; direction from type
    lot_number              VARCHAR(50),               -- for lot-controlled items
    serial_number           VARCHAR(50),               -- for serialized items
    unit_cost_at_movement   NUMERIC(14,6),
    extended_cost           NUMERIC(18,6),
    PRIMARY KEY (movement_key)
)
PARTITION BY (movement_date_key)
CLUSTER BY (item_key, work_order_key, movement_type);
```

### Quality Events

Quality event modeling must link to the specific batch, lot, or work order — not just the item. This linkage is what enables root cause analysis: "was the high scrap rate on Work Order 5550 caused by Lot XYZ of raw material RM045?"

```sql
CREATE TABLE fact_quality_event (
    quality_event_key       BIGINT          NOT NULL,
    event_id                VARCHAR(50)     NOT NULL,
    event_datetime          TIMESTAMP       NOT NULL,
    event_date_key          INT             NOT NULL,
    event_type              VARCHAR(30)     NOT NULL,  -- 'NONCONFORMANCE','SCRAP','REWORK','CUSTOMER_COMPLAINT','AUDIT_FINDING'
    item_key                BIGINT          NOT NULL,
    work_order_key          BIGINT,
    lot_number              VARCHAR(50),
    work_center_key         BIGINT,
    plant_key               BIGINT          NOT NULL,
    defect_code             VARCHAR(20)     NOT NULL,
    defect_description      VARCHAR(500),
    quantity_affected       NUMERIC(14,4)   NOT NULL,
    disposition             VARCHAR(20),               -- 'SCRAP','REWORK','USE_AS_IS','RETURN_TO_SUPPLIER'
    cost_of_quality         NUMERIC(14,2),
    root_cause_category     VARCHAR(50),
    corrective_action_id    VARCHAR(50),
    PRIMARY KEY (quality_event_key)
)
PARTITION BY (event_date_key)
CLUSTER BY (plant_key, item_key, defect_code);
```

## The Hard Problems

**Event-Driven Inventory Reconciliation**: At a large manufacturer with 50 plants and 100,000 SKUs, inventory movements arrive from ERP systems, IoT floor sensors, and manual transactions. The aggregate (sum of movements) should equal the physical count snapshot. When they diverge — and they will — the reconciliation query must identify the specific movements that caused the discrepancy. This requires both the movement fact (for aggregation) and the snapshot fact (for comparison). The movement table must support efficient `SUM(quantity) WHERE movement_type != 'ADJUSTMENT'` over arbitrary date ranges by item+location — hence `item_key` as the first clustering column.

**BOM Version Control**: BOMs change over time. When a component is substituted, the old BOM version must be retained for historical work order costing. The `eff_start_date/eff_end_date` pattern on `fact_bom_structure` handles this, but it means cost rollups for historical work orders must join to the BOM version effective at the time of the work order, not the current BOM. This is the same bi-temporal pattern as healthcare, applied to engineering data.

## Scale Mechanics

The BOM flattened table is the primary scale lever. In automotive supply chains, a vehicle BOM can have 30,000+ unique components with up to 12 hierarchy levels. The flattened table for a 10,000-part BOM across 20 finished goods produces ~200,000 rows — trivial. For a 30,000-part BOM across 500 models, the flattened table hits ~15M rows and becomes a first-class partitioned table partitioned by `root_item_id` hash bucket.

The inventory movement table is the high-velocity table in manufacturing analytics. A 50-plant operation running 24/7 generates 500K–2M movement records per day. At 5 years retention, this is 1B–3B rows. Partitioning by `movement_date_key` with clustering on `(item_key, plant_key)` reduces most operational queries (current stock by location) to single-partition scans.
