group "default" {
  targets = ["tpch", "iceberg-parquet", "spark-local", "datafusion", "spark-comet-local"]
}

target "tpch" {
  context = "."
  dockerfile = "tools/tpch/Dockerfile"
  tags = ["lakehouse-bench/tpch:latest"]
}
target "iceberg-parquet" {
  context = "."
  dockerfile = "tools/spark.Dockerfile"
  target = "iceberg-parquet"
  tags = ["lakehouse-bench/iceberg-parquet:latest"]
}
target "spark-local" {
  context = "."
  dockerfile = "tools/spark.Dockerfile"
  target = "spark-local"
  tags = ["lakehouse-bench/spark-local:latest"]
}
target "datafusion" {
  context = "."
  dockerfile = "tools/datafusion/Dockerfile"
  tags = ["lakehouse-bench/datafusion:latest"]
}
target "spark-comet-local" {
  context = "."
  dockerfile = "tools/spark.Dockerfile"
  target = "spark-comet-local"
  tags = ["lakehouse-bench/spark-comet-local:latest"]
}
