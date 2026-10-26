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

# Kept under /etc: the validator mounts the rental volume over /root after this script.
CLUSTER_SSH_DIR=/etc/lium
CLUSTER_SSH_KEY_FILE=$CLUSTER_SSH_DIR/cluster_ed25519
CLUSTER_SSH_AUTHORIZED_KEYS_FILE=$CLUSTER_SSH_DIR/cluster_authorized_keys
CLUSTER_SSH_CLIENT_CONF=/etc/ssh/ssh_config.d/lium-cluster.conf
CLUSTER_SSHD_CONF=/etc/ssh/sshd_config.d/lium-cluster.conf
CLUSTER_SSH_CHECK_LOG=/var/log/lium-cluster-ssh-check.log
# How long the start-up peer check keeps trying before it writes its verdict. The peers raise their
# overlay and start sshd on their own clock, so the first tries are expected to fail.
CLUSTER_SSH_CHECK_WAIT_SECONDS="${LIUM_CLUSTER_SSH_CHECK_WAIT_SECONDS:-300}"

# How long the fabric gate waits before refusing the pod. A card whose driver is still loading or
# whose link is renegotiating reports no ACTIVE port for a few seconds after boot, and refusing
# there would fail a rental that used to come up; a pod with no device at all still refuses, later.
FABRIC_GATE_ATTEMPTS=5
FABRIC_GATE_RETRY_SECONDS=2

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

    publish_cluster_env
}

await_fabric_env() {
    local attempt=1
    local output
    while true; do
        if output=$(python3 /usr/local/bin/lium-fabric-env); then
            printf '%s' "$output"
            return 0
        fi
        if (( attempt >= FABRIC_GATE_ATTEMPTS )); then
            return 1
        fi
        echo "lium-cluster: no ACTIVE RDMA port yet, retrying in ${FABRIC_GATE_RETRY_SECONDS}s" >&2
        attempt=$((attempt + 1))
        sleep "$FABRIC_GATE_RETRY_SECONDS"
    done
}

publish_cluster_env() {
    # Exporting only reaches what this script execs. A renter almost always arrives over SSH, whose
    # session starts from a clean environment — and NCCL then picks the docker bridge, announces
    # 172.x to its peers and the job hangs or crawls. So the same variables are written where a
    # session will read them: PAM reads /etc/environment, a login shell reads /etc/profile.d, and
    # the nested-container runtime reads CLUSTER_ENV_FILE, because a container the inner
    # docker starts inherits nothing from this process either.
    # The one contract with the workload: the overlay is always called wg0. NCCL and gloo do not
    # pick a second interface on their own, so we name it for them here and the renter never has to.
    # The socket fan-out spreads the bootstrap across flows (measured 7.3x on our fabric).
    local vars=(
        "NCCL_SOCKET_IFNAME=wg0"
        "GLOO_SOCKET_IFNAME=wg0"
        "NCCL_SOCKET_NTHREADS=4"
        "NCCL_NSOCKS_PERTHREAD=8"
    )

    # DAH-2667: which RoCE card and GID carry this pod's fabric, empty on InfiniBand where NCCL needs
    # no help. It is also the fabric GATE — it exits non-zero when no ACTIVE port answers verbs, and
    # a pod without a fabric must not start: NCCL would fall back to TCP over the overlay and the
    # renter would pay cluster price for a job nothing in the logs explains. A crash in it is fatal
    # here for the same reason, which is why its status is checked instead of being piped away.
    # Appended BEFORE the file below is written, so a nested container inherits these too.
    local fabric_env
    if ! fabric_env=$(await_fabric_env); then
        echo "lium-cluster: no usable RDMA fabric in this pod. Refusing to start." >&2
        exit 1
    fi
    if [[ -n "$fabric_env" ]]; then
        mapfile -t -O "${#vars[@]}" vars <<< "$fabric_env"
    fi

    printf '%s\n' "${vars[@]}" > "$CLUSTER_ENV_FILE"
    chmod 644 "$CLUSTER_ENV_FILE"

    # Every name this script can write, cleared before anything is written back. Clearing only what
    # we are about to write would strand a value from a previous boot: a pod restarted on a fabric
    # that no longer pins a GID index would keep serving the old NCCL_IB_GID_INDEX to SSH sessions.
    local managed=(
        NCCL_SOCKET_IFNAME GLOO_SOCKET_IFNAME NCCL_SOCKET_NTHREADS NCCL_NSOCKS_PERTHREAD
        NCCL_IB_HCA NCCL_IB_GID_INDEX
    )
    for name in "${managed[@]}"; do
        sed -i "/^${name}=/d" /etc/environment 2>/dev/null || true
    done

    for var in "${vars[@]}"; do
        export "$var"
        echo "$var" >> /etc/environment
    done

    mkdir -p /etc/profile.d
    {
        echo "# DAH-2620: the cluster overlay this pod is a member of."
        echo "set -a"
        echo ". $CLUSTER_ENV_FILE"
        echo "set +a"
    } > /etc/profile.d/lium-cluster.sh
    chmod 644 /etc/profile.d/lium-cluster.sh

    echo "lium-cluster: wg0 up at $(wg show wg0 2>/dev/null | awk '/interface/{print}')" >&2
}

