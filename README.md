# Lakehouse Bench

A small OCI tool-plugin harness for fair, single-node lakehouse comparisons. Each selected component has one declarative manifest in [`tools/`](./tools): its name, kind, supported topology/formats, Bake target, and image. Tool images are independent; there is no all-engines image or Docker-socket container.

## Included comparison

[`presets/tpch-iceberg-parquet-single-node-sf1.json`](./presets/tpch-iceberg-parquet-single-node-sf1.json) is intentionally the only normal selection: TPC-H Q1, Iceberg v2/Parquet, `spark-local`, `datafusion`, and `spark-comet-local`, on one node with four threads. The only execution controls are scale factor, threads, warmups, and iterations.

`run-preset.sh` validates that immutable selection, uses `docker buildx bake --load` to build only its five tool images, runs the TPC-H and Iceberg setup containers before timing, then runs engine containers sequentially over shared `.bench-data` and `out` mounts. Engines warm up and measure inside their own process, emit compact JSON, and the orchestrator refuses differing checksums before writing `out/result.json`.

```sh
./run-preset.sh presets/tpch-iceberg-parquet-single-node-sf1.json
```

Tool dependencies are pinned Python packages and pinned Maven jars; BuildKit cache mounts accelerate package installation. No Spark tarballs, source builds, or git clones are used.

## Smoke

The Compose smoke service remains the stable local/remote result contract:

```sh
docker compose --profile smoke run --build --rm smoke
jq . out/result.json
```

## Hetzner

```sh
export HCLOUD_SSH_KEY=my-ssh-key
./bench.sh presets/smoke.json
# ./bench.sh presets/tpch-iceberg-parquet-single-node-sf1.json
```

`bench.sh` archives the committed revision to the VM. Smoke uses Compose; normal runs invoke `run-preset.sh`. It collects `out/result.json`, publishes the result bundle, then deletes the VM only after a successful push. On failure the VM is retained for inspection.
