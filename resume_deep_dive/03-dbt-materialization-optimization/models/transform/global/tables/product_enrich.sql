{{
  config(
    materialized       = 'incremental',
    unique_key         = ['product_pk'],
    on_schema_change   = 'sync_all_columns',
    merge_exclude_columns = ['product_pk'],
    snowflake_warehouse = 'TRANSFORM_WH_LARGE'
  )
}}

WITH source AS (
    SELECT *
    FROM {{ source('sap_raw', 'material') }}
    {% if is_incremental() %}
    WHERE _FIVETRAN_SYNCED > (SELECT MAX(_FIVETRAN_SYNCED) FROM {{ this }})
    {% endif %}
),

deduped AS (
    SELECT *,
        ROW_NUMBER() OVER (
            PARTITION BY MATNR
            ORDER BY _FIVETRAN_SYNCED DESC
        ) AS _row_num
    FROM source
),

enriched AS (
    SELECT
        d.*,
        SHA2(
            COALESCE(CAST(d.MATNR AS VARCHAR), '')      || '|' ||
            COALESCE(CAST(d.MAKTX AS VARCHAR), '')      || '|' ||
            COALESCE(CAST(d.MTART AS VARCHAR), '')      || '|' ||
            COALESCE(CAST(d.MATKL AS VARCHAR), '')      || '|' ||
            COALESCE(CAST(d.MEINS AS VARCHAR), ''),
            256
        ) AS _row_hash,
        CURRENT_TIMESTAMP() AS _loaded_at
    FROM deduped d
    WHERE _row_num = 1
)

SELECT
    {{ dbt_utils.generate_surrogate_key(['MATNR']) }} AS product_pk,
    MATNR     AS product_id,
    MAKTX     AS product_name,
    MTART     AS material_type,
    MATKL     AS material_group,
    MEINS     AS base_unit,
    _row_hash,
    _FIVETRAN_SYNCED,
    _loaded_at
FROM enriched
