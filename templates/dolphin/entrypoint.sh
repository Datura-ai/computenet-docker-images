#!/usr/bin/env bash
#
# Boot a Dolphin (dphn.ai) v2 inference worker inside a Lium pod: render worker.json from env,
# ensure the binary is present, then supervise `dolphinpod-worker update && start` in a restart
# loop so the worker can self-update while the container keeps running.
#
# The worker auto-scales to every GPU on the node (gpu_ids: null), so this image does NOT pick
# a GPU count. Which nodes are eligible (VRAM floor, supported arch) is the scheduler's job.
set -euo pipefail

DOLPHIN_HOME="${DOLPHIN_HOME:-/opt/dolphinpod}"
WORKER_BIN="${DOLPHIN_HOME}/dolphinpod-worker"
CONFIG_DIR="${HOME:-/root}/.config/dolphinpod"

API_KEY="${DOLPHIN_API_KEY:-}"
MODEL="${DOLPHIN_MODEL:-nvidia/Qwen3.6-35B-A3B-NVFP4}"
WORKER_TYPE="${DOLPHIN_WORKER_TYPE:-text-v}"
# Comma-separated GPU indices (e.g. "0,1"); empty -> null -> worker uses all GPUs on the node.
GPU_IDS="${DOLPHIN_GPU_IDS:-}"
# Public, stable worker-binary URL (linux/amd64 only — the worker ships no arm64 build). `update`
# refreshes it after first launch. Override only if Dolphin moves the download.
WORKER_URL="${DOLPHIN_WORKER_URL:-https://updates.dphn.ai/dolphinpod-worker-v2_linux_amd64}"

if [[ -z "${API_KEY}" ]]; then
    echo "[dolphin] DOLPHIN_API_KEY is required (dp-... key from v2.dphn.ai)." >&2
    exit 1
fi

mkdir -p "${CONFIG_DIR}"
gpu_ids_json="null"
if [[ -n "${GPU_IDS}" ]]; then
    gpu_ids_json="$(jq -Rc 'split(",") | map(select(length > 0) | tonumber)' <<<"${GPU_IDS}")"
fi
# 0600 up front: worker.json holds the api_key and the worker refuses a config readable beyond its
# owner ("contains secrets but is accessible beyond its owner").
config_path="${CONFIG_DIR}/worker.json"
touch "${config_path}"
chmod 600 "${config_path}"
jq -n \
    --arg api "${API_KEY}" \
    --arg model "${MODEL}" \
    --arg worker_type "${WORKER_TYPE}" \
    --argjson gpu_ids "${gpu_ids_json}" \
    '{schema_version: 1, api_key: $api, model: $model, worker_type: $worker_type, gpu_ids: $gpu_ids}' \
    >"${config_path}"

# DAH-2475: DOLPHIN_HOME is a cache volume SHARED by every filler container on the node, so the
# binary download and the worker's self-update are cross-container critical sections — two cold
# workers writing the same path at once produce a corrupted binary and a crash loop. Serialize them
# behind a lock file inside that volume; the first container populates it and the rest wait, then
# find it ready. Writes are also staged + atomically renamed, so even a lock timeout can never expose
# a half-written binary to a sibling. `flock` ships in the CUDA base image (util-linux is a required
# package), so nothing extra is installed for it.
# The model weights under HOME/.cache are shared too, but huggingface_hub does its own file locking.
DOLPHIN_LOCK="${DOLPHIN_HOME}/.dolphinpod.lock"
# A cold download on a slow miner link takes minutes; this only bounds a stuck holder, and on timeout
# we proceed anyway rather than fail the container.
DOLPHIN_LOCK_TIMEOUT="${DOLPHIN_LOCK_TIMEOUT:-900}"

with_dolphin_lock() {
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
    mv -f "${staged}" "${WORKER_BIN}"
}

if [[ ! -x "${WORKER_BIN}" ]]; then
    if [[ -z "${WORKER_URL}" ]]; then
        echo "[dolphin] dolphinpod-worker not found and DOLPHIN_WORKER_URL is unset." >&2
        echo "[dolphin] Provide the binary URL from your v2.dphn.ai install script." >&2
        exit 1
    fi
    with_dolphin_lock download_worker_binary
fi

