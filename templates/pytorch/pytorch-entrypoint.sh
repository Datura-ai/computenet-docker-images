#!/bin/bash
set -e

start_docker() {
    if [[ "${ENABLE_DIND}" != "true" ]]; then
        return
    fi

    echo "Preparing NVIDIA device paths for nested Docker..."
    /nvidia-setup.sh

    mkdir -p /var/run /var/lib/docker
    # This entrypoint is the first process after a container (re)start, so any
    # pidfile left by a previous run is stale by definition. Without this,
    # dockerd refuses to start when the recycled PID happens to be alive
    # ("process with PID N is still running") and the container restart-loops
    # (DAH-2341).
    rm -f /var/run/docker.pid
    echo "Starting Docker daemon..."
    dockerd --host=unix:///var/run/docker.sock > /var/log/dockerd.log 2>&1 &

    for _ in {1..30}; do
        if docker info >/dev/null 2>&1; then
            echo "Docker daemon is ready."
            return
        fi
        sleep 1
    done

    echo "Docker daemon did not become ready. Recent dockerd logs:"
    tail -100 /var/log/dockerd.log || true
    exit 1
}

start_docker

# Exec whatever command was passed (the image CMD, or a startup command the
# caller appended to `docker run`). Because dockerd is started from this
# ENTRYPOINT rather than CMD, the nested daemon comes up even when the caller
# overrides CMD (e.g. lium's validator appends the renter's startup command).
exec "$@"
