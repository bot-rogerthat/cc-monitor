# Changelog

## v0.2.0 - 2026-09-24

### Added

- Context size in tokens next to the percentage (`ctx:142k 14%`); the icon follows whichever is worse.
- Optional full session id at the end of the line (`CC_MONITOR_SESSION_ID=true`).
- Per-process `ctxk-<pid>` state file with the current context size in tokens.
- Black-box tests with stubbed `curl` and notifiers, `Makefile`, CI on Linux and macOS.

### Fixed

- 5-hour reset timer was missing on stock macOS: `date -d` does not exist there and `/usr/bin/date` is not a real path. The timestamp is now parsed by `jq`.
- Concurrent sessions could leave a truncated usage cache: each fetch now uses its own temp files.
- The OAuth token was visible in `ps` as a `curl -H` argument; it is now passed through a config on stdin.
- Empty or broken stdin broke the arithmetic and printed shell errors instead of a status line.
- Stale state files were kept for two days instead of one.

## v0.1.0 - 2026-04-04

First public version: context percentage, 5-hour and 7-day usage with reset timer, threshold notifications on macOS and Linux, HTTP 429 backoff with `Retry-After`, process monitor (`CC_MONITOR_PROCESS`).
