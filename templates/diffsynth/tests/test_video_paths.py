"""DAH-2909: user-typed video file names stay inside VIDEO_DIR. Stdlib only, no pytest dependency:

    python3 templates/diffsynth/tests/test_video_paths.py
"""

import os
import pathlib
import sys
import tempfile

TEMPLATE_DIR = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(TEMPLATE_DIR / "apps" / "streamlit"))

failures: list[str] = []


def check(label: str, ok: bool) -> None:
    print(("ok   " if ok else "FAIL ") + label)
    if not ok:
        failures.append(label)


def expect_error(label: str, fn, *args, **kwargs) -> None:
    try:
        fn(*args, **kwargs)
    except ValueError:
        check(label, True)
    else:
        check(label + " (no ValueError raised)", False)


with tempfile.TemporaryDirectory() as tmp:
    root = os.path.join(tmp, "videos")
    os.environ["DIFFSYNTH_VIDEO_DIR"] = root
    import video_paths  # noqa: E402  (reads DIFFSYNTH_VIDEO_DIR at import)

    inside = video_paths.resolve_video_path("clip.mp4")
    check("a plain name resolves under VIDEO_DIR", inside == os.path.join(os.path.realpath(root), "clip.mp4"))
    check("VIDEO_DIR is created on first use", os.path.isdir(root))

    expect_error("empty name is refused", video_paths.resolve_video_path, "")
    expect_error("whitespace name is refused", video_paths.resolve_video_path, "   ")
    expect_error("../ traversal is refused", video_paths.resolve_video_path, "../../etc/passwd")
    expect_error("absolute path is refused", video_paths.resolve_video_path, "/etc/passwd")
    expect_error("the directory itself is refused", video_paths.resolve_video_path, ".")
    expect_error("must_exist on a missing file is refused", video_paths.resolve_video_path, "missing.mp4", must_exist=True)

    outside = os.path.join(tmp, "secret.txt")
    open(outside, "w").write("x")
    os.symlink(outside, os.path.join(root, "link.mp4"))
    expect_error("a symlink pointing outside is refused", video_paths.resolve_video_path, "link.mp4")

    open(os.path.join(root, "real.mp4"), "w").write("x")
    check("must_exist on a present file resolves", video_paths.resolve_video_path("real.mp4", must_exist=True).endswith("real.mp4"))

print(f"\n{len(failures)} failure(s)")
sys.exit(1 if failures else 0)
