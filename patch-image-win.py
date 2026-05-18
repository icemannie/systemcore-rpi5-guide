#!/usr/bin/env python3
"""Windows-native SystemCore Pi 5B image patcher.

Launch with no arguments for the GUI, or pass an image path for CLI mode.

Requirements:
  pip install pyfatfs
  Place debugfs.exe in patcher_win/tools/ (see patcher_win/tools/README.txt)

Usage:
  python patch-image-win.py                       # GUI mode
  python patch-image-win.py image.img             # Patch with defaults
  python patch-image-win.py image.img --dry-run   # Preview without changes
  python patch-image-win.py image.img --only install_mrccan
"""

import sys
from pathlib import Path

# Ensure the project root is on the path so patcher_win can be imported
sys.path.insert(0, str(Path(__file__).resolve().parent))


def cli():
    import argparse
    import logging

    from patcher_win.core import PatchOptions, patch_image, PATCH_DESCRIPTIONS

    parser = argparse.ArgumentParser(
        description="Windows-native SystemCore Pi 5B image patcher")
    parser.add_argument("input_image", nargs="?", help="Input .img or .zip file")
    parser.add_argument("-o", "--output", help="Output image path (default: <input>-pi5b.img)")
    parser.add_argument("--dry-run", action="store_true", help="Log only, don't modify")
    parser.add_argument("-v", "--verbose", action="store_true")
    parser.add_argument("--backup", action="store_true", help="Backup input before patching")
    parser.add_argument("--skip-b", action="store_true", help="Only patch A partitions")
    parser.add_argument("--validate", action="store_true", help="Validate after patching")
    parser.add_argument("--only", nargs="+", help="Run only these patches",
                        choices=list(PATCH_DESCRIPTIONS.keys()))
    parser.add_argument("--list-patches", action="store_true",
                        help="List available patches and exit")
    args = parser.parse_args()

    if args.list_patches:
        for name, desc in PATCH_DESCRIPTIONS.items():
            print(f"  {name:30s} {desc}")
        return

    if args.input_image is None:
        # No image given — launch GUI
        from patcher_win.gui import run
        run()
        return

    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(asctime)s [%(levelname)s] %(message)s",
        datefmt="%H:%M:%S",
    )
    log = logging.getLogger("patcher")

    input_path = Path(args.input_image)
    if args.output:
        output_path = Path(args.output)
    else:
        stem = input_path.stem
        if stem.endswith(".img"):
            stem = stem[:-4]
        output_path = input_path.with_name(stem + "-pi5b.img")

    opts = PatchOptions(
        input_image=input_path,
        output_image=output_path,
        dry_run=args.dry_run,
        verbose=args.verbose,
        backup=args.backup,
        skip_b_partitions=args.skip_b,
        validate_after=args.validate,
    )

    if args.only:
        for name in opts.patch_names():
            setattr(opts, name, name in args.only)

    patch_image(opts, log)


if __name__ == "__main__":
    cli()
