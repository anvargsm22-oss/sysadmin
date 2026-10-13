#!/usr/bin/env bash
# worktree-status.sh — напоминание о незакоммиченной работе в репозитории мозга (ADR-0042).
#
# Вызов: SessionStart в Claude Code (.claude/settings.json); в Codex — первым шагом по AGENTS.md.
# Ничего не коммитит, не прячет и не чистит: только печатает сводку, которую агент
# пересказывает оператору одной строкой. Решение о коммите — за оператором.
#
# Ожог 2026-10-13: адаптация под Codex (ADR-0041) пролежала незакоммиченной 6 дней,
# её никто не замечал, пока новый pre-commit не заблокировал чужой коммит.
#
# Возраст: mtime файлов возраст работы НЕ доказывает (checkout и генераторы его сбивают),
# поэтому момент, когда дерево впервые замечено «грязным», хранится в .git/ (вне истории).
# Дерево стало чистым — отметка снимается. Граница: это «грязно непрерывно с …», а не
# «самому старому изменению столько-то»; частичный коммит возраст не обнуляет.
#
# Вывод — чистый bash без python: не зависит от кодовой страницы консоли (правило 3д
# building-enforcement.md). Любой сбой — тишина и код 0: напоминалка не должна мешать старту.

cat >/dev/null 2>&1 || true   # вход хука (JSON) не нужен

root="${CLAUDE_PROJECT_DIR:-}"
[ -n "$root" ] || root="$(git rev-parse --show-toplevel 2>/dev/null)" || exit 0
[ -n "$root" ] || exit 0

status="$(git -C "$root" -c core.quotePath=false --no-optional-locks status --porcelain=v1 2>/dev/null)" || exit 0
git_dir="$(git -C "$root" rev-parse --absolute-git-dir 2>/dev/null)" || exit 0
mark="$git_dir/sysadmin-dirty-since"

if [ -z "$status" ]; then
    rm -f "$mark" 2>/dev/null
    exit 0
fi

now="$(date +%s)"
if [ ! -s "$mark" ]; then
    printf '%s\n' "$now" > "$mark" 2>/dev/null || true
fi
since="$(cat "$mark" 2>/dev/null)"
case "$since" in ''|*[!0-9]*) since="$now" ;; esac
days=$(( (now - since) / 86400 ))

total="$(printf '%s\n' "$status" | grep -c .)"
# Группы верхнего уровня: путь после двух символов статуса и пробела; кавычки git для
# не-ASCII имён убираются, чтобы «ЖУРНАЛ.md» и "\320..." не считались разными.
groups="$(printf '%s\n' "$status" | cut -c4- | sed 's/^"//; s/"$//; s/.* -> //' \
    | awk -F/ '{print (index($0, "/") ? $1 "/" : $1)}' | sort | uniq -c | sort -rn \
    | awk '{printf "%s%s (%s)", (NR > 1 ? ", " : ""), $2, $1}')"

if [ "$days" -ge 1 ]; then
    age="грязно не меньше ${days} дн. (с $(date -d "@$since" '+%Y-%m-%d' 2>/dev/null || echo "$since"))"
else
    age="замечено в этой или вчерашней сессии"
fi

printf 'НЕЗАКОММИЧЕННАЯ РАБОТА в %s: %s файл(ов), %s.\n' "$(basename "$root")" "$total" "$age"
printf 'Группы: %s\n' "$groups"
printf 'Агенту: скажи оператору об этом одной строкой в статусе сессии. Не коммить, не stash и не чисть без его слова.\n'
exit 0
