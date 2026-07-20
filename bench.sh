#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_ROOT="$ROOT/.bench"

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

note() {
  printf '==> %s\n' "$*"
}

require() {
  command -v "$1" >/dev/null 2>&1 || fail "missing required command: $1"
}

usage() {
  printf 'usage: %s <config.json>\n' "${0##*/}" >&2
  exit 2
}

is_allowed_keys() {
  local json=$1
  shift
  jq -e --argjson allowed "$(printf '%s\n' "$@" | jq -R . | jq -s .)" \
    'type == "object" and ((keys - $allowed) | length == 0)' <<<"$json" >/dev/null
}

validate_config() {
  local config=$1 json
  json="$(jq -ce . "$config")" || fail "invalid JSON: $config"

  is_allowed_keys "$json" '$schema' name cloud suite profile workload execution publish || fail "config has unknown keys"
  jq -e '
    ."$schema" == "../suites/schema.json"
    and (.name | type == "string" and test("^[a-z0-9][a-z0-9-]{0,38}$"))
    and (.suite | type == "string" and test("^[a-z0-9][a-z0-9-]{0,62}$"))
    and (.profile as $profile | ["smoke", "engine-execution", "end-to-end", "distributed"] | index($profile) != null)
    and (.cloud | type == "object" and ([keys[]] | sort) == ["image", "location", "server_type"])
    and (.cloud.server_type | type == "string" and test("^[a-z0-9-]+$"))
    and (.cloud.location | type == "string" and test("^[a-z0-9-]+$"))
    and (.cloud.image | type == "string" and test("^[a-z0-9._-]+$"))
    and (.workload | type == "object" and ([keys[]] | sort) == ["name", "queries", "scale_factor"])
    and (.workload.name | type == "string" and test("^[a-z0-9][a-z0-9-]{0,62}$"))
    and (.workload.scale_factor | type == "number" and floor == . and . >= 1 and . <= 100000)
    and (.workload.queries | type == "array" and length == (unique | length)
         and all(.[]; type == "string" and test("^q([1-9]|1[0-9]|2[0-2])$")))
    and (.execution | type == "object" and ([keys[]] | sort) == ["iterations", "warmups"])
    and (.execution.warmups | type == "number" and floor == . and . >= 0 and . <= 100)
    and (.execution.iterations | type == "number" and floor == . and . >= 1 and . <= 100)
    and (.publish | type == "object" and ([keys[]] | sort) == ["branch"])
    and (.publish.branch | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._/-]{0,127}$"))
  ' "$config" >/dev/null || fail "config does not match suites/schema.json"
}

config_value() {
  jq -er "$2" "$1"
}

compose_has_service() {
  local profile=$1 service=$2 candidate
  while IFS= read -r candidate; do
    [ "$candidate" = "$service" ] && return 0
  done < <(cd "$ROOT" && docker compose --profile "$profile" config --services)
  return 1
}

suite_value() {
  jq -er "$2" "$1"
}

validate_suite() {
  local suite=$1 profile=$2 manifest service
  manifest="$ROOT/suites/$suite/suite.json"
  [ -f "$manifest" ] || fail "suite manifest not found: suites/$suite/suite.json"
  jq -e '
    type == "object"
    and ([keys[]] | sort) == ["name", "profiles", "service"]
    and (.name | type == "string")
    and (.service | type == "string" and test("^[a-z0-9][a-z0-9-]{0,62}$"))
    and (.profiles | type == "array" and length > 0 and all(.[]; type == "string"))
  ' "$manifest" >/dev/null || fail "invalid suite manifest: $manifest"
  [ "$(suite_value "$manifest" '.name')" = "$suite" ] || fail "suite manifest name does not match directory"
  jq -e --arg profile "$profile" '.profiles | index($profile) != null' "$manifest" >/dev/null \
    || fail "suite $suite does not support profile $profile"
  service="$(suite_value "$manifest" '.service')"
  compose_has_service "$profile" "$service" || fail "suite service is not enabled by Compose profile $profile: $service"
  printf '%s\n' "$service"
}

wait_for_ready() {
  local host=$1 known_hosts=$2 elapsed=0
  while [ "$elapsed" -lt 600 ]; do
    if ssh -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new \
      -o UserKnownHostsFile="$known_hosts" "root@$host" \
      'test -f /var/lib/lakehouse-bench/ready'; then
      return 0
    fi
    sleep 5
    elapsed=$((elapsed + 5))
  done
  return 1
}

