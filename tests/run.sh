#!/bin/bash
# Black-box tests for cc-monitor.sh. No network: curl, security, osascript and notify-send are
# replaced by stubs on PATH, and every case runs against its own state dir.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/cc-monitor.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0

# --- Stubs ---
STUBS="$WORK/stubs"
mkdir -p "$STUBS"

# curl: records its argv, answers with $FAKE_HTTP_CODE, $FAKE_BODY and optional $FAKE_RETRY_AFTER
cat > "$STUBS/curl" <<'EOF'
#!/bin/bash
printf '%s\n' "$@" > "$FAKE_LOG/curl-argv"
cat > "$FAKE_LOG/curl-stdin"
out="" hdr=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift ;;
    -D) hdr="$2"; shift ;;
  esac
  shift
done
[ -n "$out" ] && printf '%s' "${FAKE_BODY:-}" > "$out"
if [ -n "$hdr" ]; then
  printf 'HTTP/2 %s\r\n' "${FAKE_HTTP_CODE:-200}" > "$hdr"
  [ -n "${FAKE_RETRY_AFTER:-}" ] && printf 'retry-after: %s\r\n' "$FAKE_RETRY_AFTER" >> "$hdr"
fi
printf '%s' "${FAKE_HTTP_CODE:-200}"
EOF

cat > "$STUBS/security" <<'EOF'
#!/bin/bash
echo '{"claudeAiOauth":{"accessToken":"test-token-123"}}'
EOF

for n in osascript notify-send; do
  cat > "$STUBS/$n" <<'EOF'
#!/bin/bash
echo "$*" >> "$FAKE_LOG/notifications"
EOF
done
chmod +x "$STUBS"/*

# Linux reads credentials from a file instead of the Keychain
CONFIG_DIR="$WORK/config"
mkdir -p "$CONFIG_DIR"
echo '{"claudeAiOauth":{"accessToken":"test-token-123"}}' > "$CONFIG_DIR/.credentials.json"

# --- Helpers ---
# run <stdin-json> [VAR=value ...] — runs the script in a fresh state dir, output in $OUT
run() {
  local input="$1"; shift
  CASE_DIR="$(mktemp -d "$WORK/case.XXXXXX")"
  mkdir -p "$CASE_DIR/log"
  OUT=$(echo "$input" | env PATH="$STUBS:$PATH" \
    CLAUDE_CONFIG_DIR="$CONFIG_DIR" \
    CC_MONITOR_STATE_DIR="$CASE_DIR/state" \
    CC_MONITOR_NOTIFY=false \
    FAKE_LOG="$CASE_DIR/log" \
    "$@" bash "$SCRIPT")
}

usage_body() {
  local five="$1" seven="$2" resets_in="$3"
  jq -nc --argjson f "$five" --argjson s "$seven" --argjson r "$(( $(date +%s) + resets_in ))" \
    '{five_hour: {utilization: $f, resets_at: ($r | todate | sub("Z$"; ".123456+00:00"))},
      seven_day: {utilization: $s}}'
}

check() {
  local name="$1" expected="$2" actual="$3"
  if [ "$expected" == "$actual" ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL %s\n  expected: %s\n  actual:   %s\n' "$name" "$expected" "$actual"
  fi
}

check_match() {
  local name="$1" pattern="$2" actual="$3"
  if [[ "$actual" =~ $pattern ]]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL %s\n  pattern: %s\n  actual:  %s\n' "$name" "$pattern" "$actual"
  fi
}

CTX_12='{"session_id":"3f2a1b9c-0000-4000-8000-123456789abc","context_window":{"used_percentage":12.4,"context_window_size":200000}}'

# --- Cases ---

run "$CTX_12" FAKE_HTTP_CODE=200 FAKE_BODY="$(usage_body 47.2 72 4380)"
check_match "shows context, 5h with reset timer and 7d" \
  '^🟢 ctx:24k 12% 🟢 5h:47% ~1h(12|13)m 🟡 7d:72%$' "$OUT"

run "$CTX_12" FAKE_HTTP_CODE=200 FAKE_BODY="$(usage_body 10 10 600)"
check_match "reset timer under an hour shows minutes only" '~(9|10)m ' "$OUT"

run "$CTX_12" FAKE_HTTP_CODE=500 FAKE_BODY='oops'
check "falls back to context only when usage is unavailable" "🟢 ctx:24k 12%" "$OUT"

run "$CTX_12" FAKE_HTTP_CODE=429 FAKE_RETRY_AFTER=120
check "hides usage on 429" "🟢 ctx:24k 12%" "$OUT"
until_ts=$(cat "$CASE_DIR/state/backoff-until" 2>/dev/null || echo 0)
delta=$(( until_ts - $(date +%s) ))
check_match "honours Retry-After on 429" '^1(1[5-9]|20)$' "$delta"

run "$CTX_12" FAKE_HTTP_CODE=200 FAKE_BODY="$(usage_body 1 1 600)"
check "keeps the token out of curl argv" "" "$(grep -c test-token-123 "$CASE_DIR/log/curl-argv" | grep -v '^0$')"
check_match "passes the token via curl config on stdin" 'Bearer test-token-123' "$(cat "$CASE_DIR/log/curl-stdin")"

run "$CTX_12" FAKE_HTTP_CODE=500
check_match "hides session id by default" '^[^|]*$' "$OUT"

run "$CTX_12" FAKE_HTTP_CODE=500 CC_MONITOR_SESSION_ID=true
check "shows full session id when enabled" "🟢 ctx:24k 12% | 3f2a1b9c-0000-4000-8000-123456789abc" "$OUT"

run 'not json' FAKE_HTTP_CODE=500
check "survives broken stdin" "🟢 ctx:0%" "$OUT"

run '{"context_window":{"used_percentage":35,"current_usage":{"input_tokens":1000,"cache_creation_input_tokens":9000,"cache_read_input_tokens":340000}}}' FAKE_HTTP_CODE=500
check "colours context by absolute size when it is worse than the share" "🟠 ctx:350k 35%" "$OUT"

run '{"context_window":{"used_percentage":55,"context_window_size":200000}}' FAKE_HTTP_CODE=500 CC_MONITOR_NOTIFY=true
sleep 0.2   # notifications are sent in the background
check_match "notifies when context crosses 50%" 'Context: 55%' "$(cat "$CASE_DIR/log/notifications" 2>/dev/null)"

sleep 30 &
SLEEPER=$!
run "$CTX_12" FAKE_HTTP_CODE=500 CC_MONITOR_PROCESS="sleep 30"
kill "$SLEEPER" 2>/dev/null
wait "$SLEEPER" 2>/dev/null
check_match "shows monitored process count" '\| sleep 30:[0-9]+$' "$OUT"

echo ""
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
