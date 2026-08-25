#!/usr/bin/env bash
# One side of a two-host RoCE measurement (DAH-2667).
#
#   lium-roce-probe server <tcp_port> <iterations>
#   lium-roce-probe client <tcp_port> <iterations> <server_roce_address>
#
# The rail and GID come from `lium-fabric-env`, the same script the cluster pod hands NCCL, so a
# host that measures well here is measured on the wire its rental would actually use.
set -euo pipefail

role="${1:?usage: lium-roce-probe server|client <tcp_port> <iterations> [server_address]}"
tcp_port="${2:?the handshake port both sides open}"
iterations="${3:?how many writes to push}"
server_address="${4:-}"

fabric_environment="$(python3 /usr/local/bin/lium-fabric-env)"
# NCCL_IB_HCA arrives as "=mlx5_0:1,mlx5_1:1" — the leading "=" is NCCL's exact-match marker.
rails="$(printf '%s\n' "$fabric_environment" | sed -n 's/^NCCL_IB_HCA==\{0,1\}//p')"
gid_index="$(printf '%s\n' "$fabric_environment" | sed -n 's/^NCCL_IB_GID_INDEX=//p')"
if [[ -z "$rails" || -z "$gid_index" ]]; then
    echo "lium-roce-probe: this host names no single RoCE rail, nothing to measure" >&2
    exit 1
fi

# Every rail here sits on one segment (lium-fabric-env drops the host otherwise), so the first one
# measures the fabric. Measuring them all would say more about the host than about the wire.
rail="${rails%%,*}"
device="${rail%%:*}"
device_port="${rail##*:}"

# A fixed write count, not a duration: the probe proves the wire carries RDMA at all, and a
# validator cycle has seconds for it, not minutes. The reported rate is a side effect.
arguments=(-d "$device" -i "$device_port" -x "$gid_index" -p "$tcp_port" -n "$iterations" --report_gbits)
if [[ "$role" == "server" ]]; then
    exec ib_write_bw "${arguments[@]}"
fi
exec ib_write_bw "${arguments[@]}" "${server_address:?the client needs the server's RoCE address}"
