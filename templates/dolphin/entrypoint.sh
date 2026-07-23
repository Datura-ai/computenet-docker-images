#!/usr/bin/env bash
#
# Boot Dolphin (dphn.ai) v2 inference worker(s) inside a Lium pod: render worker.json from env,
# ensure the binary is present, then supervise `dolphinpod-worker update && start` in a restart
# loop so workers can self-update while the container keeps running.
#
# DAH-2465: on multi-GPU nodes one worker is spawned per minimal VRAM bundle (the smallest card
# group that fits the model) instead of one tensor-sharded worker over every GPU. Every worker
# instance loads the FULL model, so sharding one worker across many cards wastes VRAM that would
# otherwise be KV cache: measured on prod, an 8x RTX PRO 6000 single worker reports 317 slots at
# ~13% VRAM/GPU while a 1x worker on the same card reports 72 slots at ~70%. Slots bound the
# concurrent batch and Dolphin pays per processed token, so more workers recover the lost
# concurrency. 96 GB cards get a worker per GPU, 48 GB cards one per pair, and so on; nodes that
# cannot form 2+ bundles keep the single all-GPUs worker (exact pre-split behavior).
#
# What multi-instance costs, and how each cost is paid here:
#   - config collision   -> per-instance HOME, so each worker reads its own worker.json
#   - N copies of 35 GB  -> per-instance HOME/.cache is a SYMLINK to the shared cache, so the
#                           weights land in one place no matter how the closed worker binary
#                           treats HF_HOME/XDG_CACHE_HOME (it scrubs its child's env)
#   - binary corruption  -> every write to the shared DOLPHIN_HOME goes through flock, staged
#                           into a temp file and renamed atomically (DAH-2475)
#   - metrics undercount -> the sidecar scrapes EVERY engine socket and tags each with its own
#                           dolphin_engine label; DOLPHIN_ENGINES_EXPECTED lets it report a
#                           dead engine as a gap instead of as a smaller token count
set -euo pipefail

DOLPHIN_HOME="${DOLPHIN_HOME:-/opt/dolphinpod}"
WORKER_BIN="${DOLPHIN_HOME}/dolphinpod-worker"

API_KEY="${DOLPHIN_API_KEY:-}"
MODEL="${DOLPHIN_MODEL:-nvidia/Qwen3.6-35B-A3B-NVFP4}"
WORKER_TYPE="${DOLPHIN_WORKER_TYPE:-text-v}"
# Public, stable worker-binary URL (linux/amd64 only — the worker ships no arm64 build). `update`
# refreshes it after first launch. Override only if Dolphin moves the download.
WORKER_URL="${DOLPHIN_WORKER_URL:-https://updates.dphn.ai/dolphinpod-worker-v2_linux_amd64}"

# How often (seconds) to check WORKER_URL for a newly published binary while workers run.
CHECK_INTERVAL="${DOLPHIN_UPDATE_CHECK_SECONDS:-3600}"
# Worker liveness is checked this often; the etag poll fires once per CHECK_INTERVAL.
LIVENESS_INTERVAL=30

# Delay between initial worker spawns, AFTER the shared cache is seeded.
SPLIT_STAGGER_SECONDS="${DOLPHIN_SPLIT_STAGGER_SECONDS:-30}"

# On a cold node the siblings wait for the FIRST instance to finish seeding the shared cache
# instead of merely pausing a few seconds. Measured 2026-07-23: with a 30 s stagger both workers
# downloaded the ~12 GB runtime into their own staging directories side by side, doubling the
# bytes over a link that boostrun throttles to a few MB/s. Waiting for instance 0 to actually
# serve means the runtime AND the weights are on disk, so every sibling starts warm.
# 0 disables the wait (back to a plain stagger); the bound keeps a stuck seed from wedging
# the node forever.
SEED_WAIT_SECONDS="${DOLPHIN_SEED_WAIT_SECONDS:-5400}"
# The worker opens this socket once its engine is up; same path the metrics sidecar scrapes.
ENGINE_SOCKET_GLOB="${METRICS_SOCKET_GLOB:-/tmp/dp-*/v.sock}"

