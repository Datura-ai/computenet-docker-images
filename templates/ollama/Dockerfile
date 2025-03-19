# Base Image
FROM daturaai/pytorch:2.6.0-py3.12-cuda12.6.0-devel-ubuntu22.04

# Install necessary dependencies
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    curl \
    lshw \
    && rm -rf /var/lib/apt/lists/*

RUN wget https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2204/x86_64/cuda-keyring_1.1-1_all.deb && \
    dpkg -i cuda-keyring_1.1-1_all.deb && \
    apt-get update && \
    apt-get -y --allow-change-held-packages install libcublas-12-6 libcublas-dev-12-6 && \
    apt-get -y --allow-change-held-packages install --no-install-recommends cuda-toolkit-12-6 && \
    rm cuda-keyring_1.1-1_all.deb

# Download and install Ollama
RUN wget https://github.com/ollama/ollama/releases/download/v0.6.2/ollama-linux-amd64.tgz
RUN tar -xvzf ollama-linux-amd64.tgz && \
    chmod +x /usr/bin/ollama

COPY settings.json /root/.local/share/code-server/User/settings.json
COPY tasks.json /root/.local/share/code-server/User/tasks.json

# Start Scripts
COPY --from=scripts start.sh /
RUN chmod +x /start.sh

# Set environment variables for runtime
ENV OLLAMA_HOST=0.0.0.0
ENV PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ENV LD_LIBRARY_PATH=/usr/local/nvidia/lib:/usr/local/nvidia/lib64
ENV NVIDIA_DRIVER_CAPABILITIES=compute,utility
ENV NVIDIA_VISIBLE_DEVICES=all

# Expose the required port
EXPOSE 11434


CMD ["/start.sh"]
