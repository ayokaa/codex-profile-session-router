# 设计说明

## 目标

将会话存储与本次运行配置分离：所有 profile 使用同一个 `CODEX_HOME`，但每个进程
使用当前固定 profile 的模型、服务地址和凭证。

## 路由层

`codex-profile.sh` 根据名称解析：

```text
<name>.config.toml
auth.json.<name>
```

`default` 是特例，对应 `default.config.toml` 和根 `auth.json`。

脚本不复制 auth 文件，也不修改根 auth。它读取当前 auth 的 API key，将其放入当前
子进程环境，然后执行 Codex 原生 `--profile`。

## 为什么使用 provider env_key

Codex 交互式 TUI 创建内嵌 App Server 时禁用 `CODEX_API_KEY` 环境覆盖。如果 provider
仍然设置 `requires_openai_auth = true`，模型请求会使用共享根 AuthManager。

因此路由脚本根据当前 profile 的 `model_provider` 自动注入：

```toml
env_key = "OPENAI_API_KEY"
requires_openai_auth = false
```

provider 解析请求鉴权时会优先读取自己的 `env_key`，因此不会使用根 AuthManager 的
token。将规则放在脚本中还能保护后来新增但忘记配置 `env_key` 的 profile。
`codex exec` 与 TUI 使用相同的 provider 请求鉴权逻辑。

## 会话发现

所有 profile 保持：

```text
CODEX_HOME=$HOME/.codex
```

因此共享：

```text
sessions/
archived_sessions/
state_*.sqlite
```

原生列表可能根据当前行为过滤结果，所以无参数 `resume`、`fork` 和 `--last` 由本地
选择器直接查询 `threads` 表，取得 UUID 后再调用原生 Codex。

## 并发

不同 UUID 写入不同 JSONL，可正常并发。恢复已有 UUID 时，路由脚本持有：

```text
$CODEX_HOME/.locks/sessions/<UUID>.lock
```

第二个进程无法同时恢复同一 UUID。SQLite 并发仍由 Codex 自身管理。

## 配置安全

API key 存在于父脚本和 Codex 子进程的环境中，但不会写入 profile。启动参数同时：

- 保持 Codex 默认的 `*KEY*`、`*TOKEN*`、`*SECRET*` 环境排除；
- 禁用 shell snapshot。

同一用户或 root 仍可能读取进程环境，这是环境变量鉴权的系统级边界。
