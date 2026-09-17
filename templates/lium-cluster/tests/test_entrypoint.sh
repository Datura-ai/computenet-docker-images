#!/usr/bin/env bash
# Contract tests for templates/lium-cluster/entrypoint.sh. The entrypoint writes to /etc and execs
# the base image's start script, so it runs inside a throwaway container with wg-quick, wg, ip, ssh
# and /pytorch-entrypoint.sh stubbed — what is under test is where the overlay settings and the
# cluster login end up, with which permissions, and that nothing of ours depends on /root: the
# validator mounts the rental volume over /root AFTER the entrypoint (DAH-3060), which the mount
# scenario below reproduces with a tmpfs (it needs CAP_SYS_ADMIN in the test container, so it is
# skipped when docker refuses the mount). The peer login itself, with a real sshd, is
# tests/test_peer_login.sh.
#
#   bash templates/lium-cluster/tests/test_entrypoint.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
IMAGE="${TEST_BASE_IMAGE:-ubuntu:24.04}"

# A cluster pod is dispatched with these three; a standalone pod with none of them.
WIREGUARD_CONF_B64="$(printf '[Interface]\nAddress = 10.42.0.1/24\n' | base64)"
# not a key: the entrypoint only decodes and places it, and a real-looking header trips secret scans
SSH_PRIVATE_KEY_B64="$(printf 'FAKE-CLUSTER-PRIVATE-KEY-FOR-TESTS\n' | base64)"
SSH_AUTHORIZED_KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIfake lium-cluster"

