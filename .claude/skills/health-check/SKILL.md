---
name: health-check
description: |
  Read-only диагностика здоровья сервера: docker ps, CPU/RAM/Disk, HTTP-эндпоинты, статус
  контейнеров (healthy/unhealthy/restarting), свежесть бэкапа, TLS-валидность. Три режима:
  smoke (~10 сек), full (~1 мин), specific (один сервис). Output: JSON + human-readable.
  Green Zone, без брифинга.
  Триггеры: «проверь сервер», «health check», «smoke test», «всё ли ок», «жив ли сервис»,
  «утренняя проверка», «diagnostic», «как там сервер».
  НЕ для изменений (это deploy-service / другие скиллы); НЕ для детального аудита (audit-security).
allowed-tools: Bash, Read
---

<role>
Я провожу быструю read-only диагностику без изменений на сервере. Три режима: smoke (10 секунд,
основные сигналы), full (1 минута, всё что есть), specific (один сервис в фокусе). Доклад
структурирован — оператор видит картину за один экран: что зелёное, что жёлтое, что красное.
Рекомендации по красным/жёлтым выдаю, но НЕ выполняю — это другие скиллы.
</role>

<context>
Предполагается:
- SSH-доступ к серверу (по ключу) или прямой запуск на сервере
- Docker установлен; на сервере есть `jq` для JSON-парсинга
- (Опционально) мониторинг-стек установлен — тогда дополняю запросами в Beszel/Kuma

