#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
codex_root="$(cd -- "${script_dir}/.." && pwd)"
session_picker="${script_dir}/codex-session-picker.sh"
session_lock_dir="${codex_root}/.locks/sessions"
codex_bin="${CODEX_PROFILE_CODEX_BIN:-codex}"

usage() {
  cat >&2 <<'EOF'
用法:
  codex-profile.sh list
  codex-profile.sh <profile|配置文件名> [codex 参数...]

路由规则:
  default                 -> default.config.toml + 共享 auth.json（见下方提醒）
  example                 -> example.config.toml + auth.json.example
  example.config.toml     -> 自动解析 profile example
  config.toml.example     -> 仅把旧名称解析为 profile example，不读取该文件
  auth.json.example       -> 自动解析 profile example

提醒: --profile default 对 Codex 没有任何特殊含义，裸 codex 只读 root config.toml，
不会读 default.config.toml。但这个脚本把 default 路由的鉴权文件指向共享 auth.json，
而 codex login 会重写那个文件，所以建议给每个端点单独起名字，登录态交给 root config。

共享会话:
  所有路由直接使用 ~/.codex 作为唯一 CODEX_HOME。
  直接使用固定的 <profile>.config.toml 和 Codex 原生 --profile。
  CODEX_API_KEY 与 OPENAI_API_KEY 都只注入当前进程。

鉴权模式:
  apikey (默认)  读取路由鉴权文件的 OPENAI_API_KEY，并把该 provider 改成 env_key 鉴权。
  login          不改写 provider 鉴权，沿用共享 auth.json 的 ChatGPT 登录态。开启方式：
                 <profile>.auth-mode 内容为 login，或环境变量 CODEX_PROFILE_AUTH=login
                 （后者优先）。该模式下 provider 表若还带 env_key/base_url 会拒绝启动，
                 否则会把自己的登录 token 发到第三方端点；官方登录态共享会话请写在
                 root config.toml 里，让裸 codex 和路由同一个桶。

示例:
  codex-profile.sh list
  codex-profile.sh example
  codex-profile.sh tmp
  codex-profile.sh .tmp exec -C /tmp --skip-git-repo-check --sandbox read-only "你好"

加载 alias:
  source ${HOME}/.codex/scripts/codex-aliases.sh
EOF
  exit 2
}

list_routes() {
  local config_path base profile auth_path auth_mode_file auth_mode
  shopt -s nullglob
  for config_path in "${codex_root}"/*.config.toml; do
    base="${config_path##*/}"
    profile="${base%.config.toml}"
    [[ "${profile}" == route-* ]] && continue
    if [[ "${profile}" == "default" ]]; then
      auth_path="${codex_root}/auth.json"
    else
      auth_path="${codex_root}/auth.json.${profile}"
    fi
    auth_mode="${CODEX_PROFILE_AUTH:-}"
    if [[ -z "${auth_mode}" ]]; then
      auth_mode="apikey"
      auth_mode_file="$(route_auth_mode_file "${profile}")"
      if [[ -f "${auth_mode_file}" && "$(tr -d '[:space:]' <"${auth_mode_file}")" == "login" ]]; then
        auth_mode="login"
      fi
    fi
    if [[ ! -f "${auth_path}" && "${auth_mode}" != "login" ]]; then
      continue
    fi
    if [[ "${auth_mode}" == "login" ]]; then
      printf '  %s -> %s / 共享 auth.json (login)\n' "${profile}" "${base}"
    else
      printf '  %s -> %s / %s\n' "${profile}" "${base}" "${auth_path##*/}"
    fi
  done
  shopt -u nullglob
}

profile_name() {
  local raw="${1}"

  if [[ ! "${raw}" =~ ^[A-Za-z0-9_-]+$ ]]; then
    echo "路由后缀不符合 Codex --profile 规则: ${raw}" >&2
    echo "只允许字母、数字、下划线和连字符。" >&2
    exit 1
  fi
  printf '%s' "${raw}"
}

read_api_key() {
  local auth_path="${1}"
  local api_key

  api_key="$(jq -er '.OPENAI_API_KEY // empty' "${auth_path}")" || {
    echo "鉴权文件缺少 OPENAI_API_KEY: ${auth_path}" >&2
    echo "登录态路由请写一个 ${profile}.auth-mode 文件（内容为 login）或设置 CODEX_PROFILE_AUTH=login。" >&2
    exit 1
  }
  printf '%s' "${api_key}"
}

