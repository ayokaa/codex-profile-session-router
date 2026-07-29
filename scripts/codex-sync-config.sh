#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
codex_root="$(cd -- "${script_dir}/.." && pwd)"
source_config="${codex_root}/config.toml"
dry_run="false"
quiet="false"

usage() {
  cat <<'EOF'
用法:
  codex-sync-config.sh [--dry-run] [--quiet]

说明:
  以 ~/.codex/config.toml 为权威源,把其中除模型与端点外的通用设置
  增量同步到各个 <name>.config.toml。

受保护(保留各 profile 自有值,不参与同步):
  - 顶层 model、model_provider
  - 整个 [model_providers.*] 段

合并语义:
  增量合并——权威源的设置覆盖 profile 同名项;profile 中源没有的设置保留。
  实际写入前自动备份到 <name>.config.toml.bak;--dry-run 只预览差异,不写入。
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) dry_run="true"; shift ;;
    --quiet) quiet="true"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "未知参数: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ ! -f "${source_config}" ]]; then
  [[ "$quiet" != "true" ]] && echo "权威源配置不存在,跳过同步: ${source_config}" >&2
  exit 0
fi

# parse_toml FILE
# 把 toml 解析为结构化记录,字段以 \x1f 分隔,供 bash 读取:
#   TOP\x1f<key>\x1f<rawline>           顶层 kv(注释/空行忽略)
#   SECSTART\x1f<sec>\x1f<headerline>   段头
#   SECLINE\x1f<sec>\x1f<rawline>       段内行(原样,含注释/kv/空行)
parse_toml() {
  awk -v OFS='\x1f' '
    function trim(s) { sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s); return s }
    {
      line = $0
      if (line ~ /^[[:space:]]*\[[^]]+\][[:space:]]*$/) {
        sec = line
        sub(/^[[:space:]]*\[/, "", sec)
        sub(/\][[:space:]]*$/, "", sec)
        in_sec = trim(sec)
        print "SECSTART", in_sec, line
        next
      }
      if (in_sec == "") {
        if (line ~ /^[[:space:]]*#/ || line ~ /^[[:space:]]*$/) next
        eq = index(line, "=")
        if (eq > 0) {
          key = trim(substr(line, 1, eq - 1))
          print "TOP", key, line
        }
      } else {
        print "SECLINE", in_sec, line
      }
    }
  ' "$1"
}

