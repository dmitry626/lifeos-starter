#!/usr/bin/env python3
"""
Атомарная запись/обновление блока в weekly-журнале Claude Code.

Использование:
    session_log_append.py --week-file PATH --session-id ID --payload-file PATH --mode insert
    session_log_append.py --week-file PATH --session-id ID --payload-file PATH --mode update
    session_log_append.py --week-file PATH --session-id ID --payload-file PATH --mode auto

Режимы:
    insert  — вставить payload в начало обратной хронологии (после шапки).
              Если в файле уже есть блок с тем же session-id — ошибка.
    update  — найти блок с тем же session-id и заменить его на payload.
              Если не найден — ошибка.
    auto    — если блок с тем же session-id найден → update, иначе insert.
              Рекомендуется как дефолт.

Параметры:
    --week-file     Путь к weekly-файлу `YYYY-WNN.md`.
                    Если файл не существует — создаётся с шапкой из
                    `--week-title` (или генерируется из имени файла).
    --session-id    Session ID (строка из
                    `Resources/00 Журнал AI/logs/claude-session-<id>.log`).
                    Должна совпадать со значением в маркере payload.
    --payload-file  Путь к файлу с готовым блоком записи. Формат:

                        ### YYYY-MM-DD HH:MM
                        ...
                        <!-- session: <id> | name: ... | host: ... -->
                        ...

                    Блок НЕ содержит завершающего пустого разделителя —
                    скрипт сам добавит пустую строку после блока.
    --mode          insert | update | auto (по умолчанию: auto).
    --week-title    Заголовок для создаваемой шапки, если weekly-файл не
                    существует. По умолчанию выводится из basename.
    --week-range    Строка «YYYY-MM-DD (Пн) — YYYY-MM-DD (Вс)» для шапки.
                    Обязателен при создании нового файла.
    --lock-timeout  Секунды ожидания flock (по умолчанию 10).

Конкурентность:
    Запись под эксклюзивным fcntl.flock на файле
    `Resources/00 Журнал AI/logs/session-log.lock`.
    Параллельные вызовы из разных Claude Code-сессий сериализуются —
    невозможен lost update при одновременной записи нескольких сессий в
    один weekly-файл.

Атомарность записи:
    Запись через временный файл в той же директории + os.replace().
    os.replace() гарантирует атомарность на одном FS (POSIX rename).

История:
    2026-04-15: создан в рамках бэклога L2 (см.
        Agents/Инфраструктура/Session Logger/Backlog/L2 Flock на запись weekly-журнала.md).
        Решает race condition при параллельных /session-log вызовах.
"""

from __future__ import annotations

import argparse
import fcntl
import os
import re
import sys
import tempfile
import time
from pathlib import Path

def _resolve_lock_file() -> str:
    """Lock-файл живёт в home (~/.lifeos/logs), рядом с raw-логами сессий.

    Плагин user-scope: журнал и логи не привязаны к проекту/vault. Канонический
    путь, переопределяется env LIFEOS_HOME. Стабильный путь нужен, чтобы flock
    сериализовал параллельные /session-log на одной машине.
    """
    home = os.environ.get("LIFEOS_HOME") or os.path.join(os.path.expanduser("~"), ".lifeos")
    lock_dir = os.path.join(home, "logs")
    os.makedirs(lock_dir, exist_ok=True)
    return os.path.join(lock_dir, "session-log.lock")


LOCK_FILE = _resolve_lock_file()
HEADER_LINE_RE = re.compile(r"^>\s*Неделя:")

# Маркер начала блока: "<!-- session: <id>"
# Используем именно начало строки, чтобы исключить случайные совпадения в тексте.
SESSION_MARKER_RE = re.compile(
    r"^<!--\s*session:\s*([^\s|>]+)", re.MULTILINE
)


def read_payload(path: str) -> str:
    with open(path, "r", encoding="utf-8") as f:
        payload = f.read()
    # Нормализуем: ровно один trailing newline, без лишних пустых строк
    payload = payload.rstrip() + "\n"
    return payload


def verify_payload_session_id(payload: str, expected_id: str) -> None:
    """Убедиться, что payload содержит маркер с ожидаемым session-id.

    Это защита от рассинхронизации CLI-аргумента и содержимого payload.
    """
    m = SESSION_MARKER_RE.search(payload)
    if not m:
        raise ValueError(
            "payload не содержит маркер '<!-- session: <id> -->'. "
            "Добавь маркер в тело записи или используй --no-verify-payload."
        )
    found_id = m.group(1)
    if found_id != expected_id:
        raise ValueError(
            f"session-id в маркере payload ({found_id}) не совпадает с "
            f"--session-id ({expected_id})"
        )


