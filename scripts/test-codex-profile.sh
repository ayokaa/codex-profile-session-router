#!/usr/bin/env bash
set -euo pipefail

source_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d /tmp/codex-profile-test.XXXXXX)"
trap 'rm -rf -- "${test_root}"' EXIT

mkdir -p "${test_root}/scripts"
install -m 755 "${source_root}/scripts/codex-profile.sh" "${test_root}/scripts/codex-profile.sh"
install -m 755 "${source_root}/scripts/codex-session-picker.sh" "${test_root}/scripts/codex-session-picker.sh"
install -m 755 "${source_root}/scripts/codex-sync-commands.sh" "${test_root}/scripts/codex-sync-commands.sh"
install -m 755 "${source_root}/scripts/codex-sync-config.sh" "${test_root}/scripts/codex-sync-config.sh"
install -m 755 "${source_root}/scripts/codex-normalize-provider.sh" "${test_root}/scripts/codex-normalize-provider.sh"
install -m 755 "${source_root}/scripts/install-codex-command-sync.sh" "${test_root}/scripts/install-codex-command-sync.sh"
install -m 644 "${source_root}/scripts/codex-aliases.sh" "${test_root}/scripts/codex-aliases.sh"
install -m 644 "${source_root}/scripts/codex-profile-commands.fish" "${test_root}/scripts/codex-profile-commands.fish"

printf '%s\n' \
  'model = "base-model"' \
  'model_provider = "localhost"' \
  >"${test_root}/config.toml"
printf '%s\n' \
  'model = "legacy-model"' \
  'model_provider = "localhost"' \
  >"${test_root}/config.toml.example"
printf '%s\n' \
  'model = "profile-model"' \
  'model_provider = "localhost"' \
  '' \
  '[model_providers.localhost]' \
  'name = "test"' \
  'base_url = "http://127.0.0.1:9/v1"' \
  'wire_api = "responses"' \
  'requires_openai_auth = true' \
  >"${test_root}/example.config.toml"
install -m 600 "${test_root}/config.toml" "${test_root}/default.config.toml"
printf '%s\n' '{"OPENAI_API_KEY":"root-test-key"}' >"${test_root}/auth.json"
printf '%s\n' '{"OPENAI_API_KEY":"suffix-test-key"}' >"${test_root}/auth.json.example"

install -m 755 "${source_root}/scripts/testdata/fake-codex-profile.sh" "${test_root}/fake-codex"

route=(
  env
  CODEX_PROFILE_CODEX_BIN="${test_root}/fake-codex"
  "${test_root}/scripts/codex-profile.sh"
  example
)

resume_id="019f5742-1549-7ad2-ae54-42a19dfa340d"
sqlite3 "${test_root}/state_5.sqlite" "
  CREATE TABLE threads (
    id TEXT PRIMARY KEY,
    archived INTEGER NOT NULL DEFAULT 0,
    preview TEXT,
    first_user_message TEXT,
    title TEXT,
    source TEXT,
    model_provider TEXT,
    cwd TEXT,
    updated_at INTEGER,
    updated_at_ms INTEGER
  );
  INSERT INTO threads (
    id, archived, preview, source, model_provider, cwd, updated_at, updated_at_ms
  ) VALUES (
    '${resume_id}', 0, 'latest session', 'cli', 'localhost', '/tmp', 1, 1000
  );
"
FAKE_EXPECT_NATIVE_RESUME=true "${route[@]}" resume --all
FAKE_EXPECT_RESUME_ID="${resume_id}" "${route[@]}" resume "${resume_id}" --all
FAKE_EXPECT_REWRITTEN_LAST=true FAKE_EXPECT_RESUME_ID="${resume_id}" \
  "${route[@]}" resume --last --all

FAKE_EDIT_PROFILE=true "${route[@]}" exec --skip-git-repo-check test
grep -q 'model = "tui-model"' "${test_root}/example.config.toml"
grep -q 'model = "legacy-model"' "${test_root}/config.toml.example"

"${test_root}/scripts/codex-profile.sh" list | grep -q 'example -> example.config.toml / auth.json.example'

# ---- 登录态鉴权模式 ----
sed -i 's/tui-model/profile-model/' "${test_root}/example.config.toml"
cp "${test_root}/auth.json.example" "${test_root}/auth.json.example.orig"
# 登录态只会带 ChatGPT token，provider 表里的 base_url 会把它发到第三方端点，
# 所以先摘掉这一行跑登录态断言，最后再放回去验证拒绝路径。
sed -i '/^base_url = /d' "${test_root}/example.config.toml"

