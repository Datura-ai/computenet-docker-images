#!/usr/bin/env bash
# DAH-4300: download the Engy checkpoint into the node's Engy cache volume while PEARL mines, so the node can switch
# to Engy without the download wait. The backend sets both variables only on a node Engy could serve:
#   PEARL_PREFETCH_HF_REPO  Hugging Face repo of the checkpoint, e.g. moonshotai/Kimi-K3
#   PEARL_PREFETCH_DIR      where the golden image reads it, /root/models/<model> on the engy_cache_* volume
# Never fails the container: the miner runs whatever happens here. `hf download` resumes per file, so a run
# stopped mid-download (a rental, the switch to Engy) continues on the next PEARL start.
set -uo pipefail

if [[ -z "${PEARL_PREFETCH_HF_REPO:-}" || -z "${PEARL_PREFETCH_DIR:-}" ]]; then
    exit 0
fi

# The validator may refuse the Engy cache volume; then the parent dir is not mounted and the download would fill
# the container's small run volume instead.
if ! mountpoint -q "${PEARL_PREFETCH_DIR%/*}"; then
    echo "[prefetch] ${PEARL_PREFETCH_DIR%/*} is not mounted; skipping the download"
    exit 0
fi

# As fast as the host allows: the checkpoint is Xet-backed, so hf_xet's high-performance mode plus many files in
# parallel; no nice, the miner is GPU-bound. On the bb host this was ~2.2x the old 4 workers at nice 19 (cdi#87).
max_workers="${PEARL_PREFETCH_MAX_WORKERS:-32}"
export HF_XET_HIGH_PERFORMANCE="${HF_XET_HIGH_PERFORMANCE:-1}"
attempts="${PEARL_PREFETCH_ATTEMPTS:-5}"
retry_delay="${PEARL_PREFETCH_RETRY_DELAY_SECONDS:-60}"

for (( attempt = 1; attempt <= attempts; attempt++ )); do
    echo "[prefetch] ${PEARL_PREFETCH_HF_REPO} -> ${PEARL_PREFETCH_DIR} (attempt ${attempt}/${attempts})"
    if hf download "${PEARL_PREFETCH_HF_REPO}" \
        --local-dir "${PEARL_PREFETCH_DIR}" --max-workers "${max_workers}"; then
        echo "[prefetch] done"
        exit 0
    fi
    (( attempt < attempts )) && sleep "${retry_delay}"
done
echo "[prefetch] gave up after ${attempts} attempts; the miner keeps running" >&2
exit 0
