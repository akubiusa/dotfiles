#!/usr/bin/env python3
import asyncio
import json
import math
import os
import re
import socket
import ssl
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request

USAGE = """\
Usage: python3 pve-vnc.py NODE VMID OUT.png [ACTION...]

Actions (run in order, then OUT.png is saved):
  key NAME     press a vncdotool key (enter, shift, super-r, ctrl-alt-del, ...)
  type TEXT    press each character of TEXT in turn
  click X Y    move to X,Y and press button 1
  move X Y     move the pointer to X,Y
  wait SEC     sleep

Reads PROXMOX_URL / PROXMOX_USER / PROXMOX_PASSWORD from ~/.env.
Requires: pip install 'websockets>=14' vncdotool pillow (use a venv).
The first frame may be black: send a key (e.g. shift) and wait a few seconds.
TLS verification is disabled (self-signed certificate; trusted LAN only).
"""

# アクション名 -> 引数の個数。接続前に全アクションを検証するために使う
ARITY = {"key": 1, "type": 1, "click": 2, "move": 2, "wait": 1}


def die(msg):
    sys.exit("pve-vnc: " + msg)


def parse_actions(tokens):
    acts = []
    i = 0
    while i < len(tokens):
        name = tokens[i]
        if name not in ARITY:
            die(f"unknown action: {name!r}")
        n = ARITY[name]
        args = tokens[i + 1:i + 1 + n]
        if len(args) < n:
            die(f"action {name!r} needs {n} argument(s)")
        try:
            if name in ("click", "move"):
                args = [int(a) for a in args]
            elif name == "wait":
                args = [float(args[0])]
                # nan / inf / 負値は不正または無限待機になるため拒否する
                if not (math.isfinite(args[0]) and args[0] >= 0):
                    die(f"action 'wait' needs a finite, non-negative number: {tokens[i + 1]!r}")
        except ValueError:
            die(f"action {name!r} has a non-numeric argument: {args!r}")
        acts.append((name, *args))
        i += 1 + n
    return acts


if sys.argv[1:2] in (["-h"], ["--help"]):
    print(USAGE, file=sys.stderr)
    sys.exit(0)
if len(sys.argv) < 4:
    print(USAGE, file=sys.stderr)
    sys.exit(2)

node, vmid, out, *raw_acts = sys.argv[1:]
if not re.fullmatch(r"[A-Za-z0-9._-]+", node):
    die(f"invalid node name: {node!r}")
if not re.fullmatch(r"[0-9]+", vmid):
    die(f"invalid vmid: {vmid!r}")
acts = parse_actions(raw_acts)

try:
    from vncdotool import api
    from websockets.asyncio.client import connect as ws_connect  # websockets 14 以降のみ
except ImportError as e:
    die(f"missing deps ({e}). Run: python3 -m venv V && V/bin/pip install 'websockets>=14' vncdotool pillow")


def read_env(path=os.path.expanduser("~/.env")):
    want = ("PROXMOX_URL", "PROXMOX_USER", "PROXMOX_PASSWORD")
    env = {}
    try:
        lines = open(path).read().splitlines()
    except OSError as e:
        die(f"cannot read {path}: {e.strerror}")
    for line in lines:
        m = re.match(r"(?:export\s+)?(\w+)=(.*)$", line.strip().rstrip("\r"))
        if m and m.group(1) in want:
            # pve-api.sh と同じく、前後が対になった引用符だけを外す
            env[m.group(1)] = re.sub(r"""^(["'])(.*)\1$""", r"\2", m.group(2))
    missing = [k for k in want if not env.get(k)]
    if missing:
        die(f"missing or empty in {path}: " + ", ".join(missing))
    return env


env = read_env()
base = env["PROXMOX_URL"].rstrip("/")
ctx = ssl.create_default_context()
ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE


def call(method, path, data=None, hdr=None):
    req = urllib.request.Request(
        base + "/api2/json" + path, method=method,
        data=urllib.parse.urlencode(data).encode() if data else None, headers=hdr or {})
    return json.load(urllib.request.urlopen(req, context=ctx, timeout=30))["data"]


