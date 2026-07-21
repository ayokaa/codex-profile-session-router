# Codex Profile Session Router

在不修改 Codex 源码的前提下，让多个固定 profile：

- 共享同一个 `CODEX_HOME`、会话目录和 SQLite 索引；
- 无参数 `resume` 使用 Codex 原生会话选择 UI；
- 相同 `model_provider` 的 profile 可在原生 UI 中互相看到会话；
- `fork` 和 `resume --last` 继续跨 provider 查询共享索引；
- 恢复后继续使用当前 profile 的模型、URL 和 API key；
- 显式 UUID 和 `resume --last` 防止两个进程同时恢复同一个会话。

## 设计

每个路由由一组固定文件组成：

```text
default.config.toml + auth.json
work.config.toml     + auth.json.work
lab.config.toml     + auth.json.lab
```

以 `codex-work resume` 为例：

```text
codex-work
  -> codex-profile.sh work
  -> 读取 auth.json.work
  -> 设置当前进程的 OPENAI_API_KEY
  -> codex --profile work resume
  -> Codex 原生 UI 从共享索引选择会话
```

交互式 Codex TUI 不使用 `CODEX_API_KEY` 覆盖共享 AuthManager，因此请求必须使用
provider 环境变量鉴权：

```toml
env_key = "OPENAI_API_KEY"
requires_openai_auth = false
```

路由脚本会读取当前 `model_provider` 并自动注入这两个设置。这样新增 profile 即使
忘记声明，普通新会话和 `resume` 仍由当前 provider 读取当前进程的 key，不会回落
到共享根 `auth.json`。

## 安装

```bash
./install.sh
```

然后在 `~/.codex` 创建固定 profile 和 auth。可以参考：

- `examples/profile.config.toml.example`
- `examples/credentials.example.json`

安装自动命令：

```bash
~/.codex/scripts/install-codex-command-sync.sh
```

它会生成：

```text
~/.local/bin/codex-default
~/.local/bin/codex-work
~/.local/bin/codex-lab
~/.local/bin/codex-routes
~/.local/bin/codex-sync-routes
```

生成的包装命令是独立可执行文件，可以从 Bash、fish 或其他 shell 调用。安装器同时：

- 在 `.bashrc` 安装 Bash 自动同步钩子；
- 在 `~/.config/fish/conf.d/codex-profile-commands.fish` 安装 fish 集成；
- 让 fish 启动时把 `~/.local/bin` 加入 PATH 并刷新路由命令。

fish 不需要额外 alias：

```fish
codex-routes
codex-work
codex-work resume --all
codex-sync-routes
```

## 使用

```bash
# 启动新会话
codex-work

# 当前目录使用 Codex 原生 UI 选择会话
codex-work resume

# 原生 UI 显示所有目录（仍按当前 model_provider 过滤）
codex-work resume --all

# 恢复最新会话
codex-work resume --last --all

# 显式 UUID
codex-work resume 00000000-0000-0000-0000-000000000000

# Fork 使用同样的跨 profile 选择逻辑
codex-work fork --all
```

查看和刷新路由：

```bash
codex-routes
codex-sync-routes
```

## 会话安全

- 不修改已有 JSONL 消息或历史元数据。
- 无参数 `resume` 直接使用 Codex 原生 UI；原生 UI 会按当前 `model_provider` 过滤。
- 显式恢复 UUID 和 `resume --last` 时持有进程锁，避免两个进程同时追加同一个 JSONL。
- `resume --last` 先由只读 SQLite 选择器解析成 UUID。
- 原生 UI 在 Codex 进程内完成选择，外层脚本无法得知 UUID，因此该路径不加 UUID 锁。
- `fork` 会创建新 UUID，因此不需要占用原会话的写锁。
- API key 只注入当前 Codex 进程。
- 启用默认敏感环境变量排除并禁用 shell snapshot，避免 key 进入工具 shell 或快照。

## 旧会话迁移

如果此前使用过 `~/.codex/shared`，可以先审查并执行：

```bash
~/.codex/scripts/codex-migrate-to-root.sh
```

迁移脚本使用 `--ignore-existing` 和 `INSERT OR IGNORE`，不会覆盖根目录已有会话；执行
前仍建议自行备份整个 `~/.codex`。

## 测试

完整测试套件使用临时目录和假凭证，不访问真实 API，包含隔离测试和真实 Codex CLI 测试：

```bash
./scripts/test-codex-profile.sh
```

只运行快速隔离测试：

```bash
CODEX_PROFILE_TEST_SKIP_E2E=true ./scripts/test-codex-profile.sh
```

真实 Codex 端到端测试使用本机 `codex` 二进制和本地 mock Responses 服务，创建真实
session 后通过 `codex-work` 和 `codex-default` 恢复同一个 UUID，不访问外部 API：

```bash
./scripts/test-codex-profile-e2e.sh
```

可用 `CODEX_PROFILE_E2E_CODEX_BIN` 指定 Codex 二进制，测试完成后会删除临时 `CODEX_HOME`。

## 限制

- 固定 profile 会叠加在根 `config.toml` 上；profile 未声明的通用字段继续继承根配置。
- Codex 原生 resume UI 按当前 `model_provider` 过滤；`--all` 只取消目录过滤。不同
  provider 的旧会话需要显式传入 UUID，或通过 `fork` 的跨 provider 选择器查找。
- 原生 UI 路径没有本项目额外提供的 UUID 级跨进程锁；显式 UUID 和 `--last` 不受影响。
- 多个同名 profile 进程同时修改配置时，遵循 Codex 原生的最后写入者行为。
- 显式 `--remote` 使用远端 App Server 配置，本地 profile 无法覆盖远端模型和 auth。
- 插件目录和 ChatGPT 云功能仍可能使用共享根 AuthManager；这不影响自定义 provider 的
  模型请求。

详细设计见 `docs/design.md`，验证记录见 `docs/verification.md`。
