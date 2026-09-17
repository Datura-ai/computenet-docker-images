
# Base: Ubuntu 24.04 + Docker 28.0.4, what daturaai/dind:0.0.1 was built from. Pinned (DAH-2856): `latest`
# moved to Ubuntu 26.04 / Docker 29.7.2 in Sep 2026, and a rebuild for one fix should not also change the OS
# and the dockerd version the probe runs on. Bump on purpose, in its own change.
FROM cruizba/ubuntu-dind:noble-28.0.4

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

# DAH-2856: the inner dockerd talks to the kernel through iptables. The base image selects the
# legacy binary, which needs the ip_tables/iptable_nat kernel modules loaded ON THE HOST; a host
# whose own iptables runs in nf_tables mode with nothing else loading those modules (Debian 12+,
# Ubuntu without ufw) leaves the inner dockerd dying at `iptables -t nat -N DOCKER` with
# "can't initialize iptables table `nat': Table does not exist", sshd never starts and the
# validator scores the node as "no sysbox" (ticket-0309: three reinstalls). A sysbox container
# cannot modprobe. iptables-nft only needs nf_tables, which every host running a current dockerd
# already has. The default is nft; select-iptables-backend.sh (run first by load-probe-entrypoint.sh)
# falls back to legacy at start when nft cannot open a table but legacy can (legacy-only hosts).
RUN update-alternatives --set iptables /usr/sbin/iptables-nft \
    && update-alternatives --set ip6tables /usr/sbin/ip6tables-nft

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
# as sysbox=False and cut their reward multiplier.
#
# The tarball is loaded by load-probe.sh, which is invoked through an ENTRYPOINT chain
# (load-probe-entrypoint.sh -> cruizba's start-docker.sh -> load-and-exec.sh -> user CMD)
# so the load completes BEFORE any user-supplied command (in particular, the lium
# validator's `service ssh start` chain) runs. ENTRYPOINT was chosen because lium's
# validator overrides CMD, so any setup we put in CMD would be silently dropped.
# A failed load is best-effort: the validator probe just falls back to a registry pull.
COPY hello-world.tar /opt/probe/hello-world.tar
COPY load-probe.sh load-probe-entrypoint.sh select-iptables-backend.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/load-probe.sh /usr/local/bin/load-probe-entrypoint.sh /usr/local/bin/select-iptables-backend.sh
ENTRYPOINT ["/usr/local/bin/load-probe-entrypoint.sh"]

# Welcome Message
COPY --from=scripts computenet.txt /etc/computenet.txt
RUN echo 'cat /etc/computenet.txt' >> /root/.bashrc
RUN echo 'echo -e "\nmade with ❤️  by Datura\n\n"' >> /root/.bashrc

# Default CMD when nobody overrides it. load-probe runs via the ENTRYPOINT chain above,
# not here, so this is just the regular pod-bring-up path for interactive use.
# (The lium validator overrides CMD with its own `sh -c '... service ssh start ...'`,
# but the ENTRYPOINT chain still runs load-probe before that override — that is the
# whole point of moving load-probe out of CMD.)
CMD ["bash", "-c", "/nvidia-setup.sh && /start.sh"]