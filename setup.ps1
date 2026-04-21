# LifeOS Starter Pack — setup script (Windows, PowerShell)
#
# Что делает:
#   1. Находит vault автоматически (через конфиг Obsidian или текущую папку).
#   2. Скачивает starter pack с GitHub (или берёт локальный источник через
#      $env:LIFEOS_SOURCE).
#   3. Распаковывает содержимое в vault, не затрагивая .obsidian/.
#   4. Прописывает идемпотентную функцию `lifeos` в PowerShell-профиль.
#   5. Запускает claude — управление переходит к AI.
#
# Использование:
#   # Однострочно из любой папки:
#   iwr -useb https://raw.githubusercontent.com/dmitry626/lifeos-starter/main/setup.ps1 | iex
#
#   # Локально:
#   .\setup.ps1
#
#   # С указанием пути vault:
#   .\setup.ps1 -VaultPath "C:\Users\me\Documents\LifeOS"
#
#   # С локальным источником:
#   $env:LIFEOS_SOURCE = 'C:\path\to\lifeos-starter-main.zip'; .\setup.ps1

param(
    [string]$VaultPath = ''
)

$ErrorActionPreference = 'Stop'

# ---------- Настройки ----------
$RepoUrl = if ($env:LIFEOS_REPO_URL) { $env:LIFEOS_REPO_URL } else { 'https://github.com/dmitry626/lifeos-starter' }
$Branch = if ($env:LIFEOS_BRANCH) { $env:LIFEOS_BRANCH } else { 'main' }
$LocalSource = $env:LIFEOS_SOURCE

function Write-Log  { param($m) Write-Host "[LifeOS] $m" -ForegroundColor Green }
function Write-Warn { param($m) Write-Host "[LifeOS] $m" -ForegroundColor Yellow }
function Write-Err  { param($m) Write-Host "[LifeOS] $m" -ForegroundColor Red }

# ---------- Определить vault ----------
function Get-ObsidianVaults {
    $configPath = Join-Path $env:APPDATA 'obsidian\obsidian.json'
    if (-not (Test-Path $configPath)) {
        return @()
    }
    try {
        $config = Get-Content $configPath -Raw | ConvertFrom-Json
        $paths = @()
        foreach ($prop in $config.vaults.PSObject.Properties) {
            if ($prop.Value.path) {
                $paths += $prop.Value.path
            }
        }
        return $paths | Where-Object { Test-Path $_ -PathType Container }
    } catch {
        return @()
    }
}

function Resolve-VaultDir {
    param([string]$Explicit)

    # 1. Явный аргумент
    if ($Explicit) {
        if (Test-Path (Join-Path $Explicit '.obsidian')) {
            return $Explicit
        }
        Write-Warn "Папка '$Explicit' не содержит .obsidian/ — не похоже на vault."
    }

    # 2. Текущая папка
    $cwd = (Get-Location).Path
    if (Test-Path (Join-Path $cwd '.obsidian')) {
        return $cwd
    }

    # 3. Конфиг Obsidian
    $vaults = Get-ObsidianVaults
    if ($vaults.Count -eq 1) {
        return $vaults[0]
    }
    if ($vaults.Count -gt 1) {
        Write-Warn "Найдено несколько Obsidian-vault'ов:"
        for ($i = 0; $i -lt $vaults.Count; $i++) {
            Write-Host ("  {0}) {1}" -f ($i + 1), $vaults[$i])
        }
        $choice = Read-Host "Выбери номер [1-$($vaults.Count)]"
        if ($choice -match '^\d+$') {
            $idx = [int]$choice - 1
            if ($idx -ge 0 -and $idx -lt $vaults.Count) {
                return $vaults[$idx]
            }
        }
    }

    # 4. Интерактивный ввод
    Write-Warn "Не удалось найти vault автоматически."
    Write-Warn "Путь к vault можно перетащить из Explorer в это окно терминала."
    $userPath = Read-Host "Путь к папке vault"
    $userPath = $userPath.Trim("'").Trim('"')
    if (Test-Path $userPath -PathType Container) {
        return $userPath
    }

    return $null
}

$VaultDir = Resolve-VaultDir -Explicit $VaultPath

if (-not $VaultDir -or -not (Test-Path $VaultDir -PathType Container)) {
    Write-Err "Vault не определён. Отмена."
    Write-Err ""
    Write-Err "Варианты:"
    Write-Err "  1. Запусти из папки vault: cd <vault>; .\setup.ps1"
    Write-Err "  2. Передай путь: .\setup.ps1 -VaultPath 'C:\путь\к\vault'"
    Write-Err "  3. Проверь, что Obsidian создал хотя бы один vault"
    exit 1
}

