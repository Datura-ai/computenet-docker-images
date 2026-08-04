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
GATEWAY_REQUIRED_INFLIGHT=8
PER_ENGINE_REQUESTS="${ENGY_MAX_RUNNING_REQUESTS:-${GATEWAY_REQUIRED_INFLIGHT}}"
# Checked as text before any arithmetic: under `set -u` a non-numeric value makes (( )) treat it as
# an unset variable NAME and kill the script here, before the log capture that would explain why.
if [[ ! "${PER_ENGINE_REQUESTS}" =~ ^[0-9]+$ ]]; then
    echo "[engy] ENGY_MAX_RUNNING_REQUESTS='${PER_ENGINE_REQUESTS}' is not a number;" \
         "using ${GATEWAY_REQUIRED_INFLIGHT}." >&2
    PER_ENGINE_REQUESTS="${GATEWAY_REQUIRED_INFLIGHT}"
fi
if (( PER_ENGINE_REQUESTS < GATEWAY_REQUIRED_INFLIGHT )); then
    echo "[engy] ENGY_MAX_RUNNING_REQUESTS=${PER_ENGINE_REQUESTS} is below the gateway's floor;" \
         "using ${GATEWAY_REQUIRED_INFLIGHT} instead — a lower value earns nothing at all." >&2
    PER_ENGINE_REQUESTS="${GATEWAY_REQUIRED_INFLIGHT}"
