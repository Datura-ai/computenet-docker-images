"""Event-loop lag probe contract tests (DAH-2531). Stdlib only, no pytest dependency:

    python3 tests/test_loop_probe.py

The central case blocks a REAL asyncio loop with a real `time.sleep`, which is what a multi-second
`json.loads` of a hidden-state block does to the miner. A probe that cannot see that is worthless,
so it is measured rather than asserted about.
"""

import asyncio
import os
import pathlib
import sys
import tempfile
import time

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent))

import loop_probe                                                          # noqa: E402
from metrics_sidecar import SAMPLE_LINE, merge_engine_bodies, metric_family  # noqa: E402

BLOCK_SECONDS: float = 1.5
INFLIGHT_DURING_BLOCK: int = 7

failures: list[str] = []


def check(condition: bool, description: str) -> None:
    if condition:
        print(f"  ok: {description}")
    else:
        failures.append(description)
        print(f"  FAIL: {description}")


def sample_value(body: str, name: str) -> float | None:
    for line in body.splitlines():
        match = SAMPLE_LINE.match(line) if line and not line.startswith("#") else None
        if match and match.group("name") == name:
            return float(match.group("rest").strip())
    return None


def help_lines_per_family(body: str) -> dict[str, int]:
    counts: dict[str, int] = {}
    for line in body.splitlines():
        parts: list[str] = line.split(maxsplit=3)
        if line.startswith("#") and len(parts) >= 3 and parts[1] == "HELP":
            family: str = metric_family(parts[2])
            counts[family] = counts.get(family, 0) + 1
    return counts


async def run_probe_across_a_blocked_loop(output_path: str) -> loop_probe.LoopLagProbe:
    """Take clean samples, freeze the loop the way a big json.loads does, then let it recover."""
    inflight: list[int] = [0]
    probe = loop_probe.LoopLagProbe(
        "lium-test-g0", output_path, lambda: inflight[0], write_interval_seconds=0.5
    )
    task: asyncio.Task = asyncio.get_running_loop().create_task(probe.run_forever())
    await asyncio.sleep(0.7)                        # clean samples on an idle loop
    inflight[0] = INFLIGHT_DURING_BLOCK             # a burst arrives and registers its jobs
    await asyncio.sleep(0.3)
    time.sleep(BLOCK_SECONDS)                       # the loop cannot run: exactly the failure mode
    # The jobs deregister only now, because the miner drops them from _JOBS on the loop — which is
    # why the count read on WAKING is already back to zero and cannot describe the stall.
    inflight[0] = 0
    await asyncio.sleep(0.9)
    task.cancel()
    return probe


