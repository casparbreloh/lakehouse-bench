"""Generic preset-driven container runner."""
import json
import os
import subprocess
import sys
import time
from pathlib import Path

from lakehouse_bench.registry import validate_preset
from lakehouse_bench.workloads.tpch import checksum, sql


def engine_adapter(engine, scale_factor, threads):
    if engine in {"spark-local", "spark-comet-local"}:
        from lakehouse_bench.engines.spark import SparkLocal
        return SparkLocal(engine, scale_factor, threads), "tpch.lineitem"
    if engine == "datafusion":
        from lakehouse_bench.engines.datafusion import DataFusionLocal
        return DataFusionLocal(scale_factor, threads), "lineitem"
    raise ValueError(f"unknown engine: {engine}")


def smoke(preset):
    return {"status": "success", "workload": "smoke", "created_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "measurements": [{"name": "container-contract", "status": "success", "duration_ms": 0, "result_checksum": "smoke"}]}


def initialize_tpch(preset):
    scale_factor = preset["workload"]["scale_factor"]
    threads = preset["execution"]["threads"]
    data_root = Path(os.environ.get("BENCH_DATA", "/data"))
    raw_dir = data_root / f"tpch-sf{scale_factor}" / "raw"
    ready = data_root / f"tpch-sf{scale_factor}" / ".iceberg-v2-parquet-ready"
    raw_dir.mkdir(parents=True, exist_ok=True)
    if not (raw_dir / "lineitem.tbl").exists():
        subprocess.run(["cp", "/opt/tpch-kit/dbgen/dists.dss", str(raw_dir / "dists.dss")], check=True)
        subprocess.run(["/opt/tpch-kit/dbgen/dbgen", "-s", str(scale_factor), "-f", "-T", "L"], cwd=raw_dir, check=True)
    if not ready.exists():
        subprocess.run(["spark-submit", "/opt/lakehouse-bench/src/lakehouse_bench/table_formats/iceberg.py", str(scale_factor), str(threads)], check=True)
        ready.touch()


def benchmark(preset):
    execution, workload = preset["execution"], preset["workload"]
    threads = execution["threads"]
    os.environ["BENCH_THREADS"] = str(threads)
    initialize_tpch(preset)
    expected_checksum = None
    measurements = []
    for engine in preset["engines"]:
        adapter, table = engine_adapter(engine, workload["scale_factor"], threads)
        try:
            prepared = adapter.prepare(sql("q1", table))
            for _ in range(execution["warmups"]):
                adapter.execute(prepared)
            for iteration in range(1, execution["iterations"] + 1):
                started = time.perf_counter_ns()
                rows = adapter.execute(prepared)
                duration_ms = (time.perf_counter_ns() - started) / 1_000_000
                result_checksum = checksum(rows)
                if expected_checksum is None:
                    expected_checksum = result_checksum
                if result_checksum != expected_checksum:
                    raise RuntimeError(f"checksum mismatch for {engine} q1 iteration {iteration}")
                if len(rows) != 4:
                    raise RuntimeError(f"unexpected q1 row count for {engine}: {len(rows)}")
                measurements.append({"name": f"{engine}-q1-iteration-{iteration}", "status": "success", "duration_ms": duration_ms, "result_checksum": result_checksum, "engine": engine, "query": "q1", "iteration": iteration, "row_count": len(rows)})
        finally:
            adapter.close()
    return {"status": "success", "workload": "tpch", "table": {"format": "iceberg", "format_version": 2, "file_format": "parquet"}, "result_checksum": expected_checksum, "measurements": measurements}


def main():
    preset_path = Path(os.environ.get("BENCH_PRESET", "/workspace/presets/smoke.json"))
    try:
        preset = json.loads(preset_path.read_text())
        runner = validate_preset(preset)
        result = smoke(preset) if runner == "smoke" else benchmark(preset)
    except Exception as error:
        print(f"benchmark failed: {error}", file=sys.stderr)
        raise
    Path("/out").mkdir(parents=True, exist_ok=True)
    Path("/out/result.json").write_text(json.dumps(result))


if __name__ == "__main__":
    main()
