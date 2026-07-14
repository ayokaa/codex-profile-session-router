#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
codex_home="${CODEX_HOME:-${HOME}/.codex}"
target_scripts="${codex_home}/scripts"

mkdir -p "${target_scripts}/testdata"
install -m 755 \
  "${repo_root}/scripts/codex-profile.sh" \
  "${repo_root}/scripts/codex-session-picker.sh" \
  "${repo_root}/scripts/codex-migrate-to-root.sh" \
  "${repo_root}/scripts/codex-sync-commands.sh" \
  "${repo_root}/scripts/install-codex-command-sync.sh" \
  "${repo_root}/scripts/test-codex-profile.sh" \
  "${repo_root}/scripts/test-codex-profile-e2e.sh" \
  "${target_scripts}/"
install -m 644 "${repo_root}/scripts/codex-aliases.sh" "${target_scripts}/codex-aliases.sh"
install -m 644 \
  "${repo_root}/scripts/codex-profile-commands.fish" \
  "${target_scripts}/codex-profile-commands.fish"
install -m 755 \
  "${repo_root}/scripts/testdata/fake-codex-profile.sh" \
  "${target_scripts}/testdata/fake-codex-profile.sh"
install -m 755 \
  "${repo_root}/scripts/testdata/mock-codex-responses.py" \
  "${target_scripts}/testdata/mock-codex-responses.py"

echo "脚本已安装到: ${target_scripts}"
echo "请先创建固定 profile 与对应 auth，再运行:"
echo "  ${target_scripts}/install-codex-command-sync.sh"
