{{
  config(materialized = 'view')
}}

-- Global Inventory Report — intermediate view combining EAGLE (US) and UNICORN (EU)
-- NOTE: All UNION ALL branches must use explicit column aliases to prevent silent column misalignment

WITH eagle_inventory AS (
    SELECT
        WERKS           AS plant_code,
        MATNR           AS material_number,
        LGORT           AS storage_location,
        LABST           AS unrestricted_stock,
        EINME           AS unit_of_measure,
        BUCHDAT         AS posting_date,
        _FIVETRAN_SYNCED,
        'EAGLE'         AS source_system
    FROM {{ source('sap_eagle', 'MARD') }}
    WHERE _FIVETRAN_DELETED = FALSE
),

unicorn_inventory AS (
    SELECT
        PLANT           AS plant_code,         -- explicit alias: PLANT → plant_code
        MATERIAL        AS material_number,
        SLOC            AS storage_location,
        UNREST_STOCK    AS unrestricted_stock,
        UOM             AS unit_of_measure,
        POST_DATE       AS posting_date,
        _FIVETRAN_SYNCED,
        'UNICORN'       AS source_system
    FROM {{ source('sap_unicorn', 'INVENTORY') }}
    WHERE _FIVETRAN_DELETED = FALSE
)

SELECT * FROM eagle_inventory
UNION ALL
SELECT * FROM unicorn_inventory
