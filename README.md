# Codex Profile Session Router

Without modifying Codex source, multiple fixed profiles can:

- share one `CODEX_HOME`, session directory, and SQLite index;
- use Codex’s native session picker for bare `resume`;
- see each other’s sessions in the native UI when they share the same `model_provider`;
- reuse ChatGPT-login sessions through the same index by sharing one provider id from the root config, so bare `codex` and the routes list the same sessions;
- bring old provider IDs back into the native list with a one-time normalization script;
- keep `fork` and `resume --last` querying the shared index across providers;
- keep using the current profile’s model, URL, and API key after resume;
- take a process lock on explicit UUIDs and `resume --last` so two processes do not resume the same session at once.

## Design

Each route is a fixed pair of files:

```text
work.config.toml + auth.json.work
lab.config.toml  + auth.json.lab
api.config.toml  + auth.json.api
```

`default` is a legal route name, but it is the odd one: its auth file is the shared root `auth.json`, and `--profile default` is still just a profile layer — bare `codex` never reads `default.config.toml`. Prefer a distinct name per endpoint and let the root config be the login path.

Example flow for `codex-work resume` (apikey route):

```text
codex-work
  -> codex-profile.sh work
  -> read auth.json.work
  -> set OPENAI_API_KEY for this process
  -> codex --profile work resume
  -> Codex native UI selects a session from the shared index
```

The interactive Codex TUI does not let `CODEX_API_KEY` override the shared AuthManager, so requests must authenticate via the provider environment key:

```toml
env_key = "OPENAI_API_KEY"
requires_openai_auth = false
```

For an `apikey` route, the route script reads the current `model_provider` and injects both settings automatically. New profiles that omit them still use the current process key for new sessions and `resume`, instead of falling back to the shared root `auth.json`.

## Auth modes

Each route resolves one of two modes, first from `CODEX_PROFILE_AUTH=apikey|login`, then from a `<name>.auth-mode` sidecar next to the profile config, then from the shape of its auth file (non-empty `OPENAI_API_KEY` → `apikey`; `tokens` / `auth_mode = "chatgpt"` → `login` — `codex login` leaves an empty `OPENAI_API_KEY` in the shared root `auth.json`).

- `apikey`: injects the route’s key plus the `env_key` / `requires_openai_auth = false` overrides described above.
- `login`: launches on the shared ChatGPT login state written by `codex login`. No provider overrides are injected and `CODEX_API_KEY` / `OPENAI_API_KEY` are unset, so the login token is what actually authenticates the request. Such a route needs no `auth.json.<name>`, and because command and alias generation only looks at persistent files, it must use the `<name>.auth-mode` sidecar — `CODEX_PROFILE_AUTH` alone will not register the route.

To reuse login sessions from your API-key routes, name the shared provider id in the **root** `~/.codex/config.toml` instead of adding a route for it:

```toml
model_provider = "localhost"

[model_providers.localhost]
name = "OpenAI"
wire_api = "responses"
requires_openai_auth = true
```

No `base_url` and no `env_key`, so Codex falls back to the official ChatGPT backend URL from the login auth mode, and first-party behavior keeps working because it is gated on the provider **name** (`is_openai()`), not the id. Bare `codex` then lists *and* records sessions in the same bucket as every route, with no extra command to remember.

Three rules follow from that setup:

- the built-in id `openai` is reserved, so a custom provider can never take it;
- a route that resolves to `login` must not keep `env_key` or `base_url` in its provider table — login mode can only send your ChatGPT token, and a `base_url` would post it to a third-party gateway, so the wrapper refuses the launch and lists the offending keys;
- declare `name`, `wire_api`, and `requires_openai_auth` in every route profile: the root table now supplies them to any profile that omits them, where an omitted `name` used to be a hard error.

```bash
echo login >~/.codex/work.auth-mode   # or: CODEX_PROFILE_AUTH=login codex-work
```