route_auth_mode_file() {
  printf '%s' "${codex_root}/${1}.auth-mode"
}

resolve_auth_mode() {
  local profile="${1}"
  local auth_path="${2}"
  local mode="${CODEX_PROFILE_AUTH:-}"

  case "${mode}" in
    login|apikey)
      printf '%s' "${mode}"
      return
      ;;
    "")
      ;;
    *)
      echo "CODEX_PROFILE_AUTH 只支持 login 或 apikey，当前为: ${mode}" >&2
      exit 1
      ;;
  esac

  local auth_mode_file
  auth_mode_file="$(route_auth_mode_file "${profile}")"
  if [[ -f "${auth_mode_file}" ]]; then
    mode="$(tr -d '[:space:]' <"${auth_mode_file}")"
    case "${mode}" in
      login|apikey)
        printf '%s' "${mode}"
        return
        ;;
      *)
        echo "${auth_mode_file} 的内容只支持 login 或 apikey，当前为: ${mode}" >&2
        exit 1
        ;;
    esac
  fi

  if [[ ! -f "${auth_path}" ]]; then
    printf 'apikey'
    return
  fi
  if [[ -n "$(jq -r '.OPENAI_API_KEY // empty' "${auth_path}")" ]]; then
    printf 'apikey'
    return
  fi
  if jq -e 'has("tokens") or (.auth_mode == "chatgpt")' "${auth_path}" >/dev/null 2>&1; then
    printf 'login'
    return
  fi
  echo "鉴权文件既没有 OPENAI_API_KEY，也不是 ChatGPT 登录态: ${auth_path}" >&2
  echo "请设置 CODEX_PROFILE_AUTH=login|apikey，或写入 ${profile}.auth-mode。" >&2
  exit 1
}

read_model_provider() {
  local profile_config="${1}"
  local provider

  provider="$(sed -nE 's/^[[:space:]]*model_provider[[:space:]]*=[[:space:]]*"([A-Za-z0-9_-]+)"[[:space:]]*(#.*)?$/\1/p' "${profile_config}" | head -n 1)"
  if [[ -z "${provider}" && -f "${codex_root}/config.toml" ]]; then
    provider="$(sed -nE 's/^[[:space:]]*model_provider[[:space:]]*=[[:space:]]*"([A-Za-z0-9_-]+)"[[:space:]]*(#.*)?$/\1/p' "${codex_root}/config.toml" | head -n 1)"
  fi
  if [[ -z "${provider}" ]]; then
    echo "无法从配置解析 model_provider: ${profile_config}" >&2
    exit 1
  fi
  printf '%s' "${provider}"
}

