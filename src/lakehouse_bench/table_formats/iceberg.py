"""Iceberg v2 tables backed by Parquet in a local Hadoop catalog."""
import os
import sys
from pathlib import Path

from pyspark.sql import SparkSession
from pyspark.sql.types import (
    DateType, DecimalType, IntegerType, StringType, StructField, StructType,
)

CATALOG = "bench"
NAMESPACE = "tpch"
TABLE = "lineitem"


def data_root():
    return Path(os.environ.get("BENCH_DATA", "/data"))


def warehouse(scale_factor):
    return data_root() / f"tpch-sf{scale_factor}" / "warehouse"


def table_name():
    return f"{CATALOG}.{NAMESPACE}.{TABLE}"


def spark_catalog(builder, scale_factor):
    return (builder
        .config(f"spark.sql.catalog.{CATALOG}", "org.apache.iceberg.spark.SparkCatalog")
        .config(f"spark.sql.catalog.{CATALOG}.type", "hadoop")
        .config(f"spark.sql.catalog.{CATALOG}.warehouse", str(warehouse(scale_factor)))
        .config("spark.sql.defaultCatalog", CATALOG))


def lineitem_schema():
    return StructType([
        StructField("l_orderkey", IntegerType(), False),
        StructField("l_partkey", IntegerType(), False),
        StructField("l_suppkey", IntegerType(), False),
        StructField("l_linenumber", IntegerType(), False),
        StructField("l_quantity", DecimalType(15, 2), False),
        StructField("l_extendedprice", DecimalType(15, 2), False),
        StructField("l_discount", DecimalType(15, 2), False),
        StructField("l_tax", DecimalType(15, 2), False),
        StructField("l_returnflag", StringType(), False),
        StructField("l_linestatus", StringType(), False),
        StructField("l_shipdate", DateType(), False),
        StructField("l_commitdate", DateType(), False),
        StructField("l_receiptdate", DateType(), False),
        StructField("l_shipinstruct", StringType(), False),
        StructField("l_shipmode", StringType(), False),
        StructField("l_comment", StringType(), False),
    ])


def initialize(scale_factor, threads):
    raw_dir = data_root() / f"tpch-sf{scale_factor}" / "raw"
    lineitem = raw_dir / "lineitem.tbl"
    if not lineitem.exists():
        raise SystemExit(f"missing dbgen output: {lineitem}")
    spark = spark_catalog(
        SparkSession.builder.master(f"local[{threads}]").appName("lakehouse-bench-iceberg-initialize"),
        scale_factor,
    ).getOrCreate()
    try:
        source = spark.read.option("sep", "|").schema(lineitem_schema()).csv(str(lineitem))
        spark.sql(f"CREATE NAMESPACE IF NOT EXISTS {CATALOG}.{NAMESPACE}")
        spark.sql(f"DROP TABLE IF EXISTS {table_name()}")
        source.writeTo(table_name()).using("iceberg") \
            .tableProperty("format-version", "2") \
            .tableProperty("write.format.default", "parquet").create()
    finally:
        spark.stop()


if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit("usage: iceberg.py SCALE_FACTOR BENCH_THREADS")
    initialize(int(sys.argv[1]), int(sys.argv[2]))
