# SystemCore RPi5 Guide

## What this project is

Tooling for running FRC Limelight SystemCore OS on a standard Raspberry Pi 5 Model B (instead of the Compute Module 5). A single `build-image.sh` script produces a ready-to-flash SD card image with zero post-flash interaction.

## Primary workflow

```bash
sudo ./build-image.sh        # downloads upstream image, patches it
sudo dd if=systemcore-pi5b-beta10-v1.img of=/dev/sdX bs=4M status=progress
```

## Project layout

```
build-image.sh        - Main script: downloads upstream image, patches everything
patch-image.py        - Standalone patcher for new upstream releases
patcher/              - Python package backing patch-image.py
  core.py             - Partition discovery, mount tracking, per-patch logic, orchestrator
  gui.py              - Tkinter GUI with live log streaming + per-patch toggles
  cli.py              - argparse, --dry-run / --inspect / --validate / --only
  resources/          - Drop-in service overrides + udev rules + tmpfile configs
netboot/
  flash-pico.sh       - Pico flasher replacement (installed into image by build-image.sh)
  setup-netboot.sh    - TFTP + NFS netboot setup for WSL2 development
  cmdline_nfs.txt     - NFS boot cmdline template
```

## When to use which tool

| Scenario | Tool |
| --- | --- |
| Build a patched image from scratch | `sudo ./build-image.sh` |
| New upstream release | `sudo python3 patch-image.py upstream.img` |
| Apply only one patch to an existing image for debugging | `sudo python3 patch-image.py img --only install_mrccan` |
| Inspect what's in a patched image | `sudo python3 patch-image.py img --inspect` (mounts all 4 partitions, prints paths) |
| Verify a patched image looks right | `sudo python3 patch-image.py img --validate` |
| See what would happen without actually patching | `sudo python3 patch-image.py img --dry-run -v` |

`patcher/resources/*` is the single source of truth for systemd overrides, udev rules, and tmpfile configs. `build-image.sh` currently inlines copies of these via heredocs — keep them in sync if you change one.

Not tracked in git: `cache/`, `*.img`, `*.zip`, `netboot/tftpboot/`, `netboot/nfsroot/`

## What the build script patches

1. **HDMI enabled** — stock image disables all display output (headless for Limelight carrier board)
2. **SPI CAN overlays disabled** — no MCP2518 hardware on Pi 5B
3. **flash-pico.sh** — replaces picoflasherprocess for external USB Pico flashing via dd
4. **Multi-adapter USB-CAN** — any number of USB-CAN adapters, CAN FD with fallback to standard CAN
5. **Persistent CAN naming** — USB port path mapped to stable can_sN index via `/etc/can_port_map`, works with USB hubs
6. **CAN is optional** — 30s timeout, robot starts regardless of adapter presence
7. **CAN discovery frame** — `cansend 000#00` sent on each bus after interface up
8. **vcan placeholders** — canbusprocess fills missing `can_s0..can_s4` slots with vcan interfaces after USB-CAN setup. HAL aborts the robot program if any of the 5 buses is missing (`SIOCGIFINDEX ... No such device`), so this is required for robot.service to start with fewer than 5 physical adapters.
9. **/dev/mrccan tmpfile** — `/etc/tmpfiles.d/mrccan.conf` creates `/dev/mrccan/` at boot. Without it `MrcCommDaemon` crash-loops on `Failed to open control data file`, never sets the NT key `/Netcomm/Control/ServerReady`, and the HAL SIGABRTs the robot program ~10s after start with `Error: Waiting for server ready failed`.
10. **Wireless regdb** — regulatory.db installed for US WiFi channel support
11. **WLAN0 AP settings unlocked** — dashboard JS patched to allow modifying Access Point config
12. **Fault count reset button** — frontend-only baseline reset added to fault tooltip in dashboard

## Key technical details

- Upstream image: `limelightsystemcorebetacm5-limelightosr-beta-10.zip` from GitHub releases
- Beta 10 partition layout (6 partitions):
  - p1: boot selector (FAT32, 16M) — autoboot.txt
  - p2: boot A (FAT32, 64M) — kernel, DTBs, config.txt, cmdline.txt
  - p3: boot B (FAT32, 64M) — same as boot A
  - p4: extended
  - p5: rootfs A (ext4, 7G)
  - p6: rootfs B (ext4, 7G)
