#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
用法:
  codex-session-picker.sh pick DB [CWD] [include-non-interactive]
  codex-session-picker.sh latest DB [CWD] [include-non-interactive]

从 Codex SQLite 索引中跨 provider 选择会话，只向 stdout 输出会话 UUID。
EOF
  exit 2
}

mode="${1:-}"
db_path="${2:-}"
cwd_filter="${3:-}"
include_non_interactive="${4:-false}"

if [[ "${mode}" != "pick" && "${mode}" != "latest" ]]; then
  usage
fi
if [[ -z "${db_path}" || ! -f "${db_path}" ]]; then
  echo "会话索引不存在: ${db_path}" >&2
  exit 1
fi

sql_text_literal() {
  local value="${1}"
  local hex
  hex="$(printf '%s' "${value}" | xxd -p -c 1000000)"
  printf "CAST(X'%s' AS TEXT)" "${hex}"
}

where_clause="archived = 0 AND COALESCE(NULLIF(preview, ''), NULLIF(first_user_message, ''), NULLIF(title, ''), '') <> ''"
# 与 Codex 的 resume_source_kinds 对齐：subagent 行的 source 是 JSON，必须排除。
if [[ "${include_non_interactive}" == "true" ]]; then
  where_clause+=" AND source IN ('cli', 'vscode', 'exec', 'app_server')"
else
  where_clause+=" AND source IN ('cli', 'vscode')"
fi
if [[ -n "${cwd_filter}" ]]; then
  where_clause+=" AND cwd = $(sql_text_literal "${cwd_filter}")"
fi

limit=1000
if [[ "${mode}" == "latest" ]]; then
  limit=1
fi

query="
SELECT
  id,
  datetime(updated_at, 'unixepoch', 'localtime'),
  replace(replace(replace(replace(cwd, char(27), ''), char(13), ' '), char(9), ' '), char(10), ' '),
  replace(replace(replace(replace(substr(COALESCE(NULLIF(preview, ''), NULLIF(first_user_message, ''), NULLIF(title, ''), '(无预览)'), 1, 100), char(27), ''), char(13), ' '), char(9), ' '), char(10), ' '),
  model_provider
FROM threads
WHERE ${where_clause}
ORDER BY COALESCE(updated_at_ms, updated_at * 1000) DESC, id DESC
LIMIT ${limit};
"

mapfile -t rows < <(sqlite3 -readonly -separator $'\t' -cmd '.timeout 5000' "${db_path}" "${query}")
if [[ ${#rows[@]} -eq 0 ]]; then
  if [[ -n "${cwd_filter}" ]]; then
    echo "当前目录没有可恢复的会话；可使用 resume --all 查看全部目录。" >&2
  else
    echo "没有可恢复的会话。" >&2
  fi
  exit 1
fi

if [[ "${mode}" == "latest" ]]; then
  IFS=$'\t' read -r thread_id _ <<<"${rows[0]}"
  printf '%s\n' "${thread_id}"
  exit 0
fi

if [[ ! -r /dev/tty ]]; then
  echo "跨后缀会话选择需要交互式终端。也可以直接传入会话 UUID。" >&2
  exit 1
fi

echo "可恢复会话（跨全部 provider，最多显示 ${limit} 条）:" >&2
echo >&2
for index in "${!rows[@]}"; do
  IFS=$'\t' read -r thread_id updated_at cwd preview provider <<<"${rows[index]}"
  printf '%3d) %s  %s  %s  [%s]\n' "$((index + 1))" "${thread_id:0:8}" "${updated_at}" "${preview}" "${provider}" >&2
  printf '     %s\n' "${cwd}" >&2
done

while true; do
  printf '\n输入序号、完整 UUID，或 q 取消: ' >&2
  IFS= read -r choice </dev/tty
  case "${choice}" in
    q|Q|quit|exit|"")
      exit 130
      ;;
    *[!0-9]*)
      if [[ "${choice}" =~ ^[0-9a-fA-F-]{36}$ ]]; then
        printf '%s\n' "${choice}"
        exit 0
      fi
      echo "请输入列表序号或完整 UUID。" >&2
      ;;
    *)
      choice_number=$((10#${choice}))
      if (( choice_number >= 1 && choice_number <= ${#rows[@]} )); then
        IFS=$'\t' read -r thread_id _ <<<"${rows[choice_number - 1]}"
        printf '%s\n' "${thread_id}"
        exit 0
      fi
      echo "序号超出范围。" >&2
      ;;
  esac
done
