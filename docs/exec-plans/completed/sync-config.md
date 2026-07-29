# 同步各 profile 的通用配置(codex-sync-config)

> 实现演进:最终未提供独立 `codex-sync-config` 命令,改为在每次 route refresh
> (`codex-sync-commands.sh`,由 `codex-sync-routes` 与 shell 启动钩子触发)时自动
> 调用 `codex-sync-config.sh --quiet`。源 `config.toml` 不存在时静默跳过;写入为
> 原子写并备份。详见 `docs/design.md` 的 Config sync 小节。

## 目标

新增 `codex-sync-config` 命令:以 `~/.codex/config.toml` 为权威源,把其中的通用设置
增量同步到各个 `<name>.config.toml`,保留每个 profile 自有的模型与端点配置。

## 范围与合并语义

- 权威源:`~/.codex/config.toml`(Codex 根全局配置,各 profile 本就继承它)
- 目标:`~/.codex/*.config.toml`(含 `default.config.toml`,排除 `route-*`,与现有
  `list_routes` / `print_route_table` 一致)。源 `config.toml` 不匹配该 glob,不会被当作目标。
- 受保护(不同步,保留各 profile 自有值):
  - 顶层 `model`、`model_provider`
  - 整个 `[model_providers.*]` 段(含 `base_url`、`name`、`wire_api`、
    `requires_openai_auth` 等)
- 同步区:源中其余顶层 kv 与其余 table 段(如 `model_reasoning_effort`、
  `sandbox_mode`、`[features]`、`[sandbox_workspace_write]`、`[notice.model_migrations]`、
  `[projects."..."]` 等)
- 增量合并(用户选定):
  - 顶层 kv:源有则覆盖 profile 同名 key;源无则保留 profile 该 key
  - table 段:源有同名段则段内逐 kv 合并(源 kv 覆盖同名,profile 有而源无的 kv 保留);
    源无该段则保留 profile 该段;源有而 profile 无的段则追加
  - profile 的受保护字段始终保留不动

## 实现(纯 Bash)

新增 `scripts/codex-sync-config.sh`,`set -euo pipefail`:

1. 解析:用 `awk` 把每个 toml 文件解析为两块
   - 顶层 kv 区:第一个 `[header]` 之前的 `key = value` 行
   - 段列表:每个 `[section]` header 及其后续 kv 行(直到下一个 header)
2. 受保护区识别:
   - 顶层 kv 中 `key == model` 或 `key == model_provider`
   - 段名前缀为 `model_providers.` 的段
3. 增量合并算法(对每个目标 profile):
   - 顶层通用 kv:遍历源同步区 kv,目标有同名 key 则替换该行,否则追加到顶层 kv 区末尾
   - 通用段:遍历源同步区段,目标有同名段则逐 kv 合并段内,否则追加整段
4. 重组输出(TOML 语法要求顶层 kv 在所有 table 之前):
   - 顶层 kv 区:profile 的 `model`、`model_provider` + 合并后的通用 kv
   - 段区:profile 的 `[model_providers.*]` 段(保留)+ 合并后的通用段
5. 选项:
   - `--dry-run`:只打印每个目标将发生的变更(新增/覆盖的 key 与段),不写文件
   - 默认写入:写入前把目标备份到 `<name>.config.toml.bak`(覆盖上次备份)
   - `--quiet`:减少输出
   - `-h|--help`:用法
6. 错误处理:源 `config.toml` 不存在则报错退出;无目标 profile 则提示并无操作

## 接入命令体系

- `scripts/codex-sync-commands.sh`:新增生成 `codex-sync-config` wrapper(指向
  `codex-sync-config.sh`),纳入 `current_commands` 与 manifest 清理逻辑
- `install.sh`:把 `codex-sync-config.sh` 加入安装列表
- 不接入 bashrc/fish 自动钩子:同步会改写 profile 文件内容,应由用户手动运行,
  避免每次开终端覆盖正在编辑的 profile

## 限制(KISS,在文档中说明)

- 假设 `key = value` 单行(符合 Codex config 常见结构,用户真实 config 即如此);
  多行数组 / 多行字符串不支持
- 源中的注释行不同步(只同步 `key = value`);目标原有注释随目标结构保留
- 不做语义解析,按文本结构重组

## 测试

在 `scripts/test-codex-profile.sh` 增加 isolated 用例(临时目录 + fake config):
- 构造源 `config.toml`(含 `model`/`model_provider`/`[model_providers.x]` + 通用 kv +
  `[features]` + `[sandbox_workspace_write]`)
- 构造 2 个目标 profile:一个带部分通用 kv 与源重叠、一个带源没有的 kv 与段
- 先 `--dry-run` 预览,再实际写入
- 断言:
  - 受保护字段(`model`、`model_provider`、`[model_providers.*]`)各 profile 保留原值
  - 源通用 kv 已写入/覆盖
  - profile 有而源无的 kv / 段保留
  - `[features]` 等段内逐 kv 合并正确(源 kv 覆盖同名,profile 独有 kv 保留)
  - 顶层 kv 始终在 table 段之前(生成的 toml 合法)

## 文档(行为变更须伴文档变更)

- `README.md`:新增 `codex-sync-config` 用法;Limitations 补充同步粒度与限制
- `docs/design.md`:新增 "Config sync" 小节,说明源、受保护区、增量语义
- `docs/verification.md`:补充同步用例覆盖
- 本执行计划完成后移至 `docs/exec-plans/completed/`

## 涉及文件

- 新增:`scripts/codex-sync-config.sh`
- 修改:`scripts/codex-sync-commands.sh`、`install.sh`、`scripts/test-codex-profile.sh`、
  `README.md`、`docs/design.md`、`docs/verification.md`
