"""Sidecar contract tests (DAH-2550, rewritten for PeakMiner in DAH-2688). Stdlib only, no pytest:

    python3 tests/test_sidecar.py

The sidecar runs as a real subprocess against a fake PeakMiner stats API, the same code path
production runs, so the bearer check and the JSON reading are exercised over HTTP rather than by
importing the functions. The payload below is a real /summary response captured from a live miner.

Covered: auth, per-GPU hashrate and share counts, a card reported at zero counting as not mining,
the accepted-share age that makes rejected work visible, a miner whose API is gone answering 503,
and the /logs tail. DAH-6084: per-GPU power from a stub nvidia-smi (a card reporting [N/A] is left out, and so
are the node totals), and the WildRig benchmark build reading WildRig's stats document.
"""

import http.server
import json
import os
import pathlib
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.request

SIDECAR_PATH: str = os.environ.get(
    "SIDECAR_PATH", str(pathlib.Path(__file__).resolve().parent.parent / "metrics_sidecar.py")
)
TOKEN: str = "test-token"
PORT: int = 9313
MINER_API_PORT: int = 9314
BASE_URL: str = f"http://127.0.0.1:{PORT}"
MINER_API_URL: str = f"http://127.0.0.1:{MINER_API_PORT}/summary"

LAST_SHARE_AGE_SECONDS: int = 90

failures: list[str] = []


def check(condition: bool, description: str) -> None:
    if condition:
        print(f"  ok: {description}")
    else:
        failures.append(description)
        print(f"  FAIL: {description}")


def summary_payload() -> dict:
    """One card hashing and taking shares, one present but stopped."""
    return {
        "version": "2.10.0",
        "algo": "pearl",
        "uptime": 600,
        "pool": {"url": "prl.kryptex.network:7048", "ping_ms": 35, "connected": True},
        "hashrate": 60.8e12,
        "accepted_shares": 7,
        "invalid_shares": 1,
        "last_share_at": time.time() - LAST_SHARE_AGE_SECONDS,
        "gpus": [
            {"id": 0, "name": "RTX A4000", "hashrate": 60.8e12, "accepted_shares": 7, "invalid_shares": 1},
            {"id": 1, "name": "RTX A4000", "hashrate": 0.0, "accepted_shares": 0, "invalid_shares": 0},
        ],
    }


def wildrig_payload() -> dict:
    """WildRig's stats document, in the fields its own HiveOS h-stats.sh reads: two cards, one hashing."""
    return {
        "version": "0.52.1",
        "algo": "pearlhash",
        "uptime": 600,
        "hashrate": {"total": [70.0e12, 69.0e12, 68.0e12], "threads": [[70.0e12, 69.0e12], [0.0, 0.0]]},
        "results": {"shares_good": 9, "shares_total": 11},
        "connection": {"pool": "prl.kryptex.network:7048", "uptime": 590},
    }


# GPU 0 under our 210 W cap, GPU 1 a card that reports no draw (left out, never read as 0 W).
NVIDIA_SMI_STUB: str = """#!/bin/sh
echo "0, 205.50, 210.00"
echo "1, [N/A], [N/A]"
"""
# Every card reports: the node totals are the sums.
NVIDIA_SMI_ALL_REPORTING: str = """#!/bin/sh
echo "0, 205.50, 210.00"
echo "1, 190.00, 210.00"
"""


class MinerApiHandler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt: str, *args) -> None:  # noqa: A003
        return

    def do_GET(self) -> None:  # noqa: N802
        body: bytes = json.dumps(wildrig_payload() if self.path == "/" else summary_payload()).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def get(path: str, token: str | None = TOKEN) -> tuple[int, str]:
    headers: dict[str, str] = {"Authorization": f"Bearer {token}"} if token is not None else {}
    request = urllib.request.Request(f"{BASE_URL}{path}", headers=headers)
    try:
        with urllib.request.urlopen(request, timeout=5) as response:
            return response.status, response.read().decode()
    except urllib.error.HTTPError as error:
        return error.code, error.read().decode()


def sample(body: str, name: str) -> float | None:
    for line in body.splitlines():
        if line.startswith(name) and not line.startswith("#"):
            return float(line.rsplit(maxsplit=1)[-1])
    return None


