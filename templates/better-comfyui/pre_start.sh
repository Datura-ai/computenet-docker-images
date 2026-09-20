#!/bin/bash
# pre_start.sh — run by /start.sh (scripts/start.sh) in the foreground: first-time sync of the venv and the ComfyUI tree
# into /workspace, then the ComfyUI server on :3000. PID 1 blocks here while ComfyUI runs; when the server exits, control
# returns to /start.sh, which keeps the pod up for SSH (`sleep infinity`) — the reason is in /workspace/comfyui.log.

# Set a default TERM if it's not set
if [ -z "$TERM" ]; then
    export TERM=xterm-256color
fi

# Exit immediately if a command exits with a non-zero status
set -e

# Function to print colorized feedback
print_feedback() {
    GREEN='\033[0;32m'
    NC='\033[0m' # No Color
    echo -e "${GREEN}[ComfyUI Startup]:${NC} $1"
}

# A command that fails under `set -e` would end this script and, through /start.sh's own `set -e`, the container.
# A pod the renter can still reach over SSH, with this line in `docker logs`, is worth more than a dead one, so the
# failure is reported and control goes back to /start.sh (SSH setup, `sleep infinity`).
on_error() {
    local rc=$? line=$1
    print_feedback "pre_start.sh failed at line $line (exit $rc): ComfyUI was not started; the pod stays up for SSH"
    exit 0
}
trap 'on_error $LINENO' ERR

# Function to run rsync with progress bar and optimizations
rsync_with_progress() {
    rsync -aHvx --info=progress2 --ignore-existing --update --stats "$@"
}

# Check for required commands
if ! command -v rsync &> /dev/null; then
    echo "rsync could not be found, please install it."
    exit 1
fi

LOG_FILE="/workspace/comfyui.log"

# Copy the notebook and install-flux.sh script to the /workspace directory
print_feedback "Copying notebook and install script to /workspace..."
mkdir -p /workspace
cp /comfyui_extras.ipynb /workspace/
cp /install-flux.sh /workspace/

# Check if the NO_SYNC variable is set to true
if [ "${NO_SYNC}" == "true" ]; then
    print_feedback "Skipping sync and startup as per environment variable setting."
    exec bash -c 'sleep infinity'
fi

print_feedback "Starting ComfyUI setup..."

print_feedback "Syncing virtual environment..."
# The venv was built at this path (its bin/activate and pyvenv.cfg name it) and moved to /venv in the image;
# the first start copies it back here, so everything below uses this copy through its own interpreter.
VIRTUAL_ENV="/workspace/venvs/better-comfyui"
SOURCE_VENV="/venv"

if [ ! -d "$VIRTUAL_ENV" ]; then
    clear 2>/dev/null || true
    echo -e "\e[1;33m"
    cat << "EOF"
 _____________________________________
|                                     |
|  !!! ATTENTION - FIRST TIME SYNC !!!|
|                                     |
|  This process will take ~10 minutes |
|_____________________________________|

EOF
    echo -e "\e[0m"

    mkdir -p "$VIRTUAL_ENV"

    # Start background process to show progress
    (
        while true; do
            for s in / - \\ \|; do
                printf "\r\033[1;31m[%s] \033[1;37mSYNC IN PROGRESS - PLEASE WAIT\033[0m" "$s"
                sleep 0.5
            done
        done
    ) &
    PROGRESS_PID=$!

    # Perform the sync
    rsync -aHx --info=progress2 --stats --exclude='*.pyc' --exclude='__pycache__' "$SOURCE_VENV/" "$VIRTUAL_ENV/"

    # Stop the progress indicator. `wait` on a killed child returns 128+SIGTERM (143); under `set -e` a bare
    # `wait $PID` ends this script right here and the container with it (DAH-3704), so the status is swallowed.
    kill "$PROGRESS_PID" 2>/dev/null || true
    wait "$PROGRESS_PID" 2>/dev/null || true

    clear 2>/dev/null || true
    echo -e "\e[1;32m"
    cat << "EOF"
 _____________________________________
|                                     |
|        SYNC COMPLETED SUCCESS       |
|_____________________________________|

EOF
    echo -e "\e[0m"
else
    print_feedback "Subsequent sync: Updating venv without overwriting existing files..."
    rsync -aHx --info=progress2 --stats --exclude='*.pyc' --exclude='__pycache__' --ignore-existing --update "$SOURCE_VENV/" "$VIRTUAL_ENV/"
fi

print_feedback "Using virtual environment $VIRTUAL_ENV..."
# Same effect as bin/activate without sourcing it; ComfyUI and its custom-node installs run through this interpreter.
export VIRTUAL_ENV
export PATH="$VIRTUAL_ENV/bin:$PATH"
PYTHON="$VIRTUAL_ENV/bin/python"

export PYTHONUNBUFFERED=1

print_feedback "Syncing ComfyUI files..."
rsync_with_progress /ComfyUI/ /workspace/ComfyUI/

print_feedback "Creating symbolic links for model checkpoints..."
mkdir -p /workspace/ComfyUI/models/checkpoints
for model in /comfy-models/*; do
    # the light image ships no checkpoints: an unmatched glob must not become a dangling `*` link
    if [ -e "$model" ]; then
        ln -sf "$model" /workspace/ComfyUI/models/checkpoints/
    fi
done

print_feedback "Changing to ComfyUI directory..."
cd /workspace/ComfyUI

print_feedback "Starting ComfyUI server..."
print_feedback "ComfyUI will be available at http://0.0.0.0:3000"

COMFY_ARGS=(--listen --port 3000 --enable-cors-header)
# CUSTOM_ARGS is a space-separated list of extra ComfyUI flags (e.g. "--lowvram --preview-method auto")
if [ -n "$CUSTOM_ARGS" ]; then
    read -r -a EXTRA_ARGS <<< "$CUSTOM_ARGS"
    COMFY_ARGS+=("${EXTRA_ARGS[@]}")
fi

# Foreground: the container is alive on the server. The pipeline's status is tee's, so a server exit never trips
# `set -e`; its own exit code is read from PIPESTATUS and logged before /start.sh takes over.
"$PYTHON" main.py "${COMFY_ARGS[@]}" 2>&1 | tee -a "$LOG_FILE"
COMFY_RC=${PIPESTATUS[0]}
print_feedback "ComfyUI exited with status $COMFY_RC — the pod stays up for SSH; see $LOG_FILE"
