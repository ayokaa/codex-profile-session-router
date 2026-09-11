#!/usr/bin/env bash
set -euo pipefail

# 把共享会话索引里的 model_provider 归一到同一个 id。
#
# Codex 的原生 resume 列表按“当前 profile 的 model_provider”硬过滤
# (state/src/runtime/threads.rs: AND threads.model_provider IN (...)),
# 因此历史上用其他 provider id 记录的会话（官方登录态、改名前的 provider）
# 在任何路由的列表里都看不到。恢复时请求仍以当前 profile 的 provider 与密钥为准，
# 归一只改变“列表归属”，不会把请求打回旧端点。

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
codex_root="$(cd -- "${script_dir}/.." && pwd)"
dry_run="false"
force="false"
target=""
from_list=""
db_override=""

usage() {
  cat >&2 <<'EOF'
用法:
  codex-normalize-provider.sh [--dry-run] [--to <provider-id>] [--from <id[,id...]>] [--force] [索引文件]

  --dry-run      只打印影响面，不写数据库。
  --to <id>      目标 provider id。默认取 root config.toml（其次 default.config.toml）的 model_provider。
  --from <列表>  只归一这些 id；默认归一所有不等于 --to 的 id。
  --force        跳过“Codex 正在运行”的检查。
  索引文件       默认自动选择 <codex_root>/state_*.sqlite 中版本号最高的一个。

示例:
  codex-normalize-provider.sh --dry-run
  codex-normalize-provider.sh --to localhost --from openai,OpenAI,cch
EOF
  exit 2
}

validate_id() {
  local label="${1}" value="${2}"
  if [[ -z "${value}" ]]; then
    echo "${label} 不能为空。" >&2
    exit 1
  fi
  if [[ "${value}" =~ [[:cntrl:]] ]]; then
    echo "${label} 含有换行/制表等控制字符，拒绝执行。" >&2
    exit 1
  fi
}

sql_quote() {
  local escaped="${1}"
  escaped="${escaped//\'/\'\'}"
  printf "'%s'" "${escaped}"
}

while [[ $# -gt 0 ]]; do
  case "${1}" in
    --dry-run) dry_run="true" ;;
    --force) force="true" ;;
    --to)
      if [[ $# -lt 2 ]]; then usage; fi
      target="${2}"
      shift
      ;;
    --to=*) target="${1#--to=}" ;;
    --from)
      if [[ $# -lt 2 ]]; then usage; fi
      from_list="${2}"
      shift
      ;;
    --from=*) from_list="${1#--from=}" ;;
    -h|--help) usage ;;
    --*) usage ;;
    *) db_override="${1}" ;;
  esac
  shift
done

if [[ -n "${db_override}" ]]; then
  database="${db_override}"
  if [[ ! -f "${database}" ]]; then
    echo "索引文件不存在: ${database}" >&2
    exit 1
  fi
