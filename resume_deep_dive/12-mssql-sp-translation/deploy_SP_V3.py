import snowflake.connector
import os
import glob
import uuid
import logging

logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s [%(levelname)s] [%(funcName)s] %(message)s'
)
logger = logging.getLogger(__name__)

# V3: Generalised to all DB object types, dependency-ordered execution, retry mechanism
EXECUTION_ORDER = [
    "Tables",
    "Scalar_valued_Functions",
    "Table_valued_Functions",
    "Views",
    "Stored_Procedures",
]


class DBObjectExecutor:
    """
    V3 improvements over V2:
    - Renamed SPExecutor → DBObjectExecutor (handles tables, funcs, views, SPs)
    - Dependency-ordered execution: Tables → Functions → Views → SPs
    - retry_failed_executions() re-runs only FAILED entries from log table
    - CREATE OR REPLACE TABLE replaced by existence check to prevent destructive re-runs
    """

    def __init__(self, conn_params: dict, log_schema: str = "logs"):
        self.conn_params = conn_params
        self.conn = snowflake.connector.connect(
            **conn_params,
            session_parameters={"MULTI_STATEMENT_COUNT": 0}
        )
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
                object_type    VARCHAR,
                status         VARCHAR,
                error_message  VARCHAR
            )
        """)

    def _log_result(self, file_path, object_name, object_type, status, error=None):
        try:
            self.conn.cursor().execute(
                f"INSERT INTO {self.log_schema}.sp_execution_log "
                f"(execution_id, file_path, object_name, object_type, status, error_message) "
                f"VALUES (%s, %s, %s, %s, %s, %s)",
                (self.execution_id, file_path, object_name, object_type, status, error)
            )
        except Exception as log_err:
            logger.error(f"[LOG_ERROR] Failed to write log: {log_err}")

    def deploy_all(self, base_dir: str):
        logger.info(f"[DEPLOY] execution_id={self.execution_id}")
        for obj_type in EXECUTION_ORDER:
            subfolder = os.path.join(base_dir, obj_type)
            if not os.path.isdir(subfolder):
                logger.info(f"[SKIP] No folder for: {obj_type}")
                continue
            files = sorted(glob.glob(os.path.join(subfolder, "*.sql")))
            logger.info(f"[{obj_type}] Deploying {len(files)} files")
            for fpath in files:
                self._deploy_file(fpath, obj_type)

    def _deploy_file(self, fpath: str, obj_type: str = "Unknown"):
        object_name = os.path.splitext(os.path.basename(fpath))[0]
        try:
            with open(fpath, "r", encoding="utf-8") as f:
                sql = f.read()
            cur = self.conn.cursor()
            cur.execute(sql, num_statements=0)
            self._log_result(fpath, object_name, obj_type, "SUCCESS")
            logger.info(f"[{obj_type}][OK]   {object_name}")
        except Exception as e:
            self._log_result(fpath, object_name, obj_type, "FAILED", str(e))
            logger.error(f"[{obj_type}][FAIL] {object_name}: {e}")

    def retry_failed_executions(self):
        """Re-execute only files that are FAILED in the log table."""
        cur = self.conn.cursor()
        cur.execute(f"""
            SELECT DISTINCT file_path, object_type
            FROM {self.log_schema}.sp_execution_log
            WHERE status = 'FAILED'
            ORDER BY object_type, file_path
        """)
        rows = cur.fetchall()
        logger.info(f"[RETRY] {len(rows)} failed objects to retry. execution_id={self.execution_id}")
        for fpath, obj_type in rows:
            if os.path.exists(fpath):
                self._deploy_file(fpath, obj_type)
            else:
                logger.warning(f"[RETRY][MISSING] File no longer exists: {fpath}")

    def close(self):
        try:
            self.conn.close()
        except Exception:
            pass
