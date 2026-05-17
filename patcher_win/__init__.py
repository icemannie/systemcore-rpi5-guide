"""Windows-native SystemCore Pi 5B image patcher.

Uses pure Python for partition table parsing, pyfatfs for FAT32 boot
partitions, and bundled e2fsprogs (debugfs.exe) for ext4 rootfs access.
No WSL, no Linux mount commands, no admin/root required for FAT32 ops.
"""
