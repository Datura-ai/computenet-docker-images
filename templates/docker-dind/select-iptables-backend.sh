#!/bin/bash
# Pick the iptables backend the host kernel can serve, before the inner dockerd starts (DAH-2856).
#
# The image defaults to iptables-nft (Dockerfile): it only needs nf_tables, which every host that
# runs a current dockerd already has loaded. The legacy binary needs ip_tables/iptable_nat loaded
# on the host, and a container cannot modprobe, so on a Debian 12+ style host the inner dockerd
# died at `iptables -t nat -N DOCKER` and sshd never started (ticket-0309).
#
# A host that still runs legacy-only iptables may have no nf_tables loaded; there nft cannot open a
# table but legacy can, so switch the alternatives back to legacy. Best-effort and silent when nft
# works; when neither backend answers, nothing is changed (the image default, nft, stays) and dockerd's
# own error stays in the container log. Called by load-probe-entrypoint.sh; also runnable by hand inside the container.

set -u

if iptables-nft -t nat -L -n >/dev/null 2>&1; then
    exit 0
fi

if iptables-legacy -t nat -L -n >/dev/null 2>&1; then
    echo "select-iptables-backend: nf_tables unavailable on this host, using iptables-legacy" >&2
    update-alternatives --set iptables /usr/sbin/iptables-legacy >/dev/null 2>&1 || true
    update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy >/dev/null 2>&1 || true
    exit 0
fi

echo "select-iptables-backend: neither iptables-nft nor iptables-legacy can open the nat table; leaving the current backend" >&2
exit 0
