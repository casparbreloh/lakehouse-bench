FROM python:3.11-slim-bookworm
ARG DUCKDB_VERSION=1.1.3
RUN --mount=type=cache,target=/root/.cache/pip pip install "duckdb==${DUCKDB_VERSION}"
RUN python -c 'import duckdb; duckdb.connect().execute("INSTALL tpch")'
COPY tools/common/tpch_setup.py /opt/lakehouse-bench/tpch_setup.py
ENTRYPOINT ["python", "/opt/lakehouse-bench/tpch_setup.py"]
