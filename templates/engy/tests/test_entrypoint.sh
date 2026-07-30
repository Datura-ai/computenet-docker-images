#!/usr/bin/env bash
# Contract tests for templates/engy/entrypoint.sh, runnable on a laptop: nvidia-smi, curl, hf and
# python3 are replaced by stubs on PATH, so what is under test is the entrypoint's own decisions —
# how many engines it starts, on which ports, and what capacity it declares to the gateway.
#
#   bash templates/engy/tests/test_entrypoint.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ENTRYPOINT="${HERE}/../entrypoint.sh"
failures=0

fail() { echo "  FAIL: $*"; failures=$((failures + 1)); }
pass() { echo "  ok: $*"; }

# One sandbox per case: stub bin dir, a fake checkpoint so no download is attempted, and a log the
# stubs append their argv to.
new_sandbox() {
    local gpu_count="$1"
    SANDBOX="$(mktemp -d)"
    mkdir -p "${SANDBOX}/bin" "${SANDBOX}/home/models/Qwen/Qwen3.6-35B-A3B-FP8" "${SANDBOX}/miner"
    echo '{}' >"${SANDBOX}/home/models/Qwen/Qwen3.6-35B-A3B-FP8/config.json"
    : >"${SANDBOX}/calls.log"

    { echo '#!/usr/bin/env bash'; echo "seq 0 $((gpu_count - 1))"; } >"${SANDBOX}/bin/nvidia-smi"
    # Every engine reports ready immediately; the supervisor loop then sees them healthy.
    { echo '#!/usr/bin/env bash'; echo 'exit 0'; } >"${SANDBOX}/bin/curl"
    { echo '#!/usr/bin/env bash'; echo 'exit 0'; } >"${SANDBOX}/bin/hf"
    # python3 records how it was invoked and, for the miner, blocks so the loop does not spin.
    cat >"${SANDBOX}/bin/python3" <<'STUB'
#!/usr/bin/env bash
echo "python3 $* | MAX_INFLIGHT=${MAX_INFLIGHT:-} ENGY_WORKER_NAME=${ENGY_WORKER_NAME:-} ENGY_PROBE_DIR=${ENGY_PROBE_DIR:-} CUDA_VISIBLE_DEVICES=${CUDA_VISIBLE_DEVICES:-}" >>"${CALLS_LOG}"
case "$*" in
    *engy_miner.py*) echo "[engy-miner] stub speaking on stdout"; sleep 30 ;;
    *) sleep 30 ;;
esac
STUB
    chmod +x "${SANDBOX}/bin/"*
}

start_entrypoint() {
    # Launches the entrypoint in the sandbox and returns once the miner is up (or the wait expires),
    # leaving it running as ENTRYPOINT_PID. The entrypoint never exits on its own, so every caller
    # has to stop it; its recorded calls are what the assertions read.
    CALLS_LOG="${SANDBOX}/calls.log" \
    PATH="${SANDBOX}/bin:${PATH}" \
    ENGY_HOME="${SANDBOX}/home" \
    ENGY_MINER_DIR="${SANDBOX}/miner" \
    "$@" bash "${ENTRYPOINT}" >"${SANDBOX}/out.log" 2>&1 &
    ENTRYPOINT_PID=$!
    # Loud on timeout, never silent: a readiness wait that expires and lets the assertions run anyway
    # reports "0 engines" on a busy machine and reads like a real regression.
    local waited=0
    while (( waited < 150 )); do
        grep -q "engy_miner.py" "${SANDBOX}/calls.log" 2>/dev/null && return 0
        sleep 0.2
        waited=$((waited + 1))
    done
    fail "the miner never started within 30s; entrypoint said: $(tail -2 "${SANDBOX}/out.log" 2>&1)"
}

run_entrypoint() {
    start_entrypoint "$@"
    kill -TERM "${ENTRYPOINT_PID}" 2>/dev/null
    wait "${ENTRYPOINT_PID}" 2>/dev/null
}

echo "== a missing MINER_KEY is refused before anything starts =="
new_sandbox 1
PATH="${SANDBOX}/bin:${PATH}" ENGY_HOME="${SANDBOX}/home" CALLS_LOG="${SANDBOX}/calls.log" \
    bash "${ENTRYPOINT}" >"${SANDBOX}/out.log" 2>&1
if [[ $? -eq 0 ]]; then
    fail "entrypoint exited 0 without MINER_KEY"
elif grep -q "MINER_KEY is required" "${SANDBOX}/out.log"; then
    pass "refused with a named reason"
else
    fail "refused, but not for the stated reason: $(tail -1 "${SANDBOX}/out.log")"
fi
rm -rf "${SANDBOX}"

