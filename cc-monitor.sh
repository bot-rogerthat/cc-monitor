#!/bin/bash
# cc-monitor — Claude Code status line: context window + subscription usage
#
# Shows: ctx% | 5h% | 7d% with color-coded icons and macOS/Linux notifications
# Requires: jq, curl

# --- Configuration (override via environment variables) ---
CACHE_TTL="${CC_MONITOR_CACHE_TTL:-60}"
STATE_DIR="${CC_MONITOR_STATE_DIR:-/tmp/claude-monitor}"
NOTIFY_ENABLED="${CC_MONITOR_NOTIFY:-true}"
NOTIFY_START="${CC_MONITOR_NOTIFY_START:-50}"

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

CTX_STATE="$STATE_DIR/ctx-$$"
USAGE_CACHE="$STATE_DIR/usage-cache"
USAGE_NOTIFY="$STATE_DIR/usage-notify-$$"

# Cleanup stale state files (older than 24h)
find "$STATE_DIR" -name 'ctx-*' -mtime +1 -delete 2>/dev/null || true
find "$STATE_DIR" -name 'usage-notify-*' -mtime +1 -delete 2>/dev/null || true

# --- Context window ---
CTX=$(echo "$INPUT" | jq -r '.context_window.used_percentage // 0' | cut -d. -f1)

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

fetch_usage() {
  local token
  token=$(get_token)
  [ -z "$token" ] && return 1
  local http_code
  http_code=$(curl -s --max-time 5 -w '%{http_code}' -o "$USAGE_CACHE.tmp" \
    -H "Authorization: Bearer $token" \
    -H "anthropic-beta: oauth-2025-04-20" \
    "https://api.anthropic.com/api/oauth/usage" 2>/dev/null)
  # Accept only HTTP 200 with valid JSON containing utilization data
  if [ "$http_code" = "200" ] && jq -e '.five_hour.utilization // .seven_day.utilization' "$USAGE_CACHE.tmp" >/dev/null 2>&1; then
    mv "$USAGE_CACHE.tmp" "$USAGE_CACHE"
  else
    rm -f "$USAGE_CACHE.tmp"
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
  # First run: fetch synchronously so we have data to show
  fetch_usage || true
fi

if [ -f "$USAGE_CACHE" ]; then
  FIVE_H=$(jq -r '.five_hour.utilization // 0' "$USAGE_CACHE" | cut -d. -f1)
  SEVEN_D=$(jq -r '.seven_day.utilization // 0' "$USAGE_CACHE" | cut -d. -f1)
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

  # Add thresholds: every 10% from start+10 to 90, then every 1% from 91
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

CTX_ICON=$(pick_icon "$CTX")
if [ "$FIVE_H" != "?" ]; then
  FIVE_ICON=$(pick_icon "$FIVE_H")
  SEVEN_ICON=$(pick_icon "$SEVEN_D")
  echo "${CTX_ICON} ctx:${CTX}% ${FIVE_ICON} 5h:${FIVE_H}% ${SEVEN_ICON} 7d:${SEVEN_D}%"
else
  echo "${CTX_ICON} ctx:${CTX}%"
fi
