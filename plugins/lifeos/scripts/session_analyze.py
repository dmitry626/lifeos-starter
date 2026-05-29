#!/usr/bin/env python3
"""
Анализатор лога сессии Claude Code.

Использование:
    session_analyze.py [logfile-или-session-id]

Аргумент:
    - абсолютный путь к claude-session-*.log → анализируется этот файл;
    - session-id (UUID без префиксов) → резолвится в logs_dir/claude-session-<id>.log;
    - без аргумента → резолв по приоритету (см. pick_logfile):
        (a) явный аргумент,
        (b) pointer текущей вкладки current-session-<TERM_SESSION_ID>,
        (c) env CLAUDE_CODE_SESSION_ID,
        (d) самый свежий лог по mtime (последний резерв).

Logs directory резолвится тем же способом, что hook session-tracker.sh:
    1) ENV CLAUDE_PROJECT_DIR (стандарт Claude Code) → <root>/Resources/00 Журнал AI/logs
    2) Fallback: положение скрипта (<vault>/scripts/session_analyze.py)
       → parent.parent/Resources/00 Журнал AI/logs
Без env-переменных типа CLAUDE_SESSION_LOGS_DIR (не нужны — vault root
уже стандартизирован).

Вывод (stdout): key=value метрики сессии. Интерфейс совместим с прежним
session-analyze.sh (bash-версия, 2026-03). Выход разобран навыком
/session-log из .claude/commands/session-log.md.

Формат timestamp в логе: `2026-03-21T08:14:59+0800` (ISO 8601 с TZ offset).
Обратная совместимость: `2026-03-21T08:14:59` (без TZ) тоже парсится — в
этом случае используется локальный TZ системы.

История:
    2026-04-15: переписан с bash на Python (бэклог L1).
        Причина: функция to_epoch() в bash-версии запускала отдельный процесс
        python3 на каждый timestamp, что давало O(N×M) python-стартов при
        детекции параллельных сессий. На 27 накопленных /tmp логах — 12+ сек
        overhead на короткую сессию. Python-версия делает всё in-memory в
        одном процессе, время выполнения <0.5 сек независимо от накопления.
    2026-05-10: исправлен путь к логам — рассинхрон с hook session-tracker.sh.
        Hook писал в <vault>/Resources/00 Журнал AI/logs/, анализатор читал
        из /tmp/. Теперь оба используют CLAUDE_PROJECT_DIR + fallback на
        Path(__file__).parent.parent. Добавлена резолюция session-id (UUID)
        в путь файла, чтобы вызов с явным id работал.
    2026-05-29: исправлен mis-attribution при параллельных вкладках.
        Раньше вызов без аргумента брал самый свежий лог по mtime среди ВСЕХ
        сессий → при параллельных Claude Code (ферма + основная) выбирал чужую
        сессию, и работа одной сессии попадала в журнал/календарь другой.
        Теперь приоритет резолва: (a) аргумент, (b) pointer вкладки
        current-session-<TERM_SESSION_ID> (хук пишет live id, переживает
        компакцию), (c) env CLAUDE_CODE_SESSION_ID, (d) mtime (резерв).
"""

from __future__ import annotations

import os
import re
import sys
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path

PAUSE_THRESHOLD_SEC = 900  # 15 минут

TZ_LOCATIONS: dict[str, str] = {
    "+0800": "Бали (UTC+8)",
    "+0500": "Челябинск (UTC+5)",
    "+0300": "Москва (UTC+3)",
    "+0700": "Бангкок (UTC+7)",
    "+0900": "Токио (UTC+9)",
    "+0000": "UTC",
}

TS_RE = re.compile(r"^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})([+-]\d{4})?$")


@dataclass
class ParsedTimestamp:
    raw: str
    dt: datetime
    epoch: int
    tz_offset: str  # "+0800" или "" если без TZ


def parse_timestamp(raw: str) -> ParsedTimestamp | None:
    raw = raw.strip()
    if not raw:
        return None
    m = TS_RE.match(raw)
    if not m:
        return None
    base = m.group(1)
    tz = m.group(2) or ""
    dt = datetime.strptime(base, "%Y-%m-%dT%H:%M:%S")
    if tz:
        sign = 1 if tz[0] == "+" else -1
        hh = int(tz[1:3])
        mm = int(tz[3:5])
        dt = dt.replace(tzinfo=timezone.utc)
        # подменить offset на нужный без изменения wall clock
        from datetime import timedelta
        dt = dt.replace(tzinfo=timezone(timedelta(hours=sign * hh, minutes=sign * mm)))
    else:
        # Локальный TZ — эквивалент bash-версии `dt.astimezone()`
        dt = dt.astimezone()
    return ParsedTimestamp(raw=raw, dt=dt, epoch=int(dt.timestamp()), tz_offset=tz)


