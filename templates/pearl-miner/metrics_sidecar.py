"""Expose the PEARL container's per-GPU hashrate, accepted work and miner log on :9101.

Same contract as the Dolphin and engy sidecars (bearer token, fail-closed, port 9101). PeakMiner
serves its own stats on the container's loopback, so this reads that JSON instead of parsing stdout:

    GET http://127.0.0.1:4068/summary

  PEARL_LOG_DIR=/var/log/pearl PEARL_GPU_COUNT=8 METRICS_TOKEN=… python3 metrics_sidecar.py

That API is also why ACCEPTED SHARES are exported here, not just hashrate. Pearl's V3 hard fork
(2026-08-11) had the old miner submitting work the network rejected outright: every card sat at full
hashrate and 100% GPU util, the platform called the fleet healthy, and six days of mining earned
nothing. Hashrate says the GPU is busy; only accepted shares say the work counted.

Two routes, both behind the same bearer token:
  /metrics        per-GPU hashrate and share counts, the node total, accepted/invalid work, how long
                  since the pool took a share, and reporting vs expected GPU count
  /logs?tail=N    the tail of the miner log, because on a miner's host the container's stdout goes
                  to a docker pipe we cannot reach

Without METRICS_TOKEN it refuses to start: an unauthenticated port on a miner's host would publish
our fleet's hashrate to whoever scans it. PeakMiner's own API has no auth at all, which is why it
stays on the container's loopback and this port is the only way out.
"""

import hmac
import http.server
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

from dataclasses import dataclass

PORT: int = int(os.environ.get("METRICS_PORT", "9101"))
TOKEN: str = os.environ.get("METRICS_TOKEN", "")
LOG_DIR: str = os.environ.get("PEARL_LOG_DIR", "/var/log/pearl")
MINER_LOG_NAME: str = "peakminer.log"
# PeakMiner's stats API. Its default binding is the container's own loopback and it is left there.
MINER_API_URL: str = os.environ.get("PEAK_API_URL", "http://127.0.0.1:4068/summary")
MINER_API_TIMEOUT_SECONDS: float = 3.0
# How many GPUs the entrypoint counted at launch. Kept as its own series rather than inferred from
# what the miner reports: "2 of 8 GPUs reporting" is the alert, while a bare count of 2 reads as a
# healthy 2-card node.
EXPECTED_GPUS: int = int(os.environ.get("PEARL_GPU_COUNT", "0"))
LOG_TAIL_DEFAULT_BYTES: int = 262144
LOG_TAIL_MAX_BYTES: int = 8388608


@dataclass(frozen=True)
class GpuSample:
    """One card as the miner currently reports it."""

    index: int
    hashrate_hs: float
    accepted_shares: int
    invalid_shares: int


@dataclass(frozen=True)
class MinerSummary:
    """The miner's own view of this node: what it is hashing and what the pool has taken."""

    pool_connected: bool
    hashrate_hs: float
    accepted_shares: int
    invalid_shares: int
    last_share_at: float | None
    gpus: list[GpuSample]


@dataclass(frozen=True)
class MetricsSnapshot:
    """One rendered exposition and how many GPUs were hashing when it was taken."""

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


def fetch_summary() -> MinerSummary | None:
    """The miner's stats, or None while it is starting up, wedged, or already gone."""
    try:
        with urllib.request.urlopen(MINER_API_URL, timeout=MINER_API_TIMEOUT_SECONDS) as response:
            payload = json.loads(response.read())
    except (OSError, urllib.error.HTTPError, ValueError) as error:
        _log(f"cannot read {MINER_API_URL}: {error!r}")
        return None
    gpus: list[GpuSample] = [
        GpuSample(
            index=int(gpu["id"]),
            hashrate_hs=float(gpu["hashrate"]),
            accepted_shares=int(gpu["accepted_shares"]),
            invalid_shares=int(gpu["invalid_shares"]),
        )
        for gpu in payload.get("gpus", [])
    ]
    last_share_at = payload.get("last_share_at")
    return MinerSummary(
        pool_connected=bool(payload.get("pool", {}).get("connected", False)),
        hashrate_hs=float(payload.get("hashrate", 0.0)),
        accepted_shares=int(payload.get("accepted_shares", 0)),
        invalid_shares=int(payload.get("invalid_shares", 0)),
        last_share_at=float(last_share_at) if last_share_at is not None else None,
        gpus=gpus,
    )


