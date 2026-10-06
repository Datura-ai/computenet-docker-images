#!/usr/bin/env bash
# Does the cluster login work once the validator has mounted the volume over /root?
#
# Two containers on one docker network stand in for two pods of a group rental. Each runs the real
# entrypoint (wg-quick, wg, ip and the fabric gate stubbed; sshd and ssh REAL, from openssh-server),
# then the test does what the validator does next, in the validator's order: mounts a filesystem
# OVER /root (a tmpfs here, gocryptfs `-nonempty` in prod) and writes the renter's authorized_keys
# into the mounted tree. Then node a dials node b the way mpirun and pdsh do: plain `ssh root@<peer>`.
#
# With TEST_OLD_ENTRYPOINT=<file> the same run is made with that entrypoint and the login is
# EXPECTED TO FAIL — that is the regression this test exists for (the key, the authorized key and the
# Host block all lived under /root/.ssh and the mount hid them).
#
#   bash templates/lium-cluster/tests/test_peer_login.sh
#   TEST_OLD_ENTRYPOINT=/path/to/main/entrypoint.sh bash templates/lium-cluster/tests/test_peer_login.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
RUN_ID="$$"
NET="lium-cluster-peer-test-${RUN_ID}"
# a second network both nodes are also on, standing in for the public side of the pod: the shared
# key must NOT open a peer from there, only from the overlay
PUBLIC_NET="lium-cluster-peer-test-public-${RUN_ID}"
IMAGE="${TEST_SSHD_IMAGE:-lium-cluster-test-sshd:24.04}"
# a /24 of its own per run, so two runs on one docker host do not collide
OCTET=$(( RUN_ID % 200 + 20 ))
SUBNET="172.30.${OCTET}.0/24"
NODE_A_IP="172.30.${OCTET}.2"
NODE_B_IP="172.30.${OCTET}.3"
PUBLIC_SUBNET="172.31.${OCTET}.0/24"
NODE_B_PUBLIC_IP="172.31.${OCTET}.3"
WORK="$(mktemp -d)"

failures=0
fail() { echo "  FAIL: $*"; failures=$((failures + 1)); }
pass() { echo "  ok: $*"; }

cleanup() {
    docker rm -f "node-a-${RUN_ID}" "node-b-${RUN_ID}" >/dev/null 2>&1
    docker network rm "$NET" "$PUBLIC_NET" >/dev/null 2>&1
    rm -rf "$WORK"
}
trap cleanup EXIT

