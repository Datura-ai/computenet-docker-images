#!/usr/bin/env bash
#
# Boot an engy (Bittensor SN53) worker inside a Lium filler container.
#
# Shape: ONE sglang engine PER GPU (each --tp-size 1, its own port), and ONE engy_miner driving all
# of them. Measured on 2xH100, 2026-07-27: per-card engines serve 564 tok/s against 329 tok/s for a
# single --tp-size 2 engine over the same cards — 1.72x, at better p99 TTFT. The miner stays single
# because engy's acceptance gate is per (miner, model): a second miner process would need its own
# registered hotkey, and one bad worker zeroes the whole key for the day.
set -euo pipefail

ENGY_HOME="${ENGY_HOME:-/opt/engy}"
ENGY_MINER_DIR="${ENGY_MINER_DIR:-/opt/engy-miner}"

MINER_KEY="${MINER_KEY:-}"
GW="${GW:-wss://api.engy.ai/gw}"
MODEL="${MODEL:-qwen3.6-35b-a3b}"
CKPT_REPO="${ENGY_CKPT_REPO:-Qwen/Qwen3.6-35B-A3B-FP8}"
CKPT_REVISION="${ENGY_CKPT_REVISION:-95a723d08a9490559dae23d0cff1d9466213d989}"
CKPT_DIR="${ENGY_HOME}/models/${CKPT_REPO}"
# Per-engine concurrency. MAX_INFLIGHT is declared to the gateway as the SUM across engines: it is
# the only capacity signal engy has, and routing share follows it. Under-declare and the gateway
# under-drives us; over-declare and requests queue past the 1800s deadline, get abandoned, and the
# acceptance gate zeroes the epoch.
PER_ENGINE_REQUESTS="${ENGY_MAX_RUNNING_REQUESTS:-8}"
FIRST_PORT="${ENGY_FIRST_PORT:-8000}"
# The gateway's own model spec forces this; sglang refuses a shorter context for it.
CONTEXT_LENGTH="${ENGY_CONTEXT_LENGTH:-262144}"
# The miner's own stdout is the ONLY place that says why a routed request failed, and on a miner's
# host it goes to a docker pipe we cannot reach. Keep a copy on disk so the log survives to be read
# over SSH or pulled from the sidecar's /logs.
LOG_FILE="${ENGY_HOME}/logs/miner.log"
LOG_MAX_BYTES="${ENGY_LOG_MAX_BYTES:-268435456}"   # 256MB, head-trimmed in place

if [[ -z "${MINER_KEY}" ]]; then
    echo "[engy] MINER_KEY is required (gateway key from provider.engy.ai)." >&2
    exit 1
fi

gpu_count="$(nvidia-smi --query-gpu=index --format=csv,noheader | wc -l)"
if [[ "${gpu_count}" -lt 1 ]]; then
    echo "[engy] no GPUs visible to the container." >&2
    exit 1
fi
echo "[engy] ${gpu_count} GPU(s) -> ${gpu_count} engine(s), ${PER_ENGINE_REQUESTS} running requests each"

export PYTHONPATH="${ENGY_MINER_DIR}"   # loads sitecustomize.py, which trims returned hidden states
export HF_HOME="${ENGY_HOME}/hf"

mkdir -p "${CKPT_DIR}" "${HF_HOME}" "${LOG_FILE%/*}"
if [[ ! -f "${CKPT_DIR}/config.json" ]]; then
    echo "[engy] pulling ${CKPT_REPO}@${CKPT_REVISION} (~35GB) into the shared cache volume"
    HF_HUB_ENABLE_HF_TRANSFER=1 hf download "${CKPT_REPO}" --revision "${CKPT_REVISION}" --local-dir "${CKPT_DIR}"
fi

serve_pids=()
miner_pid=""
trim_log_pid=""
sidecar_pid=""

# SIGTERM is a DROP, not a drain. A customer rental stops the filler and must not wait: the platform
# only allows FILLER_STOP_WAIT_TIMEOUT_SECONDS (30s) and a real drain of 262k-context requests can
# exceed it. Killing the miner first closes the gateway websocket, so routing stops within ~1 min and
# only the in-flight requests are lost — bounded by MAX_INFLIGHT, and the error budget is 1% of the
# day's requests. Losing the epoch to a slow stop would cost far more.
shutdown() {
    # EVERY long-lived child has to die before the bare wait below, or the container never finishes
    # stopping and blows the platform's 30s filler-stop budget. The trimmer and the sidecar both loop
    # forever, so neither ends on its own. Miner first: closing the gateway websocket stops routing.
    for pid in "${miner_pid}" "${trim_log_pid}" "${sidecar_pid}" "${serve_pids[@]:-}"; do
        [[ -n "${pid}" ]] && kill -TERM "${pid}" 2>/dev/null || true
    done
    wait 2>/dev/null || true
    exit 0
}
trap shutdown TERM INT

