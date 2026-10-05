#!/usr/bin/env bash
# pytorch-entrypoint.sh with ENABLE_DIND=true, run against stubbed containerd, dockerd, curl, docker and
# nvidia-setup.sh (no docker, no root). Checks:
#   - an overridden CMD (a renter's startup command) runs only after dockerd answers, and not at all when
#     dockerd or the NVIDIA setup fails;
#   - the default /start.sh starts before dockerd answers (sshd does not wait for Docker), and the pod ends
#     when dockerd or the NVIDIA setup fails;
#   - a containerd that dies is started again.
#
# Usage: templates/pytorch/tests/test-entrypoint.sh
#        ENTRYPOINT=<file> templates/pytorch/tests/test-entrypoint.sh   (another revision of the entrypoint)
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
entrypoint="${ENTRYPOINT:-$here/../pytorch-entrypoint.sh}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# Stubs read the case's dir from CASE_DIR; every stub that stays up records its PID there for the cleanup.
mkdir -p "$work/bin"
# STUB_CONTAINERD=crash-once: the first run dies like a killed containerd, the next one stays up.
cat > "$work/bin/containerd" <<'STUB'
#!/usr/bin/env bash
if [ "${STUB_CONTAINERD:-}" = crash-once ] && [ ! -e "$CASE_DIR/containerd-crashed" ]; then
  touch "$CASE_DIR/containerd-crashed"; exit 137
fi
[ -e "$CASE_DIR/containerd-crashed" ] && touch "$CASE_DIR/containerd-restarted"
echo $$ >> "$CASE_DIR/pids"; exec sleep 30
STUB
# STUB_DOCKERD: ready:<seconds> answers after a delay; fail exits at once, like dockerd with a broken daemon.json.
cat > "$work/bin/dockerd" <<'STUB'
#!/usr/bin/env bash
case "$STUB_DOCKERD" in
  fail) echo "failed to start daemon: invalid daemon.json" >&2; exit 1 ;;
  ready:*) echo $$ >> "$CASE_DIR/pids"; sleep "${STUB_DOCKERD#ready:}"; touch "$CASE_DIR/docker-ready"; exec sleep 30 ;;
