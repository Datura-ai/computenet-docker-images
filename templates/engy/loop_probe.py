"""Measure how long the miner's asyncio event loop goes unserviced, and publish it as metrics.

Why this exists. The miner answers the gateway's keepalive pings from its event loop, and it parses
every serve reply in the SAME process — a TOPLOC proof ships the model's hidden states, so one reply
is tens of MB of JSON and `json.loads` holds the GIL for over a second. When enough replies land at
once the loop stops being serviced, the pong we owe the gateway is never read, and the `websockets`
client tears its own leg down with Close(1011, 'keepalive ping timeout'). That is what prod showed on
2026-07-29.

The problem is that the same 1011 appears when the GATEWAY goes quiet, so the log alone cannot say
which side stalled. This probe settles it. It schedules itself every `sample_interval` on the loop
under test and records the overshoot: the loop's own delay IS the measurement. It also records how
many requests were in flight at the worst moment, which is the discriminator — a big lag with
requests in flight is our GIL, a leg dropping while the lag stayed flat is not.

Output is a Prometheus text fragment written atomically to a file. The metrics sidecar picks the file
up and merges it into /metrics, so nothing here needs a port or a scrape endpoint of its own.
"""

from __future__ import annotations

import asyncio
import os
import sys
import time
from typing import Callable

# Buckets, not a histogram: what we need to answer is "did the loop ever go past the 60s ping timeout,
# and how close does it normally get", and five counters read that off directly in a query.
STALL_THRESHOLDS_SECONDS: tuple[float, ...] = (1.0, 5.0, 15.0, 30.0, 60.0)
SAMPLE_INTERVAL_SECONDS: float = 0.25
WRITE_INTERVAL_SECONDS: float = 10.0


def escape_label_value(value: str) -> str:
    return value.replace("\\", r"\\").replace('"', r"\"").replace("\n", r"\n")