# Runs the entrypoint in a container and prints what it left behind, one fact per line.
run_entrypoint() {
    docker run --rm -i "$@" -v "${HERE}/..:/template:ro" "${IMAGE}" bash -s <<'IN_CONTAINER'
set -uo pipefail
mkdir -p /usr/local/bin
printf '#!/bin/sh\nexit 0\n' > /usr/local/bin/wg-quick
# `wg show wg0 allowed-ips`: the peers of this group, one /32 each, plus a wider route nobody dials
printf '#!/bin/sh\ncase "$3" in allowed-ips) printf "pk1\\t10.42.0.2/32\\npk2\\t10.42.0.3/32 10.42.1.0/24\\n";; esac\nexit 0\n' > /usr/local/bin/wg
# ssh: records every peer it was asked to dial; TEST_SSH_PEER_DOWN names one that never answers
printf '#!/bin/sh\necho "$*" >> /tmp/ssh-calls\nfor a in "$@"; do case "$a" in root@*) peer=${a#root@};; esac; done\n[ -n "${TEST_SSH_PEER_DOWN:-}" ] && [ "$peer" = "$TEST_SSH_PEER_DOWN" ] && exit 255\nexit 0\n' > /usr/local/bin/ssh
# what `ip` reports once the real wg-quick has raised the interface from the injected config
if [ -n "${TEST_IP_FAILS:-}" ]; then
  printf '#!/bin/sh\necho "Device wg0 does not exist." >&2\nexit 1\n' > /usr/local/bin/ip
else
  printf '#!/bin/sh\necho "5: wg0    inet 10.42.0.1/24 scope global wg0"\n' > /usr/local/bin/ip
fi
# python3 runs both configure_nested_docker's script and lium-fabric-env, the fabric gate.
# Silent + status 0 is what the gate does on an InfiniBand host; a RoCE host prints the two vars.
if [ -n "${TEST_NO_FABRIC:-}" ]; then
  printf '#!/bin/sh\ncase "$1" in *lium-fabric-env) exit 1;; esac\nexit 0\n' > /usr/local/bin/python3
elif [ -n "${TEST_FABRIC_FLAPS:-}" ]; then
  # a card whose link is still coming up: no ACTIVE port for the first two asks, fine on the third
  printf '#!/bin/sh\ncase "$1" in *lium-fabric-env) n=$(cat /tmp/gate-calls 2>/dev/null || echo 0); n=$((n+1)); echo $n > /tmp/gate-calls; [ "$n" -lt 3 ] && exit 1;; esac\nexit 0\n' > /usr/local/bin/python3
elif [ -n "${TEST_ROCE_FABRIC:-}" ]; then
  printf '#!/bin/sh\ncase "$1" in *lium-fabric-env) echo "NCCL_IB_HCA==mlx5_0:1"; echo "NCCL_IB_GID_INDEX=3";; esac\nexit 0\n' > /usr/local/bin/python3
else
  printf '#!/bin/sh\nexit 0\n' > /usr/local/bin/python3
fi
printf '#!/bin/sh\necho handed-off-to-base-entrypoint\n' > /pytorch-entrypoint.sh
if [ -n "${TEST_RESTORED_HOME:-}" ]; then      # a backup restored into /root before start
  mkdir -p /root/.ssh
  echo "CUSTOMERS-OWN-PRIVATE-KEY" > /root/.ssh/id_ed25519
  printf 'Host *\n    StrictHostKeyChecking yes\nHost customers-own-host\n' > /root/.ssh/config
fi
chmod +x /usr/local/bin/wg-quick /usr/local/bin/wg /usr/local/bin/ip /usr/local/bin/ssh /usr/local/bin/python3 /pytorch-entrypoint.sh

bash /template/entrypoint.sh >/tmp/out.log 2>&1
echo "exit_status=$?"
if [ -n "${TEST_MOUNT_OVER_ROOT:-}" ]; then
  # What the validator does next on an encrypted rental: a `docker exec` mounts the plaintext OVER
  # /root (`gocryptfs … -nonempty`), then another writes the renter's keys into the mounted tree.
  mount -t tmpfs -o mode=700 tmpfs /root && echo "mounted_over_root=1"
  mkdir -p /root/.ssh && echo "RENTERS-OWN-KEY" >> /root/.ssh/authorized_keys
fi
# the peer check runs in the background and writes its verdict when every peer answered or the wait ran out
if [ -s /etc/lium/cluster_ed25519 ]; then
  for _ in $(seq 1 60); do grep -q verdict /var/log/lium-cluster-ssh-check.log 2>/dev/null && break; sleep 0.5; done
fi
echo "handed_off=$(grep -c handed-off-to-base-entrypoint /tmp/out.log)"
echo "cluster_env=$(cat /etc/lium-cluster.env 2>/dev/null | tr '\n' ',')"
echo "etc_environment_has_ifname=$(grep -c '^NCCL_SOCKET_IFNAME=wg0$' /etc/environment 2>/dev/null)"
echo "login_shell_ifname=$(env -i sh -c '. /etc/profile.d/lium-cluster.sh 2>/dev/null; echo ${NCCL_SOCKET_IFNAME:-}')"
echo "login_shell_gid_index=$(env -i sh -c '. /etc/profile.d/lium-cluster.sh 2>/dev/null; echo ${NCCL_IB_GID_INDEX:-}')"
echo "etc_environment_has_hca=$(grep -c '^NCCL_IB_HCA==mlx5_0:1$' /etc/environment 2>/dev/null)"
echo "gate_calls=$(cat /tmp/gate-calls 2>/dev/null)"
echo "private_key=$(cat /etc/lium/cluster_ed25519 2>/dev/null | head -1)"
echo "private_key_mode=$(stat -c '%a' /etc/lium/cluster_ed25519 2>/dev/null)"
echo "cluster_dir_mode=$(stat -c '%a' /etc/lium 2>/dev/null)"
echo "cluster_authorized_keys=$(cat /etc/lium/cluster_authorized_keys 2>/dev/null | tr '\n' ',')"
echo "cluster_authorized_keys_mode=$(stat -c '%a' /etc/lium/cluster_authorized_keys 2>/dev/null)"
echo "sshd_dropin=$(grep -v '^#' /etc/ssh/sshd_config.d/lium-cluster.conf 2>/dev/null | tr '\n' ',')"
echo "ssh_config=$(grep -v '^#' /etc/ssh/ssh_config.d/lium-cluster.conf 2>/dev/null | tr -d ' ' | tr '\n' ',')"
echo "root_ssh_entries=$(ls -A /root/.ssh 2>/dev/null | tr '\n' ',')"
echo "renter_authorized_keys=$(cat /root/.ssh/authorized_keys 2>/dev/null | tr '\n' ',')"
echo "customer_key_kept=$(cat /root/.ssh/id_ed25519 2>/dev/null)"
echo "customer_config_kept=$(cat /root/.ssh/config 2>/dev/null | tr -d ' ' | tr '\n' ',')"
echo "ssh_calls=$(sort -u /tmp/ssh-calls 2>/dev/null | tr -d '\n' | tr -s ' ')"
echo "ssh_check_log=$(cut -d' ' -f2- /var/log/lium-cluster-ssh-check.log 2>/dev/null | tr '\n' ';')"
echo "ssh_check_stderr=$(grep -c 'lium-cluster: ssh to' /tmp/out.log)"
IN_CONTAINER
}