def start_sidecar(
    log_dir: str, gpu_count: str, miner: str = "peakminer", nvidia_smi: str = NVIDIA_SMI_STUB
) -> subprocess.Popen:
    stub_dir: str = tempfile.mkdtemp()
    stub: pathlib.Path = pathlib.Path(stub_dir) / "nvidia-smi"
    stub.write_text(nvidia_smi)
    stub.chmod(0o755)
    environment: dict[str, str] = {
        **os.environ,
        "PATH": f"{stub_dir}:{os.environ.get('PATH', '')}",
        "PEARL_MINER": miner,
        "METRICS_TOKEN": TOKEN,
        "METRICS_PORT": str(PORT),
        "PEARL_LOG_DIR": log_dir,
        "PEARL_GPU_COUNT": gpu_count,
        "PEAK_API_URL": MINER_API_URL if miner == "peakminer" else f"http://127.0.0.1:{MINER_API_PORT}/",
    }
    process = subprocess.Popen([sys.executable, SIDECAR_PATH], env=environment)
    for _ in range(50):
        try:
            urllib.request.urlopen(f"{BASE_URL}/metrics", timeout=1)
        except urllib.error.HTTPError:
            return process  # answering 401 means it is up
        except OSError:
            time.sleep(0.1)
    return process


def write_miner_log(log_dir: str) -> None:
    (pathlib.Path(log_dir) / "peakminer.log").write_text(
        "INFO connected prl.kryptex.network:7048  diff -  ping 35ms\nINFO new job 6c77ef86_2097152\n"
    )


def check_bearer_token_is_required() -> None:
    print("auth")
    status, _ = get("/metrics", token=None)
    check(status == 401, "no bearer token is rejected")
    status, _ = get("/metrics", token="wrong")
    check(status == 401, "wrong bearer token is rejected")
    status, _ = get("/logs", token=None)
    check(status == 401, "log tail needs the bearer token too")


def check_hashrate_and_share_series() -> None:
    print("metrics")
    status, body = get("/metrics")
    check(status == 200, "authorized scrape answers 200")
    check(
        sample(body, 'pearl_sidecar_gpu_hashrate_hs{gpu="0"}') == 60.8e12,
        "the hashing GPU's rate is exposed in hashes per second",
    )
    check(
        sample(body, 'pearl_sidecar_gpu_hashrate_hs{gpu="1"}') == 0,
        "a GPU the miner reports at zero stays in the series instead of vanishing",
    )
    check(
        sample(body, 'pearl_sidecar_gpu_accepted_shares{gpu="0"}') == 7,
        "per-GPU accepted shares are exposed, so work that never counts is visible per card",
    )
    check(
        sample(body, 'pearl_sidecar_gpu_invalid_shares{gpu="0"}') == 1,
        "per-GPU invalid shares are exposed next to the accepted ones",
    )
    check(sample(body, "pearl_sidecar_accepted_shares") == 7, "node accepted shares are exposed")
    check(sample(body, "pearl_sidecar_invalid_shares") == 1, "node invalid shares are exposed")
    check(sample(body, "pearl_sidecar_pool_connected") == 1, "a live stratum connection reports as connected")
    check(
        sample(body, "pearl_sidecar_gpus_reporting") == 1,
        "only GPUs actually hashing count as reporting",
    )
    check(
        sample(body, "pearl_sidecar_gpus_expected") == 3,
        "expected GPU count comes from the launcher, so a card the miner never picked up is visible",
    )
    check(
        sample(body, "pearl_sidecar_hashrate_total_hs") == 60.8e12,
        "the node total is the miner's own total",
    )
    age: float | None = sample(body, "pearl_sidecar_last_share_age_seconds")
    check(
        age is not None and LAST_SHARE_AGE_SECONDS <= age < LAST_SHARE_AGE_SECONDS + 60,
        "the age of the last accepted share is exposed",
    )


def check_power_series() -> None:
    print("power")
    _, body = get("/metrics")
    check(sample(body, 'pearl_sidecar_gpu_power_draw_watts{gpu="0"}') == 205.5, "per-GPU power draw is exposed")
    check(sample(body, 'pearl_sidecar_gpu_power_limit_watts{gpu="0"}') == 210, "per-GPU power limit is exposed")
    check(sample(body, 'pearl_sidecar_gpu_power_draw_watts{gpu="1"}') is None, "a card reporting [N/A] is left out")
    check(sample(body, "pearl_sidecar_power_draw_watts_total") is None, "no draw total while a card reads [N/A]")
    check(sample(body, "pearl_sidecar_power_limit_watts_total") is None, "no limit total while a card reads [N/A]")


