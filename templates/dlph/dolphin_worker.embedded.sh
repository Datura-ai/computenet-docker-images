#!/usr/bin/env bash
set -Eeuo pipefail

readonly WORKER_IMAGE='registry.gitlab.com/i81032staging-group/i81032staging-worker:gpu'
readonly WORKER_IMAGE_CPU='registry.gitlab.com/i81032staging-group/i81032staging-worker:cpu'
readonly WORKER_IMAGE_GPU='registry.gitlab.com/i81032staging-group/i81032staging-worker:gpu'
readonly WATCHTOWER_IMAGE='registry.gitlab.com/i81032staging-group/i81032staging-worker:watchtower'
readonly REGISTRY_USER='i81032staging'
readonly REGISTRY_TOKEN='glpat-ciMc5kEKyvZu5rnamPl3N2M6MQpvOjEKdTpreG5nZQ8.01.170z382ej'
readonly WORKER_AUTH_TOKEN='dp-lArukt5oFOg3pwfWeF3vj_c4Nage4BBxQKXR96_XiCw'
readonly API_BASE_URL='https://api-v2.dphn.ai'
readonly LIGHTHOUSE_URL='wss://lighthouse-v2.dphn.ai'
readonly MODEL='Qwen/Qwen3.5-35B-A3B-FP8'
readonly WORKER_TYPE='text-v'
readonly GPU_MEMORY_UTILIZATION='0.8'
readonly WATCHTOWER_BIND_IP='0.0.0.0'
readonly WATCHTOWER_PORT='9344'
readonly WATCHTOWER_AUTH_TOKEN='F219CD74E0145EAA013AFBCAE60E62EC'

PROJECT_NAME="dolphinpod-worker"
SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="$SCRIPT_DIR/.docker-compose.embedded.yml"

DOLPHIN_ASCII='██████╗  ██████╗ ██╗     ██████╗ ██╗  ██╗██╗███╗   ██╗
██╔══██╗██╔═══██╗██║     ██╔══██╗██║  ██║██║████╗  ██║
██║  ██║██║   ██║██║     ██████╔╝███████║██║██╔██╗ ██║
██║  ██║██║   ██║██║     ██╔═══╝ ██╔══██║██║██║╚██╗██║
██████╔╝╚██████╔╝███████╗██║     ██║  ██║██║██║ ╚████║
╚═════╝  ╚═════╝ ╚══════╝╚═╝     ╚═╝  ╚═╝╚═╝╚═╝  ╚═══╝'

log() {
  printf '[dolphin-worker] %s\n' "$*"
}

warn() {
  printf '[dolphin-worker] WARNING: %s\n' "$*" >&2
}

die() {
  printf '[dolphin-worker] ERROR: %s\n' "$*" >&2
  exit 1
}

die_highlighted() {
  local message="$1"

  if [[ -t 2 ]]; then
    printf '\033[1;37;41m[dolphin-worker] ERROR\033[0m %s\n' "$message" >&2
  else
    printf '[dolphin-worker] ERROR: %s\n' "$message" >&2
  fi
  exit 1
}

print_error_block() {
  local message="$1"

  if [[ -t 2 ]]; then
    printf '\033[1;31m%s\033[0m\n' "$message" >&2
  else
    printf '%s\n' "$message" >&2
  fi
}

