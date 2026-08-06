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
    local gpu_count="$1" card_mb="${2:-143771}"     # an H200 unless the case says otherwise
    SANDBOX="$(mktemp -d)"
    mkdir -p "${SANDBOX}/bin" "${SANDBOX}/home/models/Qwen/Qwen3.6-35B-A3B-FP8" "${SANDBOX}/miner"
    echo '{}' >"${SANDBOX}/home/models/Qwen/Qwen3.6-35B-A3B-FP8/config.json"
    : >"${SANDBOX}/calls.log"

    # Answers the two queries the entrypoint makes: the card list, and how big those cards are.
    { echo '#!/usr/bin/env bash'
      echo "case \"\$*\" in *memory.total*) for _ in \$(seq 1 ${gpu_count}); do echo ${card_mb}; done ;;"
      echo "                *) seq 0 $((gpu_count - 1)) ;; esac"
    } >"${SANDBOX}/bin/nvidia-smi"
    # Every engine reports ready immediately; the supervisor loop then sees them healthy.
    { echo '#!/usr/bin/env bash'; echo 'exit 0'; } >"${SANDBOX}/bin/curl"
    { echo '#!/usr/bin/env bash'; echo 'exit 0'; } >"${SANDBOX}/bin/hf"
    # python3 records how it was invoked and, for the miner, blocks so the loop does not spin.
    cat >"${SANDBOX}/bin/python3" <<'STUB'
#!/usr/bin/env bash
echo "python3 $* | MAX_INFLIGHT=${MAX_INFLIGHT:-} ENGY_WORKER_NAME=${ENGY_WORKER_NAME:-} ENGY_WORKER_ID=${ENGY_WORKER_ID:-} ENGY_PROBE_DIR=${ENGY_PROBE_DIR:-} CUDA_VISIBLE_DEVICES=${CUDA_VISIBLE_DEVICES:-}" >>"${CALLS_LOG}"
case "$*" in
    *engy_launch.py*) echo "[engy-miner] stub speaking on stdout"; sleep 30 ;;
    # Faithful to the image: PYTHONPATH points at sitecustomize.py, which prints an "armed" banner
    # on STDOUT at interpreter startup. Anything reading this command's stdout as a verdict breaks.
    *py_compile*) [[ -n "${PYTHONPATH:-}" ]] && echo "[engy] hidden-states trim armed"; exit 0 ;;
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
        grep -q "engy_launch.py" "${SANDBOX}/calls.log" 2>/dev/null && return 0
        sleep 0.2
        waited=$((waited + 1))
    done
    fail "the miner never started within 30s; entrypoint said: $(tail -2 "${SANDBOX}/out.log" 2>&1)"
}