def ensure_week_file(path: str, week_title: str | None, week_range: str | None) -> None:
    """Создаёт weekly-файл с шапкой, если его нет."""
    if os.path.exists(path):
        return
    stem = Path(path).stem  # "2026-W16"
    title = week_title or f"{stem} – Журнал AI"
    lines = [f"# {title}", ""]
    if week_range:
        lines.append(f"> Неделя: {week_range}")
        lines.append("")
    else:
        lines.append("> Неделя: (уточнить)")
        lines.append("")
    Path(path).parent.mkdir(parents=True, exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")


def find_existing_block(content: str, session_id: str) -> tuple[int, int] | None:
    """Ищет блок с указанным session-id.

    Возвращает (start_line_idx, end_line_idx) — границы блока в списке строк.
    end_line_idx — индекс строки ПОСЛЕ последней строки блока (exclusive).
    Блок начинается с `###` (заголовок записи) и заканчивается перед
    следующим `###` или концом файла.

    Если не найден — None.
    """
    lines = content.splitlines()
    # Найти строку с маркером
    marker_prefix = f"<!-- session: {session_id}"
    marker_line_idx = None
    for i, line in enumerate(lines):
        if line.strip().startswith(marker_prefix):
            marker_line_idx = i
            break
    if marker_line_idx is None:
        return None

    # Назад к ближайшему `###`
    start_idx = None
    for i in range(marker_line_idx, -1, -1):
        if lines[i].startswith("### "):
            start_idx = i
            break
    if start_idx is None:
        return None

    # Вперёд до следующего `###` или EOF
    end_idx = len(lines)
    for i in range(start_idx + 1, len(lines)):
        if lines[i].startswith("### "):
            end_idx = i
            break
    # Исключить trailing пустые строки блока
    while end_idx > start_idx and not lines[end_idx - 1].strip():
        end_idx -= 1
    return (start_idx, end_idx)


def find_insert_point(content: str) -> int:
    """Возвращает индекс строки, ПОСЛЕ которой вставлять новую запись.

    Ищется последняя строка `> Неделя: ...` (шапка блока). Если найдена —
    точка вставки = строка после шапки + одна пустая строка. Если не
    найдена — вставляем после строки `#` (заголовок файла). Если и её нет
    — в самое начало.
    """
    lines = content.splitlines()
    for i, line in enumerate(lines):
        if HEADER_LINE_RE.match(line):
            return i + 1  # после шапки
    for i, line in enumerate(lines):
        if line.startswith("# "):
            return i + 1
    return 0


def insert_block(content: str, payload: str) -> str:
    lines = content.splitlines()
    insert_idx = find_insert_point(content)
    # Пропустить существующие пустые строки после точки вставки
    while insert_idx < len(lines) and not lines[insert_idx].strip():
        insert_idx += 1
    payload_lines = payload.rstrip("\n").split("\n")
    new_lines = (
        lines[:insert_idx]
        + [""]  # пустая строка-разделитель перед новой записью
        + payload_lines
        + [""]  # пустая строка после
        + lines[insert_idx:]
    )
    return "\n".join(new_lines) + "\n"


def update_block(
    content: str, payload: str, block: tuple[int, int]
) -> str:
    lines = content.splitlines()
    start, end = block
    payload_lines = payload.rstrip("\n").split("\n")
    new_lines = lines[:start] + payload_lines + lines[end:]
    return "\n".join(new_lines) + "\n"


def atomic_write(path: str, content: str) -> None:
    """Запись через tmp-файл в той же директории + os.replace()."""
    dir_ = os.path.dirname(os.path.abspath(path)) or "."
    fd, tmp_path = tempfile.mkstemp(
        prefix=".session-log-", suffix=".tmp", dir=dir_
    )
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(content)
        os.replace(tmp_path, path)
    except Exception:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass
        raise


def acquire_lock(lock_path: str, timeout_sec: float) -> int:
    """Блокирует lock-файл эксклюзивно, с timeout.

    Возвращает file descriptor lock-файла. Caller обязан не закрывать его
    до завершения критической секции — освобождение происходит через
    os.close() в finally.
    """
    fd = os.open(lock_path, os.O_RDWR | os.O_CREAT, 0o644)
    deadline = time.monotonic() + timeout_sec
    while True:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return fd
        except BlockingIOError:
            if time.monotonic() >= deadline:
                os.close(fd)
                raise TimeoutError(
                    f"не удалось захватить lock {lock_path} за {timeout_sec} сек"
                )
            time.sleep(0.1)


def main(argv: list[str]) -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--week-file", required=True)
    p.add_argument("--session-id", required=True)
    p.add_argument("--payload-file", required=True)
    p.add_argument("--mode", choices=["insert", "update", "auto"], default="auto")
    p.add_argument("--week-title", default=None)
    p.add_argument("--week-range", default=None)
    p.add_argument("--lock-timeout", type=float, default=10.0)
    p.add_argument("--no-verify-payload", action="store_true")
    args = p.parse_args(argv[1:])

    if not os.path.isfile(args.payload_file):
        print(f"error: payload file not found: {args.payload_file}", file=sys.stderr)
        return 2

    payload = read_payload(args.payload_file)
    if not args.no_verify_payload:
        try:
            verify_payload_session_id(payload, args.session_id)
        except ValueError as e:
            print(f"error: {e}", file=sys.stderr)
            return 2

    lock_fd = acquire_lock(LOCK_FILE, args.lock_timeout)
    try:
        ensure_week_file(args.week_file, args.week_title, args.week_range)
        with open(args.week_file, "r", encoding="utf-8") as f:
            content = f.read()

        existing = find_existing_block(content, args.session_id)
        effective_mode = args.mode
        if effective_mode == "auto":
            effective_mode = "update" if existing else "insert"

        if effective_mode == "insert":
            if existing:
                print(
                    f"error: запись с session-id={args.session_id} уже существует "
                    f"в {args.week_file}; используй --mode update или auto",
                    file=sys.stderr,
                )
                return 3
            new_content = insert_block(content, payload)
            action = "insert"
        elif effective_mode == "update":
            if not existing:
                print(
                    f"error: запись с session-id={args.session_id} не найдена "
                    f"в {args.week_file}; используй --mode insert или auto",
                    file=sys.stderr,
                )
                return 4
            new_content = update_block(content, payload, existing)
            action = "update"
        else:
            print(f"error: неизвестный режим {effective_mode}", file=sys.stderr)
            return 2

        atomic_write(args.week_file, new_content)
    finally:
        try:
            fcntl.flock(lock_fd, fcntl.LOCK_UN)
        except OSError:
            pass
        os.close(lock_fd)

    print(f"mode={action}")
    print(f"week_file={args.week_file}")
    print(f"session_id={args.session_id}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
