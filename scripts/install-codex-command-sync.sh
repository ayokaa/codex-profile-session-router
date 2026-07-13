#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
codex_root="$(cd -- "${script_dir}/.." && pwd)"
sync_script="${codex_root}/scripts/codex-sync-commands.sh"
rc_file="${HOME}/.bashrc"
hook_start='# >>> codex profile commands >>>'
hook_line='[ -x "$HOME/.codex/scripts/codex-sync-commands.sh" ] && "$HOME/.codex/scripts/codex-sync-commands.sh" --quiet >/dev/null 2>&1 || true'
hook_end='# <<< codex profile commands <<<'

usage() {
  cat <<'EOF'
用法:
  install-codex-command-sync.sh

说明:
  1. 立即同步 codex-* 命令到 ~/.local/bin
  2. 向 ~/.bashrc 写入自动同步钩子
EOF
}

if [[ $# -gt 0 ]]; then
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "未知参数: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
fi

mkdir -p "${HOME}/.local/bin"
"${sync_script}" --quiet

if [[ -f "${rc_file}" ]] && grep -Fq "${hook_start}" "${rc_file}"; then
  echo "bash 自动同步已存在: ${rc_file}"
  exit 0
fi

{
  printf '\n%s\n' "${hook_start}"
  printf '%s\n' "${hook_line}"
  printf '%s\n' "${hook_end}"
} >> "${rc_file}"

echo "已安装 codex 命令自动同步"
echo "命令目录: ${HOME}/.local/bin"
echo "shell 钩子: ${rc_file}"