else
  databases=()
  while IFS= read -r candidate; do
    [[ -f "${candidate}" ]] && databases+=("${candidate}")
  done < <(printf '%s\n' "${codex_root}"/state_*.sqlite | sort -V)
  if [[ ${#databases[@]} -eq 0 ]]; then
    echo "Codex 会话索引不存在: ${codex_root}/state_*.sqlite" >&2
    exit 1
  fi
  database="${databases[-1]}"
fi

if [[ -z "${target}" ]]; then
  target=""
  for candidate in "${codex_root}/config.toml" "${codex_root}/default.config.toml"; do
    [[ -f "${candidate}" ]] || continue
    target="$(sed -nE 's/^[[:space:]]*model_provider[[:space:]]*=[[:space:]]*"([A-Za-z0-9_-]+)"[[:space:]]*(#.*)?$/\1/p' "${candidate}" | head -n 1)"
    [[ -n "${target}" ]] && break
  done
  if [[ -z "${target}" ]]; then
    echo "需要 --to <provider-id>：${codex_root}/config.toml 和 default.config.toml 都没有 model_provider。" >&2
    usage
  fi
fi
validate_id "--to" "${target}"

from_ids=()
if [[ -n "${from_list}" ]]; then
  remaining="${from_list}"
  while [[ -n "${remaining}" ]]; do
    entry="${remaining%%,*}"
    if [[ "${entry}" == "${remaining}" ]]; then
      remaining=""
    else
      remaining="${remaining#*,}"
    fi
    entry="${entry#"${entry%%[![:space:]]*}"}"
    entry="${entry%"${entry##*[![:space:]]}"}"
    if [[ -n "${entry}" ]]; then
      from_ids+=("${entry}")
    fi
  done
else
  while IFS= read -r recorded; do
    if [[ -n "${recorded}" ]]; then
      from_ids+=("${recorded}")
    fi
  done < <(sqlite3 -readonly "${database}" \
    "SELECT DISTINCT model_provider FROM threads WHERE model_provider <> $(sql_quote "${target}") ORDER BY 1;")
fi

provider_sql=""
for id in ${from_ids[@]+"${from_ids[@]}"}; do
  validate_id "--from" "${id}"
  if [[ "${id}" == "${target}" ]]; then
    continue
  fi
  if [[ -n "${provider_sql}" ]]; then
    provider_sql+=", "
  fi
  provider_sql+="$(sql_quote "${id}")"
done

if [[ -z "${provider_sql}" ]]; then
  echo "索引文件: ${database}"
  echo "没有需要归一的 provider id（目标已是 ${target}）。"
  exit 0
fi
provider_sql="(${provider_sql})"

if [[ "${dry_run}" != "true" && "${force}" != "true" ]] \
  && pgrep -x codex >/dev/null 2>&1; then
  echo "检测到 Codex 正在运行；归一期间新建的会话不会被更新。" >&2
  echo "请退出所有 Codex 后重试，或使用 --force。" >&2
  exit 1
fi

echo "索引文件: ${database}"
echo "目标 provider: ${target}"
echo "影响面:"
sqlite3 -readonly "${database}" \
  "SELECT '  ' || model_provider || '  ->  ${target}   (' || COUNT(*) || ' 条)'
   FROM threads WHERE model_provider IN ${provider_sql}
   GROUP BY model_provider ORDER BY COUNT(*) DESC, model_provider;"
affected="$(sqlite3 -readonly "${database}" \
  "SELECT COUNT(*) FROM threads WHERE model_provider IN ${provider_sql};")"
if [[ "${affected}" == "0" ]]; then
  echo "没有需要归一的行。"
  exit 0
fi
echo "合计: ${affected} 条"

if [[ "${dry_run}" == "true" ]]; then
  echo "--dry-run：未写入。"
  exit 0
fi

backup_dir="${codex_root}/.backups/provider-normalize"
mkdir -p "${backup_dir}"
backup_path="${backup_dir}/${database##*/}"
suffix=1
while [[ -e "${backup_path}" ]]; do
  backup_path="${backup_dir}/${database##*/}.${suffix}"
  suffix=$((suffix + 1))
done
sqlite3 "${database}" ".backup $(sql_quote "${backup_path}")"
chmod 600 "${backup_path}"
echo "已备份: ${backup_path}"

sqlite3 -cmd '.timeout 10000' "${database}" <<EOF
BEGIN IMMEDIATE;
UPDATE threads SET model_provider = $(sql_quote "${target}") WHERE model_provider IN ${provider_sql};
COMMIT;
EOF

still_other="$(sqlite3 -readonly "${database}" \
  "SELECT COUNT(*) FROM threads WHERE model_provider <> $(sql_quote "${target}");")"
printf '归一完成: 更新 %s 条，仍属于其他 provider 的会话 %s 条\n' "${affected}" "${still_other}"
echo "注意: rollout JSONL 里的 session_meta.model_provider 保持原值（原生列表只读 SQLite，不影响可见性）。"
