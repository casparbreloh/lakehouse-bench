#!/usr/bin/env bash
# Build and run one immutable, single-node tool selection. Setup is never timed.
set -Eeuo pipefail
IFS=$'\n\t'
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fail() { printf 'error: %s\n' "$*" >&2; exit 1; }
[ "$#" -eq 1 ] || fail "usage: ${0##*/} <preset.json>"
PRESET="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
case "$PRESET" in "$ROOT"/*) ;; *) fail "preset must be inside the repository";; esac
[ -f "$PRESET" ] || fail "preset not found: $1"
command -v docker >/dev/null || fail "missing docker"
docker buildx version >/dev/null 2>&1 || fail "missing Docker Buildx"
command -v jq >/dev/null || fail "missing jq"
REL="${PRESET#"$ROOT"/}"
jq -e '
  .profile == "benchmark" and .topology == "single-node"
  and .workload == {name:"tpch", scale_factor:.workload.scale_factor, queries:["q1"]}
  and .storage == {table_format:"iceberg", file_format:"parquet"}
  and .engines == ["spark-local", "datafusion", "spark-comet-local"]
  and (.execution | keys == ["iterations", "threads", "warmups"]
       and .threads >= 1 and .warmups >= 0 and .iterations >= 1)
' "$PRESET" >/dev/null || fail "only the fair TPC-H Q1 Iceberg/Parquet single-node selection is supported"
WORKLOAD_TOOL="$(jq -r '.workload.name' "$PRESET")"
STORAGE_TOOL="$(jq -r '.storage.table_format + "-" + .storage.file_format' "$PRESET")"
mapfile -t ENGINES < <(jq -r '.engines[]' "$PRESET")
TOOLS=("$WORKLOAD_TOOL" "$STORAGE_TOOL" "${ENGINES[@]}")
TOPOLOGY="$(jq -r '.topology' "$PRESET")"
FILE_FORMAT="$(jq -r '.storage.file_format' "$PRESET")"
TABLE_FORMAT="$(jq -r '.storage.table_format' "$PRESET")"
validate_tool() {
  local tool=$1 kind=$2 formats=$3 manifest
  manifest="$ROOT/tools/$tool/tool.json"
  [ -f "$manifest" ] || fail "tool manifest not found: $manifest"
  jq -e --arg tool "$tool" --arg kind "$kind" --arg topology "$TOPOLOGY" --argjson formats "$formats" '
    .name == $tool and .kind == $kind and .topology == [$topology] and .formats == $formats
    and (.build_target | type == "string") and (.image | type == "string")
  ' "$manifest" >/dev/null || fail "invalid tool manifest: $manifest"
}
validate_tool "$WORKLOAD_TOOL" workload "[\"$FILE_FORMAT\"]"
validate_tool "$STORAGE_TOOL" storage "[\"$TABLE_FORMAT\", \"$FILE_FORMAT\"]"
for engine in "${ENGINES[@]}"; do validate_tool "$engine" engine "[\"$TABLE_FORMAT\", \"$FILE_FORMAT\"]"; done
TARGETS=()
for tool in "${TOOLS[@]}"; do TARGETS+=("$(jq -r .build_target "$ROOT/tools/$tool/tool.json")"); done
(cd "$ROOT" && docker buildx bake --load "${TARGETS[@]}")
DATA="$ROOT/.bench-data"; OUT="$ROOT/out"
mkdir -p "$DATA" "$OUT"
rm -f "$OUT"/{spark-local,datafusion,spark-comet-local}.json "$OUT/result.json"
run_tool() {
  local tool=$1 engine=${2:-}
  local image; image="$(jq -r .image "$ROOT/tools/$tool/tool.json")"
  local args=(docker run --rm -e "BENCH_PRESET=/workspace/$REL" -e BENCH_DATA=/data)
  if [ -n "$engine" ]; then args+=(--network none -e "BENCH_ENGINE=$engine"); fi
  args+=(-v "$ROOT:/workspace:ro" -v "$DATA:/data" -v "$OUT:/out" "$image")
  "${args[@]}"
}
run_tool "$WORKLOAD_TOOL"
run_tool "$STORAGE_TOOL"
for engine in "${ENGINES[@]}"; do run_tool "$engine" "$engine"; done
ENGINE_OUTPUTS=()
for engine in "${ENGINES[@]}"; do ENGINE_OUTPUTS+=("$OUT/$engine.json"); done
jq -s -e '
  length == 3 and all(.[]; .status == "success" and (.measurements | length > 0))
  and ([.[] | .measurements[] | .result_checksum] | unique | length == 1)
' "${ENGINE_OUTPUTS[@]}" >/dev/null || fail "engine result status or checksums disagree"
jq -s --arg workload "$WORKLOAD_TOOL" --arg table_format "$TABLE_FORMAT" --arg file_format "$FILE_FORMAT" '{status:"success", workload:$workload, table:{format:$table_format, format_version:2, file_format:$file_format}, result_checksum:.[0].measurements[0].result_checksum, measurements:[.[] | .engine as $engine | .measurements[] | {name:($engine + "-q1-iteration-" + (.iteration|tostring)), status:"success", duration_ms, result_checksum, engine:$engine, query:"q1", iteration}]}' "${ENGINE_OUTPUTS[@]}" >"$OUT/result.json"