# How often (seconds) to check WORKER_URL for a newly published binary while the worker runs.
CHECK_INTERVAL="${DOLPHIN_UPDATE_CHECK_SECONDS:-3600}"
# Worker liveness is checked this often; the etag poll fires once per CHECK_INTERVAL.
LIVENESS_INTERVAL=30

published_etag() {
    curl -fsSI --max-time 30 "${WORKER_URL}" | awk 'tolower($1) == "etag:" {print $2}' | tr -d '\r'
}

# Metrics sidecar (DAH-2468): proxies vLLM's uds /metrics onto :9101. Own restart loop
# with backoff so a broken sidecar can neither kill the worker nor spin hot; the worker
# supervisor below stays untouched. Orphaned python (if the subshell dies first on TERM)
# is reaped by container teardown when PID 1 exits.
sidecar_pid=""
if [[ -f "${DOLPHIN_HOME}/metrics_sidecar.py" ]]; then
    (
        while true; do
            python3 "${DOLPHIN_HOME}/metrics_sidecar.py" || true
            sleep 5
        done
    ) &
    sidecar_pid=$!
fi

# Engine watchdog: vLLM wedges inside a CUDA kernel under load — worker alive, container
# running, /health 200, GPU pinned at 100% — and only the token counters show it. Restarts
# the engine (not the worker, not the container) so a filler loses minutes, not hours. Own
# restart loop for the same reason as the sidecar; DOLPHIN_WATCHDOG_ENABLED=0 turns it off.
# Unlike the sidecar this process acts, so an orphan surviving the TERM below can still
# SIGKILL an engine during shutdown — harmless only because the container is going away.
watchdog_pid=""
if [[ "${DOLPHIN_WATCHDOG_ENABLED:-1}" != "0" && -f "${DOLPHIN_HOME}/watchdog.py" ]]; then
    (
        while true; do
            python3 "${DOLPHIN_HOME}/watchdog.py" || true
            sleep 5
        done
    ) &
    watchdog_pid=$!
fi

worker_pid=""
on_term() {
    if [[ -n "${sidecar_pid}" ]]; then
        kill -TERM "${sidecar_pid}" 2>/dev/null || true
    fi
    if [[ -n "${watchdog_pid}" ]]; then
        kill -TERM "${watchdog_pid}" 2>/dev/null || true
    fi
    if [[ -n "${worker_pid}" ]]; then
        kill -TERM "${worker_pid}" 2>/dev/null || true
        wait "${worker_pid}" || true
    fi
    exit 0
}
trap on_term TERM INT

cd "${DOLPHIN_HOME}"
# Supervisor loop. The worker's own self-update downloads a new binary and then exits expecting an
# external supervisor to restart it (systemd in Dolphin's reference install); without this loop that
# exit killed PID 1, so long-lived fillers stayed on their boot version forever (DAH-2457). The etag
# poll is the fallback for when that self-update path does not fire: a changed etag on WORKER_URL
# means a new binary was published, so restart the worker through `update`.
while true; do
    # Also under the lock: `update` rewrites the binary in the SHARED cache volume, so two siblings
    # updating at once would race on the same file.
    with_dolphin_lock "${WORKER_BIN}" update || echo "[dolphin] update failed; starting current version" >&2
    running_etag="$(published_etag || true)"
    "${WORKER_BIN}" start &
    worker_pid=$!

    elapsed=0
    while kill -0 "${worker_pid}" 2>/dev/null; do
        # sleep in background + wait, so the TERM trap fires immediately instead of after the nap.
        sleep "${LIVENESS_INTERVAL}" &
        wait $! || true
        elapsed=$((elapsed + LIVENESS_INTERVAL))
        if (( elapsed < CHECK_INTERVAL )); then
            continue
        fi
        elapsed=0
        latest_etag="$(published_etag || true)"
        if [[ -n "${latest_etag}" && -n "${running_etag}" && "${latest_etag}" != "${running_etag}" ]]; then
            echo "[dolphin] new worker binary published; restarting worker to update" >&2
            kill -TERM "${worker_pid}" 2>/dev/null || true
            break
        fi
    done

    wait "${worker_pid}" || true
    worker_pid=""
    echo "[dolphin] worker exited; restarting in 5s" >&2
    sleep 5
done
