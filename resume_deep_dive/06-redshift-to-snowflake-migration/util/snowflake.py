import snowflake.connector
import os
import logging
from typing import Dict, List, AnyStr
import re

logger = logging.getLogger(__name__)

class SnowflakeClient():
    def __init__(self):
        self.account = os.environ.get("DBT_WH_SNOWFLAKE_ACCOUNT")
        self.user = os.environ.get("DBT_WH_SNOWFLAKE_USER")
        self.role = os.environ.get("DBT_WH_SNOWFLAKE_ROLE")
        self.warehouse = os.environ.get("DBT_WH_SNOWFLAKE_WAREHOUSE")
        self.database = os.environ.get("DBT_WH_SNOWFLAKE_DB")
        self.private_key_file = os.environ.get("DBT_WH_SNOWFLAKE_PRIVATE_KEY_FILE")
        self.connection = None

    def connect(self):
        connection_params = {
            'account': self.account,
            'user': self.user,
            'authenticator': 'externalbrowser',  # Default to external browser. If private key is provided, connector will use snowflake_jwt.
            'role': self.role,
            'warehouse': self.warehouse,
            'database': self.database,
        }
        if self.private_key_file:
            connection_params['private_key_file'] = self.private_key_file
        
        self.connection = snowflake.connector.connect(**connection_params)
        return self.connection
    
    def run_query(self, query: str, use_database: str = None, use_schema: str = None, commit: bool = False):
        if self.connection is None:
            self.connect()

        cursor = self.connection.cursor()

        if use_database:
            cursor.execute(f"USE DATABASE {use_database};")
        if use_schema:
            cursor.execute(f"USE SCHEMA {use_schema};")

        cursor.execute(query)
        
        # For SELECT, SHOW, DESCRIBE commands, fetch all results
        if any(query.strip().upper().startswith(cmd) for cmd in ['SELECT', 'SHOW', 'DESCRIBE', 'EXPLAIN']):
            result = cursor.fetchall()
        else:
            result = cursor.rowcount
        
        if commit:
            self.connection.commit()
        
        cursor.close()
        return result

    def get_table_definition(self, schema: str, table: str, database: str = None) -> Dict[str, Dict[str, Dict[str, AnyStr]]]:
        database = database or self.database
        
        col_query = f"""
        SELECT 
            ordinal_position,
            column_name,
            data_type,
            character_maximum_length,
            numeric_precision,
            numeric_scale,
            comment
        FROM {database}.information_schema.columns
        WHERE table_schema = '{schema.upper()}'
        AND table_name = '{table.upper()}'
        ORDER BY ordinal_position
        """
        
        table_query = f"""
        SELECT table_type, comment
        FROM {database}.information_schema.tables
        WHERE table_schema = '{schema.upper()}'
        AND table_name = '{table.upper()}'
        """
        
        cols = self.run_query(col_query)
        table_info = self.run_query(table_query)
        
        ret = {"type": table_info[0][0] if table_info else "TABLE", "description": table_info[0][1] if table_info and table_info[0][1] else ""}
        
        columns = {}
        for col in cols:
            try:
                # Ensure we have enough elements in the tuple
                if len(col) < 7:
                    logger.warning(f"Incomplete column information: {col}")
                    continue
                    
                col_name = col[1]
                data_type = col[2]
                
                if col[3] and data_type.upper() in ['VARCHAR', 'CHAR']:
                    dt = f"{data_type}({col[3]})"
                elif col[4] and col[5] and data_type.upper() in ['NUMBER', 'DECIMAL', 'NUMERIC']:
                    dt = f"{data_type}({col[4]},{col[5]})"
                else:
                    dt = data_type
                    
                columns[col_name] = {"datatype": dt, "position": col[0]}
                if col[6]:
                    columns[col_name].update({"description": col[6]})
            except (IndexError, TypeError) as e:
                logger.error(f"Error processing column definition {col}: {str(e)}")
                continue

        ret["columns"] = columns
        return ret

    def table_exists(self, schema: str, table: str, database: str = None) -> bool:
        database = database or self.database
        query = f"""
        SELECT COUNT(*)
        FROM {database}.information_schema.tables
        WHERE table_schema = '{schema.upper()}'
        AND table_name = '{table.upper()}'
        """
        
        result = self.run_query(query)
        return result[0][0] > 0

    def view_exists(self, schema: str, view: str, database: str = None) -> bool:
        database = database or self.database
        query = f"""
        SELECT COUNT(*)
        FROM {database}.information_schema.tables
        WHERE table_schema = '{schema.upper()}'
        AND table_name = '{view.upper()}'
        AND table_type = 'VIEW'
        """
        
        result = self.run_query(query)
        return result[0][0] > 0

    def create_table_from_s3(self, schema: str, table: str, s3_path: str, file_format: str = "PARQUET", database: str = None):
        """
        Create Snowflake table and load data from S3 using storage integration and predefined file format
        """
        if database is None:
            database = self.database
        
        stage_name = f"MIGRATION_STAGE_{schema}_{table}".upper()
        
        # Use storage integration and predefined file format
        storage_integration = os.environ.get("DBT_WH_SNOWFLAKE_STORAGE_INTEGRATION", "EXT_S3_INTEGRATION")
        parquet_file_format = os.environ.get("DBT_WH_SNOWFLAKE_PARQUET_FF", "BASE.EXT_PARQUET_FF")
        
        # Handle file format with explicit database prefix if needed
        if '.' in parquet_file_format and not parquet_file_format.startswith(('EXTERNAL_LAKE.', 'DATA_WAREHOUSE_RC1.')):
            # File format is in external_lake database by default
            parquet_file_format = f"EXTERNAL_LAKE.{parquet_file_format}"
        
        create_stage_query = f"""
        CREATE OR REPLACE STAGE {database}.{schema}.{stage_name}
            URL = '{s3_path}'
            STORAGE_INTEGRATION = {storage_integration}
            FILE_FORMAT = {parquet_file_format};
        """
        
        logger.debug(f"Creating stage: {stage_name} with storage integration: {storage_integration}")
        self.run_query(create_stage_query, commit=True)
        
        copy_query = f"""
        COPY INTO {database}.{schema}.{table}
        FROM @{database}.{schema}.{stage_name}
        FILE_FORMAT = (FORMAT_NAME = '{parquet_file_format}')
        MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE
        ON_ERROR = 'ABORT_STATEMENT';
        """
        
        logger.debug(f"Loading data into {database}.{schema}.{table} using file format: {parquet_file_format}")
        result = self.run_query(copy_query, commit=True)
        
        drop_stage_query = f"DROP STAGE IF EXISTS {database}.{schema}.{stage_name};"
        self.run_query(drop_stage_query, commit=True)
        
        return result

    def create_table_ddl(self, schema: str, table: str, columns: Dict, database: str = None) -> str:
        """Generate CREATE TABLE DDL for Snowflake from column definitions"""
        database = database or self.database
        
        ddl = f"CREATE OR REPLACE TABLE {database}.{schema}.{table} (\n"
        
        col_definitions = []
        for col_name, col_info in columns.items():
            original_type = col_info['datatype']
            data_type = self._map_redshift_to_snowflake_type(original_type, col_name)
            # Quote column names that start with a number
            col_name_fix = col_name if re.match("^[0-9]", col_name) is None else f'"{col_name.upper()}"'
            col_definitions.append(f"    {col_name_fix} {data_type}")
        
        ddl += ",\n".join(col_definitions)
        ddl += "\n);"
        
        logger.debug(ddl)
        return ddl

    def clone_table(self, source_database, source_schema, source_table, target_schema, target_table):
        transient_query = f"""
            select is_transient
            from {source_database}.information_schema.tables
            where table_schema = '{source_schema.upper()}'
            and table_name = '{source_table.upper()}'
        """
        is_transient = bool(self.run_query(transient_query)[0][0])
        logger.info(f"Cloning table {source_database}.{source_schema}.{source_table} to {self.database}.{target_schema}.{target_table}")
        query = f"CREATE OR REPLACE {('TRANSIENT ' if is_transient else '')}TABLE {self.database}.{target_schema}.{target_table} CLONE {source_database}.{source_schema}.{source_table};"
        self.run_query(query, commit=True)

    def clone_view(self, source_database, source_schema, source_table, target_schema, target_table):
        logger.info(f"Cloning view {source_database}.{source_schema}.{source_table} to {self.database}.{target_schema}.{target_table}")
        view_ddl = self.run_query(f"SELECT GET_DDL('VIEW', '{source_database}.{source_schema}.{source_table}');")[0][0]
        self.run_query(view_ddl, use_database=self.database, use_schema=target_schema, commit=True)

    def _map_redshift_to_snowflake_type(self, redshift_type: str, column_name: str = None) -> str:
        """Map Redshift data types to Snowflake equivalents with safe length handling"""
        type_mapping = {
            'smallint': 'SMALLINT',
            'integer': 'INTEGER', 
            'int': 'INTEGER',
            'bigint': 'BIGINT',
            'decimal': 'NUMBER',
            'numeric': 'NUMBER',
            'real': 'REAL',
            'double precision': 'DOUBLE PRECISION',
            'float': 'FLOAT',
            'boolean': 'BOOLEAN',
            'char': 'CHAR',
            'varchar': 'VARCHAR',
            'character varying': 'VARCHAR',
            'text': 'TEXT',
            'date': 'DATE',
            'timestamp': 'TIMESTAMP_NTZ',
            'timestamp without time zone': 'TIMESTAMP_NTZ',
            'timestamp with time zone': 'TIMESTAMP_TZ',
            'time': 'TIME',
            'time without time zone': 'TIME',
            'time with time zone': 'TIME',
            'super': 'VARIANT',
            'json': 'VARIANT',
            'jsonb': 'VARIANT',
            'uuid': 'VARCHAR(36)',
            'double': 'DOUBLE PRECISION',
            'serial': 'INTEGER',
            'bigserial': 'BIGINT'
        }
        
        for redshift_key, snowflake_type in type_mapping.items():
            if redshift_type.lower().startswith(redshift_key):
                if snowflake_type == 'VARIANT':
                    return snowflake_type
                elif '(' in redshift_type:
                    params = redshift_type[redshift_type.find('('):]
                    
                    if snowflake_type in ['VARCHAR', 'CHAR']:
                        return self._apply_safe_string_length(snowflake_type, params, column_name)
                    
                    return snowflake_type + params
                else:
                    if snowflake_type in ['VARCHAR', 'CHAR']:
                        if column_name:
                            logger.info(f"Column '{column_name}': Setting {snowflake_type} length to 255 (no length specified)")
                        return f"{snowflake_type}(255)"
                    return snowflake_type
        
        logger.warning(f"Unknown data type '{redshift_type}', using as-is")
        return redshift_type
    
    def _apply_safe_string_length(self, snowflake_type: str, params: str, column_name: str = None) -> str:
        """Apply safe minimum length for string columns to prevent truncation errors"""
        try:
            if '(' in params and ')' in params:
                length_str = params[1:params.find(')')]
                if length_str.isdigit():
                    length = int(length_str)
                    
                    if length < 50:
                        column_info = f"Column '{column_name}': " if column_name else ""
                        logger.info(f"{column_info}Adjusting {snowflake_type} length from {length} to 50 for safety")
                        return f"{snowflake_type}(50)"
                    elif length < 255:
                        column_info = f"Column '{column_name}': " if column_name else ""
                        logger.info(f"{column_info}Adjusting {snowflake_type} length from {length} to 255 for safety")
                        return f"{snowflake_type}(255)"
                    else:
                        return snowflake_type + params
        except (ValueError, IndexError):
            pass
        
        return snowflake_type + params

