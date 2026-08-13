#!/usr/bin/env python3
"""DAH-2667: tell NCCL which card and which GID carry this pod's fabric, when it is RoCE.

On InfiniBand nothing has to be said. There is one fabric, addressing is by LID, and NCCL finds it
by itself — which is what runs in prod today, so this stays silent on such a host.

RoCE gives NCCL two choices it cannot make on its own:

- WHICH DEVICE. A RoCE host answers verbs on every Ethernet card that has them, including the one
  carrying the internet and storage. NCCL would happily pick that one and run the job over it.
- WHICH GID. Every RoCE port publishes several GIDs — a v1 entry, a v2 entry, link-local ones — and
  only the IPv4-mapped v2 entry is routable between two hosts. NCCL's own default moves with the
  driver, and the index differs per card (mlx5 puts it at 2-3, Intel irdma at 1), so it is read from
  sysfs rather than assumed.

Both are read from this host alone, and that is enough because the backend never sells a host whose
live RoCE ports sit on two different segments (`find_joinable_roce_groups`): anything active here
belongs to the fabric the cluster was rented on.
"""

import os

SYSFS_ROOT = "/sys/class/infiniband"

# The GID that can cross a router. RoCE v1 is L2-only, and NCCL addresses its peers by IP here.
ROUTABLE_GID_TYPE = "roce v2"

# An IPv4 address carried in an IPv6 GID: ::ffff:a.b.c.d, printed by sysfs in full.
IPV4_MAPPED_GID_PREFIX = "0000:0000:0000:0000:0000:ffff:"


def _read(path: str) -> str:
    try:
        with open(path) as handle:
            return handle.read().strip()
    except OSError:
        return ""


def _ports_of(device: str) -> list[str]:
    try:
        return sorted(os.listdir(os.path.join(SYSFS_ROOT, device, "ports")))
    except OSError:
        return []


def _is_active(port_path: str) -> bool:
    # sysfs reports "<code>: <NAME>". Matched exactly, so the degraded ACTIVE_DEFER does not pass.
    return _read(os.path.join(port_path, "state")).split(":")[-1].strip().upper() == "ACTIVE"


def _routable_gid_index(port_path: str) -> int | None:
    """The index of the port's IPv4-mapped RoCE v2 entry, the only one a peer can dial."""
    gids_path = os.path.join(port_path, "gids")
    try:
        indexes = sorted(int(name) for name in os.listdir(gids_path) if name.isdigit())
    except OSError:
        return None

    for index in indexes:
        gid = _read(os.path.join(gids_path, str(index))).lower()
        if not gid.startswith(IPV4_MAPPED_GID_PREFIX):
            continue
        gid_type = _read(os.path.join(port_path, "gid_attrs", "types", str(index))).lower()
        if gid_type != ROUTABLE_GID_TYPE:
            continue
        return index
    return None


def fabric_environment() -> dict[str, str]:
    """What NCCL needs beyond the overlay, or nothing at all on an InfiniBand host."""
    try:
        devices = sorted(os.listdir(SYSFS_ROOT))
    except OSError:
        return {}

    roce_rails: list[str] = []
    gid_indexes: set[int] = set()
    for device in devices:
        for port in _ports_of(device):
            port_path = os.path.join(SYSFS_ROOT, device, "ports", port)
            if not _is_active(port_path):
                continue
            link_layer = _read(os.path.join(port_path, "link_layer")).lower()
            # A host holding a live InfiniBand port was sold on that fabric — pinning its Ethernet
            # leg would point the job at the wrong wire.
            if link_layer == "infiniband":
                return {}
            if link_layer != "ethernet":
                continue
            gid_index = _routable_gid_index(port_path)
            if gid_index is None:
                continue
            roce_rails.append(f"{device}:{port}")
            gid_indexes.add(gid_index)

    if not roce_rails:
        return {}

    environment: dict[str, str] = {"NCCL_IB_HCA": ",".join(roce_rails)}
    # NCCL_IB_GID_INDEX is one value for the whole job, so rails that disagree get none: a wrong
    # index breaks every rail, while NCCL's own v2 detection is at least right on most of them.
    if len(gid_indexes) == 1:
        environment["NCCL_IB_GID_INDEX"] = str(gid_indexes.pop())
    return environment


def render(environment: dict[str, str]) -> str:
    return "\n".join(f"{name}={value}" for name, value in environment.items())


if __name__ == "__main__":
    print(render(fabric_environment()))
