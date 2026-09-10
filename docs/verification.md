# Verification

## Automated tests

`scripts/test-codex-profile.sh` covers:

- fixed profile → auth mapping;
- `CODEX_API_KEY` and `OPENAI_API_KEY` injection in `apikey` mode;
- automatic `env_key` override for incorrect provider auth config;
- bare `resume --all` passed through to Codex with no pre-injected UUID;
- explicit UUID passthrough;
- `resume --last` still resolved from shared SQLite and rewritten to a UUID;
- legacy `config.toml.<name>` not used as a route source file;
- auto-generated commands and Bash aliases;
- fish `conf.d` autoload, PATH discovery, route listing, and argument forwarding;
- auth-mode resolution: `<name>.auth-mode` sidecar, `CODEX_PROFILE_AUTH`
  override, inference from a `tokens`-only auth file, a `login` route that needs
  no auth file, a hard failure when the auth file has neither shape, and
  `list` labelling shared-login routes;
- `login` routes pass no `model_providers.*` override and leave both key
  variables empty;
- a `login`-mode launch is refused when the provider table still declares
  `base_url` or `env_key`, and the refusal names the offending key;
- the cross-provider selector offers only interactive sources by default and
  adds `exec`/`app_server` with `--include-non-interactive`, never subagent rows;
- route registration without an auth file: a `login`-marked profile gets a
  generated command and a Bash alias, a config with neither an auth file nor the
  sidecar gets neither;
- provider normalization: `--dry-run` prints impact without writing, a real run
  rewrites legacy ids (including one containing an apostrophe) to the inferred
  target, the index backup is created, a rerun is a no-op, a repeat pass
  picks up a newly inserted legacy row while leaving the earlier backup
  byte-identical and still showing pre-migration labels, and the target
  inference prefers the root `config.toml` over a disagreeing
  `default.config.toml` while still falling back to it;
- shared config sync on route refresh: protected model/provider fields kept, shared keys overwritten and appended, in-section kv merge, source-only sections appended, top-level keys stay before tables, idempotent re-run, and no standalone `codex-sync-config` command generated.

By default the suite also runs the real Codex end-to-end tests. Set
`CODEX_PROFILE_TEST_SKIP_E2E=true` to skip that stage.

## Real Codex end-to-end tests

`scripts/test-codex-profile-e2e.sh` uses the local real Codex binary and a local
mock Responses server. It covers:

- creating a real session through the generated command resolved from `PATH`, and
  persisting JSONL;
- resuming the same UUID through a sourced Bash alias (`codex-aliases.sh` in a
  script file, so alias expansion is exercised), and once more through
  `codex-default` — that name is deliberate, it exercises the `default` route
  pairing with the root `auth.json` that the guide otherwise discourages;
- fish as an optional third leg: without a fish binary the suite reports the skip
  and still runs everything through Bash;
- both profiles’ model settings appearing in actual Codex requests;
- a temporary `CODEX_HOME` so no external API is hit and real sessions are not
  modified.

Optional: `CODEX_PROFILE_E2E_CODEX_BIN` pins the Codex binary, and
`CODEX_PROFILE_E2E_FISH_BIN` supplies a fish binary to add the fish leg.

## Source behavior assumptions

Re-read against Codex 0.154.0 during the provider-sharing work (paths relative
to `codex-rs/`):

- `--profile <name>` loads `$CODEX_HOME/<name>.config.toml` and layers it above
  root config (`config/src/config_layer_source.rs`);
- `resume` without a UUID opens the native TUI session picker
  (`tui/src/lib.rs`);
- the local native picker queries sessions by current `model_provider`
  (`tui/src/resume_picker.rs` → `app-server/src/request_processors/thread_processor.rs`
  → `state/src/runtime/threads.rs`: `AND threads.model_provider IN (...)`);
  `--all` only drops the cwd filter, and no flag, env var, or config key turns
  the provider filter off;
- the picker’s candidate sources are `cli` and `vscode`, plus `exec` and
  `app_server` with `--include-non-interactive`; subagent rows store JSON in
  `source` and are excluded;
- local TUI resume explicitly sends the current model and provider, and
  `tui/src/app/config_persistence.rs` promotes that to an override
  whenever the profile layer or a `-c` flag pins `model` / `model_provider`, so
  a resumed session adopts the live route’s model, endpoint, and credentials;
- TUI embedded App Server disables `CODEX_API_KEY` AuthManager env overrides
  (`login/src/auth/manager.rs`, `cli/src/main.rs`);
- Bearer auth from provider `env_key` takes precedence over the shared
  AuthManager (`model-provider/src/auth.rs`: `bearer_auth_for_provider()` runs
  first, and a provider with `requires_openai_auth = false` and no `auth`
  command resolves to no auth headers at all — which is why a login-mode route
  must keep `requires_openai_auth = true`);
- omitting `model_provider` everywhere falls back to the built-in `openai` id
  (`core/src/config/mod.rs`), and an id with no matching table is a hard
  `Model provider ... not found` error;
- a provider `name` defaults to empty and is rejected by
  `validate_model_providers()` (`config/src/config_toml.rs`), so a root provider
  table that supplies `name` removes that failure mode for profiles that forget
  it;
- the thread index has no auth-mode or account column: ChatGPT login versus API
  key is not a resume filter, only the recorded `model_provider` label is;
- a custom provider table may not be named `openai`: reserved built-in ids are a
  config error (`config/src/config_toml.rs`);
- first-party provider behavior is name-gated — `is_openai()` compares the
  provider `name`, `supports_codex_backend_routes()` also accepts a missing
  `base_url`, and `to_api_provider()` derives the official ChatGPT backend URL
  from the auth mode when `base_url` is absent (`model-provider-info/src/lib.rs`);
- explicit UUID resume bypasses the provider filter
  (`tui/src/lib.rs`), while `codex exec resume --last` is provider-scoped
  (`exec/src/lib.rs`) with a rollout-scan fallback.

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

## Cross-provider visibility (manual)

With one mock Responses endpoint and two profiles whose only difference is the
provider id:

- `codex-<beta> resume --all` listed only sessions created under `beta` and
  reported no match for a marker string that exists solely in an `alpha`
  session, so the native list really is provider-scoped;
- `codex-<beta> resume <alpha-uuid>` still started, and the request carried
  `beta`’s model and `beta`’s key;
- after that resume the index row’s model had been rewritten from `alpha`’s
  model to `beta`’s, confirming the live profile wins on resume;
- recording both profiles under one provider id made both sessions appear in
  either picker.

Conclusion: what hides a session is the `model_provider` label stored in the
index, not the auth mode, so the script-side fix is a shared provider id plus a
one-time normalization pass.

## Shared login bucket (manual)

Against a real `~/.codex` holding a ChatGPT login, after the root `config.toml`
started declaring the shared provider id with `name = "OpenAI"`:

- `codex doctor` reported `model … · localhost`, `provider name OpenAI`,
  `reachability mode ChatGPT auth`, and `0 fail`, so bare `codex` resolves the
  shared id and authenticates through the login rather than a key;
- `codex resume --all` on bare `codex` listed sessions that the route profiles
  had recorded, including rows that had needed the normalization pass, and left
  the index untouched;
- launching a route that resolves to `login` while its provider table still
  carried a third-party `base_url` was refused, with the endpoint that would have
  received the ChatGPT token printed in the message.
