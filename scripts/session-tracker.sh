#!/bin/bash
# Хук: UserPromptSubmit — записывает timestamp при каждом промпте
# Вход: JSON из stdin с полем session_id
# Выход: дописывает в /tmp/claude-session-{session_id}.log
#
# Часть инфраструктуры трекинга сессий LifeOS.
# Настраивается в .claude/settings.json как хук UserPromptSubmit.

INPUT=$(cat)
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)

if [ -z "$SESSION_ID" ]; then
  # fallback: парсинг без jq
  SESSION_ID=$(echo "$INPUT" | grep -o '"session_id" *: *"[^"]*"' | head -1 | sed 's/.*: *"//;s/"//')
fi

if [ -z "$SESSION_ID" ]; then
  exit 0
fi

LOGFILE="/tmp/claude-session-${SESSION_ID}.log"
# Формат: ISO 8601 с часовым поясом
# Пример: 2026-03-21T08:14:59+0800
echo "$(date '+%Y-%m-%dT%H:%M:%S%z')" >> "$LOGFILE"
exit 0
