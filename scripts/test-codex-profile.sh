#!/usr/bin/env bash
set -euo pipefail

source_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d /tmp/codex-profile-test.XXXXXX)"
trap 'rm -rf -- "${test_root}"' EXIT

mkdir -p "${test_root}/scripts"
install -m 755 "${source_root}/scripts/codex-profile.sh" "${test_root}/scripts/codex-profile.sh"
install -m 755 "${source_root}/scripts/codex-session-picker.sh" "${test_root}/scripts/codex-session-picker.sh"
install -m 755 "${source_root}/scripts/codex-sync-commands.sh" "${test_root}/scripts/codex-sync-commands.sh"
install -m 755 "${source_root}/scripts/install-codex-command-sync.sh" "${test_root}/scripts/install-codex-command-sync.sh"
install -m 644 "${source_root}/scripts/codex-aliases.sh" "${test_root}/scripts/codex-aliases.sh"
install -m 644 "${source_root}/scripts/codex-profile-commands.fish" "${test_root}/scripts/codex-profile-commands.fish"

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
  'requires_openai_auth = true' \
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
sqlite3 "${test_root}/state_5.sqlite" "
  CREATE TABLE threads (
    id TEXT PRIMARY KEY,
    archived INTEGER NOT NULL DEFAULT 0,
    preview TEXT,
    first_user_message TEXT,
    title TEXT,
    source TEXT,
    cwd TEXT,
    updated_at INTEGER,
    updated_at_ms INTEGER
  );
  INSERT INTO threads (
    id, archived, preview, source, cwd, updated_at, updated_at_ms
  ) VALUES (
    '${resume_id}', 0, 'latest session', 'cli', '/tmp', 1, 1000
  );
"
FAKE_EXPECT_NATIVE_RESUME=true "${route[@]}" resume --all
FAKE_EXPECT_RESUME_ID="${resume_id}" "${route[@]}" resume "${resume_id}" --all
FAKE_EXPECT_REWRITTEN_LAST=true FAKE_EXPECT_RESUME_ID="${resume_id}" \
  "${route[@]}" resume --last --all

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

HOME="${test_root}" XDG_CONFIG_HOME="${test_root}/.config" \
  "${test_root}/scripts/install-codex-command-sync.sh" >/dev/null
[[ -f "${test_root}/.config/fish/conf.d/codex-profile-commands.fish" ]]
grep -q 'set -gx PATH' "${test_root}/.config/fish/conf.d/codex-profile-commands.fish"

if [[ -n "${CODEX_PROFILE_TEST_FISH_BIN:-}" ]]; then
  fish_resume_id="019f5742-1549-7ad2-ae54-42a19dfa341"
  sed -i 's/tui-model/profile-model/' "${test_root}/example.config.toml"
  HOME="${test_root}" XDG_CONFIG_HOME="${test_root}/.config" TEST_RESUME_ID="${fish_resume_id}" \
    "${CODEX_PROFILE_TEST_FISH_BIN}" --interactive -c '
      test (command -s codex-example) = "$HOME/.local/bin/codex-example"; or begin
        echo "fish resolved unexpected codex-example path: "(command -s codex-example) >&2
        exit 1
      end
      test (command -s codex-default) = "$HOME/.local/bin/codex-default"; or begin
        echo "fish resolved unexpected codex-default path: "(command -s codex-default) >&2
        exit 1
      end
      codex-routes | string match -q "*example -> example.config.toml / auth.json.example*"; or begin
        echo "fish route listing failed" >&2
        exit 1
      end
      env CODEX_PROFILE_CODEX_BIN="$HOME/fake-codex" \
        FAKE_EXPECT_RESUME_ID="$TEST_RESUME_ID" \
        codex-example resume "$TEST_RESUME_ID" --all; or begin
        echo "fish argument forwarding failed" >&2
        exit 1
      end
    '
fi

if [[ "${CODEX_PROFILE_TEST_SKIP_E2E:-false}" != "true" ]]; then
  "${source_root}/scripts/test-codex-profile-e2e.sh"
fi

echo "codex-profile tests: ok"
