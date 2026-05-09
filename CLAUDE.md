# SystemCore RPi5 Guide

## What this project is

Tooling for running FRC Limelight SystemCore OS on a standard Raspberry Pi 5 Model B (instead of the Compute Module 5). A single `build-image.sh` script produces a ready-to-flash SD card image with zero post-flash interaction.

## Primary workflow

```bash
sudo ./build-image.sh        # downloads, builds kernel (cached), patches image
sudo dd if=systemcore-pi5b-beta9.img of=/dev/sdX bs=4M status=progress
```

## Project layout

```
build-image.sh        - Main script: downloads upstream image, builds kernel, patches everything
build-kernel.sh       - Cross-compiles 4K-page ARM64 kernel from rpi-6.6.y
boot9/                - Boot partition source files (config.txt, cmdline.txt, etc.)
netboot/
  flash-pico.sh       - Pico flasher replacement (installed into image by build-image.sh)
  setup-netboot.sh    - TFTP + NFS netboot setup for WSL2 development
  cmdline_nfs.txt     - NFS boot cmdline template
boot/                 - Legacy Beta 7 boot configs (superseded by boot9/)
beta9/
  apply-patches.sh    - Legacy patch script (superseded by build-image.sh)
```

Not tracked in git: `rpi-linux/`, `cache/`, `*.img`, `*.zip`, `netboot/tftpboot/`, `netboot/nfsroot/`

## The three boot issues this project fixes

1. **Missing cmdline.txt** — config.txt references it but image only ships cmdline_a.txt
2. **Config filter bug** — `[boot_partition=N]` without closing `[all]` breaks partition A boot
3. **16K vs 4K pages** — Stock kernel uses 16K pages, Buildroot binaries need 4K alignment

## Additional Pi 5B adaptations

- **HDMI enabled** — stock image disables all display (headless for Limelight hardware)
- **SPI CAN overlays disabled** — no MCP2518 hardware on Pi 5B
- **flash-pico.sh** — replaces picoflasherprocess for external USB Pico flashing
- **USB-CAN support** — udev rule + systemd overrides for any USB-CAN adapter at 1Mbps
- **CAN is optional** — 30s timeout, robot starts regardless of adapter presence
- **Kernel modules** — replaced to match 4K kernel (gs_usb needed for USB-CAN)
- **Wireless regdb** — regulatory.db installed for US WiFi channel support

## Key technical details

- Upstream image: `limelightsystemcorebetacm5-limelightosr-beta-9.zip` from GitHub releases
- Image partitions: boot(sector 1), rootfs_a(131073), rootfs_b(10616833), data(21102593)
- Kernel version: 6.6.78-v8-16k+ (4K pages despite the name)
- Pi 5B external USB: xhci-hcd.1 (Limelight internal is xhci-hcd.0)
- Pico after flash: VID=0xCAFE PID=0x4011 ("Limelight RT Subsystem")
- CAN udev match: ATTR{type}=="280" (ARPHRD_CAN, matches any CAN netdev)
- RP2350 firmware faults (BROWNOUT, IMU, DISPLAY, CAN, RSL) are cosmetic — closed-source firmware expects carrier board hardware

## Dev environment

- Host: WSL2 on Windows (Ubuntu/Debian)
- Cross-compiler: aarch64-linux-gnu-gcc
- Target: Raspberry Pi 5 Model B (BCM2712), ARM64
- Kernel branch: rpi-6.6.y
- SystemCore version: Beta 9 (limelightosr-beta-9-12)
- Test Pi: systemcore@10.0.0.169 (password: systemcore)

## Network boot (for development)

WSL2 serves TFTP + NFS to Pi 5 over the LAN. Requires mirrored networking mode in `.wslconfig`. Run `netboot/setup-netboot.sh` to configure, then set Pi EEPROM boot order to `0xf21`.
