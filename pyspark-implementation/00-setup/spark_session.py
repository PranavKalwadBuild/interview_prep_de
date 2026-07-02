"""
00-setup/spark_session.py
Shared SparkSession builder for all pyspark-implementation scripts.

Usage (at top of every pattern script):
    import sys, os
    sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '00-setup'))
    from spark_session import get_spark, stop_and_wait

Delta usage (18-delta-lake only):
    from spark_session import get_spark
    spark = get_spark("delta-lake-patterns", delta=True)
"""

import os
from pyspark.sql import SparkSession


OUTPUT_DIR = os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "..", "data", "output"
)
OUTPUT_DIR = os.path.normpath(OUTPUT_DIR)


def get_spark(app_name: str = "pyspark-patterns", delta: bool = False) -> SparkSession:
    """
    Build and return a SparkSession with Spark UI enabled.

    Parameters
    ----------
    app_name : str
        Shown in the Spark UI header and history server.
    delta : bool
        When True, adds delta-spark jars and extensions.
        Requires: pip install delta-spark

    Spark UI
    --------
    Runs at http://localhost:4040 (or 4041/4042 if 4040 is taken).
    Call stop_and_wait(spark) at the end of each script to keep
    the session alive until you finish browsing the UI.
    """
    builder = (
        SparkSession.builder
        .appName(app_name)
        .master("local[*]")
        # ── Spark UI ──────────────────────────────────────────────
        .config("spark.ui.enabled", "true")
        .config("spark.ui.port", "4040")
        .config("spark.ui.showConsoleProgress", "true")
        # ── Tuning for local / small data ─────────────────────────
        .config("spark.sql.shuffle.partitions", "4")
        .config("spark.driver.memory", "2g")
        .config("spark.sql.adaptive.enabled", "true")
        # ── Logging: suppress INFO spam ───────────────────────────
        .config("spark.driver.extraJavaOptions", "-Dlog4j.logLevel=WARN")
    )

    if delta:
        # Adjust the Scala version suffix to match your PySpark build:
        #   PySpark 3.3.x → delta-spark_2.12:2.3.0
        #   PySpark 3.4.x → delta-spark_2.12:2.4.0
        #   PySpark 3.5.x → delta-spark_2.12:3.2.0
        builder = (
            builder
            .config("spark.jars.packages", "io.delta:delta-spark_2.12:3.2.0")
            .config("spark.sql.extensions",
                    "io.delta.sql.DeltaSparkSessionExtension")
            .config("spark.sql.catalog.spark_catalog",
                    "org.apache.spark.sql.delta.catalog.DeltaCatalog")
        )

    spark = builder.getOrCreate()
    spark.sparkContext.setLogLevel("WARN")

    print(f"\n{'='*55}")
    print(f"  SparkSession ready   app={app_name}")
    print(f"  Spark UI → http://localhost:4040")
    print(f"  Spark version: {spark.version}")
    print(f"{'='*55}\n")

    return spark


def output_path(subdir: str = "") -> str:
    """
    Return an absolute path under data/output/.
    Creates the directory if it does not exist.

    Example
    -------
    output_path("parquet/employees")
    → .../pyspark-implementation/data/output/parquet/employees
    """
    path = os.path.join(OUTPUT_DIR, subdir) if subdir else OUTPUT_DIR
    os.makedirs(path, exist_ok=True)
    return path


def stop_and_wait(spark: SparkSession, port: int = 4040) -> None:
    """
    Pause execution so the Spark UI stays accessible, then stop.
    Call this as the last line of every pattern script.
    """
    print(f"\n{'─'*55}")
    print(f"  Script complete.  Spark UI → http://localhost:{port}")
    print(f"  Browse DAGs, stages, SQL plans, then press Enter.")
    print(f"{'─'*55}")
    input("  Press Enter to stop SparkSession: ")
    spark.stop()
    print("  SparkSession stopped.")