safe_remove_file() {
  local path="${1:-}"

  [[ -n "$path" ]] || die "Refusing to remove empty path."
  [[ "$path" != "/" ]] || die "Refusing to remove root path."
  [[ "$path" == "$SCRIPT_DIR"/* ]] || die "Refusing to remove path outside script dir: $path"

  if [[ -e "$path" ]]; then
    rm -f -- "$path"
  fi
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    die "Missing required command: $1"
  fi
}

ensure_root() {
  if [[ "$(id -u)" -eq 0 ]]; then
    return
  fi

  if command -v sudo >/dev/null 2>&1; then
    exec sudo bash "$0" "$@"
  fi

  die "Run this script as root."
}

write_embedded_compose_file() {
  cat >"$COMPOSE_FILE" <<EOF
name: dolphinpod-worker

services:
  worker:
    image: ${WORKER_IMAGE}
    container_name: dolphinpod-worker
    restart: unless-stopped
${WORKER_COMPOSE_GPU_BLOCK:-}
    volumes:
      - ./worker-models:/app/worker/models
    environment:
      API_KEY: ${WORKER_AUTH_TOKEN}
      API_BASE_URL: ${API_BASE_URL}
      LIGHTHOUSE_URL: ${LIGHTHOUSE_URL}
      MODEL: ${MODEL}
      WORKER_TYPE: ${WORKER_TYPE}
      GPU_MEMORY_UTILIZATION: ${GPU_MEMORY_UTILIZATION}
      WATCHTOWER_URL: http://watchtower:8080
      WATCHTOWER_AUTH_TOKEN: ${WATCHTOWER_AUTH_TOKEN}
      WORKER_STARTUP_DEBUG: ${WORKER_STARTUP_DEBUG:-}
      HF_HUB_DISABLE_PROGRESS_BARS: 1
      PYTHONWARNINGS: ignore
    networks:
      - worker-net

  watchtower:
    image: ${WATCHTOWER_IMAGE}
    container_name: dolphinpod-watchtower
    restart: unless-stopped
    ports:
      - "${WATCHTOWER_BIND_IP}:${WATCHTOWER_PORT}:8080"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - ./worker-data:/data
    environment:
      WORKER_CONTAINER: dolphinpod-worker
      WORKER_IMAGE: ${WORKER_IMAGE}
      WORKER_IMAGE_CPU: ${WORKER_IMAGE_CPU}
      WORKER_IMAGE_GPU: ${WORKER_IMAGE_GPU}
      REGISTRY_USER: ${REGISTRY_USER}
      REGISTRY_TOKEN: ${REGISTRY_TOKEN}
      WATCHTOWER_AUTH_TOKEN: ${WATCHTOWER_AUTH_TOKEN}
      WEBUI_ENABLED: true
      API_BASE_URL: ${API_BASE_URL}
      LIGHTHOUSE_URL: ${LIGHTHOUSE_URL}
    networks:
      - worker-net

networks:
  worker-net:
    driver: bridge
EOF
}

worker_uses_cpu_image() {
  [[ -n "${WORKER_IMAGE_CPU:-}" && "${WORKER_IMAGE:-}" == "${WORKER_IMAGE_CPU}" ]]
}

worker_requires_gpu() {
  ! worker_uses_cpu_image
}

set_worker_compose_gpu_block() {
  if worker_requires_gpu; then
    export WORKER_COMPOSE_GPU_BLOCK="    gpus: all"
  else
    export WORKER_COMPOSE_GPU_BLOCK=""
  fi
}

json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\t'/\\t}"
  printf '%s' "$s"
}

ensure_worker_config_json() {
  local config_dir="$SCRIPT_DIR/worker-data"
  local config_file="$config_dir/config.json"

  mkdir -p "$config_dir"
  cat >"$config_file" <<EOF
{
  "api_key": "$(json_escape "$WORKER_AUTH_TOKEN")",
  "model_id": "$(json_escape "$MODEL")",
  "worker_type": "$(json_escape "$WORKER_TYPE")"
}
EOF
}

clear_worker_config_json_for_bootstrap() {
  local config_file="$SCRIPT_DIR/worker-data/config.json"
  if [[ -f "$config_file" ]]; then
    safe_remove_file "$config_file"
    log "Reset watchtower config for clean startup."
  fi
}

install_docker_if_missing() {
  if command -v docker >/dev/null 2>&1; then
    return
  fi

  require_cmd curl
  log "Docker is missing. Installing Docker..."

  curl -fsSL https://get.docker.com | sh || die "Docker install failed."
}

ensure_docker_running() {
  local uid
  local rootless_sock
  local docker_err
  local attempt

  if docker info >/dev/null 2>&1; then
    return
  fi

  docker_err="$(docker info 2>&1 || true)"
  docker_err="${docker_err//$'\n'/ }"
  if [[ "$docker_err" == *"permission denied"* || "$docker_err" == *"Got permission denied"* ]]; then
    die "Docker daemon is running but this user cannot access it. Run this script as root."
  fi

  uid="$(id -u)"
  rootless_sock="/run/user/${uid}/docker.sock"

  if [[ -n "${DOCKER_HOST:-}" ]] && env -u DOCKER_HOST docker info >/dev/null 2>&1; then
    warn "DOCKER_HOST is unreachable (${DOCKER_HOST}). Falling back to local Docker daemon."
    unset DOCKER_HOST
    return
  fi

  if [[ -S "$rootless_sock" ]] && DOCKER_HOST="unix://${rootless_sock}" docker info >/dev/null 2>&1; then
    export DOCKER_HOST="unix://${rootless_sock}"
    log "Using rootless Docker socket: ${DOCKER_HOST}"
    return
  fi

  warn "Docker daemon is not reachable. Trying to start it..."

  if command -v systemctl >/dev/null 2>&1; then
    systemctl start docker >/dev/null 2>&1 || true
  fi

  if ! docker info >/dev/null 2>&1 && command -v service >/dev/null 2>&1; then
    service docker start >/dev/null 2>&1 || true
  fi

  for attempt in 1 2 3 4 5; do
    if docker info >/dev/null 2>&1; then
      return
    fi
    sleep 2
  done

  docker_err="$(docker info 2>&1 || true)"
  docker_err="${docker_err//$'\n'/ }"
  die "Docker is installed but the daemon is still unavailable. docker info error: ${docker_err}"
}

available_gpu_indices() {
  nvidia-smi --query-gpu=index --format=csv,noheader,nounits 2>/dev/null \
    | tr -d ' ' \
    | sed '/^$/d'
}

debian_or_ubuntu_host() {
  command -v apt-get >/dev/null 2>&1
}

install_nvidia_container_toolkit_if_missing() {
  local keyring_path="/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg"
  local repo_path="/etc/apt/sources.list.d/nvidia-container-toolkit.list"
  local repo_url="https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list"

  if command -v nvidia-ctk >/dev/null 2>&1; then
    return 0
  fi

  if ! debian_or_ubuntu_host; then
    return 1
  fi

  require_cmd curl
  require_cmd gpg

  log "NVIDIA container toolkit is missing. Installing it..."

  export DEBIAN_FRONTEND=noninteractive
  if ! apt-get update; then
    die "Could not refresh apt metadata for NVIDIA container toolkit install."
  fi

  if ! apt-get install -y --no-install-recommends ca-certificates curl gnupg2; then
    die "Could not install prerequisites for NVIDIA container toolkit."
  fi

  mkdir -p /usr/share/keyrings /etc/apt/sources.list.d
  if ! curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
    | gpg --dearmor -o "$keyring_path"; then
    die "Could not install NVIDIA container toolkit apt key."
  fi

  if ! curl -fsSL "$repo_url" \
    | sed "s#deb https://#deb [signed-by=$keyring_path] https://#g" >"$repo_path"; then
    die "Could not configure NVIDIA container toolkit apt repository."
  fi

  if ! apt-get update; then
    die "Could not refresh apt metadata after adding NVIDIA container toolkit repository."
  fi

  if ! apt-get install -y \
    nvidia-container-toolkit \
    nvidia-container-toolkit-base \
    libnvidia-container-tools \
    libnvidia-container1; then
    die "Automatic NVIDIA container toolkit install failed."
  fi

  if ! command -v nvidia-ctk >/dev/null 2>&1; then
    die "NVIDIA container toolkit install completed, but nvidia-ctk is still unavailable."
  fi

  log "NVIDIA container toolkit is available."
}

docker_is_rootless() {
  if docker info --format '{{.Rootless}}' 2>/dev/null | grep -qi '^true$'; then
    return 0
  fi

  if docker info --format '{{json .SecurityOptions}}' 2>/dev/null | grep -qi 'rootless'; then
    return 0
  fi

  [[ "${DOCKER_HOST:-}" == unix:///run/user/*/docker.sock ]]
}

