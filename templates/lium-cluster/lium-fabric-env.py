#!/usr/bin/env python3
"""DAH-2667: tell NCCL which card and which GID carry this pod's fabric, when it is RoCE.

On InfiniBand nothing has to be said. There is one fabric, addressing is by LID, and NCCL finds it
by itself — which is what runs in prod today, so this stays silent on such a host.

RoCE gives NCCL two choices it cannot make on its own:

- WHICH DEVICE. A RoCE host answers verbs on every Ethernet card that has them, including the one
  carrying the internet and storage. NCCL would happily pick that one and run the job over it.
- WHICH GID. Every RoCE port publishes several GIDs — a v1 entry, a v2 entry, link-local ones — and
  only the IPv4-mapped v2 entry is routable between two hosts. NCCL's own default moves with the
  driver, and the index differs per card (mlx5 puts it at 2-3, Intel irdma at 1), so it is read at
  runtime rather than assumed.

Read through `ibv_devinfo`, NOT `/sys/class/infiniband`, because this runs INSIDE the pod: sysfs is
mounted there but its attribute files read back EMPTY (measured on staging 2026-08-13 — the tree
lists `rxe0/ports/1/gids/*` while every `cat` returns nothing). libibverbs opens the forwarded
`/dev/infiniband/uverbs*` character devices instead, which is exactly what the workload's NCCL does,
so what this sees is what NCCL will see.

Both facts are read from this host alone, and that is enough because the backend never sells a host
whose live RoCE ports sit on two different segments (`find_joinable_roce_groups`): anything active
here belongs to the fabric the cluster was rented on.
"""

import re
import subprocess

# The GID that can cross a router. RoCE v1 is L2-only, and NCCL addresses its peers by IP here.
ROUTABLE_GID_TYPE = "roce v2"

IBV_DEVINFO = ["ibv_devinfo", "-v"]

_HCA = re.compile(r"^hca_id:\s*(\S+)")
_PORT = re.compile(r"^\s*port:\s*(\d+)")
_STATE = re.compile(r"^\s*state:\s*(\S+)")
_LINK_LAYER = re.compile(r"^\s*link_layer:\s*(\S+)")
# "GID[  1]:		::ffff:10.0.0.40, RoCE v2"
_GID = re.compile(r"^\s*GID\[\s*(\d+)\]:\s*([^,\s]+)(?:,\s*(.*))?$")


class FabricPort:
    """One RDMA port as libibverbs reports it."""

    def __init__(self, device: str, port: str) -> None:
        self.device: str = device
        self.port: str = port
        self.state: str = ""
        self.link_layer: str = ""
        # index -> (address, gid type)
        self.gids: dict[int, tuple[str, str]] = {}

    @property
    def is_active(self) -> bool:
        # ibv_devinfo prints PORT_ACTIVE (4); PORT_ACTIVE_DEFER is a degraded link, not a fabric.
        return self.state.upper() == "PORT_ACTIVE"

    @property
    def is_roce(self) -> bool:
        return self.link_layer.lower() == "ethernet"

    @property
    def is_infiniband(self) -> bool:
        return self.link_layer.lower() == "infiniband"

    def routable_gid_index(self) -> int | None:
        """The index of the IPv4-mapped RoCE v2 entry, the only one a peer on another host can dial.

        An address the card gave itself names nothing: 169.254/16 is what a NIC with no DHCP lease
        holds, and without this every unconfigured card would be offered to NCCL as a fabric.
        """
        for index in sorted(self.gids):
            address, gid_type = self.gids[index]
            if gid_type.lower() != ROUTABLE_GID_TYPE:
                continue
            if not address.lower().startswith("::ffff:"):
                continue
            ipv4 = address.split(":")[-1]
            if ipv4.startswith(("169.254.", "127.", "0.0.0.0")):
                continue
            return index
        return None


def read_ports() -> list[FabricPort]:
    """Every RDMA port this pod can actually open, as libibverbs reports it."""
    try:
        output = subprocess.run(IBV_DEVINFO, capture_output=True, text=True, timeout=30).stdout
    except (OSError, subprocess.SubprocessError):
        return []

    ports: list[FabricPort] = []
    device: str = ""
    current: FabricPort | None = None
    for line in output.splitlines():
        hca = _HCA.match(line)
        if hca:
            device = hca.group(1)
            continue
        port = _PORT.match(line)
        if port:
            current = FabricPort(device, port.group(1))
            ports.append(current)
            continue
        if current is None:
            continue
        state = _STATE.match(line)
        if state:
            current.state = state.group(1)
            continue
        link_layer = _LINK_LAYER.match(line)
        if link_layer:
            current.link_layer = link_layer.group(1)
            continue
        gid = _GID.match(line)
        if gid:
            current.gids[int(gid.group(1))] = (gid.group(2), (gid.group(3) or "").strip())
    return ports


def fabric_environment() -> dict[str, str]:
    """What NCCL needs beyond the overlay, or nothing at all on an InfiniBand host."""
    live_ports = [port for port in read_ports() if port.is_active]
    # A host holding a live InfiniBand port was sold on that fabric — pinning its Ethernet leg
    # would point the job at the wrong wire.
    if any(port.is_infiniband for port in live_ports):
        return {}

    rails: list[str] = []
    gid_indexes: set[int] = set()
    for port in live_ports:
        if not port.is_roce:
            continue
        gid_index = port.routable_gid_index()
        if gid_index is None:
            continue
        rails.append(f"{port.device}:{port.port}")
        gid_indexes.add(gid_index)

    if not rails:
        return {}

    environment: dict[str, str] = {"NCCL_IB_HCA": ",".join(sorted(rails))}
    # NCCL_IB_GID_INDEX is one value for the whole job, so rails that disagree get none: a wrong
    # index breaks every rail, while NCCL's own v2 detection is at least right on most of them.
    if len(gid_indexes) == 1:
        environment["NCCL_IB_GID_INDEX"] = str(gid_indexes.pop())
    return environment


def render(environment: dict[str, str]) -> str:
    return "\n".join(f"{name}={value}" for name, value in environment.items())


if __name__ == "__main__":
    print(render(fabric_environment()))
