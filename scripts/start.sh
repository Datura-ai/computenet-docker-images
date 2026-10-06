#!/bin/bash
set -e  # Exit the script if any statement returns a non-true return value

# ---------------------------------------------------------------------------- #
#                          Function Definitions                                #
# ---------------------------------------------------------------------------- #

# Start nginx service
start_nginx() {
    if [[ $REQUIRE_NGINIX == "true" ]]; then
        echo "Starting Nginx service..."
        service nginx start
    fi
}

# Execute script if exists
execute_script() {
    local script_path=$1
    local script_msg=$2
    if [[ -f ${script_path} ]]; then
        echo "${script_msg}"
        bash ${script_path}
    fi
}

# Setup ssh
#
# The Lium validator execs its own SSH bootstrap (ssh-keygen -A + sshd start)
# into the container right after `docker run`, so everything here can race a
# concurrent writer of /etc/ssh and the sshd daemon (DAH-2341):
#   - a shared mkdir lock serializes the two writers when both take it
#   - `ssh-keygen -A` never prompts and skips key types that already exist
#     (the per-type `ssh-keygen -t -f` it replaces blocked PID 1 on an
#     "Overwrite (y/n)?" prompt when the other side created the key first)
#   - an sshd that is already running counts as success, not an error
# None of this may kill PID 1 (`set -e` is active): if SSH setup fails, the
# container must stay alive so the validator bootstrap can still repair it.
SSH_SETUP_LOCK_DIR="/run/lium-ssh-setup.lock"
SSH_SETUP_LOCK_HELD=0

is_sshd_running() {
    # ps fallback for images that ship start.sh without procps (no pgrep).
    if command -v pgrep >/dev/null 2>&1; then
        pgrep -x sshd >/dev/null 2>&1 && return 0
    elif ps -ef 2>/dev/null | grep '[s]shd' >/dev/null 2>&1; then
        return 0
    fi
    return 1
}

acquire_ssh_setup_lock() {
    local i=0
    while ! mkdir "$SSH_SETUP_LOCK_DIR" 2>/dev/null; do
        if [ "$i" -ge 120 ]; then
            echo "SSH setup lock busy for 60s; proceeding without it" >&2
            return 0
        fi
        i=$((i + 1))
        sleep 0.5
    done
    SSH_SETUP_LOCK_HELD=1
}

release_ssh_setup_lock() {
    if [ "$SSH_SETUP_LOCK_HELD" -eq 1 ]; then
        rmdir "$SSH_SETUP_LOCK_DIR" 2>/dev/null || true
        SSH_SETUP_LOCK_HELD=0
    fi
}

setup_ssh() {
    echo "Setting up SSH..."

    acquire_ssh_setup_lock

    ssh-keygen -A || echo "WARNING: ssh-keygen -A failed" >&2
    mkdir -p /run/sshd

    if is_sshd_running; then
        echo "sshd is already running; skipping service start"
    elif ! service ssh start; then
        # Lost a start race (port already bound by the validator bootstrap's
        # sshd) or an init-script hiccup — only a real failure if sshd is
        # genuinely not up afterwards.
        if is_sshd_running; then
            echo "sshd was started concurrently; continuing"
        else
            echo "WARNING: failed to start sshd" >&2
        fi
    fi

    release_ssh_setup_lock

    echo "SSH host keys:"
    for key in /etc/ssh/*.pub; do
        [ -f "$key" ] || continue
        echo "Key: $key"
        ssh-keygen -lf "$key" || true
    done
}

# Start jupyter lab
start_jupyter() {
    if [[ $JUPYTER_PASSWORD ]]; then
        echo "Starting Jupyter Lab..."
        mkdir -p /workspace && \
        cd / && \
        nohup jupyter lab --allow-root --no-browser --port=8888 --ip=* --FileContentsManager.delete_to_trash=False --ServerApp.terminado_settings='{"shell_command":["/bin/bash"]}' --ServerApp.token=$JUPYTER_PASSWORD --ServerApp.allow_origin=* --ServerApp.preferred_dir=/workspace &> /jupyter.log &
        echo "Jupyter Lab started"
    fi
}

# ---------------------------------------------------------------------------- #
#                               Main Program                                   #
# ---------------------------------------------------------------------------- #

start_nginx

execute_script "/pre_start.sh" "Running pre-start script..."

echo "Pod Started"

setup_ssh
start_jupyter

execute_script "/post_start.sh" "Running post-start script..."

echo "Start script(s) finished, pod is ready to use."

sleep infinity
