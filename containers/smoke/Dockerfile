FROM alpine:3.21

RUN apk add --no-cache python3
COPY src /opt/lakehouse-bench/src
ENV PYTHONPATH=/opt/lakehouse-bench/src
ENTRYPOINT ["python3", "-m", "lakehouse_bench.runner"]