fi
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
# How long a cold start may take before an engine is left to the supervisor instead of held for.
# A 35GB load plus ~16k JIT-compiled FP8 kernels is 10-20 minutes on an empty cache.
ENGINE_READY_TIMEOUT_SECONDS="${ENGY_ENGINE_READY_TIMEOUT_SECONDS:-2400}"
# How long the first engine gets to seed the shared DeepGEMM cache before the rest are started.
# See start_engines_seeding_the_kernel_cache_first.
CACHE_SEED_WAIT_SECONDS="${ENGY_CACHE_SEED_WAIT_SECONDS:-1500}"
# A miner exiting means something is genuinely wrong (it has its own websocket reconnect loop), so
# back off before respawning rather than spinning against the gateway.
MINER_RESTART_BACKOFF_SECONDS="${ENGY_MINER_RESTART_BACKOFF_SECONDS:-60}"
# How long engines and miners get to act on TERM during a refusal before they are killed outright.
REFUSAL_KILL_GRACE_SECONDS="${ENGY_REFUSAL_KILL_GRACE_SECONDS:-10}"
# Where the miner is refreshed from on every boot, and the switch to stop doing that. Upstream tags
# lag their own default branch badly (the newest release was v0.4.1 while tags were at v0.4.4), so
# the branch is the honest source of "current".
ENGY_MINER_SOURCE_URL="${ENGY_MINER_SOURCE_URL:-https://raw.githubusercontent.com/hanlinai/engy/main/miner/engy_miner.py}"
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
mining_engines=0

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
    local children=(${miner_pids[@]+"${miner_pids[@]}"} ${engine_pids[@]+"${engine_pids[@]}"})
    local pid
    for pid in ${children[@]+"${children[@]}"}; do
        [[ -n "${pid}" ]] && kill -TERM "${pid}" 2>/dev/null || true
    done
    terminate_supervised_loop "${trim_log_pid}"
    terminate_supervised_loop "${sidecar_pid}"
    # Everything above is a request; this is not. An engine wedged in a driver call never acts on
    # TERM, and whether a signalled subshell dies before or after its child is bash semantics we
    # would rather not depend on — either way something can still hold the log pipe and the wait
    # below would never return, hanging the container instead of refusing loudly.
    if (( ${#children[@]} > 0 )); then
        sleep "${REFUSAL_KILL_GRACE_SECONDS}"
        for pid in "${children[@]}"; do
            [[ -n "${pid}" ]] && kill -KILL "${pid}" 2>/dev/null || true
        done
    fi
    kill_supervised_loop_hard "${trim_log_pid}"
    kill_supervised_loop_hard "${sidecar_pid}"
    exec 1>&- 2>&-
    wait "${log_pipe_pid}" 2>/dev/null || true
    exit 1
}

# Start a supervised loop in a session of its own and echo its pid, which `setsid` also makes the
# process-GROUP id. That group is the only reliable handle on it: the loop's child is reparented to
# PID 1 the moment the loop dies, and `pkill -P <loop>` then finds nothing. Measured on the H100 test
# node — the sidecar's python survived TERM and KILL, kept the log pipe open, and a refusal that had
# already printed its reason hung for 400s instead of exiting.
# The pid lands in started_loop_pid rather than on stdout: a $(…) around a background job never
# returns, because the job inherits the substitution's pipe and holds it open for its whole life.
start_supervised_loop() {
    local loop_function="$1"
    export -f "${loop_function}" interruptible_sleep
    export LOG_FILE ENGY_MINER_DIR PROBE_DIR ENGY_LOG_MAX_BYTES
    # Without setsid the loop shares our process group and signalling the group would hit the whole
    # container, so that case falls back to the parent/child handles the kill helpers also accept.
    if command -v setsid >/dev/null 2>&1; then
        setsid bash -c "${loop_function}" &
    else
        bash -c "${loop_function}" &
    fi
    started_loop_pid=$!
}

# Kill a supervised background loop AND the child it is currently running.
#
# The sidecar and the log trimmer are subshells; TERM to the subshell leaves its python/`tail`
# grandchild alive, and that grandchild still holds the log pipe open. `refuse_to_start` then waits
# for the pipe to drain and never returns: a container that was supposed to refuse loudly hangs
# forever instead, and the platform sees it as running. Reproduced on bare bash.
#
# The loop is signalled BEFORE its child: bash defers a TERM taken while it waits on a foreground
# child until that child exits, so the loop dies instead of starting one more iteration. Killing the
# child first leaves a window in which the loop spawns a fresh pipe holder and the hang comes back.
# Neither race reproduced in 20 trials on bare bash, which is exactly why `refuse_to_start` does not
# rely on this ordering being right and follows up with kill_supervised_loop_hard.
terminate_supervised_loop() {
    local pid="$1"
    [[ -n "${pid}" ]] || return 0
    kill -TERM -"${pid}" 2>/dev/null || kill -TERM "${pid}" 2>/dev/null || true
    pkill -TERM -P "${pid}" 2>/dev/null || true
}

# The same pair with KILL, for when the container is going down anyway and nothing may be left
# holding the log pipe. The loop dies first so it cannot answer its child's death with a new one.
kill_supervised_loop_hard() {
    local pid="$1"
    [[ -n "${pid}" ]] || return 0
    kill -KILL -"${pid}" 2>/dev/null || kill -KILL "${pid}" 2>/dev/null || true
    pkill -KILL -P "${pid}" 2>/dev/null || true
}

# SIGTERM is a DROP, not a drain. A customer rental stops the filler and must not wait: the platform
# allows FILLER_STOP_WAIT_TIMEOUT_SECONDS (30s) and draining 262k-context requests can exceed it.
# Killing the miners first closes their gateway websockets, so routing stops within ~1 min and only
# the in-flight requests are lost.
shutdown() {
    local pid
    for pid in ${miner_pids[@]+"${miner_pids[@]}"} ${engine_pids[@]+"${engine_pids[@]}"}; do
        [[ -n "${pid}" ]] && kill -TERM "${pid}" 2>/dev/null || true
    done
    terminate_supervised_loop "${trim_log_pid}"
    terminate_supervised_loop "${sidecar_pid}"
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
    # Every start earns the reload grace, first one included: a cold start JITs ~16k FP8 kernels and
    # is the longest window in which a healthy engine looks wedged.
    engine_kill_allowed_at[gpu_index]=$(( SECONDS + ENGINE_RESTART_GRACE_SECONDS ))
    engine_started_at[gpu_index]="${SECONDS}"
}

# Start engine 0 alone, let it fill the shared kernel cache, then release the rest.
#
# sglang JIT-compiles ~16k FP8 DeepGEMM kernels on a cold engine, 10-20 minutes, into
# DG_JIT_CACHE_DIR — which lives on the shared volume precisely so it is paid once. Started
# together, all N engines compile the same kernels at the same time into the same directory: N times
# the CPU for one cache, and N writers racing over the same files. Started one behind the seed, the
# rest find the cache warm. Borrowed from templates/dolphin (wait_for_cache_seed + its stagger).
#
# The wait is capped and never fatal: an engine that dies during seeding must not hold the node
# hostage, so when the budget runs out the siblings start anyway and pay their own compile.
start_engines_seeding_the_kernel_cache_first() {
    local index waited=0
    for index in $(seq 0 $((gpu_count - 1))); do
        engine_ports[index]=$((FIRST_PORT + index))
        start_engine "${index}" "${engine_ports[$index]}"
        if (( index == 0 && gpu_count > 1 )); then
            echo "[engy] engine on port ${engine_ports[0]} is seeding the shared kernel cache; the other $((gpu_count - 1)) wait up to ${CACHE_SEED_WAIT_SECONDS}s"
            while (( waited < CACHE_SEED_WAIT_SECONDS )) && ! engine_is_generating "${engine_ports[0]}"; do
                # A dead seed will never warm anything, and holding the other cards for the rest of
                # the budget is pure lost mining. The supervisor restarts it either way.
                if ! kill -0 "${engine_pids[0]}" 2>/dev/null; then
                    echo "[engy] the seeding engine exited after ${waited}s; starting the rest now" >&2
                    break
                fi
                interruptible_sleep 10
                waited=$((waited + 10))
            done
            if engine_is_generating "${engine_ports[0]}"; then
                echo "[engy] kernel cache seeded after ${waited}s; starting the remaining engines warm"
            elif kill -0 "${engine_pids[0]}" 2>/dev/null; then
                echo "[engy] cache not seeded after ${waited}s; starting the remaining engines anyway" >&2
            fi
        fi
    done
}

# /health_generate, not /health: it answers only once the engine can actually GENERATE. A miner
# connected to a loaded-but-not-generating serve is how you fail the acceptance gate.
engine_is_generating() {
    curl -sf -m 5 "http://127.0.0.1:$1/health_generate" >/dev/null 2>&1
}

# Give each engine its miner the moment THAT engine can generate, and return how many got one.
#
# Polled in rounds against one shared deadline rather than waiting on each engine in turn: a card
# that never comes up would otherwise hold the whole deadline before the next card is even looked
# at, so one sick GPU delayed seven healthy ones by the full timeout. Cards also warm at different
# speeds, and there is no reason a fast one should wait for a slow one.
start_miners_as_engines_become_ready() {
    local deadline=$((SECONDS + ENGINE_READY_TIMEOUT_SECONDS)) index
    mining_engines=0
    while true; do
        for index in "${!engine_ports[@]}"; do
            [[ -n "${miner_pids[$index]:-}" ]] && continue
            if engine_is_generating "${engine_ports[$index]}"; then
                echo "[engy] engine on port ${engine_ports[$index]} ready"
                start_miner "${index}"
                mining_engines=$((mining_engines + 1))
            fi
        done
        (( mining_engines == ${#engine_ports[@]} )) && break
        (( SECONDS >= deadline )) && break
        interruptible_sleep 10
    done
    for index in "${!engine_ports[@]}"; do
        if [[ -z "${miner_pids[$index]:-}" ]]; then
            echo "[engy] engine on port ${engine_ports[$index]} never became ready — leaving it to the supervisor" >&2
        fi
    done
}

# One name per miner. The worker ID is deliberately NOT pinned to it — see ARCHITECTURE.md,
# "Why worker ids are random again".
miner_worker_name() {
    local index="$1"
    echo "${ENGY_WORKER_NAME:-$(hostname)}-g${index}"
}

# The hardware summary a miner sends the gateway comes from `nvidia-smi`, which lists the whole node
# and ignores CUDA_VISIBLE_DEVICES. Every miner here fronts ONE engine on ONE card, so without this
# all eight of ours announce the node's eight cards each. HW_GPUS is upstream's own override for it.
one_gpu_name() {
    local name
    name="$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1 | sed 's/^ *//;s/ *$//')"
    echo "${name:-GPU}"
}

start_miner() {
    local index="$1" port="${engine_ports[$1]}" name
    name="$(miner_worker_name "${index}")"
    miner_names[index]="${name}"
    GW="${GW}" MINER_KEY="${MINER_KEY}" MODEL="${MODEL}" \
    MAX_INFLIGHT="${PER_ENGINE_REQUESTS}" \
    HW_GPUS="1x $(one_gpu_name)" \
    ENGY_WORKER_NAME="${name}" \
    ENGY_PROBE_DIR="${PROBE_DIR}" \
        python3 "${ENGY_MINER_DIR}/engy_launch.py" \
        --checkpoint "${CKPT_DIR}" \
        --serve-url "http://127.0.0.1:${port}" &
    miner_pids[index]=$!
}

# Pull the newest upstream miner before anything starts. The vendored copy in the image is a
# byte-identical fallback, never a patch target: Lium's modifications live in engy_launch.py, which
# applies them from outside, so a refresh cannot silently drop them.
#
# Deliberately fail-soft. A miner that runs a week-old upstream still earns; a miner that refuses to
# boot because GitHub was unreachable earns nothing. Anything that fails validation is discarded and
# the baked-in copy stays.
# The hooks engy_launch.py assigns after import. Kept next to the validator on purpose: adding a
# modification there means adding its hook here, or a refresh can hand us an upstream we cannot
# modify and every miner runs with no per-worker lock and no probe — seven of eight cards unmined.
REQUIRED_MINER_HOOKS=("^def _worker_name" "^WORKER_NAME" "^async def _serve_all" "^def main" "^_JOBS" "^HW")

# Empty when the staged file is usable; otherwise the reason it is not.
why_staged_miner_is_unusable() {
    local staged="$1" hook
    for hook in "${REQUIRED_MINER_HOOKS[@]}"; do
        if ! grep -qE "${hook}" "${staged}" 2>/dev/null; then
            echo "it is missing '${hook}', so Lium's modifications would not apply"
            return 0
        fi
    done
    # PYTHONPATH is cleared and stdout dropped: by this point PYTHONPATH points at our own dir, and
    # importing sitecustomize.py prints an "armed" banner on stdout that this function's caller reads
    # as a rejection reason. That silently discarded EVERY valid refresh in the image.
    if ! PYTHONPATH= python3 -m py_compile "${staged}" >/dev/null 2>&1; then
        echo "it does not compile"
    fi
}

refresh_vendored_miner() {
    if [[ "${ENGY_MINER_AUTO_UPDATE:-1}" != "1" ]]; then
        echo "[engy] miner auto-update disabled; using the copy baked into the image"
        return 0
    fi
    local staged="${ENGY_MINER_DIR}/engy_miner.py.new" reason
    if ! curl -sfL -m 60 "${ENGY_MINER_SOURCE_URL}" -o "${staged}"; then
        echo "[engy] could not fetch the upstream miner; keeping the image's copy" >&2
        rm -f "${staged}"
        return 0
    fi
    reason="$(why_staged_miner_is_unusable "${staged}")"
    if [[ -n "${reason}" ]]; then
        echo "[engy] discarding the fetched miner: ${reason}; keeping the image's copy" >&2
        rm -f "${staged}"
        return 0
    fi
    mv -f "${staged}" "${ENGY_MINER_DIR}/engy_miner.py"
    echo "[engy] miner refreshed from ${ENGY_MINER_SOURCE_URL} ($(wc -l < "${ENGY_MINER_DIR}/engy_miner.py") lines)"
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
    export ENGY_METRICS_TARGETS="${targets}" ENGY_LOG_FILE="${LOG_FILE}" ENGY_PROBE_DIR="${PROBE_DIR}"
    start_supervised_loop run_metrics_sidecar_forever
    sidecar_pid="${started_loop_pid}"
}

run_metrics_sidecar_forever() {
    while true; do
        python3 "${ENGY_MINER_DIR}/metrics_sidecar.py" || true
        sleep 5
    done
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

# "<running> <tokens>", or empty when the engine did not answer. One scrape per pass, not one per
# counter: an sglang exposition is 65 metric families, and an 8-card node was pulling 16 of them a
# minute to read two numbers.
engine_running_and_tokens() {
    local port="$1"
    curl -sf -m 5 "http://127.0.0.1:${port}/metrics" 2>/dev/null | awk '
        /^sglang:num_running_reqs/ { running = $2 }
        /^sglang:generation_tokens_total/ { tokens = $2 }
        END { if (running != "" && tokens != "") print running, tokens }'
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
    local index="$1" port="${engine_ports[$1]}" counters running tokens now
    now="${SECONDS}"
    # Inside the grace after its own restart this engine is reloading, not wedged.
    if (( now < ${engine_kill_allowed_at[$index]:-0} )); then
        engine_stall_since[index]=0
        return 1
    fi
    counters="$(engine_running_and_tokens "${port}")"
    read -r running tokens <<<"${counters}"
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
# The only way an engine is restarted, whether it wedged or exited on its own. Both used to have
# their own copy and they drifted: the exited path forgot to reset the stall state, so the new
# engine inherited the dead one's clock.
restart_engine() {
    local index="$1" reason="$2"
    echo "[engy] engine on port ${engine_ports[$index]} ${reason} — restarting it" >&2
    [[ -n "${miner_pids[$index]:-}" ]] && kill -TERM "${miner_pids[$index]}" 2>/dev/null || true
    kill -KILL "${engine_pids[$index]}" 2>/dev/null || true
    wait "${engine_pids[$index]}" 2>/dev/null || true
    miner_pids[index]=""
    engine_stall_since[index]=0
    engine_last_tokens[index]=""
    engine_restarts[index]=$(( ${engine_restarts[$index]:-0} + 1 ))
    start_engine "${index}" "${engine_ports[$index]}"
}

# Publish what the supervisor has done, through the same file the miners' probes use — the sidecar
# already merges everything in PROBE_DIR into /metrics. Without this a container that quietly
# restarts one engine every hour is indistinguishable from a healthy one: the log says so, but on a
# miner's host nobody reads the log until something has already gone wrong. Shape borrowed from
# templates/dolphin, whose watchdog publishes dolphin_watchdog_restarts_total the same way.
write_supervisor_metrics() {
    local index staged="${PROBE_DIR}/supervisor.prom.tmp"
    # Atomic, and never fatal: metrics must not be able to stop the supervisor.
    {
        echo "# HELP engy_supervisor_heartbeat_timestamp_seconds When the supervisor last completed a pass."
        echo "# TYPE engy_supervisor_heartbeat_timestamp_seconds gauge"
        echo "engy_supervisor_heartbeat_timestamp_seconds $(date +%s)"
        echo "# HELP engy_supervisor_pass_interval_seconds How often a pass is expected, so staleness is judgeable."
        echo "# TYPE engy_supervisor_pass_interval_seconds gauge"
        echo "engy_supervisor_pass_interval_seconds ${LIVENESS_INTERVAL_SECONDS}"
        echo "# HELP engy_supervisor_engine_restarts_total Engines restarted in place since this container started."
        echo "# TYPE engy_supervisor_engine_restarts_total counter"
        for index in "${!engine_ports[@]}"; do
            echo "engy_supervisor_engine_restarts_total{engy_engine=\"${engine_ports[$index]}\"} ${engine_restarts[$index]:-0}"
        done
        echo "# HELP engy_supervisor_miner_restarts_total Miners respawned since this container started."
        echo "# TYPE engy_supervisor_miner_restarts_total counter"
        for index in "${!engine_ports[@]}"; do
            echo "engy_supervisor_miner_restarts_total{engy_engine=\"${engine_ports[$index]}\"} ${miner_restarts[$index]:-0}"
        done
        echo "# HELP engy_supervisor_miner_running Whether this engine currently has its miner attached."
        echo "# TYPE engy_supervisor_miner_running gauge"
        for index in "${!engine_ports[@]}"; do
            echo "engy_supervisor_miner_running{engy_engine=\"${engine_ports[$index]}\"} $([[ -n "${miner_pids[$index]:-}" ]] && echo 1 || echo 0)"
        done
    } > "${staged}" 2>/dev/null && mv -f "${staged}" "${PROBE_DIR}/supervisor.prom" 2>/dev/null || true
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
                restart_engine "${index}" "exited"
                continue
            fi
            if engine_is_wedged "${index}"; then
                restart_engine "${index}" \
                    "produced no tokens for ${ENGINE_STALL_SECONDS}s with requests in flight"
                continue
            fi
            if [[ -z "${miner_pids[$index]:-}" ]]; then
                if (( SECONDS < ${miner_restart_allowed_at[$index]:-0} )); then
                    continue                     # still inside this miner's respawn backoff
                fi
                if engine_is_generating "${engine_ports[$index]}"; then
                    echo "[engy] engine on port ${engine_ports[$index]} is generating again — starting its miner" >&2
                    start_miner "${index}"
                elif (( SECONDS - ${engine_started_at[$index]:-0} >= ENGINE_READY_TIMEOUT_SECONDS )); then
                    # An engine that is alive but has never served is not "wedged" by the token test
                    # (it has no requests, so the stall clock never arms) and would otherwise sit
                    # here forever — one card silently idle for the life of the container.
                    restart_engine "${index}" \
                        "never became ready in ${ENGINE_READY_TIMEOUT_SECONDS}s"
                fi
                continue
            fi
            if ! kill -0 "${miner_pids[$index]}" 2>/dev/null; then
                wait "${miner_pids[$index]}" 2>/dev/null || true
                echo "[engy] miner ${miner_names[$index]} exited — respawning in ${MINER_RESTART_BACKOFF_SECONDS}s" >&2
                miner_pids[index]=""
                # Deadline, not a sleep: sleeping here stalls the whole pass, so one crash-looping
                # miner would delay wedge detection on every other card and freeze the heartbeat
                # the ETL charts.
                miner_restart_allowed_at[index]=$(( SECONDS + MINER_RESTART_BACKOFF_SECONDS ))
                miner_restarts[index]=$(( ${miner_restarts[$index]:-0} + 1 ))
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

    # `|| true` is load-bearing: grep -c exits 1 on empty input, and under set -e that would kill
    # the script at this assignment — before refuse_to_start could put the reason on disk. A node
    # with no GPUs would then die with a completely empty log, which is the one outcome the whole
    # log-capture machinery exists to prevent. (wc -l never failed, but padded its output.)
    gpu_count="$(nvidia-smi --query-gpu=index --format=csv,noheader | grep -c . || true)"
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
    start_engines_seeding_the_kernel_cache_first

    start_metrics_sidecar
    # After the engines are spawned, not before: the miner is not needed until they are ready, and a
    # slow GitHub would otherwise add a minute of dead time to every cold start.
    refresh_vendored_miner

    # One card that never comes up costs one card. This used to end the container, which was right
    # when a single miner fronted every engine — losing one engine lost the worker anyway. With a
    # miner per engine the healthy cards keep earning, and the supervisor retries the sick one for as
    # long as the container lives. Only a node where NOTHING came up is worth refusing.
    start_miners_as_engines_become_ready
    if (( mining_engines == 0 )); then
        refuse_to_start "no engine became ready on any of the ${gpu_count} GPU(s)."
    fi
    echo "[engy] ${mining_engines} of ${gpu_count} engine(s) mining"

    start_supervised_loop trim_log_forever
    trim_log_pid="${started_loop_pid}"

    supervise_forever
}

declare -a engine_stall_since=()
declare -a engine_started_at=()
declare -a miner_restart_allowed_at=()
declare -a engine_restarts=()
declare -a miner_restarts=()
declare -a engine_kill_allowed_at=()
declare -a engine_last_tokens=()

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
