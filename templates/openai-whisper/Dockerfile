ARG BASE_IMAGE=daturaai/pytorch:2.6.0-py3.12-cuda12.6.0-devel-ubuntu22.04

FROM ${BASE_IMAGE} as base

SHELL ["/bin/bash", "-o", "pipefail", "-c"]
ENV DEBIAN_FRONTEND noninteractive\
    SHELL=/bin/bash
   
RUN apt-get update --yes && \
    apt-get upgrade --yes && \
    apt install --yes --no-install-recommends \
    git \
    nano \
    nginx \
    tzdata \
    expect \
    ca-certificates \
    build-essential \
    wget \
    curl \
    bash \
    ffmpeg \
    openssh-server && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* && \
    echo "en_US.UTF-8 UTF-8" > /etc/locale.gen

RUN pip install jupyterlab
RUN pip install ipywidgets
RUN pip install jupyter-archive
RUN pip install git+https://github.com/openai/whisper.git
RUN pip install yt-dlp
RUN jupyter nbextension enable --py widgetsnbextension

# NGINX Proxy
ENV REQUIRE_NGINIX=true
COPY --from=proxy nginx.conf /etc/nginx/nginx.conf
COPY --from=proxy readme.html /usr/share/nginx/html/readme.html

# Copy the README.md
COPY README.md /usr/share/nginx/html/README.md

# Start Scripts
WORKDIR /
COPY post_start.sh /post_start.sh
COPY --from=scripts start.sh /
RUN chmod +x /start.sh /post_start.sh

CMD ["/bin/bash", "post_start.sh"]