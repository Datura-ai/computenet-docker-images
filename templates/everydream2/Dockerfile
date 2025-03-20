ARG BASE_IMAGE=daturaai/pytorch:2.6.0-py3.12-cuda12.6.0-devel-ubuntu22.04
FROM ${BASE_IMAGE} as base

ARG DEBIAN_FRONTEND=noninteractive
ARG TORCH
ARG TORCHVISION
ARG TORCHAUDIO
ARG PYTHON_VERSION

# Use bash shell
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# Set environment variables
ENV DEBIAN_FRONTEND=noninteractive
ENV SHELL=/bin/bash
ENV PYTHONUNBUFFERED=1
ENV LD_LIBRARY_PATH="/usr/local/cuda-12.6/targets/x86_64-linux/lib/"

# Create workspace directory
WORKDIR /

# Install any additional packages not included in the base image
RUN apt-get update --yes && \
    apt-get upgrade --yes && \
    apt-get autoremove -y && \
    apt install --yes --no-install-recommends \
    git wget curl bash libgl1 software-properties-common \
    openssh-server nginx rsync nano ffmpeg tmux && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* && \
    echo "en_US.UTF-8 UTF-8" > /etc/locale.gen

# Clone EveryDream2trainer repository
WORKDIR /root
RUN git clone https://github.com/victorchall/EveryDream2trainer
ENV PYTHONUNBUFFERED=1
# Add requirements files and install Python packages from the cloned repository
RUN pip install --upgrade --no-cache-dir pip && \
    pip install --no-deps xformers aiohttp && \
    pip install --no-cache-dir -r /root/EveryDream2trainer/docker/requirements-build.txt && \
    grep -v 'aiohttp' /root/EveryDream2trainer/docker/requirements-runtime.txt | pip install -U --no-cache-dir -r /dev/stdin


# Copy pre_start.sh script to the image
COPY pre_start.sh /pre_start.sh
RUN chmod +x /pre_start.sh

# Copy notebook
COPY Train_Cellium.ipynb /root/EveryDream2trainer/Train_Cellium.ipynb

# Start Scripts
COPY --from=scripts start.sh /
RUN chmod +x /start.sh

# Set the default command for the container
CMD [ "/start.sh" ]
