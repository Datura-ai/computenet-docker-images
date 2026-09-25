#!/usr/bin/env bash
# Miner supervision tests (DAH-2688). No framework, run it:
#
#     bash tests/test_entrypoint_restart.sh
#
# The entrypoint runs for real against stub `peakminer` and `nvidia-smi` binaries on PATH, so the
# restart loop and its crash-loop ceiling are exercised as production runs them.
#
# Covered: a miner that dies is restarted; a miner that keeps dying ends the container with exit 0
# at the cap (`restart: on-failure` leaves a zero exit alone, so the run ends) instead of a
# forever-restart; the script's own failures (no wallet, no GPU, the supervisor
# dying) stay non-zero.
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
sleep ${run_seconds}
exit ${miner_exit_code}
STUB
    printf '#!/usr/bin/env bash\necho "GPU 0: NVIDIA L4"\n' > "${stub_dir}/nvidia-smi"
    chmod +x "${stub_dir}/peakminer" "${stub_dir}/nvidia-smi"
}

run_entrypoint() {
    local stub_dir="$1" max_restarts="$2" restart_delay="${3:-0}"
    PATH="${stub_dir}:${PATH}" \
    PEARL_POOL_HOST=prl.kryptex.network \
    PEARL_POOL_PORT=7048 \
    PEARL_POOL_WALLET=prl1test \
    PEARL_POOL_WORKER=test-worker \
    PEARL_LOG_DIR="${stub_dir}/logs" \
    PEARL_MINER_RESTART_DELAY_SECONDS="${restart_delay}" \
    PEARL_MINER_MAX_RESTARTS="${max_restarts}" \
    PEARL_MINER_RESTART_WINDOW_SECONDS=600 \
    PEARL_MINER_AUTO_UPDATE=0 \
    PEARL_MINER_DIR="${stub_dir}/install" \
        bash "${ENTRYPOINT}" > "${stub_dir}/out" 2>&1
    echo $?
}

# Regression: the cap used to `return` the miner's code (3 here), which `restart: on-failure`
# restarts with no cap, so the run never ended.
test_crash_loop_cap_exits_zero() {
    echo "crash loop"
    local stub_dir
    stub_dir="$(mktemp -d)"
    make_stubs "${stub_dir}" 3 0
    local status
    status="$(run_entrypoint "${stub_dir}" 2)"
    local launches
    launches="$(wc -l < "${stub_dir}/launches" | tr -d ' ')"

    check "$([[ "${status}" == "0" ]] && echo pass)" "a miner that keeps dying ends the container with exit 0 at the cap (got ${status})"
    check "$([[ "${launches}" -eq 3 ]] && echo pass)" "a cap of 2 restarts means 3 launches, then abandoned (got ${launches})"
    check "$(grep -q "cap 2 reached; giving the node back, exiting 0 so the reconciler closes the run" "${stub_dir}/out" && echo pass)" "the cap exit is logged with the reason"
    check "$(grep -q "exited with code 3; 3 exits in 600s" "${stub_dir}/out" && echo pass)" "the cap line carries the miner's last code and the count"
    check "$(grep -q "restarting in" "${stub_dir}/out" && echo pass)" "each restart is logged"
    rm -rf "${stub_dir}"
}

# Negative control for the zero exit: only the cap is 0. A supervisor that dies for its own reason
# (here `sleep` refusing a bad delay under errexit) must not read as a finished run.
test_supervisor_failure_stays_non_zero() {
    echo "supervisor failure"
    local stub_dir
    stub_dir="$(mktemp -d)"
    make_stubs "${stub_dir}" 3 0
    local status
    status="$(run_entrypoint "${stub_dir}" 5 not-a-number)"
    local launches
    launches="$(wc -l < "${stub_dir}/launches" | tr -d ' ')"

    check "$([[ "${status}" != "0" ]] && echo pass)" "a supervisor that dies before the cap exits the container non-zero (got ${status})"
    check "$([[ "${launches}" -eq 1 ]] && echo pass)" "the miner was launched once, then the supervisor died on the delay (got ${launches})"
    check "$(! grep -q "exiting 0" "${stub_dir}/out" && echo pass)" "no cap line is logged"
    rm -rf "${stub_dir}"
}

test_no_gpu_fails_fast() {
    echo "no gpu"
    local stub_dir
    stub_dir="$(mktemp -d)"
    make_stubs "${stub_dir}" 0 0
    printf '#!/usr/bin/env bash\nexit 0\n' > "${stub_dir}/nvidia-smi"
    local status
    status="$(run_entrypoint "${stub_dir}" 5)"

    check "$([[ "${status}" != "0" ]] && echo pass)" "no visible GPU is a hard failure, not a cap exit (got ${status})"
    check "$([[ ! -f "${stub_dir}/launches" ]] && echo pass)" "the miner is never launched without a GPU"
    rm -rf "${stub_dir}"
}

test_missing_wallet_fails_fast() {
    echo "missing wallet"
    local stub_dir
    stub_dir="$(mktemp -d)"
    make_stubs "${stub_dir}" 0 0
    PATH="${stub_dir}:${PATH}" PEARL_POOL_HOST=prl.kryptex.network PEARL_POOL_PORT=7048 \
        PEARL_LOG_DIR="${stub_dir}/logs" bash "${ENTRYPOINT}" > "${stub_dir}/out" 2>&1
    local status=$?

    check "$([[ "${status}" != "0" ]] && echo pass)" "no wallet is a hard failure, not a crash loop"
    check "$([[ ! -f "${stub_dir}/launches" ]] && echo pass)" "the miner is never launched without a wallet"
    rm -rf "${stub_dir}"
}

test_crash_loop_cap_exits_zero
test_supervisor_failure_stays_non_zero
test_missing_wallet_fails_fast
test_no_gpu_fails_fast

echo
if (( failures )); then
    echo "${failures} failure(s)"
    exit 1
fi
echo "all checks passed"
