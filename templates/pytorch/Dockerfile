ARG BASE_IMAGE=nvidia/cuda
FROM ${BASE_IMAGE}

ARG TORCH
ARG PYTHON_VERSION
ARG ENABLE_DIND=false
ARG DOCKER_VERSION=27.3.1
ARG CONTAINERD_VERSION=1.7.23-1

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# Set environment variables
ENV DEBIAN_FRONTEND=noninteractive
ENV SHELL=/bin/bash
ENV ENABLE_DIND=${ENABLE_DIND}

# Set the working directory
WORKDIR /

# Create workspace directory
RUN mkdir /workspace

# Update, upgrade, install packages, install python if PYTHON_VERSION is specified, clean up
RUN apt-get update --yes && \
    apt-get upgrade --yes && \
    apt install --yes --no-install-recommends \
        apt-transport-https \
        bash \
        build-essential \
        ca-certificates \
        curl \
        fuse3 \
        git \
        gnupg2 \
        htop \
        iproute2 \
        iptables \
        iputils-ping \
        jq \
        kmod \
        less \
        libgl1 \
        lsof \
        nano \
        net-tools \
        openssh-server \
        procps \
        rsync \
        software-properties-common \
        sudo \
        tmux \
        tree \
        unzip \
        vim \
        wget \
        zip && \
    if [ -n "${PYTHON_VERSION}" ]; then \
        add-apt-repository ppa:deadsnakes/ppa && \
        apt-get update --yes && \
        apt install "python${PYTHON_VERSION}" "python${PYTHON_VERSION}-dev" "python${PYTHON_VERSION}-venv" -y --no-install-recommends; \
    fi && \
    apt-get autoremove -y && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* && \
    echo "en_US.UTF-8 UTF-8" > /etc/locale.gen

# gocryptfs powers lium encrypted local volumes
ARG GOCRYPTFS_VERSION=2.6.1
RUN curl -fsSL \
        "https://github.com/rfjakob/gocryptfs/releases/download/v${GOCRYPTFS_VERSION}/gocryptfs_v${GOCRYPTFS_VERSION}_linux-static_amd64.tar.gz" \
        -o /tmp/gocryptfs.tgz && \
    tar -xzf /tmp/gocryptfs.tgz -C /usr/local/bin gocryptfs && \
    chmod 0755 /usr/local/bin/gocryptfs && \
    rm -f /tmp/gocryptfs.tgz && \
    gocryptfs --version

# label that enables encrypted volume provisioning in lium
LABEL lium.volume_encryption.enable="1"

# Install Docker Engine and NVIDIA runtime support only for DinD-enabled targets
# that do not already provide Docker.
RUN if [[ "${ENABLE_DIND}" == "true" ]] && ! command -v docker >/dev/null 2>&1; then \
        install -m 0755 -d /etc/apt/keyrings && \
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg && \
        chmod a+r /etc/apt/keyrings/docker.gpg && \
        . /etc/os-release && \
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${VERSION_CODENAME} stable" > /etc/apt/sources.list.d/docker.list && \
        curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg && \
        curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
            sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
            tee /etc/apt/sources.list.d/nvidia-container-toolkit.list && \
        apt-get update --yes && \
        DOCKER_APT_VERSION="5:${DOCKER_VERSION}-1~ubuntu.${VERSION_ID}~${VERSION_CODENAME}" && \
        apt-get install --yes --no-install-recommends \
            docker-ce="${DOCKER_APT_VERSION}" \
            docker-ce-cli="${DOCKER_APT_VERSION}" \
            containerd.io="${CONTAINERD_VERSION}" \
            docker-buildx-plugin \
            docker-compose-plugin \
            nvidia-container-toolkit && \
        nvidia-ctk runtime configure --runtime=docker && \
        apt-get clean && \
        rm -rf /var/lib/apt/lists/*; \
    fi

# Set up Python and pip only if PYTHON_VERSION is specified
RUN if [ -n "${PYTHON_VERSION}" ]; then \
        ln -s /usr/bin/python${PYTHON_VERSION} /usr/bin/python && \
        rm -f /usr/bin/python3 && \
        ln -s /usr/bin/python${PYTHON_VERSION} /usr/bin/python3 && \
        curl https://bootstrap.pypa.io/get-pip.py -o get-pip.py && \
        python get-pip.py --break-system-packages; \
        rm -f get-pip.py; \
    fi && \
    pip install --upgrade --no-cache-dir pip --break-system-packages && \
    if [ -n "${TORCH}" ]; then pip install --upgrade --no-cache-dir ${TORCH} --break-system-packages; fi && \
    pip install --upgrade --no-cache-dir jupyterlab ipywidgets jupyter-archive jupyter_contrib_nbextensions notebook==6.5.7 --break-system-packages && \
    jupyter contrib nbextension install --user && \
    jupyter nbextension enable --py widgetsnbextension

COPY --from=scripts start.sh computenet.txt /tmp/computenet-scripts/
COPY daemon.json config.toml nvidia-setup.sh pytorch-entrypoint.sh /tmp/pytorch-files/
RUN rm -f /etc/ssh/ssh_host_* && \
    install -m 0755 /tmp/computenet-scripts/start.sh /start.sh && \
    install -m 0644 /tmp/computenet-scripts/computenet.txt /etc/computenet.txt && \
    install -m 0644 -D /tmp/pytorch-files/daemon.json /etc/docker/daemon.json && \
    install -m 0644 -D /tmp/pytorch-files/config.toml /etc/nvidia-container-runtime/config.toml && \
    install -m 0755 /tmp/pytorch-files/nvidia-setup.sh /nvidia-setup.sh && \
    install -m 0755 /tmp/pytorch-files/pytorch-entrypoint.sh /pytorch-entrypoint.sh && \
    rm -rf /tmp/computenet-scripts /tmp/pytorch-files && \
    # Lium welcome banner. It MUST live outside /root: lium mounts a volume at
    # /root for rentals (full-node rentals use a sparse loopback volume), which
    # shadows the image's /root/.bashrc and hides any banner appended there — so
    # the logo never prints in a real rental. Install it as an interactive-only
    # /etc/profile.d script (sourced by login shells, i.e. the renter's ssh
    # session) and strip the base image's /root/.bashrc copy so it can't
    # double-print on paths where /root is NOT shadowed (partial rentals, local).
    sed -i '/cat \/etc\/computenet\.txt/d; /made with .* by Datura/d' /root/.bashrc 2>/dev/null || true; \
    printf '%s\n' \
        'case "$-" in' \
        '  *i*)' \
        '    [ -r /etc/computenet.txt ] && cat /etc/computenet.txt' \
        '    printf "\nmade with ❤️  by Datura\n\n" ;;' \
        'esac' \
        > /etc/profile.d/zz-lium-welcome.sh && \
    chmod 0644 /etc/profile.d/zz-lium-welcome.sh

# Start dockerd from ENTRYPOINT so the nested daemon survives a CMD override
# (lium's validator appends the renter's startup command, which replaces CMD).
# The entrypoint then execs CMD — the default /start.sh, or the caller's command.
ENTRYPOINT [ "/pytorch-entrypoint.sh" ]
CMD [ "/start.sh" ]
