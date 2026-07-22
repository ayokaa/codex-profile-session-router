# Design

## Goals

Separate session storage from per-run configuration: every profile uses the same
`CODEX_HOME`, while each process uses the current fixed profile’s model, endpoint,
and credentials.

## Routing layer

`codex-profile.sh` resolves a name to:

```text
<name>.config.toml
auth.json.<name>
```

`default` is special: `default.config.toml` plus root `auth.json`.

The script does not copy auth files or rewrite root auth. It reads the API key
from the current auth file, injects it into the current child process environment,
then runs Codex with native `--profile`.

## Why provider `env_key`

When the interactive Codex TUI starts its embedded App Server, it disables
`CODEX_API_KEY` AuthManager overrides. If a provider still has
`requires_openai_auth = true`, model requests use the shared root AuthManager.

So the route script always injects, based on the current profile’s
`model_provider`:

```toml
env_key = "OPENAI_API_KEY"
requires_openai_auth = false
```

Provider request auth prefers its own `env_key`, so it does not use the root
AuthManager token. Keeping the rule in the script also protects later profiles
that forget to set `env_key`. `codex exec` and the TUI share the same provider
request-auth path.

## Session discovery

All profiles keep:

```text
CODEX_HOME=$HOME/.codex
```

and therefore share:

```text
sessions/
archived_sessions/
state_*.sqlite
```

Bare `resume` is passed straight to Codex’s native session picker. The local
native list filters by the current `model_provider`; `--all` only drops the
working-directory filter. Fixed profiles that share a provider ID can see each
other’s sessions in the native UI; sessions from a different provider ID need an
explicit UUID.

`fork` and `resume --last` still go through the local selector against the
`threads` table. `fork` uses that cross-provider pick to create a new UUID;
`resume --last` resolves the latest UUID in the shared index, then calls native
Codex with that UUID.

## Shell integration

Every `codex-*` route is a standalone executable with a Bash shebang. Fish only
adds `~/.local/bin` to `PATH` from `conf.d` and calls the same sync script;
routing, auth, and session selection are not reimplemented in fish, so shells do
not diverge.

## Concurrency

Different UUIDs write different JSONL files and can run concurrently. When resume
has an explicit UUID, or when `resume --last` has been rewritten to a UUID, the
route script holds:

```text
$CODEX_HOME/.locks/sessions/<UUID>.lock
```

A second process cannot resume the same UUID at the same time. Bare `resume`
selection happens inside the Codex process; the outer script never learns the
UUID in advance, so the native UI path does not take that lock. SQLite
concurrency remains Codex’s responsibility.

## Config safety

The API key lives in the parent script and Codex child process environment, but
is never written into the profile. Launch flags also:

- keep Codex’s default `*KEY*`, `*TOKEN*`, and `*SECRET*` environment excludes;
- disable shell snapshot.

The same user or root can still read process environment; that is the system
boundary of env-var auth.
