---
aliases:
  - Удалённый доступ через Telegram
  - LifeOS Pro Этап 1
---

# Удалённый доступ через Telegram и выделенный сервер

Полный воспроизводимый гайд: как получить доступ к LifeOS с телефона через Telegram, пока система работает на всегда-включённом выделенном сервере. Этап 1 версии Pro — см. [[LifeOS Pro/README|LifeOS Pro]].

Всё обезличено переменными (таблица плейсхолдеров — в [[LifeOS Pro/README|LifeOS Pro]]).

## 1. Зачем это

LifeOS базового уровня живёт на одном компьютере: открыл ноутбук — работаешь с системой, закрыл — недоступна.

Этот этап снимает ограничение. «Движок» системы (Claude Code + vault) переезжает на отдельный всегда-включённый компьютер. Доступ к нему — через Telegram-бота: пишешь боту с телефона обычное сообщение, на сервере его обрабатывает та же сессия Claude Code, что и при работе за столом, и присылает ответ обратно в чат.

Что это даёт:
- Управление системой с телефона, без ноутбука — из машины, в дороге, в очереди.
- Голосовой ввод: надиктовал боту голосовое — система расшифровала и выполнила.
- Долгие операции идут на сервере и не зависят от того, открыт ли ноутбук.
- Единая точка входа: один бот — вся система (заметки, задачи, проекты, поиск, ресёрч).

## 2. Архитектура

```
   Телефон (Telegram)
          │  сообщение боту
          ▼
   Telegram Bot API
          │  long-poll
          ▼
 ┌─────────────────────────────────────────────┐
 │  Выделенный сервер <remote-host>             │
 │                                              │
 │   tmux-сессия (переживает отключение SSH)     │
 │     └─ Claude Code  --channels                │
 │          └─ плагин telegram (MCP-сервер)      │
 │               слушает Bot API,                │
 │               инжектит входящие в сессию       │
 │                                              │
 │   LaunchAgent — автозапуск при загрузке        │
 │   Watchdog — авто-восстановление при сбое      │
 └─────────────────────────────────────────────┘
          │  vault
          ▼
   Файлы LifeOS (<vault-path>)
```

Ключевые компоненты:
- **Плагин Telegram Channels** для Claude Code — официальный плагин Anthropic. Поднимает локальный MCP-сервер, который слушает Telegram Bot API и пробрасывает сообщения в живую сессию Claude Code.
- **Постоянная сессия** — Claude Code запущен в `tmux`, сессия не умирает при разрыве SSH.
- **Allowlist по Telegram ID** — бот отвечает только владельцу, посторонним молчит.
- **Автозапуск** — сессия поднимается при загрузке сервера (LaunchAgent на macOS / systemd на Linux).
- **Watchdog** — отдельный сторож, который замечает скрытые падения и перезапускает.

## 3. Что понадобится

| Компонент | Назначение |
|---|---|
| Выделенный сервер | Всегда включён, headless допустимо. Подойдёт любой always-on компьютер: мини-ПК, домашний сервер, старый ноутбук |
| Удалённый доступ к серверу | SSH. Желательно — стабильный адрес (mesh-VPN вроде Tailscale, либо статический хост) |
| Claude Code | Установлен на сервере, авторизован действующей подпиской |
| Аккаунт Telegram | Для создания бота и общения с ним |
| Среда исполнения `bun` | Нужен плагину для MCP-сервера. **Без `bun` плагин не стартует — бот молчит** |

Плагин Channels — research preview: протокол может меняться. Версии `bun`, плагина и Claude Code стоит зафиксировать и не обновлять автоматически.

## 4. Шаг 1 — Telegram-бот

1. В Telegram открыть **@BotFather** → команда `/newbot` → задать имя и username бота.
2. BotFather выдаёт **токен** — это `<bot-token>`. Хранить как секрет: токен = полный контроль над ботом.
3. Узнать свой числовой Telegram user ID (`<owner-id>`) — например, через бота **@userinfobot**. Понадобится для allowlist.

## 5. Шаг 2 — Подготовка выделенного сервера

Сервер должен быть всегда доступен и не «засыпать».

**macOS:**

```bash
# Запретить сон системы и парковку дисков; авто-рестарт при сбое питания
sudo pmset -a sleep 0 disksleep 0 autorestart 1 womp 1
```

- **Remote Login (SSH)** — включить в System Settings → General → Sharing. Аутентификация — по SSH-ключу.
- **Сетевой доступ** — стабильный путь к серверу. Удобный вариант — mesh-VPN (например, Tailscale): сервер получает постоянный адрес, доступный из любой сети.
- **Headless-нюанс (важно для macOS):** login Keychain блокируется при простое системы. Сервисы, читающие учётные данные (включая авторизацию Claude Code), при заблокированном Keychain зависают. После перезагрузки сервера первый SSH-вход **по паролю** разблокирует систему и Keychain. Это разовое действие после каждого ребута.
- Проверять `pmset -g` после обновлений macOS — апдейты сбрасывают настройки сна.

