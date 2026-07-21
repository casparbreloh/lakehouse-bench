FROM eclipse-temurin:17-jdk-jammy

ARG SPARK_VERSION=3.5.8
ARG ICEBERG_VERSION=1.10.1
ARG COMET_VERSION=0.15.0
ARG TPCH_KIT_REF=852ad0a5ee31ebefeed884cea4188781dd9613a3

ENV SPARK_HOME=/opt/spark
ENV PATH=/opt/spark/bin:$PATH
ENV PYSPARK_PYTHON=/usr/bin/python3
ENV PYTHONPATH=/opt/lakehouse-bench/src

RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      build-essential ca-certificates curl git jq python3 python3-pip && \
    rm -rf /var/lib/apt/lists/* && \
    curl -fsSL "https://archive.apache.org/dist/spark/spark-${SPARK_VERSION}/spark-${SPARK_VERSION}-bin-hadoop3.tgz" | tar -xz -C /opt && \
    mv "/opt/spark-${SPARK_VERSION}-bin-hadoop3" "$SPARK_HOME" && \
    curl -fsSL "https://repo.maven.apache.org/maven2/org/apache/iceberg/iceberg-spark-runtime-3.5_2.12/${ICEBERG_VERSION}/iceberg-spark-runtime-3.5_2.12-${ICEBERG_VERSION}.jar" \
      -o "$SPARK_HOME/jars/iceberg-spark-runtime-3.5_2.12-${ICEBERG_VERSION}.jar" && \
    curl -fsSL "https://repo.maven.apache.org/maven2/org/apache/datafusion/comet-spark-spark3.5_2.12/${COMET_VERSION}/comet-spark-spark3.5_2.12-${COMET_VERSION}.jar" \
      -o "$SPARK_HOME/jars/comet-spark-spark3.5_2.12-${COMET_VERSION}.jar" && \
    git clone https://github.com/gregrahn/tpch-kit.git /opt/tpch-kit && \
    git -C /opt/tpch-kit checkout --detach "$TPCH_KIT_REF" && \
    make -C /opt/tpch-kit/dbgen MACHINE=LINUX && \
    python3 -m pip install --no-cache-dir \
      'datafusion==51.0.0' 'pyiceberg==0.11.1' 'pyiceberg-core==0.8.0' 'pyarrow==17.0.0'

COPY src /opt/lakehouse-bench/src
ENTRYPOINT ["python3", "-m", "lakehouse_bench.runner"]
