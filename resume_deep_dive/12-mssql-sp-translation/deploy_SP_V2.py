import snowflake.connector
import os
import glob
import uuid
import logging
from datetime import datetime

logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s [%(levelname)s] %(message)s'
)
logger = logging.getLogger(__name__)


class SPExecutor:
    """V2: SP-only executor with structured logging to Snowflake log table."""

    def __init__(self, conn_params: dict, log_schema: str = "logs"):
        self.conn = snowflake.connector.connect(**conn_params)
        self.log_schema = log_schema
        self.execution_id = str(uuid.uuid4())
        self._ensure_log_table()

    def _ensure_log_table(self):
        self.conn.cursor().execute(f"""
            CREATE TABLE IF NOT EXISTS {self.log_schema}.sp_execution_log (
                execution_id   VARCHAR,
                run_timestamp  TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                file_path      VARCHAR,
                object_name    VARCHAR,
                status         VARCHAR,
                error_message  VARCHAR
            )
        """)

    def _log_result(self, file_path: str, object_name: str, status: str, error: str = None):
        self.conn.cursor().execute(
            f"INSERT INTO {self.log_schema}.sp_execution_log "
            f"(execution_id, file_path, object_name, status, error_message) "
            f"VALUES (%s, %s, %s, %s, %s)",
            (self.execution_id, file_path, object_name, status, error)
        )

    def deploy_all(self, sql_dir: str):
        files = sorted(glob.glob(os.path.join(sql_dir, "**/*.sql"), recursive=True))
        logger.info(f"[DEPLOY] Found {len(files)} SQL files. execution_id={self.execution_id}")
        for fpath in files:
            self._deploy_file(fpath)

    def _deploy_file(self, fpath: str):
        object_name = os.path.splitext(os.path.basename(fpath))[0]
        try:
            with open(fpath, "r", encoding="utf-8") as f:
                sql = f.read()
            cur = self.conn.cursor()
            cur.execute(sql, num_statements=0)
            self._log_result(fpath, object_name, "SUCCESS")
            logger.info(f"[OK]   {object_name}")
        except Exception as e:
            self._log_result(fpath, object_name, "FAILED", str(e))
            logger.error(f"[FAIL] {object_name}: {e}")

    def close(self):
        self.conn.close()
