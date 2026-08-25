# DAH-2667: the image the validator uses to MEASURE a RoCE fabric before we sell it as a cluster.
#
# A RoCE fabric is otherwise only inferred — one provider, one IPv4 segment — and a segment says
# nothing about whether the switch between the hosts carries RDMA. This image answers that with a
# real transfer: `ib_write_bw` between two hosts, over the same card and GID the cluster image would
# hand NCCL, so the measurement is a rehearsal of the rental rather than a separate opinion.
#
# Small on purpose: it lands on provider hosts that never asked for it, so it carries the RDMA
# userspace, perftest and nothing else.
FROM ubuntu:24.04

RUN apt-get update && apt-get install -y --no-install-recommends \
        python3-minimal \
        libibverbs1 \
        librdmacm1 \
        ibverbs-providers \
        ibverbs-utils \
        perftest \
    && rm -rf /var/lib/apt/lists/*

# The build context is the templates directory, so this image takes the cluster image's OWN copy
# of the fabric reader instead of a second one that could drift from it.
COPY lium-cluster/lium-fabric-env.py /usr/local/bin/lium-fabric-env
COPY lium-rdma-probe/lium-roce-probe.sh /usr/local/bin/lium-roce-probe
RUN chmod +x /usr/local/bin/lium-fabric-env /usr/local/bin/lium-roce-probe

ENTRYPOINT ["/usr/local/bin/lium-roce-probe"]