# 从一行提取 kv 的 key;非 kv 行(注释/空行/无 =)返回空字符串
extract_key() {
  local line="$1" key
  [[ "$line" =~ ^[[:space:]]*$ ]] && return 0
  [[ "$line" =~ ^[[:space:]]*# ]] && return 0
  [[ "$line" == *=* ]] || return 0
  key="${line%%=*}"
  key="${key#"${key%%[![:space:]]*}"}"
  key="${key%"${key##*[![:space:]]}"}"
  printf '%s' "$key"
}

is_protected_top() { [[ "$1" == "model" || "$1" == "model_provider" ]]; }
is_protected_sec() { [[ "$1" =~ ^model_providers\. ]]; }

# 输出一个 table 段:header 前加空行分隔,段内去掉尾部空行
emit_section() {
  local header="$1"; shift
  local -a out=("$@")
  local end=${#out[@]} i
  while (( end > 0 )) && [[ "${out[$((end - 1))]:-}" =~ ^[[:space:]]*$ ]]; do
    end=$((end - 1))
  done
  printf '\n%s\n' "$header"
  for ((i = 0; i < end; i++)); do printf '%s\n' "${out[i]}"; done
}

# 权威源数据(全局)
declare -A src_top_kv src_top_seen src_sec_header src_sec_seen src_sec_lines src_sec_count
declare -a src_top_order=() src_sec_order=()

load_source() {
  local kind a b n
  while IFS=$'\x1f' read -r kind a b; do
    case "$kind" in
      TOP)
        src_top_kv["$a"]="$b"
        [[ -z "${src_top_seen[$a]:-}" ]] && { src_top_seen[$a]=1; src_top_order+=("$a"); }
        ;;
      SECSTART)
        src_sec_header["$a"]="$b"
        [[ -z "${src_sec_seen[$a]:-}" ]] && { src_sec_seen[$a]=1; src_sec_order+=("$a"); }
        src_sec_count["$a"]=0
        ;;
      SECLINE)
        n="${src_sec_count[$a]:-0}"
        src_sec_lines["$a::$n"]="$b"
        src_sec_count["$a"]=$((n + 1))
        ;;
    esac
  done < <(parse_toml "$source_config")
}

# merge_target FILE:把合并后的内容输出到 stdout
merge_target() {
  local tfile="$1"
  declare -A dst_top_kv dst_top_seen dst_sec_header dst_sec_seen dst_sec_lines dst_sec_count
  declare -a dst_top_order=() dst_sec_order=()
  local kind a b n

  while IFS=$'\x1f' read -r kind a b; do
    case "$kind" in
      TOP)
        dst_top_kv["$a"]="$b"
        [[ -z "${dst_top_seen[$a]:-}" ]] && { dst_top_seen[$a]=1; dst_top_order+=("$a"); }
        ;;
      SECSTART)
        dst_sec_header["$a"]="$b"
        [[ -z "${dst_sec_seen[$a]:-}" ]] && { dst_sec_seen[$a]=1; dst_sec_order+=("$a"); }
        dst_sec_count["$a"]=0
        ;;
      SECLINE)
        n="${dst_sec_count[$a]:-0}"
        dst_sec_lines["$a::$n"]="$b"
        dst_sec_count["$a"]=$((n + 1))
        ;;
    esac
  done < <(parse_toml "$tfile")

  local key sec i line skey dkey dn sn
  declare -A src_sec_keymap dst_sec_keys_seen

  # 1) 顶层 kv:受保护在前(保留 profile 自有),通用按目标原序并以源覆盖,再追加源独有
  for key in "${dst_top_order[@]}"; do
    is_protected_top "$key" && printf '%s\n' "${dst_top_kv[$key]}"
  done
  for key in "${dst_top_order[@]}"; do
    is_protected_top "$key" && continue
    if [[ -n "${src_top_kv[$key]:-}" ]]; then
      printf '%s\n' "${src_top_kv[$key]}"
    else
      printf '%s\n' "${dst_top_kv[$key]}"
    fi
  done
  for key in "${src_top_order[@]}"; do
    is_protected_top "$key" && continue
    [[ -n "${dst_top_kv[$key]:-}" ]] && continue
    printf '%s\n' "${src_top_kv[$key]}"
  done

  local -a sec_out
  # 2) 受保护段 [model_providers.*]:目标原样保留
  for sec in "${dst_sec_order[@]}"; do
    is_protected_sec "$sec" || continue
    sec_out=()
    dn="${dst_sec_count[$sec]:-0}"
    for ((i = 0; i < dn; i++)); do sec_out+=("${dst_sec_lines[$sec::$i]:-}"); done
    emit_section "${dst_sec_header[$sec]}" "${sec_out[@]}"
  done

  # 3) 通用段:目标原序,段内逐 kv 合并(源覆盖同名,追加源独有)
  for sec in "${dst_sec_order[@]}"; do
    is_protected_sec "$sec" && continue
    src_sec_keymap=(); dst_sec_keys_seen=(); sec_out=()
    sn="${src_sec_count[$sec]:-0}"
    for ((i = 0; i < sn; i++)); do
      line="${src_sec_lines[$sec::$i]:-}"
      skey="$(extract_key "$line")"
      [[ -n "$skey" ]] && src_sec_keymap["$skey"]="$line"
    done
    dn="${dst_sec_count[$sec]:-0}"
    for ((i = 0; i < dn; i++)); do
      line="${dst_sec_lines[$sec::$i]:-}"
      dkey="$(extract_key "$line")"
      if [[ -n "$dkey" && -n "${src_sec_keymap[$dkey]:-}" ]]; then
        sec_out+=("${src_sec_keymap[$dkey]}")
      else
        sec_out+=("$line")
      fi
      [[ -n "$dkey" ]] && dst_sec_keys_seen["$dkey"]=1
    done
    for ((i = 0; i < sn; i++)); do
      line="${src_sec_lines[$sec::$i]:-}"
      skey="$(extract_key "$line")"
      [[ -n "$skey" && -z "${dst_sec_keys_seen[$skey]:-}" ]] && sec_out+=("$line")
    done
    emit_section "${dst_sec_header[$sec]}" "${sec_out[@]}"
  done

  # 4) 源独有通用段:目标没有的,整段追加
  for sec in "${src_sec_order[@]}"; do
    is_protected_sec "$sec" && continue
    [[ -n "${dst_sec_seen[$sec]:-}" ]] && continue
    sec_out=()
    sn="${src_sec_count[$sec]:-0}"
    for ((i = 0; i < sn; i++)); do sec_out+=("${src_sec_lines[$sec::$i]:-}"); done
    emit_section "${src_sec_header[$sec]}" "${sec_out[@]}"
  done
}

load_source

shopt -s nullglob
target_files=()
for f in "${codex_root}"/*.config.toml; do
  base="${f##*/}"
  profile="${base%.config.toml}"
  [[ "$profile" == route-* ]] && continue
  target_files+=("$f")
done
shopt -u nullglob

if [[ ${#target_files[@]} -eq 0 ]]; then
  [[ "$quiet" != "true" ]] && echo "没有可同步的 profile 配置(*.config.toml)。"
  exit 0
fi

changed=0
unchanged=0
for tfile in "${target_files[@]}"; do
  base="${tfile##*/}"
  merged="$(merge_target "$tfile")"
  if diff -q <(printf '%s\n' "$merged") "$tfile" >/dev/null 2>&1; then
    [[ "$quiet" != "true" ]] && echo "无变更: ${base}"
    unchanged=$((unchanged + 1))
  else
    if [[ "$dry_run" == "true" ]]; then
      [[ "$quiet" != "true" ]] && { echo "=== ${base} ==="; diff -u "$tfile" <(printf '%s\n' "$merged") || true; }
    else
      cp -p "$tfile" "${tfile}.bak"
      tmp_out="$(mktemp "${tfile}.XXXXXX")"
      printf '%s\n' "$merged" > "$tmp_out"
      chmod --reference="$tfile" "$tmp_out" 2>/dev/null || chmod 600 "$tmp_out"
      mv -f "$tmp_out" "$tfile"
      [[ "$quiet" != "true" ]] && echo "已同步: ${base}(备份 ${base}.bak)"
    fi
    changed=$((changed + 1))
  fi
done

if [[ "$quiet" != "true" ]]; then
  echo "同步完成:变更 ${changed},无变更 ${unchanged}"
fi