failures=0
fail() { echo "  FAIL: $*"; failures=$((failures + 1)); }
pass() { echo "  ok: $*"; }
fact() { grep "^$1=" <<<"${RESULT}" | cut -d= -f2-; }

echo "== a cluster pod: overlay settings published and the shared login installed under /etc =="
RESULT="$(run_entrypoint \
    -e LIUM_WIREGUARD_CONF_B64="${WIREGUARD_CONF_B64}" \
    -e LIUM_CLUSTER_SSH_KEY_B64="${SSH_PRIVATE_KEY_B64}" \
    -e LIUM_CLUSTER_SSH_PUBKEY="${SSH_AUTHORIZED_KEY}")"

[[ "$(fact exit_status)" == "0" ]] && pass "entrypoint succeeded" || fail "exit $(fact exit_status)"
[[ "$(fact handed_off)" == "1" ]] && pass "handed off to the base entrypoint" || fail "never reached the base entrypoint"
# DAH-2664 item 1: the file the nested-container runtime reads, since a nested container inherits
# nothing from this process.
[[ "$(fact cluster_env)" == "NCCL_SOCKET_IFNAME=wg0,GLOO_SOCKET_IFNAME=wg0,NCCL_SOCKET_NTHREADS=4,NCCL_NSOCKS_PERTHREAD=8," ]] \
    && pass "the overlay settings are published for nested containers" \
    || fail "cluster env file reads: $(fact cluster_env)"
[[ "$(fact etc_environment_has_ifname)" == "1" ]] && pass "an SSH session still reads them too" || fail "/etc/environment lost the settings"
[[ "$(fact login_shell_ifname)" == "wg0" ]] && pass "a login shell reads them too" || fail "a login shell got: $(fact login_shell_ifname)"
# DAH-2664 item 3: without a private key and the matching authorized key, mpirun cannot start a
# rank on a peer. DAH-3060: none of it under /root, which the validator mounts over afterwards.
[[ "$(fact private_key)" == "FAKE-CLUSTER-PRIVATE-KEY-FOR-TESTS" ]] && pass "the cluster private key is installed" || fail "private key reads: $(fact private_key)"
[[ "$(fact private_key_mode)" == "600" ]] && pass "the private key is unreadable to others" || fail "private key mode $(fact private_key_mode)"
# sshd's StrictModes: the keys file and its directory are root-owned and writable by nobody else
[[ "$(fact cluster_dir_mode)" == "755" ]] && pass "/etc/lium is root's, not writable by others" || fail "/etc/lium mode $(fact cluster_dir_mode)"
[[ "$(fact cluster_authorized_keys)" == "${SSH_AUTHORIZED_KEY}," ]] && pass "the peers' login is authorized" || fail "cluster_authorized_keys reads: $(fact cluster_authorized_keys)"
[[ "$(fact cluster_authorized_keys_mode)" == "644" ]] && pass "sshd may read the peers' login" || fail "cluster_authorized_keys mode $(fact cluster_authorized_keys_mode)"
[[ "$(fact sshd_dropin)" == "AuthorizedKeysFile .ssh/authorized_keys /etc/lium/cluster_authorized_keys," ]] \
    && pass "sshd reads the renter's authorized_keys AND ours" \
    || fail "sshd drop-in reads: $(fact sshd_dropin)"