esac
STUB
cat > "$work/bin/curl" <<'STUB'
#!/usr/bin/env bash
[ -e "$CASE_DIR/docker-ready" ]
STUB
cat > "$work/bin/docker" <<'STUB'
#!/usr/bin/env bash
[ -e "$CASE_DIR/docker-ready" ] || { echo "Cannot connect to the Docker daemon" >&2; exit 1; }
STUB
cat > "$work/nvidia-setup.sh" <<'STUB'
#!/usr/bin/env bash
exit "${STUB_NVIDIA_EXIT:-0}"
STUB
# The default CMD: notes whether Docker answered before it started, then stays up like /start.sh.
cat > "$work/start.sh" <<'STUB'
#!/usr/bin/env bash
if [ -e "$CASE_DIR/docker-ready" ]; then touch "$CASE_DIR/start-after-docker"; else touch "$CASE_DIR/start-before-docker"; fi
echo $$ >> "$CASE_DIR/pids"; exec sleep 30
STUB
chmod +x "$work"/bin/* "$work/nvidia-setup.sh" "$work/start.sh"
# macOS checks a new executable on its first run (~0.4 s); take that hit here, not inside the timed cases.
CASE_DIR="$work" "$work/bin/curl"; CASE_DIR="$work" "$work/nvidia-setup.sh"

fail=0
pass() { echo "ok: $1"; }
flunk() { echo "FAIL: $1" >&2; fail=1; }

# run_entrypoint <seconds> <cmd…>: the entrypoint's exit status, or 124 when it still runs after <seconds>.
# Each run gets a fresh $dir, so a process left by one case cannot write into the next one's files.
# "@/x" in the command means "$dir/x"; the entrypoint's /var, /nvidia-setup.sh and /start.sh are moved
# under $dir and $work.
run_entrypoint() {
  local limit=$1 arg args=() tick rc=124; shift
  dir="$(mktemp -d "$work/case.XXXX")"
  mkdir -p "$dir/var/log"
  sed -e "s#/var/#$dir/var/#g" -e "s#/nvidia-setup.sh#$work/nvidia-setup.sh#g" -e "s#/start.sh#$work/start.sh#g" \
    "$entrypoint" > "$dir/entrypoint.sh"
  for arg in "$@"; do args+=("${arg/#@/$dir}"); done
  CASE_DIR="$dir" ENABLE_DIND=true PATH="$work/bin:$PATH" bash "$dir/entrypoint.sh" "${args[@]}" > "$dir/out.log" 2>&1 &
  local pid=$!
  for ((tick = 0; tick < limit * 10; tick++)); do
    kill -0 "$pid" 2>/dev/null || { wait "$pid"; rc=$?; break; }
    sleep 0.1
  done
  [ $rc -eq 124 ] && { kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; }
  # the entrypoint's background jobs (their command lines hold $dir) and the stubs' sleeps
  pkill -f "$dir/" 2>/dev/null
  [ -f "$dir/pids" ] && xargs kill 2>/dev/null < "$dir/pids"
  return $rc
}

# 1. Renter command `docker info`, dockerd answers after 300 ms → the command sees a ready daemon.
STUB_DOCKERD=ready:0.3 run_entrypoint 5 docker info; rc=$?
if [ $rc -eq 0 ]; then pass "an overridden CMD runs after dockerd answers"
else flunk "overridden CMD 'docker info' exited $rc: $(tail -n 1 "$dir/out.log")"; fi

# 2. dockerd fails → the renter command does not run, the container exits non-zero.
STUB_DOCKERD=fail run_entrypoint 5 touch @/cmd-ran; rc=$?
if [ $rc -ne 0 ] && [ $rc -ne 124 ] && [ ! -e "$dir/cmd-ran" ]; then pass "a failed dockerd stops an overridden CMD"
else flunk "failed dockerd: exit $rc, command ran: $([ -e "$dir/cmd-ran" ] && echo yes || echo no)"; fi

# 3. NVIDIA setup fails → the renter command does not run, the container exits non-zero.
STUB_NVIDIA_EXIT=1 STUB_DOCKERD=ready:0 run_entrypoint 5 touch @/cmd-ran; rc=$?
if [ $rc -ne 0 ] && [ $rc -ne 124 ] && [ ! -e "$dir/cmd-ran" ]; then pass "a failed NVIDIA setup stops an overridden CMD"
else flunk "failed NVIDIA setup: exit $rc, command ran: $([ -e "$dir/cmd-ran" ] && echo yes || echo no)"; fi

# 4. Default /start.sh, dockerd answers after 1 s → /start.sh starts first and the pod stays up.
STUB_DOCKERD=ready:1 run_entrypoint 3 "$work/start.sh"; rc=$?
if [ $rc -eq 124 ] && [ -e "$dir/start-before-docker" ]; then pass "/start.sh starts before dockerd answers and the pod stays up"
else flunk "default CMD: exit $rc (124 = still up), started before docker: $([ -e "$dir/start-before-docker" ] && echo yes || echo no)"; fi

# 5. Default /start.sh, dockerd fails → the pod ends non-zero.
STUB_DOCKERD=fail run_entrypoint 5 "$work/start.sh"; rc=$?
if [ $rc -ne 0 ] && [ $rc -ne 124 ]; then pass "a failed dockerd ends a /start.sh pod"
else flunk "default CMD with failed dockerd: exit $rc (124 = pod still up)"; fi

# 6. Default /start.sh, NVIDIA setup fails → the pod ends non-zero.
STUB_NVIDIA_EXIT=1 STUB_DOCKERD=ready:0 run_entrypoint 5 "$work/start.sh"; rc=$?
if [ $rc -ne 0 ] && [ $rc -ne 124 ]; then pass "a failed NVIDIA setup ends a /start.sh pod"
else flunk "default CMD with failed NVIDIA setup: exit $rc (124 = pod still up)"; fi

# 7. containerd dies once → it is started again, the pod stays up.
STUB_CONTAINERD=crash-once STUB_DOCKERD=ready:0 run_entrypoint 3 "$work/start.sh"; rc=$?
if [ $rc -eq 124 ] && [ -e "$dir/containerd-restarted" ]; then pass "a crashed containerd is restarted"
else flunk "crashed containerd: exit $rc (124 = still up), restarted: $([ -e "$dir/containerd-restarted" ] && echo yes || echo no)"; fi

exit "$fail"
