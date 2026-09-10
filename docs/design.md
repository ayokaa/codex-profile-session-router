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

`default` is the one special name: it pairs `default.config.toml` with the root
`auth.json`. Nothing about that name means anything to Codex — the profile layer
loads only when `--profile` selects it, and `config.toml` alone is the user layer
(`config/src/loader/mod.rs` layer order) — so `codex` without a profile never
reads `default.config.toml`. The pairing does matter here, because
`codex login` rewrites that shared `auth.json`: a `default` route silently
changes from an API-key route into a login route, which the launch guard then
refuses. Give a gateway its own named route with `auth.json.<name>` and let the
root config carry the login instead.

The script does not copy auth files or rewrite root auth. For an `apikey` route
it reads the key from the route’s auth file, injects it into the current child
process environment, and then runs Codex with native `--profile`; a `login`
route injects nothing and reuses the shared root login state (see Auth modes).

## Auth modes

Each route resolves an auth mode before launching Codex:

1. `CODEX_PROFILE_AUTH=apikey|login` (explicit override);
2. `<name>.auth-mode` sidecar in `CODEX_HOME`;
3. the shape of the route’s auth file: a non-empty `OPENAI_API_KEY` →
   `apikey`; `tokens` or `auth_mode == "chatgpt"` → `login`. `codex login`
   rewrites the shared root `auth.json` and leaves `OPENAI_API_KEY` empty, so a
   route that reads that file follows the login branch;
4. no auth file at all → `apikey`, which then fails the existence check; a login
   route is declared by writing `login` into `<name>.auth-mode`.

If the file has neither shape the script stops instead of guessing.

Command and alias generation (`codex-sync-commands.sh`, `codex-aliases.sh`)
registers a route from a paired auth file or the sidecar only, never from
`CODEX_PROFILE_AUTH`: a one-off environment override must not decide what lands
in `~/.local/bin`.

### apikey mode

`apikey` is the mode this project was built for. Because the interactive Codex
TUI starts its embedded App Server with `CODEX_API_KEY` AuthManager overrides
disabled, a provider that still has `requires_openai_auth = true` would send
model requests with the shared root AuthManager token.

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

### login mode

A route in `login` mode must not touch provider auth: injecting
`requires_openai_auth = false` would force an `env_key` that has no value, and
exporting `OPENAI_API_KEY` would let the built-in `openai` provider silently
downgrade the ChatGPT session to API-key billing. The script therefore passes no
`model_providers.*` overrides and unsets `CODEX_API_KEY` / `OPENAI_API_KEY`, so
Codex uses the shared root AuthManager login state.

Reusing login sessions through the shared index is an attribution problem: the
native picker only lists rows whose `model_provider` matches the live profile.
The official id cannot be borrowed — `openai` is a reserved built-in id and
naming a custom provider table after it is a hard config error
(`config/src/config_toml.rs:RESERVED_MODEL_PROVIDER_IDS`), and a route that only
sets `model_provider = "openai"` would stop using its own endpoint altogether.

A custom shared id works instead, because the first-party switches key off the
provider *name*, not the id: `is_openai()` compares `name` to `"OpenAI"`,
`supports_codex_backend_routes()` adds a base-URL check that a missing
`base_url` passes, `provider_uses_first_party_auth_path()` looks only at
`requires_openai_auth` plus the absence of `env_key`/`auth`/`aws`, and
`to_api_provider()` falls back to the official ChatGPT backend URL from the
login auth mode (`model-provider-info/src/lib.rs`). One behavior is still
id-gated: `turn_context.rs` only forwards the cyber-access-program metadata when
the id is literally `openai`.

So the login-side provider table is `name = "OpenAI"`, `requires_openai_auth = true`,
and no `base_url` or `env_key`. It belongs in the root `config.toml` next to a
root `model_provider`, not in a dedicated profile: bare `codex` then reads and
writes the same bucket as every route, and no route has to stop being an
API-key route. Keep that name off third-party routes either way — remote
compaction and the search/image extensions are enabled by `is_openai()` alone,
and a custom `base_url` will not implement them.

Because a profile layer merges into the root layer per key, a root
`[model_providers.<shared id>]` also supplies `name` to any profile that omits
it, where an empty name used to be a hard error. Declare all three keys in every
route profile.

The wrapper enforces the other half: a route that resolves to `login` mode must
not carry `env_key` or `base_url`, because the only credential that mode can
send is the ChatGPT token, and a `base_url` would hand it to a third-party
gateway. Such a launch exits with the offending keys and endpoint listed.

## Provider ID normalization

The native resume list is filtered by `threads.model_provider`, so rows recorded
under another id — an official ChatGPT login from before the root config shared
the id, or a provider name a route has since dropped — stay invisible even
though they live in the same index. `codex-normalize-provider.sh` rewrites only
that column; once the root config shares the id, new login sessions land in the
same bucket and only leftovers need a pass:

```bash
~/.codex/scripts/codex-normalize-provider.sh --dry-run
~/.codex/scripts/codex-normalize-provider.sh --to localhost --from openai,OpenAI
```

It prints the per-provider impact before writing, backs the index up to
`.backups/provider-normalize/` (an existing backup is never overwritten — a
later pass writes a numbered one), and applies a single `BEGIN IMMEDIATE`
transaction. Rollout JSONL
`session_meta` is left untouched, matching the config-safety rule below: only
the index attribution changes, and requests still use the live profile’s
provider, endpoint, and credentials.

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
explicit UUID, a normalization pass, or the cross-provider selector below.

`fork` and `resume --last` still go through the local selector against the
`threads` table. `fork` uses that cross-provider pick to create a new UUID;
`resume --last` resolves the latest UUID in the shared index, then calls native
Codex with that UUID. The selector limits candidates to the same session sources
Codex’s own picker queries (`cli`, `vscode`, plus `exec` and `app_server` only
when `--include-non-interactive` is passed), so subagent rows never appear.

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
is never written into the profile. A `login` route goes the other way: it unsets
`CODEX_API_KEY` and `OPENAI_API_KEY` so an inherited key cannot silently replace
the ChatGPT login state. Launch flags also:

- keep Codex’s default `*KEY*`, `*TOKEN*`, and `*SECRET*` environment excludes;
- disable shell snapshot.

The same user or root can still read process environment; that is the system
boundary of env-var auth.

## Config sync

Every route refresh (`codex-sync-commands.sh`, run by `codex-sync-routes` and
the shell startup hook) calls `codex-sync-config.sh`, which uses root
`config.toml` as the authoritative source and incrementally syncs its shared
settings into every `<name>.config.toml`.

Protected fields stay per-profile:

- top-level `model`, `model_provider`;
- the whole `[model_providers.*]` section (so `base_url`, `wire_api`,
  `requires_openai_auth`, etc. keep each profile's own values).

Everything else is the shared sync region. The merge is incremental: source
keys overwrite same-name profile keys (top-level and inside each table), source
keys missing from the profile are appended, and profile keys absent from the
source are left untouched. TOML syntax is preserved by emitting all top-level
keys before any table section.

Writes are atomic and back up to `<name>.config.toml.bak`; the run is a no-op
when nothing changed. `--dry-run` previews the diff without writing.
