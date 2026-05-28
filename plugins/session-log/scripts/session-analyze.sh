#!/bin/bash
# Анализатор лога сессии Claude Code.
#
# С 2026-04-15 это тонкая обёртка над scripts/session_analyze.py.
# Логика и документация живут в Python-скрипте; здесь только запуск,
# чтобы не ломать вызовы вида `bash scripts/session-analyze.sh` из
# .claude/commands/session-log.md и других потребителей.
#
# Почему переписано: см. [[Agents/Инфраструктура/Session Logger/Backlog/L1 Python rewrite session-analyze]].
# Старая bash-версия запускала python3 на каждый timestamp, что давало
# O(N×M) стартов интерпретатора и 12+ секунд overhead на закрытие сессии.

exec python3 "$(dirname "$0")/session_analyze.py" "$@"
