#!/usr/bin/env python3
import os
import shutil
import glob
from math import ceil
from snowflake.snowpark import Session  
import logging



logger = logging.getLogger(__name__)
logging.basicConfig(level=logging.INFO) # logs to console 


# Configuration (all lowercase)
table_name = "CUSTOMER"
src_db = "SOURCE_DB"
tgt_db = "TARGET_DB"
src_schema = "PUBLIC"
tgt_schema = "PUBLIC"
src_warehouse = "COMPUTE_WH"
tgt_warehouse = "COMPUTE_WH"
src_stage = f"{table_name}_src_stage"
tgt_stage = f"{table_name}_tgt_stage"
local_dir = f"{table_name}_parquet_chunks"
chunk_size = 10_000
order_by_keys = []  # override order key here or leave empty for auto []




def create_sf_sessions():
    """
    Build and return Snowflake sessions for source and target:
      - src_sf_session uses source settings
      - tgt_sf_session uses target settings
    """
    src_conf = {
        "ACCOUNT": "DYLSJTN-DVB44546",
        "USER": "RUSHIL",
        "PASSWORD": "Defau1t$1234^&*(",
        "ROLE": "SYSADMIN",
        "DATABASE": src_db,
        "SCHEMA": src_schema,
        "WAREHOUSE": src_warehouse
    }
    tgt_conf = {
        "ACCOUNT": "DYLSJTN-DVB44546",
        "USER": "RUSHIL",
        "PASSWORD": "Defau1t$1234^&*(",
        "ROLE": "SYSADMIN",
        "DATABASE": tgt_db,
        "SCHEMA": tgt_schema,
        "WAREHOUSE": tgt_warehouse
    }

    src_sf_session = Session.builder.configs(src_conf).create()
    tgt_sf_session = Session.builder.configs(tgt_conf).create()
    return src_sf_session, tgt_sf_session

def get_order_by_key(src_session: Session, override_keys: list[str] | None = None) -> str:
    try:
        if override_keys and len(override_keys) > 0:
            logging.info(f"[CONFIG] Using user-provided ORDER BY key(s): {', '.join(override_keys)}")
            return ", ".join(override_keys)  # join all keys for ORDER BY

        info_sql = f"""
            SELECT column_name
            FROM {src_db}.INFORMATION_SCHEMA.COLUMNS
            WHERE table_name = '{table_name.upper()}'
              AND table_schema = '{src_schema.upper()}'
            ORDER BY ordinal_position
            LIMIT 1
        """
        logging.info(f"[CONFIG] Fetching default ORDER BY key from INFORMATION_SCHEMA...")
        result = src_session.sql(info_sql).collect()

        if not result:
            msg = f"Unable to determine ORDER BY column for table {table_name}"
            logging.error(f"[CONFIG] {msg}")
            raise RuntimeError(msg)

        key = result[0]['COLUMN_NAME']
        logging.info(f"[CONFIG] Using INFORMATION_SCHEMA ORDER BY key: {key}")
        return key

    except Exception as e:
        logging.exception(f"[CONFIG] Error while getting ORDER BY key: {e}")
        raise



def generate_and_create_table(src_session: Session, tgt_session: Session):
    try:
        tgt_session.use_database(tgt_db)
        tgt_session.use_schema(tgt_schema)

        logging.info(f"[DDL] Checking if table {table_name} exists in {tgt_db}.{tgt_schema}...")
        tbl_check_sql = f"SHOW TABLES LIKE '{table_name}'"
        existing = tgt_session.sql(tbl_check_sql).collect()
        if existing:
            logging.info(f"[DDL] Table {table_name} already exists, skipping creation.")
            return

        logging.info(f"[DDL] Fetching column metadata from source table {src_db}.{src_schema}.{table_name}...")
        cols_sql = f"""
            SELECT column_name, data_type, character_maximum_length,
                   numeric_precision, numeric_scale, is_nullable
            FROM {src_db}.INFORMATION_SCHEMA.COLUMNS
            WHERE table_name = '{table_name.upper()}'
              AND table_schema = '{src_schema.upper()}'
            ORDER BY ordinal_position
        """
        columns = src_session.sql(cols_sql).collect()

        if not columns:
            msg = f"No column metadata found for table {table_name}"
            logging.error(f"[DDL] {msg}")
            raise RuntimeError(msg)

        ddl_cols = []
        for col in columns:
            name = col['COLUMN_NAME']
            dtype = col['DATA_TYPE']
            if dtype.upper() == 'VARCHAR' and col['CHARACTER_MAXIMUM_LENGTH']:
                dtype = f"VARCHAR({col['CHARACTER_MAXIMUM_LENGTH']})"
            elif dtype.upper() in ('NUMBER', 'DECIMAL') and col['NUMERIC_PRECISION']:
                dtype = f"NUMBER({col['NUMERIC_PRECISION']},{col['NUMERIC_SCALE'] or 0})"
            nullable = 'NOT NULL' if col['IS_NULLABLE'] == 'NO' else ''
            ddl_cols.append(f"{name} {dtype} {nullable}".strip())

        ddl = f"CREATE TABLE {table_name} (\n  " + ",\n  ".join(ddl_cols) + "\n);"
        logging.info(f"[DDL] Executing CREATE TABLE for {table_name}...")
        tgt_session.sql(ddl).collect()

        logging.info(f"[DDL] Successfully created table {table_name} in {tgt_db}.{tgt_schema}")

    except Exception as e:
        logging.exception(f"[DDL] Failed to generate or create table {table_name}: {e}")
        raise  # Optional: re-raise if you want it to halt the process




