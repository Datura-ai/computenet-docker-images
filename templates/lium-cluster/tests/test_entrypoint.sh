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
printf '#!/bin/sh\necho "5: wg0    inet 10.42.0.1/24 scope global wg0"\n' > /usr/local/bin/ip
printf '#!/bin/sh\nexit 0\n' > /usr/local/bin/python3     # only configure_nested_docker needs it
printf '#!/bin/sh\necho handed-off-to-base-entrypoint\n' > /pytorch-entrypoint.sh
chmod +x /usr/local/bin/wg-quick /usr/local/bin/wg /usr/local/bin/ip /usr/local/bin/python3 /pytorch-entrypoint.sh

bash /template/entrypoint.sh >/tmp/out.log 2>&1
echo "exit_status=$?"
echo "handed_off=$(grep -c handed-off-to-base-entrypoint /tmp/out.log)"
echo "cluster_env=$(cat /etc/lium-cluster.env 2>/dev/null | tr '\n' ',')"
echo "etc_environment_has_ifname=$(grep -c '^NCCL_SOCKET_IFNAME=wg0$' /etc/environment 2>/dev/null)"
echo "login_shell_ifname=$(env -i sh -c '. /etc/profile.d/lium-cluster.sh 2>/dev/null; echo ${NCCL_SOCKET_IFNAME:-}')"
echo "private_key=$(cat /root/.ssh/id_ed25519 2>/dev/null | head -1)"
echo "private_key_mode=$(stat -c '%a' /root/.ssh/id_ed25519 2>/dev/null)"
echo "ssh_dir_mode=$(stat -c '%a' /root/.ssh 2>/dev/null)"
echo "authorized_keys=$(cat /root/.ssh/authorized_keys 2>/dev/null | tr '\n' ',')"
echo "ssh_config=$(cat /root/.ssh/config 2>/dev/null | tr -d ' ' | tr '\n' ',')"
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

echo "== a standalone pod: nothing of the cluster is installed =="
RESULT="$(run_entrypoint)"

[[ "$(fact exit_status)" == "0" ]] && pass "entrypoint succeeded" || fail "exit $(fact exit_status)"
[[ "$(fact handed_off)" == "1" ]] && pass "handed off to the base entrypoint" || fail "never reached the base entrypoint"
[[ -z "$(fact cluster_env)" ]] && pass "no overlay settings" || fail "cluster env file reads: $(fact cluster_env)"
[[ -z "$(fact private_key)" ]] && pass "no cluster login" || fail "a private key was installed on a standalone pod"

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
