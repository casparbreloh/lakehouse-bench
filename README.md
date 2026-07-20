# Lakehouse Bench

A deliberately small, container-first benchmark harness for query engines, table formats, and file formats.

It currently contains a **smoke suite** only. The smoke suite proves the Docker/result contract without generating data or running a real benchmark. The first real suite will be Iceberg + Parquet with TPC-H.

## Requirements

The launcher machine needs only:

- [Hetzner Cloud CLI](https://github.com/hetznercloud/cli) (`hcloud`)
- Docker CLI with `docker compose`
- Git
- Bash
- `jq`

The benchmark VM installs Docker through cloud-init. No Mise, Python, Node, Java, Rust, Terraform, or Kubernetes is required on the launcher machine.

## Try the smoke suite locally

This is the basic development check. It builds a tiny container and writes a valid result bundle to `out/result.json`.

```sh
docker compose --profile smoke run --rm smoke
jq . out/result.json
```

## Run a suite on Hetzner

Set `HCLOUD_SSH_KEY` to the name or ID of an SSH key already registered in your Hetzner project. `hcloud` must be authenticated using its normal configuration or `HCLOUD_TOKEN`.

```sh
export HCLOUD_SSH_KEY=my-ssh-key
./bench.sh configs/smoke.json
```

`bench.sh` validates the config, creates a labelled VM, waits for cloud-init, transfers the exact committed source revision, runs the selected Compose service, collects `out/result.json`, renders a result folder, commits it, and pushes it to the configured branch. Commit the benchmark source before running: the launcher intentionally benchmarks only committed files.

A successful push is the only case in which it automatically deletes the VM. If any step fails, the VM is retained and the script prints the server ID and IP so it can be inspected or deleted with `hcloud`.

> The initial SSH connection uses OpenSSH `accept-new` host-key checking. That is a deliberate simple/TOFU trade-off for disposable benchmark VMs.

## Results

Browse published runs in [`results/`](./results/). The root README stays focused on how to run the project; each result keeps its full Markdown table and raw JSON together.

Published results are normal Git-tracked files:

```text
results/
  README.md
  2026-07-20-tpch-sf10-cpx51-abc123/
    README.md
    result.json
```

Each run folder contains a GitHub-rendered Markdown summary and raw JSON evidence: resolved config, source revision, VM details, and every measurement returned by the suite. Logs and generated datasets are not committed.

Results are only compared within the same suite and profile. For example, raw Parquet versus Iceberg-on-Parquet is a table-overhead study, not a claim that Iceberg is a file format.

## Suites and configuration

A suite is an explicit implementation under `suites/<name>/`; it owns its Docker image and format/engine choices. Configurations select a suite instead of trying to construct arbitrary engine × table-format × file-format combinations.

`configs/*.json` must conform to [`suites/schema.json`](./suites/schema.json). The schema rejects unknown keys. `bench.sh` also checks the selected suite's checked-in `suite.json` manifest, its Compose service, allowed profile, and requested TPC-H query IDs.

The smoke configuration is intentionally tiny:

```json
{
  "$schema": "../suites/schema.json",
  "name": "smoke",
  "cloud": { "server_type": "cpx12", "location": "fsn1", "image": "ubuntu-24.04" },
  "suite": "smoke",
  "profile": "smoke",
  "workload": { "name": "smoke", "scale_factor": 1, "queries": [] },
  "execution": { "warmups": 0, "iterations": 1 },
  "publish": { "branch": "main" }
}
```

Use a branch on which the local Git credentials are permitted to push. Benchmark result commits contain only `results/` paths.
