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
    echo 'cat /etc/computenet.txt' >> /root/.bashrc && \
    echo 'echo -e "\nmade with ❤️  by Datura\n\n"' >> /root/.bashrc

# Set the default command for the container
ENTRYPOINT []
CMD [ "/pytorch-entrypoint.sh" ]
