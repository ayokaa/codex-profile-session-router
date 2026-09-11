#!/usr/bin/env bash

if [[ -z "${BASH_VERSION:-}" ]]; then
  echo '请在 bash 中 source 这个文件: source "$HOME/.codex/scripts/codex-aliases.sh"' >&2
  return 1 2>/dev/null || exit 1
fi

_codex_aliases_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
_codex_root="$(cd -- "${_codex_aliases_dir}/.." && pwd)"
_codex_profile_script="${_codex_root}/scripts/codex-profile.sh"

_codex_alias_name() {
  local route_name="${1,,}"
  route_name="${route_name//[^a-z0-9._-]/-}"
  while [[ "${route_name}" == *--* ]]; do
    route_name="${route_name//--/-}"
  done
  route_name="${route_name#-}"
  route_name="${route_name%-}"
  if [[ -z "${route_name}" ]]; then
    route_name="default"
  fi
  printf 'codex-%s' "${route_name}"
}

# 登录态路由没有 auth.json.<name>，只认 <name>.auth-mode 这个持久化标记。
_codex_route_is_login_mode() {
  local mode_file="${_codex_root}/${1}.auth-mode"
  [[ -f "${mode_file}" ]] && [[ "$(tr -d '[:space:]' <"${mode_file}")" == "login" ]]
}

codex_aliases_reload() {
  local alias_name alias_value auth_path base config_path route_name

  if declare -p CODEX_PROFILE_ALIASES >/dev/null 2>&1; then
    for alias_name in "${CODEX_PROFILE_ALIASES[@]}"; do
      unalias "${alias_name}" 2>/dev/null || true
    done
  fi

  CODEX_PROFILE_ALIASES=()
  shopt -s nullglob
  for config_path in "${_codex_root}"/*.config.toml; do
    base="${config_path##*/}"
    route_name="${base%.config.toml}"
    [[ "${route_name}" == route-* ]] && continue
    if [[ "${route_name}" == "default" ]]; then
      auth_path="${_codex_root}/auth.json"
    else
      auth_path="${_codex_root}/auth.json.${route_name}"
    fi
    if [[ ! -f "${auth_path}" ]] && ! _codex_route_is_login_mode "${route_name}"; then
      continue
    fi

    alias_name="$(_codex_alias_name "${route_name}")"
    printf -v alias_value '%q ' "${_codex_profile_script}" "${route_name}"
    alias "${alias_name}=${alias_value% }"
    CODEX_PROFILE_ALIASES+=("${alias_name}")
  done
  shopt -u nullglob
}

codex_routes() {
  local alias_name
  if [[ ${#CODEX_PROFILE_ALIASES[@]} -eq 0 ]]; then
    echo "没有可用的 codex 路由。"
    return 0
  fi

  for alias_name in "${CODEX_PROFILE_ALIASES[@]}"; do
    alias "${alias_name}"
  done
}

codex_aliases_reload
