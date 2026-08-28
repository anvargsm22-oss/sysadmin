#!/usr/bin/env bash
# .claude/hooks/retro-finding-gate.sh — PreToolUse-хук: гейт формата находок /retro (ADR-0021).
#
# ЗАЧЕМ. Саморазбор `/retro` пишет в BACKLOG и ADR — то есть в память, которой доверяют
# будущие сессии. Один раз он уже сконфабулировал: записал последствие («агент сломал
# оператору рабочий VPN»), которого в транскрипте не было. Выдуманная находка живёт дальше
# уже как факт. Правило «не повышай гипотезу до факта» было прозой в рубрикаторе; хук делает
# его механическим: находку нельзя записать, не объявив её основание.
#
# ПОВЕДЕНИЕ:
#   пишем не в retro/BACKLOG.md            → тихо пропускаем
#   новая активная находка с основанием    → пропускаем
#   новая активная находка без основания   → deny + образец строки
#
# Основание — ровно одно слово в строке: «факт» (есть в транскрипте, цитата приведена)
# либо «гипотеза» (правдоподобно, но не подтверждено — так и записывается).
# Исторические строки (`done`, `wontfix`) не проверяются: гейт смотрит вперёд, не назад.
#
# Ручная проверка: bash .claude/hooks/tests/test-retro-finding-gate.sh

set -uo pipefail

# Вывод хука читает движок, а не терминал: печатаем UTF-8 независимо от кодовой страницы
# консоли. Без этого на Windows (cp1252) python падает на первом же не-ASCII символе, а
# сообщения здесь русские — хук не печатает НИЧЕГО и выходит с кодом 0, что движок читает
# как «разрешаю»: замок молча пропускает то, ради чего поставлен (поймано 26.08.2026,
# 16 случаев теста из 16). Разбор — building-enforcement.md, правило «немой замок».
export PYTHONIOENCODING=utf-8
RAW="$(cat)"

json_get() {
  local path="$1"
  if command -v python3 >/dev/null 2>&1; then
    printf '%s' "$RAW" | python3 -c '
import sys, json
try: d = json.load(sys.stdin)
except Exception: sys.exit(1)
cur = d
for k in sys.argv[1].split("."):
    if not isinstance(cur, dict) or k not in cur: sys.exit(1)
    cur = cur[k]
print(cur if isinstance(cur, str) else json.dumps(cur, ensure_ascii=False))
' "$path" 2>/dev/null && return 0
  fi
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$RAW" | jq -er ".${path} // empty" 2>/dev/null && return 0
  fi
  return 1
}

FILE="$(json_get tool_input.file_path || true)"
# Гейт срабатывает на ЛЮБОМ бэклоге находок, а не только на пути локального скилла
# `/retro`. Причина (разбор 2026-07-24, F5): саморазбор переехал в глобальный навык
# `/lore-retro`, который пишет в `_retro/`, и правило снова стало просто прозой на новом
# маршруте. Гейт должен следовать за находками, а не за именем каталога.
#
# Границы: сырой отчёт аудитора (`_retro/REVIEW-*.md`, `_digest.md`) НЕ гейтим — это
# стенограмма чужого суждения с цитатами, а не запись в память. Гейт стоит там, где
# находка становится трекаемой задачей.
case "${FILE:-}" in
  *BACKLOG.md) ;;
  *) exit 0 ;;
esac

# Write отдаёт весь файл в content, Edit — добавляемый кусок в new_string.
TEXT="$(json_get tool_input.new_string || true)"
[ -z "${TEXT:-}" ] && TEXT="$(json_get tool_input.content || true)"
[ -z "${TEXT:-}" ] && exit 0

# Ищем активные строки-находки без объявленного основания.
BAD="$(printf '%s' "$TEXT" | awk '
  /^[[:space:]]*\|/ {
    line = $0
    if (line ~ /^[[:space:]]*\|[[:space:]]*-+/) next          # разделитель таблицы
    if (line ~ /Severity/ || line ~ /Находка/) next            # шапка
    if (line !~ /open/) next                                   # исторические done/wontfix
    if (line ~ /факт/ || line ~ /гипотеза/) next               # основание объявлено
    print line
  }')"

[ -z "$BAD" ] && exit 0

COUNT="$(printf '%s\n' "$BAD" | grep -c . )"
SAMPLE="$(printf '%s\n' "$BAD" | head -2 | cut -c1-160)"

REASON="🚧 ГЕЙТ /retro — находка без объявленного основания (ADR-0021).

Строк без основания: ${COUNT}
${SAMPLE}

Саморазбор пишет в память, которой поверят будущие сессии. Поэтому каждая активная
находка обязана объявить, на чём стоит — ОДНИМ словом в строке:

  факт      — есть в транскрипте, цитата приведена в сыром отчёте
  гипотеза  — правдоподобно, но транскриптом не подтверждено

Образец строки:
| 2026-07-24 | MUST | скиллы | факт | <что именно произошло> | <предложение> | open |

NEVER повышать внутрисессионную гипотезу агента («скорее всего X») до находки-факта
(«оказалось X»), и NEVER приписывать последствие, следа которого в транскрипте нет —
такую находку убираем или переписываем в то, что действительно было."

if command -v python3 >/dev/null 2>&1; then
  python3 -c '
import sys, json
print(json.dumps({"hookSpecificOutput": {
  "hookEventName": "PreToolUse",
  "permissionDecision": "deny",
  "permissionDecisionReason": sys.argv[1]}}, ensure_ascii=False))
' "$REASON"
else
  esc="$(printf '%s' "$REASON" | sed 's/\\/\\\\/g; s/"/\\"/g' | awk 'BEGIN{ORS="\\n"}1')"
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}\n' "$esc"
fi
