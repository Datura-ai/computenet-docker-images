"""Sidecar contract tests (DAH-2468). Stdlib only, no pytest dependency:
runnable as `python3 tests/test_sidecar.py` on the host AND inside the built
image (where SIDECAR_PATH points at the shipped copy). Each test launches the
sidecar as a real subprocess — same code path as production.

Covered contract points: verbatim pass-through + appended series, trailing
newline normalization, bearer auth (hmac), fail-closed without token,
socket-missing 200, stale-newest socket fall-through, /health, 405.
"""

import contextlib
import http.server
import json
import os
import pathlib
import socket
import socketserver
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.request

HERE = pathlib.Path(__file__).resolve().parent
SIDECAR_PATH = os.environ.get("SIDECAR_PATH", str(HERE.parent / "metrics_sidecar.py"))
FIXTURE = (HERE / "fixtures" / "vllm_metrics.txt").read_bytes()
TOKEN = "t3st-fleet-token"


def free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


class _UdsHandler(http.server.BaseHTTPRequestHandler):
    body: bytes = b""

    def do_GET(self) -> None:  # noqa: N802
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(self.body)))
        self.end_headers()
        self.wfile.write(self.body)

    def log_message(self, fmt: str, *args) -> None:  # noqa: A003
        pass


class _UdsServer(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
    daemon_threads = True

    # BaseHTTPRequestHandler expects client_address[0]; unix sockets give ''
    def get_request(self):
        request, _ = super().get_request()
        return request, ("uds", 0)


@contextlib.contextmanager
def fake_vllm(sock_path: pathlib.Path, body: bytes):
    # minimal HTTP-over-unix-socket server standing in for the vLLM engine
    handler = type("H", (_UdsHandler,), {"body": body})
    server = _UdsServer(str(sock_path), handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield
    finally:
        server.shutdown()
        server.server_close()


@contextlib.contextmanager
def sidecar(glob_pattern: str, token: str | None):
    # run the real sidecar as a subprocess, wait until it listens
    port = free_port()
    env = dict(os.environ)
    env["METRICS_PORT"] = str(port)
    env["METRICS_SOCKET_GLOB"] = glob_pattern
    env.pop("METRICS_TOKEN", None)
    if token is not None:
        env["METRICS_TOKEN"] = token
    proc = subprocess.Popen(
        [sys.executable, SIDECAR_PATH], env=env,
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    try:
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            try:
                with socket.create_connection(("127.0.0.1", port), timeout=0.2):
                    break
            except OSError:
                if proc.poll() is not None:
                    raise RuntimeError("sidecar exited early")
                time.sleep(0.05)
        else:
            raise RuntimeError("sidecar never started listening")
        yield f"http://127.0.0.1:{port}"
    finally:
        proc.terminate()
        proc.wait(timeout=5)


def get(url: str, token: str | None = TOKEN, method: str = "GET") -> tuple[int, bytes, str]:
    req = urllib.request.Request(url, method=method)
    if token is not None:
        req.add_header("Authorization", f"Bearer {token}")
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            return resp.status, resp.read(), resp.headers.get("Content-Type", "")
    except urllib.error.HTTPError as e:
        return e.code, e.read(), e.headers.get("Content-Type", "")


def test_passthrough_and_appended_series() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        sock = pathlib.Path(tmp) / "dp-1" / "v.sock"
        sock.parent.mkdir()
        with fake_vllm(sock, FIXTURE), sidecar(f"{tmp}/dp-*/v.sock", TOKEN) as base:
            status, body, ctype = get(f"{base}/metrics")
    assert status == 200, status
    assert body.startswith(FIXTURE), "vllm body must pass through byte-identical"
    assert b"\ndolphin_sidecar_up 1\n" in body
    assert b"dolphin_sidecar_proxy_ok 1\n" in body
    assert b"dolphin_sidecar_sockets_found 1\n" in body
    assert b"dolphin_sidecar_version 1\n" in body
    assert ctype.startswith("text/plain; version=0.0.4"), ctype


def test_trailing_newline_normalized() -> None:
    no_newline = FIXTURE.rstrip(b"\n")
    with tempfile.TemporaryDirectory() as tmp:
        sock = pathlib.Path(tmp) / "dp-1" / "v.sock"
        sock.parent.mkdir()
        with fake_vllm(sock, no_newline), sidecar(f"{tmp}/dp-*/v.sock", TOKEN) as base:
            _, body, _ = get(f"{base}/metrics")
    assert no_newline + b"\ndolphin_sidecar_up 1\n" in body, \
        "appended series must start on its own line even without upstream trailing newline"


def test_auth_wrong_and_missing() -> None:
    with tempfile.TemporaryDirectory() as tmp, sidecar(f"{tmp}/dp-*/v.sock", TOKEN) as base:
        status_wrong, _, _ = get(f"{base}/metrics", token="wrong")
        status_missing, _, _ = get(f"{base}/metrics", token=None)
        status_health, _, _ = get(f"{base}/health", token="wrong")
    assert status_wrong == 401, status_wrong
    assert status_missing == 401, status_missing
    assert status_health == 401, status_health


def test_fail_closed_without_token() -> None:
    with tempfile.TemporaryDirectory() as tmp, sidecar(f"{tmp}/dp-*/v.sock", token=None) as base:
        status, _, _ = get(f"{base}/metrics", token="anything")
    assert status == 503, f"unset METRICS_TOKEN must fail closed, got {status}"


def test_socket_missing_serves_sidecar_series_only() -> None:
    with tempfile.TemporaryDirectory() as tmp, sidecar(f"{tmp}/dp-*/v.sock", TOKEN) as base:
        status, body, _ = get(f"{base}/metrics")
    assert status == 200, status
    assert body.startswith(b"dolphin_sidecar_up 1\n"), body[:80]
    assert b"dolphin_sidecar_proxy_ok 0\n" in body
    assert b"dolphin_sidecar_sockets_found 0\n" in body
    assert b"vllm:" not in body


def test_stale_newest_socket_falls_through() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        live = pathlib.Path(tmp) / "dp-1" / "v.sock"
        live.parent.mkdir()
        with fake_vllm(live, FIXTURE):
            stale = pathlib.Path(tmp) / "dp-2" / "v.sock"
            stale.parent.mkdir()
            stale.touch()  # newer mtime, nothing listening — must be skipped
            os.utime(live, (time.time() - 3600, time.time() - 3600))
            with sidecar(f"{tmp}/dp-*/v.sock", TOKEN) as base:
                status, body, _ = get(f"{base}/metrics")
    assert status == 200, status
    assert body.startswith(FIXTURE), "must fall through the dead newest socket to the live one"
    assert b"dolphin_sidecar_proxy_ok 1\n" in body
    assert b"dolphin_sidecar_sockets_found 2\n" in body


def test_health_endpoint() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        sock = pathlib.Path(tmp) / "dp-1" / "v.sock"
        sock.parent.mkdir()
        with fake_vllm(sock, FIXTURE), sidecar(f"{tmp}/dp-*/v.sock", TOKEN) as base:
            get(f"{base}/metrics")  # populate last_ok/socket state
            status, body, ctype = get(f"{base}/health")
    assert status == 200, status
    assert ctype.startswith("application/json"), ctype
    payload = json.loads(body)
    assert payload["sidecar_version"] == 1
    assert payload["sockets_found"] == 1
    assert payload["socket"].endswith("v.sock")
    assert payload["last_ok"] > 0


def test_post_rejected() -> None:
    with tempfile.TemporaryDirectory() as tmp, sidecar(f"{tmp}/dp-*/v.sock", TOKEN) as base:
        status, _, _ = get(f"{base}/metrics", method="POST")
    assert status == 405, status


def main() -> None:
    tests = [(name, fn) for name, fn in sorted(globals().items()) if name.startswith("test_")]
    failed = 0
    for name, fn in tests:
        try:
            fn()
            print(f"PASS {name}")
        except Exception as e:
            failed += 1
            print(f"FAIL {name}: {e}")
    print(f"{len(tests) - failed}/{len(tests)} passed")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
