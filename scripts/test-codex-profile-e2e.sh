#!/usr/bin/env bash
set -euo pipefail

source_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
real_codex="${CODEX_PROFILE_E2E_CODEX_BIN:-}"
fish_bin="${CODEX_PROFILE_E2E_FISH_BIN:-}"

if [[ -z "${real_codex}" ]]; then
  real_codex="$(command -v codex || true)"
fi
if [[ -z "${fish_bin}" ]]; then
  fish_bin="$(command -v fish || true)"
fi

if [[ ! -x "${real_codex}" ]]; then
  echo "real Codex binary not found; set CODEX_PROFILE_E2E_CODEX_BIN" >&2
  exit 2
fi
if [[ ! -x "${fish_bin}" ]]; then
  echo "fish binary not found; set CODEX_PROFILE_E2E_FISH_BIN" >&2
  exit 2
fi
command -v jq >/dev/null || {
  echo "jq is required" >&2
  exit 2
}
command -v python3 >/dev/null || {
  echo "python3 is required" >&2
  exit 2
}

test_root="$(mktemp -d "${TMPDIR:-/tmp}/codex-profile-e2e.XXXXXX")"
mock_pid=""

cleanup() {
  set +e
  if [[ -n "${mock_pid}" ]]; then
    kill "${mock_pid}" 2>/dev/null
    wait "${mock_pid}" 2>/dev/null
  fi
  rm -rf -- "${test_root}"
}
trap cleanup EXIT

mkdir -p "${test_root}/.codex/scripts" "${test_root}/.config/fish/conf.d"
install -m 755 \
  "${source_root}/scripts/codex-profile.sh" \
  "${source_root}/scripts/codex-session-picker.sh" \
  "${source_root}/scripts/codex-sync-commands.sh" \
  "${source_root}/scripts/install-codex-command-sync.sh" \
  "${test_root}/.codex/scripts/"
install -m 644 \
  "${source_root}/scripts/codex-profile-commands.fish" \
  "${test_root}/.codex/scripts/"
install -m 644 \
  "${source_root}/scripts/codex-profile-commands.fish" \
  "${test_root}/.config/fish/conf.d/"

port_file="${test_root}/mock-port"
request_log="${test_root}/mock-requests.jsonl"
python3 "${source_root}/scripts/testdata/mock-codex-responses.py" \
  --port-file "${port_file}" \
  --request-log "${request_log}" &
mock_pid="$!"

for _ in {1..100}; do
  [[ -s "${port_file}" ]] && break
  sleep 0.05
done
if [[ ! -s "${port_file}" ]]; then
  echo "mock Codex server did not start" >&2
  exit 1
fi
mock_port="$(<"${port_file}")"

write_profile() {
  local profile_name="$1"
  local model_name="$2"
  printf '%s\n' \
    "model = \"${model_name}\"" \
    'model_provider = "localhost"' \
    '' \
    '[model_providers.localhost]' \
    'name = "local Codex profile test"' \
    "base_url = \"http://127.0.0.1:${mock_port}/v1\"" \
    'wire_api = "responses"' \
    'requires_openai_auth = true' \
    >"${test_root}/.codex/${profile_name}.config.toml"
}

printf '%s\n' \
  'model = "e2e-base-model"' \
  'model_provider = "localhost"' \
  >"${test_root}/.codex/config.toml"
write_profile default e2e-default-model
write_profile work e2e-work-model
printf '%s\n' '{"OPENAI_API_KEY":"e2e-default-key"}' >"${test_root}/.codex/auth.json"
printf '%s\n' '{"OPENAI_API_KEY":"e2e-work-key"}' >"${test_root}/.codex/auth.json.work"

HOME="${test_root}" XDG_CONFIG_HOME="${test_root}/.config" \
  "${test_root}/.codex/scripts/install-codex-command-sync.sh" >/dev/null
[[ -f "${test_root}/.config/fish/conf.d/codex-profile-commands.fish" ]]

run_fish_route() {
  local output_path="$1"
  local command_text="$2"
  if ! HOME="${test_root}" XDG_CONFIG_HOME="${test_root}/.config" \
    CODEX_PROFILE_CODEX_BIN="${real_codex}" \
    "${fish_bin}" --interactive -c "${command_text}" >"${output_path}" 2>"${output_path}.stderr"; then
    cat "${output_path}.stderr" >&2
    cat "${output_path}" >&2
    return 1
  fi
}

create_output="${test_root}/create.jsonl"
run_fish_route "${create_output}" \
  'exec codex-work exec --json --skip-git-repo-check -s read-only "create an e2e session"'
thread_id="$(jq -r -s '[.[] | select(.type == "thread.started") | .thread_id][0] // empty' "${create_output}")"
if [[ ! "${thread_id}" =~ ^[0-9a-fA-F-]{36}$ ]]; then
  echo "real Codex did not create a thread" >&2
  cat "${create_output}" >&2
  exit 1
fi
jq -e -s 'any(.[]; .type == "turn.completed")' "${create_output}" >/dev/null
[[ -x "${test_root}/.local/bin/codex-work" ]]
[[ -x "${test_root}/.local/bin/codex-default" ]]

session_path="$(find "${test_root}/.codex/sessions" -type f -name "*${thread_id}*.jsonl" -print -quit)"
if [[ -z "${session_path}" ]]; then
  echo "real Codex did not persist the created session" >&2
  exit 1
fi

work_resume_output="${test_root}/work-resume.jsonl"
run_fish_route "${work_resume_output}" \
  "exec codex-work exec --json -s read-only resume ${thread_id} \"continue the e2e session from work\""
jq -e -s 'any(.[]; .type == "turn.completed")' "${work_resume_output}" >/dev/null
jq -e -s --arg thread_id "${thread_id}" \
  'any(.[]; .type == "thread.started" and .thread_id == $thread_id)' \
  "${work_resume_output}" >/dev/null

default_resume_output="${test_root}/default-resume.jsonl"
run_fish_route "${default_resume_output}" \
  "exec codex-default exec --json -s read-only resume ${thread_id} \"continue the e2e session from default\""
jq -e -s 'any(.[]; .type == "turn.completed")' "${default_resume_output}" >/dev/null
jq -e -s --arg thread_id "${thread_id}" \
  'any(.[]; .type == "thread.started" and .thread_id == $thread_id)' \
  "${default_resume_output}" >/dev/null

request_count="$(wc -l <"${request_log}")"
if (( request_count < 3 )); then
  echo "expected create plus two resume requests, got ${request_count}" >&2
  exit 1
fi
jq -e -s \
  --arg work_model e2e-work-model \
  --arg default_model e2e-default-model \
  '[.[].body.model] | index($work_model) != null and index($default_model) != null' \
  "${request_log}" >/dev/null
jq -e -s \
  --arg work_key 'Bearer e2e-work-key' \
  --arg default_key 'Bearer e2e-default-key' \
  '[.[].authorization] | index($work_key) != null and index($default_key) != null' \
  "${request_log}" >/dev/null

echo "codex-profile real e2e tests: ok"
