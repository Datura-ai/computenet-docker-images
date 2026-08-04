"""Sidecar contract tests (DAH-2550). Stdlib only, no pytest dependency:

    python3 tests/test_sidecar.py

The sidecar runs as a real subprocess, the same code path production runs, so the bearer check and
the log parsing are exercised over HTTP rather than by importing the functions.

Covered: auth, TH/s -> H/s per GPU, a card that stopped writing showing up as stale (value kept,
no longer counted as reporting) rather than vanishing, an empty log directory answering 503, and
the /logs tail.
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
PORT: int = 9313
BASE_URL: str = f"http://127.0.0.1:{PORT}"

failures: list[str] = []


def check(condition: bool, description: str) -> None:
    if condition:
        print(f"  ok: {description}")
    else:
        failures.append(description)
        print(f"  FAIL: {description}")


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


def start_sidecar(log_dir: str, gpu_count: str) -> subprocess.Popen:
    environment: dict[str, str] = {
        **os.environ,
        "METRICS_TOKEN": TOKEN,
        "METRICS_PORT": str(PORT),
        "PEARL_LOG_DIR": log_dir,
        "PEARL_GPU_COUNT": gpu_count,
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


STALE_AGE_SECONDS: int = 600


def write_gpu_logs(log_dir: str) -> None:
    """One GPU still hashing, one that went quiet ten minutes ago while its miner kept talking."""
    directory = pathlib.Path(log_dir)
    (directory / "gpu-0.log").write_text(
        "GPU #0 (sm: 86) initialized\nHashrate GPU #0 = 51.02 TH/s\nHashrate Total = 51.02 TH/s\n"
    )
    (directory / "rate-0.log").write_text("Hashrate GPU #0 = 47.50 TH/s\nHashrate GPU #0 = 51.02 TH/s\n")

    # GPU 1 stopped hashing ten minutes ago but its miner keeps printing pool chatter, so the full
    # log looks fresh and only the rate file tells the truth.
    stale_mtime: float = time.time() - STALE_AGE_SECONDS
    (directory / "gpu-1.log").write_text("Hashrate GPU #0 = 12.25 TH/s\nReceived new job: 7\n")
    stale_rate = directory / "rate-1.log"
    stale_rate.write_text("Hashrate GPU #0 = 12.25 TH/s\n")
    os.utime(stale_rate, (stale_mtime, stale_mtime))


def check_bearer_token_is_required() -> None:
    print("auth")
    status, _ = get("/metrics", token=None)
    check(status == 401, "no bearer token is rejected")
    status, _ = get("/metrics", token="wrong")
    check(status == 401, "wrong bearer token is rejected")
    status, _ = get("/logs", token=None)
    check(status == 401, "log tail needs the bearer token too")


def check_hashrate_and_freshness_series() -> None:
    print("metrics")
    status, body = get("/metrics")
    check(status == 200, "authorized scrape answers 200")
    check(
        sample(body, 'pearl_sidecar_gpu_hashrate_hs{gpu="0"}') == 51.02e12,
        "last TH/s sample of gpu 0 is exposed in hashes per second",
    )
    check(
        sample(body, 'pearl_sidecar_gpu_hashrate_hs{gpu="1"}') == 12.25e12,
        "a GPU that stopped writing keeps its last value instead of vanishing",
    )
    check(
        (sample(body, 'pearl_sidecar_gpu_sample_age_seconds{gpu="1"}') or 0) >= STALE_AGE_SECONDS,
        "the stale GPU's sample age reports how long it has been quiet",
    )
    check(
        (sample(body, 'pearl_sidecar_gpu_sample_age_seconds{gpu="0"}') or 999) < 60,
        "the live GPU's sample age is fresh",
    )
    check(
        sample(body, "pearl_sidecar_gpus_reporting") == 1,
        "a GPU silent past the stale cutoff stops counting as reporting",
    )
    check(
        sample(body, "pearl_sidecar_hashrate_total_hs") == 51.02e12,
        "the node total counts the hashing GPU only, so a dead card earns nothing downstream",
    )
    check(
        sample(body, "pearl_sidecar_gpus_expected") == 3,
        "expected GPU count comes from the launcher, so a dead process is visible",
    )


def check_log_tail_serves_miner_lines() -> None:
    print("logs")
    status, body = get("/logs?tail=64")
    check(status == 200, "log tail answers 200")
    check("TH/s" in body, "log tail carries the miner's own lines")


def check_live_and_stale_gpus() -> None:
    with tempfile.TemporaryDirectory() as log_dir:
        write_gpu_logs(log_dir)
        process = start_sidecar(log_dir, gpu_count="3")
        try:
            check_bearer_token_is_required()
            check_hashrate_and_freshness_series()
            check_log_tail_serves_miner_lines()
        finally:
            process.terminate()
            process.wait(timeout=10)


def check_empty_log_dir() -> None:
    with tempfile.TemporaryDirectory() as empty_dir:
        process = start_sidecar(empty_dir, gpu_count="1")
        try:
            print("no logs yet")
            status, body = get("/metrics")
            check(status == 503, "a scrape that found no GPU log answers 503, not 200")
            check(
                sample(body, "pearl_sidecar_gpus_reporting") == 0,
                "the body still states zero reporting GPUs",
            )
        finally:
            process.terminate()
            process.wait(timeout=10)


def main() -> None:
    check_live_and_stale_gpus()
    check_empty_log_dir()

    print()
    if failures:
        print(f"{len(failures)} failure(s):")
        for description in failures:
            print(f"  - {description}")
        raise SystemExit(1)
    print("all checks passed")


if __name__ == "__main__":
    main()
