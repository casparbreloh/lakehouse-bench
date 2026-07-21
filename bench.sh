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
  printf 'usage: %s <preset.json>\n' "${0##*/}" >&2
  exit 2
}

is_allowed_keys() {
  local json=$1
  shift
  jq -e --argjson allowed "$(printf '%s\n' "$@" | jq -R . | jq -s .)" \
    'type == "object" and ((keys - $allowed) | length == 0)' <<<"$json" >/dev/null
}

validate_preset() {
  local preset=$1 json
  json="$(jq -ce . "$preset")" || fail "invalid JSON: $preset"

  is_allowed_keys "$json" '$schema' name cloud workload storage engines profile topology execution publish || fail "preset has unknown keys"
  jq -e '
    ."$schema" == "schema.json"
    and (.name | type == "string" and test("^[a-z0-9][a-z0-9-]{0,62}$"))
    and (.cloud | type == "object" and ([keys[]] | sort) == ["image", "location", "server_type"])
    and (.cloud.server_type | type == "string" and test("^[a-z0-9-]+$"))
    and (.cloud.location | type == "string" and test("^[a-z0-9-]+$"))
    and (.cloud.image | type == "string" and test("^[a-z0-9._-]+$"))
    and (.workload | type == "object" and ([keys[]] | sort) == ["name", "queries", "scale_factor"])
    and (.workload.name | type == "string" and test("^[a-z0-9][a-z0-9-]{0,62}$"))
    and (.workload.scale_factor | type == "number" and floor == . and . >= 1 and . <= 100000)
    and (.workload.queries | type == "array" and length == (unique | length) and all(.[]; type == "string" and test("^q([1-9]|1[0-9]|2[0-2])$")))
    and (.profile as $profile | ["smoke", "benchmark"] | index($profile) != null)
    and (.topology == "single-node")
    and (.execution | type == "object" and ([keys[]] | sort) == ["iterations", "threads", "warmups"])
    and (.execution.threads | type == "number" and floor == . and . >= 1 and . <= 1024)
    and (.execution.warmups | type == "number" and floor == . and . >= 0 and . <= 100)
    and (.execution.iterations | type == "number" and floor == . and . >= 1 and . <= 100)
    and (.publish | type == "object" and ([keys[]] | sort) == ["branch"])
    and (.publish.branch | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._/-]{0,127}$"))
    and (if .profile == "smoke" then .workload.name == "smoke" and (has("storage") | not) and (has("engines") | not) and .workload.queries == [] else (.storage | type == "object" and ([keys[]] | sort) == ["file_format", "table_format"] and (.table_format | type == "string" and test("^[a-z0-9][a-z0-9-]{0,62}$")) and (.file_format | type == "string" and test("^[a-z0-9][a-z0-9-]{0,62}$"))) and (.engines | type == "array" and length > 0 and length == (unique | length) and all(.[]; type == "string" and test("^[a-z0-9][a-z0-9-]{0,62}$"))) end)
  ' "$preset" >/dev/null || fail "preset does not match presets/schema.json or supported registry combinations"
}

preset_value() {
  jq -er "$2" "$1"
}

compose_has_service() {
  local profile=$1 service=$2 candidate
  while IFS= read -r candidate; do
    [ "$candidate" = "$service" ] && return 0
  done < <(cd "$ROOT" && docker compose --profile "$profile" config --services)
  return 1
}