render_result() {
  local config=$1 suite_result=$2 result_dir=$3 run_id=$4 source_revision=$5 server_id=$6 server_type=$7 location=$8 image=$9 expected_suite=${10}
  local result_json="$result_dir/result.json"
  local summary="$result_dir/README.md"

  jq -e --arg expected_suite "$expected_suite" '
    type == "object"
    and (.status == "success")
    and (.suite == $expected_suite)
    and (.measurements | type == "array" and length > 0)
    and all(.measurements[];
      type == "object"
      and (.name | type == "string")
      and (.status == "success")
      and (.duration_ms | type == "number" and . >= 0)
      and (.result_checksum | type == "string")
    )
  ' "$suite_result" >/dev/null || fail "suite did not produce a valid successful result"

  jq -n \
    --arg run_id "$run_id" \
    --arg source_revision "$source_revision" \
    --arg server_id "$server_id" \
    --arg server_type "$server_type" \
    --arg location "$location" \
    --arg image "$image" \
    --arg collected_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --slurpfile config "$config" \
    --slurpfile suite_result "$suite_result" \
    '{
      run_id: $run_id,
      collected_at: $collected_at,
      source_revision: $source_revision,
      cloud: {server_id: $server_id, server_type: $server_type, location: $location, image: $image},
      config: $config[0],
      suite_result: $suite_result[0]
    }' >"$result_json"

  {
    printf '# %s\n\n' "$(config_value "$config" '.name')"
    printf -- '- Run ID: `%s`\n' "$run_id"
    printf -- '- Suite: `%s`\n' "$(config_value "$config" '.suite')"
    printf -- '- Profile: `%s`\n' "$(config_value "$config" '.profile')"
    printf -- '- Source revision: `%s`\n' "$source_revision"
    printf -- '- VM: Hetzner `%s` in `%s` (`%s`)\n' "$server_type" "$location" "$server_id"
    printf -- '- Collected: %s\n\n' "$(jq -r '.collected_at' "$result_json")"
    printf '## Measurements\n\n'
    printf '| Name | Status | Duration | Checksum |\n|---|---|---:|---|\n'
    jq -r '.suite_result.measurements[] | [.name, .status, (.duration_ms | tostring) + " ms", .result_checksum] | @tsv' "$result_json" |
      while IFS=$'\t' read -r name status duration checksum; do
        printf '| %s | %s | %s | `%s` |\n' "$name" "$status" "$duration" "$checksum"
      done
    printf '\nRaw measurements and provenance: [`result.json`](./result.json)\n'
  } >"$summary"
}

update_results_index() {
  local run_id=$1 config=$2
  local index="$ROOT/results/README.md"
  local entry="- [${run_id}](./${run_id}/) — $(config_value "$config" '.suite') / $(config_value "$config" '.profile')"

  if grep -q '^No benchmark runs have been published yet\.$' "$index"; then
    printf '# Benchmark results\n\n%s\n' "$entry" >"$index"
  else
    printf '%s\n' "$entry" >>"$index"
  fi
}

publish_results() {
  local result_dir=$1 config=$2
  local branch current_branch
  branch="$(config_value "$config" '.publish.branch')"
  git -C "$ROOT" check-ref-format --branch "$branch" >/dev/null || fail "invalid publish branch: $branch"
  current_branch="$(git -C "$ROOT" branch --show-current)"
  [ "$current_branch" = "$branch" ] || fail "publish branch is $branch, but the checked-out branch is ${current_branch:-detached}"
  git -C "$ROOT" diff --quiet -- . ':(exclude)results' \
    && git -C "$ROOT" diff --cached --quiet -- . ':(exclude)results' \
    || fail "working tree changed outside results while benchmark was running"

  git -C "$ROOT" add results/README.md
  git -C "$ROOT" add -f "$result_dir"
  git -C "$ROOT" commit -m "bench: $(basename "$result_dir")"
  git -C "$ROOT" push origin "HEAD:refs/heads/$branch"
}

