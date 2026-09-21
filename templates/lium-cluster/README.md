# lium-cluster — multi-node InfiniBand rentals (DAH-2620)

The image every pod of a group rental runs. The backend refuses a cluster rental whose image name
does not start with `daturaai/lium-cluster` (`CLUSTER_TEMPLATE_IMAGE_PREFIX`), because only this
entrypoint reads the injected config and raises the overlay.

## What it solves

NCCL's bootstrap is a TCP ring: every rank binds a socket to the address of the interface
`NCCL_SOCKET_IFNAME` picks, and those addresses are exchanged so each rank can dial its neighbour.
On the docker bridge every pod believes it is `172.17.0.2`, so a rank dials itself and the
InfiniBand transport never starts. The validator injects `LIUM_WIREGUARD_CONF_B64` — this node's
wg-quick config, minted for the whole group by the backend — and the entrypoint raises `wg0` from
it. Each node then has one routable address (`10.42.0.N`), the bootstrap completes over the
overlay, and the tensors travel over InfiniBand.

Without a config injected the block is skipped and the pod behaves like an ordinary one, so the
same image is safe on a single-node rental.

## What the renter has to configure

Nothing.

- `NCCL_SOCKET_IFNAME=wg0` and the gloo equivalent are written to `/etc/environment` (PAM reads it,
  so SSH sessions get them) and to `/etc/profile.d/lium-cluster.sh` for login shells. Exporting them
  from the entrypoint alone reaches the exec'd workload and nothing else — a renter arriving over
  SSH would get a clean environment, NCCL would pick `eth0` and announce a bridge address.
- The inner Docker daemon starts on its own (`ENABLE_DIND=true`, then the base entrypoint).
- Containers the renter starts inside the pod get the fabric without flags: `lium-rdma-runc` is
  registered as the inner daemon's `default-runtime` and injects the verbs devices, `CAP_IPC_LOCK`
  and an unlimited memlock into every OCI spec. Docker can default a ulimit but not a device, hence
  the wrapper. It merges into the base image's `daemon.json` rather than replacing it, so the
  nvidia runtime survives.
- Those same settings reach a **nested** container too (DAH-2664). The entrypoint writes them to
  `/etc/lium-cluster.env` and `lium-rdma-runc` copies them into every OCI spec it sees, because a
  container the inner daemon starts inherits nothing from the pod — `docker run … printenv
  NCCL_SOCKET_IFNAME` used to come back empty and NCCL then picked the inner bridge. A variable the
  renter passes with `-e` is left alone.
- Pod-to-pod SSH works over the overlay (DAH-2664). The backend mints one keypair per cluster; the
  entrypoint installs the private half at `/etc/lium/cluster_ed25519`, the public half at
  `/etc/lium/cluster_authorized_keys` (an `AuthorizedKeysFile` drop-in in `/etc/ssh/sshd_config.d/`
  makes sshd read it next to the renter's own `authorized_keys`; the key carries a `from=` limited
  to the overlay subnet, since sshd also listens on the public port and the key is the whole
  group's — without wg0's address nothing of the login is installed), and a `Host` block for the overlay
  subnet in `/etc/ssh/ssh_config.d/lium-cluster.conf` that names the key and skips the host-key
  prompt. This is what `mpirun`, DeepSpeed's pdsh launcher and the nccl-tests recipes need; without
  it the only working launcher is torchrun with a hand-typed `--node_rank` per node.
  Nothing of it lives under `/root` (DAH-3060): on an encrypted rental the validator mounts the
  gocryptfs plaintext over `/root` after the entrypoint has run, and anything written to
  `/root/.ssh` before that is hidden by the mount. The renter's own `~/.ssh` is never touched. One
  consequence: a restored backup whose `~/.ssh/config` opens with `Host *` and
  `StrictHostKeyChecking yes` keeps that setting for the peers too, since ssh reads the user's file
  before the system one.
- At start the entrypoint dials every peer `wg0` lists (`ssh root@<peer> true`, retried for
  `LIUM_CLUSTER_SSH_CHECK_WAIT_SECONDS`, default 300) in the background and writes the verdict to
  `/var/log/lium-cluster-ssh-check.log` and the container log: `verdict PASS: every peer answers
  ssh`, or `FAIL` with the peers that never did. It never stops the pod; it is where to look first
  when a launcher hangs.
