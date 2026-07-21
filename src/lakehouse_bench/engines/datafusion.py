"""Native DataFusion adapter for Iceberg tables."""
import os

# DataFusion uses Rayon for its native execution pool. Set this before importing
# datafusion so it receives the same single-node allocation as Spark.
os.environ["RAYON_NUM_THREADS"] = os.environ["BENCH_THREADS"]

from datafusion import SessionConfig, SessionContext
from pyiceberg.catalog import load_catalog

from lakehouse_bench.table_formats.iceberg import NAMESPACE, TABLE, warehouse


class DataFusionLocal:
    def __init__(self, scale_factor, threads):
        config = SessionConfig().with_target_partitions(threads)
        self.context = SessionContext(config)
        table_warehouse = warehouse(scale_factor)
        if not table_warehouse.exists():
            raise RuntimeError(f"Iceberg warehouse does not exist: {table_warehouse}")
        catalog = load_catalog("bench", type="hadoop", warehouse=f"file://{table_warehouse}")
        self.context.register_table_provider(TABLE, catalog.load_table(f"{NAMESPACE}.{TABLE}"))

    def prepare(self, query):
        return self.context.sql(query)

    def execute(self, prepared):
        rows = []
        for batch in prepared.collect():
            rows.extend(tuple(record.values()) for record in batch.to_pylist())
        return rows

    def close(self):
        pass