# login 模式下 Codex 用的是共享 ChatGPT token：provider 表里残留 env_key 会
# 因为环境变量缺失直接报错，残留 base_url 则会把 token 发到第三方端点。
provider_keys_forbidden_in_login_mode() {
  local profile_config="${1}"
  local provider_id="${2}"

  awk -v id="${provider_id}" '
    /^[[:space:]]*\[/ {
      in_table = ($0 ~ "^[[:space:]]*\\[model_providers\\." id "\\][[:space:]]*$")
      next
    }
    in_table && /^[[:space:]]*(env_key|base_url)[[:space:]]*=[[:space:]]*"[^"]/ {
      key = $0
      sub(/[[:space:]]*=.*/, "", key)
      gsub(/^[[:space:]]+/, "", key)
      value = $0
      sub(/^[^=]*=[[:space:]]*"/, "", value)
      sub(/".*/, "", value)
      print key "\t" value
    }
  ' "${profile_config}"
}

state_database_path() {
  local -a databases=()
  local database

  shopt -s nullglob
  databases=("${codex_root}"/state_*.sqlite)
  shopt -u nullglob
  if [[ ${#databases[@]} -eq 0 ]]; then
    echo "Codex 会话索引不存在: ${codex_root}/state_*.sqlite" >&2
    return 1
  fi

  database="$(printf '%s\n' "${databases[@]}" | sort -V | tail -n 1)"
  printf '%s' "${database}"
}

has_resume_session_argument() {
  local -a args=("$@")
  local index=0 token

  while (( index < ${#args[@]} )); do
    token="${args[index]}"
    case "${token}" in
      --)
        index=$((index + 1))
        (( index < ${#args[@]} )) && return 0
        return 1
        ;;
      -c|--config|--enable|--disable|-i|--image|-m|--model|--local-provider|-p|--profile|-s|--sandbox|-C|--cd|--add-dir|-a|--ask-for-approval|--remote|--remote-auth-token-env)
        index=$((index + 2))
        ;;
      --config=*|--enable=*|--disable=*|--image=*|--model=*|--local-provider=*|--profile=*|--sandbox=*|--cd=*|--add-dir=*|--ask-for-approval=*|--remote=*|--remote-auth-token-env=*)
        index=$((index + 1))
        ;;
      --all|--include-non-interactive|--strict-config|--oss|--search|--no-alt-screen|--dangerously-bypass-approvals-and-sandbox|--dangerously-bypass-hook-trust)
        index=$((index + 1))
        ;;
      -*)
        index=$((index + 1))
        ;;
      *)
        return 0
        ;;
    esac
  done
  return 1
}

prepare_root_resume() {
  local -a original=("$@") rewritten=()
  local action="${original[0]}"
  local cwd_filter="${PWD}"
  local include_non_interactive="false"
  local latest="false"
  local token thread_id state_db

  for token in "${original[@]:1}"; do
    case "${token}" in
      -h|--help|-V|--version|--remote|--remote=*)
        CODEX_PROFILE_ARGS=("${original[@]}")
        return 0
        ;;
      --all)
        cwd_filter=""
        ;;
      --include-non-interactive)
        include_non_interactive="true"
        ;;
      --last)
        latest="true"
        ;;
    esac
  done

  if [[ "${latest}" == "true" ]]; then
    state_db="$(state_database_path)"
    thread_id="$("${session_picker}" latest "${state_db}" "${cwd_filter}" "${include_non_interactive}")"
    rewritten+=("${action}")
    for token in "${original[@]:1}"; do
      if [[ "${token}" == "--last" ]]; then
        rewritten+=("${thread_id}")
      else
        rewritten+=("${token}")
      fi
    done
    CODEX_PROFILE_ARGS=("${rewritten[@]}")
    return 0
  fi

  if [[ "${action}" == "resume" ]]; then
    CODEX_PROFILE_ARGS=("${original[@]}")
    return 0
  fi

  if has_resume_session_argument "${original[@]:1}"; then
    CODEX_PROFILE_ARGS=("${original[@]}")
    return 0
  fi

  state_db="$(state_database_path)"
  thread_id="$("${session_picker}" pick "${state_db}" "${cwd_filter}" "${include_non_interactive}")"
  CODEX_PROFILE_ARGS=("${action}" "${thread_id}" "${original[@]:1}")
}

resume_session_argument() {
  local -a args=("$@")
  local index=0 token

  while (( index < ${#args[@]} )); do
    token="${args[index]}"
    case "${token}" in
      --)
        index=$((index + 1))
        (( index < ${#args[@]} )) && printf '%s' "${args[index]}"
        return 0
        ;;
      -c|--config|--enable|--disable|-i|--image|-m|--model|--local-provider|-p|--profile|-s|--sandbox|-C|--cd|--add-dir|-a|--ask-for-approval|--remote|--remote-auth-token-env)
        index=$((index + 2))
        ;;
      --config=*|--enable=*|--disable=*|--image=*|--model=*|--local-provider=*|--profile=*|--sandbox=*|--cd=*|--add-dir=*|--ask-for-approval=*|--remote=*|--remote-auth-token-env=*|--all|--include-non-interactive|--strict-config|--oss|--search|--no-alt-screen|--dangerously-bypass-approvals-and-sandbox|--dangerously-bypass-hook-trust)
        index=$((index + 1))
        ;;
      -*)
        index=$((index + 1))
        ;;
      *)
        printf '%s' "${token}"
        return 0
        ;;
    esac
  done
}

normalize_profile() {
  local raw="${1:-}"

  case "${raw}" in
    ""|default|config.toml|default.config.toml|auth.json)
      printf '%s' "default"
      ;;
    *.config.toml)
      printf '%s' "${raw%.config.toml}"
      ;;
    config.toml.*)
      printf '%s' "${raw#config.toml.}"
      ;;
    auth.json.*)
      printf '%s' "${raw#auth.json.}"
      ;;
    .*)
      printf '%s' "${raw#.}"
      ;;
    *)
      printf '%s' "${raw}"
      ;;
  esac
}