restricted_container_runtime() {
  local virt

  if command -v systemd-detect-virt >/dev/null 2>&1; then
    virt="$(systemd-detect-virt 2>/dev/null || true)"
    case "$virt" in
      lxc|lxd|incus|docker|podman|openvz|wsl)
        printf '%s' "$virt"
        return 0
        ;;
    esac
  fi

  if [[ -r /proc/1/cgroup ]] && grep -qiE '(docker|containerd|kubepods|lxc)' /proc/1/cgroup; then
    printf '%s' "containerized-host"
    return 0
  fi

  return 1
}

nvidia_runtime_no_cgroups_enabled() {
  local config_path="/etc/nvidia-container-runtime/config.toml"

  [[ -f "$config_path" ]] || return 1
  awk '
    /^[[:space:]]*no-cgroups[[:space:]]*=[[:space:]]*true([[:space:]]*|[[:space:]]*#.*)$/ {
      found = 1
    }
    END {
      exit found ? 0 : 1
    }
  ' "$config_path"
}

enable_nvidia_runtime_no_cgroups() {
  local config_path="/etc/nvidia-container-runtime/config.toml"

  [[ -f "$config_path" ]] || die "Missing NVIDIA runtime config: $config_path"

  if grep -Eq '^[[:space:]]*#?[[:space:]]*no-cgroups[[:space:]]*=' "$config_path"; then
    sed -i 's/^[[:space:]]*#\?[[:space:]]*no-cgroups[[:space:]]*=.*/no-cgroups = true/' "$config_path"
  else
    printf '\nno-cgroups = true\n' >>"$config_path"
  fi
}

configure_nvidia_runtime_with_ctk() {
  if ! command -v nvidia-ctk >/dev/null 2>&1; then
    if ! install_nvidia_container_toolkit_if_missing; then
      return 1
    fi
  fi

  nvidia-ctk runtime configure --runtime=docker >/dev/null 2>&1 || return 1
}

restart_docker_for_nvidia_runtime_change() {
  local restarted=0

  if command -v systemctl >/dev/null 2>&1; then
    if systemctl restart docker >/dev/null 2>&1; then
      restarted=1
    fi
  fi

  if (( restarted == 0 )) && command -v service >/dev/null 2>&1; then
    if service docker restart >/dev/null 2>&1; then
      restarted=1
    fi
  fi

  if (( restarted == 0 )); then
    die "Updated NVIDIA runtime config but could not restart Docker automatically."
  fi

  ensure_docker_running
}