**Linux:** аналогично — отключить suspend, включить SSH, обеспечить сетевую доступность. Автозапуск (шаг 7) делается через `systemd --user` юнит вместо LaunchAgent.

## 6. Шаг 3 — Установка плагина Telegram

На сервере, в Claude Code:

```
/plugin marketplace add anthropics/claude-plugins-official
/plugin install telegram@claude-plugins-official
```

Плагин ставится в user scope (доступен во всех проектах на этой машине). Среда `bun` должна быть установлена заранее — плагин запускает на ней свой MCP-сервер.

## 7. Шаг 4 — Конфигурация канала

Конфигурация канала живёт в `<claude-home>/channels/telegram/`.

**Файл `.env`** — токен бота:

```
TELEGRAM_BOT_TOKEN=<bot-token>
```

Права доступа — только владельцу:

```bash
chmod 600 <claude-home>/channels/telegram/.env
```

**Файл `access.json`** — политика доступа. Ключевая защита: бот реагирует только на сообщения из allowlist.

```json
{
  "dmPolicy": "allowlist",
  "allowFrom": ["<owner-id>"],
  "groups": {},
  "pending": {}
}
```

- `dmPolicy: "allowlist"` — личные сообщения принимаются только от ID из `allowFrom`. Все прочие игнорируются.
- `allowFrom` — список разрешённых Telegram user ID. Для персональной системы — один свой ID.

## 8. Шаг 5 — Первый запуск и проверка

Из каталога vault на сервере:

```bash
cd <vault-path>
claude --channels plugin:telegram@claude-plugins-official
```

В выводе должно появиться `Listening for channel messages from: plugin:telegram@...`. Написать боту в Telegram любое сообщение — должен прийти ответ. Если посторонний напишет боту — реакции быть не должно (сработал allowlist).

На этом базовый удалённый доступ работает. Шаги 6–8 делают его надёжным и автономным.

## 9. Шаг 6 — Постоянная сессия (tmux)

Сессия из шага 5 умрёт при разрыве SSH. Сервер headless — значит сессия должна жить независимо от подключений. Решение — `tmux`.

Нюанс: Claude Code — это TUI-приложение, ему нужен псевдотерминал (PTY). Под `tmux` PTY есть; если запускать из не-интерактивного контекста (LaunchAgent) — PTY эмулируется утилитой `script`.

Скрипт-обёртка `start-channel.sh` создаёт сессию идемпотентно (повторный запуск не плодит дубль):

```bash
#!/bin/bash
# Создаёт tmux-сессию с Claude Code + Telegram-каналом.
# SHELL=bash (не zsh) — чтобы не цепляться за пользовательские
# профили, которые в контексте LaunchAgent могут висеть.
set -u
export PATH="/opt/homebrew/bin:/opt/homebrew/sbin:/usr/bin:/bin:/usr/sbin:/sbin"
export SHELL=/bin/bash

VAULT="<vault-path>"
SESSION="lifeos-pa"
LOG="/tmp/lifeos-channel.pane.log"

if tmux has-session -t "$SESSION" 2>/dev/null; then
    echo "$(date '+%F %T'): сессия $SESSION уже есть, выходим" >&2
    exit 0
fi

tmux new-session -d -s "$SESSION" -c "$VAULT" \
    "/usr/bin/script -q /dev/null claude --channels plugin:telegram@claude-plugins-official"
tmux set-option -t "$SESSION" remain-on-exit on
tmux pipe-pane -t "$SESSION" -o "cat >> $LOG"

echo "$(date '+%F %T'): сессия $SESSION запущена" >&2
```

Ручной перезапуск сессии (если понадобится):

```bash
ssh <remote-host> 'tmux kill-session -t lifeos-pa 2>/dev/null; \
  tmux new -d -s lifeos-pa -c "<vault-path>"; \
  tmux send-keys -t lifeos-pa \
    "claude --channels plugin:telegram@claude-plugins-official" Enter'
```

## 10. Шаг 7 — Автозапуск при загрузке сервера

Чтобы после перезагрузки сервера бот поднимался сам.

**macOS — LaunchAgent** `~/Library/LaunchAgents/lifeos.tg-channel.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>lifeos.tg-channel</string>
    <key>ProgramArguments</key>
    <array>
        <string>/Users/<user>/bin/start-channel.sh</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <dict><key>SuccessfulExit</key><false/></dict>
    <key>ThrottleInterval</key>
    <integer>30</integer>
    <key>StandardOutPath</key>
    <string>/tmp/lifeos.tg-channel.out</string>
    <key>StandardErrorPath</key>
    <string>/tmp/lifeos.tg-channel.err</string>
</dict>
</plist>
```

