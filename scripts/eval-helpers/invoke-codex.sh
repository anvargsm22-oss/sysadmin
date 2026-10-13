#!/usr/bin/env bash
# Тот же контракт skill|cost|duration, но через Codex CLI. Стоимость неизвестна.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
exec python3 "$ROOT/scripts/eval-helpers/invoke-codex.py" "${1:?нужна фраза оператора}"
