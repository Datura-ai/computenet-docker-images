"""Metrics sidecar for the Dolphin filler: proxies vLLM's /metrics from its
unix socket onto TCP :9101 so the platform's published-port machinery can
expose it to the lium-stats scraper.

Design constraints (DAH-2468):
- stdlib only, must never interfere with the worker; a crash is fine — the
  entrypoint restart loop brings it back (with backoff).
- Verbatim pass-through of the vLLM Prometheus text (no parsing at the edge),
  plus appended dolphin_sidecar_* series. vLLM down still answers 200 with
  the sidecar series only, so the scraper can tell "worker dead" from
  "sidecar dead" from "machine dead".
- Fail closed: without METRICS_TOKEN every request gets 503 — this port is
  published to the internet, never serve it unauthenticated.
- Total upstream budget per request stays under the scraper's client timeout
  even when falling through several stale sockets.
"""

import glob
import hmac
import http.client
import http.server
import json
import os
import socket
import sys
import time

PORT = int(os.environ.get("METRICS_PORT", "9101"))
TOKEN = os.environ.get("METRICS_TOKEN", "")
SOCKET_GLOB = os.environ.get("METRICS_SOCKET_GLOB", "/tmp/dp-*/v.sock")
SIDECAR_VERSION = 1
TOTAL_BUDGET_S = 4.0
CONNECT_TIMEOUT_S = 1.0
MAX_BODY_BYTES = 5 * 1024 * 1024
LOG_INTERVAL_S = 10.0
# Prometheus text exposition format version — NOT the image version (which also
# happens to be 0.0.4). Do not bump this when bumping the image tag.
PROM_CONTENT_TYPE = "text/plain; version=0.0.4; charset=utf-8"

_last_ok_ts: float = 0.0
_last_socket: str = ""
_last_error: str | None = None
_last_log_ts: float = 0.0


def _log(msg: str) -> None:
    # rate-limited: a crash-looping upstream must not flood container logs
    global _last_log_ts
    now = time.monotonic()
    if now - _last_log_ts >= LOG_INTERVAL_S:
        _last_log_ts = now
        print(f"[sidecar] {msg}", file=sys.stderr, flush=True)


class UdsHTTPConnection(http.client.HTTPConnection):
    """HTTPConnection over an AF_UNIX socket path."""

    def __init__(self, path: str, timeout: float) -> None:
        super().__init__("localhost", timeout=timeout)
        self._path = path

    def connect(self) -> None:
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(self.timeout)
        sock.connect(self._path)
        self.sock = sock


def discover_sockets() -> list[str]:
    # newest mtime first: stale /tmp/dp-*/v.sock files survive worker restarts
    paths = glob.glob(SOCKET_GLOB)
    def mtime(p: str) -> float:
        try:
            return os.stat(p).st_mtime
        except OSError:
            return 0.0
    return sorted(paths, key=mtime, reverse=True)


def fetch_vllm_metrics(sockets: list[str]) -> bytes | None:
    # try each socket within one shared deadline; first good response wins
    global _last_ok_ts, _last_socket, _last_error
    deadline = time.monotonic() + TOTAL_BUDGET_S
    for path in sockets:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            _last_error = "budget exhausted"
            return None
        conn = UdsHTTPConnection(path, timeout=min(CONNECT_TIMEOUT_S, remaining))
        try:
            conn.connect()
            conn.sock.settimeout(max(0.1, deadline - time.monotonic()))
            conn.request("GET", "/metrics")
            resp = conn.getresponse()
            if resp.status != 200:
                _last_error = f"{path}: HTTP {resp.status}"
                continue
            body = resp.read(MAX_BODY_BYTES + 1)
            if len(body) > MAX_BODY_BYTES:
                _last_error = f"{path}: body over {MAX_BODY_BYTES} bytes"
                continue
            _last_ok_ts = time.time()
            _last_socket = path
            _last_error = None
            return body
        except (OSError, http.client.HTTPException) as e:
            # a stale socket may host a non-HTTP listener, or vllm can die
            # mid-response (IncompleteRead) — fall through to the next socket;
            # a crash here would defeat the 200 fail-open the scraper relies on
            _last_error = f"{path}: {e}"
            continue
        finally:
            try:
                conn.close()
            except Exception:
                pass
    return None


def sidecar_series(sockets_found: int, proxy_ok: bool) -> bytes:
    # proxy_ok is THE engine-liveness discriminator for the scraper: stale
    # socket files can exist while the engine is dead, so sockets_found alone
    # cannot distinguish "vllm down" from "vllm schema changed".
    return (
        f"dolphin_sidecar_up 1\n"
        f"dolphin_sidecar_proxy_ok {int(proxy_ok)}\n"
        f"dolphin_sidecar_sockets_found {sockets_found}\n"
        f"dolphin_sidecar_last_proxy_ok_timestamp {int(_last_ok_ts)}\n"
        f"dolphin_sidecar_version {SIDECAR_VERSION}\n"
    ).encode()


class Handler(http.server.BaseHTTPRequestHandler):
    server_version = "dolphin-sidecar"

    def log_message(self, fmt: str, *args) -> None:  # noqa: A003
        pass  # per-request access logging is pure noise on a 60s scrape

    def _reply(self, status: int, body: bytes, content_type: str) -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _authorized(self) -> bool:
        got = self.headers.get("Authorization", "")
        return hmac.compare_digest(got, f"Bearer {TOKEN}")

    def do_GET(self) -> None:  # noqa: N802
        if not TOKEN:
            # fail closed: an unset token must never mean an open port
            self._reply(503, b"METRICS_TOKEN not configured\n", "text/plain")
            _log("refusing request: METRICS_TOKEN is not set")
            return
        if not self._authorized():
            self._reply(401, b"unauthorized\n", "text/plain")
            return
        if self.path == "/metrics":
            self._get_metrics()
        elif self.path == "/health":
            self._get_health()
        else:
            self._reply(404, b"not found\n", "text/plain")

    def do_POST(self) -> None:  # noqa: N802
        self._reply(405, b"method not allowed\n", "text/plain")

    def _get_metrics(self) -> None:
        # verbatim vllm body (if any engine answers) + appended sidecar series
        sockets = discover_sockets()
        body = fetch_vllm_metrics(sockets)
        if body is None:
            out = sidecar_series(len(sockets), proxy_ok=False)
            if sockets:
                _log(f"no responsive vllm socket ({len(sockets)} candidates): {_last_error}")
        else:
            if not body.endswith(b"\n"):
                body += b"\n"
            out = body + sidecar_series(len(sockets), proxy_ok=True)
        self._reply(200, out, PROM_CONTENT_TYPE)

    def _get_health(self) -> None:
        sockets = discover_sockets()
        payload = {
            "socket": _last_socket or None,
            "sockets_found": len(sockets),
            "last_ok": int(_last_ok_ts),
            "error": _last_error,
            "sidecar_version": SIDECAR_VERSION,
        }
        self._reply(200, json.dumps(payload).encode() + b"\n", "application/json")


def main() -> None:
    server = http.server.ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    server.daemon_threads = True
    print(f"[sidecar] serving on :{PORT} (version {SIDECAR_VERSION})", file=sys.stderr, flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
