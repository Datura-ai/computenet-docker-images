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

The cure is equally narrow — kill the engine, nothing else. The worker respawns it
from the warm cache within ~40 s and tokens return 2-3 minutes after the kill, while
the container and its filler_run row are untouched, so there is no cold start
(30-60 min, ~35 GB re-downloaded) and no launch backoff. Two details are not
optional, both learned from production: a wedged process ignores SIGTERM, and the
`VLLM::EngineCore` child survived the parent's death in 12 of 12 cases while holding
~70 GB of VRAM, which blocks the respawn until it is killed too.

Deliberately NOT handled here: an engine that never came up at all (no socket). Cold
start legitimately takes 30-60 minutes, and restarting a worker mid-download only
sends it back to the beginning.
"""

import json
import os
import re
import signal
import sys
import time

from dataclasses import dataclass

# The sidecar owns the unix-socket client and the socket-discovery order; importing it
# keeps one implementation. Its module body only reads env — nothing starts on import.
from metrics_sidecar import discover_sockets, fetch_vllm_metrics

POLL_INTERVAL_S = float(os.environ.get("DOLPHIN_WATCHDOG_POLL_SECONDS", "60"))
# How long the token counter may stand still, with requests in flight, before the engine
# is declared wedged. Real wedges never recover, so this is a false-positive margin only.
STALL_LIMIT_S = float(os.environ.get("DOLPHIN_WATCHDOG_STALL_SECONDS", "300"))
# Quiet period after a kill: the engine reloads weights for ~90 s and must not be judged
# (or killed again) while it does.
RESTART_GRACE_S = float(os.environ.get("DOLPHIN_WATCHDOG_GRACE_SECONDS", "300"))
# How long the EngineCore child gets to die with its parent before it is killed directly.
CHILD_GRACE_S = float(os.environ.get("DOLPHIN_WATCHDOG_CHILD_SECONDS", "20"))
STATE_PATH = os.environ.get(
    "DOLPHIN_WATCHDOG_STATE",
    os.path.join(os.environ.get("DOLPHIN_HOME", "/opt/dolphinpod"), "watchdog_state.json"),
)
STATE_VERSION = 1

SERVE_MARKER = "vllm serve"
ENGINE_MARKER = "VLLM::EngineCore"

# Prometheus lines carry labels (engine, model_name); the value is the last field.
_GENERATED = re.compile(rb"^vllm:generation_tokens_total(?:\{[^}]*\})?[ \t]+([0-9.eE+-]+)", re.M)
_RUNNING = re.compile(rb"^vllm:num_requests_running(?:\{[^}]*\})?[ \t]+([0-9.eE+-]+)", re.M)


@dataclass
class Sample:
    """One reading of the engine: tokens produced so far and requests in flight."""

    generated: float
    running: float


def _log(msg: str) -> None:
    print(f"[watchdog] {msg}", file=sys.stderr, flush=True)


def _first_value(pattern: re.Pattern[bytes], body: bytes) -> float | None:
    match = pattern.search(body)
    if match is None:
        return None
    try:
        return float(match.group(1))
    except ValueError:
        return None


def read_engine() -> Sample | None:
    # None means there is nothing to judge: no socket yet, engine not answering, or a
    # metrics schema we do not recognise. All three must leave the engine alone.
    sockets = discover_sockets()
    if not sockets:
        return None
    body = fetch_vllm_metrics(sockets)
    if body is None:
        return None
    generated = _first_value(_GENERATED, body)
    running = _first_value(_RUNNING, body)
    if generated is None or running is None:
        return None
    return Sample(generated=generated, running=running)


def find_pids() -> tuple[list[int], list[int]]:
    # Scanning /proc rather than pkill, which matches its own shell cmdline. The watchdog
    # runs inside the filler container, so /proc can only ever show that container's
    # processes — no risk of reaching another filler on the same machine.
    serve: list[int] = []
    engine: list[int] = []
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
        if SERVE_MARKER in cmdline:
            serve.append(pid)
        elif ENGINE_MARKER in cmdline:
            engine.append(pid)
    return serve, engine


def _alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def _kill(pids: list[int]) -> list[int]:
    killed = []
    for pid in pids:
        try:
            os.kill(pid, signal.SIGKILL)
            killed.append(pid)
        except OSError as e:
            _log(f"could not kill pid {pid}: {e}")
    return killed


def restart_engine() -> bool:
    # SIGKILL only: a process stuck in a CUDA kernel ignores SIGTERM. Returns False when
    # there was no engine to kill, which the caller reports instead of counting a restart.
    serve, engine = find_pids()
    if not serve and not engine:
        _log("wedge detected but no `vllm serve` process found — nothing to restart")
        return False

    _log(f"restarting engine: SIGKILL serve={serve} (EngineCore={engine})")
    _kill(serve)
    time.sleep(CHILD_GRACE_S)

    # The child usually outlives its parent and keeps the whole model in VRAM; until it is
    # gone the respawned engine cannot allocate.
    orphans = [pid for pid in engine if _alive(pid)]
    if orphans:
        _log(f"EngineCore outlived its parent, killing directly: {orphans}")
        _kill(orphans)
        time.sleep(2)

    still_alive = [pid for pid in serve + engine if _alive(pid)]
    if still_alive:
        _log(f"WARNING: still alive after SIGKILL: {still_alive}")
    return True


def write_state(restarts: int, last_restart: float, stall_s: float, sample: Sample | None) -> None:
    # Written every tick, so its freshness doubles as the watchdog's own heartbeat: the
    # sidecar turns a stale file into dolphin_watchdog_up 0 instead of silence.
    state = {
        "version": STATE_VERSION,
        "updated": time.time(),
        "poll_interval_s": POLL_INTERVAL_S,
        "restarts_total": restarts,
        "last_restart_timestamp": last_restart,
        "stall_seconds": round(stall_s, 1),
        "requests_running": sample.running if sample else None,
        "generated_tokens": sample.generated if sample else None,
    }
    tmp_path = f"{STATE_PATH}.tmp"
    try:
        with open(tmp_path, "w") as fh:
            json.dump(state, fh)
        os.replace(tmp_path, STATE_PATH)  # atomic: the sidecar never reads a half file
    except OSError as e:
        _log(f"could not write state to {STATE_PATH}: {e}")


def load_state() -> tuple[int, float]:
    # The watchdog's own restart (a crash, its supervisor loop) must not erase the count:
    # a machine that keeps wedging would then read as a machine that never wedged. Scope is
    # the container's lifetime — a new container starts from an empty directory anyway.
    try:
        with open(STATE_PATH) as fh:
            state = json.load(fh)
        return int(state.get("restarts_total") or 0), float(state.get("last_restart_timestamp") or 0.0)
    except (OSError, ValueError, TypeError):
        return 0, 0.0


def main() -> None:
    restarts, last_restart = load_state()
    _log(
        f"watching engine: poll {POLL_INTERVAL_S:.0f}s, stall limit {STALL_LIMIT_S:.0f}s, "
        f"state {STATE_PATH}, {restarts} restart(s) so far this container"
    )
    last_generated: float | None = None
    last_change = time.monotonic()
    armed_at = time.monotonic()
    reported_stall = False

    while True:
        sample = read_engine()
        now = time.monotonic()

        if sample is None or sample.generated != last_generated:
            last_generated = sample.generated if sample else None
            last_change = now
            reported_stall = False

        stall_s = now - last_change
        # An idle queue is a demand problem, not a wedge — the engine is fine and waiting.
        wedged = sample is not None and sample.running > 0 and stall_s >= STALL_LIMIT_S

        if wedged and not reported_stall:
            reported_stall = True
            _log(
                f"no tokens for {stall_s:.0f}s while {sample.running:.0f} request(s) are "
                f"running (generated stuck at {sample.generated:.0f})"
            )

        if wedged and now >= armed_at:
            armed_at = time.monotonic() + RESTART_GRACE_S
            if restart_engine():
                restarts += 1
                last_restart = time.time()
                # Restart the stall clock only on a real kill; if there was nothing to kill
                # the counter keeps climbing, which is what makes the problem visible.
                last_generated = None
                last_change = time.monotonic()
                stall_s = 0.0
                reported_stall = False

        write_state(restarts, last_restart, stall_s, sample)
        time.sleep(POLL_INTERVAL_S)


if __name__ == "__main__":
    main()
