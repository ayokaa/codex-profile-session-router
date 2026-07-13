#!/usr/bin/env bash
set -euo pipefail

source_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d /tmp/codex-profile-test.XXXXXX)"
trap 'rm -rf -- "${test_root}"' EXIT

mkdir -p "${test_root}/scripts"
install -m 755 "${source_root}/scripts/codex-profile.sh" "${test_root}/scripts/codex-profile.sh"
install -m 755 "${source_root}/scripts/codex-session-picker.sh" "${test_root}/scripts/codex-session-picker.sh"
install -m 755 "${source_root}/scripts/codex-sync-commands.sh" "${test_root}/scripts/codex-sync-commands.sh"
install -m 644 "${source_root}/scripts/codex-aliases.sh" "${test_root}/scripts/codex-aliases.sh"

printf '%s\n' \
  'model = "base-model"' \
  'model_provider = "localhost"' \
  >"${test_root}/config.toml"
printf '%s\n' \
  'model = "legacy-model"' \
  'model_provider = "localhost"' \
  >"${test_root}/config.toml.example"
printf '%s\n' \
  'model = "profile-model"' \
  'model_provider = "localhost"' \
  '' \
  '[model_providers.localhost]' \
  'name = "test"' \
  'base_url = "http://127.0.0.1:9/v1"' \
  'wire_api = "responses"' \
  'env_key = "OPENAI_API_KEY"' \
  'requires_openai_auth = false' \
  >"${test_root}/example.config.toml"
install -m 600 "${test_root}/config.toml" "${test_root}/default.config.toml"
printf '%s\n' '{"OPENAI_API_KEY":"root-test-key"}' >"${test_root}/auth.json"
printf '%s\n' '{"OPENAI_API_KEY":"suffix-test-key"}' >"${test_root}/auth.json.example"

install -m 755 "${source_root}/scripts/testdata/fake-codex-profile.sh" "${test_root}/fake-codex"

route=(
  env
  CODEX_PROFILE_CODEX_BIN="${test_root}/fake-codex"
  "${test_root}/scripts/codex-profile.sh"
  example
)

resume_id="019f5742-1549-7ad2-ae54-42a19dfa340d"
FAKE_EXPECT_RESUME_ID="${resume_id}" "${route[@]}" resume "${resume_id}" --all

FAKE_EDIT_PROFILE=true "${route[@]}" exec --skip-git-repo-check test
grep -q 'model = "tui-model"' "${test_root}/example.config.toml"
grep -q 'model = "legacy-model"' "${test_root}/config.toml.example"

"${test_root}/scripts/codex-profile.sh" list | grep -q 'example -> example.config.toml / auth.json.example'

mkdir -p "${test_root}/bin"
HOME="${test_root}" "${test_root}/scripts/codex-sync-commands.sh" --target-dir "${test_root}/bin" --quiet
[[ -x "${test_root}/bin/codex-example" ]]
[[ -x "${test_root}/bin/codex-default" ]]

TEST_CODEX_ROOT="${test_root}" bash -c '
  source "${TEST_CODEX_ROOT}/scripts/codex-aliases.sh"
  alias codex-example >/dev/null
  alias codex-default >/dev/null
'

echo "codex-profile tests: ok"