class LoopLagProbe:
    """Samples one asyncio loop's responsiveness and writes the result as Prometheus text."""

    def __init__(
        self,
        worker_name: str,
        output_path: str,
        count_inflight_requests: Callable[[], int],
        sample_interval_seconds: float = SAMPLE_INTERVAL_SECONDS,
        write_interval_seconds: float = WRITE_INTERVAL_SECONDS,
    ) -> None:
        self.worker_name: str = worker_name
        self.output_path: str = output_path
        self.count_inflight_requests: Callable[[], int] = count_inflight_requests
        self.sample_interval_seconds: float = sample_interval_seconds
        self.write_interval_seconds: float = write_interval_seconds
        self.samples_taken: int = 0
        self.worst_lag_seconds: float = 0.0
        self.worst_lag_inflight: int = 0
        self.recent_worst_lag_seconds: float = 0.0
        self.inflight_now: int = 0
        self.worst_inflight: int = 0
        self.stall_counts: dict[float, int] = {threshold: 0 for threshold in STALL_THRESHOLDS_SECONDS}
        self.last_write_error: str = ""

    def record_sample(self, lag_seconds: float, inflight_before_wait: int, inflight_after_wait: int) -> None:
        """Both in-flight readings, because the stall is measured only after it has ENDED.

        Reading the queue once, on waking, undercounts the exact case we care about: the requests
        whose parsing held the GIL have finished by then, so a 78s stall caused by 30 concurrent
        replies would report 0 in flight and read as an idle loop. The count that was in flight
        going INTO the wait is the one that describes the stall.
        """
        inflight_during_wait: int = max(inflight_before_wait, inflight_after_wait)
        self.samples_taken += 1
        self.inflight_now = inflight_after_wait
        self.worst_inflight = max(self.worst_inflight, inflight_during_wait)
        self.recent_worst_lag_seconds = max(self.recent_worst_lag_seconds, lag_seconds)
        if lag_seconds > self.worst_lag_seconds:
            # This pair is the whole point. A long lag WITH requests in flight is our GIL; the same
            # lag with an empty queue is something else starving the box.
            self.worst_lag_seconds = lag_seconds
            self.worst_lag_inflight = inflight_during_wait
        for threshold in STALL_THRESHOLDS_SECONDS:
            if lag_seconds >= threshold:
                self.stall_counts[threshold] += 1

    def render_prometheus_text(self) -> str:
        labels: str = f'{{engy_worker="{escape_label_value(self.worker_name)}"}}'
        stall_lines: list[str] = [
            f'engy_miner_loop_stall_samples_total{{engy_worker="{escape_label_value(self.worker_name)}",'
            f'ge="{threshold:g}"}} {self.stall_counts[threshold]}'
            for threshold in STALL_THRESHOLDS_SECONDS
        ]
        return "\n".join(
            [
                "# HELP engy_miner_loop_lag_seconds_max Worst event-loop delay since the miner started.",
                "# TYPE engy_miner_loop_lag_seconds_max gauge",
                f"engy_miner_loop_lag_seconds_max{labels} {self.worst_lag_seconds:.3f}",
                "# HELP engy_miner_loop_lag_seconds_recent_max Worst event-loop delay in the last write window.",
                "# TYPE engy_miner_loop_lag_seconds_recent_max gauge",
                f"engy_miner_loop_lag_seconds_recent_max{labels} {self.recent_worst_lag_seconds:.3f}",
                "# HELP engy_miner_loop_lag_peak_inflight Requests in flight when the worst delay was measured.",
                "# TYPE engy_miner_loop_lag_peak_inflight gauge",
                f"engy_miner_loop_lag_peak_inflight{labels} {self.worst_lag_inflight}",
                "# HELP engy_miner_inflight_requests Requests the miner is serving right now.",
                "# TYPE engy_miner_inflight_requests gauge",
                f"engy_miner_inflight_requests{labels} {self.inflight_now}",
                "# HELP engy_miner_inflight_requests_max Most requests the miner has served at once.",
                "# TYPE engy_miner_inflight_requests_max gauge",
                f"engy_miner_inflight_requests_max{labels} {self.worst_inflight}",
                "# HELP engy_miner_loop_stall_samples_total Samples whose event-loop delay reached `ge` seconds.",
                "# TYPE engy_miner_loop_stall_samples_total counter",
                *stall_lines,
                "# HELP engy_miner_probe_samples_total Event-loop samples taken.",
                "# TYPE engy_miner_probe_samples_total counter",
                f"engy_miner_probe_samples_total{labels} {self.samples_taken}",
                "# HELP engy_miner_probe_written_timestamp_seconds When this file was last written.",
                "# TYPE engy_miner_probe_written_timestamp_seconds gauge",
                f"engy_miner_probe_written_timestamp_seconds{labels} {time.time():.0f}",
                "",
            ]
        )

    def write(self) -> None:
        """Publish atomically. A scraper must never read a half-written exposition."""
        temporary_path: str = f"{self.output_path}.tmp"
        try:
            os.makedirs(os.path.dirname(self.output_path) or ".", exist_ok=True)
            with open(temporary_path, "w", encoding="utf-8") as handle:
                handle.write(self.render_prometheus_text())
            os.replace(temporary_path, self.output_path)
        except OSError as error:
            # Never take the miner down over a metrics file, and never log the same failure every
            # 10 seconds into the log we serve over /logs.
            if repr(error) != self.last_write_error:
                self.last_write_error = repr(error)
                print(f"[engy-miner] loop probe cannot write {self.output_path}: {error!r}", flush=True)

    async def run_forever(self) -> None:
        next_write: float = time.monotonic() + self.write_interval_seconds
        while True:
            inflight_before_wait: int = self.count_inflight_requests()
            expected_wakeup: float = time.monotonic() + self.sample_interval_seconds
            await asyncio.sleep(self.sample_interval_seconds)
            now: float = time.monotonic()
            self.record_sample(
                max(0.0, now - expected_wakeup), inflight_before_wait, self.count_inflight_requests()
            )
            if now >= next_write:
                self.write()
                self.recent_worst_lag_seconds = 0.0
                next_write = now + self.write_interval_seconds


def start(worker_name: str, worker_id: str, count_inflight_requests: Callable[[], int]) -> LoopLagProbe | None:
    """Attach a probe to the running loop. Returns None when the probe is switched off."""
    output_dir: str = os.environ.get("ENGY_PROBE_DIR", "")
    if not output_dir:
        return None
    # Keyed on the worker id, which is stable across restarts and unique per miner in the container,
    # so a restarted miner overwrites its own file instead of leaving a frozen one behind forever.
    probe = LoopLagProbe(worker_name, os.path.join(output_dir, f"loop-{worker_id}.prom"), count_inflight_requests)
    try:
        asyncio.get_running_loop().create_task(probe.run_forever())
    except RuntimeError:
        print("[engy-miner] loop probe needs a running loop; not started", file=sys.stderr, flush=True)
        return None
    print(f"[engy-miner] loop probe writing {probe.output_path}", flush=True)
    return probe