def download_chunk(src_session: Session, chunk_index: int, order_key: str) -> str:
    offset = chunk_index * chunk_size
    chunk_tag = f"chunk_{chunk_index}.parquet"
    stage_path = f"@{src_stage}/{chunk_tag}"

    # Unload chunk to source named stage
    df = src_session.sql(f"""
        SELECT *
        FROM {table_name}
        ORDER BY {order_key} 
        LIMIT {chunk_size} OFFSET {offset}
    """)
    df.write.copy_into_location(
        location=stage_path,
        file_format_type="parquet",
        header=True,
        overwrite=True
    )
    logger.info(f"[DOWNLOAD] Unloaded chunk {chunk_index} to stage path {stage_path}")

    # Download to local
    src_session.file.get(stage_path, local_dir)
    logger.info(f"[DOWNLOAD] Downloaded files to local directory")

    # Cleanup source stage files for this chunk
    src_session.sql(f"REMOVE {stage_path}").collect()
    logger.info(f"[DOWNLOAD] Removed {chunk_tag} from source stage")

    downloaded_files = glob.glob(os.path.join(local_dir, f"{chunk_tag}_*.snappy.parquet"))

    if not downloaded_files:
        raise FileNotFoundError(f"No files found matching pattern {chunk_tag}_*.snappy.parquet")

    # Log downloaded file size
    file_path = downloaded_files[0]
    file_size_mb = os.path.getsize(file_path) / (1024 * 1024)
    logger.info(f"[DOWNLOAD] Downloaded Parquet file size: {os.path.basename(file_path)} ({file_size_mb:.2f} MB)")

    return os.path.basename(file_path)





def upload_chunk(tgt_session: Session, file_name: str):
    local_path = os.path.join(local_dir, file_name)
    stage_target = f"@{tgt_stage}/{file_name}"

    # Upload to target stage
    tgt_session.file.put(local_path, f"@{tgt_stage}", auto_compress=False, overwrite=True)
    logger.info(f"[UPLOAD] Uploaded {file_name} to target stage {tgt_stage}")

    # Load into target table
    tgt_session.sql(f"""
        COPY INTO {table_name}
        FROM {stage_target}
        FILE_FORMAT = (TYPE = PARQUET)
        MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE
    """).collect()
    logger.info(f"[UPLOAD] Loaded {file_name} into table {table_name}")

    # Cleanup target stage files for this chunk
    tgt_session.sql(f"REMOVE {stage_target}").collect()
    logger.info(f"[UPLOAD] Removed {file_name} from target stage")

    # Delete local file
    os.remove(local_path)
    logger.info(f"[UPLOAD] Deleted local file {file_name}")



def setup_stages_and_dirs(src_sf_session, tgt_sf_session):
    try:
        src_sf_session.sql(f"CREATE STAGE IF NOT EXISTS {src_stage}").collect()
        logger.info(f"Source stage '{src_stage}' is ready.")
        tgt_sf_session.sql(f"CREATE STAGE IF NOT EXISTS {tgt_stage}").collect()
        logger.info(f"Target stage '{tgt_stage}' is ready.")

        if os.path.isdir(local_dir):
            shutil.rmtree(local_dir)
            logger.info(f"Removed existing local directory '{local_dir}'.")
        os.makedirs(local_dir, exist_ok=True)
        logger.info(f"Local directory '{local_dir}' is ready.")

    except Exception as e:
        logger.exception("Error during setup of stages or directories")
        raise





def process_chunks(src_session, tgt_session, order_key):
    total_rows = src_session.table(table_name).count()
    num_chunks = ceil(total_rows / chunk_size)
    logger.info(f"Total rows: {total_rows}, splitting into {num_chunks} chunks of up to {chunk_size}")

    for i in range(num_chunks):
        logger.info(f"\n--- Processing chunk {i + 1}/{num_chunks} ---")
        file_name = download_chunk(src_session, i, order_key)
        upload_chunk(tgt_session, file_name)

    logger.info("\n✅ All chunks processed end-to-end.")    




def cleanup_resources(src_session, tgt_session):
    try:
        src_session.sql(f"DROP STAGE IF EXISTS {src_stage}").collect()
        logger.info(f"Dropped source stage '{src_stage}'.")
        tgt_session.sql(f"DROP STAGE IF EXISTS {tgt_stage}").collect()
        logger.info(f"Dropped target stage '{tgt_stage}'.")

        shutil.rmtree(local_dir)
        logger.info(f"Deleted local directory '{local_dir}'.")

    except Exception as e:
        logger.exception("Error during resource cleanup")
        raise

    finally:
        src_session.close()
        tgt_session.close()
        logger.info("Closed both Snowflake sessions.")




def main(order_override: list[str] | None = None):
    src_sf_session, tgt_sf_session = create_sf_sessions()
    src_sf_session.use_database(src_db)
    src_sf_session.use_schema(src_schema)
    tgt_sf_session.use_database(tgt_db)
    tgt_sf_session.use_schema(tgt_schema)

    setup_stages_and_dirs(src_sf_session, tgt_sf_session)
    generate_and_create_table(src_sf_session, tgt_sf_session)
    order_key = get_order_by_key(src_sf_session, order_override)
    process_chunks(src_sf_session, tgt_sf_session, order_key)
    cleanup_resources(src_sf_session, tgt_sf_session)


if __name__ == "__main__":
    main(order_override=order_by_keys)
