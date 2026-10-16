#!/bin/sh
# Runs inside the booted image (build-smoke.sh copies it to /tmp/smoke.sh). The entrypoint starts
# sshd before the workload, so by the time the boot check looks it must be serving, from a
# hardened config, with the pidfile the validator's SSH bootstrap reloads through.
set -eu
grep -qE ':0016 0+:0+ 0A ' /proc/net/tcp /proc/net/tcp6 || { echo "nothing listens on :22"; exit 1; }
kill -0 "$(cat /run/sshd.pid)" || { echo "/run/sshd.pid does not name a live sshd"; exit 1; }
grep -q '^# lium-hardened$' /etc/ssh/sshd_config || { echo "sshd_config lacks the lium-hardened marker"; exit 1; }
sshd -T | grep -qx 'passwordauthentication no' || { echo "sshd allows password login"; exit 1; }
echo "sshd is up and hardened"
