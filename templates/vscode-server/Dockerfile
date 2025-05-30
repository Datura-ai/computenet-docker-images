# Base image
ARG BASE_IMAGE=nvidia/cuda:12.8.1-cudnn-runtime-ubuntu24.04
FROM ${BASE_IMAGE}

# Set working directory
WORKDIR /

ENV DEBIAN_FRONTEND=noninteractive

# VS Code Server Environment Variables
ENV VSCODE_SERVE_MODE=remote


# Install System Packages
RUN apt-get update -y && \
    apt-get upgrade -y && \
    apt-get install -y --no-install-recommends software-properties-common && \
    add-apt-repository ppa:deadsnakes/ppa && \
    apt-get update -y && \
    apt-get install -y --no-install-recommends \
    git             \
    nano            \
    nginx           \
    tzdata          \
    expect          \
    ca-certificates \
    openssh-server  \
    build-essential \
    python3.10-dev python3.10-venv \
    gnome-keyring wget curl ca-certificates \
    && apt-get autoremove -y && apt-get clean -y && rm -rf /var/lib/apt/lists/*


# Set up Python and pip
RUN ln -s /usr/bin/python3.10 /usr/bin/python && \
    rm /usr/bin/python3 && \
    ln -s /usr/bin/python3.10 /usr/bin/python3 && \
    curl https://bootstrap.pypa.io/get-pip.py -o get-pip.py && \
    python get-pip.py

RUN pip install --upgrade pip && pip install jupyterlab

# Install vscode-server
COPY src/vscode-server-setup.sh /tmp/vscode-server-setup.sh
RUN chmod +x /tmp/vscode-server-setup.sh && \
    /tmp/vscode-server-setup.sh && \
    rm /tmp/vscode-server-setup.sh

# RUN wget -q -O- https://aka.ms/install-vscode-server/setup.sh | sh && \
#     rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# copy scripts
COPY src/* /usr/local/bin/

# expose port
EXPOSE 8000

# NGINX Proxy
ENV REQUIRE_NGINIX=true
RUN wget -O init-deb.sh https://www.linode.com/docs/assets/660-init-deb.sh && \
    mv init-deb.sh /etc/init.d/nginx && \
    chmod +x /etc/init.d/nginx && \
    /usr/sbin/update-rc.d -f nginx defaults

COPY --from=proxy nginx.conf /etc/nginx/nginx.conf
COPY --from=proxy readme.html /usr/share/nginx/html/readme.html

# Copy the README.md
COPY README.md /usr/share/nginx/html/README.md

# Start Scripts
COPY post_start.sh /post_start.sh
COPY --from=scripts start.sh /
RUN chmod +x /start.sh

CMD [ "/start.sh" ]
