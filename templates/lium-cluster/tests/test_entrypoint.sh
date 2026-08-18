#!/usr/bin/env bash
# Contract tests for templates/lium-cluster/entrypoint.sh. The entrypoint writes to /etc and
# /root/.ssh and execs the base image's start script, so it runs inside a throwaway container with
# wg-quick, wg and /pytorch-entrypoint.sh stubbed — what is under test is where the overlay settings
# and the cluster login end up, and with which permissions.
#
#   bash templates/lium-cluster/tests/test_entrypoint.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
IMAGE="${TEST_BASE_IMAGE:-ubuntu:24.04}"

# A cluster pod is dispatched with these three; a standalone pod with none of them.
WIREGUARD_CONF_B64="$(printf '[Interface]\nAddress = 10.42.0.1/24\n' | base64)"
SSH_PRIVATE_KEY_B64="$(printf -- '-----BEGIN OPENSSH PRIVATE KEY-----\nZmFrZQ==\n' | base64)"
SSH_AUTHORIZED_KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIfake lium-cluster"

# Runs the entrypoint in a container and prints what it left behind, one fact per line.
run_entrypoint() {
    docker run --rm -i "$@" -v "${HERE}/..:/template:ro" "${IMAGE}" bash -s <<'IN_CONTAINER'
set -uo pipefail
mkdir -p /usr/local/bin
printf '#!/bin/sh\nexit 0\n' > /usr/local/bin/wg-quick
printf '#!/bin/sh\nexit 0\n' > /usr/local/bin/wg
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
chmod +x /usr/local/bin/wg-quick /usr/local/bin/wg /usr/local/bin/ip /usr/local/bin/python3 /pytorch-entrypoint.sh

bash /template/entrypoint.sh >/tmp/out.log 2>&1
echo "exit_status=$?"
echo "handed_off=$(grep -c handed-off-to-base-entrypoint /tmp/out.log)"
echo "cluster_env=$(cat /etc/lium-cluster.env 2>/dev/null | tr '\n' ',')"
echo "etc_environment_has_ifname=$(grep -c '^NCCL_SOCKET_IFNAME=wg0$' /etc/environment 2>/dev/null)"
echo "login_shell_ifname=$(env -i sh -c '. /etc/profile.d/lium-cluster.sh 2>/dev/null; echo ${NCCL_SOCKET_IFNAME:-}')"
echo "login_shell_gid_index=$(env -i sh -c '. /etc/profile.d/lium-cluster.sh 2>/dev/null; echo ${NCCL_IB_GID_INDEX:-}')"
echo "etc_environment_has_hca=$(grep -c '^NCCL_IB_HCA==mlx5_0:1$' /etc/environment 2>/dev/null)"
echo "private_key=$(cat /root/.ssh/lium_cluster_ed25519 2>/dev/null | head -1)"
echo "private_key_mode=$(stat -c '%a' /root/.ssh/lium_cluster_ed25519 2>/dev/null)"
echo "ssh_dir_mode=$(stat -c '%a' /root/.ssh 2>/dev/null)"
echo "authorized_keys=$(cat /root/.ssh/authorized_keys 2>/dev/null | tr '\n' ',')"
echo "ssh_config=$(cat /root/.ssh/config 2>/dev/null | tr -d ' ' | tr '\n' ',')"
echo "customer_key_kept=$(cat /root/.ssh/id_ed25519 2>/dev/null)"
echo "customer_config_kept=$(grep -c 'customers-own-host' /root/.ssh/config 2>/dev/null)"
echo "overlay_block_wins=$(grep -n 'Host 10.42.0' /root/.ssh/config 2>/dev/null | cut -d: -f1)"
IN_CONTAINER
}

failures=0
fail() { echo "  FAIL: $*"; failures=$((failures + 1)); }
pass() { echo "  ok: $*"; }
fact() { grep "^$1=" <<<"${RESULT}" | cut -d= -f2-; }

