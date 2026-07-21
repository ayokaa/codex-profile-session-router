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
printf '%s\n' "$@" | grep -qx 'model_providers.localhost.env_key="OPENAI_API_KEY"'
printf '%s\n' "$@" | grep -qx 'model_providers.localhost.requires_openai_auth=false'

if [[ "${FAKE_EXPECT_NATIVE_RESUME:-false}" == "true" ]]; then
  printf '%s\n' "$@" | grep -qx 'resume'
  printf '%s\n' "$@" | grep -qx -- '--all'
  if printf '%s\n' "$@" | grep -Eq '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'; then
    echo "原生 resume UI 路径不应预先注入会话 UUID" >&2
    exit 1
  fi
fi

if [[ -n "${FAKE_EXPECT_RESUME_ID:-}" ]]; then
  printf '%s\n' "$@" | grep -qx "${FAKE_EXPECT_RESUME_ID}"
fi

if [[ "${FAKE_EXPECT_REWRITTEN_LAST:-false}" == "true" ]] \
  && printf '%s\n' "$@" | grep -qx -- '--last'; then
  echo "resume --last 应在启动 Codex 前改写为会话 UUID" >&2
  exit 1
fi

if [[ "${FAKE_EDIT_PROFILE:-false}" == "true" ]]; then
  sed -i 's/profile-model/tui-model/' "${profile_config}"
fi
