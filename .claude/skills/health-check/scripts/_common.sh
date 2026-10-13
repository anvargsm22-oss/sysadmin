#!/usr/bin/env bash
# _common.sh — общие помощники quick-health.sh и full-health.sh (подключается через source).
#
# resolve_inventory   → $INVENTORY_DIR (папка inventory/ активного проекта) и $HOST_INV_DIR
#                       (inventory/hosts/<хост>/ проверяемого сервера, если опознан).
# list_domains        → домены из таблиц inventory/shared/domains.md: первая колонка строки
#                       таблицы, токены в `обратных кавычках`; «+ `www`» раскрывается в www.<домен>;
#                       строки с TLS «—» (погашенные) пропускаются.
# backup_age_lines    → по строке «<часов>\t<теги>» на каждую группу тегов restic НА СЕРВЕРЕ.
#
# Почему не относительный путь `inventory/...`: скрипт запускается из sysadmin/, а inventory живёт
# в папке инфры оператора (ADR-0013) — относительный путь там молча не находил ничего, и TLS/drift
# пропускались с пометкой «не найден» (поймано обходом 2026-10-13).

# Папка inventory: явный INVENTORY_DIR → infra_root активного проекта → ./inventory
resolve_inventory() {
    HOST_INV_DIR=""
    if [ -z "${INVENTORY_DIR:-}" ]; then
        local lib
        lib="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../_lib" 2>/dev/null && pwd)"
        if [ -n "$lib" ] && [ -f "$lib/find-config.sh" ] && command -v jq >/dev/null 2>&1; then
            # shellcheck disable=SC1091
            . "$lib/find-config.sh"
            find_sysadmin_config silent >/dev/null 2>&1 || true
            [ -n "${ACTIVE_INFRA_ROOT:-}" ] && [ -d "$ACTIVE_INFRA_ROOT/inventory" ] \
                && INVENTORY_DIR="$ACTIVE_INFRA_ROOT/inventory"
        fi
        [ -z "${INVENTORY_DIR:-}" ] && [ -d "inventory" ] && INVENTORY_DIR="$(pwd)/inventory"
    fi
    INVENTORY_DIR="${INVENTORY_DIR:-}"

    # Хост: явный INVENTORY_HOST → каталог hosts/<имя>, совпадающий с адресом из SSH_TARGET,
    # либо тот, чей server.md упоминает этот адрес
    [ -n "$INVENTORY_DIR" ] && [ -d "$INVENTORY_DIR/hosts" ] || return 0
    if [ -n "${INVENTORY_HOST:-}" ]; then
        [ -d "$INVENTORY_DIR/hosts/$INVENTORY_HOST" ] && HOST_INV_DIR="$INVENTORY_DIR/hosts/$INVENTORY_HOST"
        return 0
    fi
    local addr="${SSH_TARGET:-}"
    addr="${addr##*@}"
    [ -n "$addr" ] || return 0
    if [ -d "$INVENTORY_DIR/hosts/$addr" ]; then
        HOST_INV_DIR="$INVENTORY_DIR/hosts/$addr"
        return 0
    fi
    local d
    for d in "$INVENTORY_DIR"/hosts/*/; do
        [ -f "$d/server.md" ] && grep -qF "$addr" "$d/server.md" && { HOST_INV_DIR="${d%/}"; return 0; }
    done
    return 0
}

list_domains() {
    local f="$INVENTORY_DIR/shared/domains.md"
    [ -n "${INVENTORY_DIR:-}" ] && [ -f "$f" ] || return 1
    awk -F'|' '
        /^\|/ && $2 ~ /`[a-z0-9.-]+\.[a-z]+`/ {
            if ($0 ~ /\| *— *\|/) next
            col = $2; base = ""
            while (match(col, /`[^`]+`/)) {
                tok = substr(col, RSTART + 1, RLENGTH - 2)
                col = substr(col, RSTART + RLENGTH)
                if (tok ~ /^[a-z0-9.-]+\.[a-z]+$/) { base = tok; print tok }
                else if (tok == "www" && base != "") print "www." base
            }
        }' "$f" | sort -u
}

# Выполняется на сервере через run(). Окружение restic берётся из RESTIC_ENV_FILE на сервере,
# если задан (файл с export RESTIC_REPOSITORY=… RESTIC_PASSWORD_FILE=…), иначе — из окружения
# самой ssh-сессии. Худшая группа тегов — главная: свежий снапшот одного бэкапа не должен прятать
# двухнедельную дыру другого (2026-10-13: x-ui свежий, system — 365 ч).
BACKUP_REMOTE_SNIPPET='
[ -n "${RESTIC_ENV_FILE_R:-}" ] && [ -r "$RESTIC_ENV_FILE_R" ] && { set -a; . "$RESTIC_ENV_FILE_R"; set +a; }
unset ALL_PROXY all_proxy http_proxy https_proxy HTTP_PROXY HTTPS_PROXY
command -v restic >/dev/null || { echo "NO_RESTIC"; exit 0; }
if [ -z "${RESTIC_REPOSITORY:-}" ]; then
    if { crontab -l 2>/dev/null; cat /etc/crontab /etc/cron.d/* 2>/dev/null; } | grep -v "^#" | grep -q .; then
        for s in $( { crontab -l 2>/dev/null; cat /etc/crontab /etc/cron.d/* 2>/dev/null; } | grep -v "^#" | grep -oE "/[^ ]+\.sh" | sort -u); do
            [ -f "$s" ] && grep -q restic "$s" && { echo "RESTIC_IN_CRON $s"; }
        done
    fi
    echo "NO_ENV"; exit 0
fi
now=$(date -u +%s)
restic snapshots --json --latest 1 --group-by tags 2>/dev/null \
 | jq -r "if (length > 0 and (.[0] | has(\"snapshots\"))) then .[] | [((.group_key.tags // []) | join(\",\")), (.snapshots | max_by(.time) | .time)] else .[] | [((.tags // []) | join(\",\")), .time] end | @tsv" \
 | while IFS="	" read -r tags t; do
       ts=$(date -u -d "$t" +%s 2>/dev/null) || continue
       printf "%s\t%s\n" $(( (now - ts) / 3600 )) "${tags:-без тегов}"
   done
'

backup_age_lines() {
    run "RESTIC_ENV_FILE_R='${RESTIC_ENV_FILE:-}'; $BACKUP_REMOTE_SNIPPET"
}