def check_wildrig_build() -> None:
    with tempfile.TemporaryDirectory() as log_dir:
        (pathlib.Path(log_dir) / "wildrig.log").write_text("wildrig pearlhash new job\n")
        process = start_sidecar(log_dir, gpu_count="2", miner="wildrig", nvidia_smi=NVIDIA_SMI_ALL_REPORTING)
        try:
            print("wildrig")
            status, body = get("/metrics")
            check(status == 200, "a hashing WildRig answers 200")
            check(sample(body, 'pearl_sidecar_gpu_hashrate_hs{gpu="0"}') == 70.0e12, "per-GPU rate is the current one")
            check(sample(body, 'pearl_sidecar_gpu_hashrate_hs{gpu="1"}') == 0, "an idle card stays in the series")
            check(sample(body, "pearl_sidecar_hashrate_total_hs") == 70.0e12, "node total is WildRig's current total")
            check(sample(body, "pearl_sidecar_gpus_reporting") == 1, "only the hashing card is reporting")
            check(sample(body, "pearl_sidecar_accepted_shares") == 9, "node accepted shares are WildRig's good shares")
            check(sample(body, "pearl_sidecar_invalid_shares") == 2, "invalid shares are total minus good")
            check(sample(body, "pearl_sidecar_pool_connected") == 1, "a pool connection with uptime is connected")
            check("pearl_sidecar_gpu_accepted_shares{" not in body, "no per-GPU share series WildRig does not report")
            check(sample(body, "pearl_sidecar_power_draw_watts_total") == 395.5, "node draw is the sum of the cards")
            check(sample(body, "pearl_sidecar_power_limit_watts_total") == 420, "node limit is the sum of the cards")
            status, body = get("/logs?tail=256")
            check(status == 200 and "new job" in body, "the log tail serves wildrig.log")
        finally:
            process.terminate()
            process.wait(timeout=10)


def check_log_tail_serves_miner_lines() -> None:
    print("logs")
    status, body = get("/logs?tail=256")
    check(status == 200, "log tail answers 200")
    check("new job" in body, "log tail carries the miner's own lines")


def check_live_miner() -> None:
    with tempfile.TemporaryDirectory() as log_dir:
        write_miner_log(log_dir)
        process = start_sidecar(log_dir, gpu_count="3")
        try:
            check_bearer_token_is_required()
            check_hashrate_and_share_series()
            check_power_series()
            check_log_tail_serves_miner_lines()
        finally:
            process.terminate()
            process.wait(timeout=10)


def check_miner_api_down(miner_api: http.server.ThreadingHTTPServer) -> None:
    miner_api.shutdown()
    with tempfile.TemporaryDirectory() as empty_dir:
        process = start_sidecar(empty_dir, gpu_count="1")
        try:
            print("miner api gone")
            status, body = get("/metrics")
            check(status == 503, "a scrape that cannot reach the miner answers 503, not 200")
            check(sample(body, "pearl_sidecar_gpus_reporting") == 0, "the body still states zero reporting GPUs")
            check(sample(body, "pearl_sidecar_pool_connected") == 0, "an unreachable miner is not connected to a pool")
            check(sample(body, "pearl_sidecar_accepted_shares") == 0, "share counts fall back to zero rather than vanishing")
        finally:
            process.terminate()
            process.wait(timeout=10)


def main() -> None:
    miner_api = http.server.ThreadingHTTPServer(("127.0.0.1", MINER_API_PORT), MinerApiHandler)
    threading.Thread(target=miner_api.serve_forever, daemon=True).start()
    try:
        check_live_miner()
        check_wildrig_build()
        check_miner_api_down(miner_api)
    finally:
        miner_api.server_close()

    print()
    if failures:
        print(f"{len(failures)} failure(s):")
        for description in failures:
            print(f"  - {description}")
        raise SystemExit(1)
    print("all checks passed")


if __name__ == "__main__":
    main()
