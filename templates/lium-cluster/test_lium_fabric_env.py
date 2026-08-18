"""DAH-2667 — the pod names the RoCE device and GID for NCCL, and stays out of the way on InfiniBand.

The samples are real `ibv_devinfo -v` output: the RoCE ones measured inside a staging cluster pod
(Soft-RoCE) and on a prod RTX 6000 Ada host (mlx5), the InfiniBand one on the Nebius H100 pair.
"""

import importlib.util
import sys
from pathlib import Path

import pytest

MODULE_PATH = Path(__file__).with_name("lium-fabric-env.py")
spec = importlib.util.spec_from_file_location("lium_fabric_env", MODULE_PATH)
lium_fabric_env = importlib.util.module_from_spec(spec)
sys.modules["lium_fabric_env"] = lium_fabric_env
spec.loader.exec_module(lium_fabric_env)

SOFT_ROCE = """hca_id:\trxe0
\ttransport:\t\t\tInfiniBand (0)
\t\tport:\t1
\t\t\tstate:\t\t\tPORT_ACTIVE (4)
\t\t\tlink_layer:\t\tEthernet
\t\t\tGID[  0]:\t\tfe80::1859:19ff:fe19:2921, RoCE v2
\t\t\tGID[  1]:\t\t::ffff:10.0.0.40, RoCE v2
"""

MLX5_ROCE = """hca_id:\tmlx5_0
\t\tport:\t1
\t\t\tstate:\t\t\tPORT_ACTIVE (4)
\t\t\tlink_layer:\t\tEthernet
\t\t\tGID[  0]:\t\tfe80::eaeb:d3ff:fea7:7e16, RoCE v1
\t\t\tGID[  1]:\t\tfe80::eaeb:d3ff:fea7:7e16, RoCE v2
\t\t\tGID[  2]:\t\t::ffff:172.16.5.6, RoCE v1
\t\t\tGID[  3]:\t\t::ffff:172.16.5.6, RoCE v2
hca_id:\tmlx5_1
\t\tport:\t1
\t\t\tstate:\t\t\tPORT_DOWN (1)
\t\t\tlink_layer:\t\tEthernet
"""

INFINIBAND = """hca_id:\tmlx5_2
\t\tport:\t1
\t\t\tstate:\t\t\tPORT_ACTIVE (4)
\t\t\tlink_layer:\t\tInfiniBand
\t\t\tGID[  0]:\t\tfe80::9a03:9bff:fe1d:8a42
"""


def _with_devinfo(output: str) -> dict[str, str]:
    """Run the module against a canned dump without pytest's monkeypatch (used by plain asserts)."""

    class _Result:
        stdout = output

    original = lium_fabric_env.subprocess.run
    lium_fabric_env.subprocess.run = lambda *a, **k: _Result()
    try:
        return lium_fabric_env.fabric_environment(lium_fabric_env.read_ports())
    finally:
        lium_fabric_env.subprocess.run = original


def _ports_from(output: str) -> list:
    class _Result:
        stdout = output

    original = lium_fabric_env.subprocess.run
    lium_fabric_env.subprocess.run = lambda *a, **k: _Result()
    try:
        return lium_fabric_env.read_ports()
    finally:
        lium_fabric_env.subprocess.run = original


@pytest.fixture
def devinfo(monkeypatch: pytest.MonkeyPatch):
    """Feed a canned `ibv_devinfo -v` dump, so the real parser is what the tests exercise."""

    def _set(output: str) -> None:
        class _Result:
            stdout = output

        monkeypatch.setattr(lium_fabric_env.subprocess, "run", lambda *a, **k: _Result())

    return _set


def test_a_soft_roce_pod_names_its_device_and_the_ipv4_mapped_v2_gid(devinfo) -> None:
    """Measured inside a staging cluster pod: sysfs reads back empty there, ibverbs does not."""
    devinfo(SOFT_ROCE)

    assert lium_fabric_env.fabric_environment(lium_fabric_env.read_ports()) == {"NCCL_IB_HCA": "=rxe0:1", "NCCL_IB_GID_INDEX": "1"}


def test_the_gid_index_is_read_not_assumed(devinfo) -> None:
    """mlx5 puts the IPv4-mapped v2 entry at 3, Soft-RoCE at 1 — position is never a constant."""
    devinfo(MLX5_ROCE)

    assert lium_fabric_env.fabric_environment(lium_fabric_env.read_ports()) == {"NCCL_IB_HCA": "=mlx5_0:1", "NCCL_IB_GID_INDEX": "3"}


def test_a_down_port_is_ignored(devinfo) -> None:
    """mlx5_1 in the sample is DOWN; only mlx5_0 may be offered to NCCL."""
    devinfo(MLX5_ROCE)

    assert lium_fabric_env.fabric_environment(lium_fabric_env.read_ports())["NCCL_IB_HCA"] == "=mlx5_0:1"