# The distinct worker ids the miners were started with, one per line.
worker_names() {
    grep "engy_launch.py" "${SANDBOX}/calls.log" | grep -o "ENGY_WORKER_NAME=[^ ][^ ]*" | sort -u
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
entrypoint_status=$?
sleep 1                       # the log reaches disk through a process substitution, not directly
if [[ ${entrypoint_status} -eq 0 ]]; then
    fail "entrypoint exited 0 without MINER_KEY"
elif grep -q "MINER_KEY is required" "${SANDBOX}/out.log"; then
    pass "refused with a named reason"
else
    fail "refused, but not for the stated reason: $(tail -1 "${SANDBOX}/out.log")"
fi
rm -rf "${SANDBOX}"

echo "== one engine per GPU, ports increment from 8000 =="
new_sandbox 4
run_entrypoint env MINER_KEY=mk-test ENGY_CACHE_SEED_WAIT_SECONDS=1
engines="$(grep -c "sglang.launch_server" "${SANDBOX}/calls.log")"
[[ "${engines}" -eq 4 ]] && pass "4 GPUs -> 4 engines" || fail "4 GPUs -> ${engines} engines"
for port in 8000 8001 8002 8003; do
    grep -q -- "--port ${port}" "${SANDBOX}/calls.log" || fail "no engine on port ${port}"
done
grep -q -- "--tp-size 1" "${SANDBOX}/calls.log" && pass "engines are tp=1" || fail "engines are not tp=1"
# An engine with a card to itself keeps the whole card: this is the value the image has always run.
grep -q -- "--mem-fraction-static 0.85" "${SANDBOX}/calls.log" \
    && pass "one engine per card reserves 0.85 of it" \
    || fail "single-engine mem fraction changed: $(grep -o -- '--mem-fraction-static [0-9.]*' "${SANDBOX}/calls.log" | head -1)"
# Without this flag sglang answers /health_generate but 404s on /metrics, so the sidecar reports
# every engine unreachable and the node looks like it earns nothing.
grep -q -- "--enable-metrics" "${SANDBOX}/calls.log" && pass "engines expose /metrics" || fail "engines do not expose /metrics"
# Each engine must be pinned to its own card, or they all pile onto GPU 0.
for gpu in 0 1 2 3; do
    grep -q "CUDA_VISIBLE_DEVICES=${gpu}$" "${SANDBOX}/calls.log" || fail "no engine pinned to GPU ${gpu}"
done
pass "each engine pinned to its own GPU"
rm -rf "${SANDBOX}"

echo "== one miner per engine, each declaring only its own engine's capacity =="
# The GIL is per PROCESS, so one miner driving N engines serialises every hidden-state parse behind
# one interpreter. One miner per engine turns that single queue into N. See ARCHITECTURE.md.
new_sandbox 2
run_entrypoint env MINER_KEY=mk-test ENGY_CACHE_SEED_WAIT_SECONDS=1 ENGY_MAX_RUNNING_REQUESTS=8
miners="$(grep -c "engy_launch.py" "${SANDBOX}/calls.log")"
[[ "${miners}" -eq 2 ]] && pass "2 engines -> 2 miners" || fail "2 engines -> ${miners} miners"
for port in 8000 8001; do
    grep "engy_launch.py" "${SANDBOX}/calls.log" | grep -q -- "--serve-url http://127.0.0.1:${port} " \
        || fail "no miner dedicated to the engine on port ${port}"
done
pass "each miner drives exactly one engine"
# Each miner declares its OWN engine's concurrency, never the node total: the probe burst the gateway
# sends is sized against what a single worker advertises.
if grep "engy_launch.py" "${SANDBOX}/calls.log" | grep -qv "MAX_INFLIGHT=8"; then
    fail "a miner declared something other than its engine's 8: $(grep 'engy_launch.py' "${SANDBOX}/calls.log" | head -1)"
else
    pass "every miner declares MAX_INFLIGHT=8, not the node sum"
fi

echo "== no worker id is pinned, and each card gets its own name =="
# Pinning the id made a restart a re-dial, but engy records a worker's declared max inflight at the
# record it creates on FIRST onboarding and never refreshes it — so a pinned id also pinned the
# capacity and every later config change was a silent no-op. Onboarding is quick now, so we let the
# miner mint a fresh id per process and re-register.
if grep "engy_launch.py" "${SANDBOX}/calls.log" | grep -q "ENGY_WORKER_ID=[^ ]"; then
    fail "the entrypoint still pins ENGY_WORKER_ID"
else
    pass "no ENGY_WORKER_ID is passed, so the miner registers fresh on every start"
fi
distinct_names="$(worker_names | wc -l | tr -d " ")"
[[ "${distinct_names}" -eq 2 ]] && pass "each card gets its own worker name" \
    || fail "expected 2 distinct worker names, got ${distinct_names}"
rm -rf "${SANDBOX}"

echo "== two engines per GPU share the card and each gets its own miner =="
# The card is not the constraint on an H200/B200 (prod: 2 concurrent across eight engines), and the
# gateway hands out work per WORKER — so a second engine on the same card is a second worker.
new_sandbox 2
run_entrypoint env MINER_KEY=mk-test ENGY_CACHE_SEED_WAIT_SECONDS=1 ENGY_ENGINES_PER_GPU=2
engines="$(grep -c "sglang.launch_server" "${SANDBOX}/calls.log")"
[[ "${engines}" -eq 4 ]] && pass "2 GPUs x 2 -> 4 engines" || fail "2 GPUs x 2 -> ${engines} engines"
miners="$(grep -c "engy_launch.py" "${SANDBOX}/calls.log")"
[[ "${miners}" -eq 4 ]] && pass "every engine still gets its own miner" || fail "expected 4 miners, got ${miners}"
# The name is the only handle on a worker in the engy dashboard and the metric labels, so with
# engines sharing a card it has to say which CARD, not just which engine.
distinct_names="$(worker_names | wc -l | tr -d " ")"
[[ "${distinct_names}" -eq 4 ]] && pass "and its own worker name" || fail "expected 4 distinct worker names, got ${distinct_names}"
if worker_names | grep -q -- "-g1e1"; then
    pass "worker names name the card and the slot on it"
else
    fail "worker names do not identify the card: $(worker_names | tr '\n' ' ')"
fi
# Engines 0-1 belong to card 0 and 2-3 to card 1. Getting this wrong piles every engine onto GPU 0,
# which fits in VRAM and looks healthy — the second card just silently earns nothing.
assert_engine_pinned_to_gpu() {
    local port="$1" gpu="$2"
    grep "sglang.launch_server" "${SANDBOX}/calls.log" | grep -- "--port ${port} " | grep -q "CUDA_VISIBLE_DEVICES=${gpu}$" \
        && pass "the engine on ${port} runs on GPU ${gpu}" \
        || fail "the engine on ${port} is not on GPU ${gpu}: $(grep -- "--port ${port} " "${SANDBOX}/calls.log")"
}
assert_engine_pinned_to_gpu 8000 0
assert_engine_pinned_to_gpu 8001 0
assert_engine_pinned_to_gpu 8002 1
assert_engine_pinned_to_gpu 8003 1
# sglang keeps a reserve proportional to what the engine finds FREE at its own start, not to the
# whole card, so the second engine on a card needs a BIGGER fraction to end up with the same pool.
# Measured live on an H200: two engines at 0.42 each left the second with a negative pool and it
# died with "Not enough memory".
assert_engine_mem_fraction() {
    local port="$1" fraction="$2"
    grep "sglang.launch_server" "${SANDBOX}/calls.log" | grep -- "--port ${port} " | grep -q -- "--mem-fraction-static ${fraction} " \
        && pass "the engine on ${port} reserves ${fraction}" \
        || fail "the engine on ${port} is not at ${fraction}: $(grep -- "--port ${port} " "${SANDBOX}/calls.log" | grep -o -- '--mem-fraction-static [0-9.]*')"
}
assert_engine_mem_fraction 8000 0.425
assert_engine_mem_fraction 8001 0.7391
assert_engine_mem_fraction 8002 0.425
assert_engine_mem_fraction 8003 0.7391
rm -rf "${SANDBOX}"

echo "== the second engine on a card waits for the first to load =="
# Both measure the memory they find free, so starting them together makes both plan for an empty
# card and the second ends up with no pool at all.
new_sandbox 1
# Nothing ever becomes ready, so slot 0 never finishes loading and slot 1 must stay unstarted.
{ echo '#!/usr/bin/env bash'; echo 'case "$*" in *health_generate*) exit 7 ;; esac; exit 0'; } >"${SANDBOX}/bin/curl"
chmod +x "${SANDBOX}/bin/curl"
CALLS_LOG="${SANDBOX}/calls.log" PATH="${SANDBOX}/bin:${PATH}" ENGY_HOME="${SANDBOX}/home" \
    ENGY_MINER_DIR="${SANDBOX}/miner" \
    env MINER_KEY=mk-test ENGY_ENGINES_PER_GPU=2 ENGY_CACHE_SEED_WAIT_SECONDS=2 \
        ENGY_ENGINE_READY_TIMEOUT_SECONDS=15 bash "${ENTRYPOINT}" >"${SANDBOX}/out.log" 2>&1 &
ENTRYPOINT_PID=$!
sleep 8
engines_early="$(grep -c "sglang.launch_server" "${SANDBOX}/calls.log")"
[[ "${engines_early}" -eq 1 ]] && pass "slot 1 is held while slot 0 is still loading" \
    || fail "expected 1 engine while slot 0 loads, got ${engines_early}"
# The seed wait and the slot wait both poll on a 10s tick, so the release lands ~30s in, not at the
# raw timeout value.
sleep 35
engines_late="$(grep -c "sglang.launch_server" "${SANDBOX}/calls.log")"
[[ "${engines_late}" -eq 2 ]] && pass "and starts anyway once the wait is spent" \
    || fail "expected 2 engines after the wait, got ${engines_late}"
grep -q "slot 0 did not finish loading" "${SANDBOX}/out.log" \
    && pass "a slot that never loads is reported, not fatal" || fail "silent about the stuck slot"
kill -TERM "${ENTRYPOINT_PID}" 2>/dev/null; wait "${ENTRYPOINT_PID}" 2>/dev/null
rm -rf "${SANDBOX}"

echo "== a card too small for the split runs fewer engines instead of OOM-looping =="
# The value comes from platform config, and each engine holds its own 35GB copy of the checkpoint.
# A wrong one must cost a log line, not a crash-loop of 35GB loads.
new_sandbox 1 49152                                  # exactly one engine's worth of VRAM
run_entrypoint env MINER_KEY=mk-test ENGY_CACHE_SEED_WAIT_SECONDS=1 ENGY_ENGINES_PER_GPU=4
engines="$(grep -c "sglang.launch_server" "${SANDBOX}/calls.log")"
[[ "${engines}" -eq 1 ]] && pass "4 per card on a 48GB card -> 1 engine" || fail "started ${engines} engines on a card that holds one"
grep -q "does not fit a 49152MB card" "${SANDBOX}/out.log" \
    && pass "and the log says it was clamped" || fail "clamped silently"
rm -rf "${SANDBOX}"

echo "== a card whose size cannot be read is taken at the operator's word =="
# An unreadable card must not silently halve a healthy node.
new_sandbox 1
{ echo '#!/usr/bin/env bash'; echo 'case "$*" in *memory.total*) exit 1 ;; *) echo 0 ;; esac'; } >"${SANDBOX}/bin/nvidia-smi"
chmod +x "${SANDBOX}/bin/nvidia-smi"
run_entrypoint env MINER_KEY=mk-test ENGY_CACHE_SEED_WAIT_SECONDS=1 ENGY_ENGINES_PER_GPU=2
engines="$(grep -c "sglang.launch_server" "${SANDBOX}/calls.log")"
[[ "${engines}" -eq 2 ]] && pass "the requested split still runs" || fail "expected 2 engines, got ${engines}"
grep -q "could not read card size" "${SANDBOX}/out.log" && pass "and says so" || fail "silent about the unreadable card"
rm -rf "${SANDBOX}"

echo "== a nonsense engines-per-GPU falls back to one =="
new_sandbox 1
run_entrypoint env MINER_KEY=mk-test ENGY_CACHE_SEED_WAIT_SECONDS=1 ENGY_ENGINES_PER_GPU=abc
engines="$(grep -c "sglang.launch_server" "${SANDBOX}/calls.log")"
[[ "${engines}" -eq 1 ]] && pass "a non-numeric value runs the default shape" || fail "started ${engines} engines"
grep -q "is not a positive number" "${SANDBOX}/out.log" \
    && pass "and the fallback is logged" || fail "fell back silently"
rm -rf "${SANDBOX}"

echo "== the default declared concurrency is the onboarding floor, not lower =="
# The miner derives its gateway connection count from MAX_INFLIGHT, and a worker holding fewer than
# the gateway's 8 connections is refused onboarding outright. Measured on a rented H100: declaring 4
# failed in three seconds with "offered 4 distinct clean legs, below the required 8", zero traffic.
new_sandbox 2
run_entrypoint env MINER_KEY=mk-test ENGY_CACHE_SEED_WAIT_SECONDS=1
if grep "engy_launch.py" "${SANDBOX}/calls.log" | grep -qv "MAX_INFLIGHT=8"; then
    fail "default declared concurrency is not 8: $(grep 'engy_launch.py' "${SANDBOX}/calls.log" | head -1)"
else
    pass "with no override every miner declares 8"
fi
grep -q -- "--max-running-requests 8" "${SANDBOX}/calls.log" \
    && pass "the engine is sized to match what the miner declares" \
    || fail "engine --max-running-requests does not match the declared 8"
rm -rf "${SANDBOX}"

new_sandbox 2
run_entrypoint env MINER_KEY=mk-test ENGY_CACHE_SEED_WAIT_SECONDS=1 ENGY_MAX_RUNNING_REQUESTS=4
if grep "engy_launch.py" "${SANDBOX}/calls.log" | grep -qv "MAX_INFLIGHT=8"; then
    fail "an override below the floor reached the gateway: $(grep 'engy_launch.py' "${SANDBOX}/calls.log" | head -1)"
else
    pass "an override below the floor is raised back to 8 instead of earning nothing"
fi
rm -rf "${SANDBOX}"

echo "== the event-loop lag probe is wired up =="
# Without it, our own GIL stall and the gateway going quiet are the same Close(1011) in the log.
new_sandbox 2
# METRICS_TOKEN, or the sidecar never starts and its assertion below would pass on an empty log.
run_entrypoint env MINER_KEY=mk-test ENGY_CACHE_SEED_WAIT_SECONDS=1 METRICS_TOKEN=probe-test-token
if grep "engy_launch.py" "${SANDBOX}/calls.log" | grep -qv "ENGY_PROBE_DIR=${SANDBOX}/home/probe"; then
    fail "a miner started without ENGY_PROBE_DIR: $(grep 'engy_launch.py' "${SANDBOX}/calls.log" | head -1)"
else
    pass "every miner is told where to publish its loop lag"
fi
if grep "metrics_sidecar.py" "${SANDBOX}/calls.log" | grep -q "ENGY_PROBE_DIR=${SANDBOX}/home/probe"; then
    pass "the sidecar is told where to read it from"
else
    fail "sidecar started without ENGY_PROBE_DIR"
fi
[[ -d "${SANDBOX}/home/probe" ]] && pass "the probe directory is created" || fail "no probe directory"
rm -rf "${SANDBOX}"

echo "== a node with no GPUs is refused loudly, never silently =="
# grep -c exits 1 on empty input; under set -e that killed the script at the assignment, before
# refuse_to_start could put the reason on disk — a dead node with a completely empty log.
new_sandbox 1
{ echo '#!/usr/bin/env bash'; echo 'exit 0'; } >"${SANDBOX}/bin/nvidia-smi"   # succeeds, lists nothing
chmod +x "${SANDBOX}/bin/nvidia-smi"
PATH="${SANDBOX}/bin:${PATH}" ENGY_HOME="${SANDBOX}/home" ENGY_MINER_DIR="${SANDBOX}/miner" \
    CALLS_LOG="${SANDBOX}/calls.log" env MINER_KEY=mk-test bash "${ENTRYPOINT}" >"${SANDBOX}/out.log" 2>&1
entrypoint_status=$?
sleep 1
[[ ${entrypoint_status} -ne 0 ]] && pass "zero GPUs -> non-zero exit" || fail "exited 0 with no GPUs"
grep -q "no GPUs visible" "${SANDBOX}/out.log" \
    && pass "and the reason reaches the log" \
    || fail "died without a reason: $(tail -2 "${SANDBOX}/out.log")"
rm -rf "${SANDBOX}"

echo "== a refreshed upstream missing WORKER_NAME is discarded =="
# engy_launch reads WORKER_NAME at call time, so without this hook a rename passes every boot check
# and then kills the miner on its first serve — every card, every 60s, forever.
new_sandbox 1
echo "${BAKED_IN_MARKER:-MARKER_BAKED_IN_COPY}" >"${SANDBOX}/miner/engy_miner.py"
{ echo '#!/usr/bin/env bash'
  echo 'for a in "$@"; do [[ "$prev" == "-o" ]] && printf "def _worker_name(): return \\"w\\"\nasync def _serve_all(): pass\ndef main(): pass\n_JOBS = {}\n" > "$a"; prev="$a"; done; exit 0'
} >"${SANDBOX}/bin/curl"
chmod +x "${SANDBOX}/bin/curl"
run_entrypoint env MINER_KEY=mk-test ENGY_CACHE_SEED_WAIT_SECONDS=1
grep -q "MARKER_BAKED_IN_COPY" "${SANDBOX}/miner/engy_miner.py" \
    && pass "an upstream without WORKER_NAME is rejected" \
    || fail "took an upstream engy_launch cannot use"
grep -q "WORKER_NAME" "${SANDBOX}/out.log" && pass "and names the missing hook" || fail "silent about which hook"
rm -rf "${SANDBOX}"

echo "== the first engine seeds the shared kernel cache before the rest start =="
# sglang JIT-compiles ~16k FP8 kernels into DG_JIT_CACHE_DIR on the shared volume. Started together,
# every engine pays that 10-20 minute compile and they race over the same files.
new_sandbox 4
# Nothing is ever ready, so the seed wait runs to its (short) budget and we can see the ordering.
{ echo '#!/usr/bin/env bash'; echo 'case "$*" in *health_generate*) exit 7 ;; esac; exit 0'; } >"${SANDBOX}/bin/curl"
chmod +x "${SANDBOX}/bin/curl"
CALLS_LOG="${SANDBOX}/calls.log" PATH="${SANDBOX}/bin:${PATH}" ENGY_HOME="${SANDBOX}/home" \
    ENGY_MINER_DIR="${SANDBOX}/miner" \
    env MINER_KEY=mk-test ENGY_CACHE_SEED_WAIT_SECONDS=20 ENGY_ENGINE_READY_TIMEOUT_SECONDS=2 \
    bash "${ENTRYPOINT}" >"${SANDBOX}/out.log" 2>&1 &
ENTRYPOINT_PID=$!
sleep 6
engines_early="$(grep -c "sglang.launch_server" "${SANDBOX}/calls.log")"
[[ "${engines_early}" -eq 1 ]] && pass "only the seeding engine starts at first" \
    || fail "expected 1 engine while seeding, got ${engines_early}"
grep -q "seeding the shared kernel cache" "${SANDBOX}/out.log" \
    && pass "the wait is announced" || fail "no seeding message"
sleep 22
engines_late="$(grep -c "sglang.launch_server" "${SANDBOX}/calls.log")"
[[ "${engines_late}" -eq 4 ]] && pass "the siblings start once the budget expires" \
    || fail "expected 4 engines after the seed budget, got ${engines_late}"
grep -q "cache not seeded" "${SANDBOX}/out.log" \
    && pass "a seed that never lands is reported, not fatal" || fail "silent about the failed seed"
kill -TERM "${ENTRYPOINT_PID}" 2>/dev/null; wait "${ENTRYPOINT_PID}" 2>/dev/null
rm -rf "${SANDBOX}"

echo "== a single-GPU node does not wait for a seed =="
new_sandbox 1
start_entrypoint env MINER_KEY=mk-test
grep -q "seeding the shared kernel cache" "${SANDBOX}/out.log" \
    && fail "one GPU should have nothing to seed for" || pass "no seed wait when there is one card"
kill -TERM "${ENTRYPOINT_PID}" 2>/dev/null; wait "${ENTRYPOINT_PID}" 2>/dev/null
rm -rf "${SANDBOX}"

echo "== one dead card costs one card, not the node =="
# Before one miner per GPU this refused the whole container, which was right when losing an engine
# lost the only worker anyway. Now seven healthy cards must keep earning through one sick one.
new_sandbox 3
# Port 8001 never answers /health_generate; the other two do.
{ echo '#!/usr/bin/env bash'
  echo 'case "$*" in *127.0.0.1:8001/health_generate*) exit 7 ;; esac; exit 0'
} >"${SANDBOX}/bin/curl"
chmod +x "${SANDBOX}/bin/curl"
start_entrypoint env MINER_KEY=mk-test ENGY_CACHE_SEED_WAIT_SECONDS=1 ENGY_ENGINE_READY_TIMEOUT_SECONDS=5
sleep 12
miners="$(grep -c "engy_launch.py" "${SANDBOX}/calls.log")"
[[ "${miners}" -eq 2 ]] && pass "2 of 3 engines got miners" || fail "expected 2 miners, got ${miners}"
kill -0 "${ENTRYPOINT_PID}" 2>/dev/null && pass "the container stayed up" || fail "the container died over one bad card"
grep -q "never became ready" "${SANDBOX}/out.log" && pass "the bad card is named in the log" || fail "the bad card was skipped silently"
grep -q "2 of 3 engine(s) mining" "${SANDBOX}/out.log" && pass "it reports how many are mining" || fail "no mining count in the log"
kill -TERM "${ENTRYPOINT_PID}" 2>/dev/null; wait "${ENTRYPOINT_PID}" 2>/dev/null
rm -rf "${SANDBOX}"

echo "== a node where nothing came up is still refused =="
new_sandbox 2
{ echo '#!/usr/bin/env bash'; echo 'case "$*" in *health_generate*) exit 7 ;; esac; exit 0'; } >"${SANDBOX}/bin/curl"
chmod +x "${SANDBOX}/bin/curl"
PATH="${SANDBOX}/bin:${PATH}" ENGY_HOME="${SANDBOX}/home" ENGY_MINER_DIR="${SANDBOX}/miner" \
    CALLS_LOG="${SANDBOX}/calls.log" \
    env MINER_KEY=mk-test ENGY_ENGINE_READY_TIMEOUT_SECONDS=3 ENGY_CACHE_SEED_WAIT_SECONDS=5 bash "${ENTRYPOINT}" >"${SANDBOX}/out.log" 2>&1
if [[ $? -ne 0 ]] && grep -q "no engine became ready" "${SANDBOX}/out.log"; then
    pass "zero ready engines -> refuse with a named reason"
else
    fail "a node with no working card was not refused: $(tail -2 "${SANDBOX}/out.log")"
fi
rm -rf "${SANDBOX}"

echo "== the boot-time miner refresh never breaks the container =="
# The vendored miner is refreshed from upstream on every boot. A refresh that can brick a node is
# worse than a stale miner, so every failure path must fall back to the copy baked into the image.
BAKED_IN_MARKER="MARKER_BAKED_IN_COPY"

# Runs the entrypoint with `curl` replaced by `stub_body`, then asserts whether the image's copy of
# the miner survived. `expectation` is kept|replaced.
assert_refresh_outcome() {
    local description="$1" stub_body="$2" expectation="$3"
    shift 3
    new_sandbox 1
    echo "${BAKED_IN_MARKER}" >"${SANDBOX}/miner/engy_miner.py"
    { echo '#!/usr/bin/env bash'; echo "${stub_body}"; } >"${SANDBOX}/bin/curl"
    chmod +x "${SANDBOX}/bin/curl"
    run_entrypoint env MINER_KEY=mk-test ENGY_CACHE_SEED_WAIT_SECONDS=1 "$@"
    if grep -q "${BAKED_IN_MARKER}" "${SANDBOX}/miner/engy_miner.py"; then
        [[ "${expectation}" == "kept" ]] && pass "${description}" || fail "${description}"
    else
        [[ "${expectation}" == "replaced" ]] && pass "${description}" || fail "${description}"
    fi
}

# A download that produces nothing at all.
assert_refresh_outcome "a failed download leaves the image's copy in place" 'exit 0' kept

# A download that succeeds but hands back something without the hooks engy_launch.py needs. Taking
# it would leave every miner on a random worker id with no probe: working, earning less, and silent.
CURL_STUB_WRITES_PAYLOAD='for a in "$@"; do [[ "$prev" == "-o" ]] && printf "%s" "$PAYLOAD" > "$a"; prev="$a"; done; exit 0'
PAYLOAD='print(1)' assert_refresh_outcome "an upstream missing our hooks is discarded" \
    "${CURL_STUB_WRITES_PAYLOAD}" kept
grep -q "discarding the fetched miner" "${SANDBOX}/out.log" \
    && pass "and the log says why" || fail "discarded silently"
rm -rf "${SANDBOX}"

PAYLOAD='def _worker_name(): return "w"
WORKER_NAME = "w"
async def _serve_all(): pass
def main(): pass
_JOBS = {}
HW = {}' assert_refresh_outcome "a valid upstream replaces the image's copy" \
    "${CURL_STUB_WRITES_PAYLOAD}" replaced
rm -rf "${SANDBOX}"

assert_refresh_outcome "ENGY_MINER_AUTO_UPDATE=0 pins the image's copy" \
    "${CURL_STUB_WRITES_PAYLOAD}" kept ENGY_MINER_AUTO_UPDATE=0
rm -rf "${SANDBOX}"

echo "== a container that refuses to start actually exits =="
# Killing the sidecar subshell leaves its python holding the log pipe, so refuse_to_start's wait
# for the pipe never returns and the container hangs instead of refusing. Reproduced on bare bash.
new_sandbox 2
{ echo '#!/usr/bin/env bash'; echo 'case "$*" in *health_generate*) exit 7 ;; esac; exit 0'; } >"${SANDBOX}/bin/curl"
chmod +x "${SANDBOX}/bin/curl"
CALLS_LOG="${SANDBOX}/calls.log" PATH="${SANDBOX}/bin:${PATH}" ENGY_HOME="${SANDBOX}/home" \
    ENGY_MINER_DIR="${SANDBOX}/miner" \
    env MINER_KEY=mk-test METRICS_TOKEN=t ENGY_CACHE_SEED_WAIT_SECONDS=2 \
        ENGY_ENGINE_READY_TIMEOUT_SECONDS=2 bash "${ENTRYPOINT}" >"${SANDBOX}/out.log" 2>&1 &
refusal_pid=$!
waited=0
while (( waited < 40 )) && kill -0 "${refusal_pid}" 2>/dev/null; do sleep 1; waited=$((waited + 1)); done
if kill -0 "${refusal_pid}" 2>/dev/null; then
    fail "the refusal hung — the sidecar's child still holds the log pipe"
    kill -9 "${refusal_pid}" 2>/dev/null
else
    pass "a sidecar with a live child does not block the refusal"
fi
grep -q "no engine became ready" "${SANDBOX}/out.log" && pass "and the reason is on disk" || fail "no reason logged"
rm -rf "${SANDBOX}"

echo "== an engine that never becomes ready is eventually restarted =="
# It is alive and holds no requests, so the token-based wedge test never arms; without this the
# card sits idle for the life of the container. Two GPUs: one healthy so the container survives.
new_sandbox 2
{ echo '#!/usr/bin/env bash'
  echo 'case "$*" in *8001/health_generate*) exit 7 ;; *8001/metrics*) exit 7 ;; esac; exit 0'
} >"${SANDBOX}/bin/curl"
chmod +x "${SANDBOX}/bin/curl"
start_entrypoint env MINER_KEY=mk-test ENGY_CACHE_SEED_WAIT_SECONDS=1 \
    ENGY_ENGINE_READY_TIMEOUT_SECONDS=3 ENGY_LIVENESS_INTERVAL_SECONDS=1 \
    ENGY_ENGINE_RESTART_GRACE_SECONDS=0
sleep 14
grep -q "port 8001 never became ready in .*restarting it" "${SANDBOX}/out.log" \
    && pass "a permanently unready engine is restarted, not abandoned" \
    || fail "never restarted; log tail: $(grep '\[engy\]' "${SANDBOX}/out.log" | tail -2 | tr '\n' ' ')"
grep -q "port 8000 ready" "${SANDBOX}/out.log" \
    && pass "and the healthy card kept mining throughout" || fail "the healthy card was disturbed"
kill -TERM "${ENTRYPOINT_PID}" 2>/dev/null; wait "${ENTRYPOINT_PID}" 2>/dev/null
rm -rf "${SANDBOX}"

echo "== the supervisor publishes what it has done =="
# A container that quietly restarts one engine an hour looks identical to a healthy one from
# outside, and on a miner's host nobody reads the log until something has already gone wrong.
new_sandbox 2
start_entrypoint env MINER_KEY=mk-test ENGY_CACHE_SEED_WAIT_SECONDS=1 ENGY_LIVENESS_INTERVAL_SECONDS=1
sleep 4
supervisor_file="${SANDBOX}/home/probe/supervisor.prom"
if [[ -f "${supervisor_file}" ]]; then
    pass "the supervisor writes its metrics file"
    grep -q "engy_supervisor_engine_restarts_total{engy_engine=\"8000\"}" "${supervisor_file}" \
        && pass "restart counters are labelled per engine" \
        || fail "no per-engine restart counter: $(head -20 "${supervisor_file}")"
    grep -q "engy_supervisor_heartbeat_timestamp_seconds [0-9]" "${supervisor_file}" \
        && pass "a heartbeat says the supervisor is still passing" \
        || fail "no heartbeat in the supervisor metrics"
    # Two engines must not produce two HELP lines for one family, or the whole scrape is invalid.
    help_line_count="$(grep -c "^# HELP engy_supervisor_engine_restarts_total" "${supervisor_file}")"
    [[ "${help_line_count}" -eq 1 ]] && pass "one HELP line per family" \
        || fail "${help_line_count} HELP lines for one family"
else
    fail "supervisor.prom was never written"
fi
kill -TERM "${ENTRYPOINT_PID}" 2>/dev/null
wait "${ENTRYPOINT_PID}" 2>/dev/null
rm -rf "${SANDBOX}"

echo "== stale probe files from a previous container are cleared =="
# The directory lives on the shared cache volume, so a node that comes back with fewer cards would
# otherwise keep publishing frozen lag series for GPUs it no longer has.
new_sandbox 1
mkdir -p "${SANDBOX}/home/probe"
echo "engy_miner_loop_lag_seconds_max{engy_worker=\"gone-g7\"} 99" >"${SANDBOX}/home/probe/loop-stale.prom"
run_entrypoint env MINER_KEY=mk-test ENGY_CACHE_SEED_WAIT_SECONDS=1
[[ -f "${SANDBOX}/home/probe/loop-stale.prom" ]] && fail "a stale probe file survived startup" \
    || pass "stale probe files are removed at startup"
rm -rf "${SANDBOX}"

echo "== the miner's stdout is kept on disk =="
# On a miner's host the container's stdout goes to a docker pipe we have no access to, so this file
# is the only record of why a routed request failed.
new_sandbox 1
run_entrypoint env MINER_KEY=mk-test ENGY_CACHE_SEED_WAIT_SECONDS=1
miner_log="${SANDBOX}/home/logs/miner.log"
if [[ -f "${miner_log}" ]] && grep -q "stub speaking on stdout" "${miner_log}"; then
    pass "miner output is tee'd to ${miner_log##*/}"
else
    fail "miner output not captured: $(ls "${SANDBOX}/home/logs" 2>&1)"
fi
# The entrypoint's own lines matter as much as the miner's: "engine never became ready" is the whole
# answer when an engine dies, and it is printed by this script, not by the miner.
grep -q "GPU(s) x .* engine(s)" "${miner_log}" 2>/dev/null \
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
sleep 1                       # same flush wait the first refusal case takes: tee writes the log
                              # through a process substitution, which outlives the exit on a busy box
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
grep -q "engy_launch.py" "${SANDBOX}/calls.log" 2>/dev/null \
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
