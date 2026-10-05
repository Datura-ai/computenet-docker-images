#!/bin/bash
set -e

CONTAINERD_SOCKET=/var/run/docker/containerd/containerd.sock

# Starts the nested containerd and dockerd and waits until dockerd answers.
# Returns non-zero when the NVIDIA setup fails or dockerd never answers.
start_docker() {
    mkdir -p /var/run /var/lib/docker
    # This entrypoint is the first process after a container (re)start, so any
    # pidfile left by a previous run is stale by definition. Without this,
    # dockerd refuses to start when the recycled PID happens to be alive
    # ("process with PID N is still running") and the container restart-loops
    # (DAH-2341). A stale containerd socket refuses dockerd's first dial, and
    # gRPC then waits out its 1 s backoff before the next one.
    rm -f /var/run/docker.pid "$CONTAINERD_SOCKET"
    echo "Starting Docker daemon..."
    # containerd is started here rather than by dockerd: dockerd dials the
    # containerd it starts itself before its socket exists and retries after
    # gRPC's 1 s backoff, while with --containerd a missing socket is retried
    # every 10 ms. Config: /etc/containerd/config.toml, same paths as before.
    containerd > /var/log/containerd.log 2>&1 &
    dockerd --host=unix:///var/run/docker.sock --containerd="$CONTAINERD_SOCKET" > /var/log/dockerd.log 2>&1 &
    local dockerd_pid=$!

    # dockerd needs ~0.5 s before it can run a GPU container, so the links are ready first
    echo "Preparing NVIDIA device paths for nested Docker..."
    if ! /nvidia-setup.sh; then
        echo "nvidia-setup.sh failed; nested containers would not see the GPU" >&2
        return 1
    fi

    for _ in {1..1500}; do
        if curl -sf --max-time 1 --unix-socket /var/run/docker.sock http://localhost/_ping >/dev/null 2>&1; then
            echo "Docker daemon is ready."
            return 0
        fi
        kill -0 "$dockerd_pid" 2>/dev/null || break
        sleep 0.02
    done

    echo "Docker daemon did not become ready. Recent logs:" >&2
    tail -n 50 /var/log/containerd.log /var/log/dockerd.log >&2 || true
    return 1
}

if [[ "${ENABLE_DIND}" != "true" ]]; then
    exec "$@"
fi

# Because dockerd is started from this ENTRYPOINT rather than CMD, the nested
# daemon comes up even when the caller overrides CMD (lium's validator passes
# the renter's startup command as CMD). That command may call docker at once,
# so it runs only after the daemon answers.
if [[ "$*" != "/start.sh" ]]; then
    start_docker || exit 1
    exec "$@"
fi

# The image's /start.sh brings up sshd and Jupyter, which do not need Docker, so
# it runs beside the daemon's start. A daemon that never comes up ends the pod,
# as it did when the daemon was started first: a DinD pod without Docker must
# not stay rented.
"$@" &
start_sh_pid=$!
if ! start_docker; then
    echo "Nested Docker is not available; stopping the pod." >&2
    kill "$start_sh_pid" 2>/dev/null || true
    exit 1
fi
wait "$start_sh_pid"
