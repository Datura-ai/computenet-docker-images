"""Expose the PEARL container's per-GPU hashrate and miner log on :9101 for the platform.

Same contract as the Dolphin and engy sidecars (bearer token, fail-closed, port 9101), simpler
plumbing: pearl-miner has no metrics port and no HTTP of any kind — the stripped binary's only
output is stdout, one line per GPU every ~5s:

    Hashrate GPU #0 = 51.02 TH/s

The entrypoint tees each per-GPU process into PEARL_LOG_DIR/gpu-<i>.log, and this reads the tail of
each file. Hashrate is the ONLY signal the miner emits — it prints no accepted/rejected shares — so
downstream revenue attribution is a hashrate-weighted split of the wallet payout, never measured
accepted work.

  PEARL_LOG_DIR=/var/log/pearl PEARL_GPU_COUNT=8 METRICS_TOKEN=… python3 metrics_sidecar.py

Two routes, both behind the same bearer token:
  /metrics        per-GPU hashrate, per-GPU age of that sample, reporting vs expected GPU count
  /logs?tail=N    the tail of the miner logs, because on a miner's host the container's stdout goes
                  to a docker pipe we cannot reach

Without METRICS_TOKEN it refuses to start: an unauthenticated port on a miner's host would publish
our fleet's hashrate to whoever scans it.
"""

import hmac
import http.server
import os
import re
import sys
import time
import urllib.parse

from dataclasses import dataclass

PORT: int = int(os.environ.get("METRICS_PORT", "9101"))
TOKEN: str = os.environ.get("METRICS_TOKEN", "")
LOG_DIR: str = os.environ.get("PEARL_LOG_DIR", "/var/log/pearl")
# How many miner processes the entrypoint launched. Kept as its own series rather than inferred from
# the files present: a process that died before writing its first line leaves no file, and "2 of 8
# GPUs reporting" is the alert, while a bare count of 2 reads as a healthy 2-card node.
EXPECTED_GPUS: int = int(os.environ.get("PEARL_GPU_COUNT", "0"))
# Enough to hold several minutes of a 5s cadence even if the miner starts printing more per line.
TAIL_BYTES: int = 65536
# A GPU counts as reporting only while its log is still moving. The miner prints every ~5s, so a
# minute of silence is a stopped card, not a slow one. Without this a miner that is alive but has
# stopped hashing (GPU fell off the bus, engine wedged) keeps its last rate forever and
# gpus_reporting stays at full — the exact "N of 8 cards mining" alert this port exists to raise
# would never fire. The stale value itself is still served, next to its age.
STALE_AFTER_SECONDS: float = 60.0
LOG_TAIL_DEFAULT_BYTES: int = 262144
LOG_TAIL_MAX_BYTES: int = 8388608

LOG_NAME = re.compile(r"^gpu-(?P<index>\d+)\.log$")
# The miner's own index is always 0 (one process per GPU, pinned with CUDA_VISIBLE_DEVICES), so the
# label comes from the FILE name; only the rate is read off the line.
HASHRATE_LINE = re.compile(r"^Hashrate GPU #\d+ = (?P<rate>[0-9.]+) (?P<unit>[KMGTPE]?)H/s\s*$")
UNIT_SCALE: dict[str, float] = {
    "": 1.0, "K": 1e3, "M": 1e6, "G": 1e9, "T": 1e12, "P": 1e15, "E": 1e18,
}


@dataclass(frozen=True)
class MetricsSnapshot:
    """One rendered exposition and how many GPUs were mining when it was taken."""

    body: bytes
    reporting_gpus: int


def _log(message: str) -> None:
    print(f"[pearl-metrics] {message}", file=sys.stderr, flush=True)


def read_tail(path: str, max_bytes: int) -> str:
    """The last `max_bytes` of a file, starting at the first whole line."""
    try:
        with open(path, "rb") as handle:
            size: int = os.fstat(handle.fileno()).st_size
            start: int = max(0, size - max_bytes)
            handle.seek(start)
            if start:
                handle.readline()
            return handle.read().decode("utf-8", "replace")
    except OSError as error:
        _log(f"cannot read {path}: {error!r}")
        return ""


def last_hashrate(text: str) -> float | None:
    """Hashes per second from the most recent complete hashrate line, whatever unit it printed in."""
    for line in reversed(text.splitlines()):
        match = HASHRATE_LINE.match(line.strip())
        if match is not None:
            return float(match.group("rate")) * UNIT_SCALE[match.group("unit")]
    return None


