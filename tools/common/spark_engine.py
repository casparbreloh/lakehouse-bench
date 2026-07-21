import hashlib
import json
import os
import time
from decimal import Decimal
from pathlib import Path
from pyspark.sql import SparkSession

preset = json.loads(Path(os.environ["BENCH_PRESET"]).read_text())
engine = os.environ["BENCH_ENGINE"]
scale, execution = preset["workload"]["scale_factor"], preset["execution"]
warehouse = Path(os.environ.get("BENCH_DATA", "/data")) / f"tpch-sf{scale}" / "warehouse"
builder = (SparkSession.builder.master(f"local[{execution['threads']}]").appName(f"lakehouse-bench-{engine}")
    .config("spark.jars", "/opt/iceberg.jar" + (",/opt/comet.jar" if engine == "spark-comet-local" else ""))
    .config("spark.sql.catalog.bench", "org.apache.iceberg.spark.SparkCatalog")
    .config("spark.sql.catalog.bench.type", "hadoop").config("spark.sql.catalog.bench.warehouse", str(warehouse))
    .config("spark.sql.shuffle.partitions", str(execution["threads"])))
if engine == "spark-comet-local":
    builder = (builder.config("spark.plugins", "org.apache.spark.CometPlugin")
        .config("spark.shuffle.manager", "org.apache.spark.sql.comet.execution.shuffle.CometShuffleManager")
        .config("spark.comet.enabled", "true").config("spark.comet.exec.enabled", "true")
        .config("spark.comet.scan.enabled", "true").config("spark.comet.scan.icebergNative.enabled", "true")
        .config("spark.memory.offHeap.enabled", "true").config("spark.memory.offHeap.size", "1g"))
spark = builder.getOrCreate()
sql = """SELECT l_returnflag, l_linestatus, sum(l_quantity), sum(l_extendedprice), sum(l_extendedprice * (1 - l_discount)), sum(l_extendedprice * (1 - l_discount) * (1 + l_tax)), avg(l_quantity), avg(l_extendedprice), avg(l_discount), count(*) FROM bench.tpch.lineitem WHERE l_shipdate <= DATE '1998-09-02' GROUP BY l_returnflag, l_linestatus ORDER BY l_returnflag, l_linestatus"""
def checksum(rows):
    def value(v): return format(v.normalize(), "f") if isinstance(v, Decimal) else str(v)
    return hashlib.sha256(json.dumps([[value(v) for v in row] for row in rows], separators=(",", ":")).encode()).hexdigest()
try:
    query = spark.sql(sql)
    if engine == "spark-comet-local" and "Comet" not in query._jdf.queryExecution().executedPlan().toString():
        raise RuntimeError("Comet physical-plan validation failed: no Comet operator found")
    for _ in range(execution["warmups"]): query.collect()
    measurements = []
    for iteration in range(1, execution["iterations"] + 1):
        start = time.perf_counter_ns(); rows = [tuple(row) for row in query.collect()]
        measurements.append({"iteration": iteration, "duration_ms": (time.perf_counter_ns() - start) / 1e6, "result_checksum": checksum(rows)})
    Path("/out").mkdir(exist_ok=True)
    Path(f"/out/{engine}.json").write_text(json.dumps({"engine": engine, "status": "success", "measurements": measurements}))
finally:
    spark.stop()
