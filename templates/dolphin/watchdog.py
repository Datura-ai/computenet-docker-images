"""Restart the vLLM engine when it wedges, so a filler stops earning for minutes
instead of hours.

The failure this exists for: under continuous load the engine gets stuck inside a
CUDA kernel that never completes. Nothing that normally reads as health notices.
The container keeps running with zero restarts, the worker stays connected, vLLM's
own API answers /health in milliseconds, and the GPU reports 100% utilization while
drawing a third of its normal power — full occupancy with no memory traffic is a
spinning kernel, not inference. Measured 2026-07-23: twelve engines stuck between
1.6 and 23.5 hours, all of them invisible to every existing check.

The one honest signal is vLLM's own token counter: it stops moving while requests
are still in flight. That is what this watchdog polls, over the same unix socket the
metrics sidecar already proxies.

The platform can already cure a bad container by recreating it, and that is the wrong
tool here: recreation costs a cold start (30-60 min, ~35 GB re-downloaded) plus launch
backoff, for a fault a SIGKILL fixes in 2-3 minutes. So the cure is as narrow as it
gets — kill the engine, nothing else. The worker respawns it from the warm cache within
~40 s, and the container and its filler_run row are never touched. Two details are not
optional, both learned from production: a wedged process ignores SIGTERM, and the
`VLLM::EngineCore` child survived the parent's death in 12 of 12 cases while holding
~70 GB of VRAM, which blocks the respawn until it is killed too.

Deliberately NOT handled here:
- An engine that never came up at all (no socket). A cold start legitimately produces
  nothing for 30-60 minutes, and killing a worker mid-download restarts the download.
- An idle queue. No demand is not a fault.
- More than one engine in the container. The counters read belong to whichever engine
  answered first, so there is no way to tell which one wedged; kill_engine() refuses
  rather than take the healthy ones down with the wedged one.
"""

import json
import os
import re
import signal
import sys
import time

from dataclasses import asdict, dataclass

# The sidecar owns the unix-socket client, the socket-discovery order, the state-file path
# and the state schema; importing it keeps one implementation of each. Its module body only
# reads env — nothing starts on import.
from metrics_sidecar import (
    TOTAL_BUDGET_S,
    WATCHDOG_STATE_PATH,
    WatchdogState,
    discover_sockets,
    fetch_vllm_metrics,
)

POLL_INTERVAL_S = float(os.environ.get("DOLPHIN_WATCHDOG_POLL_SECONDS", "60"))
# How long the token counter may stand still, with requests in flight, before the engine
# is declared wedged. Real wedges never recover, so this is a false-positive margin only.
STALL_LIMIT_S = float(os.environ.get("DOLPHIN_WATCHDOG_STALL_SECONDS", "300"))
# Quiet period after a kill, during which the reloading engine is neither judged nor killed.
RESTART_GRACE_S = float(os.environ.get("DOLPHIN_WATCHDOG_GRACE_SECONDS", "300"))
ENGINE_CORE_GRACE_S = float(os.environ.get("DOLPHIN_WATCHDOG_ENGINE_CORE_SECONDS", "20"))
ORPHAN_SETTLE_S = 2.0
# Longest a healthy watchdog may go between state writes: the tick that kills an engine
# blocks for the fetch budget plus both grace periods. The sidecar turns a wider gap than
# this into dolphin_watchdog_up 0, so it must not be read off the poll interval alone.
MAX_WRITE_GAP_S = POLL_INTERVAL_S + TOTAL_BUDGET_S + ENGINE_CORE_GRACE_S + ORPHAN_SETTLE_S

SERVE_CMDLINE_MARKER = "vllm serve"
ENGINE_CORE_CMDLINE_MARKER = "VLLM::EngineCore"

# The optional group skips the labels (engine, model_name) that vLLM puts on these lines.
_GENERATED_TOKENS_RE = re.compile(
    rb"^vllm:generation_tokens_total(?:\{[^}]*\})?[ \t]+([0-9.eE+-]+)", re.M
)
_REQUESTS_RUNNING_RE = re.compile(
    rb"^vllm:num_requests_running(?:\{[^}]*\})?[ \t]+([0-9.eE+-]+)", re.M
)


@dataclass(frozen=True)
class EngineCounters:
    """The two vLLM series this watchdog judges on."""

    generated_tokens: float
    requests_running: float


@dataclass(frozen=True)
class EnginePoll:
    """What one poll learned. `socket_found` separates the two ways counters can be
    missing: no socket at all is a cold start, a silent socket is an engine that went
    quiet — and only the first may reset the stall clock."""

    counters: EngineCounters | None
    socket_found: bool


