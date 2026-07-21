"""Supported reusable benchmark definitions and preset validation."""

ENGINES = frozenset({"spark-local", "datafusion", "spark-comet-local"})
STORAGES = frozenset({("iceberg", "parquet")})


def validate_preset(preset):
    """Reject unsupported combinations rather than composing arbitrary adapters."""
    workload = preset["workload"]
    if workload["name"] == "smoke":
        if "storage" in preset or "engines" in preset:
            raise ValueError("smoke does not select storage or engines")
        if preset["profile"] != "smoke" or preset["topology"] != "single-node":
            raise ValueError("smoke requires profile smoke and single-node topology")
        return "smoke"

    if workload["name"] != "tpch":
        raise ValueError(f"unsupported workload: {workload['name']}")
    storage = preset.get("storage", {})
    combination = (storage.get("table_format"), storage.get("file_format"))
    if combination not in STORAGES:
        raise ValueError("unsupported storage combination; supported: iceberg/parquet")
    engines = preset.get("engines", [])
    if not engines or set(engines) - ENGINES:
        raise ValueError("unsupported engine selection")
    if workload["queries"] != ["q1"]:
        raise ValueError("TPC-H currently supports exactly queries=[\"q1\"]")
    if preset["profile"] != "benchmark" or preset["topology"] != "single-node":
        raise ValueError("local TPC-H requires profile benchmark and single-node topology")
    return "benchmark"
