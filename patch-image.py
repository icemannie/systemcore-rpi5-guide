#!/usr/bin/env python3
"""Convenience launcher: `sudo python3 patch-image.py [args]`.

Equivalent to `python3 -m patcher` but works from the project root without
needing the package on PYTHONPATH.
"""

import sys
from pathlib import Path

# Ensure the patcher package is importable regardless of cwd.
sys.path.insert(0, str(Path(__file__).resolve().parent))

from patcher.cli import main  # noqa: E402

if __name__ == "__main__":
    raise SystemExit(main())
