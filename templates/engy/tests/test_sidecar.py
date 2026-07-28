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


def start_sidecar(log_file: str) -> subprocess.Popen:
    process = subprocess.Popen(
        [sys.executable, SIDECAR_PATH],
        env={
            **os.environ,
            "METRICS_TOKEN": TOKEN,
            "METRICS_PORT": str(PORT),
            "ENGY_LOG_FILE": log_file,
            # No engine is running in a test; /metrics answers 503 and that is a covered case.
            "ENGY_METRICS_TARGETS": "http://127.0.0.1:1",
        },
    )
    for _ in range(50):
        try:
            get("/metrics")
            return process
        except OSError:
            time.sleep(0.2)
    raise RuntimeError("sidecar never came up")


def main() -> int:
    with tempfile.TemporaryDirectory() as workdir:
        log_file: str = os.path.join(workdir, "miner.log")
        with open(log_file, "w", encoding="utf-8") as handle:
            for line_number in range(20000):
                handle.write(f"[engy-miner] line {line_number} padding-padding-padding\n")
            handle.write("[engy-miner] LAST-LINE\n")

        sidecar = start_sidecar(log_file)
        try:
            print("== /logs is behind the same bearer token as /metrics ==")
            status, _ = get("/logs", token=None)
            check(status == 401, "no token -> 401")
            status, _ = get("/logs", token="wrong-token")
            check(status == 401, "wrong token -> 401")

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

            print("== a missing log degrades instead of failing the scrape ==")
            os.remove(log_file)
            status, body = get("/logs")
            check(status == 200 and b"log unavailable" in body, "missing file -> 200 with a reason")

            print("== the metrics route still works next to /logs ==")
            status, _ = get("/metrics")
            check(status == 503, "unreachable engines -> 503, not a crash")
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