- `libibverbs` and the provider plugins are installed here. They are not in the base, and without
  them NCCL logs `Failed to open libibverbs.so[.1]` and silently falls back to its socket
  transport while every device check still passes.

Only `uverbs*` and `rdma_cm` are ever forwarded, never `issm*` (subnet manager) or `umad*` (raw
MAD) — the same allowlist the validator applies when it forwards devices into the pod.

## RoCE clusters (DAH-2667)

The same image serves a group rented over RoCE. The overlay, the devices and the nested-container
runtime are the same; two things are not.

- **NCCL is told which card and which GID to use.** `lium-fabric-env` reads `ibv_devinfo -v`
  and exports `NCCL_IB_HCA` (the live RoCE rails) and `NCCL_IB_GID_INDEX` (the IPv4-mapped RoCE v2
  entry, whose index moves with the driver — mlx5 puts it at 2-3, Intel irdma at 1). Left to itself
  NCCL can pick the host's storage or internet NIC, or a v1 GID that cannot cross a router. On an
  InfiniBand host it prints nothing and the behaviour is unchanged: there is one fabric and NCCL
  finds it. Reading only this host is enough because the backend never sells a host whose live RoCE
  ports straddle two segments.
- **A pod without a usable fabric refuses to start.** `lium-fabric-env` is also the gate: it exits
  non-zero when no `PORT_ACTIVE` port answers verbs, and the entrypoint turns that into a refused
  pod. Sysfs alone is not evidence, since `/sys/class/infiniband` is mounted into every container
  whether or not the verbs devices were forwarded — and inside a cluster pod its attribute files
  read back empty. Without this check NCCL falls back to TCP over the overlay and the renter pays
  for a cluster that quietly is not one.

## Verified on real hardware

Two Nebius 8xH100 nodes on one fabric, 8x ConnectX at 400 Gb/sec 4X NDR, rented through the staging
API on 2026-08-11:

| check | result |
|---|---|
| `torchrun --nnodes=2 --nproc_per_node=8`, nothing set by hand | `allreduce_ok world=16`, 264 `NET/IB` lines, zero `NET/Socket` |
| `ib_write_bw` pod to pod | 363.68 Gb/sec (host to host baseline: 364.83) |
| `ib_write_bw` from a nested container with no flags | 366.86 Gb/sec |
| inner daemon | 27.3.1, `default-runtime=lium-rdma` |

## Build

```bash
cd templates/lium-cluster
VERSION=0.0.7 docker buildx bake --push
```

`docker-bake.hcl` pins amd64 and the base tag. Bump `VERSION` and the tag in the backend's
`official_templates` (`apps/server/src/core/constants.py`) together — the template row is what
decides which tag a cluster rental actually runs.

## Tests

`test_lium_rdma_runc.py` covers the runtime wrapper: the allowlist, the cgroup rules that must
accompany each device, memory pinning, the overlay settings a nested container inherits, a host with
no fabric, and running twice over one bundle.
`test_lium_fabric_env.py` covers the fabric reader against real `ibv_devinfo -v` dumps: which GID
index is picked per driver, the InfiniBand host it must stay silent on, rails that straddle two
segments, and the exact-match `=` NCCL needs.

`tests/test_entrypoint.sh` runs the entrypoint itself in a throwaway container (wg-quick, ssh and
the base entrypoint stubbed) and checks where the overlay settings and the cluster login end up,
with which permissions, that a standalone pod gets neither, that the login survives a mount over
`/root` (the mount case needs `CAP_SYS_ADMIN` in the test container; it is skipped where Docker
refuses the mount), and what the start-up peer check writes. Needs Docker.

`tests/test_peer_login.sh` is the end-to-end proof of DAH-3060: two containers with a real sshd,
the volume mounted over `/root` after the entrypoint as the validator does it, then
`ssh root@<peer> hostname` from one to the other, and the renter's own key still opening the peer.
With `TEST_OLD_ENTRYPOINT=<file>` it runs that entrypoint too and expects the login to fail.

```bash
pytest test_lium_rdma_runc.py test_lium_fabric_env.py
bash tests/test_entrypoint.sh
bash tests/test_peer_login.sh
```
