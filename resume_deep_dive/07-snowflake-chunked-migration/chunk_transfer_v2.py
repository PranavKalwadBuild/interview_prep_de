#!/usr/bin/env python3
import os
import shutil
import glob
from math import ceil
from snowflake.snowpark import Session  
from config import SRC, TGT
import glob

# Configuration
TABLE_NAME = "CUSTOMER"
SRC_DB = "SOURCE_DB"
TGT_DB = "TARGET_DB"
SCHEMA = "PUBLIC"
SRC_STAGE = f"@%{TABLE_NAME}"
TGT_STAGE = f"{TABLE_NAME}_stage"
LOCAL_DIR = f"{TABLE_NAME}_parquet_chunks"
CHUNK_SIZE = 10_000
ORDER_BY_KEYS = ['C_CUSTKEY']  # Override order key here or leave empty for auto


def get_order_by_key(src_session: Session, override_keys: list[str] | None = None) -> str:
    """
    Determine the column to ORDER BY.
    - If override_keys is provided and non-empty, uses the first element.
    - Otherwise queries INFORMATION_SCHEMA.COLUMNS to get the first column of the table.
    """
    if override_keys and len(override_keys) > 0:
        print(f"[CONFIG] Using user-provided ORDER BY key(s): {', '.join(override_keys)}")
        return ", ".join(override_keys)  # Join all keys for ORDER BY

    # Fallback: fetch first ordinal column from information schema
    info_sql = f"""
        SELECT column_name
        FROM {SRC_DB}.INFORMATION_SCHEMA.COLUMNS
        WHERE table_name = '{TABLE_NAME.upper()}'
          AND table_schema = '{SCHEMA.upper()}'
        ORDER BY ordinal_position
        LIMIT 1
    """
    result = src_session.sql(info_sql).collect()
    if not result:
        raise RuntimeError(f"Unable to determine ORDER BY column for {TABLE_NAME}")
    key = result[0]['COLUMN_NAME']
    print(f"[CONFIG] Using INFORMATION_SCHEMA ORDER BY key: {key}")
    return key



def generate_and_create_table(src_session: Session, tgt_session: Session):
    """
    Generates a CREATE TABLE DDL for TABLE_NAME in the target database
    based on the source table's INFORMATION_SCHEMA, then executes it on target.
    """
    # Query columns metadata from source
    cols_sql = f"""
        SELECT column_name, data_type, character_maximum_length, numeric_precision, numeric_scale, is_nullable
        FROM {SRC_DB}.INFORMATION_SCHEMA.COLUMNS
        WHERE table_name = '{TABLE_NAME.upper()}'
          AND table_schema = '{SCHEMA.upper()}'
        ORDER BY ordinal_position
    """
    columns = src_session.sql(cols_sql).collect()

    if not columns:
        raise RuntimeError(f"No column metadata found for {TABLE_NAME}")

    # Build column definitions
    ddl_cols = []
    for col in columns:
        name = col['COLUMN_NAME']
        dtype = col['DATA_TYPE']
        # Append length/precision if applicable
        if dtype.upper() == 'VARCHAR' and col['CHARACTER_MAXIMUM_LENGTH']:
            dtype = f"VARCHAR({col['CHARACTER_MAXIMUM_LENGTH']})"
        elif dtype.upper() in ('NUMBER', 'DECIMAL') and col['NUMERIC_PRECISION']:
            dtype = f"NUMBER({col['NUMERIC_PRECISION']},{col['NUMERIC_SCALE'] or 0})"
        # Handle nullability
        nullable = 'NOT NULL' if col['IS_NULLABLE'] == 'NO' else ''
        ddl_cols.append(f"{name} {dtype} {nullable}".strip())

    # Compose full CREATE TABLE statement
    ddl = f"CREATE OR REPLACE TABLE {TABLE_NAME} (\n  " + ",\n  ".join(ddl_cols) + "\n);"
    print(f"[DDL] Generated DDL for {TABLE_NAME}:\n{ddl}")

    # Switch to target database and schema, then execute DDL
    tgt_session.use_database(TGT_DB)
    tgt_session.use_schema(SCHEMA)
    tgt_session.sql(ddl).collect()
    print(f"[DDL] Created table {TABLE_NAME} in target database {TGT_DB}.{SCHEMA}")


