#!/bin/bash
# cc-monitor — Claude Code status line: context window + subscription usage
#
# Shows: ctx size and % | 5h usage + reset timer | 7d usage | optional process and session id
# Requires: jq, curl

# --- Configuration (override via environment variables) ---
CACHE_TTL="${CC_MONITOR_CACHE_TTL:-180}"
BACKOFF_TTL="${CC_MONITOR_BACKOFF_TTL:-300}"
STATE_DIR="${CC_MONITOR_STATE_DIR:-/tmp/claude-monitor}"
NOTIFY_ENABLED="${CC_MONITOR_NOTIFY:-true}"
NOTIFY_START="${CC_MONITOR_NOTIFY_START:-50}"
PROCESS_NAME="${CC_MONITOR_PROCESS:-}"
SHOW_SESSION_ID="${CC_MONITOR_SESSION_ID:-false}"

# --- Install mode ---
if [[ "${1:-}" == "--install" ]]; then
  DEST="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/cc-monitor.sh"
  SETTINGS="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"

  cp "$0" "$DEST" && chmod +x "$DEST"
  echo "Installed to $DEST"
  echo ""

  if [ -f "$SETTINGS" ]; then
    if command -v jq &>/dev/null; then
      jq '.statusLine = {"type": "command", "command": "~/.claude/cc-monitor.sh"}' "$SETTINGS" > "$SETTINGS.tmp" \
        && mv "$SETTINGS.tmp" "$SETTINGS"
      echo "Updated $SETTINGS with statusLine config."
    else
      echo "Add to $SETTINGS manually:"
      echo '  "statusLine": { "type": "command", "command": "~/.claude/cc-monitor.sh" }'
    fi
  else
    echo "Add to $SETTINGS:"
    echo '  "statusLine": { "type": "command", "command": "~/.claude/cc-monitor.sh" }'
  fi
  exit 0
fi

# --- Dependency check ---
for dep in jq curl; do
  if ! command -v "$dep" &>/dev/null; then
    echo "$dep required"
    exit 0
  fi
done

# --- Init ---
mkdir -p "$STATE_DIR"
INPUT=$(cat)

CTX_STATE="$STATE_DIR/ctx-$PPID"
USAGE_CACHE="$STATE_DIR/usage-cache"
USAGE_NOTIFY="$STATE_DIR/usage-notify"

# Cleanup stale state files older than 24h (`-mtime +1` would mean older than two days)
find "$STATE_DIR" \( -name 'ctx-*' -o -name 'ctxk-*' \) -mmin +1440 -delete 2>/dev/null || true

