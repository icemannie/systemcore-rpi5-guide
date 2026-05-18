"""FAT32 partition access using pyfatfs.

Provides file read/write/copy operations on a FAT32 partition embedded
inside a raw disk image at a known byte offset. No mounting required.
"""

from __future__ import annotations

import io
import logging
from pathlib import Path, PurePosixPath
from typing import TYPE_CHECKING, Any

if TYPE_CHECKING:
    from fs.base import FS

log = logging.getLogger("patcher")


class FatPartition:
    """Context manager wrapping a pyfatfs filesystem at a given image offset."""

    def __init__(self, image_path: Path, offset: int, size: int):
        self.image_path = image_path
        self.offset = offset
        self.size = size
        self._fs: Any = None
        self._stream: io.BytesIO | None = None

    def __enter__(self) -> "FatPartition":
        from pyfatfs.PyFatFS import PyFatBytesIOFS

        with open(self.image_path, "rb") as f:
            f.seek(self.offset)
            partition_data = f.read(self.size)

        self._stream = io.BytesIO(partition_data)
        self._fs = PyFatBytesIOFS(fp=self._stream, encoding="utf-8")
        return self

    def __exit__(self, *exc):
        if self._fs:
            self._fs.close()
            self._fs = None

        if self._stream:
            self._stream.seek(0)
            modified_data = self._stream.read()
            self._stream = None

            with open(self.image_path, "r+b") as f:
                f.seek(self.offset)
                f.write(modified_data)

    @property
    def fs(self) -> Any:
        if self._fs is None:
            raise RuntimeError("FatPartition not opened — use as context manager")
        return self._fs

    def read_text(self, path: str) -> str:
        """Read a text file from the FAT partition."""
        with self.fs.open(path, "r") as f:
            return f.read()

    def write_text(self, path: str, content: str) -> None:
        """Write a text file to the FAT partition, creating parent dirs."""
        parent = str(PurePosixPath(path).parent)
        if parent != "/" and not self.fs.isdir(parent):
            self.fs.makedirs(parent, recreate=True)
        with self.fs.open(path, "w") as f:
            f.write(content)
        log.info("  wrote %s (%d bytes)", path, len(content))

    def write_binary(self, path: str, data: bytes) -> None:
        """Write binary data to a file on the FAT partition."""
        parent = str(PurePosixPath(path).parent)
        if parent != "/" and not self.fs.isdir(parent):
            self.fs.makedirs(parent, recreate=True)
        with self.fs.open(path, "wb") as f:
            f.write(data)
        log.info("  wrote %s (%d bytes)", path, len(data))

    def copy_file_in(self, local_path: Path, dest_path: str) -> None:
        """Copy a local file into the FAT partition."""
        data = local_path.read_bytes()
        self.write_binary(dest_path, data)

    def exists(self, path: str) -> bool:
        """Check if a file or directory exists."""
        return self.fs.exists(path)

