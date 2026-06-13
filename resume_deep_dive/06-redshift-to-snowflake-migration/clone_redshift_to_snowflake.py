import os
import sys
import uuid
import click
import logging
from datetime import datetime
from typing import Optional, Dict, Any

sys.path.append(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from util import redshift, dbt
from util.snowflake import SnowflakeClient

logging.basicConfig(level=logging.INFO, format='%(message)s')
logger = logging.getLogger(__name__)

class RedshiftToSnowflakeMigrator:
    
    def __init__(self, s3_bucket: str, s3_prefix: str = "redshift-to-snowflake-migration", target_database: str = None,
                 date_column: str = None, start_date: str = None, end_date: str = None, limit: int = None,
                 snowflake_client: SnowflakeClient = None):
        self.redshift_client = redshift.RedshiftClient()
        self.snowflake_client = snowflake_client or SnowflakeClient()
        self.s3_bucket = s3_bucket
        self.s3_prefix = s3_prefix
        self.migration_id = str(uuid.uuid4())
        self.date_column = date_column
        self.start_date = start_date
        self.end_date = end_date
        self.limit = limit
        
        if target_database and not target_database.upper().startswith('DEV_'):
            logger.warning(f"Loading data to non-development database '{target_database}'. Ensure this is intended for production use.")
        
        self.target_database = target_database
        
        try:
            logger.info("Connecting to Redshift...")
            self.redshift_client.connect()
            logger.info("Connected to Redshift")
            
            if snowflake_client is None:
                logger.info("Connecting to Snowflake...")
                self.snowflake_client.connect()
                logger.info("Connected to Snowflake")

        except Exception as e:
            logger.error(f"Failed to initialize connections: {str(e)}")
            raise
        
    def get_s3_path(self, schema: str, table: str) -> str:
        timestamp = datetime.now().strftime("%Y%m%dT%H%M%S")
        if self.s3_prefix:
            return f"s3://{self.s3_bucket}/{self.s3_prefix}/{schema}/{table}/{timestamp}/"
        else:
            return f"s3://{self.s3_bucket}/snowflake_migration/redshift_transfer/{schema}/{table}/{timestamp}/"
    
    def unload_redshift_table(self, source_schema: str, source_table: str, s3_path: str) -> bool:
        try:
            logger.info(f"Unloading data from Redshift: {source_schema}.{source_table}")
            
            iam_role = os.environ.get("DBT_WH_REDSHIFT_IAM_ROLE") or "arn:aws:iam::226779328744:role/airflow"
            
            credentials_clause = f"IAM_ROLE '{iam_role}'"
            
            base_query = f"SELECT * FROM {source_schema}.{source_table}"
            
            if self.date_column and (self.start_date or self.end_date):
                where_conditions = []
                if self.start_date:
                    where_conditions.append(f"{self.date_column} >= '{self.start_date}'")
                if self.end_date:
                    where_conditions.append(f"{self.date_column} <= '{self.end_date}'")
                
                where_clause = " WHERE " + " AND ".join(where_conditions)
                base_query += where_clause
                
                logger.info(f"Applying date filter: {where_clause}")
            
            if self.limit is not None:
                base_query = f"SELECT * FROM ({base_query} LIMIT {self.limit})"
            
            if credentials_clause:
                unload_query = f"""
                UNLOAD ('{base_query.replace("'", "''")}')
                TO '{s3_path}'
                {credentials_clause}
                FORMAT PARQUET
                ALLOWOVERWRITE;
                """
            else:
                unload_query = f"""
                UNLOAD ('{base_query.replace("'", "''")}')
                TO '{s3_path}'
                FORMAT PARQUET
                ALLOWOVERWRITE;
                """
            
            result = self.redshift_client.run_query(unload_query, commit=True)
            logger.info("Data unloaded to S3 successfully")
            return True
            
        except Exception as e:
            logger.error(f"UNLOAD failed for {source_schema}.{source_table}: {str(e)}")
            return False
    
    def validate_data_types(self, source_table_def: Dict) -> Dict[str, Any]:
        validation_result = {
            "valid": True,
            "warnings": [],
            "errors": []
        }
        
        for col_name, col_info in source_table_def["columns"].items():
            original_type = col_info['datatype']
            try:
                mapped_type = self.snowflake_client._map_redshift_to_snowflake_type(original_type, col_name)
                if mapped_type == original_type and original_type.lower() not in ['varchar', 'char', 'text', 'integer', 'int', 'bigint', 'smallint', 'decimal', 'numeric', 'real', 'float', 'boolean', 'date', 'timestamp', 'time', 'super', 'json', 'jsonb', 'uuid', 'double', 'serial', 'bigserial']:
                    validation_result["warnings"].append(f"Column '{col_name}' with type '{original_type}' may not be optimally mapped")
            except Exception as e:
                validation_result["errors"].append(f"Column '{col_name}' with type '{original_type}': {str(e)}")
                validation_result["valid"] = False
        
        return validation_result

    def create_snowflake_table(self, target_schema: str, target_table: str, source_table_def: Dict) -> bool:
        try:
            logger.info(f"Creating Snowflake table: {target_schema}.{target_table}")
            
            validation = self.validate_data_types(source_table_def)
            if validation["warnings"]:
                logger.info("Data type mapping warnings:")
                for warning in validation["warnings"]:
                    logger.info(f"  - {warning}")
            
            if not validation["valid"]:
                logger.error("Data type validation failed:")
                for error in validation["errors"]:
                    logger.error(f"  - {error}")
                return False
            
            create_schema_query = f"CREATE SCHEMA IF NOT EXISTS {target_schema};"
            self.snowflake_client.run_query(create_schema_query, commit=True)

            if self.snowflake_client.view_exists(target_schema, target_table):
                logger.info(f"Dropping existing Snowflake view: {target_schema}.{target_table}")
                drop_view_query = f"DROP VIEW IF EXISTS {target_schema}.{target_table};"
                self.snowflake_client.run_query(drop_view_query, commit=True)
            
            ddl = self.snowflake_client.create_table_ddl(target_schema, target_table, source_table_def["columns"])
            self.snowflake_client.run_query(ddl, commit=True)
            logger.info(f"Snowflake table created: {target_schema}.{target_table}")
            return True
            
        except Exception as e:
            error_msg = str(e)
            if "Unsupported data type" in error_msg:
                logger.error(f"Table creation failed for {target_schema}.{target_table}: {error_msg}")
                logger.error("This may be due to unsupported Redshift data types. Check the data type mapping in util/snowflake.py")
                logger.error("Available Redshift data types: SUPER, JSON, JSONB, etc. are mapped to Snowflake VARIANT")
            else:
                logger.error(f"Table creation failed for {target_schema}.{target_table}: {error_msg}")
            return False
    
    def load_snowflake_table(self, target_schema: str, target_table: str, s3_path: str) -> bool:
        try:
            logger.info(f"Loading data from S3 to Snowflake: {target_schema}.{target_table}")
            
            result = self.snowflake_client.create_table_from_s3(
                schema=target_schema,
                table=target_table,
                s3_path=s3_path,
                file_format="PARQUET",
                database=self.target_database
            )
            
            logger.info("Data loaded successfully to Snowflake")
            return True
            
        except Exception as e:
            logger.error(f"Data loading failed for {target_schema}.{target_table}: {str(e)}")
            return False
    
    def migrate_table_to_sf(self, source_schema: str, source_table: str, 
                     target_schema: Optional[str] = None, target_table: Optional[str] = None) -> Dict[str, Any]:
        """
        Migrate a single table from Redshift to Snowflake
        """
        target_schema = target_schema or source_schema
        target_table = target_table or source_table
        
        migration_result = {
            "source": f"{source_schema}.{source_table}",
            "target": f"{target_schema}.{target_table}",
            "success": False,
            "s3_path": None,
            "steps": {
                "table_analysis": False,
                "unload": False,
                "create_table": False,
                "load_data": False
            },
            "errors": []
        }
        
        try:
            logger.info(f"Starting migration: {source_schema}.{source_table} -> {target_schema}.{target_table}")
            
            logger.info("Analyzing source table structure...")
            source_table_def = self.redshift_client.get_table_definition(source_schema, source_table)
            
            if source_table_def["type"] == "VIEW":
                error_msg = "Cannot migrate views - only tables are supported"
                logger.error(error_msg)
                migration_result["errors"].append(error_msg)
                return migration_result
            
            migration_result["steps"]["table_analysis"] = True
            logger.info(f"Source table analyzed: {len(source_table_def['columns'])} columns found")
            
            s3_path = self.get_s3_path(source_schema, source_table)
            migration_result["s3_path"] = s3_path
            
            if self.unload_redshift_table(source_schema, source_table, s3_path):
                migration_result["steps"]["unload"] = True
            else:
                migration_result["errors"].append("Failed to unload data from Redshift")
                return migration_result
            
            if self.create_snowflake_table(target_schema, target_table, source_table_def):
                migration_result["steps"]["create_table"] = True
            else:
                migration_result["errors"].append("Failed to create Snowflake table")
                return migration_result
            if self.load_snowflake_table(target_schema, target_table, s3_path):
                migration_result["steps"]["load_data"] = True
                migration_result["success"] = True
            else:
                migration_result["errors"].append("Failed to load data into Snowflake")
                return migration_result
            
            validation = self.validate_migration(source_schema, source_table, target_schema, target_table)
            if self.limit is None and not validation["counts_match"]:
                logger.warning("Row counts don't match - investigation required")
            
            logger.info(f"Migration completed successfully: {source_schema}.{source_table} -> {self.snowflake_client.database}.{target_schema}.{target_table}")
            
        except Exception as e:
            error_msg = f"Unexpected error during migration: {str(e)}"
            logger.error(error_msg)
            migration_result["errors"].append(error_msg)
        
        return migration_result
    
    def validate_migration(self, source_schema: str, source_table: str, 
                          target_schema: str, target_table: str) -> Dict[str, Any]:
        validation_result = {
            "source_count": 0,
            "target_count": 0,
            "counts_match": False,
            "errors": []
        }
        
        try:
            logger.info("Validating migration by comparing row counts...")
            
            base_query = f"SELECT COUNT(*) FROM {source_schema}.{source_table}"
            
            if self.date_column and (self.start_date or self.end_date):
                where_conditions = []
                if self.start_date:
                    where_conditions.append(f"{self.date_column} >= '{self.start_date}'")
                if self.end_date:
                    where_conditions.append(f"{self.date_column} <= '{self.end_date}'")
                
                where_clause = " WHERE " + " AND ".join(where_conditions)
                base_query += where_clause
                logger.info(f"Applying date filter to validation: {where_clause}")
            
            redshift_count_query = f"{base_query};"
            redshift_result = self.redshift_client.run_query(redshift_count_query)
            
            if not redshift_result or len(redshift_result) == 0 or len(redshift_result[0]) == 0:
                raise ValueError("No results returned from Redshift count query")
            validation_result["source_count"] = redshift_result[0][0]
            
            snowflake_count_query = f"SELECT COUNT(*) FROM {target_schema}.{target_table};"
            snowflake_result = self.snowflake_client.run_query(snowflake_count_query)
            
            if not snowflake_result or len(snowflake_result) == 0 or len(snowflake_result[0]) == 0:
                raise ValueError("No results returned from Snowflake count query")
            validation_result["target_count"] = snowflake_result[0][0]
            
            validation_result["counts_match"] = validation_result["source_count"] == validation_result["target_count"]
            
            if validation_result["counts_match"]:
                logger.info(f"Validation successful: {validation_result['source_count']:,} rows match between source and target")
            else:
                logger.warning(f"Validation failed - Source: {validation_result['source_count']:,} rows, Target: {validation_result['target_count']:,} rows")
            
        except Exception as e:
            error_msg = f"Validation error: {str(e)}"
            logger.error(error_msg)
            validation_result["errors"].append(error_msg)
        
        return validation_result

    def analyze_dbt_model(self, model_name: str, manifest) -> Dict[str, Any]:
        """
        Analyze a dbt model to determine its materialization and dependencies
        """
        node = manifest.nodes.get(f"model.gusto_warehouse.{model_name}")
        if not node:
            raise ValueError(f"Model '{model_name}' not found in dbt manifest")
        
        model_info = {
            "name": model_name,
            "materialization": node.config.materialized,
            "schema": node.schema,
            "alias": node.alias,
            "depends_on": node.depends_on.nodes if hasattr(node.depends_on, 'nodes') else [],
            "source_tables": []
        }
        
        for dep in model_info["depends_on"]:
            if dep.startswith("source."):
                parts = dep.split(".")
                if len(parts) >= 4:
                    source_name = parts[2]
                    table_name = parts[3]
                    
                    source_key = f"source.gusto_warehouse.{source_name}.{table_name}"
                    source_node = manifest.sources.get(source_key)
                    
                    if source_node:
                        source_schema = source_node.schema
                        source_identifier = source_node.identifier or table_name
                        
                        model_info["source_tables"].append({
                            "schema": source_schema,
                            "table": source_identifier,
                            "full_name": f"{source_schema}.{source_identifier}"
                        })
                    else:
                        logger.warning(f"Source {source_key} not found in manifest")
        
        return model_info
    
    def handle_view_migration(self, model_info: Dict[str, Any]) -> bool:
        if model_info["materialization"] != "view":
            return True
        
        logger.info(f"Model '{model_info['name']}' is materialized as a VIEW")
        
        if not model_info["source_tables"]:
            logger.warning("No source tables detected for this view. Skipping view migration.")
            logger.info("Views cannot be directly migrated. Please migrate the underlying tables first.")
            return False
        
        logger.info("Auto-migrating source tables for base model:")
        for i, source in enumerate(model_info["source_tables"], 1):
            logger.info(f"  {i}. {source['full_name']}")
        
        return True


def migrate_model_to_sf_by_name(model: str, snapshot: str, s3_bucket: str, s3_prefix: str = None,
                         target_database: str = None, target_schema: str = None, target_table: str = None,
                         date_column: str = None, start_date: str = None, end_date: str = None):
    try:
        manifest = dbt.load_manifest(target="prod")
        
        ref = model or snapshot
        node_type = "model" if model else "snapshot"
        
        if snapshot:
            source_node = manifest.nodes.get(f"snapshot.gusto_warehouse.{ref}")
            if not source_node:
                raise ValueError(f"Snapshot '{ref}' not found in dbt manifest")
            
            source_schema = source_node.schema
            source_table = source_node.alias
            
            logger.info(f"Found snapshot: {source_schema}.{source_table}")
            
            migrator = RedshiftToSnowflakeMigrator(
                s3_bucket=s3_bucket, 
                s3_prefix=s3_prefix, 
                target_database=target_database,
                date_column=date_column,
                start_date=start_date,
                end_date=end_date
            )
            
            result = migrator.migrate_table_to_sf(
                source_schema=source_schema,
                source_table=source_table,
                target_schema=target_schema,
                target_table=target_table
            )
            
            return result
        
        if model:
            migrator = RedshiftToSnowflakeMigrator(
                s3_bucket=s3_bucket, 
                s3_prefix=s3_prefix, 
                target_database=target_database,
                date_column=date_column,
                start_date=start_date,
                end_date=end_date
            )
            
            model_info = migrator.analyze_dbt_model(model, manifest)
            
            logger.info(f"Found model '{model}' with materialization: {model_info['materialization']}")
            
            migrator.handle_view_migration(model_info)
            if model_info["materialization"] == "view":
                results = []
                
                logger.info("Migrating source tables from Redshift:")
                for source in model_info["source_tables"]:
                    logger.info(f"Migrating source table: {source['full_name']}")
                    result = migrator.migrate_table_to_sf(
                        source_schema=source["schema"],
                        source_table=source["table"],
                        target_schema=target_schema or source["schema"],
                        target_table=None
                    )
                    results.append(result)
                
                success_count = sum(1 for r in results if r["success"])
                return {
                    "success": success_count == len(results),
                    "migrated_tables": len(results),
                    "successful_migrations": success_count,
                    "results": results
                }
            
            else:
                source_schema = model_info["schema"]
                source_table = model_info["alias"]
                
                result = migrator.migrate_table_to_sf(
                    source_schema=source_schema,
                    source_table=source_table,
                    target_schema=target_schema,
                    target_table=target_table
                )
                
                return result
                
    except Exception as e:
        logger.error(f"Migration failed: {str(e)}")
        return {"success": False, "error": str(e)}


@click.group()
def clickCloneRedshiftToSnowflake():
    pass


@clickCloneRedshiftToSnowflake.command(help="Migrate a dbt model from Redshift to Snowflake")
@click.option("--model", type=str, help="Model name to migrate")
@click.option("--snapshot", type=str, help="Snapshot name to migrate")
@click.option("--s3-bucket", type=str, required=True, help="S3 bucket for temporary storage")
@click.option("--s3-prefix", type=str, help="S3 prefix/path for data organization (e.g., 'migrations/redshift')")
@click.option("--target-database", type=str, help="Target database in Snowflake (e.g., 'data_warehouse_rc1')")
@click.option("--target-schema", type=str, help="Target schema in Snowflake (defaults to source schema)")
@click.option("--target-table", type=str, help="Target table name in Snowflake (defaults to source table)")
@click.option("--date-column", type=str, help="Date column name for filtering data (e.g., 'created_at', 'updated_at')")
@click.option("--start-date", type=str, help="Start date for filtering (YYYY-MM-DD format)")
@click.option("--end-date", type=str, help="End date for filtering (YYYY-MM-DD format)")
@click.option("--verbose", "-v", is_flag=True, help="Enable verbose logging")
def migrate_model_to_sf(model, snapshot, s3_bucket, s3_prefix, target_database, target_schema, target_table, 
                  date_column, start_date, end_date, verbose):
    logging.basicConfig(level=logging.INFO, format='[%(levelname)s] %(filename)s:%(message)s', force=True)
    if verbose:
        logging.getLogger().setLevel(logging.DEBUG)
    
    if not model and not snapshot:
        raise click.UsageError("Must specify either --model or --snapshot")
    
    if model and snapshot:
        raise click.UsageError("Cannot specify both --model and --snapshot")
    
    result = migrate_model_to_sf_by_name(
        model=model,
        snapshot=snapshot, 
        s3_bucket=s3_bucket,
        s3_prefix=s3_prefix,
        target_database=target_database,
        target_schema=target_schema,
        target_table=target_table,
        date_column=date_column,
        start_date=start_date,
        end_date=end_date
    )
    
    if result["success"]:
        logger.info("Migration completed successfully")
    else:
        logger.error("Migration failed:")
        if "errors" in result:
            for error in result["errors"]:
                logger.error(f"  - {error}")
        elif "error" in result:
            logger.error(f"  - {result['error']}")
        else:
            logger.error("  - Unknown error occurred")
        sys.exit(1)


@clickCloneRedshiftToSnowflake.command(help="Migrate a table directly by schema and table name")
@click.option("--source-schema", type=str, required=True, help="Source schema in Redshift")
@click.option("--source-table", type=str, required=True, help="Source table in Redshift")
@click.option("--s3-bucket", type=str, required=True, help="S3 bucket for temporary storage")
@click.option("--s3-prefix", type=str, help="S3 prefix/path for data organization (e.g., 'migrations/redshift')")
@click.option("--target-database", type=str, help="Target database in Snowflake (e.g., 'data_warehouse_rc1')")
@click.option("--target-schema", type=str, help="Target schema in Snowflake (defaults to source schema)")
@click.option("--target-table", type=str, help="Target table name in Snowflake (defaults to source table)")
@click.option("--date-column", type=str, help="Date column name for filtering data (e.g., 'created_at', 'updated_at')")
@click.option("--start-date", type=str, help="Start date for filtering (YYYY-MM-DD format)")
@click.option("--end-date", type=str, help="End date for filtering (YYYY-MM-DD format)")
@click.option("--validate/--no-validate", default=True, help="Validate migration by comparing row counts")
@click.option("--verbose", "-v", is_flag=True, help="Enable verbose logging")
def migrate_table_to_sf(source_schema, source_table, s3_bucket, s3_prefix, target_database, target_schema, target_table, 
                  date_column, start_date, end_date, validate, verbose):
    logging.basicConfig(level=logging.INFO, format='[%(levelname)s] %(filename)s:%(message)s', force=True)
    if verbose:
        logging.getLogger().setLevel(logging.DEBUG)
    
    migrator = RedshiftToSnowflakeMigrator(
        s3_bucket=s3_bucket, 
        s3_prefix=s3_prefix, 
        target_database=target_database,
        date_column=date_column,
        start_date=start_date,
        end_date=end_date
    )
    
    result = migrator.migrate_table_to_sf(
        source_schema=source_schema,
        source_table=source_table,
        target_schema=target_schema,
        target_table=target_table
    )
    
    if result["success"] and validate:
        target_schema_final = target_schema or source_schema
        target_table_final = target_table or source_table
        
        validation = migrator.validate_migration(
            source_schema, source_table,
            target_schema_final, target_table_final
        )
        
        if not validation["counts_match"]:
            logger.warning("Row counts don't match - investigation required")
    
    if result["success"]:
        logger.info("Migration completed successfully")
    else:
        logger.error("Migration failed:")
        if "errors" in result:
            for error in result["errors"]:
                logger.error(f"  - {error}")
        elif "error" in result:
            logger.error(f"  - {result['error']}")
        else:
            logger.error("  - Unknown error occurred")
        sys.exit(1)


if __name__ == "__main__":
    clickCloneRedshiftToSnowflake() 
