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
    status: int = 200

    def do_GET(self) -> None:  # noqa: N802
        self.send_response(self.status)
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

    def handle_error(self, request, client_address) -> None:
        # the sidecar closes a non-200 upstream mid-body; the resulting broken
        # pipe on our side is expected, not a test failure
        exc = sys.exc_info()[1]
        if isinstance(exc, (BrokenPipeError, ConnectionResetError)):
            return
        super().handle_error(request, client_address)


@contextlib.contextmanager
def fake_vllm(sock_path: pathlib.Path, body: bytes, status: int = 200):
    # minimal HTTP-over-unix-socket server standing in for the vLLM engine
    handler = type("H", (_UdsHandler,), {"body": body, "status": status})
    server = _UdsServer(str(sock_path), handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield
    finally:
        server.shutdown()
        server.server_close()


@contextlib.contextmanager
def garbage_uds(sock_path: pathlib.Path):
    # a listener that speaks non-HTTP, so http.client raises BadStatusLine:
    # exercises the fetch fall-through that must NOT crash the endpoint
    srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    srv.bind(str(sock_path))
    srv.listen(8)
    srv.settimeout(0.2)
    stop = threading.Event()

    def serve() -> None:
        while not stop.is_set():
            try:
                conn, _ = srv.accept()
            except OSError:
                continue
            try:
                conn.recv(4096)
                conn.sendall(b"i am not http\r\n\r\n")
            except OSError:
                pass
            finally:
                conn.close()

    thread = threading.Thread(target=serve, daemon=True)
    thread.start()
    try:
        yield
    finally:
        stop.set()
        srv.close()


@contextlib.contextmanager
def sidecar(glob_pattern: str, token: str | None, extra_env: dict[str, str] | None = None):
    # run the real sidecar as a subprocess, wait until it listens
    port = free_port()
    env = dict(os.environ)
    env["METRICS_PORT"] = str(port)
    env["METRICS_SOCKET_GLOB"] = glob_pattern
    env.pop("METRICS_TOKEN", None)
    if token is not None:
        env["METRICS_TOKEN"] = token
    env.update(extra_env or {})
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
    assert b"dolphin_sidecar_version 2\n" in body
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


def test_upstream_non_200_falls_through_to_sidecar_only() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        sock = pathlib.Path(tmp) / "dp-1" / "v.sock"
        sock.parent.mkdir()
        with fake_vllm(sock, FIXTURE, status=500), sidecar(f"{tmp}/dp-*/v.sock", TOKEN) as base:
            status, body, _ = get(f"{base}/metrics")
    assert status == 200, status
    assert b"vllm:" not in body, "a non-200 upstream must be skipped, not passed through"
    assert b"dolphin_sidecar_proxy_ok 0\n" in body
    assert b"dolphin_sidecar_sockets_found 1\n" in body


def test_non_http_socket_does_not_crash_endpoint() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        sock = pathlib.Path(tmp) / "dp-1" / "v.sock"
        sock.parent.mkdir()
        with garbage_uds(sock), sidecar(f"{tmp}/dp-*/v.sock", TOKEN) as base:
            status, body, _ = get(f"{base}/metrics")
    assert status == 200, "a non-HTTP listener must fall through, not crash the request"
    assert b"vllm:" not in body
    assert b"dolphin_sidecar_proxy_ok 0\n" in body


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
    assert payload["sidecar_version"] == 2
    assert payload["sockets_found"] == 1
    assert payload["socket"].endswith("v.sock")
    assert payload["last_ok"] > 0


def test_post_rejected() -> None:
    with tempfile.TemporaryDirectory() as tmp, sidecar(f"{tmp}/dp-*/v.sock", TOKEN) as base:
        status, _, _ = get(f"{base}/metrics", method="POST")
    assert status == 405, status


# --- multi-engine (DAH-2465) -------------------------------------------------
#
# One container can run N worker instances, so N vLLM engines answer on N sockets. Every real
# engine labels itself engine="0" with the same model_name, so their label sets are IDENTICAL:
# concatenating bodies untagged yields duplicate series, and picking one (the old "first good
# response wins") publishes 1/N of the tokens with nothing to signal it. These tests pin the
# property that actually matters — no tokens are lost and no series collide.


def _load_sidecar_module():
    # import the shipped file directly; its module body only reads env, nothing starts
    import importlib.util

    spec = importlib.util.spec_from_file_location("sidecar_under_test", SIDECAR_PATH)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _samples(body: bytes, metric: bytes) -> list[tuple[bytes, float]]:
    # every (label_set, value) pair for one metric name in an exposition body
    found = []
    for line in body.split(b"\n"):
        line = line.strip()
        if not line.startswith(metric):
            continue
        rest = line[len(metric):]
        if rest[:1] not in (b"{", b" ", b"\t"):
            continue  # a longer metric name that merely starts the same way
        labels, _, value = rest.rpartition(b" ")
        found.append((labels.strip(), float(value)))
    return found


def _fixture_with_generated(value: float) -> bytes:
    # same real body, different token counter, so the two engines are distinguishable
    out = []
    for line in FIXTURE.split(b"\n"):
        if line.startswith(b"vllm:generation_tokens_total{"):
            labels, _, _ = line.rpartition(b" ")
            out.append(labels + b" " + str(value).encode())
        else:
            out.append(line)
    return b"\n".join(out)


@contextlib.contextmanager
def _two_engines(tmp: str, body_a: bytes, body_b: bytes):
    sock_a = pathlib.Path(tmp) / "dp-aaa" / "v.sock"
    sock_b = pathlib.Path(tmp) / "dp-bbb" / "v.sock"
    sock_a.parent.mkdir()
    sock_b.parent.mkdir()
    with fake_vllm(sock_a, body_a), fake_vllm(sock_b, body_b):
        yield


def test_two_engines_lose_no_tokens() -> None:
    # THE regression test for the single-engine bug: the totals of both engines must both
    # reach the scraper, which sums across label sets.
    a, b = _fixture_with_generated(19340.0), _fixture_with_generated(500.0)
    with tempfile.TemporaryDirectory() as tmp:
        with _two_engines(tmp, a, b), sidecar(f"{tmp}/dp-*/v.sock", TOKEN) as base:
            _, body, _ = get(f"{base}/metrics")
    samples = _samples(body, b"vllm:generation_tokens_total")
    assert len(samples) == 2, f"expected one series per engine, got {samples}"
    assert sum(value for _, value in samples) == 19840.0, samples


def test_two_engines_get_distinct_label_sets() -> None:
    # identical upstream labels must not collapse: a scraper that keys by label set would
    # otherwise keep only one engine's value
    a, b = _fixture_with_generated(1.0), _fixture_with_generated(2.0)
    with tempfile.TemporaryDirectory() as tmp:
        with _two_engines(tmp, a, b), sidecar(f"{tmp}/dp-*/v.sock", TOKEN) as base:
            _, body, _ = get(f"{base}/metrics")
    label_sets = [labels for labels, _ in _samples(body, b"vllm:generation_tokens_total")]
    assert len(set(label_sets)) == 2, label_sets
    assert all(b'dolphin_engine="dp-' in labels for labels in label_sets), label_sets


def test_two_engines_report_up_count() -> None:
    a, b = _fixture_with_generated(1.0), _fixture_with_generated(2.0)
    with tempfile.TemporaryDirectory() as tmp:
        with _two_engines(tmp, a, b), sidecar(
            f"{tmp}/dp-*/v.sock", TOKEN, {"DOLPHIN_ENGINES_EXPECTED": "2"}
        ) as base:
            _, body, _ = get(f"{base}/metrics")
    assert b"dolphin_engines_up 2\n" in body
    assert b"dolphin_engines_expected 2\n" in body


def test_dead_engine_reads_as_a_gap_not_a_smaller_number() -> None:
    # with N engines behind one port, a dead engine only makes the token total smaller, which
    # is indistinguishable from a quiet machine. up < expected is what makes it visible.
    with tempfile.TemporaryDirectory() as tmp:
        sock = pathlib.Path(tmp) / "dp-aaa" / "v.sock"
        sock.parent.mkdir()
        (pathlib.Path(tmp) / "dp-dead").mkdir()  # socket dir with no listener
        with fake_vllm(sock, FIXTURE), sidecar(
            f"{tmp}/dp-*/v.sock", TOKEN, {"DOLPHIN_ENGINES_EXPECTED": "2"}
        ) as base:
            _, body, _ = get(f"{base}/metrics")
    assert b"dolphin_engines_up 1\n" in body
    assert b"dolphin_engines_expected 2\n" in body
    assert b"dolphin_sidecar_proxy_ok 1\n" in body, "one live engine still means proxy_ok"


def test_split_container_labels_the_survivor_while_a_sibling_is_down() -> None:
    # The label must not depend on how many engines answered this scrape: dropping it for the
    # minutes a sibling spends restarting makes the survivor a different series to the scraper
    # — its counter reads as gone, and the relabelled one as a fresh counter starting at zero.
    with tempfile.TemporaryDirectory() as tmp:
        sock = pathlib.Path(tmp) / "dp-aaa" / "v.sock"
        sock.parent.mkdir()
        (pathlib.Path(tmp) / "dp-restarting").mkdir()  # socket dir with no listener
        with fake_vllm(sock, FIXTURE), sidecar(
            f"{tmp}/dp-*/v.sock", TOKEN, {"DOLPHIN_ENGINES_EXPECTED": "2"}
        ) as base:
            _, body, _ = get(f"{base}/metrics")
    label_sets = [labels for labels, _ in _samples(body, b"vllm:generation_tokens_total")]
    assert label_sets, "the live engine's counter must still be published"
    assert all(b'dolphin_engine="dp-aaa"' in labels for labels in label_sets), label_sets


def test_metric_families_stay_contiguous() -> None:
    # Exposition validity: every sample of one metric family must form a single block.
    # Concatenating two whole engine bodies would interleave families and break this.
    # A histogram's _bucket/_sum/_count belong to the family named by its # TYPE line, so
    # families -- not raw sample names -- are the unit that must stay together.
    a, b = _fixture_with_generated(1.0), _fixture_with_generated(2.0)
    with tempfile.TemporaryDirectory() as tmp:
        with _two_engines(tmp, a, b), sidecar(f"{tmp}/dp-*/v.sock", TOKEN) as base:
            _, body, _ = get(f"{base}/metrics")

    declared = {
        parts[2]
        for parts in (line.split() for line in body.split(b"\n"))
        if len(parts) >= 3 and parts[0] == b"#" and parts[1] == b"TYPE"
    }

    def family_of(name: bytes) -> bytes:
        if name in declared:
            return name
        for suffix in (b"_bucket", b"_sum", b"_count", b"_created", b"_total"):
            if name.endswith(suffix) and name[: -len(suffix)] in declared:
                return name[: -len(suffix)]
        return name

    assert declared, "no # TYPE lines survived the merge"
    seen: set[bytes] = set()
    previous = b""
    for line in body.split(b"\n"):
        line = line.strip()
        if not line or line.startswith(b"#"):
            continue
        family = family_of(line.split(b"{")[0].split(b" ")[0])
        if family != previous:
            assert family not in seen, f"family {family!r} appears in two separate blocks"
            seen.add(family)
            previous = family


def test_tag_series_survives_braces_inside_label_values() -> None:
    # a naive rfind/index on "}" would cut inside the value and corrupt the line
    module = _load_sidecar_module()
    line = b'vllm:x{model_name="a}b",engine="0"} 5.0'
    tagged = module.tag_series(line, "dp-zzz").strip()
    assert tagged == b'vllm:x{model_name="a}b",engine="0",dolphin_engine="dp-zzz"} 5.0', tagged


def test_tag_series_adds_braces_when_line_has_no_labels() -> None:
    module = _load_sidecar_module()
    tagged = module.tag_series(b"vllm:x 5.0", "dp-zzz").strip()
    assert tagged == b'vllm:x{dolphin_engine="dp-zzz"} 5.0', tagged


def test_engine_id_comes_from_the_socket_directory() -> None:
    module = _load_sidecar_module()
    assert module.engine_id("/tmp/dp-4f2a/v.sock") == "dp-4f2a"


def test_scrape_budget_grows_with_engine_count_but_stays_under_the_client_timeout() -> None:
    # One deadline covers all engines, so a fixed budget would drop the tail on a wide node --
    # the same undercount the fan-out exists to prevent. The cap keeps it under the scraper's
    # 8 s client timeout.
    previous = os.environ.get("DOLPHIN_ENGINES_EXPECTED")
    try:
        budgets = {}
        for expected in ("0", "1", "2", "8", "64"):
            os.environ["DOLPHIN_ENGINES_EXPECTED"] = expected
            budgets[expected] = _load_sidecar_module().TOTAL_BUDGET_S
    finally:
        if previous is None:
            os.environ.pop("DOLPHIN_ENGINES_EXPECTED", None)
        else:
            os.environ["DOLPHIN_ENGINES_EXPECTED"] = previous
    assert budgets["0"] == 4.0, budgets
    assert budgets["1"] == 4.0, budgets
    assert budgets["8"] > budgets["2"] > budgets["1"], budgets
    assert budgets["64"] <= 7.0, budgets


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