selector="${1:-}"
if [[ -z "${selector}" ]]; then
  usage
fi
shift

case "${selector}" in
  list|ls|--list)
    echo "可用路由:"
    list_routes
    exit 0
    ;;
esac

profile="$(profile_name "$(normalize_profile "${selector}")")"
src_config="${codex_root}/${profile}.config.toml"
if [[ "${profile}" == "default" ]]; then
  src_auth="${codex_root}/auth.json"
else
  src_auth="${codex_root}/auth.json.${profile}"
fi

if [[ ! -f "${src_config}" ]]; then
  echo "配置文件不存在: ${src_config}" >&2
  echo "可用路由:" >&2
  list_routes >&2
  exit 1
fi

auth_mode="$(resolve_auth_mode "${profile}" "${src_auth}")"

if [[ "${auth_mode}" == "apikey" && ! -f "${src_auth}" ]]; then
  echo "鉴权文件不存在: ${src_auth}" >&2
  echo "可用路由:" >&2
  list_routes >&2
  exit 1
fi

export CODEX_HOME="${codex_root}"
provider_flags=()
if [[ "${auth_mode}" == "apikey" ]]; then
  provider_id="$(read_model_provider "${src_config}")"
  api_key="$(read_api_key "${src_auth}")"
  export CODEX_API_KEY="${api_key}"
  export OPENAI_API_KEY="${api_key}"
  unset api_key
  provider_flags=(
    -c "model_providers.${provider_id}.env_key=\"OPENAI_API_KEY\""
    -c "model_providers.${provider_id}.requires_openai_auth=false"
  )
else
  provider_id="$(read_model_provider "${src_config}")"
  forbidden="$(provider_keys_forbidden_in_login_mode "${src_config}" "${provider_id}")"
  if [[ -n "${forbidden}" ]]; then
    echo "路由 ${profile} 解析为 login 模式，但 ${provider_id} provider 还配置了:" >&2
    while IFS=$'\t' read -r forbidden_key forbidden_value; do
      [[ -n "${forbidden_key}" ]] || continue
      echo "  ${forbidden_key} = \"${forbidden_value}\"" >&2
    done <<<"${forbidden}"
    forbidden_url="$(awk -F'\t' '$1 == "base_url" { print $2; exit }' <<<"${forbidden}")"
    if [[ -n "${forbidden_url}" ]]; then
      echo "登录态只会带 ChatGPT token，这个端点会收到它: ${forbidden_url}" >&2
    fi
    echo "二选一:" >&2
    echo "  1) 该路由继续走 API key: 把 OPENAI_API_KEY 写回 ${src_auth}" >&2
    echo "  2) 走登录态共享会话: 用裸 codex（root config 的 provider 表不带 env_key/base_url），或为登录态单独建一个 profile" >&2
    exit 1
  fi
  unset CODEX_API_KEY OPENAI_API_KEY
fi

CODEX_PROFILE_ARGS=("$@")
if [[ ${#CODEX_PROFILE_ARGS[@]} -gt 0 && ( "${CODEX_PROFILE_ARGS[0]}" == "resume" || "${CODEX_PROFILE_ARGS[0]}" == "fork" ) ]]; then
  prepare_root_resume "${CODEX_PROFILE_ARGS[@]}"
fi

codex_command=(
  "${codex_bin}"
  -c 'shell_environment_policy.ignore_default_excludes=false'
  "${provider_flags[@]}"
  --disable shell_snapshot
  --profile "${profile}"
  "${CODEX_PROFILE_ARGS[@]}"
)
if [[ ${#CODEX_PROFILE_ARGS[@]} -gt 0 && "${CODEX_PROFILE_ARGS[0]}" == "resume" ]]; then
  resume_id="$(resume_session_argument "${CODEX_PROFILE_ARGS[@]:1}")"
  if [[ "${resume_id}" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then
    mkdir -p "${session_lock_dir}"
    exec {session_lock_fd}>"${session_lock_dir}/${resume_id,,}.lock"
    if ! flock -n "${session_lock_fd}"; then
      echo "该会话已被另一个 Codex 进程恢复: ${resume_id}" >&2
      exit 75
    fi
  fi
fi
exec "${codex_command[@]}"
