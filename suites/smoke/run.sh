#!/bin/sh
set -eu

config="${BENCH_CONFIG:-/workspace/configs/smoke.json}"

[ -f "$config" ]
mkdir -p /out

jq -n \
  --arg suite "smoke" \
  --arg config "$config" \
  --arg created_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{
    status: "success",
    suite: $suite,
    created_at: $created_at,
    config_path: $config,
    measurements: [
      {
        name: "container-contract",
        status: "success",
        duration_ms: 0,
        result_checksum: "smoke"
      }
    ]
  }' > /out/result.json

jq -e '.status == "success" and (.measurements | length) == 1' /out/result.json >/dev/null
printf '%s\n' "Smoke result written to /out/result.json"
