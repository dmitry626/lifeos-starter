# lifeos — плагин generic-навыков LifeOS

Контейнер переносимых навыков LifeOS. Сейчас содержит `/lifeos:session-log` — логирование итогов работы с Claude Code: журнал сессий + (опционально) фактические тайм-блоки в Google Calendar. Логи хранятся в `~/.lifeos/` и **не привязаны к проекту** — плагин ставится в User scope и работает в любой папке.

## Что внутри

- `commands/session-log.md` — навык `/lifeos:session-log`.
- `hooks/hooks.json` — хук `UserPromptSubmit`, пишет таймстамп каждого промпта в `~/.lifeos/logs/claude-session-{id}.log` (нужно для расчёта блоков работы).
- `scripts/` — `session-tracker.sh` (хук), `session-analyze.sh` + `session_analyze.py` (метрики), `session_log_append.py` (атомарная запись журнала).

## Установка

```
/plugin marketplace add git@github.com:dmitry626/lifeos-starter.git
/plugin install lifeos@lifeos
/reload-plugins
```

Выбрать **User scope** — тогда навык и хук доступны во всех проектах.

## Конфигурация (env)

Плагин работает из коробки (журнал-онли). Персональные значения задаются через env в `~/.claude/settings.json` → блок `"env"`:

| Переменная | Дефолт | Назначение |
|---|---|---|
| `LIFEOS_HOME` | `~/.lifeos` | База для логов (`logs/`). Логи технические, project-independent. |
| `SESSION_LOG_JOURNAL_DIR` | `~/.lifeos/journal` | Куда писать журнал `YYYY-WNN.md`. Кто держит журнал в Obsidian-vault — указывает vault-путь (журнал виден в Obsidian и связан с заметками). |
| `SESSION_LOG_CALENDAR_ID` | (пусто) | Google Calendar id для тайм-блоков. **Пусто → календарь пропускается, пишется только журнал.** |
| `SESSION_LOG_GWS` | `gws` | Команда gws CLI (например `gws-yz`, если несколько аккаунтов). |

Пример:
```json
{
  "env": {
    "SESSION_LOG_CALENDAR_ID": "c_xxxxx@group.calendar.google.com",
    "SESSION_LOG_GWS": "gws-yz"
  }
}
```

## Тайм-блокинг в календаре (опционально)

Если задан `SESSION_LOG_CALENDAR_ID`, `/session-log` пишет фактические блоки работы (с `✓`) в выделенный календарь. Создай отдельный календарь (например «Планировщик») в своём Google-аккаунте, возьми его `calendarId`, положи в env. Тот же календарь можно вести и для плана — резервировать блоки наперёд (без `✓`) и сверять план с фактом.

## Данные

- `~/.lifeos/logs/` — сырые логи промптов + lock (технические, не для чтения).
- `~/.lifeos/journal/YYYY-WNN.md` — журнал сессий (по ISO-неделям).
