{{
  config(
    materialized       = 'incremental',
    unique_key         = ['customer_pk'],
    on_schema_change   = 'sync_all_columns',
    merge_exclude_columns = ['customer_pk'],
    snowflake_warehouse = 'TRANSFORM_WH_LARGE'
  )
}}

WITH source AS (
    SELECT *
    FROM {{ source('sap_raw', 'customer') }}
    {% if is_incremental() %}
    WHERE _FIVETRAN_SYNCED > (SELECT MAX(_FIVETRAN_SYNCED) FROM {{ this }})
    {% endif %}
),

deduped AS (
    SELECT *,
        ROW_NUMBER() OVER (
            PARTITION BY CUSTOMER_ID
            ORDER BY _FIVETRAN_SYNCED DESC
        ) AS _row_num
    FROM source
),

enriched AS (
    SELECT
        d.*,
        SHA2(
            COALESCE(CAST(d.CUSTOMER_ID AS VARCHAR), '') || '|' ||
            COALESCE(CAST(d.CUSTOMER_NAME AS VARCHAR), '') || '|' ||
            COALESCE(CAST(d.REGION AS VARCHAR), '') || '|' ||
            COALESCE(CAST(d.COUNTRY AS VARCHAR), '') || '|' ||
            COALESCE(CAST(d.CURRENCY AS VARCHAR), '') || '|' ||
            COALESCE(CAST(d.INDUSTRY AS VARCHAR), ''),
            256
        ) AS _row_hash,
        CURRENT_TIMESTAMP() AS _loaded_at
    FROM deduped d
    WHERE _row_num = 1
)

SELECT
    {{ dbt_utils.generate_surrogate_key(['CUSTOMER_ID']) }} AS customer_pk,
    CUSTOMER_ID,
    CUSTOMER_NAME,
    REGION,
    COUNTRY,
    CURRENCY,
    INDUSTRY,
    _row_hash,
    _FIVETRAN_SYNCED,
    _loaded_at
FROM enriched
