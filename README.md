# cc-monitor

Lightweight Claude Code status line monitor. Shows context window, 5-hour and 7-day subscription usage with threshold notifications. Single bash script, requires only `jq` and `curl`.

```
🟢 ctx:12% 🟢 5h:41% 🟡 7d:72%
```

## Install

```bash
git clone https://github.com/bot-rogerthat/cc-monitor.git
cd cc-monitor
./cc-monitor.sh --install
```

Or manually add to `~/.claude/settings.json`:

```json
{
  "statusLine": {
    "type": "command",
    "command": "~/.claude/cc-monitor.sh"
  }
}
```

## Requirements

- `jq`
- `curl`
- macOS: credentials from Keychain (automatic after `claude auth login`)
- Linux: credentials from `~/.claude/.credentials.json` (automatic after `claude auth login`)
- Linux notifications (optional): `notify-send` (`libnotify`)

## How it works

Claude Code calls the script periodically, passing session JSON on stdin. The script extracts context window usage from that JSON. For subscription limits (5-hour and 7-day windows), it queries `api.anthropic.com/api/oauth/usage` using your OAuth token and caches the response for 30 seconds.

When usage crosses a threshold, a native OS notification is sent (macOS: Notification Center with sound, Linux: `notify-send`).

## What it shows

| Metric | Source | Description |
|--------|--------|-------------|
| `ctx` | stdin JSON | Context window usage (current session) |
| `5h` | Anthropic API | 5-hour rolling window (resets every 5h) |
| `7d` | Anthropic API | 7-day rolling window (weekly limit) |

## Icons

| Icon | Range |
|------|-------|
| 🟢 | 0-49% |
| 🔵 | 50-69% |
| 🟡 | 70-89% |
| 🟠 | 90-94% |
| 🔴 | 95-100% |

## Notifications

Threshold notifications are sent at: **50%**, then every **10%** (60, 70, 80, 90), then every **1%** after 90 (91, 92, ...99).

Notifications fire for `ctx` and `5h` metrics. Sound escalates with severity:

| Range | macOS sound | Linux urgency |
|-------|-------------|---------------|
| 50-89% | Pop | normal |
| 90-94% | Ping | critical |
| 95-99% | Basso | critical |

## Configuration

Override via environment variables:

| Variable | Default | Description |
|----------|---------|-------------|
| `CC_MONITOR_CACHE_TTL` | `60` | Seconds between API calls |
| `CC_MONITOR_STATE_DIR` | `/tmp/claude-monitor` | State file location |
| `CC_MONITOR_NOTIFY` | `true` | Enable/disable notifications |
| `CC_MONITOR_NOTIFY_START` | `50` | Minimum % to start notifying |

Example — disable notifications and cache for 60s:

```bash
CC_MONITOR_NOTIFY=false CC_MONITOR_CACHE_TTL=60 ~/.claude/cc-monitor.sh
```

In `settings.json`:

```json
{
  "statusLine": {
    "type": "command",
    "command": "CC_MONITOR_CACHE_TTL=60 ~/.claude/cc-monitor.sh"
  }
}
```

## License

MIT
