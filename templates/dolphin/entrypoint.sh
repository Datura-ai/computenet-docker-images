#!/usr/bin/env bash
#
# Boot Dolphin (dphn.ai) v2 inference worker(s) inside a Lium pod: render worker.json from env,
# ensure the binary is present, then supervise `dolphinpod-worker update && start` in a restart
# loop so the worker can self-update while the container keeps running.
#
# DAH-2465: on multi-GPU nodes one worker is spawned per minimal VRAM bundle (the smallest card
# group that fits the model) instead of one tensor-sharded worker over every GPU. Measured on
# prod: an 8x RTX PRO 6000 single worker reports 317 slots at ~13% VRAM/GPU, while a 1x worker
# reports 72 slots at ~70% VRAM — more workers recover the lost concurrency. 96 GB cards get a
# worker per GPU, 48 GB cards one per pair, and so on; nodes that can't form 2+ bundles keep
# the single all-GPUs worker.
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

# Delay between initial worker spawns: lets the first instance warm the shared model/runtime
# cache before its siblings hit the same downloads.
SPLIT_STAGGER_SECONDS="${DOLPHIN_SPLIT_STAGGER_SECONDS:-30}"

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
# node keeps the single all-GPUs worker (pre-0.0.4 behavior).
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
# worker.json holds the api_key and the worker refuses a config readable beyond its owner.
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

published_etag() {
    curl -fsSI --max-time 30 "${WORKER_URL}" | awk 'tolower($1) == "etag:" {print $2}' | tr -d '\r'
}

# `update` swaps the binary in DOLPHIN_HOME; serialize under flock so concurrent per-instance
# respawns never write the file at the same time.
refresh_binary() {
    flock -x "${DOLPHIN_HOME}/.update.lock" "${WORKER_BIN}" update \
        || echo "[dolphin] update failed; starting current version" >&2
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
    curl -fsSL "${WORKER_URL}" -o "${WORKER_BIN}"
    chmod +x "${WORKER_BIN}"
}

main() {
    if [[ -z "${API_KEY}" ]]; then
        echo "[dolphin] DOLPHIN_API_KEY is required (dp-... key from v2.dphn.ai)." >&2
        exit 1
    fi

    ensure_worker_binary
    touch "${DOLPHIN_HOME}/.update.lock"

    local gpu_sets=() gpu_set_line
    while IFS= read -r gpu_set_line; do
        [[ -n "${gpu_set_line}" ]] && gpu_sets+=("${gpu_set_line}")
    done < <(plan_worker_gpu_sets)
    local instance_count=${#gpu_sets[@]}

    # Per-instance HOME isolates each worker's config; model weights and runtime caches stay
    # shared so N instances keep ONE copy on the pod volume.
    local base_home="${HOME:-/root}"
    export XDG_CACHE_HOME="${XDG_CACHE_HOME:-${base_home}/.cache}"
    export HF_HOME="${HF_HOME:-${XDG_CACHE_HOME}/huggingface}"

    local instance_homes=() i
    if [[ ${instance_count} -eq 1 ]]; then
        # Single-worker path: same config location as always (prod-proven behavior).
        instance_homes=("${base_home}")
    else
        for i in "${!gpu_sets[@]}"; do
            instance_homes+=("${base_home}/dolphin-workers/gpu${gpu_sets[$i]//,/-}")
        done
    fi
    for i in "${!gpu_sets[@]}"; do
        render_worker_config "${instance_homes[$i]}/.config/dolphinpod" "${gpu_sets[$i]}"
    done
    echo "[dolphin] spawning ${instance_count} worker(s): $(printf '[%s] ' "${gpu_sets[@]}")" >&2

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
            if (( i > 0 && SPLIT_STAGGER_SECONDS > 0 )); then
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
