import json
import os
from pathlib import Path
import duckdb

preset = json.loads(Path(os.environ["BENCH_PRESET"]).read_text())
root = Path(os.environ.get("BENCH_DATA", "/data")) / f"tpch-sf{preset['workload']['scale_factor']}"
raw = root / "raw"
ready = raw / ".ready"
raw.mkdir(parents=True, exist_ok=True)
if not ready.exists():
    db = duckdb.connect()
    db.execute("LOAD tpch")
    db.execute(f"CALL dbgen(sf={preset['workload']['scale_factor']})")
    db.execute(f"COPY lineitem TO '{raw / 'lineitem.parquet'}' (FORMAT PARQUET)")
    ready.touch()