preset_service() {
  local profile=$1
  [ "$profile" = "smoke" ] || return 0
  compose_has_service smoke smoke || fail "smoke service is not enabled by Compose"
  printf 'smoke\n'
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

run_remote_preset() {
  local host=$1 known_hosts=$2 run_dir=$3 preset_rel=$4 run_id=$5 timeout_seconds=${BENCH_RUN_TIMEOUT_SECONDS:-3600}
  local elapsed=0 exit_code
  [[ "$timeout_seconds" =~ ^[1-9][0-9]*$ ]] || fail "BENCH_RUN_TIMEOUT_SECONDS must be a positive integer"

  note "starting remote run; tailing $host:$run_dir/run.log (timeout: ${timeout_seconds}s)"
  ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$known_hosts" "root@$host" \
    "cd /root/lakehouse-bench && mkdir -p '$run_dir' && rm -f '$run_dir/run.status' '$run_dir/run.log' && nohup sh -c './run-preset.sh $preset_rel > $run_dir/run.log 2>&1; printf \"%s\\n\" \"\\\$?\" > $run_dir/run.status' >/dev/null 2>&1 &"

  while [ "$elapsed" -lt "$timeout_seconds" ]; do
    if exit_code="$(ssh -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$known_hosts" "root@$host" "test -f '$run_dir/run.status' && cat '$run_dir/run.status'" 2>/dev/null)"; then
      ssh -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$known_hosts" "root@$host" "tail -n 80 '$run_dir/run.log'" || true
      [ "$exit_code" = "0" ] || fail "remote benchmark failed (exit $exit_code); inspect: ssh root@$host 'tail -f $run_dir/run.log'"
      return 0
    fi
    ssh -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$known_hosts" "root@$host" "tail -n 30 '$run_dir/run.log'" 2>/dev/null || true
    sleep 15
    elapsed=$((elapsed + 15))
  done
  fail "remote benchmark exceeded ${timeout_seconds}s; it is still running. Inspect: ssh root@$host 'tail -f $run_dir/run.log'"
}

render_result() {
  local preset=$1 runner_result=$2 result_dir=$3 run_id=$4 source_revision=$5 server_id=$6 server_type=$7 location=$8 image=$9 expected_workload=${10}
  local result_json="$result_dir/result.json"
  local summary="$result_dir/README.md"

  jq -e --arg expected_workload "$expected_workload" '
    type == "object"
    and (.status == "success")
    and (.workload == $expected_workload)
    and (.measurements | type == "array" and length > 0)
    and all(.measurements[];
      type == "object"
      and (.name | type == "string")
      and (.status == "success")
      and (.duration_ms | type == "number" and . >= 0)
      and (.result_checksum | type == "string")
    )
  ' "$runner_result" >/dev/null || fail "runner did not produce a valid successful result"

  jq -n \
    --arg run_id "$run_id" \
    --arg source_revision "$source_revision" \
    --arg server_id "$server_id" \
    --arg server_type "$server_type" \
    --arg location "$location" \
    --arg image "$image" \
    --arg collected_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --slurpfile preset "$preset" \
    --slurpfile runner_result "$runner_result" \
    '{
      run_id: $run_id,
      collected_at: $collected_at,
      source_revision: $source_revision,
      cloud: {server_id: $server_id, server_type: $server_type, location: $location, image: $image},
      preset: $preset[0],
      runner_result: $runner_result[0]
    }' >"$result_json"

  {
    printf '# %s\n\n' "$(preset_value "$preset" '.name')"
    printf -- '- Run ID: `%s`\n' "$run_id"
    printf -- '- Workload: `%s`\n' "$(preset_value "$preset" '.workload.name')"
    printf -- '- Profile: `%s`\n' "$(preset_value "$preset" '.profile')"
    printf -- '- Source revision: `%s`\n' "$source_revision"
    printf -- '- VM: Hetzner `%s` in `%s` (`%s`)\n' "$server_type" "$location" "$server_id"
    printf -- '- Collected: %s\n\n' "$(jq -r '.collected_at' "$result_json")"
    printf '## Measurements\n\n'
    printf '| Name | Status | Duration | Checksum |\n|---|---|---:|---|\n'
    jq -r '.runner_result.measurements[] | [.name, .status, (.duration_ms | tostring) + " ms", .result_checksum] | @tsv' "$result_json" |
      while IFS=$'\t' read -r name status duration checksum; do
        printf '| %s | %s | %s | `%s` |\n' "$name" "$status" "$duration" "$checksum"
      done
    printf '\nRaw measurements and provenance: [`result.json`](./result.json)\n'
  } >"$summary"
}