echo "== one engine per GPU, ports increment from 8000 =="
new_sandbox 4
run_entrypoint env MINER_KEY=mk-test
engines="$(grep -c "sglang.launch_server" "${SANDBOX}/calls.log")"
[[ "${engines}" -eq 4 ]] && pass "4 GPUs -> 4 engines" || fail "4 GPUs -> ${engines} engines"
for port in 8000 8001 8002 8003; do
    grep -q -- "--port ${port}" "${SANDBOX}/calls.log" || fail "no engine on port ${port}"
done
grep -q -- "--tp-size 1" "${SANDBOX}/calls.log" && pass "engines are tp=1" || fail "engines are not tp=1"
# Without this flag sglang answers /health_generate but 404s on /metrics, so the sidecar reports
# every engine unreachable and the node looks like it earns nothing.
grep -q -- "--enable-metrics" "${SANDBOX}/calls.log" && pass "engines expose /metrics" || fail "engines do not expose /metrics"
# Each engine must be pinned to its own card, or they all pile onto GPU 0.
for gpu in 0 1 2 3; do
    grep -q "CUDA_VISIBLE_DEVICES=${gpu}$" "${SANDBOX}/calls.log" || fail "no engine pinned to GPU ${gpu}"
done
pass "each engine pinned to its own GPU"
rm -rf "${SANDBOX}"

echo "== declared capacity is the SUM across engines =="
new_sandbox 2
run_entrypoint env MINER_KEY=mk-test ENGY_MAX_RUNNING_REQUESTS=8
if grep "engy_miner.py" "${SANDBOX}/calls.log" | grep -q "MAX_INFLIGHT=16"; then
    pass "2 engines x 8 -> MAX_INFLIGHT=16"
else
    fail "expected MAX_INFLIGHT=16, got: $(grep 'engy_miner.py' "${SANDBOX}/calls.log" | head -1)"
fi
if grep "engy_miner.py" "${SANDBOX}/calls.log" | grep -q -- "--serve-url http://127.0.0.1:8000,http://127.0.0.1:8001"; then
    pass "the miner drives every engine"
else
    fail "miner serve-url wrong: $(grep 'engy_miner.py' "${SANDBOX}/calls.log" | head -1)"
fi
rm -rf "${SANDBOX}"

echo "== exactly one miner process, whatever the GPU count =="
new_sandbox 8
run_entrypoint env MINER_KEY=mk-test
miners="$(grep -c "engy_miner.py" "${SANDBOX}/calls.log")"
[[ "${miners}" -eq 1 ]] && pass "8 GPUs -> 1 miner (one hotkey, one blast radius)" || fail "8 GPUs -> ${miners} miners"
rm -rf "${SANDBOX}"

echo "== the event-loop lag probe is wired up =="
# Without it, our own GIL stall and the gateway going quiet are the same Close(1011) in the log.
new_sandbox 2
# METRICS_TOKEN, or the sidecar never starts and the assertion below would pass on an empty log.
run_entrypoint env MINER_KEY=mk-test METRICS_TOKEN=probe-test-token
if grep "engy_miner.py" "${SANDBOX}/calls.log" | grep -q "ENGY_PROBE_DIR=${SANDBOX}/home/probe"; then
    pass "the miner is told where to publish its loop lag"
else
    fail "miner started without ENGY_PROBE_DIR: $(grep 'engy_miner.py' "${SANDBOX}/calls.log" | head -1)"
fi
if grep "metrics_sidecar.py" "${SANDBOX}/calls.log" | grep -q "ENGY_PROBE_DIR=${SANDBOX}/home/probe"; then
    pass "the sidecar is told where to read it from"
else
    fail "sidecar started without ENGY_PROBE_DIR"
fi
[[ -d "${SANDBOX}/home/probe" ]] && pass "the probe directory is created" || fail "no probe directory"
rm -rf "${SANDBOX}"

echo "== stale probe files from a previous container are cleared =="
# The directory lives on the shared cache volume, so a node that comes back with fewer cards would
# otherwise keep publishing frozen lag series for GPUs it no longer has.
new_sandbox 1
mkdir -p "${SANDBOX}/home/probe"
echo 'engy_miner_loop_lag_seconds_max{engy_worker="gone-g7"} 99' >"${SANDBOX}/home/probe/loop-stale.prom"
run_entrypoint env MINER_KEY=mk-test
[[ -f "${SANDBOX}/home/probe/loop-stale.prom" ]] && fail "a stale probe file survived startup" \
    || pass "stale probe files are removed at startup"
rm -rf "${SANDBOX}"

echo "== the miner's stdout is kept on disk =="
# On a miner's host the container's stdout goes to a docker pipe we have no access to, so this file
# is the only record of why a routed request failed.
new_sandbox 1
run_entrypoint env MINER_KEY=mk-test
miner_log="${SANDBOX}/home/logs/miner.log"
if [[ -f "${miner_log}" ]] && grep -q "stub speaking on stdout" "${miner_log}"; then
    pass "miner output is tee'd to ${miner_log##*/}"
else
    fail "miner output not captured: $(ls "${SANDBOX}/home/logs" 2>&1)"