# --- Context window ---
CTX=$(echo "$INPUT" | jq -r '.context_window.used_percentage // 0' 2>/dev/null | cut -d. -f1)
case "$CTX" in ''|*[!0-9]*) CTX=0 ;; esac   # empty or broken stdin must not break the arithmetic below
# Absolute size, not just the share of the window: on a 1M model 67% is 670k tokens, and every call
# re-reads all of them. current_usage is what goes into the next call; fallback is the share of the window.
CTX_TOK=$(echo "$INPUT" | jq -r '
  (.context_window.current_usage // {}) as $u
  | (($u.input_tokens // 0) + ($u.cache_creation_input_tokens // 0) + ($u.cache_read_input_tokens // 0)) as $t
  | if $t > 0 then $t
    else (((.context_window.used_percentage // 0) * (.context_window.context_window_size // 0)) / 100 | floor) end' 2>/dev/null)
case "$CTX_TOK" in ''|*[!0-9]*) CTX_TOK=0 ;; esac
CTX_K=$((CTX_TOK / 1000))
# Per-session token count, for other tools that summarize all running sessions
echo "$CTX_TOK" > "$STATE_DIR/ctxk-$PPID"

LAST_CTX=0
[ -f "$CTX_STATE" ] && LAST_CTX=$(cat "$CTX_STATE" 2>/dev/null || echo 0)

if [ "$CTX" -lt "$LAST_CTX" ] && [ "$((LAST_CTX - CTX))" -gt 10 ]; then
  LAST_CTX=0
fi

# --- OAuth token ---
get_token() {
  local creds
  if [[ "$OSTYPE" == darwin* ]]; then
    creds=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null)
  else
    local creds_file="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.credentials.json"
    [ -f "$creds_file" ] && creds=$(<"$creds_file")
  fi
  echo "${creds:-}" | jq -r '.claudeAiOauth.accessToken // empty'
}

# --- Subscription usage (cached) ---
FIVE_H="?"
SEVEN_D="?"
FIVE_RESET=""

fetch_usage() {
  local backoff_file="$STATE_DIR/backoff-until"
  if [ -f "$backoff_file" ]; then
    local blocked_until
    blocked_until=$(cat "$backoff_file" 2>/dev/null || echo 0)
    if [ "$(date +%s)" -lt "$blocked_until" ]; then
      return 1
    fi
    rm -f "$backoff_file"
  fi

  local token
  token=$(get_token)
  [ -z "$token" ] && return 1
  # Unique temp names per call: the status line renders in many sessions at once, and a shared
  # temp file let two curls interleave, leaving a truncated JSON in the cache.
  local tmp hdr http_code retry_after
  tmp=$(mktemp "$USAGE_CACHE.XXXXXX") || return 1
  hdr="$tmp.h"
  # The token goes through a config on stdin, not -H: argv is visible in `ps` to any user process,
  # including an agent whose `ps aux` ends up in its transcript.
  http_code=$(printf 'header = "Authorization: Bearer %s"\n' "$token" | curl -sS --config - \
    --max-time 5 -w '%{http_code}' -o "$tmp" -D "$hdr" \
    -H "anthropic-beta: oauth-2025-04-20" \
    "https://api.anthropic.com/api/oauth/usage" 2>/dev/null)

  if [ "$http_code" = "200" ] && jq -e '.five_hour.utilization // .seven_day.utilization' "$tmp" >/dev/null 2>&1; then
    mv "$tmp" "$USAGE_CACHE"
    rm -f "$backoff_file" "$hdr"
  elif [ "$http_code" = "429" ]; then
    # Parse Retry-After header, fallback to BACKOFF_TTL
    retry_after=$(grep -i 'retry-after' "$hdr" 2>/dev/null | tr -d '\r' | awk '{print $2}')
    if [ -n "$retry_after" ] && [ "$retry_after" -gt 0 ] 2>/dev/null; then
      echo "$(( $(date +%s) + retry_after ))" > "$backoff_file"
    else
      echo "$(( $(date +%s) + BACKOFF_TTL ))" > "$backoff_file"
    fi
    rm -f "$tmp" "$hdr"
  else
    rm -f "$tmp" "$hdr"
  fi
}

cache_age() {
  if [[ "$OSTYPE" == darwin* ]]; then
    /usr/bin/stat -f%m "$1" 2>/dev/null || echo 0
  else
    stat -c%Y "$1" 2>/dev/null || echo 0
  fi
}

if [ -f "$USAGE_CACHE" ]; then
  AGE=$(( $(date +%s) - $(cache_age "$USAGE_CACHE") ))
  if [ "$AGE" -gt "$CACHE_TTL" ]; then
    fetch_usage &
  fi
else
  fetch_usage || true
fi

# Parse cache (stale data is better than no data)
if [ -f "$USAGE_CACHE" ]; then
  FIVE_H=$(jq -r '.five_hour.utilization // 0' "$USAGE_CACHE" | cut -d. -f1)
  SEVEN_D=$(jq -r '.seven_day.utilization // 0' "$USAGE_CACHE" | cut -d. -f1)

  # Reset timer: time until 5h window resets. Parsed by jq, not date: stock macOS date has no -d,
  # and BSD `date -j -f` reads the UTC timestamp as local time.
  reset_epoch=$(jq -r '.five_hour.resets_at // empty
    | sub("\\.[0-9]+"; "") | sub("(\\+00:00|Z)$"; "Z") | fromdateiso8601' "$USAGE_CACHE" 2>/dev/null)
  case "$reset_epoch" in ''|*[!0-9]*) reset_epoch=0 ;; esac
  remaining=$((reset_epoch - $(date +%s)))
  if [ "$reset_epoch" -gt 0 ] && [ "$remaining" -gt 0 ]; then
    hours=$((remaining / 3600))
    mins=$(( (remaining % 3600) / 60 ))
    if [ "$hours" -gt 0 ]; then
      FIVE_RESET="${hours}h${mins}m"
    else
      FIVE_RESET="${mins}m"
    fi
  fi
fi

# --- Notifications ---
send_notification() {
  local title="$1" subtitle="$2" body="$3"
  if [[ "$OSTYPE" == darwin* ]]; then
    local sound="Pop"
    [[ "$subtitle" == "CRITICAL" ]] && sound="Basso"
    [[ "$subtitle" == "Warning" ]] && sound="Ping"
    osascript -e "display notification \"$body\" with title \"$title\" subtitle \"$subtitle\" sound name \"$sound\"" 2>/dev/null &
  elif command -v notify-send &>/dev/null; then
    local urgency="normal"
    [[ "$subtitle" == "CRITICAL" ]] && urgency="critical"
    [[ "$subtitle" == "Warning" ]] && urgency="critical"
    notify-send -u "$urgency" "$title" "$subtitle: $body" 2>/dev/null &
  fi
}

notify() {
  if [[ "$NOTIFY_ENABLED" != "true" ]]; then return; fi

  local label="$1" pct="$2" last="$3"
  local thresholds="$NOTIFY_START"

  local t=$((NOTIFY_START + 10))
  while [ "$t" -le 90 ]; do
    thresholds="$thresholds $t"
    t=$((t + 10))
  done
  for t in 91 92 93 94 95 96 97 98 99; do
    thresholds="$thresholds $t"
  done

  for t in $thresholds; do
    if [ "$pct" -ge "$t" ] && [ "$last" -lt "$t" ]; then
      local subtitle="Info"
      [ "$t" -ge 90 ] && subtitle="Warning"
      [ "$t" -ge 95 ] && subtitle="CRITICAL"
      send_notification "Claude Code" "$subtitle" "${label}: ${pct}%"
      break
    fi
  done
}

# Context notifications
notify "Context" "$CTX" "$LAST_CTX"

# 5h window notifications
LAST_5H=0
[ -f "$USAGE_NOTIFY" ] && LAST_5H=$(cat "$USAGE_NOTIFY" 2>/dev/null || echo 0)
if [ "$FIVE_H" != "?" ]; then
  if [ "$FIVE_H" -lt "$LAST_5H" ] && [ "$((LAST_5H - FIVE_H))" -gt 20 ]; then
    LAST_5H=0
  fi
  notify "5h limit" "$FIVE_H" "$LAST_5H"
  echo "$FIVE_H" > "$USAGE_NOTIFY"
fi

echo "$CTX" > "$CTX_STATE"

# --- Process monitor ---
PROC_STATUS=""
if [ -n "$PROCESS_NAME" ]; then
  proc_count=$(pgrep -f "$PROCESS_NAME" 2>/dev/null | wc -l | tr -d ' ')
  if [ "$proc_count" -gt 0 ]; then
    PROC_STATUS=" | ${PROCESS_NAME}:${proc_count}"
  fi
fi

# --- Session id ---
# Full id, not a prefix: `claude --resume` and transcript file names need all of it
SID_STATUS=""
if [[ "$SHOW_SESSION_ID" == "true" ]]; then
  SID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
  [ -n "$SID" ] && SID_STATUS=" | ${SID}"
fi

# --- Status line output ---
pick_icon() {
  local p=$1
  if [ "$p" -ge 95 ]; then echo "🔴"
  elif [ "$p" -ge 90 ]; then echo "🟠"
  elif [ "$p" -ge 70 ]; then echo "🟡"
  elif [ "$p" -ge 50 ]; then echo "🔵"
  else echo "🟢"
  fi
}

# Context icon: by absolute size (100k/200k/300k/500k) or by share of the window, whichever is worse
sev_pct() { if [ "$1" -ge 95 ]; then echo 4; elif [ "$1" -ge 90 ]; then echo 3; elif [ "$1" -ge 70 ]; then echo 2; elif [ "$1" -ge 50 ]; then echo 1; else echo 0; fi; }
sev_tok() { if [ "$1" -ge 500 ]; then echo 4; elif [ "$1" -ge 300 ]; then echo 3; elif [ "$1" -ge 200 ]; then echo 2; elif [ "$1" -ge 100 ]; then echo 1; else echo 0; fi; }
sev_icon() { case "$1" in 4) echo "🔴" ;; 3) echo "🟠" ;; 2) echo "🟡" ;; 1) echo "🔵" ;; *) echo "🟢" ;; esac; }
S1=$(sev_pct "$CTX"); S2=$(sev_tok "$CTX_K")
CTX_ICON=$(sev_icon $(( S1 > S2 ? S1 : S2 )))
CTX_LABEL="ctx:${CTX}%"
[ "$CTX_TOK" -gt 0 ] && CTX_LABEL="ctx:${CTX_K}k ${CTX}%"

if [ "$FIVE_H" != "?" ]; then
  FIVE_ICON=$(pick_icon "$FIVE_H")
  SEVEN_ICON=$(pick_icon "$SEVEN_D")

  OUT="${CTX_ICON} ${CTX_LABEL}"
  OUT+=" ${FIVE_ICON} 5h:${FIVE_H}%"
  if [ -n "$FIVE_RESET" ]; then
    OUT+=" ~${FIVE_RESET}"
  fi
  OUT+=" ${SEVEN_ICON} 7d:${SEVEN_D}%"
  OUT+="${PROC_STATUS}${SID_STATUS}"

  echo "$OUT"
else
  echo "${CTX_ICON} ${CTX_LABEL}${PROC_STATUS}${SID_STATUS}"
fi
