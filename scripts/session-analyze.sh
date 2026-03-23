#!/bin/bash
# Session analyzer for Claude Code session tracking
# Usage: session-analyze.sh [logfile]
# If logfile is not specified, uses the most recent /tmp/claude-session-*.log
#
# Output (stdout): key=value session metrics
# Timestamp format in log: 2026-03-21T08:14:59+0800 (ISO 8601 with TZ offset)
# Backward compatible: 2026-03-21T08:14:59 (without TZ) also works

PAUSE_THRESHOLD=900  # 15 minutes in seconds

# --- Маппинг часовых поясов на локации ---
# Настройте под свои города. Добавляйте/удаляйте строки.
# Формат: UTC offset → название
tz_to_location() {
  case "$1" in
    +0000) echo "UTC" ;;
    +0300) echo "Москва (UTC+3)" ;;
    +0500) echo "UTC+5" ;;
    +0800) echo "UTC+8" ;;
    *)     echo "UTC$1" ;;
  esac
}

# --- Main ---

LOGFILE="$1"
if [ -z "$LOGFILE" ]; then
  LOGFILE=$(ls -t /tmp/claude-session-*.log 2>/dev/null | head -1)
fi

if [ -z "$LOGFILE" ] || [ ! -f "$LOGFILE" ]; then
  echo "error=no_log_file"
  exit 1
fi

# Read timestamps into array
TIMESTAMPS=()
while IFS= read -r line; do
  [ -n "$line" ] && TIMESTAMPS+=("$line")
done < "$LOGFILE"

COUNT=${#TIMESTAMPS[@]}

if [ "$COUNT" -eq 0 ]; then
  echo "error=empty_log"
  exit 1
fi

FIRST="${TIMESTAMPS[0]}"
LAST="${TIMESTAMPS[$((COUNT-1))]}"

# Convert to epoch (UTC)
# Supports both formats: with TZ (+0800) and without
# Uses Python for correct TZ offset parsing (macOS date -j doesn't understand %z)
to_epoch() {
  python3 -c "
import sys, re
from datetime import datetime, timezone, timedelta
ts = sys.argv[1]
m = re.match(r'(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})([+-]\d{4})?', ts)
if not m: sys.exit(1)
dt = datetime.strptime(m.group(1), '%Y-%m-%dT%H:%M:%S')
if m.group(2):
    sign = 1 if m.group(2)[0] == '+' else -1
    oh, om = int(m.group(2)[1:3]), int(m.group(2)[3:5])
    dt = dt.replace(tzinfo=timezone(timedelta(hours=sign*oh, minutes=sign*om)))
else:
    dt = dt.astimezone()  # assume local TZ
print(int(dt.timestamp()))
" "$1" 2>/dev/null
}

# Extract TZ offset from timestamp
extract_tz() {
  echo "$1" | grep -o '[+-][0-9]\{4\}$'
}

first_epoch=$(to_epoch "$FIRST")
last_epoch=$(to_epoch "$LAST")

if [ -z "$first_epoch" ] || [ -z "$last_epoch" ]; then
  echo "error=parse_failed"
  exit 1
fi

total_seconds=$((last_epoch - first_epoch))
active_seconds=0
pause_seconds=0
pause_count=0

# Collect unique TZ offsets (bash 3 compatible — no associative arrays)
tz_offsets=""
first_tz=$(extract_tz "$FIRST")
[ -n "$first_tz" ] && tz_offsets="$first_tz"

prev_epoch=$first_epoch
for ((i=1; i<COUNT; i++)); do
  cur_epoch=$(to_epoch "${TIMESTAMPS[$i]}")
  if [ -z "$cur_epoch" ]; then continue; fi

  cur_tz=$(extract_tz "${TIMESTAMPS[$i]}")
  if [ -n "$cur_tz" ] && ! echo "$tz_offsets" | grep -q "$cur_tz"; then
    tz_offsets="$tz_offsets $cur_tz"
  fi

  diff=$((cur_epoch - prev_epoch))
  if [ "$diff" -gt "$PAUSE_THRESHOLD" ]; then
    pause_seconds=$((pause_seconds + diff))
    pause_count=$((pause_count + 1))
  else
    active_seconds=$((active_seconds + diff))
  fi
  prev_epoch=$cur_epoch
done

# Format duration
format_duration() {
  local secs=$1
  if [ "$secs" -le 0 ]; then
    echo "<1мин"
    return
  fi
  local h=$((secs / 3600))
  local m=$(( (secs % 3600) / 60 ))
  if [ "$h" -gt 0 ]; then
    echo "${h}ч ${m}мин"
  else
    echo "${m}мин"
  fi
}

# Extract session_id from filename
SESSION_ID=$(basename "$LOGFILE" | sed 's/^claude-session-//;s/\.log$//')

# --- Location ---
tz_list=""
tz_count=0
for tz in $tz_offsets; do
  loc=$(tz_to_location "$tz")
  if [ -z "$tz_list" ]; then
    tz_list="$loc"
  else
    tz_list="$tz_list, $loc"
  fi
  tz_count=$((tz_count + 1))
done
# If no TZ recorded (old format without offset) — use current system TZ
if [ -z "$tz_list" ]; then
  sys_tz=$(date '+%z')
  tz_list="$(tz_to_location "$sys_tz") (system)"
  tz_count=1
fi

# --- Parallel sessions detection ---
parallel_ids=()
parallel_prompts=0

for other_log in /tmp/claude-session-*.log; do
  [ "$other_log" = "$LOGFILE" ] && continue
  [ ! -f "$other_log" ] && continue

  other_id=$(basename "$other_log" | sed 's/^claude-session-//;s/\.log$//')
  overlap=0

  while IFS= read -r ts; do
    [ -z "$ts" ] && continue
    ts_epoch=$(to_epoch "$ts")
    [ -z "$ts_epoch" ] && continue
    if [ "$ts_epoch" -ge "$first_epoch" ] && [ "$ts_epoch" -le "$last_epoch" ]; then
      overlap=$((overlap + 1))
    fi
  done < "$other_log"

  if [ "$overlap" -gt 0 ]; then
    parallel_ids+=("$other_id")
    parallel_prompts=$((parallel_prompts + overlap))
  fi
done

parallel_count=${#parallel_ids[@]}

# --- Output ---
echo "session_id=$SESSION_ID"
echo "session_start=$FIRST"
echo "session_end=$LAST"
echo "prompt_count=$COUNT"
echo "total_duration=$(format_duration $total_seconds)"
echo "active_time=$(format_duration $active_seconds)"
echo "pause_time=$(format_duration $pause_seconds)"
echo "pause_count=$pause_count"
echo "location=$tz_list"
if [ "$tz_count" -gt 1 ]; then
  echo "tz_changed=true"
fi
echo "parallel_sessions=$parallel_count"
if [ "$parallel_count" -gt 0 ]; then
  echo "parallel_prompts=$parallel_prompts"
  echo "parallel_ids=$(IFS=,; echo "${parallel_ids[*]}")"
fi
echo "logfile=$LOGFILE"
