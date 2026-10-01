#!/bin/bash
set -e

CONTAINERD_SOCKET=/var/run/docker/containerd/containerd.sock

# Runs in the background: sshd and Jupyter in CMD must not wait for the nested
# daemon, so a dockerd that fails to start leaves a pod without Docker instead
# of a dead pod.
start_docker() {
    set +e
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
    /nvidia-setup.sh || echo "WARNING: nvidia-setup.sh failed; nested containers may not see the GPU" >&2

    for _ in {1..1500}; do
        if curl -sf --max-time 1 --unix-socket /var/run/docker.sock http://localhost/_ping >/dev/null 2>&1; then
            echo "Docker daemon is ready."
            # stay dockerd's parent: a later crash gets logged, and a renter CMD
            # that never reaps children is not left with a zombie
            wait "$dockerd_pid"
            echo "Docker daemon exited with status $?"
            return
        fi
        kill -0 "$dockerd_pid" 2>/dev/null || break
        sleep 0.02
    done

    echo "Docker daemon did not become ready; the pod runs without Docker. Recent logs:"
    tail -n 50 /var/log/containerd.log /var/log/dockerd.log
}

if [[ "${ENABLE_DIND}" == "true" ]]; then
    start_docker &
fi

# Exec whatever command was passed (the image CMD, or a startup command the
# caller appended to `docker run`). Because dockerd is started from this
# ENTRYPOINT rather than CMD, the nested daemon comes up even when the caller
# overrides CMD (e.g. lium's validator appends the renter's startup command).
exec "$@"
