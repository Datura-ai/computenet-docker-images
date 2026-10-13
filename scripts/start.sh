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
#   - a host key is generated only when missing, with stdin from /dev/null:
#     when the other side creates it first, the "Overwrite (y/n)?" prompt
#     that once blocked PID 1 gets EOF and ssh-keygen gives up at once
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

    # ED25519 and ECDSA before sshd starts; RSA takes 0.4-1.5 s to generate,
    # so add_rsa_host_key makes it after sshd answers.
    local key_type key_file
    for key_type in ed25519 ecdsa; do
        key_file="/etc/ssh/ssh_host_${key_type}_key"
        [ -f "$key_file" ] || { ssh-keygen -q -t "$key_type" -N "" -f "$key_file" < /dev/null \
            || echo "WARNING: ssh-keygen -t $key_type failed" >&2; } &
    done
    wait
    mkdir -p /run/sshd

    if is_sshd_running; then
        echo "sshd is already running; skipping service start"
    elif ! /usr/sbin/sshd; then
        # Lost a start race (port already bound by the validator bootstrap's
        # sshd) — only a real failure if sshd is genuinely not up afterwards.
        # sshd is started directly: `service ssh start` costs 30 ms more.
        if is_sshd_running; then
            echo "sshd was started concurrently; continuing"
        else
            echo "WARNING: failed to start sshd" >&2
        fi
    fi

    release_ssh_setup_lock
    add_rsa_host_key &

    echo "SSH host keys:"
    for key in /etc/ssh/*.pub; do
        [ -f "$key" ] || continue
        echo "Key: $key"
        ssh-keygen -lf "$key" || true
    done
}

# For clients that know neither ED25519 nor ECDSA.
add_rsa_host_key() {
    local key_file=/etc/ssh/ssh_host_rsa_key
    acquire_ssh_setup_lock
    [ -f "$key_file" ] || ssh-keygen -q -t rsa -N "" -f "$key_file" < /dev/null \
        || echo "WARNING: ssh-keygen -t rsa failed" >&2
    release_ssh_setup_lock
    [ -f "$key_file" ] || return 0
    # sshd before OpenSSH 9.8 reads its host keys on every connection and offers the
    # new key at once; 9.8+ needs a reload, which refuses connections for a few ms.
    if ! ssh-keyscan -t rsa 127.0.0.1 2>/dev/null | grep -q ssh-rsa && [ -f /run/sshd.pid ]; then
        echo "Reloading sshd to offer the RSA host key"
        kill -HUP "$(cat /run/sshd.pid)" || true
    fi
}

# Start jupyter lab
start_jupyter() {
    if [[ $JUPYTER_PASSWORD ]]; then
        echo "Starting Jupyter Lab..."
        # The pod's volume (encrypted or not) may be mounted over /root after Jupyter starts and would hide
        # its runtime dir under /root: every kernel start would then fail.
        mkdir -p /workspace && \
        cd / && \
        JUPYTER_RUNTIME_DIR=/run/jupyter nohup jupyter lab --allow-root --no-browser --port=8888 --ip=* --FileContentsManager.delete_to_trash=False --ServerApp.terminado_settings='{"shell_command":["/bin/bash"]}' --ServerApp.token=$JUPYTER_PASSWORD --ServerApp.allow_origin=* --ServerApp.preferred_dir=/workspace &> /jupyter.log &
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
