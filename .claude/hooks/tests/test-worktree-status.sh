#!/usr/bin/env bash
# Тесты SessionStart-напоминалки о незакоммиченной работе (ADR-0042).
# Прогон: bash .claude/hooks/tests/test-worktree-status.sh
set -uo pipefail

HOOK="$(cd "$(dirname "$0")/.." && pwd)/worktree-status.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
# Реальный путь оператора: пробел и кириллица (чек-лист свода замков).
REPO="$TMP/Анвар Жамильевич/sysadmin"
mkdir -p "$REPO"
PASS=0; FAIL=0

g() { git -C "$REPO" "$@" >/dev/null 2>&1; }
g init; g config user.email t@t; g config user.name t; g config core.autocrlf false
printf 'a\n' > "$REPO/README.md"; g add README.md; g commit -m init
MARK="$(git -C "$REPO" rev-parse --absolute-git-dir)/sysadmin-dirty-since"

run() { echo '{"hook_event_name":"SessionStart"}' | CLAUDE_PROJECT_DIR="$REPO" bash "$HOOK"; }

ok()   { PASS=$((PASS+1)); printf '  ✓ %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  ✗ %s\n      вывод: %s\n' "$1" "$2"; }
expect_silent() { local out; out="$(run)"; [ -z "$out" ] && ok "$1" || bad "$1" "$out"; }
expect_has()    { local out; out="$(run)"; case "$out" in *"$2"*) ok "$1" ;; *) bad "$1" "$out" ;; esac; }

echo "[1] чистое дерево — тишина, отметки нет"
expect_silent "чистое дерево"
[ ! -e "$MARK" ] && ok "отметка не создана" || bad "отметка не создана" "$(cat "$MARK")"

echo "[2] изменённый и новый файл — напоминание, отметка создана"
printf 'b\n' >> "$REPO/README.md"; mkdir -p "$REPO/.agents/skills"; printf 'x\n' > "$REPO/.agents/skills/a.md"
expect_has "есть заголовок" "НЕЗАКОММИЧЕННАЯ РАБОТА в sysadmin"
expect_has "число файлов" ": 2 файл"
expect_has "группа каталога" ".agents/ (1)"
[ -s "$MARK" ] && ok "отметка создана" || bad "отметка создана" "нет файла"

echo "[3] возраст — из отметки, не из mtime файлов"
printf '%s\n' "$(( $(date +%s) - 3*86400 - 60 ))" > "$MARK"
expect_has "три дня по отметке" "не меньше 3 дн."
touch -d '30 days ago' "$REPO/README.md" 2>/dev/null
expect_has "старый mtime не меняет возраст" "не меньше 3 дн."

echo "[4] не-ASCII имя показано как есть, а не октальными кодами"
printf 'j\n' > "$REPO/ЖУРНАЛ-ИИ.md"
expect_has "кириллическое имя" "ЖУРНАЛ-ИИ.md (1)"

echo "[5] битая отметка не роняет хук"
printf 'мусор\n' > "$MARK"
expect_has "битая отметка → «замечено»" "замечено в этой или вчерашней сессии"

echo "[6] дерево снова чистое — тишина, отметка снята"
g add -A; g commit -m all
expect_silent "чистое после коммита"
[ ! -e "$MARK" ] && ok "отметка снята" || bad "отметка снята" "$(cat "$MARK")"

echo "[7] не git-репозиторий — тишина и код 0"
mkdir -p "$TMP/plain"
out="$(echo '{}' | CLAUDE_PROJECT_DIR="$TMP/plain" bash "$HOOK")"; rc=$?
[ -z "$out" ] && [ "$rc" -eq 0 ] && ok "вне репозитория" || bad "вне репозитория" "rc=$rc $out"

echo "[8] шаблон: хук не коммитит, не прячет и не чистит дерево"
if grep -vE '^\s*#' "$HOOK" | grep -qE 'git[^|]*\b(commit|stash|reset|clean|checkout|add)\b'; then
    bad "нет изменяющих git-команд" "$(grep -nE 'git[^|]*\b(commit|stash|reset|clean|checkout|add)\b' "$HOOK")"
else
    ok "нет изменяющих git-команд"
fi
grep -vE '^\s*#' "$HOOK" | grep -q 'python' && bad "вывод без python (правило 3д)" "python в хуке" || ok "вывод без python (правило 3д)"

printf 'Итог: %d прошло, %d провалено\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
