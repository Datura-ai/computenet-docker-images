"""DAH-2667 — the pod names the RoCE device and GID for NCCL, and stays out of the way on InfiniBand."""

import importlib.util
import sys
from pathlib import Path

import pytest

MODULE_PATH = Path(__file__).with_name("lium-fabric-env.py")
spec = importlib.util.spec_from_file_location("lium_fabric_env", MODULE_PATH)
lium_fabric_env = importlib.util.module_from_spec(spec)
sys.modules["lium_fabric_env"] = lium_fabric_env
spec.loader.exec_module(lium_fabric_env)

IPV4_MAPPED_GID = "0000:0000:0000:0000:0000:ffff:0a00:0005"
LINK_LOCAL_GID = "fe80:0000:0000:0000:9a03:9bff:fe1d:8a42"


def _write_port(
    sysfs_root: Path,
    device: str,
    port: str,
    link_layer: str,
    state: str = "4: ACTIVE",
    gids: list[str] | None = None,
    gid_types: list[str] | None = None,
) -> None:
    """One port as sysfs lays it out: /sys/class/infiniband/<dev>/ports/<n>/..."""
    port_path = sysfs_root / device / "ports" / port
    (port_path / "gids").mkdir(parents=True)
    (port_path / "gid_attrs" / "types").mkdir(parents=True)
    (port_path / "link_layer").write_text(f"{link_layer}\n")
    (port_path / "state").write_text(f"{state}\n")
    for index, gid in enumerate(gids or []):
        (port_path / "gids" / str(index)).write_text(f"{gid}\n")
    for index, gid_type in enumerate(gid_types or []):
        (port_path / "gid_attrs" / "types" / str(index)).write_text(f"{gid_type}\n")


@pytest.fixture
def sysfs(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Path:
    root = tmp_path / "infiniband"
    root.mkdir()
    monkeypatch.setattr(lium_fabric_env, "SYSFS_ROOT", str(root))
    return root


def test_a_roce_port_names_its_device_and_the_roce_v2_gid_index(sysfs: Path) -> None:
    # mlx5 puts the IPv4-mapped v2 entry at 2-3, Intel irdma at 1 — hence read, never assume.
    _write_port(
        sysfs,
        "mlx5_0",
        "1",
        "Ethernet",
        gids=[LINK_LOCAL_GID, LINK_LOCAL_GID, IPV4_MAPPED_GID],
        gid_types=["IB/RoCE v1", "RoCE v2", "RoCE v2"],
    )

    environment: dict[str, str] = lium_fabric_env.fabric_environment()

    assert environment == {"NCCL_IB_HCA": "mlx5_0:1", "NCCL_IB_GID_INDEX": "2"}


def test_an_infiniband_host_is_left_alone(sysfs: Path) -> None:
    """NCCL finds an InfiniBand fabric by itself, and that path is what runs in prod today."""
    _write_port(sysfs, "mlx5_2", "1", "InfiniBand", gids=[LINK_LOCAL_GID])

    assert lium_fabric_env.fabric_environment() == {}


def test_a_mixed_host_follows_its_infiniband_side(sysfs: Path) -> None:
    """A card on both fabrics is sold on the InfiniBand one, so pinning the Ethernet leg would
    point the job at the wrong wire."""
    _write_port(sysfs, "mlx5_2", "1", "InfiniBand", gids=[LINK_LOCAL_GID])
    _write_port(
        sysfs,
        "mlx5_0",
        "1",
        "Ethernet",
        gids=[LINK_LOCAL_GID, IPV4_MAPPED_GID],
        gid_types=["IB/RoCE v1", "RoCE v2"],
    )

    assert lium_fabric_env.fabric_environment() == {}


def test_every_live_roce_rail_is_offered_to_nccl(sysfs: Path) -> None:
    """The backend never sells a host whose live RoCE ports straddle two segments, so all of them
    belong to the fabric this pod was rented on."""
    for device in ("mlx5_0", "mlx5_1"):
        _write_port(
            sysfs,
            device,
            "1",
            "Ethernet",
            gids=[LINK_LOCAL_GID, IPV4_MAPPED_GID],
            gid_types=["IB/RoCE v1", "RoCE v2"],
        )

    environment: dict[str, str] = lium_fabric_env.fabric_environment()

    assert environment["NCCL_IB_HCA"] == "mlx5_0:1,mlx5_1:1"
    assert environment["NCCL_IB_GID_INDEX"] == "1"


def test_rails_that_disagree_about_the_gid_index_leave_it_to_nccl(sysfs: Path) -> None:
    """NCCL_IB_GID_INDEX is global to the job — one wrong value is worse than none, and NCCL can
    pick a v2 entry on its own."""
    _write_port(
        sysfs,
        "mlx5_0",
        "1",
        "Ethernet",
        gids=[LINK_LOCAL_GID, IPV4_MAPPED_GID],
        gid_types=["IB/RoCE v1", "RoCE v2"],
    )
    _write_port(
        sysfs,
        "irdma0",
        "1",
        "Ethernet",
        gids=[LINK_LOCAL_GID, LINK_LOCAL_GID, IPV4_MAPPED_GID],
        gid_types=["IB/RoCE v1", "IB/RoCE v1", "RoCE v2"],
    )

    environment: dict[str, str] = lium_fabric_env.fabric_environment()

    assert environment == {"NCCL_IB_HCA": "irdma0:1,mlx5_0:1"}


def test_a_down_roce_port_is_ignored(sysfs: Path) -> None:
    _write_port(
        sysfs,
        "mlx5_0",
        "1",
        "Ethernet",
        state="1: DOWN",
        gids=[LINK_LOCAL_GID, IPV4_MAPPED_GID],
        gid_types=["IB/RoCE v1", "RoCE v2"],
    )

    assert lium_fabric_env.fabric_environment() == {}


def test_a_roce_v1_only_port_is_ignored(sysfs: Path) -> None:
    """RoCE v1 is L2-only: it cannot cross a router, and NCCL addresses peers by IP here."""
    _write_port(
        sysfs,
        "mlx5_0",
        "1",
        "Ethernet",
        gids=[LINK_LOCAL_GID, IPV4_MAPPED_GID],
        gid_types=["IB/RoCE v1", "IB/RoCE v1"],
    )

    assert lium_fabric_env.fabric_environment() == {}


def test_a_card_with_no_address_is_ignored(sysfs: Path) -> None:
    """Only the IPv4-mapped entry names a segment; the default fe80:: one every port carries does not."""
    _write_port(sysfs, "mlx5_0", "1", "Ethernet", gids=[LINK_LOCAL_GID], gid_types=["RoCE v2"])

    assert lium_fabric_env.fabric_environment() == {}


def test_a_host_with_no_rdma_at_all_asks_for_nothing(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(lium_fabric_env, "SYSFS_ROOT", str(tmp_path / "absent"))

    assert lium_fabric_env.fabric_environment() == {}


def test_the_output_is_shell_assignments(sysfs: Path) -> None:
    _write_port(
        sysfs,
        "mlx5_0",
        "1",
        "Ethernet",
        gids=[LINK_LOCAL_GID, IPV4_MAPPED_GID],
        gid_types=["IB/RoCE v1", "RoCE v2"],
    )

    assert lium_fabric_env.render(lium_fabric_env.fabric_environment()) == (
        "NCCL_IB_HCA=mlx5_0:1\nNCCL_IB_GID_INDEX=1"
    )