[[ "$(fact ssh_config)" == "Host10.42.0.*,IdentityFile/etc/lium/cluster_ed25519,StrictHostKeyCheckingno,UserKnownHostsFile/dev/null,LogLevelERROR," ]] \
    && pass "a peer on the overlay is dialled with our key and without a fingerprint prompt" \
    || fail "ssh config reads: $(fact ssh_config)"
[[ -z "$(fact root_ssh_entries)" ]] && pass "nothing was written under /root/.ssh" || fail "/root/.ssh holds: $(fact root_ssh_entries)"
# the start-up check dialled every /32 peer wg0 knows, and only those, and left a verdict
[[ "$(fact ssh_calls)" == *"root@10.42.0.2 true"*"root@10.42.0.3 true"* && "$(fact ssh_calls)" != *"10.42.1."* ]] \
    && pass "every peer was dialled, the wider route was not" \
    || fail "ssh was called with: $(fact ssh_calls)"
[[ "$(fact ssh_check_log)" == "ok 10.42.0.2;ok 10.42.0.3;verdict PASS: every peer answers ssh;" ]] \
    && pass "the check log says every peer answers" \
    || fail "check log reads: $(fact ssh_check_log)"
[[ "$(fact ssh_check_stderr)" == "1" ]] && pass "the verdict also reaches the container log" || fail "$(fact ssh_check_stderr) verdict line(s) in the container log"

echo "== DAH-3060: the validator mounts the volume over /root after the entrypoint; the login survives =="
# The regression: everything of ours used to live in /root/.ssh, and the mount hid it — the peer
# then refused the key and mpirun/pdsh hung on every rank but the first.
# CAP_SYS_ADMIN is what `mount` needs; nothing wider. A host whose docker-default AppArmor profile
# denies mount regardless sets TEST_MOUNT_OPTS="--cap-add SYS_ADMIN --security-opt apparmor=unconfined".
# shellcheck disable=SC2086
RESULT="$(run_entrypoint ${TEST_MOUNT_OPTS:---cap-add SYS_ADMIN} \
    -e TEST_MOUNT_OVER_ROOT=1 \
    -e LIUM_WIREGUARD_CONF_B64="${WIREGUARD_CONF_B64}" \
    -e LIUM_CLUSTER_SSH_KEY_B64="${SSH_PRIVATE_KEY_B64}" \
    -e LIUM_CLUSTER_SSH_PUBKEY="${SSH_AUTHORIZED_KEY}")"

if [[ "$(fact mounted_over_root)" != "1" ]]; then
    echo "  skipped: this docker cannot mount a tmpfs inside the container (needs CAP_SYS_ADMIN)"
else
    [[ "$(fact private_key)" == "FAKE-CLUSTER-PRIVATE-KEY-FOR-TESTS" ]] && pass "the private key is still there after the mount" || fail "private key reads: $(fact private_key)"
    [[ "$(fact cluster_authorized_keys)" == "${SSH_AUTHORIZED_KEY}," ]] && pass "the peers' login is still authorized after the mount" || fail "cluster_authorized_keys reads: $(fact cluster_authorized_keys)"
    [[ -n "$(fact ssh_config)" && -n "$(fact sshd_dropin)" ]] && pass "both ssh drop-ins are still there after the mount" || fail "a drop-in vanished with the mount"
    [[ "$(fact renter_authorized_keys)" == "RENTERS-OWN-KEY," ]] && pass "the renter's authorized_keys holds only what the validator wrote" || fail "renter authorized_keys reads: $(fact renter_authorized_keys)"
fi

echo "== a cluster pod restored from a backup: the customer's own ~/.ssh is not touched =="
RESULT="$(run_entrypoint \
    -e TEST_RESTORED_HOME=1 \
    -e LIUM_WIREGUARD_CONF_B64="${WIREGUARD_CONF_B64}" \
    -e LIUM_CLUSTER_SSH_KEY_B64="${SSH_PRIVATE_KEY_B64}" \
    -e LIUM_CLUSTER_SSH_PUBKEY="${SSH_AUTHORIZED_KEY}")"