Загрузить: `launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/lifeos.tg-channel.plist`.

**Headless-оговорка:** автозапуск сразу при загрузке упирается в блокировку Keychain (см. шаг 5). Пока эта проблема не решена (например, через сервисный токен менеджера секретов, разблокирующий Keychain в обёртке), роль автоподъёма берёт на себя watchdog (шаг 8) — он поднимет сессию на первом же тике после ребута.

## 11. Шаг 8 — Watchdog (надёжность)

Плагин Channels — research preview. Известный режим отказа: MCP-сервер плагина (процесс `bun`) внутри живой сессии тихо падает, а родительский Claude Code этого **не замечает** и не перезапускает. Внешне сессия жива, но бот молчит.

Watchdog — отдельный сторож, который раз в 5 минут проверяет три признака жизни:

1. tmux-сессия существует;
2. процесс `claude --channels` запущен;
3. у процесса `claude` есть хотя бы один дочерний процесс (= MCP-сервер плагина жив).

При провале любого пункта — перезапуск сессии. Защита от циклического перезапуска: cooldown между рестартами и atomic-лок против параллельных запусков.

Скрипт `channel-watchdog.sh`:

```bash
#!/bin/bash
# Поддерживает живой tmux-сессию с Claude Code + Telegram-каналом.
set -uo pipefail
export PATH="/opt/homebrew/bin:/opt/homebrew/sbin:/usr/bin:/bin:/usr/sbin:/sbin"

SESSION="lifeos-pa"
WORKDIR="<vault-path>"
START_CMD='claude --channels plugin:telegram@claude-plugins-official'
LOG="$HOME/Library/Logs/lifeos-channel-watchdog.log"
LOCKDIR="/tmp/lifeos-channel-watchdog.lockdir"
LOCK_TTL_SEC=600
COOLDOWN_FILE="$HOME/.cache/lifeos-channel-watchdog/last_restart"
COOLDOWN_SEC=60

mkdir -p "$(dirname "$COOLDOWN_FILE")" "$(dirname "$LOG")"
log() { echo "$(date '+%Y-%m-%d %H:%M:%S %Z') $*" >> "$LOG"; }

# Ротация лога >1MB
if [[ -f "$LOG" ]] && [[ $(stat -f%z "$LOG" 2>/dev/null || echo 0) -gt 1048576 ]]; then
  tail -500 "$LOG" > "${LOG}.tmp" && mv "${LOG}.tmp" "$LOG"
fi

# Atomic-лок через mkdir + TTL для сирот
if ! mkdir "$LOCKDIR" 2>/dev/null; then
  age=$(( $(date +%s) - $(stat -f%m "$LOCKDIR" 2>/dev/null || date +%s) ))
  if (( age > LOCK_TTL_SEC )); then rmdir "$LOCKDIR" 2>/dev/null; mkdir "$LOCKDIR" 2>/dev/null || exit 0
  else exit 0; fi
fi
trap 'rmdir "$LOCKDIR" 2>/dev/null' EXIT

# Cooldown
now=$(date +%s)
if [[ -f "$COOLDOWN_FILE" ]]; then
  diff=$(( now - $(cat "$COOLDOWN_FILE" 2>/dev/null || echo 0) ))
  (( diff < COOLDOWN_SEC )) && exit 0
fi

needs_restart=""; reason=""
if ! tmux has-session -t "$SESSION" 2>/dev/null; then
  needs_restart=1; reason="нет tmux-сессии"
fi
claude_pid=""
if [[ -z "$needs_restart" ]]; then
  claude_pid=$(pgrep -f "claude --channels plugin:telegram" | head -1)
  [[ -z "$claude_pid" ]] && { needs_restart=1; reason="нет процесса claude --channels"; }
fi
if [[ -z "$needs_restart" && -n "$claude_pid" ]]; then
  [[ -z "$(pgrep -P "$claude_pid" 2>/dev/null | head -1)" ]] && \
    { needs_restart=1; reason="у claude нет дочерних — MCP-сервер плагина упал"; }
fi
[[ -z "$needs_restart" ]] && exit 0

log "[fail] $reason"
tmux kill-session -t "$SESSION" 2>/dev/null; sleep 1
tmux new -d -s "$SESSION" -c "$WORKDIR"; sleep 1
tmux send-keys -t "$SESSION" "$START_CMD" Enter
echo "$now" > "$COOLDOWN_FILE"

sleep 10
new_pid=$(pgrep -f "claude --channels plugin:telegram" | head -1)
[[ -n "$new_pid" ]] && log "[restart] success — claude PID $new_pid" \
                     || log "[restart] FAILED — повтор на следующем тике"
```