def collect() -> MetricsSnapshot:
    """Per-GPU hashrate series plus the reporting/expected counts, and how many GPUs answered.

    A GPU whose file stopped growing keeps its last value and grows an age instead of disappearing:
    a vanished series reads as "this card was never here", while a frozen one plus its age says the
    miner stopped — which is the failure we cannot see today. It stops counting as REPORTING though,
    so reporting-vs-expected answers "how many cards are mining right now".
    """
    now: float = time.time()
    hashrate_lines: list[str] = []
    age_lines: list[str] = []
    reporting_gpus: int = 0
    try:
        names: list[str] = sorted(os.listdir(LOG_DIR))
    except OSError as error:
        _log(f"cannot list {LOG_DIR}: {error!r}")
        names = []
    for name in names:
        match = LOG_NAME.match(name)
        if match is None:
            continue
        path: str = os.path.join(LOG_DIR, name)
        rate: float | None = last_hashrate(read_tail(path, TAIL_BYTES))
        if rate is None:
            continue  # the process started but has not printed a rate yet (GPU init takes ~10s)
        index: str = match.group("index")
        try:
            age: float = max(0.0, now - os.path.getmtime(path))
        except OSError:
            age = 0.0
        hashrate_lines.append(f'pearl_sidecar_gpu_hashrate_hs{{gpu="{index}"}} {rate:.0f}')
        age_lines.append(f'pearl_sidecar_gpu_sample_age_seconds{{gpu="{index}"}} {age:.1f}')
        if age <= STALE_AFTER_SECONDS:
            reporting_gpus += 1
    body: str = "\n".join(
        [
            "# HELP pearl_sidecar_gpu_hashrate_hs Last hashrate the miner printed for this GPU, in hashes per second.",
            "# TYPE pearl_sidecar_gpu_hashrate_hs gauge",
            *hashrate_lines,
            "# HELP pearl_sidecar_gpu_sample_age_seconds Seconds since that GPU's log was last written.",
            "# TYPE pearl_sidecar_gpu_sample_age_seconds gauge",
            *age_lines,
            "# HELP pearl_sidecar_gpus_reporting GPUs whose hashrate line is younger than the stale cutoff.",
            "# TYPE pearl_sidecar_gpus_reporting gauge",
            f"pearl_sidecar_gpus_reporting {reporting_gpus}",
            "# HELP pearl_sidecar_gpus_expected Miner processes the entrypoint launched.",
            "# TYPE pearl_sidecar_gpus_expected gauge",
            f"pearl_sidecar_gpus_expected {EXPECTED_GPUS}",
            "",
        ]
    )
    return MetricsSnapshot(body=body.encode("utf-8"), reporting_gpus=reporting_gpus)


def read_log_tail(max_bytes: int) -> bytes:
    """Every GPU's log tail, concatenated with a header per file so they stay tellable apart."""
    try:
        names = sorted(name for name in os.listdir(LOG_DIR) if LOG_NAME.match(name))
    except OSError as error:
        return f"logs unavailable: {error!r}\n".encode()
    if not names:
        return b"no miner logs yet\n"
    per_file: int = max(1024, max_bytes // len(names))
    chunks: list[str] = [f"===== {name} =====\n{read_tail(os.path.join(LOG_DIR, name), per_file)}" for name in names]
    return "\n".join(chunks).encode("utf-8")


def requested_tail_bytes(query: str) -> int:
    tail_values: list[str] = urllib.parse.parse_qs(query).get("tail", [])
    if tail_values and tail_values[0].isdigit():
        return min(int(tail_values[0]), LOG_TAIL_MAX_BYTES)
    return LOG_TAIL_DEFAULT_BYTES


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt: str, *args) -> None:  # noqa: A003
        return  # otherwise one access-log line per scrape, forever

    def _reply(self, status: int, body: bytes, content_type: str) -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _authorized(self) -> bool:
        # Constant-time, like the Dolphin and engy sidecars: a plain == leaks the token one byte at a
        # time to anyone who can time this port.
        return hmac.compare_digest(self.headers.get("Authorization", ""), f"Bearer {TOKEN}")

    def do_GET(self) -> None:  # noqa: N802
        route, _, query = self.path.partition("?")
        if route not in ("/metrics", "/logs"):
            self._reply(404, b"not found\n", "text/plain")
            return
        if not self._authorized():
            self._reply(401, b"unauthorized\n", "text/plain")
            return
        if route == "/logs":
            self._reply(200, read_log_tail(requested_tail_bytes(query)), "text/plain")
            return
        snapshot = collect()
        # 503 when no GPU is mining: an empty 200 reads as "this node mines zero", a different alert
        # from "the container is not running miners". The counts are in the body either way.
        self._reply(200 if snapshot.reporting_gpus else 503, snapshot.body, "text/plain; version=0.0.4")


def main() -> None:
    if not TOKEN:
        _log("METRICS_TOKEN is required — refusing to expose an unauthenticated metrics port.")
        raise SystemExit(1)
    _log(f"serving :{PORT}/metrics from {LOG_DIR} for {EXPECTED_GPUS} GPU(s)")
    http.server.ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()


if __name__ == "__main__":
    main()
