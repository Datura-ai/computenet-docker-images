#!/usr/bin/env bash
# Regression test for DAH-2433: the install RUN chain in templates/pytorch/Dockerfile must FAIL the
# build when one of the files it installs is missing, and must SUCCEED (with every target present)
# when they are all there.
#
# Why: the chain ends in `sed -i … /root/.bashrc || true`. In POSIX sh, && and || bind with equal
# precedence left-to-right, so an unscoped `|| true` catches the whole conjunction above it and the
# RUN can never fail — a broken install ships as a green image. The fix scopes it to the sed alone.
#
# How: the exact RUN instruction is lifted out of the Dockerfile (so the test follows every future
# edit of the chain), placed after a FROM ubuntu stage that provides the /tmp source files the chain
# installs, and built twice: once with one source removed (must fail), once complete (must pass).
#
# Usage: templates/pytorch/tests/test-install-chain.sh            (needs docker)
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
dockerfile="$here/../Dockerfile"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# The RUN instruction that installs /start.sh, the entrypoint, daemon.json etc. — from its first line
# up to (and including) the first line that does not end in a backslash. Comment lines inside the
# continuation are kept: Docker strips them itself, exactly as it does in the real build.
awk '
  /^RUN rm -f \/etc\/ssh\/ssh_host_\*/ { grab = 1 }
  grab { print; if ($0 ~ /^[[:space:]]*#/) next; if ($0 !~ /\\[[:space:]]*$/) exit }
' "$dockerfile" > "$work/run.txt"
[ -s "$work/run.txt" ] || { echo "FAIL: install RUN chain not found in $dockerfile" >&2; exit 2; }

# Every source path the chain installs from (install -m … /tmp/<dir>/<file> <target>), plus targets.
mapfile -t sources < <(grep -oE 'install -m [0-7]+ (-D )?/tmp/[^ ]+' "$work/run.txt" | awk '{print $NF}')
mapfile -t targets < <(grep -oE 'install -m [0-7]+ (-D )?/tmp/[^ ]+ [^ ]+' "$work/run.txt" | awk '{print $NF}')
[ "${#sources[@]}" -ge 5 ] || { echo "FAIL: expected ≥5 install sources in the chain, found ${#sources[@]}" >&2; exit 2; }

write_dockerfile() {  # $1 = output path, $2 = source to omit ("" = none)
  {
    echo "FROM ubuntu:22.04"
    echo "RUN mkdir -p $(printf '%s\n' "${sources[@]}" | xargs -n1 dirname | sort -u | tr '\n' ' ')"
    for s in "${sources[@]}"; do
      [ "$s" = "$2" ] && continue
      printf 'RUN printf '"'"'#!/bin/sh\\n'"'"' > %s\n' "$s"
    done
    cat "$work/run.txt"
    # Complete case only: prove every target landed. The broken case must fail inside the chain
    # itself, so no later step may turn a green chain red.
    [ -n "$2" ] || echo "RUN ls -l ${targets[*]} /etc/profile.d/zz-lium-welcome.sh"
  } > "$1"
}

fail=0
# 1. One install source missing → the build MUST fail.
write_dockerfile "$work/Dockerfile.broken" "${sources[2]}"
if docker build -q -f "$work/Dockerfile.broken" "$work" >/dev/null 2>"$work/broken.log"; then
  echo "FAIL: build succeeded although ${sources[2]} was missing — the install chain cannot fail" >&2
  fail=1
else
  echo "ok: build fails when ${sources[2]} is missing"
fi

# 2. Everything present → the build MUST succeed and every target exists.
write_dockerfile "$work/Dockerfile.ok" ""
if docker build -q -f "$work/Dockerfile.ok" "$work" >/dev/null 2>"$work/ok.log"; then
  echo "ok: build succeeds with all sources present (${#targets[@]} targets + welcome script verified)"
else
  echo "FAIL: build with all sources present failed:" >&2; cat "$work/ok.log" >&2
  fail=1
fi

exit "$fail"
