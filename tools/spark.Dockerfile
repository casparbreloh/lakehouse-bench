# syntax=docker/dockerfile:1.7
FROM python:3.12-slim-bookworm AS base

ARG PYSPARK_VERSION=3.5.8
ARG ICEBERG_VERSION=1.7.1

RUN --mount=type=cache,target=/var/cache/apt \
    apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      ca-certificates curl openjdk-17-jre-headless \
    && rm -rf /var/lib/apt/lists/*
RUN --mount=type=cache,target=/root/.cache/pip \
    pip install "pyspark==${PYSPARK_VERSION}"
RUN curl -fsSL "https://repo.maven.apache.org/maven2/org/apache/iceberg/iceberg-spark-runtime-3.5_2.12/${ICEBERG_VERSION}/iceberg-spark-runtime-3.5_2.12-${ICEBERG_VERSION}.jar" -o /opt/iceberg.jar

FROM base AS spark-local
COPY tools/common/spark_engine.py /opt/lakehouse-bench/spark_engine.py
ENTRYPOINT ["python", "/opt/lakehouse-bench/spark_engine.py"]

FROM base AS iceberg-parquet
COPY tools/common/iceberg_setup.py /opt/lakehouse-bench/iceberg_setup.py
ENTRYPOINT ["python", "/opt/lakehouse-bench/iceberg_setup.py"]

FROM base AS spark-comet-local
ARG COMET_VERSION=0.15.0
RUN curl -fsSL "https://repo.maven.apache.org/maven2/org/apache/datafusion/comet-spark-spark3.5_2.12/${COMET_VERSION}/comet-spark-spark3.5_2.12-${COMET_VERSION}.jar" -o /opt/comet.jar
COPY tools/common/spark_engine.py /opt/lakehouse-bench/spark_engine.py
ENTRYPOINT ["python", "/opt/lakehouse-bench/spark_engine.py"]
