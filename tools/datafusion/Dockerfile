FROM python:3.12-slim-bookworm
ARG DATAFUSION_VERSION=51.0.0
ARG PYICEBERG_VERSION=0.11.1
RUN --mount=type=cache,target=/root/.cache/pip pip install "datafusion==${DATAFUSION_VERSION}" "pyiceberg[pyarrow]==${PYICEBERG_VERSION}" "pyiceberg-core==0.8.0"
COPY tools/common/datafusion_engine.py /opt/lakehouse-bench/datafusion_engine.py
ENTRYPOINT ["python", "/opt/lakehouse-bench/datafusion_engine.py"]