install_cluster_ssh_identity() {
    # Without this a pod cannot log in to its peers — the renter's key is installed for
    # inbound access only. Every ready-made multi-node launcher needs it: mpirun spawns its remote
    # ranks over ssh, DeepSpeed's default launcher is pdsh, and every nccl-tests recipe is mpirun.
    # The backend mints one keypair for the whole group, so the same login works in every direction.
    local key_b64="${LIUM_CLUSTER_SSH_KEY_B64:-}"
    local authorized_key="${LIUM_CLUSTER_SSH_PUBKEY:-}"
    if [[ -z "$key_b64" || -z "$authorized_key" ]]; then
        return 0
    fi

    # The overlay subnet, read off wg0 before anything is written: the peers' key below is limited
    # to it, so the login is installed only once the subnet is known. It is read rather than
    # hardcoded because the backend owns the address plan, and a copy baked into this image would
    # silently stop matching the day that plan changes.
    local overlay_address overlay_host_pattern
    # `|| true` because `set -o pipefail` is on: without it a missing wg0 kills the whole entrypoint
    # here, which would fail the pod over an SSH convenience instead of degrading.
    overlay_address="$(ip -o -4 addr show wg0 2>/dev/null | awk '{print $4}' | head -1 || true)"
    if [[ -z "$overlay_address" ]]; then
        echo "lium-cluster: wg0 has no address, so the cluster login is not installed (its key could not be limited to the overlay)" >&2
        return 0
    fi
    overlay_host_pattern="${overlay_address%.*}.*"

    # Root-owned, world-readable directory: sshd's StrictModes accepts an AuthorizedKeysFile only
    # when the file and every directory above it are owned by root or the user and writable by
    # nobody else. The private key inside is restricted before it holds anything — ssh refuses a
    # private key other users can read.
    mkdir -p "$CLUSTER_SSH_DIR"
    chmod 755 "$CLUSTER_SSH_DIR"
    install -m 600 /dev/null "$CLUSTER_SSH_KEY_FILE"
    echo "$key_b64" | base64 -d > "$CLUSTER_SSH_KEY_FILE"

    # The peers' login, in a file of its own. `from=` limits it to the overlay: the group shares
    # this one key, and sshd listens on the public port too, so without it anyone holding the key
    # logs in as root from any address. The renter's authorized_keys under /root/.ssh is left to
    # the validator: it writes that file after the mount, and it lands in the mounted volume.
    install -m 644 /dev/null "$CLUSTER_SSH_AUTHORIZED_KEYS_FILE"
    echo "from=\"$overlay_host_pattern\" $authorized_key" > "$CLUSTER_SSH_AUTHORIZED_KEYS_FILE"

    # sshd reads the drop-in directory before the rest of sshd_config (Ubuntu's file opens with
    # `Include /etc/ssh/sshd_config.d/*.conf`), and the FIRST value of an option wins, so this
    # keeps the renter's own authorized_keys and adds ours. The validator's hardening only appends
    # PasswordAuthentication lines at the end of sshd_config, which this does not touch.
    mkdir -p "$(dirname "$CLUSTER_SSHD_CONF")"
    cat > "$CLUSTER_SSHD_CONF" <<EOF
# The Lium cluster login, kept outside /root.
AuthorizedKeysFile .ssh/authorized_keys $CLUSTER_SSH_AUTHORIZED_KEYS_FILE
EOF
    chmod 644 "$CLUSTER_SSHD_CONF"

    # The mesh is private. The renter's own ~/.ssh/config wins over this drop-in.
    mkdir -p "$(dirname "$CLUSTER_SSH_CLIENT_CONF")"
    cat > "$CLUSTER_SSH_CLIENT_CONF" <<EOF
# The Lium cluster overlay.
Host $overlay_host_pattern
    IdentityFile $CLUSTER_SSH_KEY_FILE
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
    LogLevel ERROR
EOF
    chmod 644 "$CLUSTER_SSH_CLIENT_CONF"
}

