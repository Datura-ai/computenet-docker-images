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

The WildRig benchmark build (PEARL_MINER=wildrig, DAH-6084) reads WildRig's own stats JSON instead (GET
http://127.0.0.1:4068/), which reports shares for the node only, so its per-GPU share series are absent. Both builds
export per-GPU power draw and power limit from nvidia-smi: the benchmark compares hashrate per watt under our cap.

Without METRICS_TOKEN it refuses to start: an unauthenticated port on a miner's host would publish
our fleet's hashrate to whoever scans it. PeakMiner's own API has no auth at all, which is why it
stays on the container's loopback and this port is the only way out.
"""

import hmac
import http.server
import json
import os
import sys
import subprocess
import time
import urllib.error
import urllib.parse
import urllib.request

from dataclasses import dataclass
from typing import TypedDict

PORT: int = int(os.environ.get("METRICS_PORT", "9101"))
TOKEN: str = os.environ.get("METRICS_TOKEN", "")
LOG_DIR: str = os.environ.get("PEARL_LOG_DIR", "/var/log/pearl")
MINER: str = os.environ.get("PEARL_MINER", "peakminer")
MINER_LOG_NAME: str = f"{MINER}.log"
# The miner's stats API, on the container's own loopback: PeakMiner's /summary, or WildRig's root document.
MINER_API_URL: str = os.environ.get(
    "PEAK_API_URL", "http://127.0.0.1:4068/" if MINER == "wildrig" else "http://127.0.0.1:4068/summary"
)
NVIDIA_SMI_TIMEOUT_SECONDS: float = 5.0
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
    # None when the miner counts shares for the node only (WildRig)
    accepted_shares: int | None
    invalid_shares: int | None


@dataclass(frozen=True)
class GpuPower:
    """One card's draw and enforced limit as nvidia-smi reads them, in watts."""

    index: int
    draw_watts: float | None
    limit_watts: float | None


class WildrigHashrate(TypedDict, total=False):
    total: list[float]  # [current, ...] for the node, in H/s
    threads: list[list[float]]  # one [current, ...] row per GPU


class WildrigResults(TypedDict, total=False):
    shares_good: int
    shares_total: int


class WildrigConnection(TypedDict, total=False):
    uptime: int


class WildrigStats(TypedDict, total=False):
    """The fields of WildRig's stats document this parser reads."""

    hashrate: WildrigHashrate
    results: WildrigResults
    connection: WildrigConnection


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
        return wildrig_summary(payload) if MINER == "wildrig" else peakminer_summary(payload)
    except (OSError, urllib.error.HTTPError, ValueError, KeyError, TypeError, IndexError) as error:
        _log(f"cannot read {MINER_API_URL}: {error!r}")
        return None


def wildrig_summary(payload: WildrigStats) -> MinerSummary:
    """WildRig's stats document: hashrate.threads holds one [current, ...] row per GPU in H/s, results the node's
    shares. The same fields HiveOS reads in the h-stats.sh WildRig ships."""
    # shortcut: pool_connected reads connection.uptime, a field not confirmed against a live WildRig; check the first
    # benchmark scrape and fix the field if it always reads 0.
    hashrate: WildrigHashrate = payload.get("hashrate") or {}
    results: WildrigResults = payload.get("results") or {}
    accepted: int = int(results.get("shares_good") or 0)
    return MinerSummary(
        pool_connected=bool((payload.get("connection") or {}).get("uptime")),
        hashrate_hs=float((hashrate.get("total") or [0.0])[0] or 0.0),
        accepted_shares=accepted,
        invalid_shares=max(0, int(results.get("shares_total") or 0) - accepted),
        last_share_at=None,
        gpus=[
            GpuSample(index=index, hashrate_hs=float(row[0] or 0.0), accepted_shares=None, invalid_shares=None)
            for index, row in enumerate(hashrate.get("threads") or [])
        ],
    )


