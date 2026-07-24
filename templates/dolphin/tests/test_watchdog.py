"""Watchdog contract tests. Stdlib only, no pytest, same shape as test_sidecar.py:
runnable as `python3 tests/test_watchdog.py` on the host AND inside the built image.
Nothing is mocked — the real watchdog and the real sidecar run as subprocesses.

Three sections. The decision half (when is an engine wedged?) drives a fake engine whose
token counter the test moves. The kill half needs /proc and is skipped without it, so a
macOS host reports SKIP and the in-image run covers it — that is where it matters anyway,
since the watchdog only ever sees its own container's processes. The last section starts
the sidecar instead and checks what a scraper sees.

The fake engine serves the captured vLLM body with the two series the watchdog reads
rewritten per test, so the parsing is exercised against the real exposition format.
"""

import contextlib
import dataclasses
import importlib.util
import json
import os
import pathlib
import re
import subprocess
import sys
import tempfile
import threading
import time

import test_sidecar as sidecar_tests  # reuse the uds server plumbing and sidecar harness

HERE = pathlib.Path(__file__).resolve().parent
WATCHDOG_PATH = os.environ.get("WATCHDOG_PATH", str(HERE.parent / "watchdog.py"))
FIXTURE = sidecar_tests.FIXTURE


def _load_shipped_sidecar():
    # the state fixtures below are built from the shipped WatchdogState, so a field renamed
    # on the production side fails here instead of silently emptying the exported series
    spec = importlib.util.spec_from_file_location("shipped_sidecar", sidecar_tests.SIDECAR_PATH)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


WatchdogState = _load_shipped_sidecar().WatchdogState

POLL_S = 0.2
STALL_S = 0.6
GRACE_S = 4.0
ENGINE_CORE_S = 0.3


class Skipped(Exception):
    """Raised by a test that cannot run in this environment (reported, not failed)."""


def engine_body(generated: float, running: float) -> bytes:
    # rewrite the two series the watchdog reads, leaving the rest of the real body intact
    body = re.sub(
        rb"^vllm:generation_tokens_total(\{[^}]*\})? .*$",
        f"vllm:generation_tokens_total{{engine=\"0\"}} {generated}".encode(),
        FIXTURE,
        count=1,
        flags=re.M,
    )
    return re.sub(
        rb"^vllm:num_requests_running(\{[^}]*\})? .*$",
        f"vllm:num_requests_running{{engine=\"0\"}} {running}".encode(),
        body,
        count=1,
        flags=re.M,
    )


class Engine:
    """Fake vLLM whose counters the test moves between scrapes."""

    def __init__(self, generated: float, running: float) -> None:
        self.generated = generated
        self.running = running
        self.lock = threading.Lock()

    def body(self) -> bytes:
        with self.lock:
            return engine_body(self.generated, self.running)

    def produce(self, tokens: float) -> None:
        with self.lock:
            self.generated += tokens