НЕ предполагается:
- Изменение состояния сервера (это другие скиллы — `deploy-service`, `restart-stack`, runbook'и)
- Полный snapshot инвентаря с обновлением документов (это `inventory-scan`)
- Решение проблем (только сигнал и рекомендация)
</context>

<goals>
После выполнения:
- ✓ Структурированный отчёт по выбранному режиму (smoke / full / specific)
- ✓ Human-readable summary в конце (зелёный / жёлтый / красный + ключевые цифры)
- ✓ Список найденных проблем с уровнем критичности
- ✓ Рекомендация для каждой проблемы — без выполнения
</goals>

# Параметры

| Параметр | Default | Описание |
|----------|---------|----------|
| `MODE` | `smoke` | `smoke` (быстро) / `full` (полно) / `specific` (один сервис) |
| `TARGET` | `all` | имя контейнера для `MODE=specific`; `all` иначе |
| `OUTPUT` | `human` | `human` (для оператора) / `json` (для парсинга) |
| `SSH_TARGET` | из `inventory/hosts/` | `<user>@<ip>` или SSH-алиас; если запуск на сервере — пусто |
| `INVENTORY_DIR` | `<infra_root>/inventory` активного проекта | папка inventory; ищется через `_lib/find-config.sh`, запасной вариант — `./inventory` |
| `INVENTORY_HOST` | по адресу из `SSH_TARGET` | имя каталога `inventory/hosts/<хост>/` (для сверки контейнеров) |
| `RESTIC_ENV_FILE` | пусто | путь **на сервере** к файлу с `RESTIC_REPOSITORY`/`RESTIC_PASSWORD_FILE`; без него restic-окружение берётся из ssh-сессии |

Параметры передаются как переменные окружения (`MODE=full bash scripts/full-health.sh`) или через
аргументы скрипта (`--mode full --target <container-name>`).

# Процедура

## Шаг 0: Дайджест состояния, приехавший вместе со скиллом

!`r=$(git rev-parse --show-toplevel 2>/dev/null); s="$r/.claude/skills/_lib/host-digest.sh"; if [ -n "$r" ] && [ -f "$s" ]; then bash "$s"; else echo "НЕ СОБРАНО: переходник host-digest.sh не найден — сессия открыта не в репозитории мозга; работаю по шагам ниже"; fi || true`

Снимок выше собран **до** того, как я прочитал скилл: командой `state.digest_cmd` из карты
инфры оператора, ничего не хардкожено (ADR-0029). Как им пользоваться:

- **Ориентировка, а не доказательство.** У дайджеста две даты: когда он собран на сервере
  и когда я его забрал. **Забрал — печатаю я, в шапке снимка. Собран — ищи внутри самого
  дайджеста:** переходник эту дату не извлекает и не гарантирует, формат снимка у каждого
  оператора свой. Даты сборки в дайджесте не нашлось — так и говорю оператору, а не
  выдаю дату съёмки за дату сборки (C.2).
  Расхождение с живой командой решается в пользу живой команды (§4.6).
- **Вопрос «что вообще есть на сервере» закрывается снимком** — хода на сбор не трачу.
- **Вопрос «жив ли сервис прямо сейчас» снимком НЕ закрывается.** Проверка живости идёт
  живой командой по процедуре ниже: «зелёный статус не доказательство» (§3.11), а
  вчерашний зелёный статус — тем более.
- Написано `НЕ СОБРАНО` — снимка нет, работаю целиком по шагам ниже и говорю об этом
  оператору. Гадать по отсутствующему снимку запрещено.

## Шаг 1: Decision Tree — выбор режима

- **Если `MODE=smoke`** (по умолчанию) → выполнить `scripts/quick-health.sh` (~10 сек):
  docker ps, df, free, latest backup, основные HTTP-эндпоинты.

- **Если `MODE=full`** → выполнить `scripts/quick-health.sh`, затем `scripts/full-health.sh` (~1 мин):
  плюс docker stats, docker inspect для всех контейнеров, TLS expiry для всех доменов,
  drift inventory ↔ реальность, опрос Beszel/Kuma если установлены.

- **Если `MODE=specific`** → требуется `TARGET` (имя контейнера):
  глубокая диагностика только этого сервиса (logs --tail=50, inspect, healthcheck,
  HTTP-проверка по домену из inventory, depends_on контейнеры).
  Если `TARGET=all` при `MODE=specific` → ошибка «укажите имя контейнера».

## Шаг 2: Smoke checks (всегда, базовый набор)

Скрипт `scripts/quick-health.sh` запускает по одной команде с `--max-time 5` на сетевые операции:

- `docker ps --format '{{.Names}}\t{{.Status}}'` → выделить строки без `Up` → unhealthy/restarting
- `df -h /` → процент использования корня
- `free -m` → процент RAM (used / total)
- `restic snapshots --latest 1 --group-by tags --json` **на сервере** → возраст последнего снапшота
  **по каждой группе тегов**, статус — по худшей (свежий бэкап одного сервиса не прячет дыру другого)
- HTTP-checks для доменов из `inventory/shared/domains.md` папки инфры (первая колонка таблиц,
  строки с TLS «—» пропускаются; `401` — зелёный: закрыто авторизацией)

## Шаг 3: Full checks (если `MODE=full`)

Скрипт `scripts/full-health.sh` дополнительно:

- `docker stats --no-stream --format '{{.Name}}\t{{.MemUsage}}\t{{.CPUPerc}}'` → таблица per-container
- `docker inspect $(docker ps -q) | jq '.[].State.Health'` → healthcheck statuses
- TLS expiry для всех доменов из `inventory/shared/domains.md`
  (`echo | openssl s_client -servername $D -connect $D:443 2>/dev/null | openssl x509 -noout -enddate`)
- `nginx -t` → синтаксис конфигов
- (Если `BESZEL_URL` задан) последние 24ч агрегатов через Beszel API
- Drift: работающие контейнеры `docker ps`, не упомянутые в `inventory/hosts/<хост>/services.md`
  (односторонне; «описан, но не запущен» сверяет `inventory-scan`)

## Шаг 4: Specific checks (если `MODE=specific`)

Для `$TARGET`:
- `docker logs --tail=50 --timestamps $TARGET`
- `docker inspect $TARGET | jq '.[].State, .[].HostConfig.Memory, .[].NetworkSettings.Networks'`
- HTTP-check по домену (если есть в `inventory/shared/services.md`)
- `depends_on` контейнеры из compose (рекурсивно один уровень) — статус каждого

## Шаг 5: Анализ — классификация

Каждая проверка → один из трёх уровней по порогам:

| Метрика       | Green     | Yellow      | Red       |
|---------------|-----------|-------------|-----------|
| RAM           | <70%      | 70-90%      | >90%      |
| Disk /        | <70%      | 70-85%      | >85%      |
| Возраст бэкапа| <12 ч     | 12-36 ч     | >36 ч     |
| Контейнеры    | все Up    | 1 restarting| ≥1 exited |
| TLS expiry    | >30 дн.   | 14-30 дн.   | <14 дн.   |
| HTTP домена   | 2xx/3xx   | 4xx         | 5xx / нет |

## Шаг 6: Output

**`OUTPUT=human` (по умолчанию):**

```
=== Health Check (smoke) — 2026-04-25 09:15 ===
🟢 GREEN | docker: 23/23 running, RAM 45%, Disk 38%, бэкап 6 ч назад
🟡 YELLOW | TLS: example.com истекает через 13 дней
🔴 RED | Сервис myapp: restart loop (5 раз за 10 мин)

Рекомендации (1 red, 1 yellow):
- myapp: посмотри `docker logs --tail=200 myapp`, рассмотри restart с очисткой volumes (Yellow Zone)
- example.com: запусти `acme.sh --renew -d example.com` (Yellow Zone)
```

**`OUTPUT=json`:**

```json
{
  "timestamp": "2026-04-25T09:15:00Z",
  "mode": "smoke",
  "overall": "red",
  "checks": [
    {"name": "docker-ps", "status": "green", "value": "23/23 running"},
    {"name": "ram",       "status": "green", "value": "45%"},
    {"name": "disk",      "status": "green", "value": "38%"},
    {"name": "backup",    "status": "green", "value": "6h ago"},
    {"name": "tls-example.com", "status": "yellow", "value": "13d"},
    {"name": "container-myapp", "status": "red", "value": "restart loop"}
  ],
  "recommendations": [
    {"target": "myapp", "level": "red", "action": "inspect logs, consider restart"},
    {"target": "example.com", "level": "yellow", "action": "renew TLS"}
  ]
}
```

JSON удобен когда скилл вызывается из cron или хука.

# Failed Attempts

Граблей, на которые уже наступали:

- **`docker stats --filter` не работает в старых версиях Docker** на сервере (`Error: filter ... not supported`).
  Решение: явный список имён контейнеров или фильтрация через `grep` после запроса всех.
- **`curl` без `--max-time` висит при медленном/ушедшем сервере**, скилл застревает на 60+ секунд.
  Решение: всегда `curl --max-time 5` для health-проверок.
- **`restic snapshots` без `--json` парсится regexp'ом** — формат меняется между версиями.
  Решение: всегда `--json | jq -r '.[0].time'` для извлечения ISO-timestamp.
- **`openssl s_client` без `-servername`** возвращает default cert на multi-vhost nginx.
  Решение: `-servername $D -connect $D:443` обязательно.
- **Относительный путь `inventory/...` и проверка `RESTIC_REPOSITORY` в ЛОКАЛЬНОМ окружении** (до 2026-10-13):
  запуск из `sysadmin/` молча пропускал TLS и drift («не найден»), а бэкап объявлялся «не настроен»,
  хотя на сервере restic-скрипты в cron падали 15 дней подряд. `--latest 1 | .[0]` вдобавок показал бы
  свежий x-ui вместо мёртвого system. Решение: inventory — через `infra_root`, restic — на сервере,
  по группам тегов; «не настроен» — только если restic не найден вовсе, иначе «НЕ ПРОВЕРЕНО».

# Граничные случаи

- **Сервер недоступен (SSH timeout)** → отчёт «не удалось подключиться, проверь VPN/IP», без выдумывания
  состояний. Никогда не показывать «GREEN» при отсутствии данных.
- **Beszel/Kuma установлены, но недоступны (например, hub упал)** → fallback на прямые команды
  (Green Zone — всё равно read-only). В отчёте пометка «мониторинг-стек недоступен».
- **Неизвестный TARGET в `MODE=specific`** → ошибка «нет такого контейнера», список доступных через
  `docker ps --format '{{.Names}}'`.
- **`inventory/shared/domains.md` отсутствует** → пропустить HTTP- и TLS-checks с пометкой
  «inventory не найден». НЕ выдумывать список доменов.
- **`restic` на сервере не найден** → «restic не найден — см. setup-backups», не red.
- **restic есть, окружения в ssh-сессии нет, но cron вызывает скрипты с restic** → YELLOW «НЕ ПРОВЕРЕНО»
  со списком скриптов. Это не «бэкапа нет»: задай `RESTIC_ENV_FILE` или прочитай логи этих скриптов.

# Что НЕ покрывает этот скилл

См. `references/what-not-shown.md` — подробный разбор blind spots мониторинг-стека и этого скилла:

- **Application-level health** (внутренняя БД-репликация, очереди задач, business KPI) — это в самих сервисах
- **Long-term тренды (>24 ч)** — в Beszel/Kuma истории, не в моменте
- **Security-аудит** (открытые порты, CVE в образах) — это `audit-security`
- **Drift inventory ↔ реальность глубокий** (volumes, сети) — это `inventory-scan` (full mode частично пересекается)
- **Состояние GitHub-репо и pipeline'ов** — это область деплоя, см. `deploy-service`

# Идемпотентность

Скилл полностью read-only — запускается сколько угодно раз, побочных эффектов нет. Если скрипт
прервался посередине — просто запусти заново.

# Параметризация

Никаких хардкодных IP/доменов. Источники истины:

- IP/SSH-алиас сервера → `inventory/hosts/<server>.md`
- Список доменов → `inventory/shared/domains.md`
- Список ожидаемых сервисов → `inventory/hosts/<хост>/services.md` (legacy — `inventory/shared/services.md`)
- Restic-репозиторий → окружение на сервере или `RESTIC_ENV_FILE` (см. `inventory/shared/access.md`)

# Примеры вызовов

```bash
# Утренний обход — быстрый smoke
bash .claude/skills/health-check/scripts/quick-health.sh

# Полная проверка раз в день/после деплоя
MODE=full bash .claude/skills/health-check/scripts/full-health.sh

# Расследование одного сервиса
MODE=specific TARGET=<container-name> bash .claude/skills/health-check/scripts/quick-health.sh

# Для cron / интеграции — JSON
OUTPUT=json bash .claude/skills/health-check/scripts/quick-health.sh
```