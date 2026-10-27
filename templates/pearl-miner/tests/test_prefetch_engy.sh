#!/usr/bin/env bash
# Engy checkpoint prefetch tests (DAH-4300). No framework, run it:
#
#     bash tests/test_prefetch_engy.sh
#
# prefetch_engy.sh and the entrypoint run for real against a stub `hf` (and the entrypoint's stub miner) on PATH.
set -uo pipefail

TEMPLATE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
failures=0

check() {
    if [[ "$1" == "pass" ]]; then
        echo "  ok: $2"
    else
        echo "  FAIL: $2"
        failures=$((failures + 1))
    fi
}

# A stub `hf` that records its arguments and exits with HF_STUB_EXIT.
make_hf_stub() {
    local stub_dir="$1"
    cat > "${stub_dir}/hf" <<STUB
#!/usr/bin/env bash
echo "\$*" >> "${stub_dir}/hf_calls"
echo "\${HF_XET_HIGH_PERFORMANCE:-}" >> "${stub_dir}/hf_env"
exit \${HF_STUB_EXIT:-0}
STUB
    chmod +x "${stub_dir}/hf"
}

run_prefetch() {
    local stub_dir="$1"
    shift
    env PATH="${stub_dir}:${PATH}" PEARL_PREFETCH_RETRY_DELAY_SECONDS=0 "$@" \
        bash "${TEMPLATE_DIR}/prefetch_engy.sh" > "${stub_dir}/out" 2>&1
    echo $?
}

test_downloads_the_checkpoint_into_the_engy_cache_dir() {
    echo "prefetch requested"
    local stub_dir status
    stub_dir="$(mktemp -d)"
    make_hf_stub "${stub_dir}"
    status="$(run_prefetch "${stub_dir}" PEARL_PREFETCH_HF_REPO=moonshotai/Kimi-K3 PEARL_PREFETCH_DIR=/root/models/kimi-k3)"

    check "$([[ "${status}" == "0" ]] && echo pass)" "exits 0 (got ${status})"
    check "$([[ "$(cat "${stub_dir}/hf_calls")" == "download moonshotai/Kimi-K3 --local-dir /root/models/kimi-k3 --max-workers 32" ]] && echo pass)" \
        "one hf download of the repo into the dir, 32 workers (got: $(cat "${stub_dir}/hf_calls" 2>/dev/null))"
    check "$([[ "$(cat "${stub_dir}/hf_env")" == "1" ]] && echo pass)" "Xet high-performance mode on"
    rm -rf "${stub_dir}"
}

test_does_nothing_without_a_request() {
    echo "no prefetch requested"
    local stub_dir status
    stub_dir="$(mktemp -d)"
    make_hf_stub "${stub_dir}"
    status="$(run_prefetch "${stub_dir}" PEARL_PREFETCH_DIR=/root/models/kimi-k3)"

    check "$([[ "${status}" == "0" ]] && echo pass)" "exits 0 (got ${status})"
    check "$([[ ! -f "${stub_dir}/hf_calls" ]] && echo pass)" "hf is never called without a repo"
    rm -rf "${stub_dir}"
}

test_a_failing_download_is_retried_then_given_up_without_failing() {
    echo "download keeps failing"
    local stub_dir status calls
    stub_dir="$(mktemp -d)"
    make_hf_stub "${stub_dir}"
    status="$(run_prefetch "${stub_dir}" HF_STUB_EXIT=1 PEARL_PREFETCH_ATTEMPTS=3 \
        PEARL_PREFETCH_HF_REPO=moonshotai/Kimi-K3 PEARL_PREFETCH_DIR=/root/models/kimi-k3)"
    calls="$(wc -l < "${stub_dir}/hf_calls" | tr -d ' ')"

    check "$([[ "${status}" == "0" ]] && echo pass)" "still exits 0 (got ${status})"
    check "$([[ "${calls}" -eq 3 ]] && echo pass)" "3 attempts (got ${calls})"
    check "$(grep -q "gave up" "${stub_dir}/out" && echo pass)" "the give-up is logged"
    rm -rf "${stub_dir}"
}

test_the_entrypoint_prefetches_beside_the_miner() {
    echo "entrypoint"
    local stub_dir
    stub_dir="$(mktemp -d)"
    make_hf_stub "${stub_dir}"
    printf '#!/usr/bin/env bash\necho launched >> "%s/launches"\nsleep 1\nexit 3\n' "${stub_dir}" > "${stub_dir}/peakminer"
    printf '#!/usr/bin/env bash\necho "GPU 0: NVIDIA B300"\n' > "${stub_dir}/nvidia-smi"
    printf '#!/usr/bin/env bash\nexit 0\n' > "${stub_dir}/sshd"
    printf '#!/usr/bin/env bash\nexit 0\n' > "${stub_dir}/ssh-keygen"
    chmod +x "${stub_dir}/peakminer" "${stub_dir}/nvidia-smi" "${stub_dir}/sshd" "${stub_dir}/ssh-keygen"
    PATH="${stub_dir}:${PATH}" \
    PEARL_POOL_HOST=prl.kryptex.network \
    PEARL_POOL_PORT=7048 \
    PEARL_POOL_WALLET=prl1test \
    PEARL_LOG_DIR="${stub_dir}/logs" \
    LIUM_RUN_DIR="${stub_dir}/run" \
    PEARL_MINER_RESTART_DELAY_SECONDS=0 \
    PEARL_MINER_MAX_RESTARTS=0 \
    PEARL_MINER_AUTO_UPDATE=0 \
    PEARL_MINER_DIR="${stub_dir}/install" \
    PEARL_PREFETCH_HF_REPO=moonshotai/Kimi-K3 \
    PEARL_PREFETCH_DIR="${stub_dir}/models/kimi-k3" \
        bash "${TEMPLATE_DIR}/entrypoint.sh" > "${stub_dir}/out" 2>&1

    check "$([[ -f "${stub_dir}/launches" ]] && echo pass)" "the miner runs"
    check "$(grep -q "^download moonshotai/Kimi-K3 --local-dir ${stub_dir}/models/kimi-k3" "${stub_dir}/hf_calls" 2>/dev/null && echo pass)" \
        "the checkpoint download starts with it"
    check "$(grep -q "\[prefetch\] done" "${stub_dir}/logs/prefetch.log" && echo pass)" "the prefetch logs to the log dir"
    rm -rf "${stub_dir}"
}

test_downloads_the_checkpoint_into_the_engy_cache_dir
test_does_nothing_without_a_request
test_a_failing_download_is_retried_then_given_up_without_failing
test_the_entrypoint_prefetches_beside_the_miner

echo
if (( failures )); then
    echo "${failures} failure(s)"
    exit 1
fi
echo "all checks passed"
