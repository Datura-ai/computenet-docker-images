#!/usr/bin/env bash
# pre_start.sh tests (DAH-3704). No framework, run it:
#
#     bash templates/better-comfyui/tests/test_pre_start.sh [path/to/pre_start.sh]
#
# Covered: the first-time-sync spinner is stopped without ending the script — the exact `kill`/`wait` lines from
# pre_start.sh run under `set -e` with a real background loop and the script must reach the line after them
# (the archived image's `kill $PID; wait $PID` returned 143 and errexit ended /pre_start.sh, so /start.sh and the
# container exited before ComfyUI started); no `wait` in the script is left unguarded; the script parses (bash -n);
# a failing command reports itself and exits 0 so /start.sh keeps the pod up, and the ComfyUI command line is built
# from CUSTOM_ARGS the way the header documents.
#
# Against the old script it fails: `bash tests/test_pre_start.sh <(git show 210db17:templates/better-comfyui/pre_start.sh)`.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRE_START="${1:-$HERE/../pre_start.sh}"
# the script is read several times below; a process substitution (<(git show …)) is a FIFO that empties on the
# first read, so anything that is not a regular file is copied to a temp file first
if [[ ! -f "$PRE_START" ]]; then
    _copy=$(mktemp)
    cat "$PRE_START" > "$_copy"
    PRE_START=$_copy
    trap 'rm -f "$_copy"' EXIT
fi
failures=0

check() {
    if [[ "$1" == "pass" ]]; then
        echo "  ok: $2"
    else
        echo "  FAIL: $2"
        failures=$((failures + 1))
    fi
}

echo "pre_start.sh under test: $PRE_START"

# --- it parses -----------------------------------------------------------------------------------------------------
if bash -n "$PRE_START" 2>/dev/null; then check pass "bash -n"; else check fail "bash -n"; fi

# --- the spinner stop survives errexit -----------------------------------------------------------------------------
# The lines between "Stop the progress indicator" and the next blank line are the ones the script runs after rsync.
stop_lines=$(sed -n '/Stop the progress indicator/,/^[[:space:]]*$/p' "$PRE_START" | grep -E '^\s*(kill|wait)\b')
if [[ -z "$stop_lines" ]]; then
    check fail "found the kill/wait lines after 'Stop the progress indicator'"
