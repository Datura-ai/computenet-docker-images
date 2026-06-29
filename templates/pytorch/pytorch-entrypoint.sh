#!/bin/bash
set -e

start_docker() {
    if [[ "${ENABLE_DIND}" != "true" ]]; then
        return
    fi

    echo "Preparing NVIDIA device paths for nested Docker..."
    /nvidia-setup.sh

    mkdir -p /var/run /var/lib/docker
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
exec /start.sh
