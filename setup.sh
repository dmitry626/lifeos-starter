#!/usr/bin/env bash
#
# LifeOS Starter Pack — setup script (macOS / Linux)
#
# Что делает:
#   1. Находит vault автоматически (через конфиг Obsidian или текущую папку).
#   2. Скачивает starter pack с GitHub (или берёт локальный источник через
#      LIFEOS_SOURCE).
#   3. Распаковывает содержимое в vault, не затрагивая .obsidian/.
#   4. Прописывает идемпотентный алиас `lifeos` в ~/.zshrc или ~/.bashrc.
#   5. Запускает claude — управление переходит к AI.
#
# Использование:
#   # Однострочно из любой папки:
#   curl -fsSL https://raw.githubusercontent.com/dmitry626/lifeos-starter/main/setup.sh | bash
#
#   # Локально:
#   ./setup.sh
#
#   # С указанием пути vault:
#   ./setup.sh /path/to/vault
#
#   # С локальным источником (для теста, пока репо приватный):
#   LIFEOS_SOURCE=/path/to/lifeos-starter-main.zip ./setup.sh
#

set -euo pipefail

# ---------- Настройки ----------
REPO_URL="${LIFEOS_REPO_URL:-https://github.com/dmitry626/lifeos-starter}"
BRANCH="${LIFEOS_BRANCH:-main}"
LOCAL_SOURCE="${LIFEOS_SOURCE:-}"

# ---------- Цвета ----------
if [ -t 1 ]; then
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    RED='\033[0;31m'
    BOLD='\033[1m'
    NC='\033[0m'
else
    GREEN='' YELLOW='' RED='' BOLD='' NC=''
fi

log()  { printf "${GREEN}${BOLD}[LifeOS]${NC} %s\n" "$*"; }
warn() { printf "${YELLOW}${BOLD}[LifeOS]${NC} %s\n" "$*"; }
err()  { printf "${RED}${BOLD}[LifeOS]${NC} %s\n" "$*" >&2; }

# ---------- Распаковка ZIP ----------
# BSD unzip на macOS не поддерживает UTF-8 имена файлов — ломается на
# кириллице. Используем нативные альтернативы, которые с UTF-8 работают.
extract_zip() {
    local zip_file="$1"
    local dest_dir="$2"

    # macOS: ditto (нативная утилита Apple, правильно обрабатывает UTF-8)
    if command -v ditto >/dev/null 2>&1; then
        ditto -xk "$zip_file" "$dest_dir" 2>/dev/null && return 0
    fi

    # Современный tar (libarchive) умеет zip из коробки
    if command -v tar >/dev/null 2>&1; then
        (cd "$dest_dir" && tar xf "$zip_file") 2>/dev/null && return 0
    fi

    # Последний шанс — unzip (на Linux обычно Info-ZIP с UTF-8)
    if command -v unzip >/dev/null 2>&1; then
        unzip -q "$zip_file" -d "$dest_dir" && return 0
    fi

    err "Не удалось распаковать ZIP. Нет ditto/tar/unzip в PATH."
    return 1
}

# ---------- Чтение stdin из /dev/tty (для curl | bash) ----------
# Когда скрипт запущен через `curl | bash`, stdin занят под сам скрипт.
# Для интерактивных вопросов читаем напрямую с терминала.
read_tty() {
    local prompt="$1"
    local var
    if [ -r /dev/tty ]; then
        read -r -p "$prompt" var < /dev/tty
    else
        read -r -p "$prompt" var
    fi
    printf '%s' "$var"
}

# ---------- Определить vault ----------
# Приоритет:
#   1. Аргумент $1 (явный путь)
#   2. Текущая папка, если в ней .obsidian/
#   3. Конфиг Obsidian: ~/Library/Application Support/obsidian/obsidian.json
#   4. Спросить пользователя интерактивно