check_cluster_ssh_peers() {
    # A pod that cannot reach its peers over ssh fails only when the renter's first mpirun/pdsh
    # hangs, hours later and with nothing in the logs. This dials
    # every peer wg0 knows once at start, in the background, and leaves the verdict where the renter
    # and a support person can read it: CLUSTER_SSH_CHECK_LOG, and the container log. It never
    # decides the pod's fate — a peer that is still booting is the normal case for the first tries.
    if [[ ! -s "$CLUSTER_SSH_KEY_FILE" ]]; then
        return 0
    fi
    # Every /32 in the peers' AllowedIPs is a pod of this group; the address plan is the backend's.
    local peers=()
    mapfile -t peers < <(wg show wg0 allowed-ips 2>/dev/null \
        | awk '{for (i = 2; i <= NF; i++) if ($i ~ /\/32$/) {sub(/\/32$/, "", $i); print $i}}' || true)
    if (( ${#peers[@]} == 0 )); then
        echo "lium-cluster: wg0 lists no peers, so there is nothing to ssh-check" >&2
        return 0
    fi

    # setsid, stdin and stdout closed: the check outlives this script's exec into the base
    # entrypoint. stderr is kept — it is the container log, the same place the other lines of this
    # script go. Plain `ssh`, no -i and no -o for the key: the check must take the same path a
    # launcher takes, drop-in config included, or a PASS here would prove nothing about mpirun.
    setsid bash -c '
        log="$1"; wait_seconds="$2"; shift 2
        mkdir -p "$(dirname "$log")"; : > "$log"
        deadline=$(( $(date +%s) + wait_seconds ))
        pending=("$@")
        sleep 1
        while :; do
            still=()
            for peer in "${pending[@]}"; do
                if ssh -o BatchMode=yes -o ConnectTimeout=5 "root@$peer" true 2>/dev/null; then
                    echo "$(date -u +%FT%TZ) ok $peer" >> "$log"
                else
                    still+=("$peer")
                fi
            done
            pending=("${still[@]}")
            if (( ${#pending[@]} == 0 )); then
                echo "$(date -u +%FT%TZ) verdict PASS: every peer answers ssh" >> "$log"
                echo "lium-cluster: ssh to every peer works (see $log)" >&2
                exit 0
            fi
            if (( $(date +%s) >= deadline )); then
                for peer in "${pending[@]}"; do
                    echo "$(date -u +%FT%TZ) FAIL $peer (no ssh login after ${wait_seconds}s)" >> "$log"
                done
                echo "$(date -u +%FT%TZ) verdict FAIL: ${#pending[@]} peer(s) never answered ssh; mpirun and pdsh will hang on them" >> "$log"
                echo "lium-cluster: ssh to ${#pending[@]} peer(s) FAILED (see $log)" >&2
                exit 1
            fi
            sleep 5
        done
    ' lium-cluster-ssh-check "$CLUSTER_SSH_CHECK_LOG" "$CLUSTER_SSH_CHECK_WAIT_SECONDS" "${peers[@]}" \
        > /dev/null < /dev/null &
    disown
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
check_cluster_ssh_peers
configure_nested_docker

# Hand off to the base image's own entrypoint, which starts the inner Docker daemon and the rest of
# the pod's services. Replacing it outright is what left a cluster pod without dockerd.
exec /pytorch-entrypoint.sh "$@"