def collect() -> MetricsSnapshot:
    """Per-GPU and node-level series, and how many GPUs are actually hashing.

    A GPU the miner reports at zero keeps its series at zero instead of disappearing: a vanished
    series reads as "this card was never here", while a zero says the card is present and dead.
    """
    summary: MinerSummary | None = fetch_summary()
    gpus: list[GpuSample] = summary.gpus if summary is not None else []
    reporting_gpus: int = sum(1 for gpu in gpus if gpu.hashrate_hs > 0)
    lines: list[str] = [
        "# HELP pearl_sidecar_gpu_hashrate_hs Hashrate the miner reports for this GPU, in hashes per second.",
        "# TYPE pearl_sidecar_gpu_hashrate_hs gauge",
        *(f'pearl_sidecar_gpu_hashrate_hs{{gpu="{gpu.index}"}} {gpu.hashrate_hs:.0f}' for gpu in gpus),
        "# HELP pearl_sidecar_gpu_accepted_shares Shares the pool accepted from this GPU since the miner started.",
        "# TYPE pearl_sidecar_gpu_accepted_shares counter",
        *(f'pearl_sidecar_gpu_accepted_shares{{gpu="{gpu.index}"}} {gpu.accepted_shares}' for gpu in gpus),
        "# HELP pearl_sidecar_gpu_invalid_shares Shares the pool rejected from this GPU since the miner started.",
        "# TYPE pearl_sidecar_gpu_invalid_shares counter",
        *(f'pearl_sidecar_gpu_invalid_shares{{gpu="{gpu.index}"}} {gpu.invalid_shares}' for gpu in gpus),
        "# HELP pearl_sidecar_hashrate_total_hs Node hashrate as the miner reports it.",
        "# TYPE pearl_sidecar_hashrate_total_hs gauge",
        f"pearl_sidecar_hashrate_total_hs {summary.hashrate_hs if summary else 0.0:.0f}",
        "# HELP pearl_sidecar_accepted_shares Shares the pool accepted from this node since the miner started.",
        "# TYPE pearl_sidecar_accepted_shares counter",
        f"pearl_sidecar_accepted_shares {summary.accepted_shares if summary else 0}",
        "# HELP pearl_sidecar_invalid_shares Shares the pool rejected from this node since the miner started.",
        "# TYPE pearl_sidecar_invalid_shares counter",
        f"pearl_sidecar_invalid_shares {summary.invalid_shares if summary else 0}",
        "# HELP pearl_sidecar_pool_connected 1 while the miner holds a stratum connection to a pool.",
        "# TYPE pearl_sidecar_pool_connected gauge",
        f"pearl_sidecar_pool_connected {1 if summary is not None and summary.pool_connected else 0}",
        "# HELP pearl_sidecar_gpus_reporting GPUs the miner reports as hashing right now.",
        "# TYPE pearl_sidecar_gpus_reporting gauge",
        f"pearl_sidecar_gpus_reporting {reporting_gpus}",
        "# HELP pearl_sidecar_gpus_expected GPUs the entrypoint counted when it launched the miner.",
        "# TYPE pearl_sidecar_gpus_expected gauge",
        f"pearl_sidecar_gpus_expected {EXPECTED_GPUS}",
    ]
    # Absent until the pool takes the first share, so "never accepted anything" cannot be read as a
    # fresh zero — a node whose work is being rejected wholesale has no last share to age.
    if summary is not None and summary.last_share_at is not None:
        age_seconds: float = max(0.0, time.time() - summary.last_share_at)
        lines += [
            "# HELP pearl_sidecar_last_share_age_seconds Seconds since the pool last accepted a share from this node.",
            "# TYPE pearl_sidecar_last_share_age_seconds gauge",
            f"pearl_sidecar_last_share_age_seconds {age_seconds:.1f}",
        ]
    body: str = "\n".join([*lines, ""])
    return MetricsSnapshot(body=body.encode("utf-8"), reporting_gpus=reporting_gpus)


def read_log_tail(max_bytes: int) -> bytes:
    """The tail of the miner log, or a readable stand-in before the miner has written one."""
    path: str = os.path.join(LOG_DIR, MINER_LOG_NAME)
    if not os.path.exists(path):
        return b"no miner log yet\n"
    return read_tail(path, max_bytes).encode("utf-8")


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
    _log(f"serving :{PORT}/metrics from {MINER_API_URL} for {EXPECTED_GPUS} GPU(s)")
    http.server.ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()


if __name__ == "__main__":
    main()
