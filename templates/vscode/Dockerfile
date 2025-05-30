ARG BASE_IMAGE=nvidia/cuda:12.8.1-cudnn-runtime-ubuntu24.04
FROM ${BASE_IMAGE}

RUN apt-get update \
    && apt-get install -y \
    curl \
    dumb-init \
    zsh \
    htop \
    locales \
    man \
    nano \
    git \
    git-lfs \
    procps \
    openssh-client \
    sudo \
    vim.tiny \
    lsb-release \
    && git lfs install \
    && apt-get clean \
    && apt-get autoremove -y \
    && rm -rf /var/lib/apt/lists/*

# https://wiki.debian.org/Locale#Manually
RUN sed -i "s/# en_US.UTF-8/en_US.UTF-8/" /etc/locale.gen \
    && locale-gen
ENV LANG=en_US.UTF-8

RUN adduser --gecos '' --disabled-password coder \
    && echo "coder ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers.d/nopasswd

RUN curl -fsSL https://code-server.dev/install.sh | sh


EXPOSE 8080

# USER 1000
ENV USER=coder
WORKDIR /home/coder

# NGINX Proxy
ENV REQUIRE_NGINIX=true
COPY --from=proxy nginx.conf /etc/nginx/nginx.conf
COPY --from=proxy readme.html /usr/share/nginx/html/readme.html

# Copy the README.md
COPY README.md /usr/share/nginx/html/README.md

# Start Scripts
COPY post_start.sh /post_start.sh
COPY --from=scripts start.sh /
RUN chmod +x /start.sh

CMD [ "/start.sh" ]