fi
# The entrypoint's own lines matter as much as the miner's: "engine never became ready" is the whole
# answer when an engine dies, and it is printed by this script, not by the miner.
grep -q "GPU(s) ->" "${miner_log}" 2>/dev/null \
    && pass "the entrypoint's own output is captured too" \
    || fail "entrypoint output missing from the log"
# Every line carries a timestamp, or reading this against engy's per-second dashboard is guesswork.
# Only when `ts` is installed; the entrypoint deliberately still works without it.
if command -v ts >/dev/null 2>&1; then
    if grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}[+-][0-9]{4} ' "${miner_log}"; then
        pass "log lines are timestamped"
    else
        fail "log lines have no timestamp: $(head -1 "${miner_log}")"
    fi
else
    pass "ts not installed here; timestamp check skipped (the image ships moreutils)"
fi
rm -rf "${SANDBOX}"

echo "== a refusal to start is logged, not just printed =="
# The container that refuses to boot is exactly the one whose reason we cannot otherwise reach.
new_sandbox 1
PATH="${SANDBOX}/bin:${PATH}" ENGY_HOME="${SANDBOX}/home" CALLS_LOG="${SANDBOX}/calls.log" \
    bash "${ENTRYPOINT}" >"${SANDBOX}/out.log" 2>&1
grep -q "MINER_KEY is required" "${SANDBOX}/home/logs/miner.log" 2>/dev/null \
    && pass "the missing-key refusal reaches the log file" \
    || fail "refusal never reached the log: $(ls "${SANDBOX}/home/logs" 2>&1)"
rm -rf "${SANDBOX}"

echo "== the sidecar is up before the engines are ready =="
# A cold start is a 35GB download plus warmup, and a node that never becomes ready is the one you
# most want to read. Verified on a real L40S box: with the sidecar started after the readiness wait,
# /logs answered nothing for the entire startup window.
new_sandbox 1
# This curl stub never reports an engine healthy, so the readiness wait blocks forever.
printf '#!/usr/bin/env bash\nexit 1\n' >"${SANDBOX}/bin/curl"
chmod +x "${SANDBOX}/bin/curl"
CALLS_LOG="${SANDBOX}/calls.log" PATH="${SANDBOX}/bin:${PATH}" \
ENGY_HOME="${SANDBOX}/home" ENGY_MINER_DIR="${SANDBOX}/miner" \
    env MINER_KEY=mk-test METRICS_TOKEN=tok-test bash "${ENTRYPOINT}" >"${SANDBOX}/out.log" 2>&1 &
never_ready_pid=$!
sidecar_started=""
for _ in $(seq 1 50); do
    grep -q "metrics_sidecar.py" "${SANDBOX}/calls.log" 2>/dev/null && { sidecar_started=yes; break; }
    sleep 0.2
done
if [[ -n "${sidecar_started}" ]]; then
    pass "sidecar starts while the engines are still coming up"
else
    fail "sidecar never started while engines were unready"
fi
grep -q "engy_miner.py" "${SANDBOX}/calls.log" 2>/dev/null \
    && fail "the miner started even though no engine was ready" \
    || pass "the miner still waits for a ready engine"
kill -TERM "${never_ready_pid}" 2>/dev/null
wait "${never_ready_pid}" 2>/dev/null
rm -rf "${SANDBOX}"

echo "== SIGTERM stops the container promptly =="
# A filler stop gets FILLER_STOP_WAIT_TIMEOUT_SECONDS (30s) before the platform gives up, and
# shutdown() ends in a bare `wait`. Every long-lived child must be killed before it: the log trimmer
# loops forever, and the sidecar serves forever. Run it with and without METRICS_TOKEN, because only
# the token case starts the sidecar and that is the case production actually runs.
assert_stops_on_sigterm() {
    local case_name="$1"
    shift
    new_sandbox 1
    start_entrypoint env MINER_KEY=mk-test "$@"
    kill -TERM "${ENTRYPOINT_PID}" 2>/dev/null
    local stopped=""
    for _ in $(seq 1 50); do            # 10s ceiling, well inside the platform's 30s
        kill -0 "${ENTRYPOINT_PID}" 2>/dev/null || { stopped=yes; break; }
        sleep 0.2
    done
    if [[ -n "${stopped}" ]]; then
        pass "${case_name}: exited on SIGTERM"
    else
        fail "${case_name}: still running 10s after SIGTERM"
        kill -KILL "${ENTRYPOINT_PID}" 2>/dev/null
    fi
    wait "${ENTRYPOINT_PID}" 2>/dev/null
    rm -rf "${SANDBOX}"
}

assert_stops_on_sigterm "no sidecar"
assert_stops_on_sigterm "with sidecar" METRICS_TOKEN=tok-test

echo
if [[ "${failures}" -eq 0 ]]; then
    echo "all entrypoint contract tests passed"
else
    echo "${failures} failure(s)"
    exit 1
fi
