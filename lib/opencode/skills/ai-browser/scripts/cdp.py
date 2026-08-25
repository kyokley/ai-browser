#!/usr/bin/env python3
"""Drive a CDP-enabled Chromium: open URLs, eval JS, extract text, screenshot.

Usage:
  cdp.py [--port N] <command> [args]

Commands:
  ping                  Print browser version (exit 1 if not running)
  open <url>            Navigate the active tab, wait for load, print {url,title}
  eval <expression>     Evaluate JavaScript in the active tab, print the value
  text                  Print document.body.innerText of the active tab
  screenshot [path]     Capture a PNG of the active tab (default: screenshot.png)
  tabs                  List open page targets as JSON
  close                 Ask the browser to shut down (Browser.close)

Port defaults to $AI_BROWSER_CDP_PORT or 9222. Requires the `websockets` package.
"""

import argparse
import asyncio
import base64
import json
import os
import sys
import urllib.error
import urllib.request

import websockets


def browser_version(port):
    url = f"http://127.0.0.1:{port}/json/version"
    with urllib.request.urlopen(url, timeout=5) as resp:
        return json.load(resp)


class CDP:
    """Websocket CDP connection with request/response correlation."""

    def __init__(self, ws):
        self.ws = ws
        self.next_id = 0
        self.pending = {}
        self.events = asyncio.Queue()
        self.reader = asyncio.create_task(self._read())

    async def _read(self):
        async for raw in self.ws:
            msg = json.loads(raw)
            if "id" in msg:
                fut = self.pending.pop(msg["id"], None)
                if fut is not None:
                    fut.set_result(msg)
            else:
                await self.events.put(msg)

    async def send(self, method, params=None, session_id=None):
        self.next_id += 1
        fut = asyncio.get_running_loop().create_future()
        self.pending[self.next_id] = fut
        msg = {"id": self.next_id, "method": method, "params": params or {}}
        if session_id is not None:
            msg["sessionId"] = session_id
        await self.ws.send(json.dumps(msg))
        resp = await fut
        if "error" in resp:
            raise RuntimeError(f"{method}: {resp['error']}")
        return resp.get("result", {})

    async def wait_event(self, method, session_id, timeout=15.0):
        async with asyncio.timeout(timeout):
            while True:
                evt = await self.events.get()
                if evt.get("method") == method and evt.get("sessionId") == session_id:
                    return evt


async def connect(port):
    version = browser_version(port)
    # max_size matters: full-page screenshots exceed the default 1 MiB frame limit.
    ws = await websockets.connect(version["webSocketDebuggerUrl"], max_size=64 * 1024 * 1024)
    return CDP(ws)


async def page_session(cdp):
    """Attach to the most relevant page target, creating one if necessary."""
    targets = await cdp.send("Target.getTargets")
    pages = [t for t in targets["targetInfos"] if t["type"] == "page"]
    if not pages:
        created = await cdp.send("Target.createTarget", {"url": "about:blank"})
        target_id = created["targetId"]
    else:
        # Prefer the most recent tab that actually has content; a stale
        # about:blank tab would silently produce empty text/screenshots.
        loaded = [t for t in pages if t["url"] != "about:blank"]
        target_id = (loaded[-1] if loaded else pages[-1])["targetId"]
    session = await cdp.send("Target.attachToTarget", {"targetId": target_id, "flatten": True})
    sid = session["sessionId"]
    await cdp.send("Page.enable", session_id=sid)
    await cdp.send("Runtime.enable", session_id=sid)
    return sid


async def evaluate(cdp, sid, expression):
    result = await cdp.send(
        "Runtime.evaluate",
        {"expression": expression, "returnByValue": True, "awaitPromise": True},
        session_id=sid,
    )
    if result.get("exceptionDetails"):
        detail = result["exceptionDetails"].get("exception", {})
        raise RuntimeError(detail.get("description", "evaluation failed"))
    return result["result"].get("value")


async def cmd_open(cdp, url):
    sid = await page_session(cdp)
    nav = await cdp.send("Page.navigate", {"url": url}, session_id=sid)
    if "errorText" in nav:
        raise RuntimeError(nav["errorText"])
    try:
        await cdp.wait_event("Page.loadEventFired", sid)
    except TimeoutError:
        pass  # some pages never fire load; report what we have
    title = await evaluate(cdp, sid, "document.title")
    final_url = await evaluate(cdp, sid, "location.href")
    print(json.dumps({"url": final_url, "title": title}))


async def cmd_eval(cdp, expression):
    sid = await page_session(cdp)
    value = await evaluate(cdp, sid, expression)
    print(value if isinstance(value, str) else json.dumps(value))


async def cmd_text(cdp):
    sid = await page_session(cdp)
    print(await evaluate(cdp, sid, "document.body.innerText"))


async def cmd_screenshot(cdp, path):
    sid = await page_session(cdp)
    shot = await cdp.send("Page.captureScreenshot", {"format": "png"}, session_id=sid)
    with open(path, "wb") as f:
        f.write(base64.b64decode(shot["data"]))
    print(path)


async def cmd_tabs(cdp):
    targets = await cdp.send("Target.getTargets")
    pages = [t for t in targets["targetInfos"] if t["type"] == "page"]
    print(json.dumps([{"id": t["targetId"], "url": t["url"], "title": t["title"]} for t in pages], indent=2))


async def run(args):
    cdp = await connect(args.port)
    try:
        if args.command == "close":
            await cdp.send("Browser.close")
        elif args.command == "open":
            await cmd_open(cdp, args.url)
        elif args.command == "eval":
            await cmd_eval(cdp, args.expression)
        elif args.command == "text":
            await cmd_text(cdp)
        elif args.command == "screenshot":
            await cmd_screenshot(cdp, args.path)
        elif args.command == "tabs":
            await cmd_tabs(cdp)
    finally:
        cdp.reader.cancel()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=int(os.environ.get("AI_BROWSER_CDP_PORT", "9222")))
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("ping")
    p_open = sub.add_parser("open")
    p_open.add_argument("url")
    p_eval = sub.add_parser("eval")
    p_eval.add_argument("expression")
    sub.add_parser("text")
    p_shot = sub.add_parser("screenshot")
    p_shot.add_argument("path", nargs="?", default="screenshot.png")
    sub.add_parser("tabs")
    sub.add_parser("close")
    args = parser.parse_args()

    if args.command == "ping":
        try:
            version = browser_version(args.port)
        except (urllib.error.URLError, OSError):
            sys.exit(1)
        print(version["Browser"])
        return

    asyncio.run(run(args))


if __name__ == "__main__":
    main()
