# Verification

## Automated tests

`scripts/test-codex-profile.sh` covers:

- fixed profile → auth mapping;
- `CODEX_API_KEY` and `OPENAI_API_KEY` injection;
- automatic `env_key` override for incorrect provider auth config;
- bare `resume --all` passed through to Codex with no pre-injected UUID;
- explicit UUID passthrough;
- `resume --last` still resolved from shared SQLite and rewritten to a UUID;
- legacy `config.toml.<name>` not used as a route source file;
- auto-generated commands and Bash aliases;
- fish `conf.d` autoload, PATH discovery, route listing, and argument forwarding.

By default the suite also runs the real Codex end-to-end tests. Set
`CODEX_PROFILE_TEST_SKIP_E2E=true` to skip that stage.

## Real Codex end-to-end tests

`scripts/test-codex-profile-e2e.sh` uses the local real Codex binary and a local
mock Responses server. It covers:

- creating a real session through a fish route and persisting JSONL;
- resuming the same UUID via `codex-work` and `codex-default`;
- both profiles’ model settings appearing in actual Codex requests;
- a temporary `CODEX_HOME` so no external API is hit and real sessions are not
  modified.

Optional: `CODEX_PROFILE_E2E_CODEX_BIN` / `CODEX_PROFILE_E2E_FISH_BIN` to pin
binaries.

## Source behavior assumptions

Implementation targets Codex 0.144.6 behavior:

- `--profile <name>` loads `$CODEX_HOME/<name>.config.toml`;
- `resume` without a UUID opens the native TUI session picker;
- the local native picker queries sessions by current `model_provider`; `--all`
  only drops the cwd filter;
- local TUI resume explicitly sends the current model and provider;
- TUI embedded App Server disables `CODEX_API_KEY` AuthManager env overrides;
- Bearer auth from provider `env_key` takes precedence over the shared
  AuthManager;
- when explicit model/provider overrides are present, historical session
  model/provider are not restored.

## Isolated verification

With a local mock endpoint and fake keys:

- requests go to the current profile URL, not the root config URL;
- Authorization fingerprints match the current profile auth;
- request model comes from the current profile;
- tests never call a real API or write into a real session directory.

## Live TUI verification

After installing the route scripts into an existing `CODEX_HOME`, from a trusted
directory run a generated suffix command:

```text
codex-<profile> resume --all
```

On a real fixed-size pseudo-TTY confirm:

- Codex native title `Resume a previous session` is shown;
- native Filter, Sort, and quit hints appear;
- no session is selected or resumed, and no Codex process remains after quit;
- shared SQLite index mtime and size stay unchanged.
