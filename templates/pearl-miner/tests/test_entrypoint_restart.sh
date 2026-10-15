#!/usr/bin/env bash
# Miner supervision tests (DAH-2688). No framework, run it:
#
#     bash tests/test_entrypoint_restart.sh
#
# The entrypoint runs for real against stub `peakminer` and `nvidia-smi` binaries on PATH, so the
# restart loop and its crash-loop ceiling are exercised as production runs them.
#
# Covered: a miner that dies is restarted, and a miner that keeps dying makes the container exit
# non-zero instead of hiding the crash-loop behind a forever-restart.
set -uo pipefail

ENTRYPOINT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/entrypoint.sh"
failures=0

check() {
    if [[ "$1" == "pass" ]]; then
        echo "  ok: $2"
    else
        echo "  FAIL: $2"
        failures=$((failures + 1))
    fi
}

# A stub miner that appends a line per launch and exits with the code the test asked for.
make_stubs() {
    local stub_dir="$1" miner_exit_code="$2" run_seconds="$3"
    cat > "${stub_dir}/peakminer" <<STUB
#!/usr/bin/env bash
echo launched >> "${stub_dir}/launches"
echo miner >> "${stub_dir}/events"
sleep ${run_seconds}
exit ${miner_exit_code}
STUB
    printf '#!/usr/bin/env bash\necho "GPU 0: NVIDIA L4"\n' > "${stub_dir}/nvidia-smi"
    # sshd and ssh-keygen are stubbed too: a host test must never start or write a real sshd. The
    # sshd stub records whether the lock was held at its start and the exit code the test asked for.
    cat > "${stub_dir}/sshd" <<STUB
#!/usr/bin/env bash
echo "sshd lock=\$(test -d "${stub_dir}/run/lium-ssh-setup.lock" && echo held)" >> "${stub_dir}/events"
exit \${SSHD_STUB_EXIT:-0}
STUB
    printf '#!/usr/bin/env bash\nexit 0\n' > "${stub_dir}/ssh-keygen"
    chmod +x "${stub_dir}/peakminer" "${stub_dir}/nvidia-smi" "${stub_dir}/sshd" "${stub_dir}/ssh-keygen"
}

run_entrypoint() {
    local stub_dir="$1" max_restarts="$2"
    PATH="${stub_dir}:${PATH}" \
    PEARL_POOL_HOST=prl.kryptex.network \
    PEARL_POOL_PORT=7048 \
    PEARL_POOL_WALLET=prl1test \
    PEARL_POOL_WORKER=test-worker \
    PEARL_LOG_DIR="${stub_dir}/logs" \
    LIUM_RUN_DIR="${stub_dir}/run" \
    PEARL_MINER_RESTART_DELAY_SECONDS=0 \
    PEARL_MINER_MAX_RESTARTS="${max_restarts}" \
    PEARL_MINER_RESTART_WINDOW_SECONDS=600 \
    PEARL_MINER_AUTO_UPDATE=0 \
    PEARL_MINER_DIR="${stub_dir}/install" \
        bash "${ENTRYPOINT}" > "${stub_dir}/out" 2>&1
    echo $?
}

test_crash_loop_gives_up_non_zero() {
    echo "crash loop"
    local stub_dir
    stub_dir="$(mktemp -d)"
    make_stubs "${stub_dir}" 3 0
    local status
    status="$(run_entrypoint "${stub_dir}" 2)"
    local launches
    launches="$(wc -l < "${stub_dir}/launches" | tr -d ' ')"

    check "$([[ "${status}" != "0" ]] && echo pass)" "a miner that keeps dying exits the container non-zero (got ${status})"
    check "$([[ "${launches}" -eq 3 ]] && echo pass)" "a cap of 2 restarts means 3 launches, then abandoned (got ${launches})"
    check "$(grep -q "giving up" "${stub_dir}/out" && echo pass)" "the give-up is logged"
    check "$(grep -q "restarting in" "${stub_dir}/out" && echo pass)" "each restart is logged"
    rm -rf "${stub_dir}"
}

test_single_crash_is_restarted() {
    echo "single crash"
    local stub_dir
    stub_dir="$(mktemp -d)"
    # Dies instantly the first times, so within a 5-restart cap the run is still alive after several
    # launches — the point being that ONE death does not end the container.
    make_stubs "${stub_dir}" 1 0
    local status
    status="$(run_entrypoint "${stub_dir}" 5)"
    local launches
    launches="$(wc -l < "${stub_dir}/launches" | tr -d ' ')"

    check "$([[ "${launches}" -gt 1 ]] && echo pass)" "the miner is relaunched after it dies (got ${launches} launches)"
    check "$([[ "${status}" != "0" ]] && echo pass)" "the container still fails once the cap is reached"
    rm -rf "${stub_dir}"
}

test_missing_wallet_fails_fast() {
    echo "missing wallet"
    local stub_dir
    stub_dir="$(mktemp -d)"
    make_stubs "${stub_dir}" 0 0
    PATH="${stub_dir}:${PATH}" PEARL_POOL_HOST=prl.kryptex.network PEARL_POOL_PORT=7048 \
        PEARL_LOG_DIR="${stub_dir}/logs" LIUM_RUN_DIR="${stub_dir}/run" bash "${ENTRYPOINT}" > "${stub_dir}/out" 2>&1
    local status=$?

    check "$([[ "${status}" != "0" ]] && echo pass)" "no wallet is a hard failure, not a crash loop"
    check "$([[ ! -f "${stub_dir}/launches" ]] && echo pass)" "the miner is never launched without a wallet"
    rm -rf "${stub_dir}"
}

test_sshd_starts_under_the_lock_before_the_miner() {
    echo "sshd before the miner"
    local stub_dir
    stub_dir="$(mktemp -d)"
    make_stubs "${stub_dir}" 3 0
    run_entrypoint "${stub_dir}" 0 > /dev/null

    check "$([[ "$(head -n 1 "${stub_dir}/events")" == "sshd lock=held" ]] && echo pass)" "sshd starts first, under the lock the validator bootstrap shares"
    check "$([[ ! -d "${stub_dir}/run/lium-ssh-setup.lock" ]] && echo pass)" "the lock is released once sshd is up"
    rm -rf "${stub_dir}"
}

test_a_failed_sshd_never_stops_the_miner() {
    echo "sshd fails"
    local stub_dir
    stub_dir="$(mktemp -d)"
    make_stubs "${stub_dir}" 3 0
    SSHD_STUB_EXIT=1 run_entrypoint "${stub_dir}" 0 > /dev/null

    check "$(grep -q "sshd did not start" "${stub_dir}/out" && echo pass)" "the failed start is logged"
    check "$(grep -qx miner "${stub_dir}/events" && echo pass)" "the miner launches anyway"
    check "$([[ ! -d "${stub_dir}/run/lium-ssh-setup.lock" ]] && echo pass)" "the lock is released after a failed start"
    rm -rf "${stub_dir}"
}

test_sshd_starts_under_the_lock_before_the_miner
test_a_failed_sshd_never_stops_the_miner
test_crash_loop_gives_up_non_zero
test_single_crash_is_restarted
test_missing_wallet_fails_fast

echo
if (( failures )); then
    echo "${failures} failure(s)"
    exit 1
fi
echo "all checks passed"