def download_chunk(src_session: Session, chunk_index: int, order_key: str) -> str:
    offset = chunk_index * CHUNK_SIZE
    chunk_tag = f"chunk_{chunk_index}.parquet"
    stage_path = f"{SRC_STAGE}/{chunk_tag}"

    # Unload chunk to Snowflake stage
    df = src_session.sql(f"""
        SELECT *
        FROM {TABLE_NAME}
        ORDER BY {order_key} 
        LIMIT {CHUNK_SIZE} OFFSET {offset}
    """)
    df.write.copy_into_location(
        location=stage_path,
        file_format_type="parquet",
        header=True,
        overwrite=True
    )
    print(f"[DOWNLOAD] Unloaded chunk {chunk_index} to stage path {stage_path}")

    # Download to local
    src_session.file.get(stage_path, LOCAL_DIR)
    print(f"[DOWNLOAD] Downloaded files to local directory")

    # Cleanup source stage
    src_session.sql(f"REMOVE {stage_path}").collect()
    print(f"[DOWNLOAD] Removed {chunk_tag} from source stage")

    # Identify the actual downloaded file
    downloaded_files = glob.glob(os.path.join(LOCAL_DIR, f"{chunk_tag}_*.snappy.parquet"))
    if not downloaded_files:
        raise FileNotFoundError(f"No files found matching pattern {chunk_tag}_*.snappy.parquet")

    # Return the actual file name
    return os.path.basename(downloaded_files[0])


def upload_chunk(tgt_session: Session, file_name: str):
    """
    Uploads a given Parquet file from local directory to target stage, loads into target table,
    then removes from stage and deletes local file.
    """
    local_path = os.path.join(LOCAL_DIR, file_name)
    stage_target = f"@{TGT_STAGE}/{file_name}"

    # Upload to target stage
    tgt_session.file.put(local_path, f"@{TGT_STAGE}", auto_compress=False, overwrite=True)
    print(f"[UPLOAD] Uploaded {file_name} to target stage {TGT_STAGE}")

    # Load into target table
    tgt_session.sql(f"""
        COPY INTO {TABLE_NAME}
        FROM {stage_target}
        FILE_FORMAT = (TYPE = PARQUET)
        MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE
    """ ).collect()
    print(f"[UPLOAD] Loaded {file_name} into table {TABLE_NAME}")

    # Cleanup target stage
    tgt_session.sql(f"REMOVE {stage_target}").collect()
    print(f"[UPLOAD] Removed {file_name} from target stage")

    # Delete local file
    os.remove(local_path)
    print(f"[UPLOAD] Deleted local file {file_name}")


def main(order_override: list[str] | None = None):
    # Connect to source and target
    src = Session.builder.configs(SRC).create()
    src.use_database(SRC_DB)
    src.use_schema(SCHEMA)

    tgt = Session.builder.configs(TGT).create()
    tgt.use_database(TGT_DB)
    tgt.use_schema(SCHEMA)

    # Generate and create target table schema based on source
    generate_and_create_table(src, tgt)

    # Determine order key
    order_key = get_order_by_key(src, order_override)

    # Prepare local directory
    if os.path.isdir(LOCAL_DIR):
        shutil.rmtree(LOCAL_DIR)
    os.makedirs(LOCAL_DIR, exist_ok=True)
    print(f"Local directory '{LOCAL_DIR}' is ready.")

    # Ensure target stage exists
    tgt.sql(f"CREATE STAGE IF NOT EXISTS {TGT_STAGE}").collect()
    print(f"Target stage '{TGT_STAGE}' is ready.")

    # Compute number of chunks
    total_rows = src.table(TABLE_NAME).count()
    num_chunks = ceil(total_rows / CHUNK_SIZE)
    print(f"Total rows: {total_rows}, splitting into {num_chunks} chunks of up to {CHUNK_SIZE}")

    # Loop: download then upload per chunk
    for i in range(num_chunks):
        print(f"\n--- Processing chunk {i + 1}/{num_chunks} ---")
        file_name = download_chunk(src, i, order_key)
        upload_chunk(tgt, file_name)

    print("\n✅ All chunks processed end-to-end.")

    # Close sessions
    src.close()
    tgt.close()


if __name__ == "__main__":
    main(order_override=ORDER_BY_KEYS)