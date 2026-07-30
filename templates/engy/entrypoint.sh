#!/usr/bin/env bash
#
# Boot engy (Bittensor SN53) workers inside a Lium filler container.
#
# Shape: ONE sglang engine PER GPU (each --tp-size 1, its own port) and ONE engy_miner PER ENGINE.
# The reasoning behind every decision here, with the measurements, is in ARCHITECTURE.md next to
# this file — read that before changing anything below.
set -euo pipefail

ENGY_HOME="${ENGY_HOME:-/opt/engy}"
ENGY_MINER_DIR="${ENGY_MINER_DIR:-/opt/engy-miner}"

MINER_KEY="${MINER_KEY:-}"
GW="${GW:-wss://api.engy.ai/gw}"
MODEL="${MODEL:-qwen3.6-35b-a3b}"
CKPT_REPO="${ENGY_CKPT_REPO:-Qwen/Qwen3.6-35B-A3B-FP8}"
CKPT_REVISION="${ENGY_CKPT_REVISION:-95a723d08a9490559dae23d0cff1d9466213d989}"
CKPT_DIR="${ENGY_HOME}/models/${CKPT_REPO}"
# Per-engine concurrency, and also what ONE miner declares to the gateway as MAX_INFLIGHT.
# 8 is a FLOOR, not a preference: the miner derives its gateway connection count from this number
# (see _leg_plan), the gateway runs 8 workers, and a miner holding fewer than 8 connections is
# refused onboarding outright — "offered N distinct clean legs, below the required 8". Measured by
# running this image at 4: instant failure, zero traffic, ever.
# See ARCHITECTURE.md, "Why every miner declares exactly 8".
PER_ENGINE_REQUESTS="${ENGY_MAX_RUNNING_REQUESTS:-8}"
FIRST_PORT="${ENGY_FIRST_PORT:-8000}"
# The gateway's own model spec forces this; sglang refuses a shorter context for it.
CONTEXT_LENGTH="${ENGY_CONTEXT_LENGTH:-262144}"
# How often the supervisor checks its children, and how long an engine may hold requests without
# producing a token before it counts as wedged.
LIVENESS_INTERVAL_SECONDS="${ENGY_LIVENESS_INTERVAL_SECONDS:-60}"
ENGINE_STALL_SECONDS="${ENGY_ENGINE_STALL_SECONDS:-300}"
# After a kill, an engine reloads ~35GB of weights and re-JITs its kernels, and it answers /metrics
# with requests still attributed to it long before it generates again. Without this grace the
# supervisor reads that reload as a fresh wedge and kills the engine it is waiting for, forever.
# Borrowed from templates/dolphin's watchdog (DOLPHIN_WATCHDOG_GRACE_SECONDS).
ENGINE_RESTART_GRACE_SECONDS="${ENGY_ENGINE_RESTART_GRACE_SECONDS:-900}"
# A miner exiting means something is genuinely wrong (it has its own websocket reconnect loop), so
# back off before respawning rather than spinning against the gateway.
MINER_RESTART_BACKOFF_SECONDS="${ENGY_MINER_RESTART_BACKOFF_SECONDS:-60}"
# The container's output is the ONLY record of why a routed request failed, and on a miner's host it
# goes to a docker pipe we cannot reach.
LOG_FILE="${ENGY_HOME}/logs/miner.log"
LOG_MAX_BYTES="${ENGY_LOG_MAX_BYTES:-268435456}"   # 256MB, head-trimmed in place
# Each miner publishes its event-loop lag here and the sidecar merges the files into /metrics. This
# is how we tell OUR stall (GIL saturated by hidden-state parsing) from the gateway going quiet —
# both show up in the log as the same Close(1011, 'keepalive ping timeout').
PROBE_DIR="${ENGY_HOME}/probe"
# The trim keeps half the cap, so anything under 2 bytes would round to `tail -c 0` and wipe the log.
if (( LOG_MAX_BYTES < 8192 )); then LOG_MAX_BYTES=8192; fi