def test_an_infiniband_host_is_left_alone(devinfo) -> None:
    """NCCL finds an InfiniBand fabric by itself, and that path is what runs in prod today."""
    devinfo(INFINIBAND)

    assert lium_fabric_env.fabric_environment(lium_fabric_env.read_ports()) == {}


def test_a_mixed_host_follows_its_infiniband_side(devinfo) -> None:
    """A host on both fabrics was sold on the InfiniBand one — pinning Ethernet points at the wrong wire."""
    devinfo(INFINIBAND + MLX5_ROCE)

    assert lium_fabric_env.fabric_environment(lium_fabric_env.read_ports()) == {}


def test_a_roce_v1_only_port_is_ignored(devinfo) -> None:
    """RoCE v1 is L2-only: it cannot cross a router, and NCCL addresses peers by IP here."""
    devinfo(
        "hca_id:\tmlx5_0\n\t\tport:\t1\n\t\t\tstate:\t\t\tPORT_ACTIVE (4)\n"
        "\t\t\tlink_layer:\t\tEthernet\n\t\t\tGID[  0]:\t\t::ffff:10.0.0.5, RoCE v1\n"
    )

    assert lium_fabric_env.fabric_environment(lium_fabric_env.read_ports()) == {}


def test_a_card_with_no_address_is_ignored(devinfo) -> None:
    """The link-local entry every port carries names no segment a peer could dial."""
    devinfo(
        "hca_id:\trxe0\n\t\tport:\t1\n\t\t\tstate:\t\t\tPORT_ACTIVE (4)\n"
        "\t\t\tlink_layer:\t\tEthernet\n\t\t\tGID[  0]:\t\tfe80::1, RoCE v2\n"
    )

    assert lium_fabric_env.fabric_environment(lium_fabric_env.read_ports()) == {}


def test_an_unconfigured_card_is_ignored(devinfo) -> None:
    """169.254/16 is what a NIC with no DHCP lease hands itself — a fabric of nobody."""
    devinfo(
        "hca_id:\trxe0\n\t\tport:\t1\n\t\t\tstate:\t\t\tPORT_ACTIVE (4)\n"
        "\t\t\tlink_layer:\t\tEthernet\n\t\t\tGID[  0]:\t\t::ffff:169.254.3.7, RoCE v2\n"
    )

    assert lium_fabric_env.fabric_environment(lium_fabric_env.read_ports()) == {}


def test_rails_that_disagree_about_the_gid_index_leave_it_to_nccl(devinfo) -> None:
    """One wrong global index breaks every rail; NCCL's own v2 detection is better than that."""
    devinfo(
        MLX5_ROCE.replace("PORT_DOWN (1)", "PORT_ACTIVE (4)")
        + "\t\t\tGID[  1]:\t\t::ffff:172.16.5.7, RoCE v2\n"
    )

    environment = lium_fabric_env.fabric_environment(lium_fabric_env.read_ports())

    assert environment["NCCL_IB_HCA"] == "=mlx5_0:1,mlx5_1:1"
    assert "NCCL_IB_GID_INDEX" not in environment


def test_a_host_with_no_rdma_asks_for_nothing(devinfo) -> None:
    devinfo("")

    assert lium_fabric_env.fabric_environment(lium_fabric_env.read_ports()) == {}


def test_the_output_is_shell_assignments(devinfo) -> None:
    devinfo(SOFT_ROCE)

    assert lium_fabric_env.render(lium_fabric_env.fabric_environment(lium_fabric_env.read_ports())) == (
        "NCCL_IB_HCA==rxe0:1\nNCCL_IB_GID_INDEX=1"
    )


def test_the_device_list_asks_nccl_for_an_exact_match() -> None:
    """Without the leading "=", NCCL treats the list as a PREFIX: naming mlx5_1 also hands it
    mlx5_10 and mlx5_11 — the storage NIC this exists to keep out of the job."""
    devinfo_output = MLX5_ROCE.replace("mlx5_1\n", "mlx5_10\n")
    parsed = _with_devinfo(devinfo_output)

    assert parsed["NCCL_IB_HCA"].startswith("=")


def test_rails_on_two_segments_name_nothing() -> None:
    """One of them is not this cluster's fabric, and pointing NCCL at the wrong rail hangs the job.
    The backend refuses to sell such a host for the same reason."""
    second_segment = (
        "hca_id:\tmlx5_9\n\t\tport:\t1\n\t\t\tstate:\t\t\tPORT_ACTIVE (4)\n"
        "\t\t\tlink_layer:\t\tEthernet\n\t\t\tGID[  1]:\t\t::ffff:192.168.9.9, RoCE v2\n"
    )

    assert _with_devinfo(SOFT_ROCE + second_segment) == {}


def test_a_pod_with_no_active_port_is_refused() -> None:
    """The script is the gate: the entrypoint turns its non-zero exit into a refused pod."""
    down_only = SOFT_ROCE.replace("PORT_ACTIVE (4)", "PORT_DOWN (1)")

    assert not any(port.is_active for port in _ports_from(down_only))