start_engine() {
    local gpu_index="$1" port="$2"
    CUDA_VISIBLE_DEVICES="${gpu_index}" python3 -m sglang.launch_server \
        --model-path "${CKPT_DIR}" \
        --served-model-name Qwen3.6 --tp-size 1 --trust-remote-code \
        --kv-cache-dtype fp8_e4m3 --mem-fraction-static 0.85 \
        --chunked-prefill-size 8192 --max-running-requests "${PER_ENGINE_REQUESTS}" \
        --context-length "${CONTEXT_LENGTH}" --enable-return-hidden-states --enable-cache-report \
        --enable-metrics \
        --host 127.0.0.1 --port "${port}" &
    serve_pids+=("$!")
}

# /health_generate, not /health: it answers only once the engine can actually GENERATE. A miner
# connected to a loaded-but-not-generating serve is how you fail the acceptance gate.
wait_for_engine() {
    local port="$1" deadline=$((SECONDS + 2400))
    while [[ ${SECONDS} -lt ${deadline} ]]; do
        if curl -sf "http://127.0.0.1:${port}/health_generate" >/dev/null 2>&1; then
            return 0
        fi
        sleep 10
    done
    return 1
}

serve_urls=()
for gpu_index in $(seq 0 $((gpu_count - 1))); do
    port=$((FIRST_PORT + gpu_index))
    start_engine "${gpu_index}" "${port}"
    serve_urls+=("http://127.0.0.1:${port}")
done

for gpu_index in $(seq 0 $((gpu_count - 1))); do
    port=$((FIRST_PORT + gpu_index))
    if ! wait_for_engine "${port}"; then
        echo "[engy] engine on port ${port} never became ready" >&2
        exit 1
    fi
    echo "[engy] engine on port ${port} ready"
done

# Token counters for the platform scraper. Every engine is scraped, not just the first — on a
# multi-card node the per-engine series is what shows one card gone quiet.
if [[ -n "${METRICS_TOKEN:-}" ]]; then
    ENGY_METRICS_TARGETS="$(IFS=,; echo "${serve_urls[*]}")" \
    ENGY_LOG_FILE="${LOG_FILE}" \
        python3 "${ENGY_MINER_DIR}/metrics_sidecar.py" &
    sidecar_pid=$!
fi

# Head-trim the log in place rather than rotating it: `cat >` keeps the inode, so the tee holding the
# file open keeps writing to the same one. A rename would leave tee appending to an unlinked file.
trim_log() {
    while true; do
        sleep 300
        local size
        # wc -c, not stat -c: stat's flags differ between GNU and BSD, and a silent failure here
        # would mean the trim never runs.
        size="$(wc -c < "${LOG_FILE}" 2>/dev/null || echo 0)"
        if [[ "${size}" -gt "${LOG_MAX_BYTES}" ]]; then
            # `|| true` because set -e would otherwise end this background loop for good on a single
            # failed trim, and the log would then grow unbounded with nothing saying why.
            { tail -c "$((LOG_MAX_BYTES / 2))" "${LOG_FILE}" > "${LOG_FILE}.trim" &&
                cat "${LOG_FILE}.trim" > "${LOG_FILE}" && rm -f "${LOG_FILE}.trim"; } || true
        fi
    done
}
trim_log &
trim_log_pid=$!

# The miner is supervised, the engines are not restarted — but a miner restart is NOT free:
# WORKER_ID is uuid4() PER PROCESS (engy_miner.py:278), so every relaunch of the miner is a brand-new
# worker to the gateway and goes to the BACK of the qualification queue (hours to a day, measured).
# The miner has its own reconnect loop for dropped websockets, so it exiting at all means something
# is genuinely wrong; the 60s backoff keeps a crash-loop from spamming the gateway with fresh
# worker_ids. A dead engine still ends the container — that decision belongs to the platform.
MINER_RESTART_BACKOFF_SECONDS=60
while true; do
    for url in "${serve_urls[@]}"; do
        if ! curl -sf "${url}/health_generate" >/dev/null 2>&1; then
            echo "[engy] engine ${url} stopped generating — exiting so the platform relaunches" >&2
            shutdown
        fi
    done

    GW="${GW}" MINER_KEY="${MINER_KEY}" MODEL="${MODEL}" \
    MAX_INFLIGHT="$((PER_ENGINE_REQUESTS * gpu_count))" \
    ENGY_WORKER_NAME="${ENGY_WORKER_NAME:-$(hostname)}" \
        python3 "${ENGY_MINER_DIR}/engy_miner.py" \
        --checkpoint "${CKPT_DIR}" \
        --serve-url "$(IFS=,; echo "${serve_urls[*]}")" \
        > >(tee -a "${LOG_FILE}") 2>&1 &
    # Process substitution rather than a `| tee` pipeline: in a pipeline $! is the tee, and shutdown
    # would then TERM the tee while the miner stayed connected to the gateway.
    miner_pid=$!
    wait "${miner_pid}" || true
    echo "[engy] miner exited — restarting as a NEW worker (back of the qualification queue) in ${MINER_RESTART_BACKOFF_SECONDS}s" >&2
    sleep "${MINER_RESTART_BACKOFF_SECONDS}"
done