- Upstream kernel: 16K pages (stock kernel works on Pi 5B as of Beta 10)
- Pi 5B external USB: xhci-hcd.0 (bus 1, ports 1-1 through 1-2)
- Pico after flash: VID=0xCAFE PID=0x4011 ("Limelight RT Subsystem")
- CAN udev match: `ATTR{type}=="280"` (ARPHRD_CAN, matches any CAN netdev). The build's `90-usb-can-rename.rules` adds `SUBSYSTEMS=="usb"` so vcan interfaces (no parent device) don't match — without that constraint, adding a vcan from inside canbusprocess re-triggers canbusprocess and infinite-loops.
- CAN FD: 1Mbps nominal / 5Mbps data bitrate, falls back to 1Mbps standard CAN if adapter doesn't support FD
- CAN port mapping persisted to `/etc/can_port_map` (port path -> can_sN index)
- HAL CAN expectation: WPILib's HAL (`libwpiHal.so`, `_GLOBAL__N_1::SocketCanState::InitializeBuses`) does `SIOCGIFINDEX` on `can_s0` through `can_s4`. ANY missing one → `IllegalStateException: Failed to initialize. Terminating` from `org.wpilib.framework.RobotBase.startRobot`. canbusprocess fills gaps with vcan after USB-CAN setup.
- HAL netcomm gate: HAL also blocks on NT key `/Netcomm/Control/ServerReady` (string lives in `libwpiHal.so`). The setter is `/usr/bin/MrcCommDaemon` (`mrccomm.service`), which opens `/dev/mrccan/controldata` + `/dev/mrccan/matchinfo` (`O_WRONLY|O_CREAT|O_TRUNC`). On real SystemCore those paths live under a kernel-module-created directory; on Pi 5B the build creates `/dev/mrccan/` via `/etc/tmpfiles.d/mrccan.conf`. Without it: `Failed to open control data file` → mrccomm crash-loops → HAL `Waiting for server ready failed` → SIGABRT (exit 134) ~10s after Java starts.
- RP2350 firmware faults (BROWNOUT, IMU, DISPLAY, CAN, RSL) are cosmetic — closed-source firmware expects carrier board hardware
- Dashboard patches: sed on minified React JS (`main.*.js`), applied to both rootfs A and B
- Interface renaming done in canbusprocess service (NOT udev PROGRAM — `ip link show` is unreliable in udev context)
- Systemd ExecStart must not use `${VAR##pattern}` syntax — systemd strips `${...}` before bash sees it

## Diagnosing a non-starting robot.service on an already-flashed image

```bash
sudo journalctl -u robot.service -n 50 --no-pager
```

| Symptom (journal line) | Cause | Fix |
| --- | --- | --- |
| `ioctl(SIOCGIFINDEX) for CAN can_sN failed with No such device` then `Failed to initialize. Terminating` | Slot `can_sN` is missing from `/sys/class/net/` (fewer than 5 USB CAN adapters and the vcan-placeholder logic isn't running) | `sudo modprobe vcan && sudo ip link add dev can_sN type vcan && sudo ip link set can_sN up` for each missing N. If a service is deleting them, check `/etc/udev/rules.d/90-usb-can-rename.rules` — must include `SUBSYSTEMS=="usb"`, else `ip link add` of a vcan re-triggers canbusprocess which has a "delete CAN interfaces without `device/driver`" cleanup that wipes the vcan you just made. |
| `Error: Waiting for server ready failed. Restarting app and retrying...` then `terminate called without an active exception` and `Aborted (core dumped)` (exit 134) | `MrcCommDaemon` isn't setting `/Netcomm/Control/ServerReady` in NT4 — almost always because it's crash-looping on `Failed to open control data file` | `sudo mkdir -p /dev/mrccan && sudo systemctl restart mrccomm.service`. For persistence write `/etc/tmpfiles.d/mrccan.conf` with `d /dev/mrccan 0755 root root -`. |
| `Failed to initialize can buses` for `can_d2` (not `can_s2`) | Both `can_s*` AND `can_d*` are probed by the HAL. `can_d0..can_d19` are typically created by stock SystemCore-OS init; if they're missing the image is broken — don't rename `can_d*` interfaces away. | Reboot to let stock init recreate them, or `sudo modprobe vcan && for i in $(seq 0 19); do sudo ip link add dev can_d$i type vcan; sudo ip link set can_d$i up; done` |

## Dev environment

- Host: WSL2 on Windows (Ubuntu/Debian)
- Target: Raspberry Pi 5 Model B (BCM2712), ARM64
- SystemCore version: Beta 10 (limelightosr-beta-10-139)
- Test Pi: systemcore@10.0.0.167 (password: systemcore)

## Network boot (for development)

WSL2 serves TFTP + NFS to Pi 5 over the LAN. Requires mirrored networking mode in `.wslconfig`. Run `netboot/setup-netboot.sh` to configure, then set Pi EEPROM boot order to `0xf21`.