else
    check pass "found the kill/wait lines after 'Stop the progress indicator'"
    out=$(bash -c "set -e
( while true; do sleep 0.2; done ) &
PROGRESS_PID=\$!
sleep 0.3
$stop_lines
echo survived" 2>&1)
    rc=$?
    if [[ $rc -eq 0 && "$out" == "survived" ]]; then
        check pass "spinner stop under set -e: rc 0 and the script continues"
    else
        check fail "spinner stop under set -e: rc $rc, output '$out' (expected rc 0, 'survived')"
    fi
fi

# --- the whole first-time-sync block, end to end, on temp directories ------------------------------------------
# From `if [ ! -d "$VIRTUAL_ENV" ]; then` to its `else`: banner, spinner, rsync into the staging dir, spinner stop,
# rename, banner. The venv must appear at its final path only, complete, and the block must run through under set -e.
if ! command -v rsync >/dev/null 2>&1; then
    echo "  skip: rsync not installed — first-time-sync block not run"
else
    block=$(awk '/^if \[ ! -d "\$VIRTUAL_ENV" \]; then$/{p=1} p{print} p&&/^else$/{exit}' "$PRE_START" | sed '$d')
    if [[ -z "$block" ]]; then
        check fail "found the first-time-sync block"
    else
        tmp=$(mktemp -d)
        mkdir -p "$tmp/src/bin" "$tmp/src/lib" && echo python > "$tmp/src/bin/python3" && echo torch > "$tmp/src/lib/torch.py"
        out=$(TERM=dumb bash -c "set -e
print_feedback() { echo \"\$1\"; }
VIRTUAL_ENV='$tmp/venv'; SOURCE_VENV='$tmp/src'; SYNC_DIR='$tmp/venv.sync'
$block
fi
echo block-done" 2>&1)
        rc=$?
        if [[ $rc -eq 0 && "$out" == *block-done* && "$out" == *"SYNC COMPLETED"* ]]; then
            check pass "first-time-sync block runs through under set -e (rc 0, completion banner)"
        else
            check fail "first-time-sync block runs through under set -e: rc $rc, tail: $(tail -c 200 <<<"$out")"
        fi
        if [[ -f "$tmp/venv/bin/python3" && -f "$tmp/venv/lib/torch.py" && ! -e "$tmp/venv.sync" ]]; then
            check pass "venv copied to its final path via the staging dir (staging dir gone)"
        else
            check fail "venv copied to its final path via the staging dir: $(find "$tmp" 2>&1 | tr '\n' ' ')"
        fi
        rm -rf "$tmp"
    fi
fi

# --- every wait is guarded ---------------------------------------------------------------------------------------
unguarded=$(grep -nE '^\s*wait\b' "$PRE_START" | grep -vE '\|\|\s*true\s*$' || true)
if [[ -z "$unguarded" ]]; then
    check pass "no bare 'wait' under set -e"
else
    check fail "bare 'wait' under set -e: $unguarded"
fi

# --- a failing command reports itself and hands back to /start.sh with rc 0 ---------------------------------------
handler=$(sed -n '/^print_feedback() {/,/^}/p; /^on_error() {/,/^}/p; /^trap .*ERR$/p' "$PRE_START")
if ! grep -q '^trap ' <<<"$handler"; then
    check fail "found the ERR trap and on_error"
else
    out=$(bash -c "set -e
$handler
false
echo unreachable" 2>&1)
    rc=$?
    if [[ $rc -eq 0 && "$out" == *"pre_start.sh failed at line"* && "$out" != *unreachable* ]]; then
        check pass "a failing command under set -e prints the failure line and exits 0 for /start.sh"
    else
        check fail "a failing command under set -e prints the failure line and exits 0: rc $rc, output '$out'"
    fi

    # a failure while the spinner runs (rsync ENOSPC, mv) must not leave the spinner subshell behind
    out=$(bash -c "set -e
$handler
( while true; do sleep 0.2; done ) &
PROGRESS_PID=\$!
echo spinner=\$PROGRESS_PID
false
echo unreachable" 2>&1)
    rc=$?
    spinner_pid=$(sed -n 's/^spinner=//p' <<<"$out")
    sleep 0.3
    if [[ $rc -eq 0 && -n "$spinner_pid" ]] && ! kill -0 "$spinner_pid" 2>/dev/null; then
        check pass "on_error stops a running spinner before it exits"
    else
        [[ -n "$spinner_pid" ]] && kill "$spinner_pid" 2>/dev/null
        check fail "on_error stops a running spinner before it exits: rc $rc, spinner '$spinner_pid', output '$out'"
    fi
fi

# --- CUSTOM_ARGS is split into extra flags -------------------------------------------------------------------------
# Run the argument-building block with a stub python that prints its argv.
argv_block=$(sed -n '/^COMFY_ARGS=(/,/^fi$/p' "$PRE_START")
if [[ -z "$argv_block" ]]; then
    check fail "found the COMFY_ARGS block"
else
    out=$(CUSTOM_ARGS="--lowvram --preview-method auto" bash -c "$argv_block
printf '%s\n' \"\${COMFY_ARGS[@]}\"" 2>&1 | tr '\n' ' ')
    if [[ "$out" == "--listen --port 3000 --enable-cors-header --lowvram --preview-method auto " ]]; then
        check pass "CUSTOM_ARGS appended after the fixed flags"
    else
        check fail "CUSTOM_ARGS appended after the fixed flags: got '$out'"
    fi
    out=$(CUSTOM_ARGS="" bash -c "$argv_block
printf '%s\n' \"\${COMFY_ARGS[@]}\"" 2>&1 | tr '\n' ' ')
    if [[ "$out" == "--listen --port 3000 --enable-cors-header " ]]; then
        check pass "empty CUSTOM_ARGS adds nothing"
    else
        check fail "empty CUSTOM_ARGS adds nothing: got '$out'"
    fi
fi

echo
if [[ $failures -eq 0 ]]; then echo "all checks passed"; else echo "$failures check(s) failed"; exit 1; fi
