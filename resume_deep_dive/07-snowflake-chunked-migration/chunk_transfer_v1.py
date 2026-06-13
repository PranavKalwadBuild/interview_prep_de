#!/usr/bin/env python3
import os
import shutil
import glob
from math import ceil
from snowflake.snowpark import Session   # type: ignore
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



def download_chunk(src_session: Session, chunk_index: int) -> str:
    offset = chunk_index * CHUNK_SIZE
    chunk_tag = f"chunk_{chunk_index}.parquet"
    stage_path = f"{SRC_STAGE}/{chunk_tag}"

    # Unload chunk to Snowflake stage
    df = src_session.sql(f"""
        SELECT *
        FROM {TABLE_NAME}
        ORDER BY C_CUSTKEY
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


def main():
    # Connect to source and target
    src = Session.builder.configs(SRC).create()
    src.use_database(SRC_DB)
    src.use_schema(SCHEMA)

    tgt = Session.builder.configs(TGT).create()
    tgt.use_database(TGT_DB)
    tgt.use_schema(SCHEMA)

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
        file_name = download_chunk(src, i)
        upload_chunk(tgt, file_name)

    print("\n✅ All chunks processed end-to-end.")

    # Close sessions
    src.close()
    tgt.close()


if __name__ == "__main__":
    main()
