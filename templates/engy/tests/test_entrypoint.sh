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
echo "python3 $* | MAX_INFLIGHT=${MAX_INFLIGHT:-} ENGY_WORKER_NAME=${ENGY_WORKER_NAME:-} CUDA_VISIBLE_DEVICES=${CUDA_VISIBLE_DEVICES:-}" >>"${CALLS_LOG}"
case "$*" in
    *engy_miner.py*) sleep 30 ;;
    *) sleep 30 ;;
esac
STUB
    chmod +x "${SANDBOX}/bin/"*
}

run_entrypoint() {
    # Returns once the miner has been launched (or the timeout expires); the entrypoint never exits
    # on its own, so it is killed and its recorded calls are what the assertions read.
    CALLS_LOG="${SANDBOX}/calls.log" \
    PATH="${SANDBOX}/bin:${PATH}" \
    ENGY_HOME="${SANDBOX}/home" \
    ENGY_MINER_DIR="${SANDBOX}/miner" \
    "$@" bash "${ENTRYPOINT}" >"${SANDBOX}/out.log" 2>&1 &
    local pid=$!
    for _ in $(seq 1 50); do
        grep -q "engy_miner.py" "${SANDBOX}/calls.log" 2>/dev/null && break
        sleep 0.2
    done
    kill -TERM "${pid}" 2>/dev/null
    wait "${pid}" 2>/dev/null
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

echo
if [[ "${failures}" -eq 0 ]]; then
    echo "all entrypoint contract tests passed"
else
    echo "${failures} failure(s)"
    exit 1
fi