nvidia_runtime_error_is_restricted_cgroups() {
  local err_text="$1"

  [[ "$err_text" == *"bpf_prog_query(BPF_CGROUP_DEVICE)"* ]] \
    || [[ "$err_text" == *"failed to add device rules"* ]] \
    || [[ "$err_text" == *"unable to find any existing device filters attached to the cgroup"* ]]
}

nvidia_runtime_error_is_cdi_setup() {
  local err_text="$1"

  [[ "$err_text" == *"failed to discover GPU vendor from CDI"* ]] \
    || [[ "$err_text" == *"no known GPU vendor found"* ]] \
    || [[ "$err_text" == *"could not select device driver"* ]]
}

docker_runtime_error_is_unsafe_procfs() {
  local err_text="$1"

  [[ "$err_text" == *"unsafe procfs detected"* ]] \
    || [[ "$err_text" == *"ip_unprivileged_port_start"* ]] \
    || [[ "$err_text" == *"invalid cross-device link"* ]]
}

docker_gpu_smoke_test() {
  local image
  image="${WORKER_IMAGE:-}"

  if [[ -z "$image" ]]; then
    warn "WORKER_IMAGE is empty; skipping Docker GPU smoke test."
    return 0
  fi

  if ! docker image inspect "$image" >/dev/null 2>&1; then
    warn "Worker image is not available locally yet; skipping Docker GPU smoke test."
    return 0
  fi

  docker run --rm --pull=never --gpus all --entrypoint nvidia-smi "$image" >/dev/null
}

auto_fix_restricted_nvidia_cgroups_if_needed() {
  local err_text
  local restricted_runtime

  err_text="$(docker run --rm --pull=never --gpus all --entrypoint nvidia-smi "${WORKER_IMAGE:-}" 2>&1 >/dev/null || true)"
  if [[ -z "$err_text" ]]; then
    return 0
  fi

  if nvidia_runtime_error_is_cdi_setup "$err_text"; then
    warn "Detected Docker CDI/NVIDIA runtime setup issue. Trying nvidia-ctk runtime configure."
    if ! configure_nvidia_runtime_with_ctk; then
      printf '%s\n' "$err_text" >&2
      die "Docker GPU startup failed with a CDI/NVIDIA runtime configuration error. Install and configure nvidia-container-toolkit."
    fi
    restart_docker_for_nvidia_runtime_change
    if docker_gpu_smoke_test; then
      log "Docker GPU smoke test passed after configuring NVIDIA runtime."
      return 0
    fi
    err_text="$(docker run --rm --pull=never --gpus all --entrypoint nvidia-smi "${WORKER_IMAGE:-}" 2>&1 >/dev/null || true)"
    if [[ -z "$err_text" ]]; then
      log "Docker GPU smoke test passed after configuring NVIDIA runtime."
      return 0
    fi
    if ! nvidia_runtime_error_is_restricted_cgroups "$err_text"; then
      printf '%s\n' "$err_text" >&2
      die "Docker GPU smoke test still fails after configuring NVIDIA runtime."
    fi
  fi

  if ! nvidia_runtime_error_is_restricted_cgroups "$err_text"; then
    if docker_runtime_error_is_unsafe_procfs "$err_text"; then
      print_error_block "$err_text"
      die_highlighted "This Docker environment is nested/restricted and cannot launch the worker container safely. Run the worker bootstrap on a real host VM or bare-metal node, not inside this containerized runtime."
    fi
    printf '%s\n' "$err_text" >&2
    die "Docker GPU smoke test failed before startup."
  fi

  restricted_runtime=""
  if docker_is_rootless; then
    restricted_runtime="rootless-docker"
  else
    restricted_runtime="$(restricted_container_runtime || true)"
  fi

  if [[ -z "$restricted_runtime" ]]; then
    warn "Docker GPU startup hit the NVIDIA cgroup device-rule error, but host restriction detection was inconclusive. Applying the NVIDIA no-cgroups workaround anyway."
    printf '%s\n' "$err_text" >&2
    restricted_runtime="error-signature"
  fi

  if nvidia_runtime_no_cgroups_enabled; then
    printf '%s\n' "$err_text" >&2
    die "Docker GPU startup still failed with restricted-environment NVIDIA cgroup errors even though no-cgroups is already enabled."
  fi

  warn "Detected NVIDIA restricted cgroup setup (${restricted_runtime}). Enabling no-cgroups = true and restarting Docker."
  enable_nvidia_runtime_no_cgroups
  restart_docker_for_nvidia_runtime_change

  if docker_gpu_smoke_test; then
    log "Docker GPU smoke test passed after updating NVIDIA runtime config."
    return 0
  fi

  err_text="$(docker run --rm --pull=never --gpus all --entrypoint nvidia-smi "${WORKER_IMAGE:-}" 2>&1 >/dev/null || true)"
  if docker_runtime_error_is_unsafe_procfs "$err_text"; then
    print_error_block "$err_text"
    die_highlighted "This Docker environment is nested/restricted and cannot launch the worker container safely. Run the worker bootstrap on a real host VM or bare-metal node, not inside this containerized runtime."
  fi

  die "Docker GPU smoke test still fails after enabling NVIDIA no-cgroups mode."
}