def read_log(path: str) -> list[ParsedTimestamp]:
    """Читает файл лога целиком, парсит timestamps. Невалидные строки пропускает."""
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            lines = f.readlines()
    except OSError:
        return []
    parsed: list[ParsedTimestamp] = []
    for line in lines:
        p = parse_timestamp(line)
        if p is not None:
            parsed.append(p)
    return parsed


def format_duration(seconds: int) -> str:
    if seconds <= 0:
        return "<1мин"
    hours = seconds // 3600
    minutes = (seconds % 3600) // 60
    if hours > 0:
        return f"{hours}ч {minutes}мин"
    return f"{minutes}мин"


def tz_to_location(offset: str) -> str:
    if offset in TZ_LOCATIONS:
        return TZ_LOCATIONS[offset]
    return f"UTC{offset}"


SESSION_ID_RE = re.compile(r"^[a-f0-9-]{8,}$")


def vault_root() -> Path:
    """Резолвит корень vault. Синхронизировано с hook session-tracker.sh.

    1) CLAUDE_PROJECT_DIR — стандартная переменная Claude Code.
    2) Fallback — положение скрипта: <vault>/scripts/session_analyze.py.
    """
    cp = os.environ.get("CLAUDE_PROJECT_DIR")
    if cp:
        return Path(cp)
    return Path(__file__).resolve().parent.parent


def logs_dir() -> Path:
    # Логи — в home (~/.lifeos/logs), НЕ в проекте: плагин user-scope, хук пишет
    # из любого проекта. Канонический путь, переопределяется env LIFEOS_HOME.
    home = os.environ.get("LIFEOS_HOME") or os.path.join(os.path.expanduser("~"), ".lifeos")
    return Path(home) / "logs"


def _logfile_for_id(session_id: str) -> str | None:
    """Путь к логу по session-id, если файл существует."""
    if not session_id or not SESSION_ID_RE.match(session_id):
        return None
    candidate = logs_dir() / f"claude-session-{session_id}.log"
    return str(candidate) if candidate.is_file() else None


def _pointer_session_id() -> str | None:
    """Live session_id из pointer'а текущей вкладки терминала.

    Хук session-tracker.sh при каждом промпте пишет
    logs_dir()/current-session-<TERM_SESSION_ID> = live session_id. Ключ —
    по вкладке терминала: стабилен, переживает компакцию (после которой
    session_id меняется), не перезаписывается другими параллельными вкладками.
    Это надёжный якорь против mis-attribution «самый свежий по mtime».
    """
    term = os.environ.get("TERM_SESSION_ID")
    if not term:
        return None
    ptr = logs_dir() / f"current-session-{term}"
    try:
        sid = ptr.read_text(encoding="utf-8").strip()
    except OSError:
        return None
    return sid or None


def pick_logfile(arg: str | None) -> str | None:
    # (a) Явный аргумент — высший приоритет.
    if arg:
        # Явный путь к существующему файлу
        if os.path.isfile(arg):
            return arg
        # Session-id (UUID) → резолвится в путь
        resolved = _logfile_for_id(arg)
        if resolved:
            return resolved
        return None

    # (b) Pointer вкладки терминала (current-session-<TERM_SESSION_ID>).
    #     Самый надёжный live-якорь: переживает компакцию, не путается с
    #     параллельными вкладками. Используем только если лог реально существует.
    ptr_id = _pointer_session_id()
    if ptr_id:
        resolved = _logfile_for_id(ptr_id)
        if resolved:
            return resolved

    # (c) ENV CLAUDE_CODE_SESSION_ID — может протухнуть после компакции, но
    #     лучше mtime-угадывания. Только если лог существует.
    env_id = os.environ.get("CLAUDE_CODE_SESSION_ID")
    if env_id:
        resolved = _logfile_for_id(env_id)
        if resolved:
            return resolved

    # (d) Последний резерв — самый свежий лог в logs_dir по mtime.
    #     Ненадёжно при параллельных сессиях; срабатывает лишь когда нет ни
    #     pointer'а, ни валидного env (headless без TERM_SESSION_ID и т.п.).
    candidates = sorted(
        logs_dir().glob("claude-session-*.log"),
        key=lambda p: p.stat().st_mtime,
        reverse=True,
    )
    return str(candidates[0]) if candidates else None


def all_logfiles() -> list[str]:
    """Все логи в logs_dir — для детекции параллельных сессий."""
    return [str(p) for p in logs_dir().glob("claude-session-*.log")]


def session_id_from_path(path: str) -> str:
    base = os.path.basename(path)
    if base.startswith("claude-session-") and base.endswith(".log"):
        return base[len("claude-session-") : -len(".log")]
    return base


