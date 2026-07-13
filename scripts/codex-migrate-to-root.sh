#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
codex_root="$(cd -- "${script_dir}/.." && pwd)"
shared_home="${codex_root}/shared"
lock_path="${codex_root}/.locks/root-session-migration.lock"
marker_path="${codex_root}/.root-session-migration-v1"
backup_dir="${codex_root}/.backups/root-session-migration"
force="false"

if [[ "${1:-}" == "--force" ]]; then
  force="true"
  shift
fi
if [[ $# -ne 0 ]]; then
  echo "用法: codex-migrate-to-root.sh [--force]" >&2
  exit 2
fi
if [[ -f "${marker_path}" && "${force}" != "true" ]]; then
  echo "根目录会话迁移已经完成；如需显式重跑，请使用 --force。"
  exit 0
fi

if [[ ! -d "${shared_home}/sessions" ]]; then
  echo "没有需要迁移的 shared 会话目录: ${shared_home}/sessions" >&2
  exit 1
fi

mkdir -p "$(dirname -- "${lock_path}")" "${backup_dir}"
exec {migration_lock_fd}>"${lock_path}"
flock -x "${migration_lock_fd}"

mkdir -p "${codex_root}/sessions" "${codex_root}/archived_sessions"
rsync -a --ignore-existing "${shared_home}/sessions/" "${codex_root}/sessions/"
if [[ -d "${shared_home}/archived_sessions" ]]; then
  rsync -a --ignore-existing "${shared_home}/archived_sessions/" "${codex_root}/archived_sessions/"
fi

root_db="${codex_root}/state_5.sqlite"
shared_db="${shared_home}/state_5.sqlite"
if [[ -f "${root_db}" && -f "${shared_db}" ]]; then
  if [[ ! -f "${backup_dir}/state_5.sqlite" ]]; then
    sqlite3 "${root_db}" ".backup '${backup_dir}/state_5.sqlite'"
    chmod 600 "${backup_dir}/state_5.sqlite"
  fi

  root_columns="$(sqlite3 "${root_db}" "select count(*) from pragma_table_info('threads');")"
  shared_columns="$(sqlite3 "${shared_db}" "select count(*) from pragma_table_info('threads');")"
  if [[ "${root_columns}" != "${shared_columns}" ]]; then
    echo "根索引与 shared 索引结构不同，拒绝自动合并: ${root_columns} != ${shared_columns}" >&2
    exit 1
  fi

  escaped_shared_db="${shared_db//\'/\'\'}"
  escaped_shared_home="${shared_home//\'/\'\'}"
  escaped_codex_root="${codex_root//\'/\'\'}"
  sqlite3 -cmd '.timeout 10000' "${root_db}" <<EOF
ATTACH DATABASE '${escaped_shared_db}' AS legacy;
BEGIN IMMEDIATE;
INSERT OR IGNORE INTO threads SELECT * FROM legacy.threads;
INSERT OR IGNORE INTO thread_spawn_edges SELECT * FROM legacy.thread_spawn_edges;
INSERT OR IGNORE INTO thread_dynamic_tools SELECT * FROM legacy.thread_dynamic_tools;
UPDATE threads
SET rollout_path = replace(rollout_path, '${escaped_shared_home}/sessions/', '${escaped_codex_root}/sessions/')
WHERE rollout_path LIKE '${escaped_shared_home}/sessions/%';
UPDATE threads
SET rollout_path = replace(rollout_path, '${escaped_shared_home}/archived_sessions/', '${escaped_codex_root}/archived_sessions/')
WHERE rollout_path LIKE '${escaped_shared_home}/archived_sessions/%';
COMMIT;
DETACH DATABASE legacy;
EOF
fi

missing_paths="$(sqlite3 "${root_db}" "select count(*) from threads where rollout_path not like '${codex_root}/sessions/%' and rollout_path not like '${codex_root}/archived_sessions/%';")"
missing_files=0
while IFS= read -r rollout_path; do
  [[ -f "${rollout_path}" || -f "${rollout_path}.zst" ]] || missing_files=$((missing_files + 1))
done < <(sqlite3 -noheader "${root_db}" "select rollout_path from threads;")
rollout_count="$({ find "${codex_root}/sessions" -type f -name '*.jsonl'; find "${codex_root}/archived_sessions" -type f -name '*.jsonl'; } | wc -l)"
thread_count="$(sqlite3 "${root_db}" "select count(*) from threads;")"

if [[ "${missing_paths}" != "0" || "${rollout_count}" != "${thread_count}" || "${missing_files}" != "0" ]]; then
  echo "迁移校验失败: rollouts=${rollout_count}, threads=${thread_count}, 非根路径=${missing_paths}, 缺失文件=${missing_files}" >&2
  exit 1
fi

: >"${marker_path}"
chmod 600 "${marker_path}"
printf '根目录迁移完成: rollouts=%s, threads=%s\n' "${rollout_count}" "${thread_count}"
printf 'shared 保留为备份，不再参与运行: %s\n' "${shared_home}"
