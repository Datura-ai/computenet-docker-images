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

Split mode (DAH-2465): one container may run N worker instances, one per GPU bundle, so
N vLLM engines share this /proc. `DOLPHIN_WATCHDOG_GPU_SET` names the cards this watchdog
owns, and everything below is then scoped to that bundle alone — the counters it judges
come from its own engine's socket, and the kill reaches only its own processes. A sibling
bundle's engine is another instance's business; killing it would turn one wedge into N.
The mapping is measured, not assumed: the worker exports CUDA_VISIBLE_DEVICES per engine
and drives vLLM with `--uds /tmp/dp-<id>/v.sock`, so /proc gives cards -> pid -> socket.
When that mapping is ambiguous the watchdog kills NOTHING and says so, because a wrong
guess here costs a healthy bundle.
"""

import json
import os
import re
import signal
import sys
import time

from dataclasses import asdict, dataclass

# The sidecar owns the unix-socket client, the socket-discovery order and the state schema
# (WatchdogState); importing it keeps one implementation of each. Its module body only reads
# env — nothing starts on import.
from metrics_sidecar import WatchdogState, discover_sockets, fetch_vllm_metrics

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

SERVE_MARKER = "vllm serve"
ENGINE_MARKER = "VLLM::EngineCore"
# The socket the worker gives its engine, and the only handle that ties a process to the
# metrics this watchdog reads.
_UDS_ARG = re.compile(r"--uds[= ]+(\S+)")


def normalize_gpus(value: str) -> tuple[str, ...]:
    # "2,3", "3,2" and " 2, 3 " all name the same bundle; order and spacing are not meaningful.
    return tuple(sorted(part.strip() for part in value.split(",") if part.strip()))


# Empty = the single-engine container: every vLLM process in /proc belongs to the one engine,
# which is the pre-split behavior the whole current fleet runs.
GPU_SET = normalize_gpus(os.environ.get("DOLPHIN_WATCHDOG_GPU_SET", ""))
SCOPE = f"GPUs {','.join(GPU_SET)}" if GPU_SET else "every vLLM process in this container"

# Prometheus lines carry labels (engine, model_name); the value is the last field.
_GENERATED = re.compile(rb"^vllm:generation_tokens_total(?:\{[^}]*\})?[ \t]+([0-9.eE+-]+)", re.M)
_RUNNING = re.compile(rb"^vllm:num_requests_running(?:\{[^}]*\})?[ \t]+([0-9.eE+-]+)", re.M)


@dataclass
class Sample:
    """One reading of the engine: tokens produced so far and requests in flight."""

    generated: float
    running: float


@dataclass
class EngineProcesses:
    """One engine's processes and the socket that identifies it.

    In split mode this is exactly one bundle's engine; in a single-engine container it is
    everything vLLM in /proc, which amounts to the same thing.
    """

    serve: list[int]
    engine: list[int]
    socket: str | None


@dataclass
class VllmProcess:
    """A vLLM process as /proc describes it, with the two facts that identify its bundle."""

    pid: int
    cmdline: str
    gpus: tuple[str, ...] | None
    ppid: int


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


def own_sockets(engine: EngineProcesses | None) -> list[str]:
    # In split mode only THIS bundle's socket may be read: a sibling's counters would
    # attribute its wedge — or its health — to us, and the kill that follows lands on the
    # wrong engine. An unidentified engine yields no socket, which reads as "nothing to
    # judge" and is the safe answer.
    if not GPU_SET:
        return discover_sockets()
    if engine is None or engine.socket is None:
        return []
    return [engine.socket]


def read_engine(sockets: list[str]) -> Sample | None:
    # None means there is nothing to judge: no socket yet, engine not answering, or a
    # metrics schema we do not recognise. All three must leave the engine alone.
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


def _read_cmdline(pid: int) -> str | None:
    try:
        with open(f"/proc/{pid}/cmdline", "rb") as fh:
            return fh.read().replace(b"\0", b" ").decode(errors="replace")
    except OSError:
        return None  # process exited between listdir and open


def _read_gpus(pid: int) -> tuple[str, ...] | None:
    # The worker sets CUDA_VISIBLE_DEVICES per engine (measured on live engines: pid 720 ->
    # "0", pid 1468 -> "1" on a two-bundle container), so the environment is what tells one
    # bundle's processes from another's inside a shared container.
    try:
        with open(f"/proc/{pid}/environ", "rb") as fh:
            raw = fh.read()
    except OSError:
        return None
    for item in raw.split(b"\0"):
        if item.startswith(b"CUDA_VISIBLE_DEVICES="):
            return normalize_gpus(item.split(b"=", 1)[1].decode(errors="replace"))
    return None


def _read_ppid(pid: int) -> int:
    try:
        with open(f"/proc/{pid}/status") as fh:
            for line in fh:
                if line.startswith("PPid:"):
                    return int(line.split()[1])
    except (OSError, ValueError, IndexError):
        pass
    return 0


def socket_of(cmdline: str) -> str | None:
    # `vllm serve --uds /tmp/dp-<id>/v.sock` — the same socket the metrics sidecar scrapes,
    # so the command line is what maps a process to the engine whose counters we read.
    match = _UDS_ARG.search(cmdline)
    return match.group(1) if match else None


def scan_vllm_processes() -> list[VllmProcess]:
    # Scanning /proc rather than pkill, which matches its own shell cmdline. The watchdog
    # runs inside the filler container, so /proc can only ever show that container's
    # processes — no risk of reaching another filler on the same machine. environ and status
    # are read only for processes that already matched a marker, so this stays a handful of
    # extra file reads per poll.
    found: list[VllmProcess] = []
    own_pid = os.getpid()
    for entry in os.listdir("/proc"):
        if not entry.isdigit():
            continue
        pid = int(entry)
        if pid == own_pid:
            continue
        cmdline = _read_cmdline(pid)
        if cmdline is None:
            continue
        if SERVE_MARKER not in cmdline and ENGINE_MARKER not in cmdline:
            continue
        found.append(
            VllmProcess(pid=pid, cmdline=cmdline, gpus=_read_gpus(pid), ppid=_read_ppid(pid))
        )
    return found


def find_engine_processes() -> EngineProcesses | None:
    # None means "cannot tell which engine is mine" and the caller must then do nothing.
    # That is the whole safety property of split mode: guessing wrong does not lose one
    # bundle, it loses a healthy one as well.
    processes = scan_vllm_processes()
    serves = [p for p in processes if SERVE_MARKER in p.cmdline]
    cores = [p for p in processes if SERVE_MARKER not in p.cmdline]

    if not GPU_SET:
        return EngineProcesses(
            serve=[p.pid for p in serves], engine=[p.pid for p in cores], socket=None
        )

    mine = [p for p in serves if p.gpus == GPU_SET]
    sockets = {path for path in (socket_of(p.cmdline) for p in mine) if path}
    if len(sockets) > 1:
        # Two engines claiming the same cards means the environment does not separate the
        # bundles the way it was measured to (a worker re-indexing CUDA_VISIBLE_DEVICES would
        # do it). Refusing is the only safe answer, and engine_found 0 makes it visible.
        _log(
            f"WARNING: {len(sockets)} engines claim GPUs {','.join(GPU_SET)} "
            f"({sorted(sockets)}) — refusing to act on an ambiguous match"
        )
        return None

    serve_pids = [p.pid for p in mine]
    # EngineCore inherits its parent's CUDA_VISIBLE_DEVICES, but the parent link is the
    # stronger claim; either one is enough, and neither can point at a sibling's bundle.
    parents = set(serve_pids)
    engine_pids = [p.pid for p in cores if p.gpus == GPU_SET or p.ppid in parents]
    return EngineProcesses(serve=serve_pids, engine=engine_pids, socket=next(iter(sockets), None))


def _alive(pid: int) -> bool:
    # Reads /proc rather than signal 0, which a zombie still answers: an engine killed but not
    # yet reaped by its parent has already released its VRAM and counts as dead here.
    try:
        with open(f"/proc/{pid}/stat", "rb") as fh:
            process_state = fh.read().rpartition(b")")[2].split()[0]
    except (OSError, IndexError):
        return False
    return process_state != b"Z"


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
    # SIGKILL only: a process stuck in a CUDA kernel ignores SIGTERM. Returns False when there
    # was nothing to kill or the engine survived the signal (a CUDA ioctl can leave a process
    # unkillable) — counting either as a restart would let a permanently wedged engine report
    # as cured every grace period. The scan is repeated here rather than reused from the poll:
    # pids read a minute ago may already belong to something else.
    found = find_engine_processes()
    if found is None:
        _log("wedge detected but this bundle's engine is ambiguous — killing nothing")
        return False
    serve, engine = found.serve, found.engine
    if not serve and not engine:
        _log("wedge detected but no `vllm serve` process found — nothing to restart")
        return False

    _log(f"restarting engine ({SCOPE}): SIGKILL serve={serve} (EngineCore={engine})")
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
        _log(f"WARNING: still alive after SIGKILL, not counting a restart: {still_alive}")
        return False
    return True


def write_state(
    restarts: int,
    last_restart: float,
    stall_s: float,
    sample: Sample | None,
    socket_path: str | None,
) -> None:
    # Written every tick, so its freshness doubles as the watchdog's own heartbeat: the
    # sidecar turns a stale file into dolphin_watchdog_up 0 instead of silence.
    # gpus + engine_socket are what let the sidecar label N bundles apart and publish
    # engine_found, so a watchdog that is running but cannot see its engine — the one state
    # that guards nothing while looking alive — is not silent.
    state = WatchdogState(
        updated=time.time(),
        poll_interval_s=POLL_INTERVAL_S,
        restarts_total=restarts,
        last_restart_timestamp=last_restart,
        stall_seconds=round(stall_s, 1),
        requests_running=sample.running if sample else None,
        generated_tokens=sample.generated if sample else None,
        gpus=",".join(GPU_SET) or None,
        engine_socket=socket_path,
    )
    tmp_path = f"{STATE_PATH}.tmp"
    try:
        with open(tmp_path, "w") as fh:
            json.dump(asdict(state), fh)
        os.replace(tmp_path, STATE_PATH)  # atomic: the sidecar never reads a half file
    except OSError as e:
        _log(f"could not write state to {STATE_PATH}: {e}")


def load_state() -> tuple[int, float]:
    # The watchdog's own restart (a crash, its supervisor loop) must not erase the count:
    # a machine that keeps wedging would then read as a machine that never wedged. Scope is
    # the container's lifetime — a new container starts from an empty directory anyway.
    state = WatchdogState.read(STATE_PATH)
    if state is None:
        return 0, 0.0
    return state.restarts_total, state.last_restart_timestamp


def main() -> None:
    restarts, last_restart = load_state()
    _log(
        f"watching {SCOPE}: poll {POLL_INTERVAL_S:.0f}s, stall limit {STALL_LIMIT_S:.0f}s, "
        f"state {STATE_PATH}, {restarts} restart(s) so far this container"
    )
    last_generated: float | None = None
    last_change = time.monotonic()
    armed_at = time.monotonic()
    reported_stall = False
    reported_socket: str | None = None

    while True:
        # Only split mode needs the scan: with one engine per container the sidecar's socket
        # discovery already points at the only engine there is.
        engine = find_engine_processes() if GPU_SET else None
        socket_path = engine.socket if engine else None
        if GPU_SET and socket_path != reported_socket:
            reported_socket = socket_path
            _log(f"engine for GPUs {','.join(GPU_SET)}: {socket_path or 'not identified'}")
        sample = read_engine(own_sockets(engine))
        now = time.monotonic()

        if sample is None or sample.generated != last_generated:
            last_generated = sample.generated if sample else None
            last_change = now
            reported_stall = False
        elif sample.running == 0:
            # An idle queue holds the clock at zero rather than merely failing the wedge test
            # below: stall banked while nothing was asked of the engine would otherwise fire
            # the moment the first request lands, when a poll can catch it mid-prefill
            # (running > 0, no tokens yet) and SIGKILL a healthy engine.
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

        write_state(restarts, last_restart, stall_s, sample, socket_path)
        time.sleep(POLL_INTERVAL_S)


if __name__ == "__main__":
    main()