printf 'login\n' >"${test_root}/example.auth-mode"
FAKE_EXPECT_LOGIN=true "${route[@]}" exec --skip-git-repo-check test
# 登录态路由不需要自己的鉴权文件
mv "${test_root}/auth.json.example" "${test_root}/auth.json.example.away"
FAKE_EXPECT_LOGIN=true "${route[@]}" exec --skip-git-repo-check test
mv "${test_root}/auth.json.example.away" "${test_root}/auth.json.example"
"${test_root}/scripts/codex-profile.sh" list | grep -q 'example -> example.config.toml / 共享 auth.json (login)'
# CODEX_PROFILE_AUTH 优先于 sidecar
CODEX_PROFILE_AUTH=apikey FAKE_EXPECT_RESUME_ID="${resume_id}" \
  "${route[@]}" resume "${resume_id}"
rm -f "${test_root}/example.auth-mode"
FAKE_EXPECT_RESUME_ID="${resume_id}" "${route[@]}" resume "${resume_id}"
# 只有环境变量时，list 也应把该路由识别为登录路由
mv "${test_root}/auth.json.example" "${test_root}/auth.json.example.away"
CODEX_PROFILE_AUTH=login "${test_root}/scripts/codex-profile.sh" list \
  | grep -q 'example -> example.config.toml / 共享 auth.json (login)'
mv "${test_root}/auth.json.example.away" "${test_root}/auth.json.example"

# 只有 ChatGPT 登录凭据的鉴权文件应自动识别为 login
printf '%s\n' '{"auth_mode":"chatgpt","tokens":{"access_token":"t","refresh_token":"r"}}' \
  >"${test_root}/auth.json.example"
FAKE_EXPECT_LOGIN=true "${route[@]}" exec --skip-git-repo-check test
# 既没有 API key 也不是登录态时必须报错
printf '%s\n' '{}' >"${test_root}/auth.json.example"
if "${route[@]}" exec --skip-git-repo-check test >/dev/null 2>&1; then
  echo "无凭据的 apikey 路由应当失败" >&2
  exit 1
fi
# provider 表带 base_url 时不能以登录态启动：ChatGPT token 会被发到第三方端点
printf '%s\n' 'base_url = "http://127.0.0.1:9/v1"' >>"${test_root}/example.config.toml"
printf '%s\n' '{"OPENAI_API_KEY":"suffix-test-key"}' >"${test_root}/auth.json.example"
printf 'login\n' >"${test_root}/example.auth-mode"
if login_guard="$("${route[@]}" exec --skip-git-repo-check test 2>&1)"; then
  echo "带 base_url 的登录态路由应当被拒绝" >&2
  exit 1
fi
if ! grep -q 'base_url' <<<"${login_guard}"; then
  echo "拒绝信息应当点出冲突的 provider 键: ${login_guard}" >&2
  exit 1
fi
rm -f "${test_root}/example.auth-mode"
cp "${test_root}/auth.json.example.orig" "${test_root}/auth.json.example"
rm -f "${test_root}/auth.json.example.orig"

# ---- 选择器的 source 过滤 ----
exec_resume_id="019f5742-1549-7ad2-ae54-42a19dfa340e"
subagent_resume_id="019f5742-1549-7ad2-ae54-42a19dfa340f"
sqlite3 "${test_root}/state_5.sqlite" "
  INSERT INTO threads (id, archived, preview, source, model_provider, cwd, updated_at, updated_at_ms)
  VALUES ('${exec_resume_id}', 0, 'exec session', 'exec', 'localhost', '/tmp', 2, 2000);
  INSERT INTO threads (id, archived, preview, source, model_provider, cwd, updated_at, updated_at_ms)
  VALUES ('${subagent_resume_id}', 0, 'subagent session', '{\"subagent\":{\"other\":\"guardian\"}}', 'localhost', '/tmp', 3, 3000);
"
# 默认与 --include-non-interactive 都不应挑到 subagent 行
FAKE_EXPECT_RESUME_ID="${resume_id}" FAKE_EXPECT_REWRITTEN_LAST=true \
  "${route[@]}" resume --last --all
FAKE_EXPECT_RESUME_ID="${exec_resume_id}" FAKE_EXPECT_REWRITTEN_LAST=true \
  "${route[@]}" resume --last --all --include-non-interactive

# ---- provider id 归一 ----
normalize="${test_root}/scripts/codex-normalize-provider.sh"
sqlite3 "${test_root}/state_5.sqlite" "
  INSERT INTO threads (id, archived, preview, source, model_provider, cwd, updated_at, updated_at_ms)
  VALUES ('legacy-login', 0, 'official login session', 'cli', 'openai', '/tmp', 1, 100);
  INSERT INTO threads (id, archived, preview, source, model_provider, cwd, updated_at, updated_at_ms)
  VALUES ('legacy-quote', 0, 'odd provider id session', 'cli', 'it''s', '/tmp', 1, 101);
