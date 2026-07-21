# 验证记录

## 自动测试

`scripts/test-codex-profile.sh` 覆盖：

- 固定 profile 到 auth 的映射；
- `CODEX_API_KEY` 与 `OPENAI_API_KEY` 注入；
- 对错误 provider auth 配置的自动 `env_key` 覆盖；
- 无参数 `resume --all` 原样交给 Codex，不预先注入 UUID；
- 显式 UUID 透传；
- `resume --last` 继续从共享 SQLite 解析并传入 UUID；
- 旧 `config.toml.<name>` 不参与路由；
- 自动命令与 Bash alias 生成。
- fish `conf.d` 自动加载、PATH 命令发现、路由列表和参数透传。
- `scripts/test-codex-profile.sh` 默认继续运行真实 Codex 端到端测试；设置
  `CODEX_PROFILE_TEST_SKIP_E2E=true` 可跳过该阶段。

## 真实 Codex 端到端测试

`scripts/test-codex-profile-e2e.sh` 使用本机真实 Codex 二进制和本地 mock Responses 服务，覆盖：

- 通过 fish 路由创建真实 session 并持久化 JSONL；
- 通过 `codex-work` 和 `codex-default` 恢复同一个 UUID；
- 两个 profile 的模型配置都实际出现在 Codex 请求中；
- 测试使用临时 `CODEX_HOME`，不会访问外部 API 或修改真实会话。

## 源码行为验证

实现依据 Codex 0.144.6 的以下行为：

- `--profile <name>` 加载 `$CODEX_HOME/<name>.config.toml`；
- 无 UUID 的 `resume` 启动原生 TUI 会话选择器；
- 本地原生选择器按当前 `model_provider` 查询会话，`--all` 只取消 cwd 过滤；
- 本地 TUI 恢复时显式发送当前模型和 provider；
- TUI 内嵌 App Server 禁用 `CODEX_API_KEY` AuthManager 环境覆盖；
- provider `env_key` 生成的 Bearer auth 优先于共享 AuthManager；
- 显式模型/provider 覆盖存在时，不恢复历史会话的模型/provider。

## 隔离验证

使用本地 mock endpoint 和假 key 验证：

- 请求发往当前 profile 的 URL，而不是根配置 URL；
- Authorization 指纹来自当前 profile 对应 auth；
- 请求模型来自当前 profile；
- 测试不会访问真实 API 或写入真实会话目录。

## 实际 TUI 验证

将路由脚本安装到现有 `CODEX_HOME` 后，从已信任目录运行生成的后缀命令：

```text
codex-<profile> resume --all
```

在固定尺寸的真实伪终端中确认：

- 显示 Codex 原生标题 `Resume a previous session`；
- 显示原生 Filter、Sort 和退出操作提示；
- 未选择或恢复任何会话，退出后没有残留 Codex 进程；
- 共享 SQLite 索引的修改时间和文件大小保持不变。
