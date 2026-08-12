#!/usr/bin/env bash
# DAH-2620: raise the cluster overlay, point NCCL at it, then hand off to the workload.
#
# The validator injects LIUM_WIREGUARD_CONF_B64 (this node's wg-quick config, base64) into every pod
# of a group rental. A single-node rental has no such variable, so this whole block is skipped and
# the pod behaves exactly like an ordinary one.
set -euo pipefail

# The overlay settings, in the one place every consumer reads them from: SSH sessions, login shells
# and the nested-container runtime. Written only while the pod is a cluster member.
CLUSTER_ENV_FILE=/etc/lium-cluster.env

# The overlay subnet the backend hands out (CLUSTER_OVERLAY_CIDR). A launcher dialling a peer here
# has never seen it before, and there is no host to impersonate on a private mesh.
CLUSTER_OVERLAY_HOST_PATTERN="10.42.0.*"

raise_cluster_overlay() {
    local conf_b64="${LIUM_WIREGUARD_CONF_B64:-}"
    if [[ -z "$conf_b64" ]]; then
        echo "lium-cluster: no cluster config injected, running as a standalone node" >&2
        return 0
    fi

    mkdir -p /etc/wireguard
    # Create the file restricted FIRST, then write into it: the config holds this node's private
    # key. Done with `install` rather than `umask` on purpose — a umask set here would survive into
    # `exec "$@"` below and silently make every file the customer's job writes mode 600.
    install -m 600 /dev/null /etc/wireguard/wg0.conf
    echo "$conf_b64" | base64 -d > /etc/wireguard/wg0.conf

    # wg-quick needs NET_ADMIN, which a group-rental pod is given; if it is missing we surface it
    # rather than letting NCCL silently fall back to the unreachable bridge address later.
    if ! wg-quick up wg0; then
        echo "lium-cluster: failed to bring up wg0 — the node cannot join the cluster" >&2
        exit 1
    fi

    # The one contract with the workload: the overlay is always called wg0. NCCL and gloo do not
    # pick a second interface on their own, so we name it for them here and the renter never has to.
    export NCCL_SOCKET_IFNAME=wg0
    export GLOO_SOCKET_IFNAME=wg0
    # Bootstrap rides one flow otherwise; these fan it across the wire (measured 7.3x on our fabric).
    export NCCL_SOCKET_NTHREADS=4
    export NCCL_NSOCKS_PERTHREAD=8

    publish_cluster_env
}

publish_cluster_env() {
    # Exporting only reaches what this script execs. A renter almost always arrives over SSH, whose
    # session starts from a clean environment — and NCCL then picks the docker bridge, announces
    # 172.x to its peers and the job hangs or crawls. So the same variables are written where a
    # session will read them: PAM reads /etc/environment, a login shell reads /etc/profile.d, and
    # (DAH-2664) the nested-container runtime reads CLUSTER_ENV_FILE, because a container the inner
    # docker starts inherits nothing from this process either.
    local vars=(
        "NCCL_SOCKET_IFNAME=wg0"
        "GLOO_SOCKET_IFNAME=wg0"
        "NCCL_SOCKET_NTHREADS=4"
        "NCCL_NSOCKS_PERTHREAD=8"
    )

    printf '%s\n' "${vars[@]}" > "$CLUSTER_ENV_FILE"
    chmod 644 "$CLUSTER_ENV_FILE"

    for var in "${vars[@]}"; do
        grep -q "^${var%%=*}=" /etc/environment 2>/dev/null || echo "$var" >> /etc/environment
    done

    mkdir -p /etc/profile.d
    {
        echo "# DAH-2620: the cluster overlay this pod is a member of."
        for var in "${vars[@]}"; do
            echo "export $var"
        done
    } > /etc/profile.d/lium-cluster.sh
    chmod 644 /etc/profile.d/lium-cluster.sh

    echo "lium-cluster: wg0 up at $(wg show wg0 2>/dev/null | awk '/interface/{print}')" >&2
}

install_cluster_ssh_identity() {
    # DAH-2664: without this a pod cannot log in to its peers — the renter's key is installed for
    # inbound access only. Every ready-made multi-node launcher needs it: mpirun spawns its remote
    # ranks over ssh, DeepSpeed's default launcher is pdsh, and every nccl-tests recipe is mpirun.
    # The backend mints one keypair for the whole group, so the same login works in every direction.
    local key_b64="${LIUM_CLUSTER_SSH_KEY_B64:-}"
    local authorized_key="${LIUM_CLUSTER_SSH_PUBKEY:-}"
    if [[ -z "$key_b64" || -z "$authorized_key" ]]; then
        return 0
    fi

    mkdir -p /root/.ssh
    chmod 700 /root/.ssh
    # Restricted before it holds anything: ssh refuses a private key other users can read.
    install -m 600 /dev/null /root/.ssh/id_ed25519
    echo "$key_b64" | base64 -d > /root/.ssh/id_ed25519

    # Appended, never written over: the validator puts the renter's own key in the same file, and
    # the two execs race.
    touch /root/.ssh/authorized_keys
    chmod 600 /root/.ssh/authorized_keys
    grep -qxF "$authorized_key" /root/.ssh/authorized_keys || echo "$authorized_key" >> /root/.ssh/authorized_keys

    # A launcher fails outright on an unknown host key, and nothing on this private mesh can be
    # impersonated — the peers are exactly the pods WireGuard let in.
    cat > /root/.ssh/config <<EOF
Host $CLUSTER_OVERLAY_HOST_PATTERN
    IdentityFile /root/.ssh/id_ed25519
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
    LogLevel ERROR
EOF
    chmod 600 /root/.ssh/config
}

configure_nested_docker() {
    # The renter's own image runs under the pod's inner daemon, and RDMA there needs devices, the
    # IPC_LOCK capability and an unlimited memlock. Docker can default the ulimit and nothing else,
    # so the rest arrives through a default runtime that edits the OCI spec (lium-rdma-runc).
    # The base image ships a daemon.json of its own (the nvidia runtime lives there), so this
    # merges into whatever is already on disk rather than replacing it.
    mkdir -p /etc/docker
    python3 - <<'PY'
import json
import os

CONFIG_PATH = "/etc/docker/daemon.json"

config = {}
if os.path.isfile(CONFIG_PATH):
    with open(CONFIG_PATH) as handle:
        config = json.load(handle) or {}

config.setdefault("runtimes", {})["lium-rdma"] = {"path": "/usr/local/bin/lium-rdma-runc"}
config["default-runtime"] = "lium-rdma"
config.setdefault("default-ulimits", {})["memlock"] = {"Name": "memlock", "Hard": -1, "Soft": -1}

with open(CONFIG_PATH, "w") as handle:
    json.dump(config, handle, indent=4)
PY
}

raise_cluster_overlay
install_cluster_ssh_identity
configure_nested_docker

# Hand off to the base image's own entrypoint, which starts the inner Docker daemon and the rest of
# the pod's services. Replacing it outright is what left a cluster pod without dockerd.
exec /pytorch-entrypoint.sh "$@"
