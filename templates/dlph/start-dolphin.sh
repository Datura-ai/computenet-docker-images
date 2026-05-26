#!/usr/bin/env bash
set -Eeuo pipefail

readonly WORKER_SCRIPT="/root/dolphin_worker.sh"
readonly EMBEDDED_WORKER_SCRIPT="/opt/dlph/dolphin_worker.embedded.sh"

log() {
  printf '[dlph] %s\n' "$*"
}

die() {
  printf '[dlph] ERROR: %s\n' "$*" >&2
  exit 1
}

decode_download_link() {
  local decoded

  if [[ -n "${DOWNLOAD_LINK:-}" ]]; then
    printf '%s' "$DOWNLOAD_LINK"
    return
  fi

  [[ -n "${DOWNLOAD_LINK_B64:-}" ]] || die "Set DOWNLOAD_LINK_B64 or DOWNLOAD_LINK."

  if ! decoded="$(printf '%s' "$DOWNLOAD_LINK_B64" | base64 -d 2>/dev/null)"; then
    die "Could not decode DOWNLOAD_LINK_B64."
  fi

  [[ -n "$decoded" ]] || die "DOWNLOAD_LINK_B64 decoded to an empty value."
  printf '%s' "$decoded"
}

prepare_worker_script() {
  local download_link

  if [[ -n "${DOWNLOAD_LINK:-}" || -n "${DOWNLOAD_LINK_B64:-}" ]]; then
    command -v curl >/dev/null 2>&1 || die "curl is required."
    command -v base64 >/dev/null 2>&1 || die "base64 is required."

    download_link="$(decode_download_link)"
    log "Downloading Dolphin worker bootstrap..."
    curl -fsSL "$download_link" -o "$WORKER_SCRIPT" || return
  else
    [[ -f "$EMBEDDED_WORKER_SCRIPT" ]] || die "Missing embedded worker script."

    log "Using embedded Dolphin worker bootstrap."
    cp "$EMBEDDED_WORKER_SCRIPT" "$WORKER_SCRIPT" || return
  fi

  chmod +x "$WORKER_SCRIPT" || return
}

validate_port() {
  local port="$1"

  [[ "$port" =~ ^[0-9]+$ ]] || die "DOLPHIN_WATCHTOWER_PORT must be numeric."
  (( port >= 1 && port <= 65535 )) || die "DOLPHIN_WATCHTOWER_PORT must be between 1 and 65535."
}

patch_watchtower_port() {
  local worker_script="$1"
  local port="${DOLPHIN_WATCHTOWER_PORT:-20000}"

  validate_port "$port"

  if ! grep -q '^readonly WATCHTOWER_PORT=' "$worker_script"; then
    die "Downloaded worker script does not define WATCHTOWER_PORT."
  fi

  sed -i "s/^readonly WATCHTOWER_PORT=.*/readonly WATCHTOWER_PORT='${port}'/" "$worker_script"
}

main() {
  local status

  log "Preparing NVIDIA device links..."
  /nvidia-setup.sh || die "NVIDIA setup failed."

  prepare_worker_script || die "Could not prepare Dolphin worker bootstrap."
  patch_watchtower_port "$WORKER_SCRIPT" || die "Could not patch Dolphin watchtower port."

  log "Starting Dolphin worker..."
  set +e
  "$WORKER_SCRIPT"
  status="$?"
  set -e

  if (( status != 0 )); then
    log "Dolphin worker bootstrap failed with exit code ${status}."
    if [[ "${KEEP_ALIVE_ON_FAILURE:-1}" == "1" ]]; then
      log "Keeping the container alive for SSH/debug. Set KEEP_ALIVE_ON_FAILURE=0 to exit on failure."
      tail -f /dev/null
    fi
    exit "$status"
  fi

  log "Dolphin worker bootstrap finished; keeping the container alive."
  tail -f /dev/null
}

main "$@"
