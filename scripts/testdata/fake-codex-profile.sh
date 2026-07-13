#!/usr/bin/env bash
set -euo pipefail

[[ "${CODEX_API_KEY:-}" == "suffix-test-key" ]]
[[ "${OPENAI_API_KEY:-}" == "suffix-test-key" ]]

profile=""
previous=""
for argument in "$@"; do
  if [[ "${previous}" == "--profile" ]]; then
    profile="${argument}"
  fi
  previous="${argument}"
done

[[ "${profile}" == "example" ]]
profile_config="${CODEX_HOME}/${profile}.config.toml"
[[ -f "${profile_config}" ]]
grep -q 'model = "profile-model"' "${profile_config}"
grep -q 'env_key = "OPENAI_API_KEY"' "${profile_config}"
grep -q 'requires_openai_auth = false' "${profile_config}"

if [[ -n "${FAKE_EXPECT_RESUME_ID:-}" ]]; then
  printf '%s\n' "$@" | grep -qx "${FAKE_EXPECT_RESUME_ID}"
fi

if [[ "${FAKE_EDIT_PROFILE:-false}" == "true" ]]; then
  sed -i 's/profile-model/tui-model/' "${profile_config}"
fi
