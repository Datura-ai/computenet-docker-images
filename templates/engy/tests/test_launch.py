"""Launcher contract tests (DAH-2531). Stdlib only, no pytest dependency:

    python3 tests/test_launch.py

The entrypoint refreshes `vendor/engy_miner.py` from upstream on every boot, so the vendored file
must stay byte-identical to upstream and every Lium modification must live in `engy_launch.py`.
These tests are what keeps that true: they assert the vendored file is unpatched, that the launcher
still applies all three modifications to it, and — the case that actually costs money — that a
future upstream which renames a hook makes the launcher REFUSE rather than start unmodified.
"""

import os
import pathlib
import sys
import types

TEMPLATE_DIR: pathlib.Path = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(TEMPLATE_DIR))

failures: list[str] = []


def check(condition: bool, description: str) -> None:
    if condition:
        print(f"  ok: {description}")
    else:
        failures.append(description)
        print(f"  FAIL: {description}")


def stub_heavy_dependencies() -> None:
    """The miner imports torch and friends at module scope; the launcher is what is under test."""
    for name in ("numpy", "requests", "torch", "websockets", "toploc", "transformers"):
        sys.modules.setdefault(name, types.ModuleType(name))
    sys.modules["toploc"].build_proofs_base64 = lambda *args, **kwargs: None
    sys.modules["transformers"].AutoTokenizer = object
    sys.modules["numpy"].float32 = float
    sys.modules["websockets"].ConnectionClosed = type("ConnectionClosed", (Exception,), {})


def check_vendored_miner_is_unpatched_upstream() -> None:
    vendored_source: str = (TEMPLATE_DIR / "vendor" / "engy_miner.py").read_text(encoding="utf-8")
    print("== the vendored miner is unpatched upstream ==")
    # If this ever fails, the boot-time refresh will silently delete whatever was added — including
    # the per-worker lock, whose loss leaves seven of eight GPUs unmined and logs nothing.
    check("LIUM PATCH" not in vendored_source, "no Lium patch markers in the vendored file")
    check('open("/tmp/engy_miner.singleton"' in vendored_source,
          "upstream's own node-wide lock is still there, untouched")
    check("import loop_probe" not in vendored_source, "the probe is not injected by editing the file")


def check_launcher_applies_every_modification() -> None:
    stub_heavy_dependencies()
    # In the image both files sit in ENGY_MINER_DIR; in the repo the miner is under vendor/.
    os.environ.update(ENGY_MINER_DIR=str(TEMPLATE_DIR / "vendor"), ENGY_WORKER_ID="testworkerid00",
                      GW="wss://x/gw")
    os.environ.pop("ENGY_PROBE_DIR", None)
    import engy_launch
    import engy_miner

    print("== the launcher applies every modification from outside ==")
    check(engy_launch.apply_stable_worker_id() == "testworkerid00",
          "WORKER_ID comes from the environment, so a restart is a re-dial not a new worker")
    engy_launch.take_worker_singleton("testworkerid00")
    check(os.path.exists("/tmp/engy_miner.singleton.testworkerid00"),
          "the singleton lock is per worker, so N miners can share one container")

    original_serve_all = engy_miner._serve_all
    engy_launch.install_loop_probe()
    check(engy_miner._serve_all is not original_serve_all,
          "the loop probe is installed by wrapping _serve_all")


def check_unset_worker_id_leaves_upstream_alone() -> None:
    import engy_launch
    import engy_miner
    print("== an unset ENGY_WORKER_ID leaves upstream's behaviour alone ==")
    os.environ.pop("ENGY_WORKER_ID")
    engy_miner.WORKER_ID = "upstream-generated"
    check(engy_launch.apply_stable_worker_id() == "upstream-generated",
          "no override -> upstream's per-process id, unchanged")


def check_a_renamed_hook_refuses_to_start() -> None:
    import engy_launch
    import engy_miner
    print("== a renamed hook refuses to start instead of running unmodified ==")
    # The whole point of the refresh being safe. Running with a random worker id and no probe would
    # look healthy and quietly cost re-onboarding on every restart.
    for hook in ("_serve_all", "WORKER_ID", "main"):
        original_hook = getattr(engy_miner, hook)
        delattr(engy_miner, hook)
        try:
            engy_launch.require(hook)
            check(False, f"a missing {hook} was not caught")
        except SystemExit as error:
            check(hook in str(error), f"a missing {hook} refuses loudly")
        finally:
            setattr(engy_miner, hook, original_hook)


def main() -> int:
    check_vendored_miner_is_unpatched_upstream()
    check_launcher_applies_every_modification()
    check_unset_worker_id_leaves_upstream_alone()
    check_a_renamed_hook_refuses_to_start()
    print()
    if failures:
        print(f"{len(failures)} failure(s)")
        return 1
    print("all launcher contract tests passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
