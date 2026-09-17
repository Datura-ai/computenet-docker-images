# daturaai/dind

Docker-in-Docker image the lium validators start on every executor for the sysbox probe
(`DockerCommand.run_dind` in lium-io `neurons/validators/src/core/docker_utils.py`): the container
brings up an inner dockerd, then the validator's own `service ssh start` command, and the validator
runs `docker run --rm hello-world` inside it over SSH. `hello-world` is bundled (DAH-1959), so the
probe never pulls from Docker Hub.

## Running it by hand

```bash
docker run -d --gpus all --runtime=sysbox-runc --rm --name=dind-test \
  -p 2023:22 daturaai/dind:0.0.2 \
  sh -c 'mkdir -p ~/.ssh && echo "<your ssh public key>" >> ~/.ssh/authorized_keys && ssh-keygen -A && service ssh start && tail -f /dev/null'
ssh -p 2023 root@<host> docker run --rm hello-world
```

## iptables backend (0.0.2, DAH-2856)

The inner dockerd needs iptables. The image selects `iptables-nft` (Dockerfile `update-alternatives`);
`select-iptables-backend.sh` runs first in the entrypoint and switches back to `iptables-legacy` only when
nft cannot open the `nat` table but legacy can. `smoke.sh` (run by `scripts/build-smoke.sh` in CI) asserts the nft alternative. Before 0.0.2 the image used legacy iptables, which needs
the `ip_tables`/`iptable_nat` kernel modules loaded on the host; on a host whose own iptables runs in
nf_tables mode with nothing loading those modules (the Debian 12+ default) the inner dockerd died with
`can't initialize iptables table 'nat'`, sshd never started and the validator scored the node as having
no sysbox. Check inside a running container: `readlink -f /etc/alternatives/iptables` prints
`/usr/sbin/xtables-nft-multi`.

## Build

The base is pinned to `cruizba/ubuntu-dind:noble-28.0.4` (Ubuntu 24.04, Docker 28.0.4, the 0.0.1 base); bump it in its own change.

```bash
cd templates/docker-dind
BUILDX_BAKE_ENTITLEMENTS_FS=0 docker buildx bake --load      # daturaai/dind:0.0.2 (VERSION in docker-bake.hcl)
```
