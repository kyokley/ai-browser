#!/usr/bin/env bash
# Idempotently launch a CDP-enabled headed Chromium.
# Usage: launch-browser.sh [port]
# Honors AI_BROWSER_CHROMIUM_CMD, AI_BROWSER_CDP_PORT.
set -euo pipefail

PORT="${1:-${AI_BROWSER_CDP_PORT:-9222}}"
HTTP="http://127.0.0.1:${PORT}"

up() {
  curl -sf --max-time 1 "${HTTP}/json/version" >/dev/null 2>&1
}

if up; then
  echo "already running on :${PORT}"
  exit 0
fi

CHROMIUM="${AI_BROWSER_CHROMIUM_CMD:-}"
if [ -z "$CHROMIUM" ]; then
  for candidate in chromium chromium-browser google-chrome-stable google-chrome chrome; do
    if command -v "$candidate" >/dev/null 2>&1; then
      CHROMIUM="$(command -v "$candidate")"
      break
    fi
  done
fi
if [ -z "$CHROMIUM" ]; then
  echo "error: no chromium found; set AI_BROWSER_CHROMIUM_CMD" >&2
  exit 1
fi

PROFILE="$(mktemp -d /tmp/ai-browser-profile.XXXXXX)"
LOG="$(mktemp /tmp/ai-browser-chromium.XXXXXX.log)"

# Headed mode needs something to draw on.
if [ -z "${DISPLAY:-}" ] && [ -z "${WAYLAND_DISPLAY:-}" ]; then
  echo "error: headed chromium needs a display; set DISPLAY or WAYLAND_DISPLAY" >&2
  exit 1
fi

# setsid + </dev/null + redirects: fully detach so shell-tool timeouts
# cannot kill the browser's process group.
setsid "$CHROMIUM" \
  --remote-debugging-port="$PORT" \
  --user-data-dir="$PROFILE" \
  --no-first-run \
  --no-default-browser-check \
  --disable-gpu \
  about:blank </dev/null >>"$LOG" 2>&1 &

for _ in $(seq 1 50); do
  if up; then
    echo "ready on :${PORT}"
    exit 0
  fi
  sleep 0.2
done

echo "error: chromium did not come up on :${PORT}; log: $LOG" >&2
exit 1