update_results_index() {
  local run_id=$1 preset=$2
  local index="$ROOT/results/README.md"
  local entry="- [${run_id}](./${run_id}/) — $(preset_value "$preset" '.workload.name') / $(preset_value "$preset" '.profile')"

  if grep -q '^No benchmark runs have been published yet\.$' "$index"; then
    printf '# Benchmark results\n\n%s\n' "$entry" >"$index"
  else
    printf '%s\n' "$entry" >>"$index"
  fi
}

publish_results() {
  local result_dir=$1 preset=$2
  local branch current_branch
  branch="$(preset_value "$preset" '.publish.branch')"
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

  local preset_input=$1 preset preset_base preset_rel
  preset="$(cd "$(dirname "$preset_input")" && pwd)/$(basename "$preset_input")"
  preset_base="$(basename "$preset")"
  case "$preset" in
    "$ROOT"/*) ;;
    *) fail "preset must be inside the repository" ;;
  esac
  [ -f "$preset" ] || fail "preset not found: $preset_input"

  require hcloud
  require docker
  require git
  require bash
  require jq
  docker compose version >/dev/null 2>&1 || fail "Docker Compose plugin is required"
  validate_preset "$preset"

  local workload service profile server_type location image name source_revision preset_status
  workload="$(preset_value "$preset" '.workload.name')"
  profile="$(preset_value "$preset" '.profile')"
  server_type="$(preset_value "$preset" '.cloud.server_type')"
  location="$(preset_value "$preset" '.cloud.location')"
  image="$(preset_value "$preset" '.cloud.image')"
  name="$(preset_value "$preset" '.name')"
  preset_rel="${preset#"$ROOT"/}"

  [ "$(dirname "$preset")" = "$ROOT/presets" ] && [[ "$preset_base" =~ ^[a-z0-9][a-z0-9-]*\.json$ ]] \
    || fail "preset must be a safely named file directly inside presets/"
  service="$(preset_service "$profile")"
  git -C "$ROOT" check-ref-format --branch "$(preset_value "$preset" '.publish.branch')" >/dev/null \
    || fail "invalid publish branch"
  git -C "$ROOT" diff --quiet && git -C "$ROOT" diff --cached --quiet || fail "commit or stash changes before running"
  preset_status="$(git -C "$ROOT" status --porcelain --untracked-files=all)"
  [ -z "$preset_status" ] || fail "commit or remove untracked files before running"
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

  note "running workload $workload"
  if [ "$profile" = "smoke" ]; then
    ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$state_dir/known_hosts" \
      "root@$server_ip" \
      "cd /root/lakehouse-bench && COMPOSE_PROJECT_NAME=lakehouse-bench-$run_id docker compose --profile smoke run --build --rm $service"
  else
    run_remote_preset "$server_ip" "$state_dir/known_hosts" "/root/lakehouse-bench/.run-$run_id" "$preset_rel" "$run_id"
  fi

  note "collecting result"
  scp -q -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$state_dir/known_hosts" \
    "root@$server_ip:/root/lakehouse-bench/out/result.json" "$state_dir/runner-result.json"

  local result_dir
  result_dir="$ROOT/results/$run_id"
  mkdir -p "$result_dir"
  render_result "$preset" "$state_dir/runner-result.json" "$result_dir" "$run_id" "$source_revision" "$server_id" "$server_type" "$location" "$image" "$workload"
  update_results_index "$run_id" "$preset"

  note "publishing results"
  publish_results "$result_dir" "$preset"

  note "published; deleting server $server_id"
  hcloud server delete "$server_id"
  printf 'completed: %s\n' "$result_dir"
}

main "$@"
