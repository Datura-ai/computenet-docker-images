# lium-rdma-probe

Measures whether two hosts on one RoCE segment really carry RDMA between them (DAH-2667).

A RoCE fabric has no subnet manager, so Lium can only infer it: one provider, one IPv4 segment,
one address per host. A segment is not proof — a switch without lossless queueing (PFC/ECN) drops
RDMA, and NCCL then falls back to TCP while every device check still passes. This image answers the
question with a transfer.

The validator runs it on both hosts of a candidate pair while both are free:

```bash
# on the host that listens
docker run --rm --network host --device /dev/infiniband daturaai/lium-rdma-probe:0.0.1 \
    server 18515 1000
# on the other host
docker run --rm --network host --device /dev/infiniband daturaai/lium-rdma-probe:0.0.1 \
    client 18515 1000 172.16.5.6
```

The third argument is a write count, not a duration — the probe proves the wire carries RDMA at
all, in well under a second, because a validator cycle has seconds for it. The client prints
`ib_write_bw`'s table; a table at all is the answer, the rate is a side effect.

The rail and GID come from `lium-fabric-env`, the cluster image's own script, taken from
`../lium-cluster` at build time. So the probe measures the exact wire a rental would use, and the
two can never drift apart.

Build:

```bash
docker buildx bake --builder luim-multi --push
```
