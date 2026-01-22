FROM python:3.11-slim

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y \
    curl \
    lsb-release \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY lib/libdmcompverify.so /usr/lib/libdmcompverify.so
COPY lib/libverifyx.so /usr/lib/libverifyx.so
COPY app/preflight /app/preflight
COPY app/services /app/services

RUN pip3 install --no-cache-dir nvidia-ml-py

ENV PYTHONPATH=/app

ENTRYPOINT ["python3", "/app/preflight/main.py"]