main() {
  [ "$#" -eq 1 ] || usage

  local config_input=$1 config config_base config_rel
  config="$(cd "$(dirname "$config_input")" && pwd)/$(basename "$config_input")"
  config_base="$(basename "$config")"
  case "$config" in
    "$ROOT"/*) ;;
    *) fail "config must be inside the repository" ;;
  esac
  [ -f "$config" ] || fail "config not found: $config_input"

  require hcloud
  require docker
  require git
  require bash
  require jq
  docker compose version >/dev/null 2>&1 || fail "Docker Compose plugin is required"
  validate_config "$config"

  local suite service profile server_type location image name source_revision config_status
  suite="$(config_value "$config" '.suite')"
  profile="$(config_value "$config" '.profile')"
  server_type="$(config_value "$config" '.cloud.server_type')"
  location="$(config_value "$config" '.cloud.location')"
  image="$(config_value "$config" '.cloud.image')"
  name="$(config_value "$config" '.name')"
  config_rel="${config#"$ROOT"/}"

  [ "$(dirname "$config")" = "$ROOT/configs" ] && [[ "$config_base" =~ ^[a-z0-9][a-z0-9-]*\.json$ ]] \
    || fail "config must be a safely named file directly inside configs/"
  service="$(validate_suite "$suite" "$profile")"
  git -C "$ROOT" check-ref-format --branch "$(config_value "$config" '.publish.branch')" >/dev/null \
    || fail "invalid publish branch"
  git -C "$ROOT" diff --quiet && git -C "$ROOT" diff --cached --quiet || fail "commit or stash changes before running"
  config_status="$(git -C "$ROOT" status --porcelain --untracked-files=all)"
  [ -z "$config_status" ] || fail "commit or remove untracked files before running"
  source_revision="$(git -C "$ROOT" rev-parse HEAD)"
  [ -n "${HCLOUD_SSH_KEY:-}" ] || fail "set HCLOUD_SSH_KEY to an existing Hetzner SSH key name or ID"

  local run_id state_dir server_json server_id server_ip
  run_id="$(date -u +%Y%m%dt%H%M%Sz)-${name}-$(git -C "$ROOT" rev-parse --short HEAD)"
  state_dir="$STATE_ROOT/$run_id"
  umask 077
  mkdir -p "$state_dir"

  note "creating Hetzner server $run_id"
  server_json="$(hcloud server create \
    --name "$run_id" \
    --type "$server_type" \
    --image "$image" \
    --location "$location" \
    --ssh-key "$HCLOUD_SSH_KEY" \
    --label "lakehouse-bench-run=$run_id" \
    --user-data-from-file "$ROOT/cloud-init.yaml" \
    -o json)"
  server_id="$(jq -er '.server.id' <<<"$server_json")"
  server_ip="$(jq -er '.server.public_net.ipv4.ip' <<<"$server_json")"
  printf '%s\n' "$server_id" >"$state_dir/server-id"
  printf '%s\n' "$server_ip" >"$state_dir/server-ip"
  note "server created: id=$server_id ip=$server_ip"

  if ! wait_for_ready "$server_ip" "$state_dir/known_hosts"; then
    fail "VM did not become ready; inspect with: hcloud server describe $server_id"
  fi

  note "transferring source revision $source_revision"
  git -C "$ROOT" archive --format=tar "$source_revision" |
    ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$state_dir/known_hosts" \
      "root@$server_ip" 'rm -rf /root/lakehouse-bench && mkdir -p /root/lakehouse-bench/out && tar -xf - -C /root/lakehouse-bench'

  note "running suite $suite"
  ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$state_dir/known_hosts" \
    "root@$server_ip" \
    "cd /root/lakehouse-bench && BENCH_CONFIG=/workspace/$config_rel COMPOSE_PROJECT_NAME=lakehouse-bench-$run_id docker compose --profile $profile run --rm $service"

  note "collecting result"
  scp -q -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$state_dir/known_hosts" \
    "root@$server_ip:/root/lakehouse-bench/out/result.json" "$state_dir/suite-result.json"

  local result_dir
  result_dir="$ROOT/results/$run_id"
  mkdir -p "$result_dir"
  render_result "$config" "$state_dir/suite-result.json" "$result_dir" "$run_id" "$source_revision" "$server_id" "$server_type" "$location" "$image" "$suite"
  update_results_index "$run_id" "$config"

  note "publishing results"
  publish_results "$result_dir" "$config"

  note "published; deleting server $server_id"
  hcloud server delete "$server_id"
  printf 'completed: %s\n' "$result_dir"
}

main "$@"