OBSIDIAN_CONFIG="$HOME/Library/Application Support/obsidian/obsidian.json"
# На Linux: ~/.config/obsidian/obsidian.json
if [ ! -f "$OBSIDIAN_CONFIG" ] && [ -f "$HOME/.config/obsidian/obsidian.json" ]; then
    OBSIDIAN_CONFIG="$HOME/.config/obsidian/obsidian.json"
fi

extract_vaults_from_config() {
    # Печатает пути ко всем vault из obsidian.json, по одному на строку.
    # Используем чистый grep+sed (нативно в macOS/Linux, без зависимости
    # от python/jq — чтобы не триггерить xcode-select на чистом Mac).
    if [ ! -f "$OBSIDIAN_CONFIG" ]; then
        return 0
    fi
    # Формат obsidian.json: {"vaults": {"hash": {"path": "/путь", ...}, ...}}
    # Вытаскиваем все значения поля "path" (пути в macOS могут содержать
    # пробелы, но не двойные кавычки — поэтому "[^"]*" корректен).
    grep -Eo '"path"[[:space:]]*:[[:space:]]*"[^"]*"' "$OBSIDIAN_CONFIG" 2>/dev/null \
        | sed -E 's/.*"path"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/'
}

choose_vault_interactive() {
    # Из списка на stdin — пусть пользователь выберет
    local vaults=()
    while IFS= read -r line; do
        [ -n "$line" ] && [ -d "$line" ] && vaults+=("$line")
    done

    if [ "${#vaults[@]}" -eq 0 ]; then
        return 1
    fi

    if [ "${#vaults[@]}" -eq 1 ]; then
        # Один vault — подтвердить и использовать
        printf '%s' "${vaults[0]}"
        return 0
    fi

    # Несколько — показать список и выбор
    {
        warn "Найдено несколько Obsidian-vault'ов:"
        local i=1
        for v in "${vaults[@]}"; do
            printf "  %d) %s\n" "$i" "$v"
            i=$((i + 1))
        done
    } >&2

    local choice
    choice=$(read_tty "Выбери номер vault для установки LifeOS [1-${#vaults[@]}]: ")
    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#vaults[@]}" ]; then
        printf '%s' "${vaults[$((choice - 1))]}"
        return 0
    fi
    return 1
}

detect_vault() {
    local vault_dir=""

    # 1. Аргумент скрипта
    if [ $# -gt 0 ] && [ -n "$1" ]; then
        if [ -d "$1/.obsidian" ]; then
            printf '%s' "$1"
            return 0
        else
            warn "Папка '$1' не содержит .obsidian/ — не похоже на vault."
        fi
    fi

    # 2. Текущая папка
    if [ -d "$PWD/.obsidian" ]; then
        printf '%s' "$PWD"
        return 0
    fi

    # 3. Конфиг Obsidian
    local candidates
    candidates="$(extract_vaults_from_config || true)"

    if [ -n "$candidates" ]; then
        local chosen
        chosen="$(printf '%s\n' "$candidates" | choose_vault_interactive || true)"
        if [ -n "$chosen" ] && [ -d "$chosen/.obsidian" ]; then
            printf '%s' "$chosen"
            return 0
        fi
    fi

    # 4. Спросить пользователя
    warn "Не удалось найти vault автоматически."
    warn "Подсказка: в Finder открой папку vault LifeOS, перетащи её в это окно терминала —"
    warn "путь вставится автоматически."
    local user_path
    user_path=$(read_tty "Путь к папке vault: ")
    # Убираем кавычки и пробелы (Finder иногда оборачивает в одинарные кавычки)
    user_path="${user_path%\'}"
    user_path="${user_path#\'}"
    user_path="${user_path%\"}"
    user_path="${user_path#\"}"

    if [ -d "$user_path" ]; then
        printf '%s' "$user_path"
        return 0
    fi

    err "Путь '$user_path' не существует."
    return 1
}

VAULT_DIR="$(detect_vault "${1:-}" || true)"

if [ -z "$VAULT_DIR" ] || [ ! -d "$VAULT_DIR" ]; then
    err "Vault не определён. Отмена."
    err ""
    err "Варианты:"
    err "  1. Запусти скрипт из папки vault: cd <vault>; bash setup.sh"
    err "  2. Передай путь аргументом: bash setup.sh /path/to/vault"
    err "  3. Проверь, что Obsidian создал хотя бы один vault"
    exit 1
fi

if [ ! -d "$VAULT_DIR/.obsidian" ]; then
    warn "В $VAULT_DIR нет .obsidian/."
    confirm=$(read_tty "Всё равно установить в эту папку? [y/N] ")
    case "$confirm" in
        [yY]|[yY][eE][sS]) ;;
        *) err "Отмена."; exit 1 ;;
    esac
