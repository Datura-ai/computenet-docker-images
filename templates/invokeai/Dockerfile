FROM daturaai/pytorch:1.13.1-py3.10-cuda11.7.1-devel-ubuntu22.04

RUN apt update && \
    apt-get install -y nano rsync build-essential  python3-opencv libopencv-dev nginx lsof && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

ENV INVOKEAI_ROOT=/workspace/invokeai

RUN python -m venv /workspace/invokeai/venv
ENV PATH="/workspace/invokeai/venv/bin:$PATH"

WORKDIR /workspace/invokeai

RUN python -m pip install --upgrade pip && \
    pip install "InvokeAI[xformers]" --use-pep517 --extra-index-url https://download.pytorch.org/whl/cu117 && \
    pip install pypatchmatch

RUN mv /workspace/invokeai /invokeai

# NGINX Proxy
ENV REQUIRE_NGINIX=true
COPY --from=proxy nginx.conf /etc/nginx/nginx.conf
COPY --from=proxy readme.html /usr/share/nginx/html/readme.html

# Copy the README.md
COPY README.md /usr/share/nginx/html/README.md

# Start Scripts
COPY pre_start.sh /pre_start.sh
COPY --from=scripts start.sh /
RUN chmod +x /start.sh && chmod +x /pre_start.sh

CMD [ "/start.sh" ]