def peakminer_summary(payload: dict) -> MinerSummary:
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


def read_gpu_power() -> list[GpuPower]:
    """Per-GPU power draw and limit, or nothing when nvidia-smi is missing, hangs or reports N/A."""
    try:
        output: str = subprocess.run(
            ["nvidia-smi", "--query-gpu=index,power.draw,power.limit", "--format=csv,noheader,nounits"],
            capture_output=True,
            text=True,
            timeout=NVIDIA_SMI_TIMEOUT_SECONDS,
            check=True,
        ).stdout
    except (OSError, subprocess.SubprocessError) as error:
        _log(f"cannot read GPU power: {error!r}")
        return []
    cards: list[GpuPower] = []
    for line in output.splitlines():
        parts: list[str] = [part.strip() for part in line.split(",")]
        if len(parts) != 3:
            continue
        cards.append(GpuPower(index=int(parts[0]), draw_watts=_watts(parts[1]), limit_watts=_watts(parts[2])))
    return cards


def _watts(text: str) -> float | None:
    """nvidia-smi's reading in watts; None for "[N/A]", never read as 0 W."""
    try:
        return float(text)
    except ValueError:
        return None


def gpu_power_series_lines(power: list[GpuPower]) -> list[str]:
    """Per-GPU draw and limit for the cards that report them, and the node totals only when every card reports both.

    A card reading [N/A] still hashes: a total without its watts would make hash per watt read high, so the totals
    are left out instead.
    """
    draws: list[GpuPower] = [card for card in power if card.draw_watts is not None]
    limits: list[GpuPower] = [card for card in power if card.limit_watts is not None]
    complete: bool = bool(power) and len(draws) == len(limits) == len(power)
    lines: list[str] = []
    if draws:
        lines += [
            "# HELP pearl_sidecar_gpu_power_draw_watts Power this GPU draws now, as nvidia-smi reads it.",
            "# TYPE pearl_sidecar_gpu_power_draw_watts gauge",
            *(f'pearl_sidecar_gpu_power_draw_watts{{gpu="{card.index}"}} {card.draw_watts:.1f}' for card in draws),
        ]
    if limits:
        lines += [
            "# HELP pearl_sidecar_gpu_power_limit_watts Enforced power limit of this GPU (our cap while it runs).",
            "# TYPE pearl_sidecar_gpu_power_limit_watts gauge",
            *(f'pearl_sidecar_gpu_power_limit_watts{{gpu="{card.index}"}} {card.limit_watts:.1f}' for card in limits),
        ]
    if complete:
        lines += [
            "# HELP pearl_sidecar_power_draw_watts_total Power all GPUs of this node draw now.",
            "# TYPE pearl_sidecar_power_draw_watts_total gauge",
            f"pearl_sidecar_power_draw_watts_total {sum(card.draw_watts or 0.0 for card in power):.1f}",
            "# HELP pearl_sidecar_power_limit_watts_total Sum of the enforced power limits of this node's GPUs.",
            "# TYPE pearl_sidecar_power_limit_watts_total gauge",
            f"pearl_sidecar_power_limit_watts_total {sum(card.limit_watts or 0.0 for card in power):.1f}",
        ]
    return lines


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
        *(
            f'pearl_sidecar_gpu_accepted_shares{{gpu="{gpu.index}"}} {gpu.accepted_shares}'
            for gpu in gpus
            if gpu.accepted_shares is not None
        ),
        "# HELP pearl_sidecar_gpu_invalid_shares Shares the pool rejected from this GPU since the miner started.",
        "# TYPE pearl_sidecar_gpu_invalid_shares counter",
        *(
            f'pearl_sidecar_gpu_invalid_shares{{gpu="{gpu.index}"}} {gpu.invalid_shares}'
            for gpu in gpus
            if gpu.invalid_shares is not None
        ),
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
    lines += gpu_power_series_lines(read_gpu_power())
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