# DAH-2475: DOLPHIN_HOME is a cache volume shared by every filler container on the node AND by
# every worker instance inside this one, so the binary download and the worker's self-update are
# cross-process critical sections — two cold workers writing the same path at once produce a
# corrupted binary and a crash loop.
DOLPHIN_LOCK="${DOLPHIN_HOME}/.dolphinpod.lock"
# A cold download on a slow miner link takes minutes; this only bounds a stuck holder, and on
# timeout we proceed anyway rather than fail the container.
DOLPHIN_LOCK_TIMEOUT="${DOLPHIN_LOCK_TIMEOUT:-900}"

# One line per GPU: "<index>, <vram_mb>". Empty output when nvidia-smi is absent/failing.
detect_gpus() {
    nvidia-smi --query-gpu=index,memory.total --format=csv,noheader,nounits 2>/dev/null || true
}

# Emit one line per worker to spawn: a comma-separated gpu_ids list, or the literal "all"
# (worker.json gpu_ids: null -> the worker auto-scales to every GPU on the node).
#
# Every worker instance loads the full model, so it needs the VRAM floor ("Running the full
# model requires 70 GB of VRAM", dphn.ai docs — the same figure the backend gates DPHN nodes
# on) across ITS cards. The plan gives each worker the smallest card group that clears the
# floor: 96 GB cards -> one worker per GPU, 48 GB cards -> one per pair, 32 GB -> one per
# triple-or-more; cards are spread evenly so none sits idle. Fewer than 2 such groups -> the
# node keeps the single all-GPUs worker.
plan_worker_gpu_sets() {
    if [[ -n "${DOLPHIN_GPU_IDS:-}" ]]; then
        echo "${DOLPHIN_GPU_IDS}"
        return
    fi
    local worker_per_gpu="${DOLPHIN_WORKER_PER_GPU:-1}"
    local split_min_vram_mb="${DOLPHIN_SPLIT_MIN_VRAM_MB:-71680}"
    if [[ "${worker_per_gpu}" != "1" ]]; then
        echo "all"
        return
    fi
    local indices=() vram_values=() index vram
    while IFS=',' read -r index vram; do
        index="${index//[[:space:]]/}"
        vram="${vram//[[:space:]]/}"
        [[ -n "${index}" && -n "${vram}" ]] || continue
        indices+=("${index}")
        vram_values+=("${vram}")
    done < <(detect_gpus)
    local gpu_count=${#indices[@]}
    if (( gpu_count < 2 )); then
        echo "all"
        return
    fi
    # The smallest card decides how many cards one worker needs (Lium nodes are homogeneous;
    # min is the conservative choice for a mixed node).
    local min_vram=${vram_values[0]}
    for vram in "${vram_values[@]}"; do
        if (( vram < min_vram )); then
            min_vram=${vram}
        fi
    done
    if (( min_vram <= 0 )); then
        echo "all"
        return
    fi
    local cards_per_worker=$(( (split_min_vram_mb + min_vram - 1) / min_vram ))
    local worker_count=$(( gpu_count / cards_per_worker ))
    if (( worker_count < 2 )); then
        echo "all"
        return
    fi
    # Spread ALL cards evenly over the workers (bundle sizes differ by at most 1), then verify
    # every bundle really clears the floor — a mixed node that can't is left on the single
    # all-GPUs worker rather than launched broken.
    local bundles=() base_bundle_size=$(( gpu_count / worker_count )) bundles_with_extra_card=$(( gpu_count % worker_count ))
    local cursor=0 w size i bundle bundle_vram
    for (( w = 0; w < worker_count; w++ )); do
        size=${base_bundle_size}
        if (( w < bundles_with_extra_card )); then
            size=$(( base_bundle_size + 1 ))
        fi
        bundle=""
        bundle_vram=0
        for (( i = cursor; i < cursor + size; i++ )); do
            bundle="${bundle:+${bundle},}${indices[$i]}"
            bundle_vram=$(( bundle_vram + vram_values[i] ))
        done
        if (( bundle_vram < split_min_vram_mb )); then
            echo "all"
            return
        fi
        bundles+=("${bundle}")
        cursor=$(( cursor + size ))
    done
    printf '%s\n' "${bundles[@]}"
}

# Render one worker.json into <config_dir>. gpu_set "all" -> gpu_ids null. 0600 up front:
# worker.json holds the api_key and the worker refuses a config readable beyond its owner
# ("contains secrets but is accessible beyond its owner").
render_worker_config() {
    local config_dir="$1" gpu_set="$2"
    local gpu_ids_json="null"
    if [[ "${gpu_set}" != "all" ]]; then
        gpu_ids_json="$(jq -Rc 'split(",") | map(select(length > 0) | tonumber)' <<<"${gpu_set}")"
    fi
    mkdir -p "${config_dir}"
    local config_path="${config_dir}/worker.json"
    touch "${config_path}"
    chmod 600 "${config_path}"
    jq -n \
        --arg api "${API_KEY}" \
        --arg model "${MODEL}" \
        --arg worker_type "${WORKER_TYPE}" \
        --argjson gpu_ids "${gpu_ids_json}" \
        '{schema_version: 1, api_key: $api, model: $model, worker_type: $worker_type, gpu_ids: $gpu_ids}' \
        >"${config_path}"
}

# Give an instance its own HOME (so worker.json cannot collide) while keeping ONE copy of the
# ~35 GB model+runtime cache. The symlink is what makes this safe: the closed worker binary
# scrubs its child's environment, so exporting HF_HOME/XDG_CACHE_HOME is not sufficient on its
# own — a path that resolves to the shared directory is.
prepare_instance_home() {
    local instance_home="$1" shared_cache="$2"
    mkdir -p "${instance_home}" "${shared_cache}"
    if [[ -L "${instance_home}/.cache" || ! -e "${instance_home}/.cache" ]]; then
        ln -sfn "${shared_cache}" "${instance_home}/.cache"
    fi
}

# True once any engine is serving: the worker opens its unix socket only after the runtime and
# the model weights are on disk, so this is the honest "shared cache is seeded" signal — and it
# needs no assumption about how the worker names its staging directories.
engine_socket_present() {
    compgen -G "${ENGINE_SOCKET_GLOB}" >/dev/null 2>&1
}

wait_for_cache_seed() {
    (( SEED_WAIT_SECONDS > 0 )) || return 0
    engine_socket_present && return 0
    echo "[dolphin] waiting up to ${SEED_WAIT_SECONDS}s for the first worker to seed the shared cache" >&2
    local waited=0
    while (( waited < SEED_WAIT_SECONDS )); do
        # background sleep + wait, so the TERM trap fires immediately instead of after the nap
        sleep 10 &
        wait $! || true
        waited=$((waited + 10))
        if engine_socket_present; then
            echo "[dolphin] shared cache seeded after ${waited}s; releasing siblings" >&2
            return 0
        fi
    done
    echo "[dolphin] cache not seeded after ${SEED_WAIT_SECONDS}s; starting siblings anyway" >&2
}

published_etag() {
    curl -fsSI --max-time 30 "${WORKER_URL}" | awk 'tolower($1) == "etag:" {print $2}' | tr -d '\r'
}

with_dolphin_lock() {
    # flock ships in the CUDA base image (util-linux). If it is ever absent the writes below
    # are UNSERIALIZED and siblings can corrupt the shared binary, so say so loudly rather
    # than degrade into the "timed out" message, which reads like a slow peer.
    if ! command -v flock >/dev/null 2>&1; then
        echo "[dolphin] WARNING: flock missing, shared-cache writes are unserialized" >&2
        "$@"
        return
    fi
    (
        flock -w "${DOLPHIN_LOCK_TIMEOUT}" 9 || echo "[dolphin] cache lock wait timed out; proceeding" >&2
        "$@"
    ) 9>"${DOLPHIN_LOCK}"
}

download_worker_binary() {
    # Re-check under the lock: whoever held it may have just downloaded the binary for us.
    if [[ -x "${WORKER_BIN}" ]]; then
        return 0
    fi
    local staged
    staged="$(mktemp "${DOLPHIN_HOME}/.dolphinpod-worker.XXXXXX")"
    curl -fsSL "${WORKER_URL}" -o "${staged}"
    chmod +x "${staged}"
    # Atomic: even a lock timeout can never expose a half-written binary to a sibling.
    mv -f "${staged}" "${WORKER_BIN}"
}

# Download the worker binary if it isn't present yet; `update` refreshes it later.
ensure_worker_binary() {
    if [[ -x "${WORKER_BIN}" ]]; then
        return
    fi
    if [[ -z "${WORKER_URL}" ]]; then
        echo "[dolphin] dolphinpod-worker not found and DOLPHIN_WORKER_URL is unset." >&2
        echo "[dolphin] Provide the binary URL from your v2.dphn.ai install script." >&2
        exit 1
    fi
    with_dolphin_lock download_worker_binary
}

# `update` rewrites the binary in the shared cache volume, so siblings updating at once would
# race on the same file.
refresh_binary() {
    with_dolphin_lock "${WORKER_BIN}" update \
        || echo "[dolphin] update failed; starting current version" >&2
}

main() {
    if [[ -z "${API_KEY}" ]]; then
        echo "[dolphin] DOLPHIN_API_KEY is required (dp-... key from v2.dphn.ai)." >&2
        exit 1
    fi

    ensure_worker_binary

    local gpu_sets=() gpu_set_line
    while IFS= read -r gpu_set_line; do
        [[ -n "${gpu_set_line}" ]] && gpu_sets+=("${gpu_set_line}")
    done < <(plan_worker_gpu_sets)
    local instance_count=${#gpu_sets[@]}

    local base_home="${HOME:-/root}"
    local shared_cache="${base_home}/.cache"
    export XDG_CACHE_HOME="${XDG_CACHE_HOME:-${shared_cache}}"
    export HF_HOME="${HF_HOME:-${XDG_CACHE_HOME}/huggingface}"

    local instance_homes=() i
    if (( instance_count == 1 )); then
        # Single-worker path: same config location as always (prod-proven behavior).
        instance_homes=("${base_home}")
    else
        for i in "${!gpu_sets[@]}"; do
            instance_homes+=("${base_home}/dolphin-workers/gpu${gpu_sets[$i]//,/-}")
            prepare_instance_home "${instance_homes[$i]}" "${shared_cache}"
        done
    fi
    for i in "${!gpu_sets[@]}"; do
        render_worker_config "${instance_homes[$i]}/.config/dolphinpod" "${gpu_sets[$i]}"
    done
    echo "[dolphin] spawning ${instance_count} worker(s): $(printf '[%s] ' "${gpu_sets[@]}")" >&2

    # Metrics sidecar (DAH-2468): proxies every engine's uds /metrics onto :9101. Own restart
    # loop with backoff so a broken sidecar can neither kill a worker nor spin hot. Orphaned
    # python (if the subshell dies first on TERM) is reaped by container teardown when PID 1
    # exits. ENGINES_EXPECTED lets it publish up-vs-expected, so one dead engine among N reads
    # as a gap rather than as a quieter machine.
    export DOLPHIN_ENGINES_EXPECTED="${instance_count}"
    local sidecar_pid=""
    if [[ -f "${DOLPHIN_HOME}/metrics_sidecar.py" ]]; then
        (
            while true; do
                python3 "${DOLPHIN_HOME}/metrics_sidecar.py" || true
                sleep 5
            done
        ) &
        sidecar_pid=$!
    fi

    # Engine watchdog: restarts a vLLM engine that wedged inside a CUDA kernel. It kills every
    # `vllm serve` it finds in the container, which is correct for one engine and catastrophic
    # for N — one wedge would take down every bundle. Until it can target a single engine (see
    # its socket->pid contract), it stays off in multi-instance mode rather than shipping a
    # blast radius. DOLPHIN_WATCHDOG_ENABLED=0 turns it off everywhere.
    local watchdog_pid=""
    if [[ "${DOLPHIN_WATCHDOG_ENABLED:-1}" != "0" && -f "${DOLPHIN_HOME}/watchdog.py" ]]; then
        if (( instance_count > 1 )); then
            echo "[dolphin] watchdog disabled: ${instance_count} engines, and it cannot yet restart just one" >&2
        else
            (
                while true; do
                    python3 "${DOLPHIN_HOME}/watchdog.py" || true
                    sleep 5
                done
            ) &
            watchdog_pid=$!
        fi
    fi

    local worker_pids=()
    terminate_workers() {
        local pid
        for pid in "${worker_pids[@]}"; do
            [[ -n "${pid}" ]] && kill -TERM "${pid}" 2>/dev/null || true
        done
        for pid in "${worker_pids[@]}"; do
            [[ -n "${pid}" ]] && wait "${pid}" 2>/dev/null || true
        done
    }
    on_term() {
        if [[ -n "${sidecar_pid}" ]]; then
            kill -TERM "${sidecar_pid}" 2>/dev/null || true
        fi
        if [[ -n "${watchdog_pid}" ]]; then
            kill -TERM "${watchdog_pid}" 2>/dev/null || true
        fi
        terminate_workers
        exit 0
    }
    trap on_term TERM INT

    spawn_instance() {
        local idx="$1"
        (cd "${DOLPHIN_HOME}" && HOME="${instance_homes[$idx]}" exec "${WORKER_BIN}" start) &
        worker_pids[idx]=$!
    }

    # Supervisor loop. The worker's own self-update downloads a new binary and then exits
    # expecting an external supervisor to restart it (systemd in Dolphin's reference install) —
    # so every (re)spawn goes through `update` (DAH-2457). The etag poll is the fallback for
    # when no instance's self-update fires: a changed etag on WORKER_URL restarts them all.
    while true; do
        refresh_binary
        local running_etag
        running_etag="$(published_etag || true)"
        worker_pids=()
        for i in "${!gpu_sets[@]}"; do
            if (( i == 1 )); then
                # Only before the SECOND instance: once instance 0 serves, the runtime and the
                # weights are on disk, so 2..N all start warm and need no further wait.
                wait_for_cache_seed
            fi
            if (( i > 0 && SPLIT_STAGGER_SECONDS > 0 )); then
                # sleep in background + wait, so the TERM trap fires immediately
                sleep "${SPLIT_STAGGER_SECONDS}" &
                wait $! || true
            fi
            spawn_instance "${i}"
        done

        local elapsed=0 restart_all=0
        while true; do
            sleep "${LIVENESS_INTERVAL}" &
            wait $! || true
            for i in "${!worker_pids[@]}"; do
                if ! kill -0 "${worker_pids[$i]}" 2>/dev/null; then
                    wait "${worker_pids[$i]}" 2>/dev/null || true
                    echo "[dolphin] worker [${gpu_sets[$i]}] exited; restarting" >&2
                    refresh_binary
                    spawn_instance "${i}"
                    # A worker exits to self-update onto a freshly published binary; refresh_binary
                    # just pulled it, so re-baseline the etag — otherwise the poll below still sees
                    # the old baseline and forces a redundant full restart of every worker.
                    running_etag="$(published_etag || true)"
                fi
            done
            elapsed=$((elapsed + LIVENESS_INTERVAL))
            if (( elapsed < CHECK_INTERVAL )); then
                continue
            fi
            elapsed=0
            local latest_etag
            latest_etag="$(published_etag || true)"
            if [[ -n "${latest_etag}" && -n "${running_etag}" && "${latest_etag}" != "${running_etag}" ]]; then
                echo "[dolphin] new worker binary published; restarting workers to update" >&2
                restart_all=1
                break
            fi
        done

        if (( restart_all )); then
            terminate_workers
            echo "[dolphin] workers stopped for update; restarting in 5s" >&2
            sleep 5
        fi
    done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
