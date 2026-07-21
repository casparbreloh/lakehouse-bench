"""Spark local engine adapters."""
from pyspark.sql import SparkSession

from lakehouse_bench.table_formats.iceberg import spark_catalog


class SparkLocal:
    def __init__(self, engine, scale_factor, threads):
        self.engine = engine
        builder = spark_catalog(
            SparkSession.builder.master(f"local[{threads}]").appName(f"lakehouse-bench-{engine}"),
            scale_factor,
        ).config("spark.sql.shuffle.partitions", str(threads))
        if engine == "spark-comet-local":
            builder = (builder
                .config("spark.plugins", "org.apache.spark.CometPlugin")
                .config("spark.shuffle.manager", "org.apache.spark.sql.comet.execution.shuffle.CometShuffleManager")
                .config("spark.comet.enabled", "true")
                .config("spark.comet.exec.enabled", "true")
                .config("spark.comet.scan.enabled", "true")
                .config("spark.comet.scan.icebergNative.enabled", "true")
                .config("spark.comet.explainFallback.enabled", "true")
                .config("spark.memory.offHeap.enabled", "true")
                .config("spark.memory.offHeap.size", "1g"))
        self.spark = builder.getOrCreate()

    def prepare(self, query):
        return self.spark.sql(query)

    def execute(self, prepared):
        if self.engine == "spark-comet-local":
            plan = prepared._jdf.queryExecution().executedPlan().toString()
            if "Comet" not in plan:
                raise RuntimeError("Comet physical-plan validation failed: no Comet operator found")
        return [tuple(row) for row in prepared.collect()]

    def close(self):
        self.spark.stop()