[[ "$(fact customer_key_kept)" == "CUSTOMERS-OWN-PRIVATE-KEY" ]] && pass "the customer's id_ed25519 is untouched" || fail "customer key now reads: $(fact customer_key_kept)"
[[ "$(fact customer_config_kept)" == "Host*,StrictHostKeyCheckingyes,Hostcustomers-own-host," ]] && pass "the customer's ssh config is left as it was" || fail "customer config now reads: $(fact customer_config_kept)"
[[ "$(fact root_ssh_entries)" == "config,id_ed25519," ]] && pass "nothing of ours was added to /root/.ssh" || fail "/root/.ssh holds: $(fact root_ssh_entries)"
[[ "$(fact private_key)" == "FAKE-CLUSTER-PRIVATE-KEY-FOR-TESTS" ]] && pass "the cluster login is installed under /etc alongside it" || fail "no cluster key"

echo "== a cluster pod with one peer that never answers ssh: the check says which one =="
RESULT="$(run_entrypoint \
    -e TEST_SSH_PEER_DOWN=10.42.0.3 \
    -e LIUM_CLUSTER_SSH_CHECK_WAIT_SECONDS=6 \
    -e LIUM_WIREGUARD_CONF_B64="${WIREGUARD_CONF_B64}" \
    -e LIUM_CLUSTER_SSH_KEY_B64="${SSH_PRIVATE_KEY_B64}" \
    -e LIUM_CLUSTER_SSH_PUBKEY="${SSH_AUTHORIZED_KEY}")"

[[ "$(fact exit_status)" == "0" && "$(fact handed_off)" == "1" ]] && pass "the pod still comes up; the check never decides its fate" || fail "exit $(fact exit_status), handed off $(fact handed_off)"
[[ "$(fact ssh_check_log)" == "ok 10.42.0.2;FAIL 10.42.0.3 (no ssh login after 6s);verdict FAIL: 1 peer(s) never answered ssh; mpirun and pdsh will hang on them;" ]] \
    && pass "the check log names the peer that never answered" \
    || fail "check log reads: $(fact ssh_check_log)"

echo "== a standalone pod: nothing of the cluster is installed =="
RESULT="$(run_entrypoint)"

[[ "$(fact exit_status)" == "0" ]] && pass "entrypoint succeeded" || fail "exit $(fact exit_status)"
[[ "$(fact handed_off)" == "1" ]] && pass "handed off to the base entrypoint" || fail "never reached the base entrypoint"
[[ -z "$(fact cluster_env)" ]] && pass "no overlay settings" || fail "cluster env file reads: $(fact cluster_env)"
[[ -z "$(fact private_key)" ]] && pass "no cluster login" || fail "a private key was installed on a standalone pod"
[[ -z "$(fact sshd_dropin)$(fact ssh_config)" ]] && pass "no ssh drop-ins" || fail "an ssh drop-in was written on a standalone pod"
[[ -z "$(fact ssh_calls)" ]] && pass "nothing was dialled" || fail "ssh was called with: $(fact ssh_calls)"

echo "== a cluster pod whose wg0 reports no address: the pod still comes up =="
# `ip` failing must not take the entrypoint down with it — set -o pipefail makes that easy to get wrong
RESULT="$(TEST_IP_FAILS=1 run_entrypoint \
    -e TEST_IP_FAILS=1 \
    -e LIUM_WIREGUARD_CONF_B64="${WIREGUARD_CONF_B64}" \
    -e LIUM_CLUSTER_SSH_KEY_B64="${SSH_PRIVATE_KEY_B64}" \
    -e LIUM_CLUSTER_SSH_PUBKEY="${SSH_AUTHORIZED_KEY}")"

