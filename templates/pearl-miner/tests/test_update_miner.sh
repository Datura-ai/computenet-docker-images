#!/usr/bin/env bash
# Miner auto-update tests (DAH-2696). No framework, run it:
#
#     bash tests/test_update_miner.sh
#
# The real update script runs against a stub `curl` that serves a canned release list and a fake
# binary, so both halves that matter are exercised: it picks the newest stable build inside the
# baked-in major, and every failure path leaves the baked-in binary untouched.
set -uo pipefail

UPDATER="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/update_miner.sh"
failures=0

check() {
    if [[ "$1" == "pass" ]]; then
        echo "  ok: $2"
    else
        echo "  FAIL: $2"
        failures=$((failures + 1))
    fi
}

RELEASES_JSON='[
    {"tag_name": "v3.0.0", "prerelease": false, "draft": false},
    {"tag_name": "v2.12.0", "prerelease": true, "draft": false},
    {"tag_name": "v2.11.0", "prerelease": false, "draft": false},
    {"tag_name": "v2.9.0", "prerelease": false, "draft": false},
    {"tag_name": "nightly", "prerelease": false, "draft": false}
]'

# A stub curl that answers both calls the updater makes: the release list (no -o) and the binary
# download (-o FILE). CURL_FAIL_* and FAKE_BINARY_EXIT drive the failure paths.
make_stub_curl() {
    local stub_dir="$1"
    cat > "${stub_dir}/curl" <<'STUB'
#!/usr/bin/env bash
out=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -o) out="$2"; shift 2 ;;
        --max-time) shift 2 ;;
        *) shift ;;
    esac
done
if [[ -z "${out}" ]]; then
    [[ "${CURL_FAIL_API:-0}" == "1" ]] && exit 7
    printf '%s' "${RELEASES_JSON}"
    exit 0
fi
[[ "${CURL_FAIL_DOWNLOAD:-0}" == "1" ]] && exit 22
printf '#!/usr/bin/env bash\nexit %s\n' "${FAKE_BINARY_EXIT:-0}" > "${out}"
STUB
    chmod +x "${stub_dir}/curl"
}

run_updater() {
    local stub_dir="$1"
    PATH="${stub_dir}:${PATH}" \
        PEARL_MINER_BAKED_VERSION="${BAKED:-2.10.0}" \
        PEARL_MINER_DIR="${stub_dir}/install" \
        PEAKMINER_RELEASES_URL="https://stub/releases" \
        RELEASES_JSON="${RELEASES_JSON}" \
        bash "${UPDATER}" > "${stub_dir}/stdout" 2> "${stub_dir}/stderr"
    echo $?
}

echo "installs the newest stable build inside the baked-in major"
work=$(mktemp -d)
make_stub_curl "${work}"
exit_code=$(run_updater "${work}")
[[ "${exit_code}" == "0" ]] && check pass "exits 0" || check fail "exits 0 (got ${exit_code})"
[[ -x "${work}/install/peakminer" ]] && check pass "installed the update" || check fail "installed the update"
grep -q "running 2.11.0" "${work}/stderr" && check pass "picked 2.11.0 over the 2.12.0 prerelease and 3.0.0" \
    || check fail "picked 2.11.0 (stderr: $(cat "${work}/stderr"))"
rm -rf "${work}"

echo "keeps the baked-in binary when it is already the newest"
work=$(mktemp -d)
make_stub_curl "${work}"
exit_code=$(BAKED=2.11.0 run_updater "${work}")
[[ "${exit_code}" == "0" ]] && check pass "exits 0" || check fail "exits 0 (got ${exit_code})"
[[ ! -e "${work}/install/peakminer" ]] && check pass "installed nothing" || check fail "installed nothing"
rm -rf "${work}"

echo "keeps mining when the release list is unreachable"
work=$(mktemp -d)
make_stub_curl "${work}"
exit_code=$(CURL_FAIL_API=1 run_updater "${work}")
[[ "${exit_code}" == "0" ]] && check pass "exits 0 instead of failing the container" || check fail "exits 0 (got ${exit_code})"
[[ ! -e "${work}/install/peakminer" ]] && check pass "installed nothing" || check fail "installed nothing"
rm -rf "${work}"

echo "keeps mining when the download fails"
work=$(mktemp -d)
make_stub_curl "${work}"
exit_code=$(CURL_FAIL_DOWNLOAD=1 run_updater "${work}")
[[ "${exit_code}" == "0" ]] && check pass "exits 0" || check fail "exits 0 (got ${exit_code})"
[[ ! -e "${work}/install/peakminer" ]] && check pass "installed nothing" || check fail "installed nothing"
rm -rf "${work}"

echo "refuses a downloaded build that cannot run"
work=$(mktemp -d)
make_stub_curl "${work}"
exit_code=$(FAKE_BINARY_EXIT=1 run_updater "${work}")
[[ "${exit_code}" == "0" ]] && check pass "exits 0" || check fail "exits 0 (got ${exit_code})"
[[ ! -e "${work}/install/peakminer" ]] && check pass "installed nothing" || check fail "installed nothing"
rm -rf "${work}"

echo "skips the check when auto-update is disabled"
work=$(mktemp -d)
make_stub_curl "${work}"
exit_code=$(PEARL_MINER_AUTO_UPDATE=0 run_updater "${work}")
[[ "${exit_code}" == "0" ]] && check pass "exits 0" || check fail "exits 0 (got ${exit_code})"
[[ ! -e "${work}/install/peakminer" ]] && check pass "installed nothing" || check fail "installed nothing"
rm -rf "${work}"

if (( failures > 0 )); then
    echo "${failures} check(s) failed"
    exit 1
fi
echo "all checks passed"