ensure_docker_gpu_runtime_ready() {
  if docker_gpu_smoke_test; then
    log "Docker GPU smoke test passed."
    return
  fi

  if ! docker info --format '{{json .Runtimes}}' 2>/dev/null | grep -q 'nvidia'; then
    install_nvidia_container_toolkit_if_missing || true
  fi

  auto_fix_restricted_nvidia_cgroups_if_needed
}

validate_gpu_prereqs() {
  if ! worker_requires_gpu; then
    return
  fi

  local available

  require_cmd nvidia-smi

  if ! nvidia-smi -L >/dev/null 2>&1; then
    die "No NVIDIA GPU detected."
  fi

  available="$(available_gpu_indices || true)"
  if [[ -z "$available" ]]; then
    die "NVIDIA GPU check failed (no visible GPU indices)."
  fi

  if ! docker info --format '{{json .Runtimes}}' 2>/dev/null | grep -q 'nvidia'; then
    warn "Docker does not report the nvidia runtime. If startup fails, install nvidia-container-toolkit."
  fi
}

urlencode() {
  local raw="$1"
  local i ch out=""
  for ((i = 0; i < ${#raw}; i++)); do
    ch="${raw:i:1}"
    case "$ch" in
      [a-zA-Z0-9.~_-])
        out+="$ch"
        ;;
      *)
        printf -v ch '%%%02X' "'$ch"
        out+="$ch"
        ;;
    esac
  done
  printf '%s' "$out"
}

setup_compose() {
  if docker compose version >/dev/null 2>&1; then
    COMPOSE_BIN=(docker compose)
    COMPOSE_BASE_ARGS=(--ansi auto --progress tty --project-name "$PROJECT_NAME" -f "$COMPOSE_FILE")
    return
  fi

  if command -v docker-compose >/dev/null 2>&1; then
    COMPOSE_BIN=(docker-compose)
    COMPOSE_BASE_ARGS=(-p "$PROJECT_NAME" -f "$COMPOSE_FILE")
    return
  fi

  die "Docker Compose is not installed."
}

compose() {
  "${COMPOSE_BIN[@]}" "${COMPOSE_BASE_ARGS[@]}" "$@"
}

login_registry() {
  if [[ -z "$REGISTRY_USER" || -z "$REGISTRY_TOKEN" ]]; then
    return
  fi

  log "Logging into worker registry..."
  printf '%s' "$REGISTRY_TOKEN" | docker login -u "$REGISTRY_USER" --password-stdin registry.gitlab.com >/dev/null 2>&1 \
    || die "Docker registry login failed."
}

remove_container_if_exists() {
  local name="$1"
  if docker container inspect "$name" >/dev/null 2>&1; then
    docker rm -f "$name" >/dev/null 2>&1 || warn "Failed to remove $name"
  fi
}

remove_if_stale() {
  local name="$1"
  local status
  local project

  if ! docker container inspect "$name" >/dev/null 2>&1; then
    return
  fi

  status="$(docker inspect -f '{{.State.Status}}' "$name" 2>/dev/null || printf 'unknown')"
  project="$(docker inspect -f '{{ index .Config.Labels "com.docker.compose.project" }}' "$name" 2>/dev/null || true)"

  if [[ "$status" == "running" ]]; then
    return
  fi

  log "Removing stale container: $name (status=$status, project=${project:-none})"
  docker rm -f "$name" >/dev/null 2>&1 || true
}

cleanup_stale_worker_containers() {
  remove_if_stale "dolphinpod-worker"
  remove_if_stale "dolphinpod-watchtower"
}

cleanup_existing_worker_containers() {
  local name

  for name in dolphinpod-worker dolphinpod-watchtower; do
    if docker container inspect "$name" >/dev/null 2>&1; then
      log "Removing existing container: $name"
      docker rm -f "$name" >/dev/null 2>&1 || warn "Failed to remove $name"
    fi
  done
}

remove_network_if_exists() {
  local name="$1"
  if docker network inspect "$name" >/dev/null 2>&1; then
    docker network rm "$name" >/dev/null 2>&1 || warn "Failed to remove network $name"
  fi
}

cleanup_dangling_images() {
  if ! docker image prune -f >/dev/null 2>&1; then
    warn "Could not clean temporary Docker image leftovers."
  fi
}

normalized_watchtower_host() {
  local host="${WATCHTOWER_BIND_IP:-}"

  if [[ -z "$host" || "$host" == "0.0.0.0" || "$host" == "::" ]]; then
    host="127.0.0.1"
  fi

  if [[ "$host" == *:* && "$host" != \[*\] ]]; then
    host="[$host]"
  fi

  printf '%s' "$host"
}

watchtower_dashboard_url() {
  local host
  local token

  host="$(normalized_watchtower_host)"
  token="$(urlencode "$WATCHTOWER_AUTH_TOKEN")"
  printf 'http://%s:%s/?token=%s' "$host" "$WATCHTOWER_PORT" "$token"
}

watchtower_external_dashboard_url() {
  local host
  local token
  host="$(hostname -I 2>/dev/null | awk '{for (i = 1; i <= NF; i++) if ($i !~ /^127\./) {print $i; exit}}')"
  if [[ -z "$host" ]]; then
    return
  fi
  token="$(urlencode "$WATCHTOWER_AUTH_TOKEN")"
  printf 'http://%s:%s/?token=%s' "$host" "$WATCHTOWER_PORT" "$token"
}

get_terminal_width() {
  local width="${COLUMNS:-}"

  if [[ -z "$width" ]] && command -v tput >/dev/null 2>&1; then
    width="$(tput cols 2>/dev/null || true)"
  fi

  if ! [[ "$width" =~ ^[0-9]+$ ]] || (( width < 40 )); then
    width=100
  fi

  printf '%s' "$width"
}

print_centered_line() {
  local text="$1"
  local width="$2"
  local text_len
  local pad_left

  text_len="${#text}"
  if (( text_len >= width )); then
    printf '%s\n' "$text"
    return
  fi

  pad_left=$(( (width - text_len) / 2 ))
  printf '%*s%s\n' "$pad_left" '' "$text"
}

append_wrapped_box_line() {
  local text="$1"
  local width="$2"
  local chunk
  local rest

  rest="$text"
  while [[ -n "$rest" ]]; do
    chunk="${rest:0:width}"
    panel_lines+=("| $(printf "%-${width}s" "$chunk") |")
    rest="${rest:width}"
  done
}

show_fullscreen_dashboard_prompt() {
  local local_url="$1"
  local network_url="${2:-}"
  local redraw_needed=1
  local used_fullscreen=""
  local warned_small_terminal=""

  if [[ ! -t 0 || ! -t 1 ]]; then
    log "Open worker dashboard:"
    printf '  Local:   %s\n' "$local_url"
    if [[ -n "$network_url" && "$network_url" != "$local_url" ]]; then
      printf '  Network: %s\n' "$network_url"
      printf '  Use Local on this machine. If this is a remote host, open Network from your own browser.\n'
    fi
    return
  fi

  cleanup_dashboard_prompt() {
    printf '\033[0m'
    tput cnorm >/dev/null 2>&1 || true
    tput clear >/dev/null 2>&1 || true
  }

  render_dashboard_prompt() {
    local cols
    local lines
    local required_cols
    local required_lines
    local top_pad
    local i
    local bg
    local fg
    local title_fg
    local box_fg
    local url_fg
    local box_title
    local box_border
    local box_header
    local inner_width
    local max_inner
    local min_inner_width
    local local_line
    local network_line
    local -a dolphin_lines panel_lines

    cols="$(tput cols 2>/dev/null || printf '80')"
    lines="$(tput lines 2>/dev/null || printf '24')"

    mapfile -t dolphin_lines <<<"$DOLPHIN_ASCII"

    box_title="DASHBOARD URLS"
    local_line="LOCAL: ${local_url}"
    network_line=""
    if [[ -n "$network_url" && "$network_url" != "$local_url" ]]; then
      network_line="NETWORK: ${network_url}"
    fi

    inner_width="${#box_title}"
    if (( ${#local_line} > inner_width )); then
      inner_width="${#local_line}"
    fi
    if (( ${#network_line} > inner_width )); then
      inner_width="${#network_line}"
    fi

    min_inner_width="$inner_width"
    max_inner=$(( cols - 8 ))
    if (( max_inner < 24 )); then
      max_inner=24
    fi
    if (( inner_width > max_inner )); then
      inner_width="$max_inner"
    fi

    box_border="+$(printf '%*s' "$(( inner_width + 2 ))" '' | tr ' ' '-')+"
    box_header="| $(printf "%-${inner_width}s" "$box_title") |"

    panel_lines=("")
    panel_lines+=("WORKER IS RUNNING")
    panel_lines+=("")
    panel_lines+=("Use LOCAL on this machine.")
    if [[ -n "$network_line" ]]; then
      panel_lines+=("If this is a remote host, open NETWORK from your own browser.")
    fi
    panel_lines+=("")
    panel_lines+=("$box_border")
    panel_lines+=("$box_header")
    panel_lines+=("$box_border")
    append_wrapped_box_line "$local_line" "$inner_width"
    if [[ -n "$network_line" ]]; then
      append_wrapped_box_line "$network_line" "$inner_width"
    fi
    panel_lines+=("$box_border")
    panel_lines+=("")
    panel_lines+=("Press ENTER to exit")
    panel_lines+=("")

    required_cols=$(( inner_width + 4 ))
    if (( ${#box_border} > required_cols )); then
      required_cols="${#box_border}"
    fi
    if (( ${#panel_lines[1]} > required_cols )); then
      required_cols="${#panel_lines[1]}"
    fi
    required_lines=$(( ${#dolphin_lines[@]} + ${#panel_lines[@]} + 1 ))

    if (( max_inner < min_inner_width || cols < required_cols || lines < required_lines )); then
      cleanup_dashboard_prompt
      if [[ -z "$warned_small_terminal" ]]; then
        warn "Terminal too small for fullscreen (${cols}x${lines}). Falling back to normal mode."
        warned_small_terminal=1
      fi
      log "Open worker dashboard:"
      printf '  Local:   %s\n' "$local_url"
      if [[ -n "$network_url" && "$network_url" != "$local_url" ]]; then
        printf '  Network: %s\n' "$network_url"
        printf '  Use Local on this machine. If this is a remote host, open Network from your own browser.\n'
      fi
      printf '  Resize the terminal and wait, or press ENTER to exit.\n'
      used_fullscreen=""
      return
    fi

    warned_small_terminal=""
    used_fullscreen=1
    top_pad=$(( (lines - ${#dolphin_lines[@]} - ${#panel_lines[@]} - 1) / 2 ))
    if (( top_pad < 0 )); then
      top_pad=0
    fi

    bg=$'\033[48;2;44;0;30m'
    fg=$'\033[38;2;255;255;255m'
    title_fg=$'\033[1;97m'
    box_fg=$'\033[38;2;255;190;240m'
    url_fg=$'\033[1;93m'

    printf '%b%b\033[2J\033[H' "$bg" "$fg"
    tput civis >/dev/null 2>&1 || true

    for ((i = 0; i < top_pad; i++)); do
      printf '\n'
    done

    for i in "${!dolphin_lines[@]}"; do
      printf '%b%b' "$bg" "$title_fg"
      print_centered_line "${dolphin_lines[$i]}" "$cols"
    done

    for i in "${!panel_lines[@]}"; do
      if [[ "${panel_lines[$i]}" == "WORKER IS RUNNING" ]]; then
        printf '%b%b' "$bg" "$title_fg"
        print_centered_line "${panel_lines[$i]}" "$cols"
        continue
      fi

      if [[ "${panel_lines[$i]}" == "Press ENTER to exit" ]]; then
        printf '%b%b' "$bg" "$fg"
        print_centered_line "${panel_lines[$i]}" "$cols"
        continue
      fi

      if [[ "${panel_lines[$i]}" == "$box_border" || "${panel_lines[$i]}" == "$box_header" ]]; then
        printf '%b%b' "$bg" "$box_fg"
        print_centered_line "${panel_lines[$i]}" "$cols"
        continue
      fi

      if [[ "${panel_lines[$i]}" == "| "* ]]; then
        printf '%b%b' "$bg" "$url_fg"
        print_centered_line "${panel_lines[$i]}" "$cols"
        continue
      fi

      printf '%b%b' "$bg" "$fg"
      print_centered_line "${panel_lines[$i]}" "$cols"
    done
  }

  trap 'cleanup_dashboard_prompt; printf "\n"; exit 130' INT TERM
  trap 'redraw_needed=1' WINCH

  while true; do
    if [[ "$redraw_needed" == "1" ]]; then
      render_dashboard_prompt
      redraw_needed=0
    fi

    if read -r -t 0.2; then
      break
    fi
  done

  cleanup_dashboard_prompt
  trap - INT TERM WINCH
}

current_worker_digest() {
  docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' dolphinpod-worker 2>/dev/null \
    | awk -F= '$1=="WORKER_IMAGE_DIGEST"{print $2; exit}'
}

worker_has_valid_digest() {
  local digest
  digest="$(current_worker_digest || true)"
  [[ -n "$digest" && "$digest" != "unknown" ]]
}

wait_for_worker_digest() {
  local timeout_s="${1:-90}"
  local start
  local now
  local last_report
  local elapsed

  start="$(date +%s)"
  last_report="$start"

  while true; do
    if worker_has_valid_digest; then
      return 0
    fi

    now="$(date +%s)"
    elapsed=$(( now - start ))
    if (( now - last_report >= 15 )); then
      log "Still waiting for worker digest... (${elapsed}s elapsed)"
      last_report="$now"
    fi
    if (( now - start >= timeout_s )); then
      return 1
    fi
    sleep 2
  done
}

wait_for_watchtower_api() {
  local timeout_s="${1:-60}"
  local host
  local base
  local start
  local now
  local last_report
  local elapsed

  require_cmd curl

  host="$(normalized_watchtower_host)"
  base="http://${host}:${WATCHTOWER_PORT}"
  start="$(date +%s)"
  last_report="$start"

  while ! curl -fsS --max-time 3 "${base}/health" >/dev/null 2>&1; do
    now="$(date +%s)"
    elapsed=$(( now - start ))
    if (( now - last_report >= 15 )); then
      log "Still waiting for watchtower API... (${elapsed}s elapsed)"
      last_report="$now"
    fi
    if (( now - start >= timeout_s )); then
      return 1
    fi
    sleep 2
  done

  return 0
}

ensure_worker_digest_via_watchtower() {
  local host
  local base
  local -a auth_header

  if worker_has_valid_digest; then
    return 0
  fi

  require_cmd curl

  host="$(normalized_watchtower_host)"
  base="http://${host}:${WATCHTOWER_PORT}"

  log "Waiting for watchtower API..."
  if ! wait_for_watchtower_api 60; then
    warn "Watchtower API did not become ready in time."
    return 1
  fi

  auth_header=()
  if [[ -n "${WATCHTOWER_AUTH_TOKEN:-}" ]]; then
    auth_header=(-H "X-Watchtower-Token: ${WATCHTOWER_AUTH_TOKEN}")
  fi

  log "Worker digest missing. Restarting watchtower..."
  docker restart dolphinpod-watchtower >/dev/null 2>&1 || true
  if ! wait_for_watchtower_api 60; then
    warn "Watchtower API did not recover after restart."
    return 1
  fi

  if wait_for_worker_digest 45; then
    log "Worker digest is set."
    return 0
  fi

  log "Digest still missing. Requesting watchtower update..."
  if ! curl -fsS --max-time 10 -X POST "${auth_header[@]}" "${base}/update" >/dev/null 2>&1; then
    warn "Could not trigger watchtower update."
    return 1
  fi

  if wait_for_worker_digest 120; then
    log "Worker digest is set."
    return 0
  fi

  warn "Worker digest was not set in time."
  return 1
}

start_worker() {
  local local_url
  local network_url

  export WORKER_STARTUP_DEBUG="${WORKER_STARTUP_DEBUG:-${STARTUP_DEBUG:-}}"

  printf '%s\n' "$DOLPHIN_ASCII"
  install_docker_if_missing
  ensure_docker_running
  set_worker_compose_gpu_block
  validate_gpu_prereqs
  setup_compose
  mkdir -p "$SCRIPT_DIR/worker-models" "$SCRIPT_DIR/worker-data"
  clear_worker_config_json_for_bootstrap
  write_embedded_compose_file
  log "Cleaning old worker containers..."
  cleanup_existing_worker_containers
  login_registry
  log "Pulling worker images..."
  compose pull || warn "Image pull failed. Continuing with local images if they exist."
  if worker_requires_gpu; then
    ensure_docker_gpu_runtime_ready
  fi
  log "Starting worker stack..."
  compose up -d --remove-orphans worker watchtower
  if ! ensure_worker_digest_via_watchtower; then
    die "Worker digest is still missing. Check: docker logs dolphinpod-watchtower"
  fi
  ensure_worker_config_json
  log "Final cleanup..."
  cleanup_stale_worker_containers
  log "Cleaning temporary Docker leftovers..."
  cleanup_dangling_images
  compose ps
  local_url="$(watchtower_dashboard_url)"
  network_url="$(watchtower_external_dashboard_url || true)"
  if [[ "$network_url" == "$local_url" ]]; then
    network_url=""
  fi
  show_fullscreen_dashboard_prompt "$local_url" "$network_url"
}

stop_worker() {
  require_cmd docker
  docker info >/dev/null 2>&1 || die "Docker is not running."
  log "Stopping worker stack..."
  remove_container_if_exists "dolphinpod-worker"
  remove_container_if_exists "dolphinpod-watchtower"
  remove_network_if_exists "dolphinpod-worker_worker-net"
  remove_network_if_exists "dolphinpod-worker_default"
  log "Worker stopped."
}

status_worker() {
  local local_url
  local network_url

  require_cmd docker
  docker ps --filter 'name=dolphinpod-worker' --filter 'name=dolphinpod-watchtower'
  local_url="$(watchtower_dashboard_url)"
  network_url="$(watchtower_external_dashboard_url || true)"
  printf 'Dashboard: %s\n' "$local_url"
  if [[ -n "$network_url" && "$network_url" != "$local_url" ]]; then
    printf 'Network: %s\n' "$network_url"
  fi
}

show_logs() {
  require_cmd docker
  docker logs -f dolphinpod-worker
}

usage() {
  cat <<EOF
Usage:
  ./$SCRIPT_NAME [start|stop|status|logs]

Examples:
  sudo ./$SCRIPT_NAME
  sudo ./$SCRIPT_NAME stop
  sudo ./$SCRIPT_NAME status
EOF
}

main() {
  local action="${1:-start}"

  case "$action" in
    start)
      ensure_root "$@"
      start_worker
      ;;
    stop)
      ensure_root "$@"
      stop_worker
      ;;
    status)
      status_worker
      ;;
    logs)
      show_logs
      ;;
    -h|--help|help)
      usage
      ;;
    *)
      usage
      die "Unknown action: $action"
      ;;
  esac
}

main "$@"
