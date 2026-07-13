# 验证记录

## 自动测试

`scripts/test-codex-profile.sh` 覆盖：

- 固定 profile 到 auth 的映射；
- `CODEX_API_KEY` 与 `OPENAI_API_KEY` 注入；
- provider `env_key` 配置；
- 显式 UUID 透传；
- 旧 `config.toml.<name>` 不参与路由；
- 自动命令与 Bash alias 生成。

## 源码行为验证

实现依据 Codex 0.144.1 的以下行为：

- `--profile <name>` 加载 `$CODEX_HOME/<name>.config.toml`；
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
