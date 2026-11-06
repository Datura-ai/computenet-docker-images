#!/usr/bin/env bash
# One side of a two-host AWS EFA measurement (DAH-5932).
#
#   lium-efa-probe address
#   lium-efa-probe server <tcp_port> <iterations>
#   lium-efa-probe client <tcp_port> <iterations> <server_address>
#
# EFA has no IP of its own, so the handshake runs over the host's own IPv4 (`address` prints the
# one its default route leaves from). AWS requires an EFA security group to allow all traffic
# between its members, so that address reaches the peer whenever the EFA path itself can.
set -euo pipefail

role="${1:?usage: lium-efa-probe address|server|client <tcp_port> <iterations> [server_address]}"

if [[ "$role" == "address" ]]; then
    # A UDP connect sends nothing; it only asks the kernel which source address it would use.
    exec python3 -c 'import socket; s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.connect(("8.8.8.8", 53)); print(s.getsockname()[0])'
fi

tcp_port="${2:?the handshake port both sides open}"
iterations="${3:?how many messages to send}"
server_address="${4:-}"

# The same provider and endpoint type NCCL takes over EFA: libfabric efa, reliable datagrams.
arguments=(-p efa -e rdm -S 65536 -I "$iterations")
if [[ "$role" == "server" ]]; then
    exec fi_pingpong "${arguments[@]}" -B "$tcp_port"
fi
exec fi_pingpong "${arguments[@]}" -P "$tcp_port" "${server_address:?a client needs the address of the server}"
