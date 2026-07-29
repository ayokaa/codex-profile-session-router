# Codex Profile Session Router

Without modifying Codex source, multiple fixed profiles can:

- share one `CODEX_HOME`, session directory, and SQLite index;
- use Codex’s native session picker for bare `resume`;
- see each other’s sessions in the native UI when they share the same `model_provider`;
- keep `fork` and `resume --last` querying the shared index across providers;
- keep using the current profile’s model, URL, and API key after resume;
- take a process lock on explicit UUIDs and `resume --last` so two processes do not resume the same session at once.

## Design

Each route is a fixed pair of files:

```text
default.config.toml + auth.json
work.config.toml     + auth.json.work
lab.config.toml      + auth.json.lab
```

Example flow for `codex-work resume`:

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

The route script reads the current `model_provider` and injects both settings automatically. New profiles that omit them still use the current process key for new sessions and `resume`, instead of falling back to the shared root `auth.json`.

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
~/.local/bin/codex-default
~/.local/bin/codex-work
~/.local/bin/codex-lab
~/.local/bin/codex-routes
~/.local/bin/codex-sync-routes
```

(Wrappers appear for every paired `<name>.config.toml` + `auth.json.<name>` under `~/.codex`; `default` uses root `auth.json`.)

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

- Does not rewrite existing JSONL messages or history metadata.
- Bare `resume` uses Codex native UI; the native list is filtered by the current `model_provider`.
- Explicit UUID resume and `resume --last` hold a process lock so two processes do not append the same JSONL at once.
- `resume --last` is resolved to a UUID first by a read-only SQLite selector.
- Native UI selection happens inside the Codex process; the outer script never learns the UUID, so that path has no UUID lock.
- `fork` creates a new UUID, so it does not take the original session’s write lock.
- API keys are injected only into the current Codex process.
- Default sensitive-env excludes stay enabled and shell snapshots are disabled so keys do not leak into tool shells or snapshots.

## Migrating old sessions

If you previously used `~/.codex/shared`, review and run:

```bash
~/.codex/scripts/codex-migrate-to-root.sh
```

The migration uses `--ignore-existing` and `INSERT OR IGNORE`, so it will not overwrite sessions already under the root. Back up all of `~/.codex` before running it.

## Tests

The full suite uses temp dirs and fake credentials, never real APIs. It includes isolated tests and real Codex CLI tests:

```bash
./scripts/test-codex-profile.sh
```

Fast isolated tests only:

```bash
CODEX_PROFILE_TEST_SKIP_E2E=true ./scripts/test-codex-profile.sh
```

Real Codex end-to-end tests use the local `codex` binary and a local mock Responses server. They create a real session, then resume the same UUID via `codex-work` and `codex-default`, with no external API calls:

```bash
./scripts/test-codex-profile-e2e.sh
```

Set `CODEX_PROFILE_E2E_CODEX_BIN` to point at a specific Codex binary. The temporary `CODEX_HOME` is removed when the test finishes.

## Limitations

- Fixed profiles layer on top of root `config.toml`; fields not set in a profile still inherit from the root.
- Shared config sync runs on every route refresh and assumes single-line `key = value` entries; multi-line arrays or strings are not merged. Source comments are not synced; each profile keeps its own. `[projects."..."]` and other non-model sections are treated as shared and synced.
- Codex native resume UI filters by current `model_provider`; `--all` only drops the directory filter. Old sessions from a different provider need an explicit UUID, or the cross-provider selector used by `fork`.
- The native UI path does not get this project’s extra UUID-level cross-process lock; explicit UUIDs and `--last` do.
- Concurrent edits to the same profile config by multiple processes follow Codex’s last-writer-wins behavior.
- Explicit `--remote` uses remote App Server config; local profiles cannot override remote model and auth.
- Plugin dirs and ChatGPT cloud features may still use the shared root AuthManager; that does not affect model requests for custom providers.

See `docs/design.md` for design detail and `docs/verification.md` for verification notes.
