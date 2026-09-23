# cc-monitor - a Claude Code status line for context and subscription limits

[![Build Status](https://github.com/bot-rogerthat/cc-monitor/workflows/build/badge.svg)](https://github.com/bot-rogerthat/cc-monitor/actions) [![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

`cc-monitor` is a status line for [Claude Code](https://github.com/anthropics/claude-code). It shows how big the current context is, how much of the 5-hour and 7-day subscription windows is used, and when the 5-hour window resets. It is a single bash script that needs only `jq` and `curl`.

```
🟢 ctx:142k 14% 🟡 5h:73% ~1h12m 🟢 7d:34% | 3f2a1b9c-0000-4000-8000-123456789abc
```

The session id at the end is optional (`CC_MONITOR_SESSION_ID=true`); everything else is on by default.

The motivation is specific: when you run several long sessions at once, the limits run out faster than you notice, and a 1M-token context grows quietly until every call re-reads hundreds of thousands of tokens. The built-in UI tells you about neither until it is too late. `cc-monitor` keeps both numbers in front of you and sends a desktop notification as they cross thresholds.

What it does:

- **Context size, not just a percentage.** On a 1M-token model 14% is already 140k tokens, and every call re-reads all of them. The line shows both, and the icon turns yellow or red by whichever is worse.
- **Subscription usage.** The 5-hour and 7-day subscription windows, with a countdown to the 5-hour reset.
- **Notifications.** Native macOS or `notify-send` notifications at 50%, every 10% after that, and every 1% after 90%, with the sound escalating near the limit.
- **Session id.** Optionally shows the full session id, so you can refer to a session by its id or pass it to `claude --resume`.
- **Process monitor.** Optionally shows how many copies of a given process are running, for example a background agent.
- **Cheap and safe to run everywhere.** The usage response is cached and shared by all sessions, HTTP 429 is honoured with `Retry-After`, and the OAuth token never appears in the process list.

## Install

```sh
git clone https://github.com/bot-rogerthat/cc-monitor.git
cd cc-monitor
./cc-monitor.sh --install
```

`--install` copies the script to `~/.claude/cc-monitor.sh` and sets `statusLine` in `~/.claude/settings.json`. To do it by hand, copy the script and add:

```json
{
  "statusLine": {
    "type": "command",
    "command": "~/.claude/cc-monitor.sh"
  }
}
```

The new line shows up on the next status line refresh; no restart is needed.

### Requirements

- `bash`, `jq`, `curl`
- A Claude subscription login (`claude auth login`). The token is read from the macOS Keychain, or from `~/.claude/.credentials.json` on Linux.
- Linux notifications (optional): `notify-send` from `libnotify`.

## What it shows

| Part | Source | Meaning |
|------|--------|---------|
| `ctx:142k 14%` | stdin JSON | Tokens the next call will send, and the share of the context window |
| `5h:73%` | Anthropic API | 5-hour rolling window usage |
| `~1h12m` | Anthropic API | Time until the 5-hour window resets |
| `7d:34%` | Anthropic API | 7-day rolling window usage |
| `\| ralphex:3` | `pgrep` | Running copies of `CC_MONITOR_PROCESS`, shown only when there are any |
| `\| 3f2a1b9c-…` | stdin JSON | Session id, shown when `CC_MONITOR_SESSION_ID=true` |

When the usage endpoint is unreachable, the line falls back to the context part alone.

### Icons

For `5h` and `7d` the icon follows the percentage. For `ctx` it follows the percentage or the absolute size, whichever is worse.

| Icon | Percentage | Context size |
|------|------------|--------------|
| 🟢 | 0-49% | under 100k |
| 🔵 | 50-69% | 100k+ |
| 🟡 | 70-89% | 200k+ |
| 🟠 | 90-94% | 300k+ |
| 🔴 | 95-100% | 500k+ |

### Notifications

Notifications fire for `ctx` and `5h` at **50%**, then every **10%** (60, 70, 80, 90), then every **1%** from 91 to 99. Each threshold fires once; a drop of more than 10 points for `ctx` (after `/compact` or `/clear`) or 20 points for `5h` (after a reset) re-arms them.

| Range | macOS sound | Linux urgency |
|-------|-------------|---------------|
| 50-89% | Pop | normal |
| 90-94% | Ping | critical |
| 95-99% | Basso | critical |

## Configuration

Everything is set through environment variables in the `statusLine` command:

| Variable | Default | Description |
|----------|---------|-------------|
| `CC_MONITOR_CACHE_TTL` | `180` | Seconds between usage API calls |
| `CC_MONITOR_BACKOFF_TTL` | `300` | Seconds to wait after HTTP 429 without `Retry-After` |
| `CC_MONITOR_STATE_DIR` | `/tmp/claude-monitor` | Cache and state files |
| `CC_MONITOR_NOTIFY` | `true` | Desktop notifications on or off |
| `CC_MONITOR_NOTIFY_START` | `50` | First notification threshold, % |
| `CC_MONITOR_PROCESS` | *(empty)* | Process to count with `pgrep -f` |
| `CC_MONITOR_SESSION_ID` | `false` | Append the full session id |

For example, session id on and notifications off:

```json
{
  "statusLine": {
    "type": "command",
    "command": "CC_MONITOR_SESSION_ID=true CC_MONITOR_NOTIFY=false ~/.claude/cc-monitor.sh"
  }
}
```

```
🟢 ctx:142k 14% 🟡 5h:73% ~1h12m 🟢 7d:34% | 3f2a1b9c-0000-4000-8000-123456789abc
```

## How it works

Claude Code runs the script on every status line refresh and passes the session JSON on stdin. Context size and the session id come from that JSON.

Subscription usage comes from `api.anthropic.com/api/oauth/usage`, authorized with your Claude Code OAuth token. The response is cached in `CC_MONITOR_STATE_DIR` for `CC_MONITOR_CACHE_TTL` seconds and shared by all sessions. A stale cache is refreshed in the background, so the line never waits on the network, and stale data is shown until the new one arrives. On HTTP 429 the script stops calling the API for `Retry-After` seconds, or `CC_MONITOR_BACKOFF_TTL` without the header.

The token is passed to `curl` through a config on stdin rather than a `-H` argument, because command-line arguments are visible in `ps` to every process of the user, including an agent that lists processes.

State files:

| File | Content |
|------|---------|
| `usage-cache` | Last good usage response |
| `backoff-until` | Epoch until which the API is not called |
| `usage-notify` | Last notified `5h` value |
| `ctx-<pid>` | Last notified `ctx` percentage for one Claude Code process |
| `ctxk-<pid>` | Current context size in tokens for one process, for tools that summarize all sessions |

Per-process files are removed after 24 hours.

## Development

```sh
make        # shellcheck + tests
make lint
make test
```

The tests in `tests/run.sh` run the script as a black box. `curl`, `security`, `osascript` and `notify-send` are replaced with stubs, so the tests need no network and no credentials. CI runs them on Linux and macOS.

See [CONTRIBUTING.md](CONTRIBUTING.md) and [CHANGELOG.md](CHANGELOG.md).

## License

[MIT](LICENSE)
