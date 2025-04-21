
# Use the docker:dind image as the base
FROM cruizba/ubuntu-dind:systemd-latest

# Install OpenSSH server using apt
RUN apt-get update && apt-get install -y openssh-server

# Configure SSH
RUN mkdir /var/run/sshd && \
    echo 'root:password' | chpasswd && \
    sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config && \
    sed -i 's/#PasswordAuthentication yes/PasswordAuthentication yes/' /etc/ssh/sshd_config && \
    ssh-keygen -A

# Expose SSH port
EXPOSE 22

# Start SSH and Docker daemon
CMD ["/bin/sh", "-c", "/usr/sbin/sshd && dockerd-entrypoint.sh"]
