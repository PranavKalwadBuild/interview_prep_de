## 7. Dimensional vs Data Vault vs One Big Table (OBT)

### When Each Architecture Wins

These three paradigms are not competing alternatives for the same problem — they solve different problems. The confusion arises because all three can technically produce similar analytical outputs.

| Dimension | Dimensional (Kimball) | Data Vault | One Big Table (OBT) |
|-----------|----------------------|------------|---------------------|
| Primary consumer | BI tools, business analysts | Data engineers, integration teams | Data scientists, ML, ad-hoc SQL |
| Schema philosophy | Query-optimized (denormalized dimensions) | Audit-optimized (normalized hubs/links/satellites) | Convenience-optimized (everything in one place) |
| Change handling | SCD types on dimensions | Satellite versioning (all history preserved) | Depends on implementation |
| Query complexity | Low (star schema, 2-3 table joins) | High (hub+link+sat reconstruction) | Minimal (single table filter) |
| Data volume efficiency | Moderate (dimension table replicated per join) | High (no duplication of keys) | Lowest (all denormalized per row) |
| Team size sweet spot | 5–50 analysts | 10–100 engineers across domains | 1–10 data scientists |
| Auditability | Moderate | Maximum | Low |

**Dimensional wins when**: The primary consumers are business analysts using BI tools (Tableau, Looker, Power BI). The query patterns are well-understood, relatively stable, and require < 4 table joins to answer. The team has defined the business processes and grain before building.

**Data Vault wins when**: Multiple heterogeneous source systems feed the same warehouse and must be loaded in parallel without coordination. Auditability of every load (who loaded what, when, from where) is a compliance requirement. The business domain changes frequently — new attributes arrive without requiring schema redesign. The team is large enough to manage the abstraction cost.

**OBT wins when**: The primary consumer is a Python/SQL data scientist building ML features. The wide table eliminates joins that would otherwise be written 50 times across 50 notebooks. The domain is narrow enough that the OBT stays manageable (< 200 columns). At Airbnb and Netflix, OBT patterns are used for ML feature serving — not for BI reporting.

### Same Domain, Three Ways: E-Commerce Order Lines

#### Kimball Dimensional

```sql
-- dim_customer, dim_sku, dim_date → fact_order_line
SELECT
    d.full_date,
    c.loyalty_tier,
    s.category_name,
    SUM(f.line_gross_revenue) AS revenue
FROM fact_order_line f
JOIN dim_date d ON f.order_date_key = d.date_key
JOIN dim_customer c ON f.customer_key = c.customer_key AND c.is_current = TRUE
JOIN dim_sku s ON f.sku_key = s.sku_key AND s.is_current = TRUE
GROUP BY 1, 2, 3;
```

3-join star schema query. Fast on columnar engines with proper clustering. BI tool-friendly.

#### Data Vault

```sql
-- Hub_Customer → Link_Order_Customer → Link_OrderLine → Sat_OrderLine_Details
-- Hub_SKU → Sat_SKU_Category

-- Data Vault reconstruction (simplified — real DV is more joins)
SELECT
    dd.full_date,
    sc.loyalty_tier,
    ss.category_name,
    SUM(sol.line_gross_revenue) AS revenue
FROM link_order_line lol
JOIN hub_order ho ON lol.order_hk = ho.order_hk
JOIN link_order_customer loc ON ho.order_hk = loc.order_hk
JOIN hub_customer hc ON loc.customer_hk = hc.customer_hk
JOIN sat_customer sc ON hc.customer_hk = sc.customer_hk
    AND sc.load_date <= CURRENT_DATE
    AND (sc.load_end_date IS NULL OR sc.load_end_date > CURRENT_DATE)
JOIN hub_sku hs ON lol.sku_hk = hs.sku_hk
JOIN sat_sku ss ON hs.sku_hk = ss.sku_hk
    AND ss.load_date <= CURRENT_DATE
    AND (ss.load_end_date IS NULL OR ss.load_end_date > CURRENT_DATE)
JOIN sat_order_line_details sol ON lol.order_line_hk = sol.order_line_hk
JOIN dim_date dd ON sol.order_date_key = dd.date_key
GROUP BY 1, 2, 3;
```

7+ join query. Not BI-tool friendly. Typically used as the raw layer, with a Business Vault or presentation layer (which looks like Kimball) built on top. The Data Vault is the integration layer, not the reporting layer.

#### One Big Table (OBT)

```sql
-- obt_order_lines: all dimensions denormalized into one table
CREATE TABLE obt_order_lines AS
SELECT
    f.order_line_id,
    f.order_id,
    f.order_placed_at,
    f.line_gross_revenue,
    f.line_cogs,
    -- Customer attributes at time of order (snapshot join in build process)
    c.customer_id,
    c.loyalty_tier,
    c.acquisition_channel,
    -- SKU attributes
    s.sku_id,
    s.product_id,
    s.product_name,
    s.category_name,
    s.brand,
    -- Date attributes
    d.full_date,
    d.day_of_week_name,
    d.is_holiday,
    d.fiscal_week,
    d.fiscal_quarter,
    -- Promotion attributes
    p.promo_name,
    p.promo_type,
    p.discount_value
FROM fact_order_line f
LEFT JOIN dim_customer c ON f.customer_key = c.customer_key AND c.is_current = TRUE
LEFT JOIN dim_sku s ON f.sku_key = s.sku_key AND s.is_current = TRUE
LEFT JOIN dim_date d ON f.order_date_key = d.date_key
LEFT JOIN dim_promotion p ON f.promo_key = p.promo_key;
```

Query is trivial: `SELECT loyalty_tier, category_name, SUM(line_gross_revenue) FROM obt_order_lines GROUP BY 1, 2`. The OBT is a materialized output of the dimensional model — it should be **built from** the dimensional model, not instead of it. The failure mode is building the OBT directly from source systems, which embeds business logic in a monolithic table with no SCD handling.