fi

log "Vault: $VAULT_DIR"

# ---------- 2. Получить содержимое ----------
TMP_DIR="$(mktemp -d -t lifeos-setup.XXXXXX)"
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

if [ -n "$LOCAL_SOURCE" ]; then
    log "Источник: локальный — $LOCAL_SOURCE"
    if [ -f "$LOCAL_SOURCE" ]; then
        extract_zip "$LOCAL_SOURCE" "$TMP_DIR" || exit 1
    elif [ -d "$LOCAL_SOURCE" ]; then
        mkdir -p "$TMP_DIR/source"
        cp -R "$LOCAL_SOURCE/." "$TMP_DIR/source/"
    else
        err "LIFEOS_SOURCE указан, но $LOCAL_SOURCE не файл и не папка."
        exit 1
    fi
else
    ZIP_URL="$REPO_URL/archive/refs/heads/$BRANCH.zip"
    log "Скачиваю starter pack..."
    log "  $ZIP_URL"
    if ! curl -fsSL -o "$TMP_DIR/starter.zip" "$ZIP_URL"; then
        err ""
        err "Не удалось скачать $ZIP_URL"
        err "Проверь доступ в интернет и что репозиторий публичный."
        exit 1
    fi
    extract_zip "$TMP_DIR/starter.zip" "$TMP_DIR" || exit 1
    rm -f "$TMP_DIR/starter.zip"
fi

