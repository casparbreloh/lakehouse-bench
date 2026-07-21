# Lakehouse Bench

A small container-first harness for reusable lakehouse benchmark definitions. Global adapters live in `src/lakehouse_bench/`: engines, table formats, file formats, workloads, the supported-combination registry, and one preset-driven runner. `spark-local` and `spark-comet-local` explicitly mean single-node Spark adapters; native `datafusion` is single-process by definition. Future clustered engines are separate adapters, not implicit modes.

## Presets and containers

`presets/` selects a workload, storage, engines, profile/topology, execution threads/warmups/iterations, and cloud/publish settings. `presets/schema.json` rejects malformed presets and the registry rejects unsupported combinations. The smoke preset intentionally selects no storage or engines. The TPC-H preset selects Iceberg/Parquet with `spark-local`, native `datafusion`, and `spark-comet-local`.

There are only two Compose services: `smoke` and the generic `benchmark`. For single-node runs, every adapter receives the preset's `execution.threads`: Spark uses `local[N]`; DataFusion uses N partitions and Rayon threads.

## Local smoke check

```sh
docker compose --profile smoke run --rm smoke
jq . out/result.json
```

## Run on Hetzner

The launcher requires `hcloud`, Docker Compose, Git, Bash, and jq. Set an existing Hetzner SSH key, commit the source, then run a preset:

```sh
export HCLOUD_SSH_KEY=my-ssh-key
./bench.sh presets/smoke.json
# ./bench.sh presets/tpch-iceberg-parquet-single-node-sf1.json
```

`bench.sh` validates the preset and its supported profile mapping, creates and labels a VM, archives the committed revision, runs the selected generic service, collects `out/result.json`, writes and publishes a result bundle, and deletes the VM only after a successful push. On failure it retains the VM for inspection.

Generated local data is `.bench-data/`; container output is `out/`; both are ignored. Published runs are tracked under [`results/`](./results/).
