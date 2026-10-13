#!/usr/bin/env bash
# full-health.sh — режим full скилла health-check (~1 минута).
#
# Делает всё то же, что quick-health.sh, плюс:
# - docker stats per-container (CPU/RAM/Net)
# - docker inspect healthcheck для всех контейнеров
# - TLS expiry для всех доменов из <infra>/inventory/shared/domains.md
# - nginx -t на сервере
# - drift inventory ↔ реальность (список контейнеров)
# - (опц) Beszel API за последние 24ч если BESZEL_URL задан
#
# Не делает изменений на сервере — Green Zone.
#
# Параметры — те же что у quick-health.sh.

set -u

OUTPUT="${OUTPUT:-human}"
SSH_TARGET="${SSH_TARGET:-}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/_common.sh"
resolve_inventory

# 1) Сначала запускаем quick-health.sh — он покрывает базу
echo "=== Smoke part ==="
MODE=smoke OUTPUT="$OUTPUT" bash "$SCRIPT_DIR/quick-health.sh" || true

run() {
    if [ -n "$SSH_TARGET" ]; then
        ssh -o ConnectTimeout=5 -o BatchMode=yes "$SSH_TARGET" "$1" 2>/dev/null
    else
        bash -c "$1" 2>/dev/null
    fi
}

echo ""
echo "=== Full part ==="

# 2) docker stats (one-shot snapshot)
echo ""
echo "--- Docker stats per-container ---"
run "docker stats --no-stream --format 'table {{.Name}}\t{{.MemUsage}}\t{{.CPUPerc}}'" || \
    echo "docker stats недоступен"

# 3) Healthcheck statuses
echo ""
echo "--- Healthcheck statuses ---"
run 'for c in $(docker ps --format "{{.Names}}"); do
        H=$(docker inspect --format "{{if .State.Health}}{{.State.Health.Status}}{{else}}n/a{{end}}" "$c")
        printf "%-30s %s\n" "$c" "$H"
    done'

# 4) TLS expiry для доменов
echo ""
echo "--- TLS expiry по доменам из inventory/shared/domains.md ---"
if DOMAINS=$(list_domains) && [ -n "$DOMAINS" ]; then
    for D in $DOMAINS; do
        END=$(echo | timeout 5 openssl s_client -servername "$D" -connect "$D:443" 2>/dev/null \
              | openssl x509 -noout -enddate 2>/dev/null | sed 's/notAfter=//')
        if [ -n "$END" ]; then
            END_EPOCH=$(date -j -f "%b %d %H:%M:%S %Y %Z" "$END" +%s 2>/dev/null || \
                        date -d "$END" +%s 2>/dev/null)
            NOW_EPOCH=$(date -u +%s)
            if [ -n "$END_EPOCH" ]; then
                DAYS_LEFT=$(( (END_EPOCH - NOW_EPOCH) / 86400 ))
                if [ $DAYS_LEFT -lt 14 ]; then TAG="RED   "
                elif [ $DAYS_LEFT -lt 30 ]; then TAG="YELLOW"
                else TAG="GREEN "; fi
                printf '%s | %-30s осталось %s дней\n' "$TAG" "$D" "$DAYS_LEFT"
            else
                printf 'GRAY   | %-30s не удалось распарсить дату\n' "$D"
            fi
        else
            printf 'RED    | %-30s TLS недоступен\n' "$D"
        fi
    done
else
    echo "domains.md не найден (INVENTORY_DIR='${INVENTORY_DIR}') — TLS НЕ проверен"
fi

# 5) nginx -t (только если nginx установлен)
echo ""
echo "--- nginx -t ---"
if run "command -v nginx" >/dev/null; then
    run "nginx -t 2>&1" || echo "nginx -t упал"
else
    echo "nginx не установлен — пропуск"
fi

# 6) Drift между docker ps и inventory/shared/services.md
echo ""
# Файл: inventory/hosts/<хост>/services.md, иначе legacy inventory/shared/services.md.
# Сверка односторонняя: работающий контейнер, ни разу не упомянутый в файле, — сигнал.
# Обратную сторону («описан, но не запущен») из таблиц свободной формы надёжно не вычислить —
# её сверяет /inventory-scan.
SERVICES_FILE=""
for F in "${HOST_INV_DIR:+$HOST_INV_DIR/services.md}" "${INVENTORY_DIR:+$INVENTORY_DIR/shared/services.md}"; do
    [ -n "$F" ] && [ -f "$F" ] && { SERVICES_FILE="$F"; break; }
done
echo "--- Drift docker ps → ${SERVICES_FILE:-services.md} ---"
if [ -n "$SERVICES_FILE" ]; then
    UNKNOWN=""
    for C in $(run "docker ps --format '{{.Names}}'" | sort -u); do
        grep -qF "$C" "$SERVICES_FILE" || UNKNOWN="$UNKNOWN $C"
    done
    if [ -z "$UNKNOWN" ]; then
        echo "GREEN | все работающие контейнеры описаны в inventory"
    else
        echo "YELLOW | контейнеры на сервере, но НЕТ в inventory:$UNKNOWN"
        echo "Рекомендация: запусти inventory-scan для синхронизации"
    fi
else
    echo "services.md хоста не найден (INVENTORY_DIR='${INVENTORY_DIR}', хост не опознан по SSH_TARGET) — drift НЕ проверен"
fi

# 7) Beszel API (если задан URL)
if [ -n "${BESZEL_URL:-}" ] && [ -n "${BESZEL_TOKEN:-}" ]; then
    echo ""
    echo "--- Beszel за 24ч ---"
    curl -s --max-time 5 -H "Authorization: Bearer $BESZEL_TOKEN" \
         "$BESZEL_URL/api/collections/system_stats/records?perPage=1&sort=-created" \
         | jq -r '.items[0] | "CPU: \(.cpu)%, RAM: \(.mp)%, Disk: \(.dp)%"' 2>/dev/null \
         || echo "Beszel API не ответил"
fi

echo ""
echo "=== Full check завершён ==="
