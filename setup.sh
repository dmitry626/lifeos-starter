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
    # Печатает пути ко всем vault из obsidian.json, по одному на строку
    if [ ! -f "$OBSIDIAN_CONFIG" ]; then
        return 0
    fi
    # Используем python3 (есть на macOS по умолчанию)
    if command -v python3 >/dev/null 2>&1; then
        python3 -c "
import json, sys
try:
    with open('$OBSIDIAN_CONFIG') as f:
        data = json.load(f)
    vaults = data.get('vaults', {})
    for v in vaults.values():
        path = v.get('path')
        if path:
            print(path)
except Exception as e:
    sys.stderr.write(f'Config read error: {e}\n')
    sys.exit(0)
"
    fi
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
        if ! command -v unzip >/dev/null 2>&1; then
            err "unzip не установлен. Linux: sudo apt install unzip"
            exit 1
        fi
        unzip -q "$LOCAL_SOURCE" -d "$TMP_DIR"
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
    if ! command -v unzip >/dev/null 2>&1; then
        err "unzip не установлен."
        exit 1
    fi
    unzip -q "$TMP_DIR/starter.zip" -d "$TMP_DIR"
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

# ---------- 3. Скопировать в vault ----------
log "Копирую файлы в vault (.obsidian/ не затрагивается)..."
cp -R "$EXTRACTED/." "$VAULT_DIR/"

# ---------- 4. Проверить claude ----------
CLAUDE_OK=1
if ! command -v claude >/dev/null 2>&1; then
    warn ""
    warn "Команда 'claude' не найдена в PATH."
    warn "Установи Claude Code: https://claude.ai"
    warn ""
    CLAUDE_OK=0
fi

# ---------- 5. Прописать алиас ----------
SHELL_RC=""
if [ -n "${ZSH_VERSION:-}" ]; then
    SHELL_RC="$HOME/.zshrc"
elif [ -n "${BASH_VERSION:-}" ]; then
    SHELL_RC="$HOME/.bashrc"
elif [ "${SHELL:-}" = "/bin/zsh" ] || [ "${SHELL:-}" = "/usr/bin/zsh" ] || [ -f "$HOME/.zshrc" ]; then
    SHELL_RC="$HOME/.zshrc"
elif [ -f "$HOME/.bashrc" ]; then
    SHELL_RC="$HOME/.bashrc"
fi

if [ -n "$SHELL_RC" ]; then
    ALIAS_LINE="alias lifeos='cd \"$VAULT_DIR\" && claude'"
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

# ---------- 6. Запуск ----------
echo ""
log "============================================="
log "Установка LifeOS завершена"
log "Vault: $VAULT_DIR"
log "============================================="
echo ""

if [ "$CLAUDE_OK" = "1" ]; then
    log "Запускаю Claude Code — дальше AI поведёт тебя сам."
    echo ""
    cd "$VAULT_DIR"
    exec claude
else
    log "После установки Claude Code запусти вручную:"
    log "  cd \"$VAULT_DIR\" && claude"
fi
