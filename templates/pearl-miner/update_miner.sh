#!/usr/bin/env bash
# Install the newest PeakMiner build inside the pinned major, next to the baked-in one.
#
# Why: Pearl's V3 hard fork (2026-08-11) had the whole fleet submitting shares the network rejected
# for six days, only because the binary in this image was pinned and nobody rebuilt it (DAH-2688).
# A miner that picks up its own new build survives that class of outage without a release.
#
# Rules that keep the update from becoming its own outage: pinned major only (a new major can change
# flags), stable releases only, the download must actually run before it is installed, and any
# failure leaves the baked-in binary in place and exits 0 — an update problem must never stop mining.
#
#   PEARL_MINER_AUTO_UPDATE    1 (default) enables the check
#   PEARL_MINER_BAKED_VERSION  version baked into the image (set by the Dockerfile)
#   PEARL_MINER_DIR            where the update is installed, first on the entrypoint's PATH
set -uo pipefail

BAKED_VERSION="${PEARL_MINER_BAKED_VERSION:-0}"
INSTALL_DIR="${PEARL_MINER_DIR:-/var/lib/pearl/bin}"
RELEASES_URL="${PEAKMINER_RELEASES_URL:-https://api.github.com/repos/peakminer/peakminer/releases?per_page=30}"

keep_baked() {
    echo "[pearl-update] $1, staying on the baked-in ${BAKED_VERSION}" >&2
    exit 0
}

[[ "${PEARL_MINER_AUTO_UPDATE:-1}" == "1" ]] || keep_baked "auto-update disabled"

releases=$(curl -fsSL --max-time 30 "${RELEASES_URL}" 2>/dev/null) || keep_baked "release list unreachable"

# Newest stable release inside the baked-in major, compared as numbers so 2.10.0 does not read as
# older than 2.9.0.
version=$(printf '%s' "${releases}" | BAKED_VERSION="${BAKED_VERSION}" python3 -c '
import json, os, re, sys

major: str = os.environ["BAKED_VERSION"].split(".")[0]
best: tuple[int, ...] = ()
for release in json.load(sys.stdin):
    if release.get("prerelease") or release.get("draft"):
        continue
    match = re.fullmatch(r"v(\d+)\.(\d+)\.(\d+)", release.get("tag_name", ""))
    if match is None or match.group(1) != major:
        continue
    candidate: tuple[int, ...] = tuple(int(part) for part in match.groups())
    best = max(best, candidate)
print(".".join(str(part) for part in best))
' 2>/dev/null) || keep_baked "release list unreadable"

[[ -n "${version}" ]] || keep_baked "no stable release for the baked-in major"
[[ "${version}" == "${BAKED_VERSION}" ]] && keep_baked "baked-in build is already the newest"

candidate=$(mktemp)
url="https://github.com/peakminer/peakminer/releases/download/v${version}/peakminer-${version}-linux-x86_64"
curl -fsSL --max-time 180 "${url}" -o "${candidate}" || { rm -f "${candidate}"; keep_baked "download of ${version} failed"; }
chmod +x "${candidate}"

# The only check available — the release publishes no checksum — so a build that cannot report its
# own version is treated as damaged rather than mined with.
"${candidate}" --version > /dev/null 2>&1 || { rm -f "${candidate}"; keep_baked "${version} does not run here"; }

mkdir -p "${INSTALL_DIR}" && mv "${candidate}" "${INSTALL_DIR}/peakminer" || { rm -f "${candidate}"; keep_baked "install of ${version} failed"; }
echo "[pearl-update] running ${version}" >&2
