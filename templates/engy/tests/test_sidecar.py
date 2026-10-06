"""Sidecar /logs contract tests (DAH-2495). Stdlib only, no pytest dependency:

    python3 tests/test_sidecar.py

The sidecar runs as a real subprocess, the same code path production runs, so the bearer check and
the tail arithmetic are exercised over HTTP rather than by importing the functions.

Covered: auth on /logs, whole-line tail start, ?tail= clamping, a missing log file degrading to 200
rather than 500, and /metrics still answering next to the new route.
"""

import os
import pathlib
import subprocess
import sys
import tempfile
import time
import http.server
import threading
import urllib.error
import urllib.request

SIDECAR_PATH: str = os.environ.get(
    "SIDECAR_PATH", str(pathlib.Path(__file__).resolve().parent.parent / "metrics_sidecar.py")
)
TOKEN: str = "test-token"
PORT: int = 9312
BASE_URL: str = f"http://127.0.0.1:{PORT}"

failures: list[str] = []


def check(condition: bool, description: str) -> None:
    if condition:
        print(f"  ok: {description}")
    else:
        failures.append(description)
        print(f"  FAIL: {description}")


def get(path: str, token: str | None = TOKEN) -> tuple[int, bytes]:
    request = urllib.request.Request(f"{BASE_URL}{path}")
    if token is not None:
        request.add_header("Authorization", f"Bearer {token}")
    try:
        with urllib.request.urlopen(request, timeout=5) as response:
            return response.status, response.read()
    except urllib.error.HTTPError as error:
        return error.code, error.read()