echo "== a cluster pod: overlay settings published and the shared login installed =="
# Arrange — the renter's own key is already in authorized_keys, as the validator's exec puts it there
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
# rank on a peer.
[[ "$(fact private_key)" == "-----BEGIN OPENSSH PRIVATE KEY-----" ]] && pass "the cluster private key is installed" || fail "private key reads: $(fact private_key)"
[[ "$(fact private_key_mode)" == "600" ]] && pass "the private key is unreadable to others" || fail "private key mode $(fact private_key_mode)"
[[ "$(fact ssh_dir_mode)" == "700" ]] && pass "~/.ssh is restricted" || fail "~/.ssh mode $(fact ssh_dir_mode)"
[[ "$(fact authorized_keys)" == "${SSH_AUTHORIZED_KEY}," ]] && pass "the peers' login is authorized" || fail "authorized_keys reads: $(fact authorized_keys)"
[[ "$(fact ssh_config)" == *"Host10.42.0.*"*"StrictHostKeyCheckingno"* ]] \
    && pass "a peer on the overlay is dialled without a fingerprint prompt" \
    || fail "ssh config reads: $(fact ssh_config)"

echo "== a cluster pod restored from a backup: the customer's own ~/.ssh survives =="
RESULT="$(run_entrypoint \
    -e TEST_RESTORED_HOME=1 \
    -e LIUM_WIREGUARD_CONF_B64="${WIREGUARD_CONF_B64}" \
    -e LIUM_CLUSTER_SSH_KEY_B64="${SSH_PRIVATE_KEY_B64}" \
    -e LIUM_CLUSTER_SSH_PUBKEY="${SSH_AUTHORIZED_KEY}")"

[[ "$(fact customer_key_kept)" == "CUSTOMERS-OWN-PRIVATE-KEY" ]] && pass "the customer's id_ed25519 is untouched" || fail "customer key now reads: $(fact customer_key_kept)"
[[ "$(fact customer_config_kept)" == "1" ]] && pass "the customer's ssh config is kept" || fail "the customer's ssh config was overwritten"
[[ "$(fact private_key)" == "-----BEGIN OPENSSH PRIVATE KEY-----" ]] && pass "the cluster login is installed alongside it" || fail "no cluster key"
[[ "$(fact ssh_config)" == *"Host10.42.0.*"* ]] && pass "the overlay host block is there" || fail "ssh config reads: $(fact ssh_config)"
# ssh takes the FIRST value it finds, so our block has to sit above the customer's `Host *`
[[ "$(fact overlay_block_wins)" == "2" ]] && pass "the overlay block outranks the customer's Host *" || fail "overlay block is at line $(fact overlay_block_wins)"

echo "== a standalone pod: nothing of the cluster is installed =="
RESULT="$(run_entrypoint)"

[[ "$(fact exit_status)" == "0" ]] && pass "entrypoint succeeded" || fail "exit $(fact exit_status)"
[[ "$(fact handed_off)" == "1" ]] && pass "handed off to the base entrypoint" || fail "never reached the base entrypoint"
[[ -z "$(fact cluster_env)" ]] && pass "no overlay settings" || fail "cluster env file reads: $(fact cluster_env)"
[[ -z "$(fact private_key)" ]] && pass "no cluster login" || fail "a private key was installed on a standalone pod"

echo "== a cluster pod whose wg0 reports no address: the pod still comes up =="
# `ip` failing must not take the entrypoint down with it — set -o pipefail makes that easy to get wrong
RESULT="$(TEST_IP_FAILS=1 run_entrypoint \
    -e TEST_IP_FAILS=1 \
    -e LIUM_WIREGUARD_CONF_B64="${WIREGUARD_CONF_B64}" \
    -e LIUM_CLUSTER_SSH_KEY_B64="${SSH_PRIVATE_KEY_B64}" \
    -e LIUM_CLUSTER_SSH_PUBKEY="${SSH_AUTHORIZED_KEY}")"

[[ "$(fact exit_status)" == "0" ]] && pass "entrypoint survived a failing ip" || fail "exit $(fact exit_status)"
[[ "$(fact handed_off)" == "1" ]] && pass "handed off to the base entrypoint" || fail "never reached the base entrypoint"
[[ "$(fact private_key)" == "-----BEGIN OPENSSH PRIVATE KEY-----" ]] && pass "the cluster login is still installed" || fail "no private key"
[[ -z "$(fact ssh_config)" ]] && pass "no host block, since the subnet is unknown" || fail "ssh config reads: $(fact ssh_config)"

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

if (( failures )); then
    echo "${failures} failing check(s)"
    exit 1
fi
echo "all checks passed"
