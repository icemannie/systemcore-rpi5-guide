# SystemCore RPi5 Guide

## What this project is

Tooling for running FRC Limelight SystemCore OS on a standard Raspberry Pi 5 Model B (instead of the Compute Module 5). A single `build-image.sh` script produces a ready-to-flash SD card image with zero post-flash interaction.

## Primary workflow

```bash
sudo ./build-image.sh        # downloads, builds kernel (cached), patches image
sudo dd if=systemcore-pi5b-beta10-v1.img of=/dev/sdX bs=4M status=progress
```

## Project layout

```
build-image.sh        - Main script: downloads upstream image, builds kernel, patches everything
build-kernel.sh       - Cross-compiles 4K-page ARM64 kernel from rpi-6.12.y
check-image.sh        - Validates a built image (partition layout, kernel, patches)
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

## What the build script patches

1. **4K-page kernel** — Stock kernel uses 16K pages, Buildroot binaries need 4K alignment. Cross-compiled from rpi-6.12.y with matching modules.
2. **HDMI enabled** — stock image disables all display output (headless for Limelight carrier board)
3. **SPI CAN overlays disabled** — no MCP2518 hardware on Pi 5B
4. **flash-pico.sh** — replaces picoflasherprocess for external USB Pico flashing via dd
5. **Multi-adapter USB-CAN** — any number of USB-CAN adapters, CAN FD with fallback to standard CAN
6. **Persistent CAN naming** — USB port path mapped to stable can_sN index via `/etc/can_port_map`, works with USB hubs
7. **CAN is optional** — 30s timeout, robot starts regardless of adapter presence
8. **CAN discovery frame** — `cansend 000#00` sent on each bus after interface up
9. **Wireless regdb** — regulatory.db installed for US WiFi channel support
10. **WLAN0 AP settings unlocked** — dashboard JS patched to allow modifying Access Point config
11. **Fault count reset button** — frontend-only baseline reset added to fault tooltip in dashboard

## Key technical details

- Upstream image: `limelightsystemcorebetacm5-limelightosr-beta-10.zip` from GitHub releases
- Beta 10 partition layout (6 partitions):
  - p1: boot selector (FAT32, 16M) — autoboot.txt
  - p2: boot A (FAT32, 64M) — kernel, DTBs, config.txt, cmdline.txt
  - p3: boot B (FAT32, 64M) — same as boot A
  - p4: extended
  - p5: rootfs A (ext4, 7G)
  - p6: rootfs B (ext4, 7G)
- Kernel version: 6.12.87-v8-16k+ (4K pages despite the name)
- Pi 5B external USB: xhci-hcd.0 (bus 1, ports 1-1 through 1-2)
- Pico after flash: VID=0xCAFE PID=0x4011 ("Limelight RT Subsystem")
- CAN udev match: ATTR{type}=="280" (ARPHRD_CAN, matches any CAN netdev)
- CAN FD: 1Mbps nominal / 5Mbps data bitrate, falls back to 1Mbps standard CAN if adapter doesn't support FD
- CAN port mapping persisted to `/etc/can_port_map` (port path -> can_sN index)
- RP2350 firmware faults (BROWNOUT, IMU, DISPLAY, CAN, RSL) are cosmetic — closed-source firmware expects carrier board hardware
- Dashboard patches: sed on minified React JS (`main.*.js`), applied to both rootfs A and B
- Interface renaming done in canbusprocess service (NOT udev PROGRAM — `ip link show` is unreliable in udev context)
- Systemd ExecStart must not use `${VAR##pattern}` syntax — systemd strips `${...}` before bash sees it

## Dev environment

- Host: WSL2 on Windows (Ubuntu/Debian)
- Cross-compiler: aarch64-linux-gnu-gcc
- Target: Raspberry Pi 5 Model B (BCM2712), ARM64
- Kernel branch: rpi-6.12.y
- SystemCore version: Beta 10 (limelightosr-beta-10-139)
- Test Pi: systemcore@10.0.0.167 (password: systemcore)

## Network boot (for development)

WSL2 serves TFTP + NFS to Pi 5 over the LAN. Requires mirrored networking mode in `.wslconfig`. Run `netboot/setup-netboot.sh` to configure, then set Pi EEPROM boot order to `0xf21`.