Sessions that are already in the index under another id — including everything `codex` without a profile recorded — still need one `codex-normalize-provider.sh` pass, described in [Migrating old sessions](#migrating-old-sessions).

## Install

```bash
./install.sh
```

Then create fixed profiles and auth under `~/.codex`. See:

- `examples/profile.config.toml.example`
- `examples/credentials.example.json`

Install the command wrappers:

```bash
~/.codex/scripts/install-codex-command-sync.sh
```

This generates:

```text
~/.local/bin/codex-work
~/.local/bin/codex-lab
~/.local/bin/codex-api
~/.local/bin/codex-routes
~/.local/bin/codex-sync-routes
```

(Wrappers appear for every `<name>.config.toml` that has its own `auth.json.<name>`, a `<name>.auth-mode` login marker, or — for the `default` name only — the shared root `auth.json`.)

Generated wrappers are standalone executables and work from Bash, fish, or other shells. The installer also:

- installs a Bash auto-sync hook in `.bashrc`;
- installs fish integration at `~/.config/fish/conf.d/codex-profile-commands.fish`;
- ensures fish startup adds `~/.local/bin` to `PATH` and refreshes route commands.

No extra fish aliases are required:

```fish
codex-routes
codex-work
codex-work resume --all
codex-sync-routes
```

## Usage

```bash
# start a new session
codex-work

# pick a session for the current directory with Codex native UI
codex-work resume

# native UI shows all directories (still filtered by current model_provider)
codex-work resume --all

# resume the latest session
codex-work resume --last --all

# explicit UUID
codex-work resume 00000000-0000-0000-0000-000000000000

# fork uses the same cross-profile selection logic
codex-work fork --all
```

List and refresh routes:

```bash
codex-routes
codex-sync-routes
```

## Shared config sync

Every route refresh (`codex-sync-routes`, or the shell startup hook) also syncs
shared settings from `~/.codex/config.toml` into every `<name>.config.toml`:

- Protected (each profile keeps its own): top-level `model`, `model_provider`,
  and the whole `[model_providers.*]` section.
- Incremental merge: source values override same-name profile keys; profile
  keys absent from the source are kept.
- Writes are atomic and back up to `<name>.config.toml.bak`; a no-op when
  nothing changed.

To preview without writing, run the script directly:

```bash
~/.codex/scripts/codex-sync-config.sh --dry-run
```

## Session safety

- Does not rewrite existing JSONL messages or history metadata; the provider normalization script only updates `threads.model_provider` in the index.
- Bare `resume` uses Codex native UI; the native list is filtered by the current `model_provider`.
- Explicit UUID resume and `resume --last` hold a process lock so two processes do not append the same JSONL at once.
- `resume --last` is resolved to a UUID first by a read-only SQLite selector.
- Native UI selection happens inside the Codex process; the outer script never learns the UUID, so that path has no UUID lock.
- `fork` creates a new UUID, so it does not take the original session’s write lock.
- API keys are injected only into the current Codex process; `login` routes inject nothing and unset both key variables instead.
- A route that resolves to `login` but still declares `env_key` or `base_url` is refused before launch, so the shared ChatGPT token can never be posted to a third-party gateway.
- Default sensitive-env excludes stay enabled and shell snapshots are disabled so keys do not leak into tool shells or snapshots.

## Migrating old sessions

If you previously used `~/.codex/shared`, review and run:

```bash
~/.codex/scripts/codex-migrate-to-root.sh
```

The migration uses `--ignore-existing` and `INSERT OR IGNORE`, so it will not overwrite sessions already under the root. Back up all of `~/.codex` before running it.

Sessions recorded under a different `model_provider` are invisible to the native picker, even though they are in the same index. Normalize them once — preview first:

```bash
~/.codex/scripts/codex-normalize-provider.sh --dry-run
~/.codex/scripts/codex-normalize-provider.sh --to localhost --from openai,OpenAI,cch
```

The script prints the per-provider impact before writing, backs the index up to `~/.codex/.backups/provider-normalize/` without overwriting an existing backup, and updates only the `model_provider` column of `threads`. Rollout JSONL is never rewritten, and resuming still uses the current profile’s model, endpoint, and credentials.

## Tests

The full suite uses temp dirs and fake credentials, never real APIs. It includes isolated tests and real Codex CLI tests:

```bash
./scripts/test-codex-profile.sh
```

Fast isolated tests only:

```bash
CODEX_PROFILE_TEST_SKIP_E2E=true ./scripts/test-codex-profile.sh
```

Real Codex end-to-end tests use the local `codex` binary and a local mock Responses server, so they make no external API calls. They create a real session through the generated command found on `PATH`, resume that UUID through a sourced Bash alias, and resume it once more via `codex-default`; fish adds a third leg when a fish binary is available.

```bash
./scripts/test-codex-profile-e2e.sh
```

Set `CODEX_PROFILE_E2E_CODEX_BIN` to point at a specific Codex binary. The temporary `CODEX_HOME` is removed when the test finishes.

## Limitations

- Fixed profiles layer on top of root `config.toml`; fields not set in a profile still inherit from the root.
- Shared config sync runs on every route refresh and assumes single-line `key = value` entries; multi-line arrays or strings are not merged. Source comments are not synced; each profile keeps its own. `[projects."..."]` and other non-model sections are treated as shared and synced.
- Codex native resume UI filters by current `model_provider`; `--all` only drops the directory filter. Old sessions from a different provider need an explicit UUID, the cross-provider selector used by `fork`, or one `codex-normalize-provider.sh` pass.
- Login and API-key sessions share one list only while both layers resolve the same provider id, which means the root `config.toml` has to carry it. A login-mode launch can never carry its own credential — the only one available is the single shared ChatGPT login state — and a root provider table leaks its keys into every profile that omits them, so route profiles should stay explicit.
- The native UI path does not get this project’s extra UUID-level cross-process lock; explicit UUIDs and `--last` do.
- Concurrent edits to the same profile config by multiple processes follow Codex’s last-writer-wins behavior.
- Explicit `--remote` uses remote App Server config; local profiles cannot override remote model and auth.
- Plugin dirs and ChatGPT cloud features may still use the shared root AuthManager; that does not affect model requests for custom providers.

See `docs/design.md` for design detail and `docs/verification.md` for verification notes.
