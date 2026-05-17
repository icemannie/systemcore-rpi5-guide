"""Pure-Python .deb file extraction.

Replaces dpkg-deb — parses the ar archive format and extracts the
data.tar.* member to get the package's installed files.
"""

from __future__ import annotations

import io
import struct
import tarfile
import tempfile
from pathlib import Path
from typing import Iterator


def _parse_ar_members(data: bytes) -> Iterator[tuple[str, bytes]]:
    """Parse an ar archive, yielding (name, content) for each member."""
    if not data.startswith(b"!<arch>\n"):
        raise ValueError("Not a valid ar archive (missing magic)")

    offset = 8
    while offset < len(data):
        if offset % 2 == 1:
            offset += 1

        header = data[offset:offset + 60]
        if len(header) < 60:
            break

        name = header[0:16].decode("ascii").strip().rstrip("/")
        size = int(header[48:58].decode("ascii").strip())
        offset += 60

        content = data[offset:offset + size]
        offset += size

        yield name, content


def extract_deb_data(deb_path: Path, dest_dir: Path) -> None:
    """Extract the data payload of a .deb into dest_dir.

    Handles data.tar.gz, data.tar.xz, and data.tar.zst members.
    """
    deb_data = deb_path.read_bytes()

    data_member = None
    data_name = None
    for name, content in _parse_ar_members(deb_data):
        if name.startswith("data.tar"):
            data_member = content
            data_name = name
            break

    if data_member is None:
        raise ValueError(f"No data.tar.* member found in {deb_path}")

    if data_name.endswith(".zst"):
        try:
            import zstandard
            dctx = zstandard.ZstdDecompressor()
            data_member = dctx.decompress(data_member)
            data_name = "data.tar"
        except ImportError:
            raise RuntimeError(
                "This .deb uses zstd compression. Install zstandard: pip install zstandard"
            )

    fileobj = io.BytesIO(data_member)

    if data_name.endswith(".gz"):
        mode = "r:gz"
    elif data_name.endswith(".xz"):
        mode = "r:xz"
    elif data_name.endswith(".bz2"):
        mode = "r:bz2"
    else:
        mode = "r:"

    with tarfile.open(fileobj=fileobj, mode=mode) as tar:
        tar.extractall(path=dest_dir)
