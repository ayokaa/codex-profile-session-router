#!/usr/bin/env bash
set -euo pipefail

if [[ "${FAKE_EXPECT_LOGIN:-false}" == "true" ]]; then
  if [[ -n "${CODEX_API_KEY:-}" ]]; then
    echo "login 路由不应注入 CODEX_API_KEY" >&2
    exit 1
  fi
  if [[ -n "${OPENAI_API_KEY:-}" ]]; then
    echo "login 路由不应注入 OPENAI_API_KEY" >&2
    exit 1
  fi
  if printf '%s\n' "$@" | grep -q 'model_providers\.'; then
    echo "login 路由不应改写 provider 鉴权" >&2
    exit 1
  fi
else
  [[ "${CODEX_API_KEY:-}" == "suffix-test-key" ]]
  [[ "${OPENAI_API_KEY:-}" == "suffix-test-key" ]]
fi

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
if [[ "${FAKE_EXPECT_LOGIN:-false}" != "true" ]]; then
  printf '%s\n' "$@" | grep -qx 'model_providers.localhost.env_key="OPENAI_API_KEY"'
  printf '%s\n' "$@" | grep -qx 'model_providers.localhost.requires_openai_auth=false'
fi

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
