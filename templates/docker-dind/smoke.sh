#!/bin/sh
# Run by scripts/build-smoke.sh inside the booted container (plain `docker run`: no sysbox, no privileges, so the inner
# dockerd cannot start here and only the image's static choice is checked). DAH-2856: iptables must be the nft backend.
set -e
alt=$(readlink -f /etc/alternatives/iptables)
case "$alt" in
    *xtables-nft-multi) echo "iptables alternative: $alt" ;;
    *) echo "iptables alternative is $alt, expected xtables-nft-multi"; exit 1 ;;
esac
iptables --version | grep -q nf_tables
test -x /usr/local/bin/select-iptables-backend.sh
echo "docker-dind smoke ok"
