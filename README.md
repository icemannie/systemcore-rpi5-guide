# FRC SystemCore on Raspberry Pi 5

Run the [Limelight SystemCore Beta](https://github.com/LimelightVision/systemcore-os-public) on a standard Raspberry Pi 5 Model B instead of the Compute Module 5.

## Why this is needed

The SystemCore image is built for the Raspberry Pi Compute Module 5 and won't boot on a standard Pi 5 out of the box due to three issues:

1. **Missing `cmdline.txt`** -- The boot config references `cmdline.txt` but the image only ships `cmdline_a.txt`, so the kernel boots without a `root=` parameter and can't find the root filesystem.

2. **Config filter bug** -- `config.txt` uses `[boot_partition=N]` conditionals without a closing `[all]`, causing all kernel/overlay settings to only apply when booting from partition B.

3. **16K page kernel vs 4K binaries** -- The stock kernel uses 16K memory pages, but the Buildroot userspace binaries are compiled with 4K page alignment. The kernel's ELF loader rejects every binary with `EINVAL`, including `/sbin/init`.

## Prerequisites

- A SystemCore Beta SD card image (flashed via the standard SystemCore flashing process)
- A Linux system for cross-compiling (Ubuntu/Debian recommended, WSL2 works)
- ~4GB disk space for the kernel source and build

## Quick Start

### 1. Build the kernel

```bash
git clone https://github.com/netarcx/systemcore-rpi5-guide.git
cd systemcore-rpi5-guide
./build-kernel.sh
```

This takes 15-30 minutes depending on your CPU. It will:
- Clone the Raspberry Pi kernel source (rpi-6.6.y branch)
- Configure it for BCM2712 (Pi 5) with **4K pages**
- Cross-compile the kernel, modules, and device trees
- Package everything into the `output/` directory

### 2. Prepare the SD card

Insert your SystemCore SD card and mount the **boot partition** (the small FAT32 partition, usually the first one).

### 3. Replace boot files

Copy the patched boot configuration files to the boot partition:

```bash
# Back up originals
cp /path/to/boot/config.txt /path/to/boot/config.txt.bak
cp /path/to/boot/Image /path/to/boot/Image.bak

# Copy patched boot config
cp boot/config.txt /path/to/boot/config.txt
cp boot/cmdline.txt /path/to/boot/cmdline.txt
cp boot/cmdline_b.txt /path/to/boot/cmdline_b.txt
cp boot/autoboot.txt /path/to/boot/autoboot.txt

# Copy the new kernel and device trees
cp output/kernel_2712.img /path/to/boot/kernel_2712.img
cp output/bcm2712*.dtb /path/to/boot/
cp output/overlays/* /path/to/boot/overlays/

# Remove the old CM5 kernel (frees space on the small boot partition)
rm /path/to/boot/Image
```

### 4. Install kernel modules (optional)

If you need full hardware support, install the matching kernel modules on the root partition:

```bash
# Mount the root partition (partition 2)
sudo mount /dev/sdX2 /mnt/rootfs

# Extract modules
sudo tar xzf output/modules-*.tar.gz -C /mnt/rootfs/

sudo umount /mnt/rootfs
```

### 5. Boot

Insert the SD card into your Pi 5 and power on. The SystemCore should boot normally.

## What changed

### config.txt
| Change | Why |
|--------|-----|
| Added `[all]` after `[boot_partition]` conditionals | Ensures kernel, overlay, and hardware settings apply to both A/B partitions |
| Changed `kernel=Image` to `kernel=kernel_2712.img` | Loads the Pi 5-compatible kernel |
| Commented out `dtoverlay=pi3-disable-bt` | This overlay doesn't exist on Pi 5; `disable-bt` already handles it |

### cmdline.txt
| Change | Why |
|--------|-----|
| Created the file (was missing entirely) | `config.txt` references `cmdline.txt` for partition A boot, but only `cmdline_a.txt` existed |
| Added `rootdelay=5` | Gives the Pi 5's PCIe-attached RP1 SD controller time to initialize |

### Kernel
| Change | Why |
|--------|-----|
| Rebuilt from `bcm2712_defconfig` | Targets Pi 5 Model B hardware (BCM2712 SoC) |
| Switched from 16K to 4K pages | SystemCore's Buildroot binaries use 4K ELF alignment; 16K page kernels reject them with EINVAL |

## Limitations

- The CAN bus overlays (`sc-mcp2518-*`) are designed for the SystemCore hardware. On a bare Pi 5 without the SystemCore carrier board, CAN bus functionality won't work (but the system will still boot).
- USB gadget mode (`dwc2` overlay) behavior may differ between the CM5 and Pi 5B.
- Kernel modules from the original SystemCore image won't load since the kernel version differs. Use the modules built by `build-kernel.sh` for full hardware support.

## Tested on

- Raspberry Pi 5 Model B (4GB/8GB)
- SystemCore Beta 7 (Limelight_SYSTEMCOREBETA-7)
- Kernel: Linux 6.6.78 (rpi-6.6.y branch, 4K pages, ARM64)

## License

The kernel is licensed under GPL-2.0 (same as the Linux kernel). Boot configuration files are provided as-is.