def main() -> int:
    with tempfile.TemporaryDirectory() as workdir:
        output_path: str = os.path.join(workdir, "loop-test.prom")

        print("== a blocked loop is measured, not missed ==")
        probe: loop_probe.LoopLagProbe = asyncio.run(run_probe_across_a_blocked_loop(output_path))
        check(
            probe.worst_lag_seconds >= BLOCK_SECONDS - 0.35,
            f"a {BLOCK_SECONDS}s block shows up as a {probe.worst_lag_seconds:.2f}s lag",
        )
        check(probe.stall_counts[1.0] >= 1, "the >=1s stall bucket counted it")
        check(probe.stall_counts[5.0] == 0, "the >=5s bucket did not fire on a 1.5s block")
        check(
            probe.samples_taken >= 4,
            f"clean samples were taken either side of the block (got {probe.samples_taken})",
        )

        print("== the in-flight count at the worst moment is captured ==")
        # This pair is the whole reason the probe exists: a long lag WITH requests in flight is our
        # GIL, the same lag with an idle queue is not, and the log's Close(1011) cannot tell them apart.
        check(
            probe.worst_lag_inflight == INFLIGHT_DURING_BLOCK,
            f"the peak lag carries its in-flight count (got {probe.worst_lag_inflight})",
        )
        check(probe.worst_inflight == INFLIGHT_DURING_BLOCK, "the in-flight high-water mark is kept")
        check(probe.inflight_now == 0, "the current in-flight gauge follows the queue back down")

        print("== the recent-window gauge resets, the all-time one does not ==")
        probe.recent_worst_lag_seconds = 0.0
        probe.record_sample(0.01, 0, 0)
        check(probe.worst_lag_seconds >= BLOCK_SECONDS - 0.35, "the all-time worst survives a write")
        check(probe.recent_worst_lag_seconds < 0.1, "the recent worst starts over after a write")

        print("== the file on disk is a complete, valid exposition ==")
        check(os.path.exists(output_path), "the probe wrote its file")
        body: str = pathlib.Path(output_path).read_text(encoding="utf-8")
        check(
            sample_value(body, "engy_miner_loop_lag_seconds_max") is not None,
            "the worst-lag gauge is on disk",
        )
        check(
            (sample_value(body, "engy_miner_loop_lag_peak_inflight") or 0) == INFLIGHT_DURING_BLOCK,
            "the peak in-flight gauge is on disk",
        )
        duplicated: list[str] = [name for name, count in help_lines_per_family(body).items() if count > 1]
        check(not duplicated, f"one HELP line per family (duplicated: {duplicated})")
        check(not list(pathlib.Path(workdir).glob("*.tmp")), "no half-written temp file is left behind")

        print("== a stalled loop is distinguishable from a quiet one at scrape time ==")
        written_at: float | None = sample_value(body, "engy_miner_probe_written_timestamp_seconds")
        check(
            written_at is not None and abs(written_at - time.time()) < 120,
            "the file carries when it was written, so a frozen miner is visible",
        )

        print("== the sidecar can merge probe files next to engine bodies ==")
        engine_body: str = (
            "# HELP sglang:num_running_reqs Running requests.\n"
            "# TYPE sglang:num_running_reqs gauge\n"
            'sglang:num_running_reqs{engy_engine="8000"} 3\n'
        )
        merged: str = merge_engine_bodies([engine_body, body, body.replace("g0", "g1")])
        duplicated = [name for name, count in help_lines_per_family(merged).items() if count > 1]
        check(not duplicated, f"merging two miners keeps one HELP per family (duplicated: {duplicated})")
        check(
            len([l for l in merged.splitlines() if l.startswith("engy_miner_loop_lag_seconds_max")]) == 2,
            "both miners' series survive the merge",
        )
        check("sglang:num_running_reqs" in merged, "engine series survive alongside the probe series")

        print("== labels cannot break the exposition ==")
        hostile = loop_probe.LoopLagProbe('we"ird\\name', output_path, lambda: 0)
        hostile.record_sample(0.5, 1, 1)
        rendered: str = hostile.render_prometheus_text()
        check(r"we\"ird\\name" in rendered, "quotes and backslashes in the worker name are escaped")
        check(
            all(
                SAMPLE_LINE.match(line)
                for line in rendered.splitlines()
                if line and not line.startswith("#")
            ),
            "every rendered sample line still parses",
        )

        print("== a restarted miner overwrites its own file, it does not duplicate it ==")
        # Upstream mints the worker id per PROCESS, so keying the file on it left the dead miner's
        # file behind. Both files carry the same engy_worker label, Prometheus keeps one sample per
        # label set, and which one it keeps is undefined — the flapping-miner case this exists for.
        restart_dir: str = os.path.join(workdir, "restarts")
        os.makedirs(restart_dir)
        os.environ["ENGY_PROBE_DIR"] = restart_dir
        first: loop_probe.LoopLagProbe | None = asyncio.run(start_and_report())
        second: loop_probe.LoopLagProbe | None = asyncio.run(start_and_report())
        check(first is not None and second is not None and first.output_path == second.output_path,
              "two runs of the same worker write the SAME file")
        check(len(list(pathlib.Path(restart_dir).glob("*.prom"))) <= 1,
              "a restart leaves no second file behind")
        hostile_name: str = loop_probe.probe_file_name("lium-x/../../etc")
        check(os.sep not in hostile_name and "/" not in hostile_name,
              f"a hostile worker name cannot escape the probe directory (got {hostile_name})")
        os.environ["ENGY_PROBE_DIR"] = os.path.join(workdir, "probe")

        print("== the probe is off unless it is asked for ==")
        os.environ.pop("ENGY_PROBE_DIR", None)
        check(asyncio.run(start_and_report()) is None, "no ENGY_PROBE_DIR -> no probe")
        os.environ["ENGY_PROBE_DIR"] = os.path.join(workdir, "probe")
        started: loop_probe.LoopLagProbe | None = asyncio.run(start_and_report())
        check(started is not None, "ENGY_PROBE_DIR -> a probe attached to the running loop")
        check(
            started is not None and started.output_path.endswith("loop-lium-test-g0.prom"),
            "the file is keyed on the worker NAME, which survives a restart",
        )
        check(started is not None and started.task is not None,
              "the probe task is held, not left to its own timer handle")

        print("== an unwritable directory does not take the miner down ==")
        unwritable = loop_probe.LoopLagProbe("w", "/proc/nonexistent/loop.prom", lambda: 0)
        unwritable.write()
        unwritable.write()
        check(True, "two failed writes raised nothing")

    print()
    if failures:
        print(f"{len(failures)} failure(s)")
        return 1
    print("all loop-probe contract tests passed")
    return 0


async def start_and_report() -> loop_probe.LoopLagProbe | None:
    return loop_probe.start("lium-test-g0", lambda: 0)


if __name__ == "__main__":
    raise SystemExit(main())
