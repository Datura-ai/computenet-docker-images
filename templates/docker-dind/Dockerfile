
# Use the docker:dind image as the base
FROM docker:dind

# Install OpenSSH server using apk
RUN apk update && apk add --no-cache openssh

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
