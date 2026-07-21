import hashlib
import json
import os
import time
from decimal import Decimal
from pathlib import Path

preset = json.loads(Path(os.environ["BENCH_PRESET"]).read_text())
engine, execution = os.environ["BENCH_ENGINE"], preset["execution"]
os.environ["RAYON_NUM_THREADS"] = str(execution["threads"])
from datafusion import SessionConfig, SessionContext
from pyiceberg.catalog import load_catalog
scale = preset["workload"]["scale_factor"]
warehouse = Path(os.environ.get("BENCH_DATA", "/data")) / f"tpch-sf{scale}" / "warehouse"
context = SessionContext(SessionConfig().with_target_partitions(execution["threads"]))
context.register_table_provider("lineitem", load_catalog("bench", type="hadoop", warehouse=f"file://{warehouse}").load_table("tpch.lineitem"))
sql = """SELECT l_returnflag, l_linestatus, sum(l_quantity), sum(l_extendedprice), sum(l_extendedprice * (1 - l_discount)), sum(l_extendedprice * (1 - l_discount) * (1 + l_tax)), avg(l_quantity), avg(l_extendedprice), avg(l_discount), count(*) FROM lineitem WHERE l_shipdate <= DATE '1998-09-02' GROUP BY l_returnflag, l_linestatus ORDER BY l_returnflag, l_linestatus"""
def checksum(rows):
    def value(v): return format(v.normalize(), "f") if isinstance(v, Decimal) else str(v)
    return hashlib.sha256(json.dumps([[value(v) for v in row] for row in rows], separators=(",", ":")).encode()).hexdigest()
query = context.sql(sql)
def execute():
    rows = []
    for batch in query.collect(): rows.extend(tuple(record.values()) for record in batch.to_pylist())
    return rows
for _ in range(execution["warmups"]): execute()
measurements = []
for iteration in range(1, execution["iterations"] + 1):
    start = time.perf_counter_ns(); rows = execute()
    measurements.append({"iteration": iteration, "duration_ms": (time.perf_counter_ns() - start) / 1e6, "result_checksum": checksum(rows)})
Path("/out").mkdir(exist_ok=True)
Path(f"/out/{engine}.json").write_text(json.dumps({"engine": engine, "status": "success", "measurements": measurements}))