@contextlib.contextmanager
def fake_engine(sock_path: pathlib.Path, engine: Engine):
    # like sidecar_tests.fake_vllm, but the body is regenerated per request
    handler = type(
        "H",
        (sidecar_tests._UdsHandler,),
        {"do_GET": lambda self: _respond(self, engine.body())},
    )
    server = sidecar_tests._UdsServer(str(sock_path), handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield
    finally:
        server.shutdown()
        server.server_close()


def _respond(handler, body: bytes) -> None:
    handler.send_response(200)
    handler.send_header("Content-Type", "text/plain")
    handler.send_header("Content-Length", str(len(body)))
    handler.end_headers()
    handler.wfile.write(body)


@contextlib.contextmanager
def watchdog(glob_pattern: str, state_path: pathlib.Path, stall_s: float = STALL_S):
    env = dict(os.environ)
    env["METRICS_SOCKET_GLOB"] = glob_pattern
    env["DOLPHIN_WATCHDOG_STATE"] = str(state_path)
    env["DOLPHIN_WATCHDOG_POLL_SECONDS"] = str(POLL_S)
    env["DOLPHIN_WATCHDOG_STALL_SECONDS"] = str(stall_s)
    env["DOLPHIN_WATCHDOG_GRACE_SECONDS"] = str(GRACE_S)
    env["DOLPHIN_WATCHDOG_ENGINE_CORE_SECONDS"] = str(ENGINE_CORE_S)
    proc = subprocess.Popen(
        [sys.executable, WATCHDOG_PATH], env=env,
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    try:
        yield proc
    finally:
        proc.terminate()
        proc.wait(timeout=5)


@contextlib.contextmanager
def sidecar_with_state_file(state_path: pathlib.Path, glob_pattern: str):
    # the sidecar reads the state path from the environment at import time, so it has to be
    # set before the subprocess starts and removed after, or it leaks into every later test
    os.environ["DOLPHIN_WATCHDOG_STATE"] = str(state_path)
    try:
        with sidecar_tests.sidecar(glob_pattern, sidecar_tests.TOKEN) as base:
            yield base
    finally:
        del os.environ["DOLPHIN_WATCHDOG_STATE"]


def write_state_file(path: pathlib.Path, updated: float, restarts: int, stall_s: float) -> None:
    path.write_text(json.dumps(dataclasses.asdict(WatchdogState(
        updated=updated,
        max_write_gap_s=86.0,
        restarts_total=restarts,
        last_restart_timestamp=1769000000.0,
        stall_seconds=stall_s,
        requests_running=None,
        generated_tokens=None,
    ))))


def read_watchdog_state(path: pathlib.Path) -> WatchdogState:
    # parsed through the shipped reader, so every assertion below also proves the file the
    # watchdog writes is the file the sidecar can read; retries until the first tick lands
    for _ in range(80):
        state = WatchdogState.read(str(path))
        if state is not None:
            return state
        time.sleep(0.05)
    raise AssertionError(f"watchdog never wrote usable state to {path}")


def wait_for(predicate, timeout_s: float, what: str) -> None:
    deadline = time.monotonic() + timeout_s
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(0.05)
    raise AssertionError(f"timed out waiting for {what}")


def require_proc() -> None:
    if not os.path.isdir("/proc"):
        raise Skipped("needs /proc (run inside the image)")


@contextlib.contextmanager
def fake_process(argv0: str):
    # a process whose /proc cmdline looks like the engine's, so the watchdog finds it the
    # same way it does in production; `exec -a` is what makes the fake name stick
    proc = subprocess.Popen(["bash", "-c", f"exec -a '{argv0}' sleep 300"])
    try:
        yield proc
    finally:
        with contextlib.suppress(ProcessLookupError):
            proc.kill()
        with contextlib.suppress(subprocess.TimeoutExpired):
            proc.wait(timeout=5)


def is_dead(proc: subprocess.Popen) -> bool:
    return proc.poll() is not None


# --- decision half: when is an engine wedged? -------------------------------------


def test_growing_counter_is_left_alone() -> None:
    engine = Engine(generated=1000.0, running=8.0)
    with tempfile.TemporaryDirectory() as tmp:
        sock = pathlib.Path(tmp) / "dp-1" / "v.sock"
        sock.parent.mkdir()
        state = pathlib.Path(tmp) / "state.json"
        with fake_engine(sock, engine), watchdog(f"{tmp}/dp-*/v.sock", state):
            for _ in range(12):
                time.sleep(POLL_S)
                engine.produce(500.0)
            final = read_watchdog_state(state)
    assert final.restarts_total == 0, "a producing engine must never be restarted"
    assert final.stall_seconds < STALL_S, final.stall_seconds


def test_idle_queue_is_not_a_wedge() -> None:
    # counters frozen because there is nothing to do — a demand problem, not a fault.
    # The clock must stay at zero, not merely be masked: stall banked while idle would
    # fire the moment the first request lands (see the mid-prefill test below).
    engine = Engine(generated=1000.0, running=0.0)
    with tempfile.TemporaryDirectory() as tmp:
        sock = pathlib.Path(tmp) / "dp-1" / "v.sock"
        sock.parent.mkdir()
        state = pathlib.Path(tmp) / "state.json"
        with fake_engine(sock, engine), watchdog(f"{tmp}/dp-*/v.sock", state):
            time.sleep(STALL_S * 4)
            final = read_watchdog_state(state)
    assert final.restarts_total == 0, "an idle engine must not be restarted"
    assert final.stall_seconds < STALL_S, "idle time must not arm the stall clock"


def test_missing_socket_is_not_a_wedge() -> None:
    # cold start: no engine yet, and restarting the worker would only send it back
    with tempfile.TemporaryDirectory() as tmp:
        state = pathlib.Path(tmp) / "state.json"
        with watchdog(f"{tmp}/dp-*/v.sock", state):
            time.sleep(STALL_S * 4)
            final = read_watchdog_state(state)
    assert final.restarts_total == 0
    assert final.stall_seconds < STALL_S, "no engine means no stall to accumulate"
    assert final.requests_running is None


def test_a_silent_socket_keeps_the_stall_clock_running() -> None:
    # an engine that stops answering is the wedge itself; if an unreadable scrape reset the
    # clock, a wedge on a flapping socket would never accumulate enough stall to fire
    with tempfile.TemporaryDirectory() as tmp:
        sock = pathlib.Path(tmp) / "dp-1" / "v.sock"
        sock.parent.mkdir()
        sock.write_bytes(b"")  # discoverable, but nothing is listening on it
        state = pathlib.Path(tmp) / "state.json"
        with watchdog(f"{tmp}/dp-*/v.sock", state):
            wait_for(lambda: read_watchdog_state(state).stall_seconds >= STALL_S, 8.0, "the stall clock")
            final = read_watchdog_state(state)
    assert final.restarts_total == 0, "a silent engine is never proof enough to kill"


# --- kill half: does it restart the right processes? ------------------------------


def test_frozen_counter_with_requests_restarts_engine() -> None:
    require_proc()
    engine = Engine(generated=1000.0, running=12.0)
    with tempfile.TemporaryDirectory() as tmp:
        sock = pathlib.Path(tmp) / "dp-1" / "v.sock"
        sock.parent.mkdir()
        state = pathlib.Path(tmp) / "state.json"
        with fake_process("vllm serve --model fake") as serve, fake_engine(sock, engine):
            with watchdog(f"{tmp}/dp-*/v.sock", state):
                wait_for(lambda: is_dead(serve), 8.0, "`vllm serve` to be killed")
                wait_for(
                    lambda: read_watchdog_state(state).restarts_total == 1, 8.0, "restart to be recorded"
                )
                final = read_watchdog_state(state)
    assert final.last_restart_timestamp > 0, "the restart must be timestamped for the scraper"


def test_first_request_after_idle_is_not_killed_mid_prefill() -> None:
    # The false positive this guards: stall banked during a quiet stretch, then the first
    # request lands and a poll catches it mid-prefill — requests running, no tokens
    # generated yet. The clock may only start counting from the last poll that saw the
    # queue empty, so the engine gets the full stall window, not the remainder of one
    # that expired while nothing was asked of it.
    require_proc()
    engine = Engine(generated=1000.0, running=0.0)
    with tempfile.TemporaryDirectory() as tmp:
        sock = pathlib.Path(tmp) / "dp-1" / "v.sock"
        sock.parent.mkdir()
        state = pathlib.Path(tmp) / "state.json"
        with fake_process("vllm serve --model fake") as serve, fake_engine(sock, engine):
            with watchdog(f"{tmp}/dp-*/v.sock", state):
                time.sleep(STALL_S * 4)  # idle long past the stall limit
                with engine.lock:
                    engine.running = 8.0  # first request arrives; prefill: no tokens yet
                time.sleep(STALL_S / 2)  # a poll lands inside the prefill window
                assert not is_dead(serve), "prefill after idle must get the full stall window"
                engine.produce(500.0)  # generation starts; the engine was healthy all along
                time.sleep(STALL_S / 2)
                assert not is_dead(serve), "a producing engine must never be restarted"
                assert read_watchdog_state(state).restarts_total == 0


def test_engine_core_child_is_killed_when_it_outlives_the_parent() -> None:
    # 12 of 12 production cases: the child survives the parent and holds ~70 GB of VRAM,
    # which blocks the respawn until it is killed directly
    require_proc()
    engine = Engine(generated=1000.0, running=12.0)
    with tempfile.TemporaryDirectory() as tmp:
        sock = pathlib.Path(tmp) / "dp-1" / "v.sock"
        sock.parent.mkdir()
        state = pathlib.Path(tmp) / "state.json"
        with fake_process("vllm serve --model fake") as serve, \
             fake_process("VLLM::EngineCore") as child, \
             fake_engine(sock, engine):
            with watchdog(f"{tmp}/dp-*/v.sock", state):
                wait_for(lambda: is_dead(serve), 8.0, "`vllm serve` to be killed")
                wait_for(lambda: is_dead(child), 8.0, "the orphaned EngineCore to be killed")


def test_unrelated_processes_survive() -> None:
    require_proc()
    engine = Engine(generated=1000.0, running=12.0)
    with tempfile.TemporaryDirectory() as tmp:
        sock = pathlib.Path(tmp) / "dp-1" / "v.sock"
        sock.parent.mkdir()
        state = pathlib.Path(tmp) / "state.json"
        with fake_process("vllm serve --model fake") as serve, \
             fake_process("dolphinpod-worker start") as worker, \
             fake_engine(sock, engine):
            with watchdog(f"{tmp}/dp-*/v.sock", state):
                wait_for(lambda: is_dead(serve), 8.0, "`vllm serve` to be killed")
                time.sleep(1.0)
                assert not is_dead(worker), "the watchdog must restart the engine, not the worker"


def test_grace_period_blocks_a_second_restart() -> None:
    require_proc()
    engine = Engine(generated=1000.0, running=12.0)
    with tempfile.TemporaryDirectory() as tmp:
        sock = pathlib.Path(tmp) / "dp-1" / "v.sock"
        sock.parent.mkdir()
        state = pathlib.Path(tmp) / "state.json"
        with fake_process("vllm serve --model fake") as first, fake_engine(sock, engine):
            with watchdog(f"{tmp}/dp-*/v.sock", state):
                wait_for(lambda: is_dead(first), 8.0, "the first kill")
                # the engine is reloading weights; a second kill here would restart the
                # restart and never let it finish
                with fake_process("vllm serve --model fake") as second:
                    time.sleep(STALL_S * 4)
                    assert not is_dead(second), "a reloading engine must not be killed again"
                    assert read_watchdog_state(state).restarts_total == 1


def test_restart_count_survives_a_watchdog_restart() -> None:
    # the watchdog is itself supervised; if its own crash reset the counter, a machine that
    # wedges every hour would read as a machine that never wedged
    require_proc()
    engine = Engine(generated=1000.0, running=12.0)
    with tempfile.TemporaryDirectory() as tmp:
        sock = pathlib.Path(tmp) / "dp-1" / "v.sock"
        sock.parent.mkdir()
        state = pathlib.Path(tmp) / "state.json"
        with fake_engine(sock, engine):
            with fake_process("vllm serve --model fake") as first, \
                 watchdog(f"{tmp}/dp-*/v.sock", state):
                wait_for(lambda: is_dead(first), 8.0, "the first kill")
                wait_for(lambda: read_watchdog_state(state).restarts_total == 1, 8.0, "the first count")
            # watchdog gone; a fresh one must pick the count up from the state file
            with fake_process("vllm serve --model fake") as second, \
                 watchdog(f"{tmp}/dp-*/v.sock", state):
                wait_for(lambda: is_dead(second), 8.0, "the second kill")
                wait_for(lambda: read_watchdog_state(state).restarts_total == 2, 8.0, "the count to continue")


# --- what the scraper sees --------------------------------------------------------


def test_state_reaches_the_sidecar_as_series() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        state = pathlib.Path(tmp) / "state.json"
        write_state_file(state, updated=time.time(), restarts=3, stall_s=12.4)
        with sidecar_with_state_file(state, f"{tmp}/dp-*/v.sock") as base:
            status, body, _ = sidecar_tests.get(f"{base}/metrics")
    assert status == 200, status
    assert b"dolphin_watchdog_up 1\n" in body, body[-200:]
    assert b"dolphin_watchdog_restarts_total 3\n" in body
    assert b"dolphin_watchdog_last_restart_timestamp 1769000000\n" in body
    assert b"dolphin_watchdog_stall_seconds 12\n" in body


def test_dead_watchdog_reports_itself_down() -> None:
    # a stale state file must not read as a healthy watchdog — silence would look like health
    with tempfile.TemporaryDirectory() as tmp:
        state = pathlib.Path(tmp) / "state.json"
        write_state_file(state, updated=time.time() - 3600, restarts=2, stall_s=0.0)
        with sidecar_with_state_file(state, f"{tmp}/dp-*/v.sock") as base:
            _, body, _ = sidecar_tests.get(f"{base}/metrics")
    assert b"dolphin_watchdog_up 0\n" in body, body[-200:]
    assert b"dolphin_watchdog_restarts_total 2\n" in body, "last known numbers stay readable"


def test_a_corrupt_state_file_does_not_take_metrics_down() -> None:
    # the sidecar's whole contract is that it always answers, so the scraper can tell
    # "worker dead" from "sidecar dead"; a file the watchdog writes must never break that
    corrupt_payloads = ("null", "[1, 2]", '"text"', '{"updated": "yesterday"}', "{}")
    with tempfile.TemporaryDirectory() as tmp:
        state = pathlib.Path(tmp) / "state.json"
        state.write_text("{}")
        with sidecar_with_state_file(state, f"{tmp}/dp-*/v.sock") as base:
            for corrupt in corrupt_payloads:  # the file is re-read on every request
                state.write_text(corrupt)
                status, body, _ = sidecar_tests.get(f"{base}/metrics")
                assert status == 200, f"{corrupt!r} broke /metrics: {status}"
                assert b"dolphin_sidecar_up 1\n" in body, corrupt
                assert b"dolphin_watchdog" not in body, f"{corrupt!r} invented series"


def test_no_watchdog_means_no_series() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        absent = pathlib.Path(tmp) / "absent.json"
        with sidecar_with_state_file(absent, f"{tmp}/dp-*/v.sock") as base:
            _, body, _ = sidecar_tests.get(f"{base}/metrics")
    assert b"dolphin_watchdog" not in body, "zeros would claim a watchdog that is not running"


def main() -> None:
    tests = [(name, fn) for name, fn in sorted(globals().items()) if name.startswith("test_")]
    failed = skipped = 0
    for name, fn in tests:
        try:
            fn()
            print(f"PASS {name}")
        except Skipped as e:
            skipped += 1
            print(f"SKIP {name}: {e}")
        except Exception as e:
            failed += 1
            print(f"FAIL {name}: {e}")
    print(f"{len(tests) - failed - skipped}/{len(tests)} passed, {skipped} skipped")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
