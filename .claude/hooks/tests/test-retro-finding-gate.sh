#!/usr/bin/env bash
# Тесты гейта находок /retro (ADR-0021). Прогон: bash .claude/hooks/tests/test-retro-finding-gate.sh
set -uo pipefail

# Обвязка теста тоже печатает русский текст через python: на чужой кодовой странице
# (Windows cp1252) она падает и подаёт хуку пустой вход — тест «проваливается» там,
# где замок исправен. Правило 3д свода замков.
export PYTHONIOENCODING=utf-8
HOOK="$(cd "$(dirname "$0")/.." && pwd)/retro-finding-gate.sh"
PASS=0; FAIL=0

run() { # $1 = file_path, $2 = текст правки, $3 = поле (new_string|content)
  python3 - "$1" "$2" "${3:-new_string}" <<'PY' | env PYTHONIOENCODING="${HOOK_ENC:-utf-8}" bash "$HOOK"
import json, sys
print(json.dumps({"tool_name": "Edit", "tool_input": {"file_path": sys.argv[1], sys.argv[3]: sys.argv[2]}}, ensure_ascii=False))
PY
}

check() { # $1 = allow|deny, $2 = описание, $3 = path, $4 = текст, $5 = поле
  local out; out="$(run "$3" "$4" "${5:-new_string}")"
  local got="allow"; printf '%s' "$out" | grep -q '"permissionDecision": *"deny"' && got="deny"
  if [ "$got" = "$1" ]; then PASS=$((PASS+1)); printf '  ✅ %s\n' "$2"
  else FAIL=$((FAIL+1)); printf '  ❌ %s — ожидали %s, получили %s\n' "$2" "$1" "$got"; fi
}

B="/repo/retro/BACKLOG.md"
OK_FACT='| 2026-07-24 | MUST | скиллы | факт | скилл выдал ложный drift | чинить парсер | open |'
OK_HYPO='| 2026-07-24 | MAY | персона | гипотеза | возможно, рефлекс не сработал | проверить на след. сессии | open |'
NO_BASIS='| 2026-07-24 | MUST | скиллы | агент сломал оператору рабочий VPN | откатить | open |'
HISTORIC='| 2026-06-14 | MUST | скиллы | старая находка без основания | предложение | done (fix abc123) |'
HEADER='| Дата | Severity | Фронт | Основание | Находка | Предложение | Статус |
|------|----------|-------|----------|---------|-------------|--------|'

echo "── Тесты гейта находок /retro ───────────────────────────"
echo "[1] Посторонние файлы гейт не трогает"
check allow "правка README"            "/repo/README.md"        "$NO_BASIS"
check allow "заметки, не бэклог"       "/repo/docs/NOTES.md"    "$NO_BASIS"
# Ожидание изменено осознанно (F5, 2026-07-24): раньше гейт стоял только на
# `retro/BACKLOG.md`, теперь — на любом бэклоге находок, потому что саморазбор
# переехал в `_retro/`. Кейс `/repo/docs/BACKLOG.md` переехал в секцию [5].

echo "[2] Корректные находки проходят"
check allow "основание «факт»"         "$B" "$OK_FACT"
check allow "основание «гипотеза»"     "$B" "$OK_HYPO"
check allow "шапка и разделитель"      "$B" "$HEADER"
check allow "историческая строка done" "$B" "$HISTORIC"
check allow "обычный текст без таблиц" "$B" "## Раздел про находки, open вопросы"

echo "[3] Находка без основания блокируется"
check deny  "нет ни факта, ни гипотезы" "$B" "$NO_BASIS"
check deny  "среди корректных затесалась плохая" "$B" "$OK_FACT
$NO_BASIS"
check deny  "полная перезапись файла (content)"  "$B" "$HEADER
$NO_BASIS" content

echo "[4] Относительный путь тоже под гейтом"
check deny  "retro/BACKLOG.md без префикса" "retro/BACKLOG.md" "$NO_BASIS"

echo "[5] Гейт следует за находками, а не за каталогом (F5, разбор 2026-07-24)"
check deny  "_retro/BACKLOG.md (глобальный /lore-retro)" "/repo/_retro/BACKLOG.md" "$NO_BASIS"
check deny  "любой иной бэклог находок"                  "/repo/docs/notes/BACKLOG.md" "$NO_BASIS"
check allow "сырой отчёт аудитора не гейтим"             "/repo/_retro/REVIEW-2026-07-24-1c176a94.md" "$NO_BASIS"
check allow "дайджест стенограммы не гейтим"             "/repo/_retro/_digest.md" "$NO_BASIS"

echo "[Кодировка] Вердикт доходит и при чужой кодовой странице консоли (правило 3д)"
# Дефект 26.08.2026: гейт печатал ответ через python, а консоль на Windows в cp1252 —
# python падал на первом же русском символе, хук не печатал НИЧЕГО и выходил с кодом 0.
# Движок читает это как «возражений нет»: 6 случаев из 6 проходили как разрешённые.
# Лечится строкой `export PYTHONIOENCODING=utf-8` в шапке ХУКА, но проверять её надо
# отдельным случаем: своим таким же export (шапка этого файла) тест лечит хук ЗА НЕГО —
# переменная наследуется дочернему процессу, и убери её из хука, итог останется зелёным.
# Здесь кодировка навязывается ИМЕННО ХУКУ, перекрывая наследство.
HOOK_ENC=cp1252
check deny  "отказ доходит при cp1252-консоли" "$B" "$NO_BASIS"
check allow "находка с основанием проходит"    "$B" "$OK_FACT"
ENC_OUT="$(run "$B" "$NO_BASIS" 2>/dev/null)"
if printf '%s' "$ENC_OUT" | grep -q 'основани'; then
  PASS=$((PASS+1)); echo "  ✅ русский текст причины не искажён"
else
  FAIL=$((FAIL+1)); echo "  ❌ причина при cp1252 пуста или искажена"
fi
unset HOOK_ENC

echo "─────────────────────────────────────────────────────────"
printf 'Итог: %d прошло, %d провалено\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
