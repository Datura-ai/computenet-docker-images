"""Run the vendored engy miner with Lium's three modifications applied from OUTSIDE the file.

`vendor/engy_miner.py` is now a byte-identical copy of upstream, and it must stay that way: the
entrypoint refreshes it from GitHub on every boot, so anything we edited in place would be silently
overwritten — including the lock below, whose loss would leave seven of eight GPUs unmined with
nothing in the log that reads as a failure.

Everything we need can be done without touching it, because all three hooks are module globals that
upstream reads at CALL time:

  WORKER_ID   read inside `_run` when it sends HELLO, so assigning it after import is enough.
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

SINGLETON_PATH_TEMPLATE: str = "/tmp/engy_miner.singleton.{worker_id}"

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


def take_worker_singleton(worker_id: str) -> None:
    """One miner per WORKER, not per node.

    Upstream locks a single node-wide path, which is right for one miner per box and wrong for us:
    we run one miner per GPU inside one container, and a node-wide lock would admit the first and
    make the other seven exit with 'another instance is running'.
    """
    global _singleton_file
    lock_file: IO[str] = open(SINGLETON_PATH_TEMPLATE.format(worker_id=worker_id), "w")
    try:
        fcntl.flock(lock_file, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        print(f"[engy-launch] worker {worker_id} already running here; exiting", flush=True)
        raise SystemExit(0)
    _singleton_file = lock_file


def apply_stable_worker_id() -> str:
    """Upstream mints `uuid4().hex` per PROCESS and engy's control plane keys a worker on that id,
    so every restart used to register a brand-new worker and throw away hours of onboarding."""
    require("WORKER_ID")
    worker_id: str = os.environ.get("ENGY_WORKER_ID", "")
    if worker_id:
        engy_miner.WORKER_ID = worker_id
    return engy_miner.WORKER_ID


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

    async def serve_all_with_probe(*args: Any, **kwargs: Any) -> Any:
        # Keyed on the worker NAME inside start(): the id is per-process, so a restarted miner
        # would leave a second, frozen file behind for the same engy_worker label.
        globals()["_loop_probe"] = loop_probe.start(engy_miner.WORKER_NAME, lambda: len(jobs_in_flight))
        return await original_serve_all(*args, **kwargs)

    engy_miner._serve_all = serve_all_with_probe


def main() -> None:
    worker_id: str = apply_stable_worker_id()
    take_worker_singleton(worker_id)
    install_loop_probe()
    print(f"[engy-launch] upstream miner with Lium modifications, worker_id={worker_id}", flush=True)
    require("main")()


if __name__ == "__main__":
    main()
