"""Run the vendored engy miner with Lium's three modifications applied from OUTSIDE the file.

`vendor/engy_miner.py` is now a byte-identical copy of upstream, and it must stay that way: the
entrypoint refreshes it from GitHub on every boot, so anything we edited in place would be silently
overwritten — including the lock below, whose loss would leave seven of eight GPUs unmined with
nothing in the log that reads as a failure.

Everything we need can be done without touching it, because all three hooks are module globals that
upstream reads at CALL time:

  _worker_name  upstream's own name resolver, called to key our lock on the same name it will
                register under.
  the lock    lives in upstream's `if __name__ == "__main__"` block, which never runs on import —
              so importing rather than executing removes it for free, and we take our own.
  _serve_all  looked up as a global by `main()`, so wrapping it injects the loop probe.

If upstream ever renames one of those three, this module fails loudly at startup rather than
quietly dropping a modification — see `require`.

The same hook names are asserted in two other places, and all three must move together: the
entrypoint's REQUIRED_MINER_HOOKS, which refuses a refreshed upstream that lacks them, and
tests/test_launch.py, which proves the refusal happens.
"""

from __future__ import annotations

import fcntl
import os
import sys
from typing import IO, Any, Callable

sys.path.insert(0, os.environ.get("ENGY_MINER_DIR", "/opt/engy-miner"))

import engy_miner  # noqa: E402
import loop_probe  # noqa: E402

SINGLETON_PATH_TEMPLATE: str = "/tmp/engy_miner.singleton.{worker_name}"

# Held open for the life of the process — closing it would release the lock.
_singleton_file: IO[str] | None = None


def require(attribute: str) -> Any:
    """Fail loudly when upstream moves a hook we depend on.

    A refresh that renames `_serve_all` would otherwise leave the miner running with no probe, or
    with a random worker id — working, earning less, and silent about why.
    """
    if not hasattr(engy_miner, attribute):
        raise SystemExit(
            f"[engy-launch] vendored engy_miner has no '{attribute}' — upstream changed shape and "
            f"Lium's modifications no longer apply. Refusing to start rather than run unmodified."
        )
    return getattr(engy_miner, attribute)


def take_worker_singleton(worker_name: str) -> None:
    """One miner per WORKER, not per node.

    Upstream locks a single node-wide path, which is right for one miner per box and wrong for us:
    we run one miner per GPU inside one container, and a node-wide lock would admit the first and
    make the other seven exit with 'another instance is running'.

    Keyed on the worker NAME, which is stable per card. The worker id is not: it is a fresh uuid4
    per process (see `main`), so locking on it would give every process its own path and never
    collide — a lock that can't fail is not a lock.
    """
    global _singleton_file
    lock_file: IO[str] = open(SINGLETON_PATH_TEMPLATE.format(worker_name=worker_name), "w")
    try:
        fcntl.flock(lock_file, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        print(f"[engy-launch] worker {worker_name} already running here; exiting", flush=True)
        raise SystemExit(0)
    _singleton_file = lock_file


def cards_this_worker_fronts() -> int:
    """How many cards this miner's engine actually holds — the entrypoint's `--tp-size`.

    Validated here because the environment is a boundary: an unset, empty or nonsense value means
    the single-card shape the image has always run, never a crash on the way to the HELLO.
    """
    declared: str = os.environ.get("ENGY_WORKER_GPU_COUNT", "")
    return int(declared) if declared.isdigit() and int(declared) >= 1 else 1


def announce_only_this_workers_cards() -> None:
    """Report the cards THIS miner's engine spans, not the node's.

    Upstream builds the HELLO hardware summary from `nvidia-smi`, which lists the whole node and
    ignores CUDA_VISIBLE_DEVICES, so all eight of our miners announced the node's eight cards each.
    `HW_GPUS` (set by the entrypoint) only overrides the human-readable string; the count beside it
    has to be corrected here or the frame contradicts itself.

    One per card at `--tp-size 1`, and the whole group above it: a tensor-parallel engine really is
    backed by all of them, and that is what the network's own tensor-parallel workers report
    (`GET /v1/network`: `"gpus": "8x NVIDIA B300 SXM6 AC"` with `"gpu_count": 8`).
    """
    hardware: dict[str, Any] = require("HW")
    if hardware.get("gpu_count"):
        hardware["gpu_count"] = cards_this_worker_fronts()


def install_loop_probe() -> None:
    """Start the event-loop lag probe inside the miner's own loop, by wrapping `_serve_all`.

    It has to run on that loop to measure it, and `main()` looks the function up as a global when it
    calls `asyncio.run`, so replacing the attribute is enough.
    """
    original_serve_all: Callable = require("_serve_all")
    # Checked HERE, not inside the wrapper: a renamed _JOBS must fail at startup like every other
    # hook, not at the first served request. Bound by identity because upstream mutates this dict in
    # place and never reassigns it.
    jobs_in_flight: dict[str, object] = require("_JOBS")
    # Checked at startup even though it is read later: the wrapper below reaches for WORKER_NAME at
    # call time, so without this a renamed WORKER_NAME passes every boot check and then kills the
    # miner with an AttributeError on its first serve — every card, every 60s, forever.
    require("WORKER_NAME")

    async def serve_all_with_probe(*args: Any, **kwargs: Any) -> Any:
        # Keyed on the worker NAME inside start(): the id is per-process, so a restarted miner
        # would leave a second, frozen file behind for the same engy_worker label.
        globals()["_loop_probe"] = loop_probe.start(engy_miner.WORKER_NAME, lambda: len(jobs_in_flight))
        return await original_serve_all(*args, **kwargs)

    engy_miner._serve_all = serve_all_with_probe


def main() -> None:
    # The worker id stays upstream's per-process uuid4 ON PURPOSE. Pinning it (DAH-2531) made a
    # restart a re-dial, but engy's control plane records a worker's declared max inflight at the
    # record it creates on FIRST onboarding and never refreshes it on reconnect — so a pinned id
    # also pinned the capacity, and every later config change was a silent no-op. Onboarding is
    # quick now, so a new worker per restart is the cheaper side of that trade.
    #
    # Resolved through upstream's own function rather than its WORKER_NAME global, which is still
    # None until upstream's main() runs — after we need the lock.
    worker_name: str = require("_worker_name")()
    take_worker_singleton(worker_name)
    announce_only_this_workers_cards()
    install_loop_probe()
    print(f"[engy-launch] upstream miner with Lium modifications, worker={worker_name}", flush=True)
    require("main")()


if __name__ == "__main__":
    main()
