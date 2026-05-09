# FRC SystemCore on Raspberry Pi 5

Run [Limelight SystemCore OS](https://github.com/LimelightVision/systemcore-os-public) on a standard Raspberry Pi 5 Model B instead of the Compute Module 5 it was designed for.

## Quick Start

```bash
git clone https://github.com/netarcx/systemcore-rpi5-guide.git
cd systemcore-rpi5-guide
sudo ./build-image.sh
```

This produces `systemcore-pi5b-beta9.img` — flash it to an SD card and boot:

```bash
sudo dd if=systemcore-pi5b-beta9.img of=/dev/sdX bs=4M status=progress
```

Insert the SD card into your Pi 5 and power on. No further configuration needed.

## What `build-image.sh` does

The script automates everything needed to convert the upstream CM5 image into a Pi 5B-compatible image:

1. **Downloads** the upstream SystemCore Beta 9 image from GitHub (~1.6GB, cached after first download)
2. **Builds a 4K-page kernel** from the rpi-6.6.y branch (15-30 min, cached after first build)
3. **Patches the boot partition** — fixes config, enables HDMI, installs kernel + device trees
4. **Patches both rootfs partitions** (A/B) — installs kernel modules, Pico flasher, CAN adapter support

Options:
- `--rebuild-kernel` — force a kernel rebuild even if one already exists

## What gets patched

### Boot fixes (required for Pi 5B to boot at all)

| Issue | Fix |
|-------|-----|
| Missing `cmdline.txt` | Created — image only ships `cmdline_a.txt` but `config.txt` references `cmdline.txt` |
| Config filter bug | Added `[all]` after `[boot_partition=N]` conditionals so settings apply to both A/B partitions |
| 16K-page kernel | Rebuilt with 4K pages — Buildroot binaries need 4K ELF alignment, 16K kernel rejects them |

### HDMI output

The stock image disables all display output (headless for Limelight hardware). The build script enables HDMI for debugging by commenting out `hdmi_ignore_hotplug`, `hdmi_blanking`, `ignore_lcd` and setting `display_auto_detect=1`.

### SPI CAN overlays disabled

The CM5 carrier board has 5 MCP2518FD SPI CAN controllers. The Pi 5B has none of this hardware, so the SPI CAN overlay lines are commented out to keep the boot log clean.

### Pico flasher (`flash-pico.sh`)

The stock `picoflasherprocess` binary only flashes Pico microcontrollers connected to the Limelight's internal USB controller (`xhci-hcd.0`). On Pi 5B, external USB is `xhci-hcd.1`, so external Picos are rejected.

The build script replaces it with `flash-pico.sh` via a systemd override. This script:
- Polls for any Pico in BOOTSEL mode on any USB port (vendor ID `2e8a`)
- Mounts the Pico's mass storage, copies `fw.uf2`, unmounts
- Works with RP2350 Picos (RP2040 not supported — firmware is RP2350-specific)
- After flashing, the Pico appears as `cafe:4011` ("Limelight RT Subsystem")

### USB-CAN adapter support (optional)

The stock image expects 5 SPI CAN interfaces (`can_s0` through `can_s4`). The build script adds support for a single USB-to-CAN adapter as a substitute:

- **Udev rule** renames any USB-CAN adapter's network interface to `can_s0`
- **canbusprocess override** waits up to 30 seconds for `can_s0`, configures it at 1Mbps
- **canbuswatchdog override** watches `can_s0` only
- **robot.service override** waits 30 seconds for CAN, starts regardless

If no CAN adapter is plugged in, all services time out gracefully and the robot starts anyway. If an adapter is plugged in later, the canbusprocess service will pick it up on its next restart cycle.

Compatible with any SocketCAN-supported USB adapter (candleLight/canable, PEAK, EMS, etc.).

### Wireless regulatory database

The stock image may be missing `regulatory.db`, which tells the kernel which WiFi channels are legal in your country. The build script installs the US regulatory database so WiFi works correctly (paired with `cfg80211.ieee80211_regdom=US` in the kernel cmdline).

### Kernel modules

The stock 16K-page kernel modules won't load under the 4K-page kernel. The build script installs matching modules built from the same kernel source, including `gs_usb` for USB-CAN adapter support.

## Known limitations

- **RP2350 firmware faults** — After flashing, the Pico firmware reports faults for hardware it expects on the carrier board (BROWNOUT, IMU, DISPLAY, CAN, RSL). These are cosmetic — USB communication works fine. The firmware is closed-source so these cannot be fixed.
- **RP2040 not supported** — `fw.uf2` is RP2350-specific. An RP2040 Pico will accept the copy but reboot back to BOOTSEL in a loop.
- **Single CAN bus** — Only one USB-CAN adapter is supported (mapped to `can_s0`). The stock 5-bus SPI CAN setup requires the carrier board.
- **USB gadget mode** — The `dwc2` overlay behavior may differ between CM5 and Pi 5B.

## Project layout

```
build-image.sh          - End-to-end image builder (run with sudo)
build-kernel.sh         - Cross-compiles 4K-page kernel for Pi 5
boot/                   - Boot configs for Beta 7 (legacy)
boot9/                  - Boot configs for Beta 9 (used by build-image.sh)
  config.txt            - Full Pi 5 config with CAN overlays, USB gadget, etc.
  cmdline.txt           - Kernel cmdline for rootfs A
  cmdline_b.txt         - Kernel cmdline for rootfs B
  autoboot.txt          - A/B boot partition selection
netboot/                - Network boot setup (development/debugging)
  flash-pico.sh         - Pico flasher replacement (installed into image)
  setup-netboot.sh      - Sets up TFTP + NFS on WSL2 for netboot
  cmdline_nfs.txt       - Kernel cmdline template for NFS root
```

Files not tracked in git (generated/downloaded):
```
cache/                  - Downloaded upstream image zip (~1.6GB)
rpi-linux/              - Kernel source tree (~2.8GB, cloned by build-kernel.sh)
systemcore-pi5b-beta9.img - Output image (~10GB)
netboot/tftpboot/       - TFTP boot files (kernel, DTBs, overlays)
netboot/nfsroot/        - NFS root mount point
```

## Network boot (development)

For iterative development, the Pi 5 can netboot from a WSL2 host via TFTP + NFS:

```bash
sudo ./netboot/setup-netboot.sh
```

This installs `tftpd-hpa` and `nfs-kernel-server`, configures exports, and prints Pi 5 EEPROM settings. WSL2 must use **mirrored networking** mode (set `networkingMode=mirrored` in `%USERPROFILE%\.wslconfig`).

## Prerequisites

- Linux host for building (Ubuntu/Debian, WSL2 works)
- `aarch64-linux-gnu-gcc` cross-compiler (installed automatically by `build-kernel.sh`)
- ~15GB free disk space (kernel source + images)
- `sudo` access (for loop-mounting image partitions)

## Tested on

- Raspberry Pi 5 Model B (4GB/8GB)
- SystemCore Beta 9 (`limelightosr-beta-9-12`)
- Kernel: Linux 6.6.78-v8-16k+ (rpi-6.6.y branch, 4K pages, ARM64)
- Host: WSL2 on Windows 11

## License

The kernel is licensed under GPL-2.0 (same as the Linux kernel). Boot configuration files and scripts are provided as-is.
