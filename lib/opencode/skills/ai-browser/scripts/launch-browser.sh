#!/usr/bin/env bash
# Idempotently launch a CDP-enabled headed browser (Chromium or Firefox).
# Usage: launch-browser.sh [port]
# Honors AI_BROWSER_CMD, AI_BROWSER_CHROMIUM_CMD, AI_BROWSER_CDP_PORT.
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

BROWSER="${AI_BROWSER_CMD:-${AI_BROWSER_CHROMIUM_CMD:-}}"
if [ -z "$BROWSER" ]; then
  for candidate in firefox chromium chromium-browser google-chrome-stable google-chrome chrome; do
    if command -v "$candidate" >/dev/null 2>&1; then
      BROWSER="$(command -v "$candidate")"
      break
    fi
  done
fi
if [ -z "$BROWSER" ]; then
  echo "error: no browser found; set AI_BROWSER_CMD or AI_BROWSER_CHROMIUM_CMD" >&2
  exit 1
fi

# Detect browser type from the command name.
case "$(basename "$BROWSER")" in
  *firefox*) IS_FIREFOX=1 ;;
  *) IS_FIREFOX=0 ;;
esac

PROFILE="$(mktemp -d /tmp/ai-browser-profile.XXXXXX)"
LOG="$(mktemp /tmp/ai-browser-browser.XXXXXX.log)"

# Headed mode needs something to draw on — but only on Linux.
# macOS uses its own windowing system and never requires DISPLAY / WAYLAND_DISPLAY.
if [ "$(uname -s)" = "Linux" ] && [ -z "${DISPLAY:-}" ] && [ -z "${WAYLAND_DISPLAY:-}" ]; then
  echo "error: headed browser on Linux needs a display; set DISPLAY or WAYLAND_DISPLAY" >&2
  exit 1
fi

# setsid + </dev/null + redirects: fully detach so shell-tool timeouts
# cannot kill the browser's process group.
if [ "$IS_FIREFOX" = "1" ]; then
  setsid "$BROWSER" \
    --remote-debugging-port "$PORT" \
    -profile "$PROFILE" \
    about:blank </dev/null >>"$LOG" 2>&1 &
else
  setsid "$BROWSER" \
    --remote-debugging-port="$PORT" \
    --user-data-dir="$PROFILE" \
    --no-first-run \
    --no-default-browser-check \
    --disable-gpu \
    about:blank </dev/null >>"$LOG" 2>&1 &
fi

for _ in $(seq 1 50); do
  if up; then
    echo "ready on :${PORT}"
    exit 0
  fi
  sleep 0.2
done

echo "error: browser did not come up on :${PORT}; log: $LOG" >&2
exit 1
