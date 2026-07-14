#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
codex_root="$(cd -- "${script_dir}/.." && pwd)"
sync_script="${codex_root}/scripts/codex-sync-commands.sh"
bash_rc_file="${HOME}/.bashrc"
fish_config_dir="${XDG_CONFIG_HOME:-${HOME}/.config}/fish/conf.d"
fish_config_file="${fish_config_dir}/codex-profile-commands.fish"
fish_source_file="${script_dir}/codex-profile-commands.fish"
hook_start='# >>> codex profile commands >>>'
hook_line='[ -x "$HOME/.codex/scripts/codex-sync-commands.sh" ] && "$HOME/.codex/scripts/codex-sync-commands.sh" --quiet >/dev/null 2>&1 || true'
hook_end='# <<< codex profile commands <<<'

usage() {
  cat <<'EOF'
用法:
  install-codex-command-sync.sh

说明:
  1. 立即同步 codex-* 命令到 ~/.local/bin
  2. 向 ~/.bashrc 写入 Bash 自动同步钩子
  3. 安装 fish conf.d 集成，自动加入 PATH 并同步命令
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

if [[ ! -f "${bash_rc_file}" ]] || ! grep -Fq "${hook_start}" "${bash_rc_file}"; then
  {
    printf '\n%s\n' "${hook_start}"
    printf '%s\n' "${hook_line}"
    printf '%s\n' "${hook_end}"
  } >> "${bash_rc_file}"
fi

if [[ ! -f "${fish_source_file}" ]]; then
  echo "fish 集成模板不存在: ${fish_source_file}" >&2
  exit 1
fi
mkdir -p "${fish_config_dir}"
install -m 644 "${fish_source_file}" "${fish_config_file}"

echo "已安装 codex 命令自动同步"
echo "命令目录: ${HOME}/.local/bin"
echo "Bash 钩子: ${bash_rc_file}"
echo "fish 集成: ${fish_config_file}"