try:
    t = call("POST", "/access/ticket", {"username": env["PROXMOX_USER"], "password": env["PROXMOX_PASSWORD"]})
    cookie = "PVEAuthCookie=" + t["ticket"]
    hdr = {"Cookie": cookie, "CSRFPreventionToken": t["CSRFPreventionToken"]}
    # vncproxy のチケットは短命なので、取得直後にこのプロセスで接続する
    p = call("POST", f"/nodes/{node}/qemu/{vmid}/vncproxy", {"websocket": 1, "generate-password": 1}, hdr)
except urllib.error.HTTPError as e:
    die(f"API error: HTTP {e.code} {e.reason}")
except urllib.error.URLError as e:
    die(f"API connection error: {e.reason}")
except Exception as e:
    die(f"API error: {type(e).__name__}")

wsurl = base.replace("https", "wss", 1) + f"/api2/json/nodes/{node}/qemu/{vmid}/vncwebsocket?" + \
    urllib.parse.urlencode({"port": p["port"], "vncticket": p["ticket"]})

bridge_error = []  # ブリッジ側の失敗理由。メインスレッドが VNC 側のエラーより優先して報告する


async def handle(r, w):
    try:
        async with ws_connect(wsurl, ssl=ctx, additional_headers={"Cookie": cookie},
                              subprotocols=["binary"], max_size=None) as ws:
            async def up():
                while d := await r.read(65536):
                    await ws.send(d)

            async def down():
                async for m in ws:
                    w.write(m if isinstance(m, bytes) else m.encode())
                    await w.drain()

            tasks = [asyncio.create_task(up()), asyncio.create_task(down())]
            done, pending = await asyncio.wait(tasks, return_when=asyncio.FIRST_COMPLETED)
            for task in pending:
                task.cancel()
            await asyncio.gather(*pending, return_exceptions=True)
            for task in done:
                if task.exception():
                    raise task.exception()
    except Exception as e:
        bridge_error.append(f"WebSocket bridge failed: {type(e).__name__}: {e}")
    finally:
        w.close()


# 空きポートを OS に選ばせ、ループバックにだけ bind する
sock = socket.socket()
sock.bind(("127.0.0.1", 0))
port = sock.getsockname()[1]
ready = threading.Event()


def serve():
    async def main():
        s = await asyncio.start_server(handle, sock=sock)
        ready.set()
        await s.serve_forever()
    asyncio.run(main())


threading.Thread(target=serve, daemon=True).start()
if not ready.wait(timeout=10):
    die("local bridge did not start within 10s")

VNC_TIMEOUT = 30
rc = 0
c = None
try:
    # timeout 未指定だと VNC が止まったときに永久に待つ。各呼び出しと切断を 30 秒で打ち切る
    c = api.connect(f"127.0.0.1::{port}", password=p["password"], timeout=VNC_TIMEOUT)
    for name, *args in acts:
        if name == "key":
            c.keyPress(args[0])
        elif name == "type":
            for ch in args[0]:
                c.keyPress(ch)
        elif name == "move":
            c.mouseMove(*args)
        elif name == "click":
            c.mouseMove(*args)
            c.mousePress(1)
        elif name == "wait":
            time.sleep(args[0])
    c.refreshScreen()
    c.captureScreen(out)
    print("captured", c.screen.size if c.screen else None)
except Exception as e:
    time.sleep(0.2)  # ブリッジ側のエラー記録が先に済むのを待つ
    if bridge_error:
        msg = bridge_error[0]
    elif isinstance(e, TimeoutError):
        msg = f"VNC did not respond within {VNC_TIMEOUT}s (rerun to get a fresh ticket)"
    else:
        msg = f"{type(e).__name__}: {e}"
    print("pve-vnc: " + msg, file=sys.stderr)
    rc = 1
finally:
    try:
        if c:
            c.disconnect()
    except Exception:
        pass  # 切断時のエラーは、接続が既に落ちている場合に出るだけで結果に影響しない
    sys.stdout.flush()
    sys.stderr.flush()
    os._exit(rc)  # vncdotool の reactor スレッドとブリッジは自力では終了しない