engine_pids=()
engine_ports=()
miner_pids=()
miner_names=()
trim_log_pid=""
sidecar_pid=""
log_pipe_pid=""
gpu_count=0

# Everything after this lands in the log: the engines, the miners and this script. Redirect BEFORE
# the first check — a container that refuses to start is exactly the one whose reason we cannot
# otherwise see. `stdbuf -oL` is load-bearing, not a nicety: ts block-buffers into a pipe and bash
# does not wait for a process substitution on exit, so an early exit used to drop the refusal
# entirely. Falling back to a bare tee when ts is absent keeps the whole output path off one
# optional binary.
start_capturing_output() {
    mkdir -p "${LOG_FILE%/*}"
    if command -v ts >/dev/null 2>&1; then
        exec > >(stdbuf -oL ts "%Y-%m-%dT%H:%M:%S%z" | tee -a "${LOG_FILE}") 2>&1
    else
        exec > >(tee -a "${LOG_FILE}") 2>&1
    fi
    log_pipe_pid=$!
}

# Refuse to start, with the reason guaranteed to be ON DISK. Anything still holding the log pipe
# keeps it from draining, so every child goes first; at the early call sites they are all empty and
# that loop is a no-op. Then closing our end lets the pipe reach EOF and we wait for it to flush.
refuse_to_start() {
    echo "[engy] $1" >&2
    local pid
    for pid in ${miner_pids[@]+"${miner_pids[@]}"} ${engine_pids[@]+"${engine_pids[@]}"} \
               "${trim_log_pid}" "${sidecar_pid}"; do
        [[ -n "${pid}" ]] && kill -TERM "${pid}" 2>/dev/null || true
    done
    exec 1>&- 2>&-
    wait "${log_pipe_pid}" 2>/dev/null || true
    exit 1
}

# SIGTERM is a DROP, not a drain. A customer rental stops the filler and must not wait: the platform
# allows FILLER_STOP_WAIT_TIMEOUT_SECONDS (30s) and draining 262k-context requests can exceed it.
# Killing the miners first closes their gateway websockets, so routing stops within ~1 min and only
# the in-flight requests are lost.
shutdown() {
    local pid
    for pid in ${miner_pids[@]+"${miner_pids[@]}"} "${trim_log_pid}" "${sidecar_pid}" \
               ${engine_pids[@]+"${engine_pids[@]}"}; do
        [[ -n "${pid}" ]] && kill -TERM "${pid}" 2>/dev/null || true
    done
    # Wait for the MINERS only, never a bare `wait`. The tee behind the exec redirect is a child too
    # and cannot see EOF while this script holds the pipe open, so a bare wait never returns under
    # bash 5 and the stop blows the platform's 30s budget.
    for pid in ${miner_pids[@]+"${miner_pids[@]}"}; do
        [[ -n "${pid}" ]] && wait "${pid}" 2>/dev/null || true
    done
    exit 0
}

# Backgrounded sleep + wait, the idiom templates/dolphin uses: a foreground sleep holds a TERM until
# the nap ends, leaving an orphaned sleep behind on every stop.
interruptible_sleep() {
    sleep "$1" &
    wait $! || true
}

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
    engine_pids[gpu_index]=$!
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

# One name per miner, and one id derived from it. The id is what engy's control plane keys a worker
# on, and the stock miner mints a fresh uuid4 per PROCESS — so every restart used to register a
# brand-new worker and throw away hours of onboarding progress. Deriving it from the name makes a
# restart a re-dial instead. See ARCHITECTURE.md, "Why worker ids are derived, not random".
miner_worker_name() {
    local index="$1"
    echo "${ENGY_WORKER_NAME:-$(hostname)}-g${index}"
}

miner_worker_id() {
    local name="$1"
    printf '%s' "${name}" | sha256sum | cut -c1-32
}

