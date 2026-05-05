
# Use the docker:dind image as the base
FROM cruizba/ubuntu-dind:latest

# Install OpenSSH server and NVIDIA dependencies
RUN apt-get update && apt-get install -y \
    openssh-server \
    curl \
    wget \
    gnupg2 \
    software-properties-common \
    apt-transport-https \
    ca-certificates

# Install NVIDIA Container Toolkit using the official method for Ubuntu
RUN curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg \
    && curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
       sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
       tee /etc/apt/sources.list.d/nvidia-container-toolkit.list

# Update and install NVIDIA tools
RUN apt-get update && apt-get install -y nvidia-container-toolkit
RUN nvidia-ctk runtime configure --runtime=docker

COPY daemon.json /etc/docker/daemon.json
COPY config.toml /etc/nvidia-container-runtime/config.toml

# Start Scripts
COPY --from=scripts start.sh /
RUN chmod +x /start.sh

COPY entrypoint.sh /
RUN chmod +x /entrypoint.sh

COPY nvidia-setup.sh /
RUN chmod +x /nvidia-setup.sh

# Bundle the official hello-world image so the validator's DinD sysbox probe (DAH-1959)
# can confirm nested docker works without ever pulling from Docker Hub. Anonymous pulls
# hit per-IP rate limits when many executors share a NAT, which falsely flagged miners
# as sysbox=False and cut their reward multiplier. The tarball is loaded asynchronously
# right after the inner dockerd becomes reachable; if the load fails the probe falls
# back to a registry pull (previous behaviour), so this is best-effort and never blocks
# dockerd startup.
COPY hello-world.tar /opt/probe/hello-world.tar
COPY load-probe.sh /usr/local/bin/load-probe.sh
RUN chmod +x /usr/local/bin/load-probe.sh

# Welcome Message
COPY --from=scripts computenet.txt /etc/computenet.txt
RUN echo 'cat /etc/computenet.txt' >> /root/.bashrc
RUN echo 'echo -e "\nmade with ❤️  by Datura\n\n"' >> /root/.bashrc

# Start SSH and Docker daemon. The load-probe runs SYNCHRONOUSLY before /start.sh
# so the bundled hello-world image is guaranteed to be in the inner dockerd's store
# before sshd starts accepting validator connections — eliminates the race where the
# validator's DinD probe (which waits ~5 s after `docker run` then SSHes in) could land
# in the window between dockerd-ready and docker-load-complete.
#
# The base image's ENTRYPOINT (start-docker.sh from cruizba/ubuntu-dind) has already
# brought dockerd up by the time CMD runs, so load-probe's first `docker info` poll
# succeeds immediately and the whole script completes in ~1-2 s. Worst case (bundled
# tar missing or `docker load` fails) load-probe exits non-zero, the `;` keeps the
# pipeline going, and the inner dockerd just lacks the bundled image — the validator
# probe then falls back to a registry pull (pre-DAH-1959 behaviour). It is not an `&&`
# on purpose: a load failure must not block container startup.
CMD ["bash", "-c", "/usr/local/bin/load-probe.sh ; /nvidia-setup.sh && /start.sh"]