"
"${normalize}" --dry-run | grep -q '合计: 2 条'
[[ "$(sqlite3 "${test_root}/state_5.sqlite" \
  "SELECT COUNT(*) FROM threads WHERE model_provider <> 'localhost';")" == "2" ]]
"${normalize}" --force | grep -q '归一完成: 更新 2 条'
[[ "$(sqlite3 "${test_root}/state_5.sqlite" \
  "SELECT model_provider FROM threads WHERE id = 'legacy-login';")" == "localhost" ]]
[[ "$(sqlite3 "${test_root}/state_5.sqlite" \
  "SELECT model_provider FROM threads WHERE id = 'legacy-quote';")" == "localhost" ]]
[[ -f "${test_root}/.backups/provider-normalize/state_5.sqlite" ]]
"${normalize}" --force | grep -q '没有需要归一的 provider id'
# 目标 id 优先取 root config.toml，default 路由不一致时不参与推断
cp "${test_root}/config.toml" "${test_root}/config.toml.orig"
printf '%s\n' 'model = "legacy-model"' 'model_provider = "localhost"' >"${test_root}/config.toml"
printf '%s\n' 'model = "profile-model"' 'model_provider = "dropped-route"' >"${test_root}/default.config.toml"
"${normalize}" --dry-run | grep -q '目标已是 localhost'
# root 不声明 model_provider 时才回落到 default.config.toml
printf '%s\n' 'model = "legacy-model"' >"${test_root}/config.toml"
printf '%s\n' 'model = "profile-model"' 'model_provider = "localhost"' >"${test_root}/default.config.toml"
"${normalize}" --dry-run | grep -q '目标已是 localhost'
cp "${test_root}/config.toml.orig" "${test_root}/config.toml"
rm -f "${test_root}/config.toml.orig"
install -m 600 "${test_root}/config.toml" "${test_root}/default.config.toml"
first_backup="${test_root}/.backups/provider-normalize/state_5.sqlite"
first_backup_sum="$(sha256sum "${first_backup}")"
# 备份保持归一前的状态
[[ "$(sqlite3 -readonly "${first_backup}" \
  "SELECT model_provider FROM threads WHERE id = 'legacy-login';")" == "openai" ]]
# 二次归一不被旧备份挡住，但历史备份只增不改
sqlite3 "${test_root}/state_5.sqlite" "
  INSERT INTO threads (id, archived, preview, source, model_provider, cwd, updated_at, updated_at_ms)
  VALUES ('legacy-late', 0, 'late session', 'cli', 'cch', '/tmp', 1, 102);
"
"${normalize}" --force | grep -q '归一完成: 更新 1 条'
[[ "$(sqlite3 "${test_root}/state_5.sqlite" \
  "SELECT model_provider FROM threads WHERE id = 'legacy-late';")" == "localhost" ]]
second_backup="${first_backup}.1"
[[ -f "${second_backup}" ]]
[[ "$(sqlite3 -readonly "${second_backup}" \
  "SELECT model_provider FROM threads WHERE id = 'legacy-late';")" == "cch" ]]
[[ "$(sha256sum "${first_backup}")" == "${first_backup_sum}" ]]

# 共享登录态路由没有鉴权文件，靠 sidecar 认定；缺两者之一的配置不算路由
printf '%s\n' 'model = "login-model"' 'model_provider = "localhost"' \
  >"${test_root}/loginy.config.toml"
printf 'login\n' >"${test_root}/loginy.auth-mode"
printf '%s\n' 'model = "orphan-model"' 'model_provider = "localhost"' \
  >"${test_root}/orphan.config.toml"
"${test_root}/scripts/codex-profile.sh" list | grep -q 'loginy -> loginy.config.toml / 共享 auth.json (login)'
if "${test_root}/scripts/codex-profile.sh" list | grep -q 'orphan'; then
  echo "没有鉴权文件也没有 login 标记的配置不应成为路由" >&2
  exit 1
fi

mkdir -p "${test_root}/bin"
HOME="${test_root}" "${test_root}/scripts/codex-sync-commands.sh" --target-dir "${test_root}/bin" --quiet
[[ -x "${test_root}/bin/codex-example" ]]
[[ -x "${test_root}/bin/codex-default" ]]
[[ -x "${test_root}/bin/codex-loginy" ]]
[[ ! -e "${test_root}/bin/codex-orphan" ]]

TEST_CODEX_ROOT="${test_root}" bash -c '
  source "${TEST_CODEX_ROOT}/scripts/codex-aliases.sh"
  alias codex-example >/dev/null
  alias codex-default >/dev/null
  alias codex-loginy >/dev/null
  if alias codex-orphan >/dev/null 2>&1; then exit 1; fi
'