start_miner() {
    local index="$1" port=$((FIRST_PORT + $1)) name
    name="$(miner_worker_name "${index}")"
    miner_names[index]="${name}"
    GW="${GW}" MINER_KEY="${MINER_KEY}" MODEL="${MODEL}" \
    MAX_INFLIGHT="${PER_ENGINE_REQUESTS}" \
    ENGY_WORKER_NAME="${name}" \
    ENGY_WORKER_ID="$(miner_worker_id "${name}")" \
    ENGY_PROBE_DIR="${PROBE_DIR}" \
        python3 "${ENGY_MINER_DIR}/engy_miner.py" \
        --checkpoint "${CKPT_DIR}" \
        --serve-url "http://127.0.0.1:${port}" &
    miner_pids[index]=$!
}

# Token counters for the platform scraper, and the log. Started BEFORE the readiness wait: a cold
# start is a 35GB download plus warmup, and that whole window is when someone wants to see why the
# node is quiet. /metrics degrades to 503 meanwhile, which the sidecar already handles. Restarted
# with backoff like templates/dolphin, since a dead sidecar costs us the only remote read of this
# container. TERM kills the subshell and orphans its python; container teardown reaps it, because
# this script is PID 1.
start_metrics_sidecar() {
    [[ -n "${METRICS_TOKEN:-}" ]] || return 0
    local targets=""
    local port
    for port in "${engine_ports[@]}"; do
        targets+="${targets:+,}http://127.0.0.1:${port}"
    done
    (
        while true; do
            ENGY_METRICS_TARGETS="${targets}" ENGY_LOG_FILE="${LOG_FILE}" \
            ENGY_PROBE_DIR="${PROBE_DIR}" \
                python3 "${ENGY_MINER_DIR}/metrics_sidecar.py" || true
            sleep 5
        done
    ) &
    sidecar_pid=$!
}

