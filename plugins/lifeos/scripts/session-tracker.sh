#!/bin/bash
# Hook: UserPromptSubmit → записывает timestamp в лог сессии
# Вход: JSON из stdin с полем session_id
# Выход: <vault>/Resources/00 Журнал AI/logs/claude-session-{session_id}.log
#
# Оптимизирован для скорости: без jq, без pipe, минимум fork.
# При параллельных сессиях каждый вызов должен завершаться за <50мс.

# Читаем stdin в переменную (таймаут 1сек на случай пустого stdin)
read -t 1 INPUT || true

# Извлекаем session_id чистым bash (без grep/sed/jq)
if [[ "$INPUT" =~ \"session_id\"[[:space:]]*:[[:space:]]*\"([a-f0-9-]+)\" ]]; then
  SESSION_ID="${BASH_REMATCH[1]}"
else
  exit 0
fi

# Каталог логов — в home, НЕ в проекте. Плагин user-scope: хук срабатывает в любом
# проекте, поэтому лог не привязан к ${CLAUDE_PROJECT_DIR} (иначе плодил бы папки в
# случайных репозиториях). Канонический путь ~/.lifeos/logs, переопределяется LIFEOS_HOME.
LOG_DIR="${LIFEOS_HOME:-$HOME/.lifeos}/logs"
mkdir -p "$LOG_DIR" 2>/dev/null

# Запись timestamp — append атомарен для коротких строк на POSIX
printf '%s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" >> "$LOG_DIR/claude-session-${SESSION_ID}.log"