@dataclass(frozen=True)
class EnginePids:
    """The engine's processes, as two markers found in /proc cmdlines."""

    serve: list[int]
    engine_core: list[int]


def _log(msg: str) -> None:
    print(f"[watchdog] {msg}", file=sys.stderr, flush=True)


def _first_metric_value(pattern: re.Pattern[bytes], body: bytes) -> float | None:
    match = pattern.search(body)
    if match is None:
        return None
    try:
        return float(match.group(1))
    except ValueError:
        return None


def poll_engine() -> EnginePoll:
    # Missing counters never fire a kill on their own; what they do to the stall clock
    # depends on whether a socket was there at all, so the two cases stay distinguishable.
    sockets = discover_sockets()
    if not sockets:
        return EnginePoll(counters=None, socket_found=False)
    body = fetch_vllm_metrics(sockets)
    if body is None:
        return EnginePoll(counters=None, socket_found=True)
    generated_tokens = _first_metric_value(_GENERATED_TOKENS_RE, body)
    requests_running = _first_metric_value(_REQUESTS_RUNNING_RE, body)
    if generated_tokens is None or requests_running is None:
        return EnginePoll(counters=None, socket_found=True)
    return EnginePoll(
        counters=EngineCounters(
            generated_tokens=generated_tokens, requests_running=requests_running
        ),
        socket_found=True,
    )


def find_engine_pids() -> EnginePids:
    # Scanning /proc rather than pkill, which matches its own shell cmdline. The watchdog
    # runs inside the filler container, so /proc can only ever show that container's
    # processes — no risk of reaching another filler on the same machine.
    serve: list[int] = []
    engine_core: list[int] = []
    own_pid = os.getpid()
    for entry in os.listdir("/proc"):
        if not entry.isdigit():
            continue
        pid = int(entry)
        if pid == own_pid:
            continue
        try:
            with open(f"/proc/{pid}/cmdline", "rb") as fh:
                cmdline = fh.read().replace(b"\0", b" ").decode(errors="replace")
        except OSError:
            continue  # process exited between listdir and open
        if SERVE_CMDLINE_MARKER in cmdline:
            serve.append(pid)
        elif ENGINE_CORE_CMDLINE_MARKER in cmdline:
            engine_core.append(pid)
    return EnginePids(serve=serve, engine_core=engine_core)


def _is_alive(pid: int) -> bool:
    # Reads /proc rather than signal 0, which a zombie still answers: a killed engine that
    # its parent has not reaped yet has already released its VRAM and counts as dead here.
    try:
        with open(f"/proc/{pid}/stat", "rb") as fh:
            process_state = fh.read().rpartition(b")")[2].split()[0]
    except (OSError, IndexError):
        return False
    return process_state != b"Z"


def _sigkill(pids: list[int]) -> None:
    for pid in pids:
        try:
            os.kill(pid, signal.SIGKILL)
        except OSError as e:
            _log(f"could not kill pid {pid}: {e}")


def kill_engine() -> bool:
    """SIGKILL the engine and report whether it is actually gone afterwards. Only SIGKILL:
    a process stuck in a CUDA kernel ignores SIGTERM. False means nothing was killed —
    nothing to kill, several engines share the container, or the signal was survived (a
    CUDA ioctl can leave a process unkillable). Counting those as restarts would let a
    permanently wedged engine report as one being cured every grace period."""
    pids = find_engine_pids()
    if not pids.serve and not pids.engine_core:
        _log("wedge detected but no `vllm serve` process found — nothing to kill")
        return False
    # The counters came from whichever engine answered first, so with several in one
    # container there is no way to tell which one wedged. Refusing is the safe half of that
    # trade, and it holds however the image is launched — an entrypoint that only starts the
    # watchdog for a single engine cannot protect an image someone runs by hand.
    if len(pids.serve) > 1:
        _log(f"wedge detected but {len(pids.serve)} engines share this container — refusing")
        return False

    _log(f"killing engine: serve={pids.serve} (EngineCore={pids.engine_core})")
    _sigkill(pids.serve)
    time.sleep(ENGINE_CORE_GRACE_S)

    # The child usually outlives its parent and keeps the whole model in VRAM; until it is
    # gone the respawned engine cannot allocate.
    orphans = [pid for pid in pids.engine_core if _is_alive(pid)]
    if orphans:
        _log(f"EngineCore outlived its parent, killing directly: {orphans}")
        _sigkill(orphans)
        time.sleep(ORPHAN_SETTLE_S)

    survivors = [pid for pid in pids.serve + pids.engine_core if _is_alive(pid)]
    if survivors:
        _log(f"WARNING: still alive after SIGKILL, not counting a restart: {survivors}")
        return False
    return True