# Head-trim the log in place rather than rotating it: `cat >` keeps the inode, so the tee holding the
# file open keeps writing to the same one. A rename would leave tee appending to an unlinked file.
trim_log_forever() {
    while true; do
        interruptible_sleep 300
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

engine_metric() {
    local port="$1" name="$2"
    curl -sf -m 5 "http://127.0.0.1:${port}/metrics" 2>/dev/null \
        | awk -v key="^sglang:${name}" '$0 ~ key { print $2; exit }'
}

# A wedged engine is the one failure nothing else notices: requests sit in flight, the process is
# alive, /health answers, and the token counter simply stops. Dolphin measured twelve of these on
# vLLM (1.6-23.5h each, invisible to every other check) and cures them the same way — kill the
# engine, not the container, because recreating the container costs a 35GB cold start for a fault a
# restart fixes in minutes.
#
# Deliberately NOT a fault here, both borrowed from templates/dolphin/watchdog.py: an engine that
# never came up (a cold start legitimately produces nothing for tens of minutes) and an idle queue
# (no demand is not a wedge, and arming the clock while idle would spend the budget before the first
# request even arrives).
engine_is_wedged() {
    local index="$1" port="${engine_ports[$1]}" running tokens now
    now="${SECONDS}"
    # Inside the grace after its own restart this engine is reloading, not wedged.
    if (( now < ${engine_kill_allowed_at[$index]:-0} )); then
        engine_stall_since[index]=0
        return 1
    fi
    running="$(engine_metric "${port}" "num_running_reqs")"
    tokens="$(engine_metric "${port}" "generation_tokens_total")"
    if [[ -z "${running}" || -z "${tokens}" ]]; then
        engine_stall_since[index]=0
        return 1
    fi
    if [[ "${running%%.*}" -eq 0 || "${tokens}" != "${engine_last_tokens[$index]:-}" ]]; then
        engine_last_tokens[index]="${tokens}"
        engine_stall_since[index]=0
        return 1
    fi
    if [[ "${engine_stall_since[$index]:-0}" -eq 0 ]]; then
        engine_stall_since[index]="${now}"
        return 1
    fi
    (( now - engine_stall_since[index] >= ENGINE_STALL_SECONDS ))
}

# SIGKILL, not SIGTERM: a process stuck inside a CUDA kernel ignores TERM (measured by dolphin in 12
# of 12 cases). The miner on this engine goes with it — it holds websockets advertising capacity the
# engine cannot serve, and the supervisor respawns both on the next pass.
restart_engine() {
    local index="$1"
    echo "[engy] engine on port ${engine_ports[$index]} produced no tokens for ${ENGINE_STALL_SECONDS}s with requests in flight — restarting it" >&2
    [[ -n "${miner_pids[$index]:-}" ]] && kill -TERM "${miner_pids[$index]}" 2>/dev/null || true
    kill -KILL "${engine_pids[$index]}" 2>/dev/null || true
    wait "${engine_pids[$index]}" 2>/dev/null || true
    miner_pids[index]=""
    engine_stall_since[index]=0
    engine_last_tokens[index]=""
    engine_restarts[index]=$(( ${engine_restarts[$index]:-0} + 1 ))
    engine_kill_allowed_at[index]=$(( SECONDS + ENGINE_RESTART_GRACE_SECONDS ))
    start_engine "${index}" "${engine_ports[$index]}"
}

# Publish what the supervisor has done, through the same file the miners' probes use — the sidecar
# already merges everything in PROBE_DIR into /metrics. Without this a container that quietly
# restarts one engine every hour is indistinguishable from a healthy one: the log says so, but on a
# miner's host nobody reads the log until something has already gone wrong. Shape borrowed from
# templates/dolphin, whose watchdog publishes dolphin_watchdog_restarts_total the same way.
write_supervisor_metrics() {
    local index body=""
    body+="# HELP engy_supervisor_heartbeat_timestamp_seconds When the supervisor last completed a pass.\n"
    body+="# TYPE engy_supervisor_heartbeat_timestamp_seconds gauge\n"
    body+="engy_supervisor_heartbeat_timestamp_seconds $(date +%s)\n"
    body+="# HELP engy_supervisor_pass_interval_seconds How often a pass is expected, so staleness is judgeable.\n"
    body+="# TYPE engy_supervisor_pass_interval_seconds gauge\n"
    body+="engy_supervisor_pass_interval_seconds ${LIVENESS_INTERVAL_SECONDS}\n"
    body+="# HELP engy_supervisor_engine_restarts_total Engines restarted in place since this container started.\n"
    body+="# TYPE engy_supervisor_engine_restarts_total counter\n"
    for index in "${!engine_ports[@]}"; do
        body+="engy_supervisor_engine_restarts_total{engy_engine=\"${engine_ports[$index]}\"} ${engine_restarts[$index]:-0}\n"
    done
    body+="# HELP engy_supervisor_miner_restarts_total Miners respawned since this container started.\n"
    body+="# TYPE engy_supervisor_miner_restarts_total counter\n"
    for index in "${!engine_ports[@]}"; do
        body+="engy_supervisor_miner_restarts_total{engy_engine=\"${engine_ports[$index]}\"} ${miner_restarts[$index]:-0}\n"
    done
    body+="# HELP engy_supervisor_miner_running Whether this engine currently has its miner attached.\n"
    body+="# TYPE engy_supervisor_miner_running gauge\n"
    for index in "${!engine_ports[@]}"; do
        body+="engy_supervisor_miner_running{engy_engine=\"${engine_ports[$index]}\"} $([[ -n "${miner_pids[$index]:-}" ]] && echo 1 || echo 0)\n"
    done
    # Atomic, and never fatal: metrics must not be able to stop the supervisor.
    { printf '%b' "${body}" > "${PROBE_DIR}/supervisor.prom.tmp" &&
        mv -f "${PROBE_DIR}/supervisor.prom.tmp" "${PROBE_DIR}/supervisor.prom"; } 2>/dev/null || true
}

# One dead engine costs one card, not the node: it is restarted in place and its miner comes back
# with it. The old shape exited the whole container, which threw away every other card's warm engine
# and, with derived worker ids now in play, is no longer the cheaper cure.
supervise_forever() {
    local index
    while true; do
        interruptible_sleep "${LIVENESS_INTERVAL_SECONDS}"
        for index in "${!engine_ports[@]}"; do
            if ! kill -0 "${engine_pids[$index]}" 2>/dev/null; then
                echo "[engy] engine on port ${engine_ports[$index]} exited — restarting it" >&2
                wait "${engine_pids[$index]}" 2>/dev/null || true
                [[ -n "${miner_pids[$index]:-}" ]] && kill -TERM "${miner_pids[$index]}" 2>/dev/null || true
                miner_pids[index]=""
                engine_restarts[index]=$(( ${engine_restarts[$index]:-0} + 1 ))
                engine_kill_allowed_at[index]=$(( SECONDS + ENGINE_RESTART_GRACE_SECONDS ))
                start_engine "${index}" "${engine_ports[$index]}"
                continue
            fi
            if engine_is_wedged "${index}"; then
                restart_engine "${index}"
                continue
            fi
            if [[ -z "${miner_pids[$index]:-}" ]]; then
                if curl -sf -m 5 "http://127.0.0.1:${engine_ports[$index]}/health_generate" >/dev/null 2>&1; then
                    echo "[engy] engine on port ${engine_ports[$index]} is generating again — starting its miner" >&2
                    start_miner "${index}"
                fi
                continue
            fi
            if ! kill -0 "${miner_pids[$index]}" 2>/dev/null; then
                wait "${miner_pids[$index]}" 2>/dev/null || true
                echo "[engy] miner ${miner_names[$index]} exited — respawning in ${MINER_RESTART_BACKOFF_SECONDS}s" >&2
                miner_pids[index]=""
                interruptible_sleep "${MINER_RESTART_BACKOFF_SECONDS}"
                miner_restarts[index]=$(( ${miner_restarts[$index]:-0} + 1 ))
                start_miner "${index}"
            fi
        done
        write_supervisor_metrics
    done
}

main() {
    start_capturing_output

    if [[ -z "${MINER_KEY}" ]]; then
        refuse_to_start "MINER_KEY is required (gateway key from provider.engy.ai)."
    fi

    gpu_count="$(nvidia-smi --query-gpu=index --format=csv,noheader | wc -l)"
    if [[ "${gpu_count}" -lt 1 ]]; then
        refuse_to_start "no GPUs visible to the container."
    fi
    echo "[engy] ${gpu_count} GPU(s) -> ${gpu_count} engine(s) x ${PER_ENGINE_REQUESTS} requests, one miner each"

    export PYTHONPATH="${ENGY_MINER_DIR}"   # loads sitecustomize.py, which trims returned hidden states
    export HF_HOME="${ENGY_HOME}/hf"

    mkdir -p "${CKPT_DIR}" "${HF_HOME}" "${PROBE_DIR}"
    # The probe dir sits on the shared cache volume, so a container that comes back with fewer cards
    # would keep publishing frozen lag series for GPUs it no longer has.
    rm -f "${PROBE_DIR}"/*.prom "${PROBE_DIR}"/*.prom.tmp
    if [[ ! -f "${CKPT_DIR}/config.json" ]]; then
        echo "[engy] pulling ${CKPT_REPO}@${CKPT_REVISION} (~35GB) into the shared cache volume"
        HF_HUB_ENABLE_HF_TRANSFER=1 hf download "${CKPT_REPO}" --revision "${CKPT_REVISION}" --local-dir "${CKPT_DIR}"
    fi

    trap shutdown TERM INT

    local index
    for index in $(seq 0 $((gpu_count - 1))); do
        engine_ports[index]=$((FIRST_PORT + index))
        engine_stall_since[index]=0
        engine_last_tokens[index]=""
        start_engine "${index}" "${engine_ports[$index]}"
    done

    start_metrics_sidecar

    for index in "${!engine_ports[@]}"; do
        if ! wait_for_engine "${engine_ports[$index]}"; then
            refuse_to_start "engine on port ${engine_ports[$index]} never became ready"
        fi
        echo "[engy] engine on port ${engine_ports[$index]} ready"
        start_miner "${index}"
    done

    trim_log_forever &
    trim_log_pid=$!

    supervise_forever
}

declare -a engine_stall_since=()
declare -a engine_restarts=()
declare -a miner_restarts=()
declare -a engine_kill_allowed_at=()
declare -a engine_last_tokens=()

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