[[ "$(fact exit_status)" == "0" ]] && pass "entrypoint survived a failing ip" || fail "exit $(fact exit_status)"
[[ "$(fact handed_off)" == "1" ]] && pass "handed off to the base entrypoint" || fail "never reached the base entrypoint"
[[ "$(fact private_key)" == "FAKE-CLUSTER-PRIVATE-KEY-FOR-TESTS" ]] && pass "the cluster login is still installed" || fail "no private key"
[[ -z "$(fact ssh_config)" ]] && pass "no host block, since the subnet is unknown" || fail "ssh config reads: $(fact ssh_config)"
[[ "$(fact ssh_check_log)" == *"verdict"* ]] && pass "the peers are still checked" || fail "check log reads: $(fact ssh_check_log)"

echo "== a cluster pod on RoCE: the card and GID the gate found are published too =="
RESULT="$(run_entrypoint \
    -e TEST_ROCE_FABRIC=1 \
    -e LIUM_WIREGUARD_CONF_B64="${WIREGUARD_CONF_B64}")"

[[ "$(fact exit_status)" == "0" ]] && pass "entrypoint succeeded" || fail "exit $(fact exit_status)"
# Appended after the overlay settings, and in the file BEFORE it is written, so a nested container
# starts with the same card and GID as the pod.
[[ "$(fact cluster_env)" == *"NCCL_NSOCKS_PERTHREAD=8,NCCL_IB_HCA==mlx5_0:1,NCCL_IB_GID_INDEX=3,"* ]] \
    && pass "the fabric vars are published for nested containers" \
    || fail "cluster env file reads: $(fact cluster_env)"
[[ "$(fact etc_environment_has_hca)" == "1" ]] && pass "an SSH session reads the card too" || fail "/etc/environment has no NCCL_IB_HCA"
[[ "$(fact login_shell_gid_index)" == "3" ]] && pass "a login shell reads the GID index" || fail "a login shell got: $(fact login_shell_gid_index)"

echo "== a pod whose card is still coming up: the gate waits instead of failing the rental =="
RESULT="$(run_entrypoint \
    -e TEST_FABRIC_FLAPS=1 \
    -e LIUM_WIREGUARD_CONF_B64="${WIREGUARD_CONF_B64}")"

[[ "$(fact exit_status)" == "0" ]] && pass "the pod came up" || fail "exit $(fact exit_status)"
[[ "$(fact gate_calls)" == "3" ]] && pass "the gate was retried until the port answered" || fail "the gate was asked $(fact gate_calls) time(s)"
[[ "$(fact handed_off)" == "1" ]] && pass "handed off to the base entrypoint" || fail "never reached the base entrypoint"

echo "== a pod with no usable fabric: it refuses to start rather than run over TCP =="
RESULT="$(run_entrypoint \
    -e TEST_NO_FABRIC=1 \
    -e LIUM_WIREGUARD_CONF_B64="${WIREGUARD_CONF_B64}" \
    -e LIUM_CLUSTER_SSH_KEY_B64="${SSH_PRIVATE_KEY_B64}" \
    -e LIUM_CLUSTER_SSH_PUBKEY="${SSH_AUTHORIZED_KEY}")"

[[ "$(fact exit_status)" == "1" ]] && pass "the pod is refused" || fail "exit $(fact exit_status)"
[[ "$(fact handed_off)" == "0" ]] && pass "the workload never starts" || fail "handed off to the base entrypoint anyway"
[[ -z "$(fact cluster_env)" ]] && pass "nothing is published" || fail "cluster env file reads: $(fact cluster_env)"

echo "== a cluster pod whose backend sends no login: the overlay still comes up =="
RESULT="$(run_entrypoint -e LIUM_WIREGUARD_CONF_B64="${WIREGUARD_CONF_B64}")"

[[ "$(fact exit_status)" == "0" ]] && pass "entrypoint succeeded" || fail "exit $(fact exit_status)"
[[ -n "$(fact cluster_env)" ]] && pass "the overlay settings are published" || fail "cluster env file is empty"
[[ -z "$(fact private_key)" ]] && pass "no cluster login" || fail "a private key appeared from nowhere"
[[ -z "$(fact ssh_calls)" ]] && pass "no peer is dialled without a login to try" || fail "ssh was called with: $(fact ssh_calls)"

if (( failures )); then
    echo "${failures} failing check(s)"
    exit 1
fi
echo "all checks passed"