# ubuntu:24.04 with a real sshd and ssh; nothing else of the pod image matters to the login.
docker image inspect "$IMAGE" >/dev/null 2>&1 || docker build -q -t "$IMAGE" - <<'DOCKERFILE' >/dev/null
FROM ubuntu:24.04
RUN apt-get update && apt-get install -y --no-install-recommends openssh-server openssh-client \
    && rm -rf /var/lib/apt/lists/*
DOCKERFILE

docker network create --subnet "$SUBNET" "$NET" >/dev/null
docker network create --subnet "$PUBLIC_SUBNET" "$PUBLIC_NET" >/dev/null

# The backend mints one keypair per group; the renter brings their own.
ssh-keygen -q -t ed25519 -N '' -C lium-cluster -f "$WORK/cluster_key"
ssh-keygen -q -t ed25519 -N '' -C renter -f "$WORK/renter_key"
CLUSTER_KEY_B64="$(base64 < "$WORK/cluster_key" | tr -d '\n')"
CLUSTER_PUBKEY="$(cat "$WORK/cluster_key.pub")"
RENTER_PUBKEY="$(cat "$WORK/renter_key.pub")"
WIREGUARD_CONF_B64="$(printf '[Interface]\nAddress = %s/24\n' "$NODE_A_IP" | base64 | tr -d '\n')"

# One pod: stubs for what a real pod gets from wg-quick and the fabric, then the entrypoint as PID 1,
# whose base-entrypoint stand-in starts sshd exactly as the base image's start.sh does.
start_node() {
    local name="$1" ip="$2" peer_ip="$3" entrypoint="$4"
    # CAP_SYS_ADMIN for the tmpfs mount over /root below (what the validator's gocryptfs exec needs
    # too); nothing wider. A host whose docker-default AppArmor profile denies mount regardless sets
    # TEST_MOUNT_OPTS="--cap-add SYS_ADMIN --security-opt apparmor=unconfined".
    # shellcheck disable=SC2086
    docker run -d --name "$name" --hostname "$name" ${TEST_MOUNT_OPTS:---cap-add SYS_ADMIN} \
        --network "$NET" --ip "$ip" \
        -v "${entrypoint}:/template/entrypoint.sh:ro" \
        -e LIUM_WIREGUARD_CONF_B64="$WIREGUARD_CONF_B64" \
        -e LIUM_CLUSTER_SSH_KEY_B64="$CLUSTER_KEY_B64" \
        -e LIUM_CLUSTER_SSH_PUBKEY="$CLUSTER_PUBKEY" \
        -e LIUM_CLUSTER_SSH_CHECK_WAIT_SECONDS=60 \
        -e TEST_SELF_IP="$ip" -e TEST_PEER_IP="$peer_ip" \
        "$IMAGE" bash -c '
            printf "#!/bin/sh\nexit 0\n" > /usr/local/bin/wg-quick
            printf "#!/bin/sh\ncase \"\$3\" in allowed-ips) printf \"pk\\\\t%s/32\\\\n\";; esac\nexit 0\n" "$TEST_PEER_IP" > /usr/local/bin/wg
            printf "#!/bin/sh\necho \"5: wg0    inet %s/24 scope global wg0\"\n" "$TEST_SELF_IP" > /usr/local/bin/ip
            printf "#!/bin/sh\nexit 0\n" > /usr/local/bin/python3
            printf "#!/bin/sh\nssh-keygen -A >/dev/null\nmkdir -p /run/sshd\nservice ssh start\nexec sleep infinity\n" > /pytorch-entrypoint.sh
            chmod +x /usr/local/bin/wg-quick /usr/local/bin/wg /usr/local/bin/ip /usr/local/bin/python3 /pytorch-entrypoint.sh
            exec bash /template/entrypoint.sh
        ' >/dev/null
}

wait_for_sshd() {
    local name="$1"
    for _ in $(seq 1 40); do
        docker exec "$name" pgrep -x sshd >/dev/null 2>&1 && return 0
        sleep 0.5
    done
    return 1
}

# What the validator does after the container is up, in its order: the mount over /root, then the
# renter's keys into the mounted tree.
mount_volume_over_root() {
    local name="$1"
    # mode=700: what /root is in the pod image; a bare tmpfs would be 1777 and sshd's StrictModes
    # would refuse every key under it, which is not the failure under test
    docker exec "$name" mount -t tmpfs -o mode=700 tmpfs /root || return 1
    docker exec -e RENTER_PUBKEY="$RENTER_PUBKEY" "$name" sh -c \
        'mkdir -p /root/.ssh && chmod 700 /root/.ssh && echo "$RENTER_PUBKEY" >> /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys'
}

# A run: two nodes with the given entrypoint, the validator's steps, then the logins that matter.
# Sets LOGIN_RC (a → b as a launcher would), NOPROMPT_RC (the same with the host-key prompt
# switched off on the command line, which isolates the key from the Host block), PUBLIC_RC (the
# cluster key offered to b's PUBLIC address, from a's public address — sshd must refuse it),
# RENTER_RC (the renter's own key still opens b; -F /dev/null so no config adds our key to that
# attempt), CHECK_LOG (node a's start-up verdict).
run_cluster() {
    local entrypoint="$1"
    docker rm -f "node-a-${RUN_ID}" "node-b-${RUN_ID}" >/dev/null 2>&1
    start_node "node-a-${RUN_ID}" "$NODE_A_IP" "$NODE_B_IP" "$entrypoint"
    start_node "node-b-${RUN_ID}" "$NODE_B_IP" "$NODE_A_IP" "$entrypoint"
    wait_for_sshd "node-a-${RUN_ID}" || { echo "node a never started sshd"; docker logs "node-a-${RUN_ID}"; return 1; }
    wait_for_sshd "node-b-${RUN_ID}" || { echo "node b never started sshd"; docker logs "node-b-${RUN_ID}"; return 1; }
    mount_volume_over_root "node-a-${RUN_ID}" || return 1
    mount_volume_over_root "node-b-${RUN_ID}" || return 1
    # the public side, joined after the entrypoint ran so `ip … wg0` (stubbed) is not what changes
    docker network connect "$PUBLIC_NET" "node-a-${RUN_ID}" || return 1
    docker network connect --ip "$NODE_B_PUBLIC_IP" "$PUBLIC_NET" "node-b-${RUN_ID}" || return 1

    LOGIN_OUT="$(docker exec "node-a-${RUN_ID}" ssh -o BatchMode=yes -o ConnectTimeout=5 "root@${NODE_B_IP}" hostname 2>&1)"
    LOGIN_RC=$?
    PUBLIC_OUT="$(docker exec "node-a-${RUN_ID}" ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -i /etc/lium/cluster_ed25519 "root@${NODE_B_PUBLIC_IP}" hostname 2>&1)"
    PUBLIC_RC=$?
    NOPROMPT_OUT="$(docker exec "node-a-${RUN_ID}" ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "root@${NODE_B_IP}" hostname 2>&1)"
    NOPROMPT_RC=$?
    docker cp "$WORK/renter_key" "node-a-${RUN_ID}:/tmp/renter_key" >/dev/null
    RENTER_OUT="$(docker exec "node-a-${RUN_ID}" ssh -F /dev/null -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -i /tmp/renter_key "root@${NODE_B_IP}" hostname 2>&1)"
    RENTER_RC=$?
    CHECK_LOG=""
    for _ in $(seq 1 120); do
        CHECK_LOG="$(docker exec "node-a-${RUN_ID}" cat /var/log/lium-cluster-ssh-check.log 2>/dev/null)"
        [[ "$CHECK_LOG" == *verdict* ]] && break
        sleep 0.5
    done
    return 0
}

echo "== two pods, the volume mounted over /root after the entrypoint: a launcher can log in to its peer =="
if run_cluster "${HERE}/../entrypoint.sh"; then
    [[ "$LOGIN_RC" == "0" && "$LOGIN_OUT" == "node-b-${RUN_ID}" ]] \
        && pass "ssh root@peer hostname → the peer's hostname, no key, no prompt" \
        || fail "ssh to the peer: rc ${LOGIN_RC}, said: ${LOGIN_OUT}"
    # the key is the whole group's and sshd listens on the public port too: from off the overlay it opens nothing
    [[ "$PUBLIC_RC" != "0" && "$PUBLIC_OUT" == *"Permission denied"* ]] \
        && pass "the cluster key is refused at the peer's public address (from= keeps it to the overlay)" \
        || fail "expected 'Permission denied' from the public side, got rc ${PUBLIC_RC}: ${PUBLIC_OUT}"
    [[ "$RENTER_RC" == "0" ]] \
        && pass "the renter's own key still opens the peer (sshd reads both authorized_keys files)" \
        || fail "the renter's key was refused: ${RENTER_OUT}"
    [[ "$CHECK_LOG" == *"ok ${NODE_B_IP}"*"verdict PASS"* ]] \
        && pass "the start-up check on node a reports PASS for its peer" \
        || fail "node a's check log reads: ${CHECK_LOG}"
    docker logs "node-a-${RUN_ID}" 2>&1 | grep -q "lium-cluster: ssh to every peer works" \
        && pass "the verdict is in the container log too" \
        || fail "no verdict line in node a's container log"
else
    fail "the cluster never came up"
fi

if [[ -n "${TEST_OLD_ENTRYPOINT:-}" ]]; then
    echo "== the same with the entrypoint from main: the mount hides the login (the regression this guards) =="
    if run_cluster "$TEST_OLD_ENTRYPOINT"; then
        # the mount hid /root/.ssh/config, so a launcher stops at the host-key prompt …
        [[ "$LOGIN_RC" != "0" && "$LOGIN_OUT" == *"Host key verification failed"* ]] \
            && pass "a launcher's ssh stops at the host-key prompt: the Host block is gone with the mount" \
            || fail "expected 'Host key verification failed', got rc ${LOGIN_RC}: ${LOGIN_OUT}"
        # … and with the prompt switched off by hand the key is gone too
        [[ "$NOPROMPT_RC" != "0" && "$NOPROMPT_OUT" == *"Permission denied"* ]] \
            && pass "with the prompt switched off the peer refuses the login: the key is gone with the mount" \
            || fail "expected 'Permission denied', got rc ${NOPROMPT_RC}: ${NOPROMPT_OUT}"
        [[ "$RENTER_RC" == "0" ]] && pass "the renter's own key works either way" || fail "the renter's key was refused: ${RENTER_OUT}"
    else
        fail "the old-entrypoint cluster never came up"
    fi
fi

if (( failures )); then
    echo "${failures} failing check(s)"
    exit 1
fi
echo "all checks passed"
