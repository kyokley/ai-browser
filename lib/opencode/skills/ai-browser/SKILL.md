---
name: ai-browser
description: Drive a real Chromium browser over the Chrome DevTools Protocol (CDP) for any web task — opening URLs, scraping rendered content, taking screenshots, evaluating JavaScript, and smoke-testing web apps. Use this skill whenever the user asks to open, browse, or visit a URL; scrape or extract a page's content; screenshot or render a site; check what a JS-heavy page actually displays; automate a browser; or test a local web server. Prefer it even when the user doesn't say "browser" and even when curl might seem enough, because a real browser executes JavaScript, handles cookies, and sees the rendered DOM. Uses $AI_BROWSER_CMD / $AI_BROWSER_PYTHON_CMD when set (the opencode-wrapped environment), otherwise falls back to any installed chromium/chrome and python3. Firefox can be automated via WebDriver BiDi (connect to ws://127.0.0.1:PORT/session with the websockets package, send session.new, then BiDi commands). The bundled cdp.py only works with Chromium — see the Connecting via WebDriver BiDi section for Firefox.
---

# ai-browser — drive a browser over CDP

> **Firefox:** Chromium uses CDP; Firefox uses the **WebDriver BiDi** protocol
> (or the legacy Marionette protocol via geckodriver). The bundled `cdp.py`
> commands speak CDP wire protocol and only work with Chromium. For Firefox
> automation, connect to `ws://127.0.0.1:PORT/session` via the `websockets`
> Python package and send BiDi commands. See the **Connecting via WebDriver BiDi**
> section below.

## Why a real browser

`curl` only sees static HTML. Most modern pages build their content with
JavaScript, so fetching the HTML often returns an empty shell. Launching a
real, headed browser (Chromium or Firefox) and driving it over a remote protocol
(CDP for Chromium, WebDriver BiDi for Firefox) gives you the rendered DOM,
executed JS, screenshots, and cookies — the same view a user gets.

## Quick start

All paths below are relative to this skill's directory. Resolve the Python
interpreter first (it needs the `websockets` package):

```bash
PY="${AI_BROWSER_PYTHON_CMD:-python3}"
"$PY" -c 'import websockets' 2>/dev/null || {
  "$PY" -m venv /tmp/ai-browser-venv && /tmp/ai-browser-venv/bin/pip install -q websockets
  PY=/tmp/ai-browser-venv/bin/python
}
```

Then:

```bash
bash scripts/launch-browser.sh                 # idempotent; prints "ready on :9222"
"$PY" scripts/cdp.py open https://example.com  # -> {"url": "...", "title": "..."}
"$PY" scripts/cdp.py text                      # rendered body text of active tab
"$PY" scripts/cdp.py eval 'document.querySelectorAll("a").length'
"$PY" scripts/cdp.py screenshot page.png       # PNG of the viewport
"$PY" scripts/cdp.py tabs                      # list open tabs as JSON
"$PY" scripts/cdp.py close                     # shut the browser down when done
```

`open` waits for the page load event before returning, so follow-up commands
see the finished page.

**Firefox (WebDriver BiDi):**

```bash
# Launch Firefox with remote debugging
# IMPORTANT: Use nohup to detach Firefox from the shell. If you just use `&`,
# the bash tool's timeout will kill the entire process group — including Firefox —
# and the BiDi connection will fail with "Connection refused" on the next command.
nohup /Applications/Firefox.app/Contents/MacOS/firefox --remote-debugging-port 9222 > /tmp/firefox-debug.log 2>&1 &
sleep 4
grep -i "WebDriver BiDi listening" /tmp/firefox-debug.log  # confirm it's ready

# Connect and automate via BiDi (requires websockets package)
"$PY" -c "
import asyncio, json, websockets
async def main():
    async with websockets.connect('ws://127.0.0.1:9222/session') as ws:
        await ws.send(json.dumps({'id': 1, 'method': 'session.new', 'params': {
            'capabilities': {'alwaysMatch': {'browserName': 'firefox'}}
        }}))
        resp = json.loads(await ws.recv())
        sid = resp['result']['sessionId']
        print('Session:', sid)
        # Navigate, eval, screenshot — see Connecting via WebDriver BiDi section
asyncio.run(main())
"
```

## Firefox Remote Debugger

Firefox exposes a **Remote Agent** that supports the W3C **WebDriver BiDi**
protocol — a bidirectional WebSocket-based protocol. This is *not* CDP; it is
a different wire format with its own domain model. The Remote Agent also
supports the legacy **Marionette** protocol (used internally and by geckodriver).

### Capabilities over WebDriver BiDi

| Capability | BiDi Module | Notes |
|------------|-------------|-------|
| Navigate tabs | `browsingContext.navigate` | Wait for load, get final URL |
| Evaluate JavaScript | `script.evaluate` / `script.callFunction` | Runs in page or sandbox context |
| Take screenshots | `browsingContext.captureScreenshot` | Viewport or element clips |
| Get page text / DOM | `script.evaluate` | `document.body.innerText`, etc. |
| List / switch tabs | `browsingContext.getTree` | Enumerate open browsing contexts |
| Network interception | `network` | Request/response monitoring |
| Console events | `log.entryAdded` | Subscribe to console output |
| Cookie / storage | `storage` | Read/write cookies, localStorage |
| Click / type / input | `input` | Dispatch keyboard and pointer events |
| Install web extensions | `webExtension.install` | Firefox-specific: `moz:allowPrivateBrowsing`, `moz:permanent` |

So Firefox *can* be automated (navigation, JS eval, screenshots, text
extraction, interaction) — just not over CDP.

### Launching Firefox for remote debugging

Pass `--remote-debugging-port` to start the Remote Agent. The HTTPD binds to
loopback only (`127.0.0.1`) and serves WebSocket connections. No authentication
or encryption is provided.

**Note:** `scripts/launch-browser.sh` polls `/json/version` for readiness,
which is CDP-specific and returns 404 on Firefox. Launch Firefox manually
or use the commands below.

**macOS:**
```bash
nohup /Applications/Firefox.app/Contents/MacOS/firefox --remote-debugging-port 9222 > /tmp/firefox-debug.log 2>&1 &
sleep 4
grep -i "WebDriver BiDi listening" /tmp/firefox-debug.log
```

**Linux:**
```bash
nohup firefox --remote-debugging-port 9222 -profile /tmp/firefox-profile about:blank > /tmp/firefox-debug.log 2>&1 &
sleep 4
grep -i "WebDriver BiDi listening" /tmp/firefox-debug.log
```

**Windows (PowerShell):**
```powershell
& "C:\Program Files\Mozilla Firefox\firefox.exe" --remote-debugging-port 9222
```

### Discovery endpoint

Firefox's BiDi WebSocket endpoint does **not** serve HTTP endpoints like
CDP's `/json/version`. The BiDi connection is WebSocket-only:

```
ws://127.0.0.1:<PORT>/session
```

The port is whatever you passed to `--remote-debugging-port`. When Firefox
starts, it prints `WebDriver BiDi listening on ws://127.0.0.1:<PORT>` to
stderr — that is the authoritative source for the WebSocket URL.

Firefox also writes connection details to `WebDriverBiDiServer.json` in the
profile directory:

```bash
cat ~/Library/Application\ Support/Firefox/Profiles/<profile>/WebDriverBiDiServer.json
# { "ws_host": "127.0.0.1", "ws_port": 9222 }
```

### Verifying Firefox is listening

```bash
# Check stderr log for the BiDi listening message
grep -i "WebDriver BiDi listening" /tmp/firefox-debug.log

# Or just check the process
ps aux | grep -i firefox | grep -v grep
```

Note: `curl http://127.0.0.1:9222/json/version` returns **404** on Firefox —
this endpoint is CDP-specific. Firefox's HTTP server only serves the `/session`
path for classic WebDriver session creation, not BiDi discovery.

### Connecting via WebDriver BiDi

The BiDi connection uses a **two-step** process: connect to the WebSocket,
then create a session.

**Step 1 — Connect to the WebSocket:**

```python
import asyncio, json, websockets

async def main():
    uri = "ws://127.0.0.1:9222/session"
    async with websockets.connect(uri) as ws:
        # Step 2: Create a session
        await ws.send(json.dumps({
            "id": 1,
            "method": "session.new",
            "params": {
                "capabilities": {
                    "alwaysMatch": {
                        "browserName": "firefox"
                    }
                }
            }
        }))
        resp = json.loads(await ws.recv())
        session_id = resp["result"]["sessionId"]
        print(f"Session: {session_id}")

asyncio.run(main())
```

**Step 2 — Send BiDi commands over the same WebSocket:**

| Command | Effect |
|---------|--------|
| `browsingContext.getTree` | List open tabs (contexts) |
| `browsingContext.navigate` | Navigate a tab to a URL |
| `script.evaluate` | Run JS in a page context |
| `browsingContext.captureScreenshot` | Capture viewport PNG |
| `session.end` | Close the BiDi session |

All commands use the same JSON-RPC-like format:

```json
{
  "id": 1,
  "method": "module.command",
  "params": { "key": "value" }
}
```

Responses arrive as:

```json
{
  "id": 1,
  "type": "success",
  "result": { ... }
}
```

**Important constraints:**

- Firefox supports **one BiDi session at a time**. Attempting to create a
  second session while one is active returns `"Maximum number of active sessions"`.
- Each command has a monotonically increasing `id` — responses arrive in the
  same order the browser processes them, but may be interleaved with events.
- The WebSocket connection is session-scoped: closing it ends the session.

### Key preferences

Set via `user.js` in the profile or `-pref` flags:

| Preference | Default | Purpose |
|------------|---------|---------|
| `remote.experimental.enabled` | `true` (Nightly), `false` (release) | Enable experimental BiDi commands/events |
| `remote.log.level` | — | Verbosity: `Trace`..`Fatal` |
| `remote.prefs.recommended` | `true` | Auto-set sensible automation prefs (disable updates, telemetry, first-run UX) |
| `remote.screenshot.use_readback` | `false` | Use WebRender framebuffer readback for screenshots |
| `remote.retry-on-abort` | `true` (since Fx 132) | Retry IPC calls when browsing contexts are replaced |

### System access

By default the Remote Agent can only interact with **WebContent** (tab-scoped).
To interact with chrome-privileged UI or core Gecko APIs, pass:

```bash
firefox --remote-debugging-port 9222 --remote-allow-system-access
```

⚠️ This grants unrestricted access to all Gecko APIs via both Marionette and
WebDriver BiDi. Use only in isolated test environments.

### Security model

- **Loopback only.** Connections restricted to `127.0.0.1` / `localhost`.
- **No auth / no encryption.** Acceptable in isolated test environments; not for
  untrusted networks. Provide your own encryption if exposing remotely.
- **Available on all release channels**, but the Remote Agent is only fully
  shipped on the **Nightly** channel. Release/Beta may have limited BiDi support.
- Use `--remote-allow-origins` and `--remote-allow-hosts` to relax the default
  host/origin restrictions (strongly discouraged for untrusted networks).

### Automation approaches for Firefox

1. **WebDriver BiDi directly** — connect to `ws://127.0.0.1:<PORT>/session`
   and send BiDi commands via the `websockets` Python package. This is the
   modern, recommended approach. See the **Connecting via WebDriver BiDi**
   section above for a complete working example.

2. **geckodriver + WebDriver HTTP** — use geckodriver as a proxy that translates
   WebDriver HTTP commands into Marionette protocol messages. Mature and
   well-tested, but requires the geckodriver binary.

3. **Marionette directly** — the legacy TCP-based protocol. Used internally by
   Firefox CI. Not recommended for new automation; prefer BiDi.

### Differences from CDP

| Aspect | CDP (Chromium) | WebDriver BiDi (Firefox) |
|--------|----------------|--------------------------|
| Transport | WebSocket (JSON) | WebSocket (JSON-RPC) |
| Model | Domain-based (Page, Runtime, Network, …) | Module-based (browsingContext, script, network, …) |
| JS evaluation | `Runtime.evaluate` | `script.evaluate` / `script.callFunction` |
| Screenshots | `Page.captureScreenshot` | `browsingContext.captureScreenshot` |
| Tab management | `Target.getTargets` | `browsingContext.getTree` |
| Network | `Network.*` events | `network.*` events |
| Auth | None (loopback) | None (loopback) |
| Legacy protocol | — | Marionette (TCP, for geckodriver) |

## Environment resolution

| What | Preferred | Fallback |
|------|-----------|----------|
| Browser binary | `$AI_BROWSER_CMD` (preferred) | `$AI_BROWSER_CHROMIUM_CMD` (fallback); or `chromium`, `chromium-browser`, `google-chrome-stable`, `google-chrome`, `firefox` on PATH |
| Python + websockets | `$AI_BROWSER_PYTHON_CMD` | `python3`; if `import websockets` fails, make a venv in `/tmp` and pip-install it |
| CDP port | `$AI_BROWSER_CDP_PORT` | `9222` |

The launch script implements this table; you only need it manually when doing
something unusual.

## Launching the browser — why each piece matters

`scripts/launch-browser.sh` is deliberately picky about process handling:

- **Full detachment (`setsid ... </dev/null >>log 2>&1 &` or `nohup` fallback).**
  Shell tools may kill the whole process group when a command times out. A
  browser launched without detaching dies silently mid-session and every later
  CDP call fails. The script uses `setsid` on Linux (creates a new session)
  and falls back to `nohup` on macOS where `setsid` is not available.
  This exact failure happened in practice; don't simplify the flags away.
- **Browser-aware flags.** Chromium and Firefox have different CLI flags.
  The script detects the browser type and applies the correct set:
  Chromium gets `--user-data-dir`, `--no-first-run`, `--no-default-browser-check`,
  `--disable-gpu`; Firefox gets `-profile` and a space-separated `--remote-debugging-port`.
- **Headed, not headless.** Always launch with a visible window — never add
  `--headless`. Headed windows make failures visible to the user and keep the
  browser's behavior identical to a real session. This requires a display:
  the script errors out clearly when neither `DISPLAY` nor `WAYLAND_DISPLAY`
  is set (Linux only — macOS doesn't need these variables).
- **Idempotency.** If `/json/version` already answers on the port, the script
  reuses the running browser instead of spawning a second one. Reuse first;
  only launch when nothing answers.
- **Fresh temp profile (`mktemp -d`).** A profile directory locked by another
  browser instance prevents startup entirely.
- **Readiness polling.** The debug port takes a moment to appear; poll
  `http://127.0.0.1:$PORT/json/version` until it responds instead of sleeping
  a fixed time. **Note:** This only works for Chromium. Firefox does not serve
  `/json/version`; for Firefox readiness, poll the stderr log for
  `WebDriver BiDi listening` or check that the WebSocket port is accepting
  connections.

## cdp.py reference

| Command | Effect |
|---------|--------|
| `ping` | Print browser version; exit code 1 if not running |
| `open <url>` | Navigate active tab, wait for load, print final URL + title |
| `eval <js>` | Evaluate JS in the page, print result (JSON for non-strings) |
| `text` | Print `document.body.innerText` — the rendered text, not source |
| `screenshot [path]` | Write a viewport PNG (default `./screenshot.png`) |
| `tabs` | List page targets as JSON |
| `close` | Graceful `Browser.close` |

Behavior worth knowing:

- The "active tab" is the most recently listed tab with a real URL — stale
  `about:blank` tabs are skipped so you don't screenshot emptiness.
- Screenshots arrive base64-encoded over one websocket frame; the script sets
  `max_size=64 MiB` because the default 1 MiB limit truncates them.
- If a page never fires `load` (rare), `open` returns after ~15 s anyway.

## Going beyond the bundled script

For flows cdp.py doesn't cover (clicking, typing, network interception,
multiple tabs), read `scripts/cdp.py` as the template — it already solves the
boring parts: request/response ID correlation against a background reader
task, per-session event filtering, and target attachment via
`Target.attachToTarget {flatten: true}`. Typical additions are a few lines:
send `Input.dispatchMouseEvent` for clicks, `Page.captureSnapshot` for MHTML,
or attach to several targets at once.

## Session patterns

**The browser is live, shared state.** The active tab can move between your
commands — the user may navigate it themselves, or another agent may drive the
same session. Before acting on "the current page", read where you actually are:

```bash
"$PY" scripts/cdp.py eval 'location.href'
```

Derive context (repo name, issue number, ...) from that URL rather than from
local assumptions like `git remote` — they can disagree, and the user almost
always means what's on screen.

**Extract structured links, then navigate.** Pull hrefs plus labels as JSON,
pick the entry you want, and `open` it:

```bash
"$PY" scripts/cdp.py eval 'JSON.stringify(
  [...document.querySelectorAll("a[href*=\"/actions/runs/\"]")]
    .slice(0, 5).map(a => ({href: a.getAttribute("href"),
                            text: a.innerText.trim().split("\n")[0]})))'
```

Worked example — latest GitHub Actions run for the repo on screen: open
`https://github.com/<owner>/<repo>/actions`. If it redirects to
`/actions/new`, the repo has zero workflow runs (this also happens when no
`.github/workflows/` exists) — stop and say so instead of guessing. Otherwise
the first `/actions/runs/<id>` link from the query above is the newest run;
open it and scrape the outcome from the page text (`Success`, `Failure`, ...)
and job names from `a[href*="/job/"]`.

## Gotchas checklist

- **Firefox launch killed by bash timeout?** The bash tool kills the *entire process group* when a command times out. A bare `&` keeps Firefox in the same group, so it dies silently and the next BiDi call gets `ConnectionRefusedError: [Errno 61] Connect call failed`. Always use `nohup` to fully detach Firefox: `nohup /Applications/Firefox.app/Contents/MacOS/firefox --remote-debugging-port 9222 > /tmp/firefox-debug.log 2>&1 &`. The same issue affects Chromium when launched outside `launch-browser.sh`.
- Browser died? `cdp.py ping` first (Chromium); for Firefox, check `ps aux | grep firefox` or look for the `WebDriver BiDi listening` message in the stderr log.
- Multiple agents/tasks sharing a machine: give each its own port via
  `AI_BROWSER_CDP_PORT`.
- Empty `text`/blank screenshot usually means you attached to a blank tab —
  run `tabs` to see what's actually open.
- Headless is intentionally never used; if launch fails on a display-less
  machine, surface the error instead of silently switching to `--headless`.
- `close` when finished with long-lived browsing sessions, but leave it
  running if more requests will come soon; startup costs ~1 s.
- Don't assume the tab is still where you left it — check `location.href`
  before reasoning about "the current page"; users and other agents move it.
- **Firefox users:** The bundled `cdp.py` speaks CDP and only works with
  Chromium. For Firefox automation, use WebDriver BiDi (see Firefox Remote
  Debugger section) or geckodriver. Firefox's Remote Agent is fully shipped
  on Nightly; release/beta may have limited BiDi support. To use Firefox
  for CDP-equivalent automation, build a BiDi client or use geckodriver's
  WebDriver HTTP interface.