HOME="${test_root}" XDG_CONFIG_HOME="${test_root}/.config" \
  "${test_root}/scripts/install-codex-command-sync.sh" >/dev/null
[[ -f "${test_root}/.config/fish/conf.d/codex-profile-commands.fish" ]]
grep -q 'set -gx PATH' "${test_root}/.config/fish/conf.d/codex-profile-commands.fish"

if [[ -n "${CODEX_PROFILE_TEST_FISH_BIN:-}" ]]; then
  fish_resume_id="019f5742-1549-7ad2-ae54-42a19dfa341"
  sed -i 's/tui-model/profile-model/' "${test_root}/example.config.toml"
  HOME="${test_root}" XDG_CONFIG_HOME="${test_root}/.config" TEST_RESUME_ID="${fish_resume_id}" \
    "${CODEX_PROFILE_TEST_FISH_BIN}" --interactive -c '
      test (command -s codex-example) = "$HOME/.local/bin/codex-example"; or begin
        echo "fish resolved unexpected codex-example path: "(command -s codex-example) >&2
        exit 1
      end
      test (command -s codex-default) = "$HOME/.local/bin/codex-default"; or begin
        echo "fish resolved unexpected codex-default path: "(command -s codex-default) >&2
        exit 1
      end
      codex-routes | string match -q "*example -> example.config.toml / auth.json.example*"; or begin
        echo "fish route listing failed" >&2
        exit 1
      end
      env CODEX_PROFILE_CODEX_BIN="$HOME/fake-codex" \
        FAKE_EXPECT_RESUME_ID="$TEST_RESUME_ID" \
        codex-example resume "$TEST_RESUME_ID" --all; or begin
        echo "fish argument forwarding failed" >&2
        exit 1
      end
    '
fi

# refresh(codex-sync-commands)时自动同步配置
cat >"${test_root}/config.toml" <<'EOF'
model = "src-model"
model_provider = "localhost"
model_reasoning_effort = "high"
sandbox_mode = "workspace-write"

[features]
plan_tool = true
multi_agent = true

[model_providers.localhost]
name = "src"
base_url = "https://src.example/v1"
EOF

cat >"${test_root}/sync-a.config.toml" <<'EOF'
model = "a-model"
model_provider = "acs"
model_reasoning_effort = "low"

[model_providers.acs]
name = "acs"
base_url = "https://acs.example/v1"

[features]
plan_tool = false
js_repl = true
EOF

# refresh 生成 wrapper 同时自动同步配置
HOME="${test_root}" "${test_root}/scripts/codex-sync-commands.sh" --target-dir "${test_root}/bin" --quiet

# 受保护字段保留各 profile 自有值
grep -q 'model = "a-model"' "${test_root}/sync-a.config.toml"
grep -q 'model_provider = "acs"' "${test_root}/sync-a.config.toml"
grep -q 'base_url = "https://acs.example/v1"' "${test_root}/sync-a.config.toml"
# 通用 kv 被源覆盖
grep -q 'model_reasoning_effort = "high"' "${test_root}/sync-a.config.toml"
# 源独有通用 kv 追加
grep -q 'sandbox_mode = "workspace-write"' "${test_root}/sync-a.config.toml"
# 段内 kv:源覆盖同名、profile 独有保留、源独有追加
grep -q 'plan_tool = true' "${test_root}/sync-a.config.toml"
grep -q 'js_repl = true' "${test_root}/sync-a.config.toml"
grep -q 'multi_agent = true' "${test_root}/sync-a.config.toml"
# 源的受保护字段不泄漏
! grep -q 'src-model' "${test_root}/sync-a.config.toml"
! grep -q 'base_url = "https://src.example/v1"' "${test_root}/sync-a.config.toml"
# 顶层 kv 必须在所有 table 段之前
sync_a_model_line=$(grep -n '^model = ' "${test_root}/sync-a.config.toml" | head -1 | cut -d: -f1)
sync_a_sec_line=$(grep -n '^\[' "${test_root}/sync-a.config.toml" | head -1 | cut -d: -f1)
(( sync_a_model_line < sync_a_sec_line ))
# 不再生成独立 codex-sync-config 命令
[[ ! -e "${test_root}/bin/codex-sync-config" ]]
# 幂等:再 refresh 一次,同步脚本应报告该 profile 无变更
HOME="${test_root}" "${test_root}/scripts/codex-sync-commands.sh" --target-dir "${test_root}/bin" --quiet
sync_out="$("${test_root}/scripts/codex-sync-config.sh")"
echo "${sync_out}" | grep -q '无变更: sync-a.config.toml'

if [[ "${CODEX_PROFILE_TEST_SKIP_E2E:-false}" != "true" ]]; then
  "${source_root}/scripts/test-codex-profile-e2e.sh"
fi

echo "codex-profile tests: ok"
