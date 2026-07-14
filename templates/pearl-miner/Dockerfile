# Lium PEARL (PRL) pool miner — pool-independent wrapper around the pearlhash pearl-miner binary.
# The binary is glibc-only (no CUDA toolkit needed at build time); libcuda is injected by the
# NVIDIA container runtime at run time.
FROM ubuntu:22.04

ARG PEARL_MINER_URL=https://pearlhash.xyz/downloads/pearl-miner-v12
ARG PEARL_MINER_SHA256=f6fe45f8fe9081987505af31f0249021a65b558af514f2e4e37340fb3182805f

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl tini \
    && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL "${PEARL_MINER_URL}" -o /usr/local/bin/pearl-miner \
    && echo "${PEARL_MINER_SHA256}  /usr/local/bin/pearl-miner" | sha256sum -c - \
    && chmod +x /usr/local/bin/pearl-miner

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

ENV NVIDIA_VISIBLE_DEVICES=all \
    NVIDIA_DRIVER_CAPABILITIES=compute,utility \
    PEARL_POOL_HOST=pool.pearlhash.xyz \
    PEARL_POOL_PORT=9000

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
