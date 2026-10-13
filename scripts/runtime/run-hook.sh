#!/bin/sh
# POSIX bootstrap: interpreter/import failures must deliver a deny, not a silent success.
hook=${1:?hook name required}
script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd) || exit 2
if out=$("${SYSADMIN_PYTHON:-python3}" "$script_dir/codex_hook.py" "$hook"); then
    [ -z "$out" ] || printf '%s\n' "$out"
elif [ "$hook" = inventory ]; then
    printf '%s\n' '{"systemMessage":"Sysadmin/Codex inventory adapter failed to start; check Python."}'
else
    printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Sysadmin/Codex adapter failed to start; check Python before server changes."}}'
fi