def write_state(
    restarts_total: int, last_restart_timestamp: float, stall_seconds: float,
    counters: EngineCounters | None,
) -> None:
    # Written every tick, so its freshness doubles as the watchdog's own heartbeat: the
    # sidecar turns a stale file into dolphin_watchdog_up 0 instead of silence.
    state = WatchdogState(
        updated=time.time(),
        max_write_gap_s=MAX_WRITE_GAP_S,
        restarts_total=restarts_total,
        last_restart_timestamp=last_restart_timestamp,
        stall_seconds=round(stall_seconds, 1),
        requests_running=counters.requests_running if counters else None,
        generated_tokens=counters.generated_tokens if counters else None,
    )
    tmp_path = f"{WATCHDOG_STATE_PATH}.tmp"
    try:
        with open(tmp_path, "w") as fh:
            json.dump(asdict(state), fh)
        os.replace(tmp_path, WATCHDOG_STATE_PATH)  # atomic: the sidecar never reads a half file
    except OSError as e:
        _log(f"could not write state to {WATCHDOG_STATE_PATH}: {e}")


def load_previous_state() -> WatchdogState | None:
    # The watchdog's own restart (a crash, its supervisor loop) must not erase what it knew:
    # a machine that keeps wedging would then read as a machine that never wedged, and a
    # fresh watchdog would judge an engine still reloading from the last kill. Scope is the
    # container's lifetime — a new container starts from an empty directory anyway.
    return WatchdogState.read(WATCHDOG_STATE_PATH)


def main() -> None:
    previous_state = load_previous_state()
    restarts_total = previous_state.restarts_total if previous_state else 0
    last_restart_timestamp = previous_state.last_restart_timestamp if previous_state else 0.0
    _log(
        f"watching engine: poll {POLL_INTERVAL_S:.0f}s, stall limit {STALL_LIMIT_S:.0f}s, "
        f"state {WATCHDOG_STATE_PATH}, {restarts_total} restart(s) so far this container"
    )
    last_generated_tokens: float | None = None
    tokens_last_moved_at = time.monotonic()
    # The previous process's kill still protects the engine: without carrying the grace over,
    # a supervisor restart would hand an engine that is still reloading weights to a watchdog
    # with no memory of the kill, which would read the reload as a fresh wedge.
    next_kill_allowed_at = time.monotonic() + max(
        0.0, RESTART_GRACE_S - (time.time() - last_restart_timestamp)
    )
    was_wedged = False

    while True:
        poll = poll_engine()
        counters = poll.counters
        now = time.monotonic()

        # A socket that exists but says nothing keeps the clock running: the engine went
        # quiet, which is the wedge itself. Only a container with no socket at all is a
        # cold start, and a cold start legitimately produces nothing for 30-60 minutes.
        if counters is not None and counters.generated_tokens != last_generated_tokens:
            last_generated_tokens = counters.generated_tokens
            tokens_last_moved_at = now
        elif not poll.socket_found:
            last_generated_tokens = None
            tokens_last_moved_at = now

        stall_seconds = now - tokens_last_moved_at
        # An idle queue is a demand problem, not a wedge — the engine is fine and waiting.
        wedged = (
            counters is not None
            and counters.requests_running > 0
            and stall_seconds >= STALL_LIMIT_S
        )

        if wedged and not was_wedged:
            _log(
                f"no tokens for {stall_seconds:.0f}s while {counters.requests_running:.0f} "
                f"request(s) are running (generated stuck at {counters.generated_tokens:.0f})"
            )

        if wedged and now >= next_kill_allowed_at:
            next_kill_allowed_at = now + RESTART_GRACE_S
            if kill_engine():
                restarts_total += 1
                last_restart_timestamp = time.time()
                # Only a real kill restarts the stall clock. When the kill was refused or
                # failed, the counter keeps climbing — that is what makes it visible.
                last_generated_tokens = None
                tokens_last_moved_at = time.monotonic()
                stall_seconds = 0.0
                wedged = False

        was_wedged = wedged
        write_state(restarts_total, last_restart_timestamp, stall_seconds, counters)
        time.sleep(POLL_INTERVAL_S)


if __name__ == "__main__":
    main()
