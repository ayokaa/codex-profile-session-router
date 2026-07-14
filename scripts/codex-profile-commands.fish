# Codex profile command integration for fish.

if set -q CODEX_HOME
    set -l codex_profile_home "$CODEX_HOME"
else
    set -l codex_profile_home "$HOME/.codex"
end

set -l codex_profile_bin "$HOME/.local/bin"
if not contains -- "$codex_profile_bin" $PATH
    set -gx PATH "$codex_profile_bin" $PATH
end

set -l codex_profile_sync "$codex_profile_home/scripts/codex-sync-commands.sh"
if test -x "$codex_profile_sync"
    command "$codex_profile_sync" --quiet >/dev/null 2>&1
end