class FakeEngine:
    """A minimal /metrics server standing in for one sglang engine."""

    def __init__(self, delay_seconds: float, body: str) -> None:
        self.delay_seconds: float = delay_seconds
        self.body: str = body
        handler = self._build_handler()
        self._server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
        self.port: int = self._server.server_address[1]
        self._thread = threading.Thread(target=self._server.serve_forever, daemon=True)
        self._thread.start()

    @property
    def url(self) -> str:
        return f"http://127.0.0.1:{self.port}"

    def _build_handler(self) -> type:
        engine = self

        class Handler(http.server.BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def log_message(self, fmt: str, *args) -> None:  # noqa: A003
                return

            def do_GET(self) -> None:  # noqa: N802
                time.sleep(engine.delay_seconds)
                payload = engine.body.encode()
                self.send_response(200)
                self.send_header("Content-Type", "text/plain")
                self.send_header("Content-Length", str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)

        return Handler

    def shutdown(self) -> None:
        self._server.shutdown()
        self._server.server_close()


def start_slow_engine() -> FakeEngine:
    # Longer than the whole scrape budget: sequentially this one alone consumed it.
    return FakeEngine(delay_seconds=30.0, body="# TYPE sglang:slow gauge\nsglang:slow 1\n")


def start_fast_engine() -> FakeEngine:
    return FakeEngine(
        delay_seconds=0.0,
        body="# TYPE sglang:generation_tokens_total counter\nsglang:generation_tokens_total 42\n",
    )


def start_sidecar(log_file: str, probe_dir: str, targets: str = "http://127.0.0.1:1") -> subprocess.Popen:
    process = subprocess.Popen(
        [sys.executable, SIDECAR_PATH],
        env={
            **os.environ,
            "METRICS_TOKEN": TOKEN,
            "METRICS_PORT": str(PORT),
            "ENGY_LOG_FILE": log_file,
            "ENGY_PROBE_DIR": probe_dir,
            "ENGY_METRICS_TARGETS": targets,
        },
    )
    for _ in range(50):
        try:
            get("/metrics")
            return process
        except OSError:
            time.sleep(0.2)
    raise RuntimeError("sidecar never came up")


def check_token_comparison_is_constant_time() -> None:
    """Guarded by reading the source, not by behaviour: `==` and `hmac.compare_digest` return the
    same answers and differ only in timing, so no HTTP-level assertion can tell them apart."""
    source: str = pathlib.Path(SIDECAR_PATH).read_text(encoding="utf-8")
    check("hmac.compare_digest" in source, "the bearer token is compared in constant time")


def restart_sidecar_targeting(target_urls: list[str], log_file: str, probe_dir: str) -> None:
    """Point a fresh sidecar at real engines; the module reads TARGETS once, at import."""
    global sidecar
    sidecar.terminate()
    sidecar.wait(timeout=10)
    sidecar = start_sidecar(log_file, probe_dir, targets=",".join(target_urls))


def main() -> int:
    with tempfile.TemporaryDirectory() as workdir:
        log_file: str = os.path.join(workdir, "miner.log")
        with open(log_file, "w", encoding="utf-8") as handle:
            for line_number in range(20000):
                handle.write(f"[engy-miner] line {line_number} padding-padding-padding\n")
            handle.write("[engy-miner] LAST-LINE\n")

        probe_dir: str = os.path.join(workdir, "probe")
        os.makedirs(probe_dir)
        # Two miners' files, plus the .tmp an in-progress atomic write leaves in the same directory.
        for worker in ("g0", "g1"):
            with open(os.path.join(probe_dir, f"loop-{worker}.prom"), "w", encoding="utf-8") as handle:
                handle.write(
                    "# HELP engy_miner_loop_lag_seconds_max Worst event-loop delay.\n"
                    "# TYPE engy_miner_loop_lag_seconds_max gauge\n"
                    f'engy_miner_loop_lag_seconds_max{{engy_worker="{worker}"}} 12.5\n'
                )
        with open(os.path.join(probe_dir, "loop-g2.prom.tmp"), "w", encoding="utf-8") as handle:
            handle.write("half-written garbage")

        global sidecar
        sidecar = start_sidecar(log_file, probe_dir)
        try:
            print("== /logs is behind the same bearer token as /metrics ==")
            status, _ = get("/logs", token=None)
            check(status == 401, "no token -> 401")
            status, _ = get("/logs", token="wrong-token")
            check(status == 401, "wrong token -> 401")
            status, _ = get("/logs", token=TOKEN[:-1])
            check(status == 401, "a token that is a prefix of the real one -> 401")
            check_token_comparison_is_constant_time()

            print("== the tail starts at a whole line and ends at the newest one ==")
            status, body = get("/logs?tail=2000")
            check(status == 200, "tail request -> 200")
            check(body.startswith(b"[engy-miner]"), "starts at a line boundary, not mid-line")
            check(body.rstrip().endswith(b"LAST-LINE"), "ends with the newest line")
            check(len(body) <= 2000, f"honours the byte cap (got {len(body)})")

            print("== the byte cap is clamped, not trusted ==")
            status, body = get("/logs?tail=99999999")
            check(status == 200 and len(body) <= 8388608, "oversized tail clamped to the max")
            status, body = get("/logs?tail=notanumber")
            check(status == 200, "junk tail value falls back to the default")

            print("== a tail window inside one huge line still returns something ==")
            # Progress bars redraw with \r, so a real log carries single lines of many KB; one was
            # measured at 11.9KB on a live node. Skipping the "partial first line" then ate the whole
            # window and /logs answered 200 with an empty body.
            with open(log_file, "a", encoding="utf-8") as handle:
                handle.write("[engy] " + "x" * 40000)
            status, body = get("/logs?tail=4000")
            check(status == 200 and len(body) > 0,
                  f"unterminated long line -> non-empty body (got {len(body)} bytes)")

            print("== a missing log degrades instead of failing the scrape ==")
            os.remove(log_file)
            status, body = get("/logs")
            check(status == 200 and b"log unavailable" in body, "missing file -> 200 with a reason")

            print("== the miners' loop-lag files reach /metrics ==")
            status, body = get("/metrics")
            check(b'engy_worker="g0"' in body and b'engy_worker="g1"' in body,
                  "both miners' loop-lag series are exposed")
            check(body.count(b"# HELP engy_miner_loop_lag_seconds_max") == 1,
                  "two miners produce ONE HELP line, so the exposition stays valid")
            check(b"half-written garbage" not in body,
                  "an in-progress atomic write (.tmp) is not served")

            print("== a scrape with probe data but no engine still serves the probes ==")
            # Prometheus discards the WHOLE body on a non-2xx, so a 503 here threw the loop-lag
            # series away exactly when no engine answered — when they matter most.
            check(status == 200, "unreachable engines + probe files -> 200, not 503")
            check(b"engy_sidecar_engines_reachable 0" in body,
                  "and engines_reachable 0 carries the engine alert instead")
            print("== one slow engine must not starve the others ==")
            # Sequentially, the first slow target spent the whole budget and every later engine was
            # skipped without a connection attempt — the undercount the shared budget exists to stop.
            slow = start_slow_engine()
            fast = start_fast_engine()
            try:
                restart_sidecar_targeting([slow.url, fast.url], log_file, probe_dir)
                status, body = get("/metrics")
                check(status == 200, "a slow first engine still yields 200")
                check(b"sglang:generation_tokens_total" in body,
                      "the FAST engine's metrics land in the body despite the slow one being first")
                check(b"engy_sidecar_engines_reachable 1" in body,
                      "and it is counted as reachable")
                # Bit 1, not bit 0: WHICH engine answered is what makes two scrapes' counters
                # comparable, and a bare count of 1 cannot say that the slow one was the absent one.
                check(b"engy_sidecar_engines_reachable_mask 2" in body,
                      "the mask names the engine that answered, not just how many did")
            finally:
                slow.shutdown()
                fast.shutdown()

            status, _ = get("/nope")
            check(status == 404, "unknown route -> 404")
        finally:
            sidecar.terminate()
            sidecar.wait(timeout=10)

    print()
    if failures:
        print(f"{len(failures)} failure(s)")
        return 1
    print("all sidecar contract tests passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
