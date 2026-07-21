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
  codex-profile.sh default [codex 参数...]
  codex-profile.sh <profile|配置文件名> [codex 参数...]

路由规则:
  default             -> default.config.toml + auth.json
  example                 -> example.config.toml + auth.json.example
  example.config.toml     -> 自动解析 profile example
  config.toml.example     -> 仅把旧名称解析为 profile example，不读取该文件
  auth.json.example       -> 自动解析 profile example

共享会话:
  所有路由直接使用 ~/.codex 作为唯一 CODEX_HOME。
  直接使用固定的 <profile>.config.toml 和 Codex 原生 --profile。
  CODEX_API_KEY 与 OPENAI_API_KEY 都只注入当前进程。

示例:
  codex-profile.sh list
  codex-profile.sh default
  codex-profile.sh tmp
  codex-profile.sh .tmp exec -C /tmp --skip-git-repo-check --sandbox read-only "你好"

加载 alias:
  source ${HOME}/.codex/scripts/codex-aliases.sh
EOF
  exit 2
}

list_routes() {
  local config_path base profile auth_path
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
    if [[ ! -f "${auth_path}" ]]; then
      continue
    fi
    printf '  %s -> %s / %s\n' "${profile}" "${base}" "${auth_path##*/}"
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
    echo "当前共享会话模式只支持 API key 鉴权。" >&2
    exit 1
  }
  printf '%s' "${api_key}"
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

if [[ ! -f "${src_auth}" ]]; then
  echo "鉴权文件不存在: ${src_auth}" >&2
  echo "可用路由:" >&2
  list_routes >&2
  exit 1
fi

api_key="$(read_api_key "${src_auth}")"
export CODEX_API_KEY="${api_key}"
export OPENAI_API_KEY="${api_key}"
unset api_key
provider_id="$(read_model_provider "${src_config}")"

export CODEX_HOME="${codex_root}"
CODEX_PROFILE_ARGS=("$@")
if [[ ${#CODEX_PROFILE_ARGS[@]} -gt 0 && ( "${CODEX_PROFILE_ARGS[0]}" == "resume" || "${CODEX_PROFILE_ARGS[0]}" == "fork" ) ]]; then
  prepare_root_resume "${CODEX_PROFILE_ARGS[@]}"
fi

codex_command=(
  "${codex_bin}"
  -c 'shell_environment_policy.ignore_default_excludes=false'
  -c "model_providers.${provider_id}.env_key=\"OPENAI_API_KEY\""
  -c "model_providers.${provider_id}.requires_openai_auth=false"
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
