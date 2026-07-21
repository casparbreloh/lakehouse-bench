import json
import os
from pathlib import Path
from pyspark.sql import SparkSession

preset = json.loads(Path(os.environ["BENCH_PRESET"]).read_text())
scale, threads = preset["workload"]["scale_factor"], preset["execution"]["threads"]
root = Path(os.environ.get("BENCH_DATA", "/data")) / f"tpch-sf{scale}"
warehouse = root / "warehouse"
if not (warehouse / "tpch" / "lineitem" / "metadata").exists():
    spark = (SparkSession.builder.master(f"local[{threads}]").appName("lakehouse-bench-setup")
        .config("spark.jars", "/opt/iceberg.jar")
        .config("spark.sql.catalog.bench", "org.apache.iceberg.spark.SparkCatalog")
        .config("spark.sql.catalog.bench.type", "hadoop")
        .config("spark.sql.catalog.bench.warehouse", str(warehouse)).getOrCreate())
    try:
        spark.sql("CREATE NAMESPACE IF NOT EXISTS bench.tpch")
        spark.read.parquet(str(root / "raw" / "lineitem.parquet")).writeTo("bench.tpch.lineitem").using("iceberg").tableProperty("format-version", "2").tableProperty("write.format.default", "parquet").createOrReplace()
    finally:
        spark.stop()
