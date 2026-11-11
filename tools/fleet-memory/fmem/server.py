"""Resident query path: models + index stay loaded in one process; clients talk JSON lines over a Unix socket.

Protocol (one request line, one response line, both UTF-8 JSON):
  {"op":"query","q":"...","k":3}  -> the query result object (see engine.Engine.query)
  {"op":"ping"}                    -> {"ok":true,"pid":N,"started":epoch}
  {"op":"reload"}                  -> re-reads thesaurus, registry, settings and reopens the index
  {"op":"stop"}                    -> {"ok":true} then the server exits
The socket is mode 0600 inside the memory home; nothing listens on the network.
The client half (`request`) imports only the standard library so a call costs milliseconds.
"""
from __future__ import annotations

import json
import os
import signal
import socket
import subprocess
import sys
import time

from . import config


def request(payload: dict, p: config.Paths | None = None, timeout: float = 60.0) -> dict | None:
    """Send one request; None if no server answers (caller falls back to one-shot)."""
    p = p or config.paths()
    if not p.sock.exists():
        return None
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(timeout)
    try:
        s.connect(str(p.sock))
        s.sendall((json.dumps(payload) + "\n").encode())
        buf = b""
        while not buf.endswith(b"\n"):
            chunk = s.recv(65536)
            if not chunk:
                break
            buf += chunk
        return json.loads(buf) if buf else None
    except (OSError, ValueError):
        return None
    finally:
        s.close()


def is_running(p: config.Paths | None = None) -> bool:
    r = request({"op": "ping"}, p, timeout=2.0)
    return bool(r and r.get("ok"))


def serve(p: config.Paths | None = None) -> None:
    p = p or config.paths()
    from .engine import Engine
    p.run.mkdir(parents=True, exist_ok=True)
    eng = Engine(p)
    if p.sock.exists():
        p.sock.unlink()
    srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    srv.bind(str(p.sock))
    os.chmod(p.sock, 0o600)
    srv.listen(8)
    p.pidfile.write_text(str(os.getpid()))
    started = int(time.time())
    stop = False

    def _term(*_):
        nonlocal stop
        stop = True
        srv.close()

    signal.signal(signal.SIGTERM, _term)
    signal.signal(signal.SIGINT, _term)
    print(f"fmem server ready pid={os.getpid()} sock={p.sock}", flush=True)
    try:
        while not stop:
            try:
                conn, _ = srv.accept()
            except OSError:
                break
            with conn:
                try:
                    data = b""
                    while not data.endswith(b"\n"):
                        chunk = conn.recv(65536)
                        if not chunk:
                            break
                        data += chunk
                    req = json.loads(data)
                    op = req.get("op")
                    if op == "ping":
                        resp = {"ok": True, "pid": os.getpid(), "started": started}
                    elif op == "query":
                        resp = eng.query(str(req["q"]), req.get("k"))
                    elif op == "reload":
                        eng.reload_config()
                        eng.reopen()
                        resp = {"ok": True}
                    elif op == "stop":
                        resp = {"ok": True}
                        stop = True
                    else:
                        resp = {"error": f"unknown op {op!r}"}
                except Exception as ex:                       # one bad request must not kill the server
                    resp = {"error": f"{type(ex).__name__}: {ex}"}
                try:
                    conn.sendall((json.dumps(resp) + "\n").encode())
                except OSError:
                    pass
    finally:
        for f in (p.sock, p.pidfile):
            try:
                f.unlink()
            except OSError:
                pass


def start(p: config.Paths | None = None, wait: float = 90.0) -> str:
    """Spawn a detached server and wait until it answers. Idempotent."""
    p = p or config.paths()
    if is_running(p):
        return "already running"
    p.run.mkdir(parents=True, exist_ok=True)
    log = open(p.logfile, "ab")
    env = dict(os.environ)
    env["PYTHONPATH"] = str(config.TOOL_DIR) + os.pathsep + env.get("PYTHONPATH", "")
    subprocess.Popen([sys.executable, "-m", "fmem", "serve"], stdout=log, stderr=log, stdin=subprocess.DEVNULL,
                     start_new_session=True, env=env)
    t0 = time.time()
    while time.time() - t0 < wait:
        if is_running(p):
            return f"started ({time.time() - t0:.1f}s)"
        time.sleep(0.3)
    raise SystemExit(f"server did not come up within {wait:.0f}s; see {p.logfile}")


def stop(p: config.Paths | None = None) -> str:
    p = p or config.paths()
    r = request({"op": "stop"}, p, timeout=5.0)
    if r is None:
        if p.sock.exists():
            p.sock.unlink()
        return "not running"
    for _ in range(30):
        if not p.sock.exists():
            break
        time.sleep(0.1)
    return "stopped"
