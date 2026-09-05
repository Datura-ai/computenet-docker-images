"""Confine user-supplied video file names to one directory.

The Streamlit pages take file names as free text. Anything typed there is
resolved inside ``VIDEO_DIR`` (``DIFFSYNTH_VIDEO_DIR``, default ``./videos``
under the working directory) so a value such as ``../../etc/passwd`` or an
absolute path can neither read nor overwrite files elsewhere in the container.
"""

import os

VIDEO_DIR = os.environ.get("DIFFSYNTH_VIDEO_DIR") or os.path.join(os.getcwd(), "videos")


def resolve_video_path(name: str, must_exist: bool = False) -> str:
    """Return the absolute path for ``name`` inside ``VIDEO_DIR``.

    Raises ``ValueError`` when the name is empty, escapes the directory
    (``..``, absolute paths, symlinks pointing outside) or, with
    ``must_exist``, does not name an existing file.
    """
    name = (name or "").strip()
    if not name:
        raise ValueError("A file name is required.")
    root = os.path.realpath(VIDEO_DIR)
    os.makedirs(root, exist_ok=True)
    candidate = os.path.realpath(os.path.join(root, name))
    if candidate == root or os.path.commonpath([root, candidate]) != root:
        raise ValueError(f"'{name}' must be a file name inside {root}.")
    if must_exist and not os.path.isfile(candidate):
        raise ValueError(f"'{name}' was not found in {root}.")
    return candidate