# Найти распакованную папку
EXTRACTED=""
for d in "$TMP_DIR"/*/; do
    [ -d "$d" ] || continue
    EXTRACTED="${d%/}"
    break
done

if [ -z "$EXTRACTED" ]; then
    err "Не найдена распакованная папка в $TMP_DIR"
    exit 1
fi

# ---------- 3a. Бэкап при повторной установке ----------
MARKER="$VAULT_DIR/.lifeos-installed"
IS_REINSTALL=0

if [ -f "$MARKER" ]; then
    IS_REINSTALL=1
    BACKUP_DIR="$VAULT_DIR/.lifeos-backup-$(date +%Y%m%d-%H%M%S)"
    log ""
    log "Обнаружена предыдущая установка LifeOS в этом vault."
    log "Marker: $MARKER"
    log "Делаю бэкап файлов, которые могут быть перезаписаны, в:"
    log "  $BACKUP_DIR"

    mkdir -p "$BACKUP_DIR"

    # Проходим по всем файлам в распакованном starter pack
    # и бэкапим те, что уже существуют в vault (значит будут перезаписаны)
    BACKUP_COUNT=0
    while IFS= read -r rel_path; do
        [ -z "$rel_path" ] && continue
        src="$VAULT_DIR/$rel_path"
        if [ -f "$src" ]; then
            dest="$BACKUP_DIR/$rel_path"
            mkdir -p "$(dirname "$dest")"
            cp "$src" "$dest"
            BACKUP_COUNT=$((BACKUP_COUNT + 1))
        fi
    done < <(cd "$EXTRACTED" && find . -type f | sed 's|^\./||')

    if [ "$BACKUP_COUNT" -gt 0 ]; then
        log "Забэкаплено файлов: $BACKUP_COUNT"
        log "Если после обновления что-то нужно вернуть — файлы в $BACKUP_DIR"
    else
        # Бэкап пустой — удаляем пустую папку
        rmdir "$BACKUP_DIR" 2>/dev/null || true
        log "Перезаписываемых файлов не обнаружено, бэкап не нужен."
    fi
    log ""
fi

# ---------- 3b. Скопировать в vault ----------
log "Копирую файлы в vault (.obsidian/ не затрагивается)..."
cp -R "$EXTRACTED/." "$VAULT_DIR/"

# ---------- 3c. Записать marker ----------
{
    echo "LifeOS Starter Pack"
    if [ "$IS_REINSTALL" = "0" ]; then
        echo "installed: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    else
        # Сохраняем оригинальную дату установки, добавляем дату обновления
        grep "^installed:" "$MARKER" 2>/dev/null || echo "installed: unknown"
    fi
    echo "last_run: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    echo "repo: $REPO_URL"
    echo "branch: $BRANCH"
} > "$MARKER"

# ---------- 4. Найти claude ----------
# Установщик Claude Code кладёт бинарник в ~/.local/bin/claude и
# добавляет PATH в ~/.zshrc. Но текущая bash-сессия (особенно curl | bash)
# не видит изменений .zshrc — нужно искать по известным местам явно.
find_claude() {
    if command -v claude >/dev/null 2>&1; then
        command -v claude
        return 0
    fi
    for p in \
        "$HOME/.local/bin/claude" \
        "$HOME/.claude/local/claude" \
        "/usr/local/bin/claude" \
        "/opt/homebrew/bin/claude"
    do
        if [ -x "$p" ]; then
            printf '%s' "$p"
            return 0
        fi
    done
    return 1
}

CLAUDE_BIN="$(find_claude || true)"
CLAUDE_OK=0
if [ -n "$CLAUDE_BIN" ]; then
    CLAUDE_OK=1
    log "Найден claude: $CLAUDE_BIN"
    # Добавим его папку в PATH, чтобы exec нашёл
    case ":$PATH:" in
        *":$(dirname "$CLAUDE_BIN"):"*) ;;
        *) export PATH="$(dirname "$CLAUDE_BIN"):$PATH" ;;
    esac
else
    warn ""
    warn "Команда 'claude' не найдена ни в PATH, ни в стандартных местах"
    warn "(~/.local/bin, ~/.claude/local, /usr/local/bin, /opt/homebrew/bin)."
    warn "Установи Claude Code: https://claude.ai"
    warn ""
fi

# ---------- 5. Прописать алиас ----------
# Определяем shell пользователя по $SHELL, а НЕ по ZSH_VERSION/BASH_VERSION
# (эти переменные отражают shell самого скрипта, а не login shell).
# curl | bash запускает bash, и BASH_VERSION будет установлен даже если
# у пользователя zsh — поэтому раньше алиас ошибочно попадал в .bashrc.
SHELL_NAME="$(basename "${SHELL:-/bin/zsh}")"
case "$SHELL_NAME" in
    zsh)
        SHELL_RC="$HOME/.zshrc"
        ;;
    bash)
        # macOS: login bash читает .bash_profile; Linux: .bashrc
        if [ "$(uname)" = "Darwin" ]; then
            SHELL_RC="$HOME/.bash_profile"
        else
            SHELL_RC="$HOME/.bashrc"
        fi
        ;;
    *)
        SHELL_RC="$HOME/.profile"
        ;;
esac
# Создаём файл если его нет, чтобы не падать при grep/append
[ ! -f "$SHELL_RC" ] && touch "$SHELL_RC"

# ---------- 5a. Добавить ~/.local/bin в PATH ----------
# Claude Code installer ставит бинарник в ~/.local/bin, но НЕ прописывает
# его автоматически в ~/.zshrc — показывает предупреждение, которое 90%
# новичков пропускают. В результате `claude` не работает в новых окнах
# терминала. Прописываем сами, идемпотентно.
if [ -d "$HOME/.local/bin" ] || [ -x "$HOME/.local/bin/claude" ]; then
    if ! grep -Fq '.local/bin' "$SHELL_RC" 2>/dev/null; then
        {
            echo ""
            echo "# Claude Code installer puts binary here — add to PATH for new sessions"
            echo 'export PATH="$HOME/.local/bin:$PATH"'
        } >> "$SHELL_RC"
        log "Добавлено ~/.local/bin в PATH через $SHELL_RC"
    else
        log "~/.local/bin уже в PATH через $SHELL_RC — не дублирую."
    fi
fi

if [ -n "$SHELL_RC" ]; then
    # Умный алиас: если vault в iCloud-контейнере Obsidian И brctl доступен,
    # делаем предварительный download всего контейнера (файлы в iCloud могут
    # быть placeholder'ами — Claude при чтении натолкнётся на не-скачанные).
    ICLOUD_ROOT="$HOME/Library/Mobile Documents/iCloud~md~obsidian"
    if [[ "$VAULT_DIR" == "$ICLOUD_ROOT/"* ]] && command -v brctl >/dev/null 2>&1; then
        ALIAS_LINE="alias lifeos='brctl download \"$ICLOUD_ROOT/\" & cd \"$VAULT_DIR\" && claude'"
    else
        ALIAS_LINE="alias lifeos='cd \"$VAULT_DIR\" && claude'"
    fi

    if [ -f "$SHELL_RC" ] && grep -Fq "alias lifeos=" "$SHELL_RC" 2>/dev/null; then
        log "Алиас 'lifeos' уже есть в $SHELL_RC — не дублирую."
    else
        {
            echo ""
            echo "# LifeOS"
            echo "$ALIAS_LINE"
        } >> "$SHELL_RC"
        log "Алиас 'lifeos' добавлен в $SHELL_RC"
        log "Для активации в текущей сессии: source $SHELL_RC"
    fi
else
    warn "Не нашёл ~/.zshrc или ~/.bashrc — алиас не прописан."
    warn "Добавь вручную: alias lifeos='cd \"$VAULT_DIR\" && claude'"
fi

# ---------- 6. Приветствие и запуск ----------
print_welcome() {
    local mode="$1"   # "launch" или "install-claude"
    echo ""
    printf "${GREEN}${BOLD}══════════════════════════════════════════════════════${NC}\n"
    printf "\n"
    printf "  ${BOLD}Добро пожаловать в LifeOS${NC}\n"
    printf "\n"
    printf "  Твоя система установлена:\n"
    printf "  ${VAULT_DIR}\n"
    printf "\n"

    if [ "$mode" = "launch" ]; then
        printf "  Запускаю Claude Code — дальше AI проведёт тебя\n"
        printf "  через первичную настройку системы.\n"
        printf "\n"
        printf "  В следующие разы запускай систему одной командой:\n"
        printf "\n"
        printf "      ${BOLD}${GREEN}lifeos${NC}\n"
    else
        printf "  ${YELLOW}Остался последний шаг — установить Claude Code:${NC}\n"
        printf "  ${BOLD}https://claude.ai${NC}\n"
        printf "\n"
        printf "  После установки открой ${BOLD}новое окно терминала${NC}\n"
        printf "  и запусти систему одной командой:\n"
        printf "\n"
        printf "      ${BOLD}${GREEN}lifeos${NC}\n"
    fi

    printf "\n"
    printf "${GREEN}${BOLD}══════════════════════════════════════════════════════${NC}\n"
    echo ""
}

if [ "$CLAUDE_OK" = "1" ]; then
    print_welcome "launch"
    cd "$VAULT_DIR"
    exec "$CLAUDE_BIN"
else
    print_welcome "install-claude"
fi
