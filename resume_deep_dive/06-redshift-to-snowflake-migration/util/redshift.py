import redshift_connector
import os
from util import queries

from typing import Dict, List, AnyStr

class RedshiftClient():
    def __init__(self):
        self.host=os.environ.get("DBT_WH_REDSHIFT_HOST")
        self.port=os.environ.get("DBT_WH_REDSHIFT_PORT")
        self.database=os.environ.get("DBT_WH_REDSHIFT_DB")
        self.user=os.environ.get("DBT_WH_REDSHIFT_USER")
        self.password=os.environ.get("DBT_WH_REDSHIFT_PW")
        self.connection = None

    def connect(self):
        self.connection = redshift_connector.connect(
            host=self.host,
            port=self.port,
            database=self.database,
            user=self.user,
            password=self.password,
        )

        return self.connection
    
    def run_query(self, query: str, commit: bool = False):
        if self.connection is None:
            self.connect()

        res = self.connection.run(query)

        if commit:
            self.connection.commit()
        
        return res
        

    def get_table_definition(self, schema, table, database=None) -> Dict[str, Dict[str, Dict[str, AnyStr]]]:
        database = database or self.database
        col_query = queries.table_definition_query(database=database, schema=schema, table=table)
        tbl_query = queries.table_description_query(database=database, schema=schema, table=table)
        cols = self.run_query(col_query)
        dsc = self.run_query(tbl_query)

        ret = {"type": dsc[0][0], "description": dsc[0][1]}
        
        columns = {}

        for col in cols:
            if col[3]:
                dt = f"{col[2]}({col[3]})"
            else:
                dt = col[2]
            columns[col[1]] = {"datatype": dt, "position": col[0]}
            if col[4]:
                columns[col[1]].update({"description": col[4]})

        ret["columns"] = columns

        return ret

    def get_tables(self, schema, pattern, database=None):
        database = database or self.database
        query = queries.tables_in_schema_query(database=database, schema=schema, pattern=pattern)

        res = self.run_query(query)

        return res

    def table_exists(self, schema, table, database=None):
        database = database or self.database
        query = queries.tables_in_schema_query(database=database, schema=schema, pattern=table)

        res = self.run_query(query)

        return len(res) > 0

    def create_table(self, schema, table, columns, database=None):
        database = database or self.database
        query = queries.create_table_query(identifier=f"{database}.{schema}.{table}", columns=columns)

        print("Executing DDL:\n" + query)
        res = self.run_query(query, commit=True)

        return res
    
    def add_column(self, schema, table, name, datatype, database=None):
        database = database or self.database
        query = queries.add_column_query(identifier=f"{database}.{schema}.{table}", column_name=name, column_datatype=datatype)

        print("Executing DDL:\n" + query)
        res = self.run_query(query, commit=True)

        return res
    
    def copy_table(self, source_table, target_table, overwrite=False):
        query_0 = f"DROP TABLE IF EXISTS {target_table};"
        query_1 = f"CREATE TABLE {target_table} (LIKE {source_table} INCLUDING DEFAULTS);"
        query_2 = f"INSERT INTO {target_table} SELECT * FROM {source_table};"

        print(f"Copying {source_table} to {target_table}")

        if overwrite:
            confirm = input(f"\nDrop if exists {target_table}? Type the full identifier to confirm:")
            if confirm != target_table:
                return
            res = self.run_query(query_0)
        res = self.run_query(query_1)
        res = self.run_query(query_2)
        self.connection.commit()

        return res