LaunchAgent watchdog `~/Library/LaunchAgents/lifeos.tg-channel-watchdog.plist` — запуск раз в 300 секунд:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>lifeos.tg-channel-watchdog</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>/Users/<user>/bin/channel-watchdog.sh</string>
    </array>
    <key>StartInterval</key>
    <integer>300</integer>
    <key>RunAtLoad</key>
    <true/>
    <key>StandardOutPath</key>
    <string>/Users/<user>/Library/Logs/lifeos-channel-watchdog.stdout.log</string>
    <key>StandardErrorPath</key>
    <string>/Users/<user>/Library/Logs/lifeos-channel-watchdog.stderr.log</string>
</dict>
</plist>
```

Загрузить: `launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/lifeos.tg-channel-watchdog.plist`.

Проверить watchdog принудительно — убить процесс `bun` (дочерний у `claude`) и подождать до 5 минут: в логе должны появиться записи `[fail]` и `[restart] success`.

## 12. Шаг 9 — Модель безопасности (permissions)

Бот выполняет инструменты Claude Code (чтение/запись файлов, команды). В режиме канала запрос на подтверждение прилетает в Telegram. Цель — баланс: рутина без вопросов, критичное спрашивает, катастрофичное запрещено.

**Осознанный риск.** Связка «широкий доступ к данным + входы из внешнего канала + автоматическое выполнение» (известна как Lethal Trifecta) — это повышенный риск. Минимизируется слоями:

1. **Allowlist канала** (шаг 7) — бот реагирует только на владельца. Первый и главный барьер.
2. **Режим разрешений `default`** — всё, что не в allowlist, по-прежнему требует подтверждения. Незнакомое и критичное → вопрос в Telegram.
3. **Продуманный allowlist рутины** — типовые безопасные операции (поиск по vault, чтение, диагностика) внесены в allowlist и не прерывают работу.
4. **Denylist** — катастрофичные операции (эскалация привилегий, рекурсивное удаление) запрещены жёстко, даже без вопроса.

Этот баланс настраивается в `permissions` файла настроек Claude Code (`allow` / `ask` / `deny`). Принцип — минимум прав: широкие разрешения только там, где операция действительно read-only и безопасна; всё с побочными эффектами — узкими паттернами или под вопросом.

## 13. Эксплуатация

**Проверить, что бот жив:**

```bash
ssh <remote-host> 'tmux has-session -t lifeos-pa && echo сессия-есть; \
  pgrep -f "claude --channels"'
```

**Посмотреть лог watchdog (история падений и рестартов):**

```bash
ssh <remote-host> 'tail -30 ~/Library/Logs/lifeos-channel-watchdog.log'
```

**Ручной перезапуск** — командой из шага 6.

**После перезагрузки сервера:** первый SSH-вход по паролю (разблокировать Keychain) → дальше watchdog поднимет сессию сам в течение ≤5 минут.

## 14. Известные ограничения

1. **Нет offline-очереди.** Если процесс канала лежит, сообщения, отправленные за время простоя, теряются — это свойство research preview.
2. **Cold-start после ребута ≤ 5 минут.** Между загрузкой сервера и первым тиком watchdog бот молчит.
3. **Headless-секреты (macOS).** Блокировка login Keychain при простое — главный блокер полностью автоматического автозапуска. Обходится первым SSH-входом после ребута.
4. **Research preview дрейфует.** Anthropic может менять протокол Channels. Версии `bun`, плагина и Claude Code держать зафиксированными.
5. **Watchdog проверяет наличие, не здоровье.** Если MCP-сервер запущен, но завис в цикле — watchdog не заметит.

## 15. Чек-лист воспроизведения

- [ ] Бот создан в @BotFather, токен сохранён, свой Telegram ID известен
- [ ] Выделенный сервер: сон отключён, SSH включён, сетевой доступ стабилен
- [ ] `bun` установлен
- [ ] Плагин `telegram@claude-plugins-official` установлен
- [ ] `.env` с токеном создан, права `600`
- [ ] `access.json` с `dmPolicy: allowlist` и своим ID
- [ ] Первый запуск: бот отвечает владельцу, посторонним молчит
- [ ] Постоянная сессия в `tmux` через скрипт-обёртку
- [ ] LaunchAgent автозапуска загружен
- [ ] Watchdog: скрипт + LaunchAgent загружены, принудительная проверка пройдена
- [ ] Permissions: режим `default` + allowlist рутины + denylist катастрофичного