if (-not (Test-Path (Join-Path $VaultDir '.obsidian'))) {
    Write-Warn "В $VaultDir нет .obsidian/."
    $confirm = Read-Host "Всё равно установить в эту папку? [y/N]"
    if ($confirm -notmatch '^[Yy]') { Write-Err 'Отмена.'; exit 1 }
}

Write-Log "Vault: $VaultDir"

# ---------- 2. Получить содержимое ----------
$TmpDir = Join-Path $env:TEMP ("lifeos-setup-" + [System.Guid]::NewGuid().ToString('N').Substring(0,8))
New-Item -ItemType Directory -Path $TmpDir -Force | Out-Null

try {
    if ($LocalSource) {
        Write-Log "Источник: локальный — $LocalSource"
        if (Test-Path $LocalSource -PathType Leaf) {
            Expand-Archive -Path $LocalSource -DestinationPath $TmpDir -Force
        } elseif (Test-Path $LocalSource -PathType Container) {
            Copy-Item -Path (Join-Path $LocalSource '*') -Destination $TmpDir -Recurse -Force
        } else {
            Write-Err "LIFEOS_SOURCE=$LocalSource не найден (не файл и не папка)."
            exit 1
        }
    } else {
        $ZipUrl = "$RepoUrl/archive/refs/heads/$Branch.zip"
        $ZipPath = Join-Path $TmpDir 'starter.zip'
        Write-Log "Скачиваю starter pack..."
        Write-Log "  $ZipUrl"
        try {
            Invoke-WebRequest -Uri $ZipUrl -OutFile $ZipPath -UseBasicParsing
        } catch {
            Write-Err ""
            Write-Err "Не удалось скачать $ZipUrl"
            Write-Err "Проверь доступ в интернет и что репозиторий публичный."
            exit 1
        }
        Expand-Archive -Path $ZipPath -DestinationPath $TmpDir -Force
        Remove-Item $ZipPath -Force
    }

    $Extracted = Get-ChildItem -Path $TmpDir -Directory | Select-Object -First 1
    if ($null -eq $Extracted) {
        Write-Err "Не найдено распакованное содержимое в $TmpDir"
        exit 1
    }
    $ExtractedPath = $Extracted.FullName

    # ---------- 3. Скопировать ----------
    Write-Log "Копирую файлы в vault (.obsidian/ не затрагивается)..."
    Get-ChildItem -Path $ExtractedPath -Force | ForEach-Object {
        Copy-Item -Path $_.FullName -Destination $VaultDir -Recurse -Force
    }
}
finally {
    if (Test-Path $TmpDir) { Remove-Item $TmpDir -Recurse -Force -ErrorAction SilentlyContinue }
}

# ---------- 4. Проверить claude ----------
$ClaudeOk = $true
if (-not (Get-Command 'claude' -ErrorAction SilentlyContinue)) {
    Write-Warn ""
    Write-Warn "Команда 'claude' не найдена в PATH."
    Write-Warn "Установи Claude Code: https://claude.ai"
    Write-Warn ""
    $ClaudeOk = $false
}

# ---------- 5. Функция lifeos в PowerShell-профиль ----------
$ProfilePath = $PROFILE.CurrentUserAllHosts
$ProfileDir = Split-Path $ProfilePath -Parent
if (-not (Test-Path $ProfileDir)) {
    New-Item -ItemType Directory -Path $ProfileDir -Force | Out-Null
}
if (-not (Test-Path $ProfilePath)) {
    New-Item -ItemType File -Path $ProfilePath -Force | Out-Null
}

$ProfileContent = Get-Content -Path $ProfilePath -Raw -ErrorAction SilentlyContinue
if (-not $ProfileContent) { $ProfileContent = '' }

if ($ProfileContent -match 'function\s+lifeos') {
    Write-Log "Функция 'lifeos' уже есть в профиле PowerShell — не дублирую."
} else {
    $Addition = "`n# LifeOS`nfunction lifeos { Set-Location `"$VaultDir`"; claude }`n"
    Add-Content -Path $ProfilePath -Value $Addition
    Write-Log "Функция 'lifeos' добавлена в $ProfilePath"
    Write-Log "Для активации в текущей сессии: . `$PROFILE"
}

# ---------- 6. Запуск ----------
Write-Host ""
Write-Log "============================================="
Write-Log "Установка LifeOS завершена"
Write-Log "Vault: $VaultDir"
Write-Log "============================================="
Write-Host ""

if ($ClaudeOk) {
    Write-Log "Запускаю Claude Code — дальше AI поведёт тебя сам."
    Write-Host ""
    Set-Location $VaultDir
    & claude
} else {
    Write-Log "После установки Claude Code запусти вручную:"
    Write-Log "  cd `"$VaultDir`"; claude"
}