def main(argv: list[str]) -> int:
    arg = argv[1] if len(argv) > 1 else None
    logfile = pick_logfile(arg)
    if not logfile:
        print("error=no_log_file")
        return 1

    current = read_log(logfile)
    if not current:
        print("error=empty_log")
        return 1

    first = current[0]
    last = current[-1]
    total_seconds = last.epoch - first.epoch

    # --- Active / pause ---
    active_seconds = 0
    pause_seconds = 0
    pause_count = 0
    tz_offsets: list[str] = []
    if first.tz_offset and first.tz_offset not in tz_offsets:
        tz_offsets.append(first.tz_offset)

    prev_epoch = first.epoch
    for i in range(1, len(current)):
        cur = current[i]
        if cur.tz_offset and cur.tz_offset not in tz_offsets:
            tz_offsets.append(cur.tz_offset)
        diff = cur.epoch - prev_epoch
        if diff > PAUSE_THRESHOLD_SEC:
            pause_seconds += diff
            pause_count += 1
        else:
            active_seconds += diff
        prev_epoch = cur.epoch

    # --- Параллельные сессии ---
    # Оптимизация: читаем каждый другой лог один раз, проверяем пересечение
    # bounding box [first.epoch, last.epoch] с [other_first, other_last] перед
    # более дорогой проверкой per-timestamp overlap.
    parallel_ids: list[str] = []
    parallel_prompts = 0
    for other in all_logfiles():
        if os.path.abspath(other) == os.path.abspath(logfile):
            continue
        other_ts = read_log(other)
        if not other_ts:
            continue
        # bounding box check
        if other_ts[-1].epoch < first.epoch or other_ts[0].epoch > last.epoch:
            continue
        overlap = sum(
            1
            for t in other_ts
            if first.epoch <= t.epoch <= last.epoch
        )
        if overlap > 0:
            parallel_ids.append(session_id_from_path(other))
            parallel_prompts += overlap

    # --- Локация ---
    if tz_offsets:
        tz_list = ", ".join(tz_to_location(tz) for tz in tz_offsets)
    else:
        # Legacy без TZ — использовать системный
        import time as _time
        offset = _time.strftime("%z")
        tz_list = f"{tz_to_location(offset)} (системный)" if offset else "UTC (системный)"

    # --- Вывод ---
    sid = session_id_from_path(logfile)
    print(f"session_id={sid}")
    print(f"session_start={first.raw}")
    print(f"session_end={last.raw}")
    print(f"prompt_count={len(current)}")
    print(f"total_duration={format_duration(total_seconds)}")
    print(f"active_time={format_duration(active_seconds)}")
    print(f"pause_time={format_duration(pause_seconds)}")
    print(f"pause_count={pause_count}")
    print(f"location={tz_list}")
    if len(tz_offsets) > 1:
        print("tz_changed=true")
    print(f"parallel_sessions={len(parallel_ids)}")
    if parallel_ids:
        print(f"parallel_prompts={parallel_prompts}")
        print(f"parallel_ids={','.join(parallel_ids)}")
    print(f"logfile={logfile}")

    # --- Детерминированные поля для записи (считаются здесь, без round-trip к модели) ---
    from datetime import timedelta
    now = datetime.now().astimezone()
    iso_week = now.strftime("%G-W%V")              # текущая ISO-неделя → имя файла журнала
    monday = now.date() - timedelta(days=now.weekday())
    sunday = monday + timedelta(days=6)
    start_week = first.dt.strftime("%G-W%V")       # ISO-неделя начала сессии (edge-case смены недели)
    host = os.uname().nodename.split(".")[0]       # короткий hostname (как hostname -s)
    print(f"now={now.strftime('%Y-%m-%d %H:%M %z')}")
    print(f"iso_week={iso_week}")
    print(f"week_file={iso_week}.md")
    print(f"week_range={monday.isoformat()} (Пн) — {sunday.isoformat()} (Вс)")
    print(f"start_week={start_week}")
    print(f"host={host}")

    # --- Блоки работы для тайм-блокинга (детерминированно: паузы >30мин + граница суток + округление + TZ) ---
    local_tz = now.tzinfo
    GAP = 30 * 60
    blocks = []
    grp = []

    def _emit(g):
        first, last = g[0], g[-1]
        st = first.dt.astimezone(local_tz).replace(second=0, microsecond=0)
        st = st.replace(minute=(st.minute // 15) * 15)          # старт вниз до 15 мин
        dur = int((last.epoch - first.epoch) // 60) + 5         # block wall clock + буфер
        dur = max(15, ((dur + 14) // 15) * 15)                  # вверх до 15 мин, минимум 15
        en = st + timedelta(minutes=dur)
        blocks.append((st, en, dur))

    for t in sorted(current, key=lambda x: x.epoch):
        if grp:
            gap = t.epoch - grp[-1].epoch
            same_day = t.dt.astimezone(local_tz).date() == grp[-1].dt.astimezone(local_tz).date()
            if gap > GAP or not same_day:                       # разрыв блока: пауза >30мин ИЛИ новый день
                _emit(grp); grp = []
        grp.append(t)
    if grp:
        _emit(grp)

    print(f"block_count={len(blocks)}")
    for i, (st, en, dur) in enumerate(blocks, 1):
        print(f"block={i} start={st.isoformat()} end={en.isoformat()} duration={dur} day={st.date().isoformat()}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
